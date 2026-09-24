import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../../domain/entities/app_shortcut.dart';
import '../../../domain/entities/connection_state.dart';
import '../../../domain/entities/remote_key.dart';
import '../../../domain/errors.dart';
import '../../../domain/ports/remote_controller.dart';
import '../../net/protobuf.dart';
import '../../net/tls_trust.dart';
import '../../net/wake_on_lan.dart';
import '../base_controller.dart';
import 'android_tv_certificate.dart';
import 'android_tv_keys.dart';

/// Codificação das mensagens `RemoteMessage` (remotemessage.proto).
class RemoteMessages {
  static const magic = 622;

  static Uint8List configure() {
    final info = ProtoWriter()
      ..string(1, 'kRemote')
      ..string(2, 'khori')
      ..int32(3, 1)
      ..string(4, '1')
      ..string(5, 'br.com.khori.kremote')
      ..string(6, '1.0.0');
    final cfg = ProtoWriter()
      ..int32(1, magic)
      ..message(2, info);
    return ProtoWriter.frameVarint((ProtoWriter()..message(1, cfg)).toBytes());
  }

  static Uint8List setActive() =>
      ProtoWriter.frameVarint((ProtoWriter()..message(2, ProtoWriter()..int32(1, magic))).toBytes());

  static Uint8List pingResponse(int val) =>
      ProtoWriter.frameVarint((ProtoWriter()..message(9, ProtoWriter()..int32(1, val))).toBytes());

  static Uint8List keyInject(int keyCode, int direction) {
    final k = ProtoWriter()
      ..int32(1, keyCode)
      ..int32(2, direction);
    return ProtoWriter.frameVarint((ProtoWriter()..message(10, k)).toBytes());
  }

  static Uint8List appLink(String link) =>
      ProtoWriter.frameVarint((ProtoWriter()..message(90, ProtoWriter()..string(1, link))).toBytes());

  static const directionStartLong = 1;
  static const directionEndLong = 2;
  static const directionShort = 3;
}

/// Controlador Google TV / Android TV (Android TV Remote v2, porta 6466).
class AndroidTvController extends BaseRemoteController {
  AndroidTvController(super.device, this.identity, this.trust, {RemoteController? volumeFallback})
    // ignore: prefer_initializing_formals
    : _volumeFallback = volumeFallback;

  /// Identidade emparelhada; `null` enquanto o aparelho não foi emparelhado.
  final ClientIdentity? identity;
  final TlsTrust trust;

  /// Controlador Cast do mesmo aparelho, usado para volume quando
  /// [RemoteDevice.volumeViaCast] está ativo.
  final RemoteController? _volumeFallback;

  static const _volumeKeys = {RemoteKey.volumeUp, RemoteKey.volumeDown, RemoteKey.mute};

  SecureSocket? _socket;
  final _buffer = <int>[];
  Completer<void>? _ready;
  Timer? _watchdog;

  @override
  Set<RemoteKey> get supportedKeys => androidTvKeyCodes.keys.toSet();

  @override
  Set<RemoteCapability> get capabilities => {
    RemoteCapability.textInput,
    RemoteCapability.appLaunch,
    if (device.macAddress != null) RemoteCapability.wakeOnLan,
  };

