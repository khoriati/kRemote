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

/// Permissões solicitadas no registro SSAP (manifesto público do webOS).
const _lgPermissions = [
  'LAUNCH',
  'LAUNCH_WEBAPP',
  'APP_TO_APP',
  'CLOSE',
  'TEST_OPEN',
  'TEST_PROTECTED',
  'CONTROL_AUDIO',
  'CONTROL_DISPLAY',
  'CONTROL_INPUT_JOYSTICK',
  'CONTROL_INPUT_MEDIA_RECORDING',
  'CONTROL_INPUT_MEDIA_PLAYBACK',
  'CONTROL_INPUT_TV',
  'CONTROL_POWER',
  'READ_APP_STATUS',
  'READ_CURRENT_CHANNEL',
  'READ_INPUT_DEVICE_LIST',
  'READ_NETWORK_STATE',
  'READ_RUNNING_APPS',
  'READ_TV_CHANNEL_LIST',
  'WRITE_NOTIFICATION_TOAST',
  'READ_POWER_STATE',
  'READ_COUNTRY_INFO',
  'READ_SETTINGS',
  'CONTROL_TV_SCREEN',
  'CONTROL_TV_STANBY',
  'CONTROL_FAVORITE_GROUP',
  'CONTROL_USER_INFO',
  'CHECK_BLUETOOTH_DEVICE',
  'CONTROL_BLUETOOTH',
  'CONTROL_TIMER_INFO',
  'STB_INTERNAL_CONNECTION',
  'CONTROL_RECORDING',
  'READ_RECORDING_STATE',
  'WRITE_RECORDING_LIST',
  'READ_RECORDING_LIST',
  'READ_RECORDING_SCHEDULE',
  'WRITE_RECORDING_SCHEDULE',
  'READ_STORAGE_DEVICE_LIST',
  'READ_TV_PROGRAM_INFO',
  'CONTROL_BOX_CHANNEL',
  'READ_TV_ACR_AUTH_TOKEN',
  'READ_TV_CONTENT_STATE',
  'READ_TV_CURRENT_TIME',
  'ADD_LAUNCHER_CHANNEL',
  'SET_CHANNEL_SKIP',
  'RELEASE_CHANNEL_SKIP',
  'CONTROL_CHANNEL_BLOCK',
  'DELETE_SELECT_CHANNEL',
  'CONTROL_CHANNEL_GROUP',
  'SCAN_CHANNELS',
  'CONTROL_TV_POWER',
  'CONTROL_WOL',
];

/// Assinatura pública do manifesto de desenvolvimento da LG (`com.lge.test`),
/// exigida pelo webOS no registro. Não é um segredo: é um blob distribuído pela
/// própria LG e presente em todos os clientes SSAP de código aberto.
const _lgManifestSignature =
    'eyJhbGdvcml0aG0iOiJSU0EtU0hBMjU2Iiwia2V5SWQiOiJ0ZXN0LXNpZ25pbmctY2VydCIsInNpZ25hdHVyZVZlcnNpb24iOjF9.hrVRgjCwXVvE2OOSpDZ58hR+59aFNwYDyjQgKk3auukd7pcegmE2CzPCa0bJ0ZsRAcKkCTJrWo5iDzNhMBWRyaMOv5zWSrthlf7G128qvIlpMT0YNY+n/FaOHE73uLrS/g7swl3/qH/BGFG2Hu4RlL48eb3lLKqTt2xKHdCs6Cd4RMfJPYnzgvI4BNrFUKsjkcu+WD4OO2A27Pq1n50cMchmcaXadJhGrOqH5YmHdOCj5NSHzJYrsW0HPlpuAx/ECMeIZYDh6RMqaFM2DXzdKX9NmmyqzJ3o/0lkk/N97gfVRLW5hA29yeAwaCViZNCP8iC9aO0q9fQojoa7NQnAtw==';

Map<String, dynamic> _registerPayload(String? clientKey) => {
  'type': 'register',
  'id': 'register_0',
  'payload': {
    'forcePairing': false,
    'pairingType': 'PROMPT',
    'client-key': ?clientKey,
    'manifest': {
      'manifestVersion': 1,
      'appVersion': '1.1',
      'signed': {
        'created': '20140509',
        'appId': 'com.lge.test',
        'vendorId': 'com.lge',
        'localizedAppNames': {'': 'kRemote'},
        'localizedVendorNames': {'': 'LG Electronics'},
        'permissions': [
          'TEST_SECURE',
          'CONTROL_INPUT_TEXT',
          'CONTROL_MOUSE_AND_KEYBOARD',
          'READ_INSTALLED_APPS',
          'READ_LGE_SDX',
          'READ_NOTIFICATIONS',
          'SEARCH',
          'WRITE_SETTINGS',
          'WRITE_NOTIFICATION_ALERT',
          'CONTROL_POWER',
          'READ_CURRENT_CHANNEL',
          'READ_RUNNING_APPS',
          'READ_UPDATE_INFO',
          'UPDATE_FROM_REMOTE_APP',
          'READ_LGE_TV_INPUT_EVENTS',
          'READ_TV_CURRENT_TIME',
        ],
        'serial': '2f930e2d2cfe083771f68e4fe7bb07',
      },
      'permissions': _lgPermissions,
      'signatures': [
        {'signatureVersion': 1, 'signature': _lgManifestSignature},
      ],
    },
  },
};

