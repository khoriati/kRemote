import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../../domain/entities/app_shortcut.dart';
import '../../../domain/entities/connection_state.dart';
import '../../../domain/entities/remote_device.dart';
import '../../../domain/entities/remote_key.dart';
import '../../../domain/errors.dart';
import '../../../domain/ports/pairing_flow.dart';
import '../../net/tls_trust.dart';
import '../base_controller.dart';

/// Pares (codeset, code) do SmartCast.
const vizioKeys = <RemoteKey, (int, int)>{
  RemoteKey.power: (11, 2),
  RemoteKey.input: (7, 1),
  RemoteKey.back: (4, 0),
  RemoteKey.home: (4, 15),
  RemoteKey.up: (3, 8),
  RemoteKey.down: (3, 0),
  RemoteKey.left: (3, 1),
  RemoteKey.right: (3, 7),
  RemoteKey.ok: (3, 2),
  RemoteKey.volumeUp: (5, 1),
  RemoteKey.volumeDown: (5, 0),
  RemoteKey.mute: (5, 4),
  RemoteKey.play: (2, 3),
  RemoteKey.pause: (2, 2),
  RemoteKey.playPause: (2, 3),
  RemoteKey.rewind: (2, 1),
  RemoteKey.fastForward: (2, 0),
  RemoteKey.channelUp: (8, 1),
  RemoteKey.channelDown: (8, 0),
  RemoteKey.menu: (4, 8),
  RemoteKey.info: (4, 6),
  RemoteKey.exit: (9, 0),
  RemoteKey.captions: (4, 4),
};

const _deviceId = 'kremote-mobile';

class _VizioApi {
  _VizioApi(this.device, this.trust);
  final RemoteDevice device;
  final TlsTrust trust;
  http.Client? _client;

  Future<http.Client> client() async {
    if (_client != null) return _client!;
    await trust.load();
    return _client = IOClient(trust.httpClient());
  }

  Uri uri(String path) => Uri(scheme: 'https', host: device.host, port: device.port, path: path);

  Future<Map<String, dynamic>> put(String path, Map<String, dynamic> body, {String? auth}) async {
    final c = await client();
    final res = await c
        .put(uri(path), headers: {'Content-Type': 'application/json', 'AUTH': ?auth}, body: jsonEncode(body))
        .timeout(const Duration(seconds: 6));
    await trust.commit();
    if (res.statusCode >= 400) throw ProtocolException('TV respondeu ${res.statusCode}');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  void close() => _client?.close();
}

/// Emparelhamento Vizio: a TV exibe um PIN de 4 dígitos.
class VizioPairingFlow implements PairingFlow {
  VizioPairingFlow(this.device, this.trust) : _api = _VizioApi(device, trust);
  final RemoteDevice device;
  final TlsTrust trust;
  final _VizioApi _api;
  final _state = StreamController<PairingState>.broadcast();
  Map<String, String>? _credentials;
  int? _reqToken;

  @override
  Stream<PairingState> get state => _state.stream;
  @override
  Map<String, String>? get credentials => _credentials;

  void _emit(PairingStage s, [String? m]) {
    if (!_state.isClosed) _state.add(PairingState(s, message: m));
  }

  @override
  Future<void> start() async {
    _emit(PairingStage.connecting, 'Solicitando emparelhamento…');
    try {
      final res = await _api.put('/pairing/start', {'DEVICE_ID': _deviceId, 'DEVICE_NAME': 'kRemote'});
      _reqToken = (res['ITEM'] as Map<String, dynamic>?)?['PAIRING_REQ_TOKEN'] as int?;
      if (_reqToken == null) throw const PairingException('TV não iniciou o emparelhamento');
      _emit(PairingStage.awaitingPin, 'Digite o PIN exibido na TV');
    } on HandshakeException {
      _emit(PairingStage.failure, TlsTrust.describeHandshakeFailure(hadPin: trust.hasPin).message);
    } catch (e) {
      _emit(PairingStage.failure, e is RemoteException ? e.message : 'Falha: $e');
    }
  }

