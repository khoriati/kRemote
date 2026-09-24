import 'dart:async';

import 'package:http/http.dart' as http;

import '../../../domain/entities/app_shortcut.dart';
import '../../../domain/entities/connection_state.dart';
import '../../../domain/entities/remote_key.dart';
import '../../../domain/errors.dart';
import '../base_controller.dart';

/// Teclas do Roku External Control Protocol.
const rokuKeys = <RemoteKey, String>{
  RemoteKey.power: 'Power',
  RemoteKey.input: 'InputTuner',
  RemoteKey.assistant: 'Search',
  RemoteKey.back: 'Back',
  RemoteKey.home: 'Home',
  RemoteKey.up: 'Up',
  RemoteKey.down: 'Down',
  RemoteKey.left: 'Left',
  RemoteKey.right: 'Right',
  RemoteKey.ok: 'Select',
  RemoteKey.volumeUp: 'VolumeUp',
  RemoteKey.volumeDown: 'VolumeDown',
  RemoteKey.mute: 'VolumeMute',
  RemoteKey.playPause: 'Play',
  RemoteKey.play: 'Play',
  RemoteKey.pause: 'Play',
  RemoteKey.rewind: 'Rev',
  RemoteKey.fastForward: 'Fwd',
  RemoteKey.previous: 'InstantReplay',
  RemoteKey.channelUp: 'ChannelUp',
  RemoteKey.channelDown: 'ChannelDown',
  RemoteKey.info: 'Info',
  RemoteKey.menu: 'Info',
  RemoteKey.backspace: 'Backspace',
  RemoteKey.enter: 'Enter',
  RemoteKey.num0: 'Lit_0',
  RemoteKey.num1: 'Lit_1',
  RemoteKey.num2: 'Lit_2',
  RemoteKey.num3: 'Lit_3',
  RemoteKey.num4: 'Lit_4',
  RemoteKey.num5: 'Lit_5',
  RemoteKey.num6: 'Lit_6',
  RemoteKey.num7: 'Lit_7',
  RemoteKey.num8: 'Lit_8',
  RemoteKey.num9: 'Lit_9',
};

/// Controlador Roku (ECP, HTTP porta 8060). Sem emparelhamento.
class RokuController extends BaseRemoteController {
  RokuController(super.device, {http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  Uri _uri(String path) => Uri(scheme: 'http', host: device.host, port: device.port, path: path);

  @override
  Set<RemoteKey> get supportedKeys => rokuKeys.keys.toSet();
  @override
  Set<RemoteCapability> get capabilities => const {RemoteCapability.textInput, RemoteCapability.appLaunch};

  @override
  Future<void> connect() async {
    setState(DeviceConnectionState.connecting);
    try {
      final res = await _client.get(_uri('/query/device-info')).timeout(const Duration(seconds: 4));
      if (res.statusCode != 200) throw ConnectionException('Roku respondeu ${res.statusCode}');
      setState(DeviceConnectionState.connected);
    } catch (e) {
      setState(DeviceConnectionState.error);
      throw e is RemoteException ? e : ConnectionException(e.toString());
    }
  }

  @override
  Future<void> disconnect() async => setState(DeviceConnectionState.disconnected);

  Future<void> _post(String path) async {
    final res = await _client.post(_uri(path)).timeout(const Duration(seconds: 4));
    if (res.statusCode >= 400) throw ProtocolException('Roku respondeu ${res.statusCode}');
  }

  @override
  Future<void> sendKey(RemoteKey key, {KeyPress press = KeyPress.short}) async {
    final name = rokuKeys[key] ?? unsupported(key);
    await ensureConnected();
    final verb = switch (press) {
      KeyPress.short => 'keypress',
      KeyPress.longStart => 'keydown',
      KeyPress.longEnd => 'keyup',
    };
    await _post('/$verb/$name');
  }

  @override
  Future<void> sendText(String text) async {
    await ensureConnected();
    for (final rune in text.runes) {
      await _post('/keypress/Lit_${Uri.encodeComponent(String.fromCharCode(rune))}');
    }
  }

  @override
  Future<void> launchApp(AppShortcut app) async {
    final id = app.ids[device.protocol.name];
    if (id == null) throw UnsupportedError('App sem id Roku');
    await ensureConnected();
    await _post('/launch/$id');
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}