/// Botões do socket de entrada por ponteiro (D-pad e afins).
const lgButtonNames = <RemoteKey, String>{
  RemoteKey.up: 'UP',
  RemoteKey.down: 'DOWN',
  RemoteKey.left: 'LEFT',
  RemoteKey.right: 'RIGHT',
  RemoteKey.ok: 'ENTER',
  RemoteKey.back: 'BACK',
  RemoteKey.home: 'HOME',
  RemoteKey.exit: 'EXIT',
  RemoteKey.menu: 'MENU',
  RemoteKey.info: 'INFO',
  RemoteKey.guide: 'GUIDE',
  RemoteKey.settings: 'QMENU',
  RemoteKey.captions: 'CC',
  RemoteKey.dash: 'DASH',
  RemoteKey.red: 'RED',
  RemoteKey.green: 'GREEN',
  RemoteKey.yellow: 'YELLOW',
  RemoteKey.blue: 'BLUE',
  RemoteKey.num0: '0',
  RemoteKey.num1: '1',
  RemoteKey.num2: '2',
  RemoteKey.num3: '3',
  RemoteKey.num4: '4',
  RemoteKey.num5: '5',
  RemoteKey.num6: '6',
  RemoteKey.num7: '7',
  RemoteKey.num8: '8',
  RemoteKey.num9: '9',
  RemoteKey.enter: 'ENTER',
  RemoteKey.backspace: 'BACK',
  RemoteKey.record: 'RECORD',
  RemoteKey.play: 'PLAY',
  RemoteKey.pause: 'PAUSE',
  RemoteKey.stop: 'STOP',
  RemoteKey.rewind: 'REWIND',
  RemoteKey.fastForward: 'FASTFORWARD',
  RemoteKey.channelUp: 'CHANNELUP',
  RemoteKey.channelDown: 'CHANNELDOWN',
  RemoteKey.volumeUp: 'VOLUMEUP',
  RemoteKey.volumeDown: 'VOLUMEDOWN',
  RemoteKey.mute: 'MUTE',
  RemoteKey.assistant: 'VOICE',
};

/// Comandos SSAP diretos.
const lgSsapUris = <RemoteKey, String>{
  RemoteKey.power: 'ssap://system/turnOff',
  RemoteKey.playPause: 'ssap://media.controls/play',
  RemoteKey.next: 'ssap://media.controls/fastForward',
  RemoteKey.previous: 'ssap://media.controls/rewind',
};

class _LgSession {
  _LgSession(this.device, this.trust);
  final RemoteDevice device;
  final TlsTrust trust;
  WebSocket? ws;
  WebSocket? pointer;
  var _id = 1;
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _events.stream;

  Future<void> open() async {
    final secure = device.port == 3001;
    final url = '${secure ? 'wss' : 'ws'}://${device.host}:${device.port}';
    if (secure) await trust.load();
    ws = await WebSocket.connect(
      url,
      customClient: secure ? trust.httpClient() : null,
    ).timeout(const Duration(seconds: 8));
    if (secure) await trust.commit();
    ws!.listen(
      (data) {
        final msg = jsonDecode(data as String) as Map<String, dynamic>;
        final id = msg['id']?.toString();
        if (!_events.isClosed) _events.add(msg);
        if (id != null && (msg['type'] == 'response' || msg['type'] == 'error') && _pending.containsKey(id)) {
          final payload = msg['payload'] as Map<String, dynamic>? ?? {};
          if (payload['pairingType'] == 'PROMPT') return;
          _pending.remove(id)!.complete(msg);
        }
      },
      onDone: () => _events.close(),
      onError: (Object e) => _events.addError(e),
    );
  }

  Future<Map<String, dynamic>> request(String uri, [Map<String, dynamic>? payload]) {
    final id = 'req_${_id++}';
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    ws!.add(jsonEncode({'type': 'request', 'id': id, 'uri': uri, 'payload': ?payload}));
    return c.future.timeout(
      const Duration(seconds: 6),
      onTimeout: () {
        _pending.remove(id);
        throw const ProtocolException('TV não respondeu ao comando');
      },
    );
  }

  void send(Map<String, dynamic> m) => ws!.add(jsonEncode(m));

  Future<void> ensurePointer() async {
    if (pointer != null) return;
    final res = await request('ssap://com.webos.service.networkinput/getPointerInputSocket');
    final path = (res['payload'] as Map<String, dynamic>?)?['socketPath'] as String?;
    if (path == null) throw const ProtocolException('TV não forneceu socket de entrada');
    pointer = await WebSocket.connect(
      path,
      customClient: path.startsWith('wss') ? trust.httpClient() : null,
    ).timeout(const Duration(seconds: 6));
    unawaited(pointer!.done.then((_) => pointer = null));
  }

