import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../../domain/entities/app_shortcut.dart';
import '../../../domain/entities/connection_state.dart';
import '../../../domain/entities/remote_key.dart';
import '../../../domain/errors.dart';
import '../../../domain/ports/remote_controller.dart';
import '../../../domain/ports/voice_source.dart';
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

  /// Busca por voz: a TV abre a escuta após `KEYCODE_SEARCH` e envia
  /// `RemoteVoiceBegin{session_id}` (30); o controle responde com o mesmo
  /// begin, transmite `RemoteVoicePayload{session_id, samples}` (31) em blocos
  /// de [voiceChunkBytes] de PCM16 mono 8 kHz e encerra com
  /// `RemoteVoiceEnd{session_id}` (32).
  static Uint8List voiceBegin(int sessionId) =>
      ProtoWriter.frameVarint((ProtoWriter()..message(30, ProtoWriter()..int32(1, sessionId))).toBytes());

  static Uint8List voicePayload(int sessionId, List<int> samples) => ProtoWriter.frameVarint(
    (ProtoWriter()..message(
          31,
          ProtoWriter()
            ..int32(1, sessionId)
            ..bytes(2, samples),
        ))
        .toBytes(),
  );

  static Uint8List voiceEnd(int sessionId) =>
      ProtoWriter.frameVarint((ProtoWriter()..message(32, ProtoWriter()..int32(1, sessionId))).toBytes());

  /// Blocos menores (8 KiB) são ignorados por algumas TVs (ex.: TCL); 20 KiB
  /// é o tamanho usado pelo app oficial.
  static const voiceChunkBytes = 20 * 1024;

  static const directionStartLong = 1;
  static const directionEndLong = 2;
  static const directionShort = 3;
}

/// Controlador Google TV / Android TV (Android TV Remote v2, porta 6466).
class AndroidTvController extends BaseRemoteController {
  AndroidTvController(
    super.device,
    this.identity,
    this.trust, {
    RemoteController? cast,
    WakeSource? bluetooth,
    this.retryDelays = defaultRetryDelays,
    this.fallbackIdentity,
    VoiceSource? voice,
  }) : _voice = voice, // ignore: prefer_initializing_formals
       _cast = cast, // ignore: prefer_initializing_formals
       _bluetooth = bluetooth; // ignore: prefer_initializing_formals

  /// Despertar pelo Bluetooth (celular pareado à TV como teclado HID).
  final WakeSource? _bluetooth;

  /// Identidade emparelhada; `null` enquanto o aparelho não foi emparelhado.
  ClientIdentity? identity;
  final TlsTrust trust;

  /// Identidade única do app. Quando a TV recusa a identidade gravada neste
  /// cadastro (ex.: cadastro antigo com identidade própria, ou outro cadastro
  /// da mesma TV emparelhado com a identidade do app), tenta-se esta antes
  /// de pedir emparelhamento; se funcionar, [onIdentityUpgraded] é chamado
  /// para o serviço regravar as credenciais.
  final ClientIdentity? fallbackIdentity;
  void Function(ClientIdentity)? onIdentityUpgraded;

  /// Microfone para busca por voz; `null` desabilita a capacidade.
  final VoiceSource? _voice;
  int? _voiceSession;
  Completer<int>? _voiceBegin;
  // Cancelada em stopVoice()/_teardown().
  // ignore: cancel_subscriptions
  StreamSubscription<Uint8List>? _voiceSub;
  final _voiceBuffer = <int>[];
  Timer? _voiceTimer;
  bool _listening = false;
  final _listeningCtrl = StreamController<bool>.broadcast();

