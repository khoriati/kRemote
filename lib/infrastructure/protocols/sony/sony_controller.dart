import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../domain/entities/app_shortcut.dart';
import '../../../domain/entities/connection_state.dart';
import '../../../domain/entities/remote_device.dart';
import '../../../domain/entities/remote_key.dart';
import '../../../domain/errors.dart';
import '../../../domain/ports/pairing_flow.dart';
import '../../net/wake_on_lan.dart';
import '../base_controller.dart';

/// Códigos IRCC (Sony Bravia).
const sonyIrccCodes = <RemoteKey, String>{
  RemoteKey.power: 'AAAAAQAAAAEAAAAVAw==',
  RemoteKey.input: 'AAAAAQAAAAEAAAAlAw==',
  RemoteKey.assistant: 'AAAAAgAAAJcAAABQAw==',
  RemoteKey.back: 'AAAAAgAAAJcAAAAjAw==',
  RemoteKey.home: 'AAAAAQAAAAEAAABgAw==',
  RemoteKey.up: 'AAAAAQAAAAEAAAB0Aw==',
  RemoteKey.down: 'AAAAAQAAAAEAAAB1Aw==',
  RemoteKey.left: 'AAAAAQAAAAEAAAA0Aw==',
  RemoteKey.right: 'AAAAAQAAAAEAAAAzAw==',
  RemoteKey.ok: 'AAAAAQAAAAEAAABlAw==',
  RemoteKey.volumeUp: 'AAAAAQAAAAEAAAASAw==',
  RemoteKey.volumeDown: 'AAAAAQAAAAEAAAATAw==',
  RemoteKey.mute: 'AAAAAQAAAAEAAAAUAw==',
  RemoteKey.play: 'AAAAAgAAAJcAAAAaAw==',
  RemoteKey.pause: 'AAAAAgAAAJcAAAAZAw==',
  RemoteKey.playPause: 'AAAAAgAAAJcAAAAaAw==',
  RemoteKey.stop: 'AAAAAgAAAJcAAAAYAw==',
  RemoteKey.rewind: 'AAAAAgAAAJcAAAAbAw==',
  RemoteKey.fastForward: 'AAAAAgAAAJcAAAAcAw==',
  RemoteKey.next: 'AAAAAgAAAJcAAAA9Aw==',
  RemoteKey.previous: 'AAAAAgAAAJcAAAA8Aw==',
  RemoteKey.record: 'AAAAAgAAAJcAAAAgAw==',
  RemoteKey.channelUp: 'AAAAAQAAAAEAAAAQAw==',
  RemoteKey.channelDown: 'AAAAAQAAAAEAAAARAw==',
  RemoteKey.menu: 'AAAAAgAAAJcAAAA2Aw==',
  RemoteKey.info: 'AAAAAQAAAAEAAAA6Aw==',
  RemoteKey.guide: 'AAAAAgAAAKQAAABbAw==',
  RemoteKey.settings: 'AAAAAgAAAJcAAAA2Aw==',
  RemoteKey.exit: 'AAAAAQAAAAEAAABjAw==',
  RemoteKey.captions: 'AAAAAgAAAJcAAAAoAw==',
  RemoteKey.num1: 'AAAAAQAAAAEAAAAAAw==',
  RemoteKey.num2: 'AAAAAQAAAAEAAAABAw==',
  RemoteKey.num3: 'AAAAAQAAAAEAAAACAw==',
  RemoteKey.num4: 'AAAAAQAAAAEAAAADAw==',
  RemoteKey.num5: 'AAAAAQAAAAEAAAAEAw==',
  RemoteKey.num6: 'AAAAAQAAAAEAAAAFAw==',
  RemoteKey.num7: 'AAAAAQAAAAEAAAAGAw==',
  RemoteKey.num8: 'AAAAAQAAAAEAAAAHAw==',
  RemoteKey.num9: 'AAAAAQAAAAEAAAAIAw==',
  RemoteKey.num0: 'AAAAAQAAAAEAAAAJAw==',
  RemoteKey.enter: 'AAAAAQAAAAEAAAALAw==',
  RemoteKey.red: 'AAAAAgAAAJcAAAAlAw==',
  RemoteKey.green: 'AAAAAgAAAJcAAAAmAw==',
  RemoteKey.yellow: 'AAAAAgAAAJcAAAAnAw==',
  RemoteKey.blue: 'AAAAAgAAAJcAAAAkAw==',
};

String _irccEnvelope(String code) =>
    '<?xml version="1.0"?>'
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
    '<s:Body><u:X_SendIRCC xmlns:u="urn:schemas-sony-com:service:IRCC:1"><IRCCCode>$code</IRCCCode></u:X_SendIRCC></s:Body></s:Envelope>';