  void button(String name) => pointer?.add('type:button\nname:$name\n\n');

  void close() {
    pointer?.close();
    pointer = null;
    ws?.close();
    ws = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(const ConnectionException('Conexão encerrada'));
    }
    _pending.clear();
  }
}

/// Emparelhamento LG: a TV mostra um pedido de permissão e devolve `client-key`.
class LgPairingFlow implements PairingFlow {
  LgPairingFlow(this.device, this.trust);
  final RemoteDevice device;
  final TlsTrust trust;
  final _state = StreamController<PairingState>.broadcast();
  _LgSession? _session;
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
      final s = _LgSession(device, trust);
      _session = s;
      await s.open();
      s.events.listen(
        (msg) {
          if (msg['type'] == 'response' && (msg['payload'] as Map?)?['pairingType'] == 'PROMPT') {
            _emit(PairingStage.awaitingTvConfirmation, 'Aceite o pedido de conexão na TV');
          } else if (msg['type'] == 'registered') {
            final key = (msg['payload'] as Map<String, dynamic>?)?['client-key']?.toString();
            if (key != null) {
              _credentials = {'clientKey': key};
              _emit(PairingStage.success, 'TV autorizada');
            } else {
              _emit(PairingStage.failure, 'TV não devolveu chave de cliente');
            }
            s.close();
          } else if (msg['type'] == 'error') {
            _emit(PairingStage.failure, 'TV recusou: ${msg['error']}');
            s.close();
          }
        },
        onDone: () {
          if (_credentials == null) _emit(PairingStage.failure, 'Conexão encerrada sem autorização');
        },
      );
      s.send(_registerPayload(null));
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
    _session?.close();
    await _state.close();
  }
}

/// Controlador LG webOS (SSAP via WebSocket, porta 3000/3001).
class LgController extends BaseRemoteController {
  LgController(super.device, this.clientKey, this.trust);
  final String? clientKey;
  final TlsTrust trust;
  _LgSession? _session;
  Completer<void>? _ready;

  @override
  Set<RemoteKey> get supportedKeys => {...lgButtonNames.keys, ...lgSsapUris.keys};
  @override
  Set<RemoteCapability> get capabilities => {
    RemoteCapability.appLaunch,
    if (device.macAddress != null) RemoteCapability.wakeOnLan,
  };

  @override
  Future<void> connect() async {
    if (currentState == DeviceConnectionState.connected) return;
    if (_ready != null && !_ready!.isCompleted) return _ready!.future;
    _ready = Completer<void>();
    setState(DeviceConnectionState.connecting);
    if (clientKey == null) {
      setState(DeviceConnectionState.needsPairing);
      throw _fail(const PairingException('Dispositivo precisa ser emparelhado'));
    }
    try {
      final s = _LgSession(device, trust);
      _session = s;
      await s.open();
      s.events.listen(
        (msg) {
          if (msg['type'] == 'registered') {
            setState(DeviceConnectionState.connected);
            if (!_ready!.isCompleted) _ready!.complete();
          } else if (msg['type'] == 'error' && msg['id'] == 'register_0') {
            _teardown(DeviceConnectionState.needsPairing);
            _fail(const PairingException('Chave rejeitada; emparelhe novamente'));
          }
        },
        onDone: () => _teardown(DeviceConnectionState.disconnected),
        onError: (Object _) => _teardown(DeviceConnectionState.error),
      );
      s.send(_registerPayload(clientKey));
      await _ready!.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw const ConnectionException('TV não confirmou o registro');
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
    _session?.close();
    _session = null;
    setState(s);
  }

  @override
  Future<void> disconnect() async => _teardown(DeviceConnectionState.disconnected);

  @override
  Future<void> sendKey(RemoteKey key, {KeyPress press = KeyPress.short}) async {
    if (press == KeyPress.longEnd) return;
    if (key == RemoteKey.power && currentState != DeviceConnectionState.connected && device.macAddress != null) {
      await const WakeOnLan().wake(device.macAddress!, host: device.host);
      return;
    }
    await ensureConnected();
    final s = _session!;
    final uri = lgSsapUris[key];
    if (uri != null) {
      if (key == RemoteKey.playPause) {
        // webOS não tem toggle; alterna com base no estado informado.
        final st = await s.request('ssap://media.controls/getForegroundAppInfo').catchError((_) => <String, dynamic>{});
        final playing = (st['payload'] as Map?)?['playState'] != 'paused';
        await s.request(playing ? 'ssap://media.controls/pause' : 'ssap://media.controls/play');
      } else {
        await s.request(uri);
      }
      return;
    }
    final button = lgButtonNames[key] ?? unsupported(key);
    await s.ensurePointer();
    s.button(button);
  }

  @override
  Future<void> launchApp(AppShortcut app) async {
    final id = app.ids[device.protocol.name];
    if (id == null) throw UnsupportedError('App sem id webOS');
    await ensureConnected();
    await _session!.request('ssap://system.launcher/launch', {'id': id});
  }

  @override
  void dispose() {
    _teardown(DeviceConnectionState.disconnected);
    super.dispose();
  }
}