  /// Tempo máximo de escuta (a TV costuma encerrar antes, ao detectar silêncio).
  static const voiceMaxDuration = Duration(seconds: 15);

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
    if (device.macAddress != null || _bluetooth != null) RemoteCapability.wakeOnLan,
    if (_voice != null) RemoteCapability.voiceInput,
  };

  @override
  bool get isListening => _listening;
  @override
  Stream<bool> get listeningChanges => _listeningCtrl.stream;

  void _setListening(bool v) {
    if (_listening == v) return;
    _listening = v;
    if (!_listeningCtrl.isClosed) _listeningCtrl.add(v);
  }

  /// Abre a busca por voz na TV e transmite o microfone.
  @override
  Future<void> startVoice() async {
    final voice = _voice;
    if (voice == null) throw UnsupportedError('startVoice');
    if (_listening) return;
    if (!await voice.requestPermission()) {
      throw const ConnectionException('Permissão de microfone negada. Libere em Ajustes para usar a busca por voz.');
    }
    await ensureConnected();
    _voiceBegin = Completer<int>();
    _socket!.add(RemoteMessages.keyInject(androidTvKeyCodes[RemoteKey.assistant]!, RemoteMessages.directionShort));
    log('voz: KEYCODE_SEARCH enviado; aguardando RemoteVoiceBegin');
    final int session;
    try {
      session = await _voiceBegin!.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _voiceBegin = null;
      throw const ProtocolException('A TV não abriu a busca por voz. Confira se o Assistente está ativo nela.');
    }
    _voiceSession = session;
    _socket?.add(RemoteMessages.voiceBegin(session));
    final stream = await voice.start();
    _voiceBuffer.clear();
    _setListening(true);
    log('voz: sessão $session, transmitindo');
    _voiceSub = stream.listen(
      (pcm) {
        _voiceBuffer.addAll(pcm);
        while (_voiceBuffer.length >= RemoteMessages.voiceChunkBytes) {
          final chunk = _voiceBuffer.sublist(0, RemoteMessages.voiceChunkBytes);
          _voiceBuffer.removeRange(0, RemoteMessages.voiceChunkBytes);
          _socket?.add(RemoteMessages.voicePayload(session, chunk));
        }
      },
      onError: (Object e) {
        log('voz: erro de captura $e');
        unawaited(stopVoice());
      },
      onDone: () => unawaited(stopVoice()),
    );
    _voiceTimer = Timer(voiceMaxDuration, () {
      log('voz: tempo máximo; encerrando');
      unawaited(stopVoice());
    });
  }

  /// Encerra a transmissão: envia o resto preenchido com silêncio e o fim.
  @override
  Future<void> stopVoice() async {
    final session = _voiceSession;
    final sub = _voiceSub;
    _voiceSub = null;
    _voiceTimer?.cancel();
    _voiceTimer = null;
    await sub?.cancel();
    await _voice?.stop();
    if (session != null) {
      if (_voiceBuffer.isNotEmpty) {
        final padded = List<int>.filled(RemoteMessages.voiceChunkBytes, 0)
          ..setRange(0, _voiceBuffer.length, _voiceBuffer);
        _voiceBuffer.clear();
        _socket?.add(RemoteMessages.voicePayload(session, padded));
      }
      _socket?.add(RemoteMessages.voiceEnd(session));
      log('voz: sessão $session encerrada');
    }
    _voiceSession = null;
    _voiceBegin = null;
    _setListening(false);
  }

  /// Acorda o aparelho por Wake-on-LAN e aguarda o serviço remoto responder.
  /// Retorna verdadeiro se conseguiu conectar após o pacote mágico.
  Future<bool> wake({Duration timeout = const Duration(seconds: 15)}) async {
    final mac = device.macAddress;
    if (mac == null) return false;
    log('enviando Wake-on-LAN');
    await const WakeOnLan().wake(mac, host: device.host);
    return _awaitService(timeout);
  }

  /// Acorda o aparelho em repouso disparando, em sequência, todos os canais
  /// disponíveis e aguardando o serviço de controle subir uma única vez:
  ///
  /// 1. Wake-on-LAN (se há MAC) — UDP, sem espera;
  /// 2. porta de repouso (receptor Cast), como o app Google Home — funciona
  ///    com "standby em rede" ativo na TV;
  /// 3. Bluetooth HID (se o celular foi pareado à TV) — funciona mesmo com o
  ///    Wi-Fi da TV desligado em repouso, como o controle físico.
  ///
  /// Ao conectar, envia HOME para sair da tela do receptor. Retorna
  /// verdadeiro se ligou.
  Future<bool> wakeFromStandby({Duration timeout = const Duration(seconds: 20)}) async {
    var fired = false;
    final mac = device.macAddress;
    if (mac != null) {
      try {
        await const WakeOnLan().wake(mac, host: device.host);
        log('wake: Wake-on-LAN enviado');
        fired = true;
      } catch (e) {
        log('wake: Wake-on-LAN falhou: $e');
      }
    }
    final cast = _cast;
    if (cast is WakeSource) {
      try {
        await (cast as WakeSource).wakeUp();
        fired = true;
      } on RemoteException catch (e) {
        log('wake via Cast falhou: ${e.message}');
      }
    }
    final bt = _bluetooth;
    if (bt != null) {
      try {
        await bt.wakeUp();
        log('wake: Power enviado por Bluetooth');
        fired = true;
      } on RemoteException catch (e) {
        log('wake via Bluetooth falhou: ${e.message}');
      } catch (e) {
        log('wake via Bluetooth falhou: $e');
      }
    }
    if (!fired) return false;
    final ok = await _awaitService(timeout);
    if (ok) {
      _socket?.add(RemoteMessages.keyInject(androidTvKeyCodes[RemoteKey.home]!, RemoteMessages.directionShort));
      log('acordou; HOME enviado');
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

  /// Esperas entre tentativas quando a TV fecha a conexão durante a abertura
  /// (acordando, Wi-Fi recém-trocado, sessão anterior ainda viva). Janela
  /// total ≈ 5 s; sobrescrevível nos testes.
  final List<Duration> retryDelays;
  static const defaultRetryDelays = [Duration(milliseconds: 600), Duration(milliseconds: 1500), Duration(seconds: 3)];

  /// Compatibilidade: tentativas de conexão (= esperas + 1).
  int get connectAttempts => retryDelays.length + 1;

  /// A sessão já foi estabelecida alguma vez com o emparelhamento atual
  /// (nesta execução ou, via [RemoteDevice.lastConnectedAt], em outra).
  bool _everConnected = false;
  bool get everConnected => _everConnected || device.everConnected;

  /// Chamado quando a sessão é estabelecida pela primeira vez na execução.
  void Function()? onFirstConnected;

  /// A TV recusou o nosso certificado? Só a **evidência TLS** conta — alerta
  /// (`CERTIFICATE_UNKNOWN`, `UNKNOWN_CA`, `BAD_CERTIFICATE`…) durante a
  /// abertura. É o mesmo critério da implementação de referência
  /// (androidtvremote2: `ssl.SSLError` → *InvalidAuth*; conexão fechada →
  /// *ConnectionClosed*). Um `HandshakeException` por conexão encerrada no
  /// meio do handshake é queda, não recusa.
  static bool isTlsRejection(Object e) {
    if (e is! TlsException) return false;
    final msg = e.toString();
    if (RegExp(r'terminated|closed|reset|broken pipe|timed out|EOF', caseSensitive: false).hasMatch(msg)) {
      return false;
    }
    return RegExp(r'ALERT|CERTIFICATE|UNKNOWN_CA|certificate', caseSensitive: false).hasMatch(msg);
  }

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
    var rejections = 0;
    var current = id;
    var triedFallback = false;
    for (var attempt = 1; ; attempt++) {
      try {
        await _attemptConnect(current);
        if (!current.sameAs(identity)) {
          identity = current;
          log('TV aceitou a identidade do app (${current.shortFingerprint}); credenciais do cadastro atualizadas');
          onIdentityUpgraded?.call(current);
        }
        if (!_everConnected) {
          _everConnected = true;
          onFirstConnected?.call();
        }
        return;
      } on PairingException {
        if (_disposed) rethrow;
        // Evidência TLS de recusa: confirma uma segunda vez antes de pedir
        // emparelhamento — um alerta isolado já foi visto com a TV acordando.
        if (++rejections < 2) {
          log('TV recusou o certificado ${current.shortFingerprint} (alerta TLS); confirmando');
          await Future<void>.delayed(const Duration(milliseconds: 1500));
          continue;
        }
        final fb = fallbackIdentity;
        if (!triedFallback && fb != null && !fb.sameAs(current)) {
          triedFallback = true;
          rejections = 0;
          current = fb;
          log('recusa confirmada; tentando a identidade do app (${fb.shortFingerprint})');
          continue;
        }
        log('recusa confirmada para ${current.shortFingerprint}: emparelhamento necessário');
        rethrow;
      } on ClosedDuringConnectException catch (e) {
        if (_disposed) rethrow;
        if (attempt <= retryDelays.length) {
          log('TV fechou a conexão na abertura (tentativa $attempt/$connectAttempts); repetindo');
          await Future<void>.delayed(retryDelays[attempt - 1]);
          continue;
        }
        if (!everConnected) {
          // Nunca houve sessão com este emparelhamento: a TV que fecha
          // sempre, sem alerta, é a que não reconhece o cliente (primeiro
          // uso). Com histórico de sucesso, isso é falha transitória.
          log('fechamento persistente sem histórico de sessão: pedindo emparelhamento');
          _teardown(DeviceConnectionState.needsPairing);
          const err = PairingException('Dispositivo precisa ser emparelhado');
          _completeReadyError(err);
          throw err;
        }
        log('fechamento persistente com emparelhamento já comprovado: erro de conexão, não reemparelhar');
        throw ConnectionException(
          '${e.message} Se continuar assim com a TV ligada, use "Emparelhar novamente" no menu.',
        );
      }
    }
  }

  Future<void> _attemptConnect(ClientIdentity id) async {
    _ready = Completer<void>();
    setState(DeviceConnectionState.connecting);
    log('conectando com identidade ${id.shortFingerprint}');
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
    } on HandshakeException catch (e) {
      // TLS recusado: ou quem responde não é a TV cadastrada (pin divergente),
      // ou a TV não reconhece o nosso certificado (alerta → reemparelhar), ou a
      // conexão caiu no meio do handshake (transitório).
      final RemoteException err;
      if (trust.pinMismatch) {
        err = TlsTrust.describeHandshakeFailure(pinMismatch: true);
      } else if (isTlsRejection(e)) {
        err = TlsTrust.describeHandshakeFailure(pinMismatch: false);
      } else {
        err = const ClosedDuringConnectException('A conexão caiu durante o handshake TLS.');
      }
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
    } else if (msg.containsKey(30)) {
      final begin = msg[30]!.asMessage.readAll();
      final session = begin[1]?.asInt ?? 0;
      log('voz: TV abriu a escuta (sessão $session${begin[2] != null ? ', ${begin[2]!.asString}' : ''})');
      final waiter = _voiceBegin;
      if (waiter != null && !waiter.isCompleted) waiter.complete(session);
    } else if (msg.containsKey(32)) {
      log('voz: TV encerrou a escuta');
      if (_listening) {
        // A TV já concluiu: só para a captura, sem reenviar o fim.
        _voiceSession = null;
        unawaited(stopVoice());
      }
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
    final connecting = currentState == DeviceConnectionState.connecting;
    final rejected = connecting && isTlsRejection(e);
    _teardown(rejected ? DeviceConnectionState.needsPairing : DeviceConnectionState.error);
    _completeReadyError(
      rejected
          ? const PairingException('Dispositivo precisa ser emparelhado novamente')
          : connecting
          ? ClosedDuringConnectException('A conexão caiu durante a abertura: $e')
          : ConnectionException(e.toString()),
    );
  }

  void _onDone() {
    log('TV encerrou a conexão (estado ${currentState.name})');
    if (currentState == DeviceConnectionState.connecting) {
      // Fechamento sem alerta TLS: a TV faz isso ao acordar, ao trocar de
      // rede ou com a sessão anterior viva. Não é recusa do cliente — a
      // recusa vem como alerta TLS (ver isTlsRejection). O connect() decide
      // entre repetir, erro ou (sem histórico) emparelhar.
      _teardown(DeviceConnectionState.error);
      _completeReadyError(const ClosedDuringConnectException('A TV fechou a conexão durante a abertura.'));
    } else {
      _teardown(DeviceConnectionState.disconnected);
    }
  }

  void _teardown(DeviceConnectionState next) {
    _watchdog?.cancel();
    _watchdog = null;
    if (_listening || _voiceSub != null) {
      _voiceSession = null;
      unawaited(stopVoice());
    }
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
    if (press == KeyPress.short && (key.isLetter || key == RemoteKey.space || key == RemoteKey.backspace)) {
      // Letras no painel ABC: com um campo de texto em foco, a TV ignora o
      // key_inject de KEYCODE_A…Z em vários apps (o teclado virtual dela é
      // quem consome o campo), mas aceita a edição pelo canal IME — o mesmo
      // que o Google Home usa. Sem campo em foco, cai para a tecla.
      await ensureConnected();
      if (_editFocusedField(key)) return;
    }
    if (key == RemoteKey.power && currentState != DeviceConnectionState.connected) {
      // Em "standby em rede" o serviço responde e a tecla Power liga o aparelho.
      // Se o Wi-Fi está desligado em repouso, só Wake-on-LAN (com MAC) acorda.
      try {
        await ensureConnected();
      } on RemoteException {
        // Cascata Wake-on-LAN → Cast → Bluetooth. Acordou: não enviar Power
        // (desligaria de novo).
        if (await wakeFromStandby()) return;
        throw ConnectionException(
          _bluetooth != null || device.macAddress != null
              ? 'A TV não acordou. Confira se ela está ligada na tomada e, se o problema persistir, '
                    'ative "Standby em rede" nas configurações de energia dela.'
              : 'A TV está em repouso com o Wi-Fi desligado. Para ligá-la pelo celular: ative "Standby em rede" '
                    'nas configurações de energia da TV, ou vincule o celular por Bluetooth em Meus dispositivos '
                    '(Android), ou informe o MAC para Wake-on-LAN.',
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

  /// Aplica uma letra, espaço ou apagar ao campo em foco pelo canal IME.
  /// Devolve `false` quando não há campo em foco (usar tecla).
  bool _editFocusedField(RemoteKey key) {
    final ime = _imeCounter;
    final field = _fieldCounter;
    if (ime == null || field == null) return false;
    final String value;
    if (key == RemoteKey.backspace) {
      if (_fieldValue.isEmpty) return false;
      value = _fieldValue.substring(0, _fieldValue.length - 1);
    } else {
      value = '$_fieldValue${key.char}';
    }
    _socket!.add(RemoteMessages.imeBatchEdit(imeCounter: ime, fieldCounter: field, text: value));
    _fieldValue = value;
    log('${key.name} via IME (campo com ${value.length} chars)');
    return true;
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
    _listeningCtrl.close();
    final f = _cast;
    if (f is BaseRemoteController) f.dispose();
    super.dispose();
  }
}