/// "Emparelhamento" Sony: o usuário informa a Pre-Shared Key configurada na TV.
class SonyPairingFlow implements PairingFlow {
  SonyPairingFlow(this.device, {http.Client? client}) : _client = client ?? http.Client();
  final RemoteDevice device;
  final http.Client _client;
  final _state = StreamController<PairingState>.broadcast();
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
    _emit(PairingStage.awaitingSecret, 'Informe a Pre-Shared Key definida em Rede › Controle de dispositivo IP');
  }

  @override
  Future<void> submit(String value) async {
    final psk = value.trim();
    if (psk.isEmpty || psk.length > 64) {
      _emit(PairingStage.awaitingSecret, 'Chave inválida');
      return;
    }
    _emit(PairingStage.connecting, 'Validando…');
    try {
      final res = await _client
          .post(
            Uri(scheme: 'http', host: device.host, port: device.port, path: '/sony/system'),
            headers: {'X-Auth-PSK': psk, 'Content-Type': 'application/json'},
            body: jsonEncode({'method': 'getSystemInformation', 'id': 1, 'params': <dynamic>[], 'version': '1.0'}),
          )
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 200 && !(jsonDecode(res.body) as Map).containsKey('error')) {
        _credentials = {'psk': psk};
        _emit(PairingStage.success, 'TV autorizada');
      } else {
        _emit(PairingStage.awaitingSecret, 'A TV rejeitou a chave');
      }
    } catch (e) {
      _emit(PairingStage.awaitingSecret, 'Não foi possível validar: $e');
    }
  }

  @override
  Future<void> cancel() async {
    _client.close();
    await _state.close();
  }
}

/// Controlador Sony Bravia (IRCC sobre SOAP + REST `appControl`).
class SonyController extends BaseRemoteController {
  SonyController(super.device, this.psk, {http.Client? client}) : _client = client ?? http.Client();
  final String? psk;
  final http.Client _client;

  Uri _uri(String path) => Uri(scheme: 'http', host: device.host, port: device.port, path: path);
  Map<String, String> get _headers => {'X-Auth-PSK': psk ?? '', 'Content-Type': 'text/xml; charset=UTF-8'};

  @override
  Set<RemoteKey> get supportedKeys => sonyIrccCodes.keys.toSet();
  @override
  Set<RemoteCapability> get capabilities => {
    RemoteCapability.appLaunch,
    if (device.macAddress != null) RemoteCapability.wakeOnLan,
  };

  @override
  Future<void> connect() async {
    if (psk == null) {
      setState(DeviceConnectionState.needsPairing);
      throw const PairingException('Informe a Pre-Shared Key da TV');
    }
    setState(DeviceConnectionState.connecting);
    try {
      final res = await _client
          .post(
            _uri('/sony/system'),
            headers: {'X-Auth-PSK': psk!, 'Content-Type': 'application/json'},
            body: jsonEncode({'method': 'getPowerStatus', 'id': 1, 'params': <dynamic>[], 'version': '1.0'}),
          )
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 403) {
        setState(DeviceConnectionState.needsPairing);
        throw const PairingException('Pre-Shared Key rejeitada');
      }
      if (res.statusCode != 200) throw ConnectionException('TV respondeu ${res.statusCode}');
      setState(DeviceConnectionState.connected);
    } catch (e) {
      if (currentState != DeviceConnectionState.needsPairing) setState(DeviceConnectionState.error);
      throw e is RemoteException ? e : ConnectionException(e.toString());
    }
  }

  @override
  Future<void> disconnect() async => setState(DeviceConnectionState.disconnected);

  @override
  Future<void> sendKey(RemoteKey key, {KeyPress press = KeyPress.short}) async {
    final code = sonyIrccCodes[key] ?? unsupported(key);
    if (press == KeyPress.longEnd) return;
    if (key == RemoteKey.power && currentState != DeviceConnectionState.connected && device.macAddress != null) {
      await const WakeOnLan().wake(device.macAddress!, host: device.host);
    }
    await ensureConnected();
    final res = await _client
        .post(
          _uri('/sony/ircc'),
          headers: {..._headers, 'SOAPACTION': '"urn:schemas-sony-com:service:IRCC:1#X_SendIRCC"'},
          body: _irccEnvelope(code),
        )
        .timeout(const Duration(seconds: 5));
    if (res.statusCode >= 400) throw ProtocolException('TV respondeu ${res.statusCode}');
  }

  @override
  Future<void> launchApp(AppShortcut app) async {
    await ensureConnected();
    final list = await _client
        .post(
          _uri('/sony/appControl'),
          headers: {'X-Auth-PSK': psk!, 'Content-Type': 'application/json'},
          body: jsonEncode({'method': 'getApplicationList', 'id': 1, 'params': <dynamic>[], 'version': '1.0'}),
        )
        .timeout(const Duration(seconds: 5));
    final result = (jsonDecode(list.body) as Map<String, dynamic>)['result'] as List<dynamic>? ?? [];
    final apps = (result.isEmpty ? <dynamic>[] : result.first as List<dynamic>).cast<Map<String, dynamic>>();
    final wanted = app.ids[device.protocol.name];
    final match = apps.firstWhere(
      (a) =>
          (wanted != null && (a['uri'] as String? ?? '').contains(wanted)) ||
          (a['title'] as String? ?? '').toLowerCase().contains(app.label.toLowerCase()),
      orElse: () => throw ProtocolException('${app.label} não está instalado na TV'),
    );
    await _client
        .post(
          _uri('/sony/appControl'),
          headers: {'X-Auth-PSK': psk!, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'method': 'setActiveApp',
            'id': 1,
            'params': [
              {'uri': match['uri']},
            ],
            'version': '1.0',
          }),
        )
        .timeout(const Duration(seconds: 5));
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}
