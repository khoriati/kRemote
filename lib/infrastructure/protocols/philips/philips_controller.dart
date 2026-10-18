import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../domain/entities/connection_state.dart';
import '../../../domain/entities/remote_key.dart';
import '../../../domain/errors.dart';
import '../../net/wake_on_lan.dart';
import '../base_controller.dart';

/// Teclas JointSpace (Philips não-Android, API v1/v5, porta 1925).
const philipsKeys = <RemoteKey, String>{
  RemoteKey.power: 'Standby',
  RemoteKey.input: 'Source',
  RemoteKey.assistant: 'Find',
  RemoteKey.back: 'Back',
  RemoteKey.home: 'Home',
  RemoteKey.up: 'CursorUp',
  RemoteKey.down: 'CursorDown',
  RemoteKey.left: 'CursorLeft',
  RemoteKey.right: 'CursorRight',
  RemoteKey.ok: 'Confirm',
  RemoteKey.volumeUp: 'VolumeUp',
  RemoteKey.volumeDown: 'VolumeDown',
  RemoteKey.mute: 'Mute',
  RemoteKey.playPause: 'PlayPause',
  RemoteKey.play: 'Play',
  RemoteKey.pause: 'Pause',
  RemoteKey.stop: 'Stop',
  RemoteKey.rewind: 'Rewind',
  RemoteKey.fastForward: 'FastForward',
  RemoteKey.next: 'Next',
  RemoteKey.previous: 'Previous',
  RemoteKey.record: 'Record',
  RemoteKey.channelUp: 'ChannelStepUp',
  RemoteKey.channelDown: 'ChannelStepDown',
  RemoteKey.menu: 'Options',
  RemoteKey.info: 'Info',
  RemoteKey.guide: 'Teletext',
  RemoteKey.settings: 'Adjust',
  RemoteKey.exit: 'WatchTV',
  RemoteKey.captions: 'Subtitle',
  RemoteKey.num0: 'Digit0',
  RemoteKey.num1: 'Digit1',
  RemoteKey.num2: 'Digit2',
  RemoteKey.num3: 'Digit3',
  RemoteKey.num4: 'Digit4',
  RemoteKey.num5: 'Digit5',
  RemoteKey.num6: 'Digit6',
  RemoteKey.num7: 'Digit7',
  RemoteKey.num8: 'Digit8',
  RemoteKey.num9: 'Digit9',
  RemoteKey.dash: 'Dot',
  RemoteKey.enter: 'Confirm',
  RemoteKey.red: 'RedColour',
  RemoteKey.green: 'GreenColour',
  RemoteKey.yellow: 'YellowColour',
  RemoteKey.blue: 'BlueColour',
};

/// Controlador Philips JointSpace v1/v5 (HTTP). TVs Philips com Google TV
/// devem ser adicionadas como "Google TV / Android TV".
class PhilipsController extends BaseRemoteController {
  PhilipsController(super.device, {http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  int _apiVersion = 1;

  Uri _uri(String path) => Uri(scheme: 'http', host: device.host, port: device.port, path: '/$_apiVersion$path');

  @override
  Set<RemoteKey> get supportedKeys => philipsKeys.keys.toSet();
  @override
  Set<RemoteCapability> get capabilities => {if (device.macAddress != null) RemoteCapability.wakeOnLan};

  @override
  Future<void> connect() async {
    setState(DeviceConnectionState.connecting);
    for (final v in const [1, 5, 6]) {
      _apiVersion = v;
      try {
        final res = await _client.get(_uri('/system')).timeout(const Duration(seconds: 3));
        if (res.statusCode == 200) {
          setState(DeviceConnectionState.connected);
          return;
        }
      } catch (_) {
        // tenta a próxima versão
      }
    }
    setState(DeviceConnectionState.error);
    throw const ConnectionException(
      'TV Philips não respondeu ao JointSpace (1925). Se for Google TV, use o protocolo Android TV.',
    );
  }

  @override
  Future<void> disconnect() async => setState(DeviceConnectionState.disconnected);

  @override
  Future<void> sendKey(RemoteKey key, {KeyPress press = KeyPress.short}) async {
    final name = philipsKeys[key] ?? unsupported(key);
    if (press == KeyPress.longEnd) return;
    if (key == RemoteKey.power && currentState != DeviceConnectionState.connected && device.macAddress != null) {
      await const WakeOnLan().wake(device.macAddress!, host: device.host);
      return;
    }
    await ensureConnected();
    final res = await _client
        .post(_uri('/input/key'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'key': name}))
        .timeout(const Duration(seconds: 4));
    if (res.statusCode >= 400) throw ProtocolException('TV respondeu ${res.statusCode}');
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}
