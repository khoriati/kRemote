import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../domain/entities/app_shortcut.dart';
import '../../../domain/entities/connection_state.dart';
import '../../../domain/entities/remote_device.dart';
import '../../../domain/entities/remote_key.dart';
import '../../../domain/errors.dart';
import '../../../domain/ports/pairing_flow.dart';
import '../../net/tls_trust.dart';
import '../../net/wake_on_lan.dart';
import '../base_controller.dart';

/// Teclas do protocolo Samsung Tizen (`samsung.remote.control`).
const samsungKeys = <RemoteKey, String>{
  RemoteKey.power: 'KEY_POWER',
  RemoteKey.input: 'KEY_SOURCE',
  RemoteKey.assistant: 'KEY_BIXBY',
  RemoteKey.back: 'KEY_RETURN',
  RemoteKey.home: 'KEY_HOME',
  RemoteKey.up: 'KEY_UP',
  RemoteKey.down: 'KEY_DOWN',
  RemoteKey.left: 'KEY_LEFT',
  RemoteKey.right: 'KEY_RIGHT',
  RemoteKey.ok: 'KEY_ENTER',
  RemoteKey.volumeUp: 'KEY_VOLUP',
  RemoteKey.volumeDown: 'KEY_VOLDOWN',
  RemoteKey.mute: 'KEY_MUTE',
  RemoteKey.playPause: 'KEY_PLAY_BACK',
  RemoteKey.play: 'KEY_PLAY',
  RemoteKey.pause: 'KEY_PAUSE',
  RemoteKey.stop: 'KEY_STOP',
  RemoteKey.rewind: 'KEY_REWIND',
  RemoteKey.fastForward: 'KEY_FF',
  RemoteKey.record: 'KEY_REC',
  RemoteKey.channelUp: 'KEY_CHUP',
  RemoteKey.channelDown: 'KEY_CHDOWN',
  RemoteKey.menu: 'KEY_MENU',
  RemoteKey.info: 'KEY_INFO',
  RemoteKey.guide: 'KEY_GUIDE',
  RemoteKey.settings: 'KEY_TOOLS',
  RemoteKey.exit: 'KEY_EXIT',
  RemoteKey.captions: 'KEY_CAPTION',
  RemoteKey.num0: 'KEY_0',
  RemoteKey.num1: 'KEY_1',
  RemoteKey.num2: 'KEY_2',
  RemoteKey.num3: 'KEY_3',
  RemoteKey.num4: 'KEY_4',
  RemoteKey.num5: 'KEY_5',
  RemoteKey.num6: 'KEY_6',
  RemoteKey.num7: 'KEY_7',
  RemoteKey.num8: 'KEY_8',
  RemoteKey.num9: 'KEY_9',
  RemoteKey.dash: 'KEY_MINUS',
  RemoteKey.enter: 'KEY_ENTER',
  RemoteKey.red: 'KEY_RED',
  RemoteKey.green: 'KEY_GREEN',
  RemoteKey.yellow: 'KEY_YELLOW',
  RemoteKey.blue: 'KEY_CYAN',
};

String _samsungUrl(RemoteDevice d, String? token) {
  final name = base64.encode(utf8.encode('kRemote'));
  final t = token == null ? '' : '&token=$token';
  // Tizen 2016–2017 (sem TokenAuthSupport) só atende em ws:// na 8001.
  final scheme = d.port == 8001 ? 'ws' : 'wss';
  return '$scheme://${d.host}:${d.port}/api/v2/channels/samsung.remote.control?name=$name$t';
}

/// Emparelhamento Samsung: a TV pede permissão na tela e devolve um token.
class SamsungPairingFlow implements PairingFlow {
  SamsungPairingFlow(this.device, this.trust);
  final RemoteDevice device;
  final TlsTrust trust;
  final _state = StreamController<PairingState>.broadcast();
  WebSocket? _ws;
  Map<String, String>? _credentials;

  @override
  Stream<PairingState> get state => _state.stream;
  @override
  Map<String, String>? get credentials => _credentials;

  void _emit(PairingStage s, [String? m]) {
    if (!_state.isClosed) _state.add(PairingState(s, message: m));
  }

  @override
  Future<void> start() async {
    _emit(PairingStage.connecting, 'Conectando à TV…');
    try {
      await trust.load();
      _ws = await WebSocket.connect(
        _samsungUrl(device, null),
        customClient: trust.httpClient(),
      ).timeout(const Duration(seconds: 8));
      await trust.commit();
      _emit(PairingStage.awaitingTvConfirmation, 'Aceite a permissão exibida na TV');
      _ws!.listen(
        (data) {
          final msg = jsonDecode(data as String) as Map<String, dynamic>;
          if (msg['event'] == 'ms.channel.connect') {
            final token = (msg['data'] as Map<String, dynamic>?)?['token']?.toString();
            if (token != null && token.isNotEmpty) {
              _credentials = {'token': token};
              _emit(PairingStage.success, 'TV autorizada');
            } else {
              _emit(PairingStage.failure, 'A TV não devolveu token (modelo antigo? use porta 8001)');
            }
            _ws?.close();
          } else if (msg['event'] == 'ms.channel.unauthorized') {
            _emit(PairingStage.failure, 'Permissão negada na TV');
            _ws?.close();
          }
        },
        onError: (Object e) => _emit(PairingStage.failure, 'Erro: $e'),
        onDone: () {
          if (_credentials == null) _emit(PairingStage.failure, 'Conexão encerrada sem autorização');
        },
      );
    } on HandshakeException {
      _emit(PairingStage.failure, TlsTrust.describeHandshakeFailure(pinMismatch: trust.pinMismatch).message);
    } catch (e) {
      _emit(PairingStage.failure, 'Não foi possível conectar: $e');
    }
  }