  @override
  Future<void> submit(String value) async {
    final pin = value.trim();
    if (!RegExp(r'^\d{4}$').hasMatch(pin)) {
      _emit(PairingStage.awaitingPin, 'O PIN tem 4 dígitos');
      return;
    }
    try {
      final res = await _api.put('/pairing/pair', {
        'DEVICE_ID': _deviceId,
        'CHALLENGE_TYPE': 1,
        'RESPONSE_VALUE': pin,
        'PAIRING_REQ_TOKEN': _reqToken,
      });
      final token = (res['ITEM'] as Map<String, dynamic>?)?['AUTH_TOKEN']?.toString();
      if (token == null || token.isEmpty) {
        _emit(PairingStage.awaitingPin, 'PIN incorreto');
        return;
      }
      _credentials = {'authToken': token};
      _emit(PairingStage.success, 'TV autorizada');
    } catch (e) {
      _emit(PairingStage.awaitingPin, e is RemoteException ? e.message : 'Falha: $e');
    }
  }

  @override
  Future<void> cancel() async {
    _api.close();
    await _state.close();
  }
}

/// Controlador Vizio SmartCast (HTTPS 7345/9000).
class VizioController extends BaseRemoteController {
  VizioController(super.device, this.authToken, this.trust) : _api = _VizioApi(device, trust);
  final String? authToken;
  final TlsTrust trust;
  final _VizioApi _api;

  @override
  Set<RemoteKey> get supportedKeys => vizioKeys.keys.toSet();
  @override
  Set<RemoteCapability> get capabilities => const {RemoteCapability.appLaunch};

  @override
  Future<void> connect() async {
    if (authToken == null) {
      setState(DeviceConnectionState.needsPairing);
      throw const PairingException('Dispositivo precisa ser emparelhado');
    }
    setState(DeviceConnectionState.connecting);
    try {
      final c = await _api.client();
      final res = await c
          .get(_api.uri('/state/device/power_mode'), headers: {'AUTH': authToken!})
          .timeout(const Duration(seconds: 5));
      await trust.commit();
      if (res.statusCode == 403 || res.statusCode == 401) {
        setState(DeviceConnectionState.needsPairing);
        throw const PairingException('Token rejeitado; emparelhe novamente');
      }
      if (res.statusCode != 200) throw ConnectionException('TV respondeu ${res.statusCode}');
      setState(DeviceConnectionState.connected);
    } on HandshakeException {
      setState(DeviceConnectionState.error);
      throw TlsTrust.describeHandshakeFailure(hadPin: trust.hasPin);
    } catch (e) {
      if (currentState != DeviceConnectionState.needsPairing) setState(DeviceConnectionState.error);
      throw e is RemoteException ? e : ConnectionException(e.toString());
    }
  }

  @override
  Future<void> disconnect() async => setState(DeviceConnectionState.disconnected);

  @override
  Future<void> sendKey(RemoteKey key, {KeyPress press = KeyPress.short}) async {
    final (codeset, code) = vizioKeys[key] ?? unsupported(key);
    if (press == KeyPress.longEnd) return;
    await ensureConnected();
    await _api.put('/key_command/', {
      'KEYLIST': [
        {'CODESET': codeset, 'CODE': code, 'ACTION': press == KeyPress.longStart ? 'KEYDOWN' : 'KEYPRESS'},
      ],
    }, auth: authToken);
  }

  @override
  Future<void> launchApp(AppShortcut app) async {
    // SmartCast lança apps por (NAME_SPACE, APP_ID); usamos IDs públicos conhecidos.
    const ids = {'netflix': (3, '1'), 'youtube': (5, '1'), 'prime': (2, '3'), 'disney': (4, '75'), 'spotify': (4, '9')};
    final entry = ids[app.id];
    if (entry == null) throw UnsupportedError('App sem id Vizio');
    await ensureConnected();
    await _api.put('/app/launch', {
      'VALUE': {'NAME_SPACE': entry.$1, 'APP_ID': entry.$2, 'MESSAGE': null},
    }, auth: authToken);
  }

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }
}
