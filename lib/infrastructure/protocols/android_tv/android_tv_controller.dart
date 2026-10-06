import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../../domain/entities/app_shortcut.dart';
import '../../../domain/entities/connection_state.dart';
import '../../../domain/entities/remote_key.dart';
import '../../../domain/errors.dart';
import '../../../domain/ports/remote_controller.dart';
import '../../../domain/ports/wake_source.dart';
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

  /// Edição de texto via IME: substitui o conteúdo do campo em foco.
  /// `RemoteImeBatchEdit{ime_counter, field_counter, edit_info[{insert, text_field_status}]}`.
  static Uint8List imeBatchEdit({required int imeCounter, required int fieldCounter, required String text}) {
    final status = ProtoWriter()
      ..int32(1, fieldCounter)
      ..string(2, text)
      ..int32(3, text.length)
      ..int32(4, text.length);
    final edit = ProtoWriter()
      ..int32(1, 1)
      ..message(2, status);
    final batch = ProtoWriter()
      ..int32(1, imeCounter)
      ..int32(2, fieldCounter)
      ..message(3, edit);
    return ProtoWriter.frameVarint((ProtoWriter()..message(21, batch)).toBytes());
  }

  static Uint8List appLink(String link) =>
      ProtoWriter.frameVarint((ProtoWriter()..message(90, ProtoWriter()..string(1, link))).toBytes());

  static const directionStartLong = 1;
  static const directionEndLong = 2;
  static const directionShort = 3;
}

/// Controlador Google TV / Android TV (Android TV Remote v2, porta 6466).
class AndroidTvController extends BaseRemoteController {
  AndroidTvController(super.device, this.identity, this.trust, {RemoteController? cast})
    // ignore: prefer_initializing_formals
    : _cast = cast;

  /// Identidade emparelhada; `null` enquanto o aparelho não foi emparelhado.
  final ClientIdentity? identity;
  final TlsTrust trust;

  /// Controlador Cast do mesmo aparelho (porta 8009): volume quando
  /// [RemoteDevice.volumeViaCast] está ativo e consulta de apps instalados.
  final RemoteController? _cast;
  RemoteController? get _volumeFallback => device.volumeViaCast ? _cast : null;

  static const _volumeKeys = {RemoteKey.volumeUp, RemoteKey.volumeDown, RemoteKey.mute};

  SecureSocket? _socket;
  final _buffer = <int>[];