  @override
  Future<void> submit(String value) async {}

  @override
  Future<void> cancel() async {
    await _ws?.close();
    await _state.close();
  }
}

/// Controlador Samsung Tizen (WebSocket seguro na porta 8002).
class SamsungController extends BaseRemoteController {
  SamsungController(super.device, this.token, this.trust);
  final String? token;
  final TlsTrust trust;
  WebSocket? _ws;
  Completer<void>? _ready;

  @override
  Set<RemoteKey> get supportedKeys => samsungKeys.keys.toSet();
  @override
  Set<RemoteCapability> get capabilities => {
    RemoteCapability.textInput,
    RemoteCapability.appLaunch,
    if (device.macAddress != null) RemoteCapability.wakeOnLan,
  };

  @override
  Future<void> connect() async {
    if (currentState == DeviceConnectionState.connected) return;
    if (_ready != null && !_ready!.isCompleted) return _ready!.future;
    _ready = Completer<void>();
    setState(DeviceConnectionState.connecting);
    try {
      await trust.load();
      _ws = await WebSocket.connect(
        _samsungUrl(device, token),
        customClient: trust.httpClient(),
      ).timeout(const Duration(seconds: 8));
      await trust.commit();
      _ws!.listen(
        (data) {
          final msg = jsonDecode(data as String) as Map<String, dynamic>;
          if (msg['event'] == 'ms.channel.connect') {
            setState(DeviceConnectionState.connected);
            if (!_ready!.isCompleted) _ready!.complete();
          } else if (msg['event'] == 'ms.channel.unauthorized') {
            _teardown(DeviceConnectionState.needsPairing);
            _fail(const PairingException('TV não autorizou este controle'));
          }
        },
        onError: (Object e) => _teardown(DeviceConnectionState.error),
        onDone: () => _teardown(DeviceConnectionState.disconnected),
      );
      await _ready!.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw const ConnectionException('TV não confirmou a conexão');
        },
      );
    } on HandshakeException {
      _teardown(DeviceConnectionState.error);
      throw _fail(TlsTrust.describeHandshakeFailure(pinMismatch: trust.pinMismatch));
    } catch (e) {
      if (currentState != DeviceConnectionState.needsPairing) _teardown(DeviceConnectionState.error);
      throw _fail(e is RemoteException ? e : ConnectionException(e.toString()));
    }
  }

  RemoteException _fail(RemoteException e) {
    final r = _ready;
    if (r != null && !r.isCompleted) {
      r.future.ignore();
      r.completeError(e);
    }
    return e;
  }

  void _teardown(DeviceConnectionState s) {
    _ws?.close();
    _ws = null;
    setState(s);
  }

  @override
  Future<void> disconnect() async => _teardown(DeviceConnectionState.disconnected);

  void _sendJson(Map<String, dynamic> m) => _ws?.add(jsonEncode(m));

  @override
  Future<void> sendKey(RemoteKey key, {KeyPress press = KeyPress.short}) async {
    final code = samsungKeys[key] ?? unsupported(key);
    if (key == RemoteKey.power && currentState != DeviceConnectionState.connected && device.macAddress != null) {
      await const WakeOnLan().wake(device.macAddress!, host: device.host);
      return;
    }
    await ensureConnected();
    final cmd = switch (press) {
      KeyPress.short => 'Click',
      KeyPress.longStart => 'Press',
      KeyPress.longEnd => 'Release',
    };
    _sendJson({
      'method': 'ms.remote.control',
      'params': {'Cmd': cmd, 'DataOfCmd': code, 'Option': 'false', 'TypeOfRemote': 'SendRemoteKey'},
    });
  }

  @override
  Future<void> sendText(String text) async {
    await ensureConnected();
    _sendJson({
      'method': 'ms.remote.control',
      'params': {'Cmd': base64.encode(utf8.encode(text)), 'DataOfCmd': 'base64', 'TypeOfRemote': 'SendInputString'},
    });
    _sendJson({
      'method': 'ms.remote.control',
      'params': {'TypeOfRemote': 'SendInputEnd'},
    });
  }

  @override
  Future<void> launchApp(AppShortcut app) async {
    final id = app.ids[device.protocol.name];
    if (id == null) throw UnsupportedError('App sem id Samsung');
    await ensureConnected();
    _sendJson({
      'method': 'ms.channel.emit',
      'params': {
        'event': 'ed.apps.launch',
        'to': 'host',
        'data': {'appId': id, 'action_type': 'DEEP_LINK'},
      },
    });
  }

  @override
  void dispose() {
    _teardown(DeviceConnectionState.disconnected);
    super.dispose();
  }
}