  /// Acorda o aparelho por Wake-on-LAN e aguarda o serviço remoto responder.
  /// Retorna verdadeiro se conseguiu conectar após o pacote mágico.
  Future<bool> wake({Duration timeout = const Duration(seconds: 15)}) async {
    final mac = device.macAddress;
    if (mac == null) return false;
    log('enviando Wake-on-LAN');
    await const WakeOnLan().wake(mac, host: device.host);
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      try {
        await connect();
        if (currentState == DeviceConnectionState.connected) return true;
      } on RemoteException {
        // ainda acordando
      }
    }
    return false;
  }

  @override
  Future<void> connect() async {
    if (currentState == DeviceConnectionState.connected) return;
    if (_ready != null && !_ready!.isCompleted) return _ready!.future;
    _ready = Completer<void>();
    final id = identity;
    if (id == null) {
      setState(DeviceConnectionState.needsPairing);
      const err = PairingException('Dispositivo precisa ser emparelhado');
      _completeReadyError(err);
      throw err;
    }
    setState(DeviceConnectionState.connecting);
    try {
      await trust.load();
      final ctx = SecurityContext(withTrustedRoots: false)
        ..useCertificateChainBytes(id.certificatePem.codeUnits)
        ..usePrivateKeyBytes(id.privateKeyPem.codeUnits);
      // Fechado em _teardown() via _socket.destroy().
      // ignore: close_sinks
      final socket = await SecureSocket.connect(
        device.host,
        device.port,
        context: ctx,
        onBadCertificate: trust.accept,
        timeout: const Duration(seconds: 8),
      );
      _socket = socket;
      await trust.commit();
      socket.listen(_onData, onError: _onError, onDone: _onDone, cancelOnError: true);
      _armWatchdog();
      await _ready!.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw const ConnectionException('A TV não concluiu o handshake');
        },
      );
    } on HandshakeException {
      // TLS recusado: ou a TV não reconhece nosso certificado (reemparelhar)
      // ou o certificado da TV mudou (pin divergente).
      final err = TlsTrust.describeHandshakeFailure(hadPin: trust.hasPin);
      _teardown(err is PairingException ? DeviceConnectionState.needsPairing : DeviceConnectionState.error);
      _completeReadyError(err);
      throw err;
    } on RemoteException catch (e) {
      // Erros já traduzidos (ex.: needsPairing sinalizado por _onDone).
      if (currentState == DeviceConnectionState.connecting) _teardown(DeviceConnectionState.error);
      _completeReadyError(e);
      rethrow;
    } catch (e) {
      _teardown(DeviceConnectionState.error);
      final err = ConnectionException(e.toString());
      _completeReadyError(err);
      throw err;
    }
  }

  void _completeReadyError(Object e) {
    final r = _ready;
    if (r != null && !r.isCompleted) {
      r.future.ignore();
      r.completeError(e);
    }
  }

  void _armWatchdog() {
    _watchdog?.cancel();
    // A TV envia ping a cada ~5s; sem tráfego por 20s consideramos queda.
    _watchdog = Timer(const Duration(seconds: 20), () {
      log('watchdog: sem tráfego, encerrando');
      _teardown(DeviceConnectionState.disconnected);
    });
  }

  void _onData(Uint8List data) {
    _armWatchdog();
    _buffer.addAll(data);
    Uint8List? frame;
    while ((frame = ProtoReader.takeVarintFrame(_buffer)) != null) {
      try {
        _handle(ProtoReader(frame!).readAll());
      } catch (e) {
        log('mensagem inválida: $e');
      }
    }
  }

  void _handle(Map<int, ProtoField> msg) {
    if (msg.containsKey(1)) {
      _socket?.add(RemoteMessages.configure());
    } else if (msg.containsKey(2)) {
      _socket?.add(RemoteMessages.setActive());
      setState(DeviceConnectionState.connected);
      if (_ready != null && !_ready!.isCompleted) _ready!.complete();
    } else if (msg.containsKey(8)) {
      final val = msg[8]!.asMessage.readAll()[1]?.asInt ?? 0;
      _socket?.add(RemoteMessages.pingResponse(val));
    } else if (msg.containsKey(3)) {
      log('remote_error recebido');
    }
  }

  void _onError(Object e) {
    log('erro de socket: $e');
    final isTls = e is HandshakeException || e is TlsException;
    _teardown(isTls ? DeviceConnectionState.needsPairing : DeviceConnectionState.error);
    _completeReadyError(
      isTls
          ? const PairingException('Dispositivo precisa ser emparelhado novamente')
          : ConnectionException(e.toString()),
    );
  }

  void _onDone() {
    if (currentState == DeviceConnectionState.connecting) {
      // A TV fecha o socket sem handshake TLS explícito quando não reconhece o cliente.
      _teardown(DeviceConnectionState.needsPairing);
      _completeReadyError(const PairingException('Dispositivo precisa ser emparelhado'));
    } else {
      _teardown(DeviceConnectionState.disconnected);
    }
  }

  void _teardown(DeviceConnectionState next) {
    _watchdog?.cancel();
    _watchdog = null;
    _socket?.destroy();
    _socket = null;
    _buffer.clear();
    setState(next);
  }

  @override
  Future<void> disconnect() async {
    _teardown(DeviceConnectionState.disconnected);
    await _volumeFallback?.disconnect();
  }

  @override
  Future<void> sendKey(RemoteKey key, {KeyPress press = KeyPress.short}) async {
    final code = androidTvKeyCodes[key] ?? unsupported(key);
    final fallback = _volumeFallback;
    if (device.volumeViaCast && fallback != null && _volumeKeys.contains(key)) {
      if (press == KeyPress.longEnd) return;
      try {
        await fallback.sendKey(key);
        log('${key.name} via Cast ok');
        return;
      } on RemoteException catch (e) {
        // Cast indisponível: cai para a injeção de tecla convencional.
        log('volume via Cast falhou (${e.message}); usando tecla');
      }
    }
    if (key == RemoteKey.power && currentState != DeviceConnectionState.connected) {
      // Em "standby em rede" o serviço responde e a tecla Power liga o aparelho.
      // Se o Wi-Fi está desligado em repouso, só Wake-on-LAN (com MAC) acorda.
      try {
        await ensureConnected();
      } on RemoteException {
        if (device.macAddress != null) {
          if (await wake()) return; // acordou: não enviar Power (desligaria)
          throw const ConnectionException('Aparelho não respondeu ao Wake-on-LAN');
        }
        throw const ConnectionException(
          'Aparelho fora do alcance da rede. Ative "Standby em rede" nas configurações de energia '
          'ou informe o MAC em Meus dispositivos para ligar por Wake-on-LAN.',
        );
      }
    }
    await ensureConnected();
    final dir = switch (press) {
      KeyPress.short => RemoteMessages.directionShort,
      KeyPress.longStart => RemoteMessages.directionStartLong,
      KeyPress.longEnd => RemoteMessages.directionEndLong,
    };
    _socket!.add(RemoteMessages.keyInject(code, dir));
    log('key_inject ${key.name} ($code, dir=$dir)');
  }

  @override
  Future<void> sendText(String text) async {
    await ensureConnected();
    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      final code = androidTvKeyCodeForChar(ch);
      if (code == null) continue;
      _socket!.add(RemoteMessages.keyInject(code, RemoteMessages.directionShort));
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  }

  @override
  Future<void> launchApp(AppShortcut app) async {
    final link = app.ids[device.protocol.name];
    if (link == null) throw UnsupportedError('App sem deep link para Android TV');
    await ensureConnected();
    _socket!.add(RemoteMessages.appLink(link));
  }

  @override
  void dispose() {
    _teardown(DeviceConnectionState.disconnected);
    final f = _volumeFallback;
    if (f is BaseRemoteController) f.dispose();
    super.dispose();
  }
}