  /// Estado do campo de texto em foco na TV (anunciado pela própria TV).
  int? _imeCounter;
  int? _fieldCounter;
  String _fieldValue = '';
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
    return _awaitService(timeout);
  }

  /// Acorda o aparelho em repouso pela porta de repouso (receptor Cast), como
  /// o app Google Home, e aguarda o serviço de controle subir. Ao conectar,
  /// envia HOME para sair da tela do receptor. Retorna verdadeiro se ligou.
  Future<bool> wakeFromStandby({Duration timeout = const Duration(seconds: 20)}) async {
    final source = _cast;
    if (source is! WakeSource) return false;
    try {
      await (source as WakeSource).wakeUp();
    } on RemoteException catch (e) {
      log('wake via Cast falhou: ${e.message}');
      return false;
    }
    final ok = await _awaitService(timeout);
    if (ok) {
      _socket?.add(RemoteMessages.keyInject(androidTvKeyCodes[RemoteKey.home]!, RemoteMessages.directionShort));
      log('acordou via Cast; HOME enviado');
    }
    await _cast?.disconnect();
    return ok;
  }

  Future<bool> _awaitService(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline) && !_disposed) {
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

  /// Tentativas de handshake antes de concluir que a TV não reconhece o
  /// cliente. A TV também fecha o socket durante a conexão por motivos
  /// transitórios (acordando, Wi-Fi recém-trocado, sessão anterior ainda
  /// viva); um único fechamento não pode virar pedido de emparelhamento.
  static const connectAttempts = 2;
  static const _retryDelay = Duration(milliseconds: 600);

  @override
  Future<void> connect() async {
    if (currentState == DeviceConnectionState.connected) return;
    if (_ready != null && !_ready!.isCompleted) return _ready!.future;
    final id = identity;
    if (id == null) {
      _ready = Completer<void>();
      setState(DeviceConnectionState.needsPairing);
      const err = PairingException('Dispositivo precisa ser emparelhado');
      _completeReadyError(err);
      throw err;
    }
    for (var attempt = 1; ; attempt++) {
      try {
        await _attemptConnect(id);
        return;
      } on PairingException {
        if (attempt >= connectAttempts || _disposed) rethrow;
        log('TV recusou a sessão (tentativa $attempt/$connectAttempts); repetindo antes de pedir emparelhamento');
        await Future<void>.delayed(_retryDelay);
      }
    }
  }

  Future<void> _attemptConnect(ClientIdentity id) async {
    _ready = Completer<void>();
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
      // Eventos de um socket antigo (ex.: fechado pela TV após remote_error)
      // não podem derrubar a conexão nova que o substituiu.
      socket.listen(
        _onData,
        onError: (Object e) {
          if (identical(socket, _socket)) _onError(e);
        },
        onDone: () {
          if (identical(socket, _socket)) _onDone();
        },
        cancelOnError: true,
      );
      _armWatchdog();
      await _ready!.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw const ConnectionException('A TV não concluiu o handshake');
        },
      );
    } on HandshakeException {
      // TLS recusado: ou quem responde não é a TV cadastrada (pin divergente)
      // ou a TV não reconhece o nosso certificado (reemparelhar).
      final err = TlsTrust.describeHandshakeFailure(pinMismatch: trust.pinMismatch);
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
    } else if (msg.containsKey(20)) {
      // RemoteImeKeyInject: campo de texto ganhou foco.
      final inject = msg[20]!.asMessage.readAll();
      final appInfo = inject[1]?.asMessage.readAll();
      final status = inject[2]?.asMessage.readAll();
      log(
        'ime_key_inject campos=${inject.keys.toList()} app_info=${appInfo?.keys.toList()} status=${status?.keys.toList()}',
      );
      _imeCounter = appInfo?[1]?.asInt ?? _imeCounter;
      _fieldCounter = status?[1]?.asInt ?? _fieldCounter;
      _fieldValue = status?[2]?.asString ?? '';
      log('campo de texto em foco (ime=$_imeCounter campo=$_fieldCounter, ${_fieldValue.length} chars)');
    } else if (msg.containsKey(21)) {
      final batch = msg[21]!.asMessage.readAll();
      _imeCounter = batch[1]?.asInt ?? _imeCounter;
      _fieldCounter = batch[2]?.asInt ?? _fieldCounter;
      final status = batch[3]?.asMessage.readAll()[2]?.asMessage.readAll();
      if (status != null) _fieldValue = status[2]?.asString ?? _fieldValue;
      log('campo de texto atualizado (ime=$_imeCounter campo=$_fieldCounter)');
    } else if (msg.containsKey(22)) {
      final status = msg[22]!.asMessage.readAll()[1]?.asMessage.readAll();
      _fieldCounter = status?[1]?.asInt ?? _fieldCounter;
      log('TV pediu teclado (campo=$_fieldCounter)');
    } else if (msg.containsKey(3)) {
      final err = msg[3]!.asMessage.readAll();
      final value = err[1]?.asInt;
      // Códigos observados: 7 = app link inválido/não tratado (a TV fecha a
      // conexão logo depois; o launchApp reconecta e tenta a alternativa).
      log('remote_error value=$value${value == 7 ? ' (app link recusado)' : ''}');
      final waiter = _launchError;
      if (waiter != null && !waiter.isCompleted) waiter.complete();
    }
  }

  void _onError(Object e) {
    log('erro de socket: $e');
    // Durante a conexão, uma falha TLS (HandshakeException ou o alerta
    // CERTIFICATE_UNKNOWN, que chega como TlsException) é a TV recusando o
    // nosso certificado: cliente não reconhecido. Falha TLS com a sessão já
    // estabelecida (rede trocada, socket morto) é queda comum.
    final rejected = e is TlsException && currentState == DeviceConnectionState.connecting;
    _teardown(rejected ? DeviceConnectionState.needsPairing : DeviceConnectionState.error);
    _completeReadyError(
      rejected
          ? const PairingException('Dispositivo precisa ser emparelhado novamente')
          : ConnectionException(e.toString()),
    );
  }

  void _onDone() {
    log('TV encerrou a conexão (estado ${currentState.name})');
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
    _imeCounter = null;
    _fieldCounter = null;
    _fieldValue = '';
    _launchError = null;
    setState(next);
  }

  @override
  Future<void> disconnect() async {
    _teardown(DeviceConnectionState.disconnected);
    await _cast?.disconnect();
  }

  /// O protocolo Android TV Remote não lista apps; a verificação vem do canal
  /// Cast do mesmo aparelho. Apps sem id Cast não são verificáveis e ficam.
  @override
  Future<Set<AppShortcut>?> installedApps(List<AppShortcut> apps) async {
    final cast = _cast;
    if (cast == null) return null;
    final verifiable = apps.where((a) => a.ids['cast'] != null).toList();
    try {
      final ok = await cast.installedApps(verifiable);
      if (ok == null) return null;
      return {...ok, ...apps.where((a) => a.ids['cast'] == null)};
    } on RemoteException catch (e) {
      log('verificação de apps via Cast falhou: ${e.message}');
      return null;
    }
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
        // Cascata: porta de repouso (Cast) → Wake-on-LAN (com MAC) → aviso.
        // Acordou: não enviar Power (desligaria de novo).
        if (await wakeFromStandby()) return;
        if (device.macAddress != null) {
          if (await wake()) return;
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
    log(
      'key_inject ${key.name} (code=$code, ${switch (dir) {
        RemoteMessages.directionShort => 'curto',
        RemoteMessages.directionStartLong => 'longo início',
        _ => 'longo fim',
      }})',
    );
  }

  @override
  Future<void> sendText(String text) async {
    await ensureConnected();
    final ime = _imeCounter;
    final field = _fieldCounter;
    if (ime != null && field != null) {
      // Canal IME: acrescenta ao conteúdo atual do campo em foco.
      final value = '$_fieldValue$text';
      _socket!.add(RemoteMessages.imeBatchEdit(imeCounter: ime, fieldCounter: field, text: value));
      _fieldValue = value;
      log('texto via IME (${text.length} chars)');
      return;
    }
    log('nenhum campo de texto em foco; enviando ${text.length} caractere(s) como teclas');
    var skipped = 0;
    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      final code = androidTvKeyCodeForChar(ch);
      if (code == null) {
        skipped++;
        continue;
      }
      _socket!.add(RemoteMessages.keyInject(code, RemoteMessages.directionShort));
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    if (skipped > 0) log('$skipped caractere(s) sem tecla equivalente (acentos/símbolos) ignorados');
  }

  /// Tecla a tecla, como o teclado numérico: `KEYCODE_A`…`Z`, dígitos e símbolos.
  @override
  Future<void> sendChar(String ch) async {
    final code = androidTvKeyCodeForChar(ch);
    if (code == null) throw ProtocolException('Sem tecla para "$ch"');
    await ensureConnected();
    _socket!.add(RemoteMessages.keyInject(code, RemoteMessages.directionShort));
    log('key_inject "$ch" (code=$code)');
  }

  Completer<void>? _launchError;

  /// Abre o app pelo primeiro link aceito pela TV. A cada `remote_error` a
  /// TV também derruba a conexão, então cada tentativa reconecta antes.
  @override
  Future<void> launchApp(AppShortcut app) async {
    final spec = app.ids[device.protocol.name];
    if (spec == null) throw UnsupportedError('App sem deep link para Android TV');
    final candidates = spec.split(RegExp(r'\s+')).where((c) => c.isNotEmpty).toList();
    for (final (i, link) in candidates.indexed) {
      await ensureConnected();
      final waiter = _launchError = Completer<void>();
      _socket!.add(RemoteMessages.appLink(link));
      log('launch ${app.id}: app_link $link (${i + 1}/${candidates.length})');
      final rejected = await waiter.future
          .then((_) => true)
          .timeout(const Duration(milliseconds: 1500), onTimeout: () => false);
      if (!rejected) {
        log('launch ${app.id}: aceito');
        return;
      }
      // A TV derruba a sessão logo após o remote_error: encerra já e
      // reconecta antes do próximo candidato (ou para restabelecer o controle).
      _teardown(DeviceConnectionState.disconnected);
    }
    // Restabelece a sessão derrubada pelo último erro e avisa a UI.
    try {
      await ensureConnected();
    } on RemoteException catch (e) {
      log('launch ${app.id}: reconexão após recusa falhou: ${e.message}');
    }
    throw ProtocolException('A TV recusou abrir ${app.label}');
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _teardown(DeviceConnectionState.disconnected);
    final f = _cast;
    if (f is BaseRemoteController) f.dispose();
    super.dispose();
  }
}
