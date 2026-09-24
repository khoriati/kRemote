import '../../../domain/entities/remote_key.dart';

/// Códigos `android.view.KeyEvent` usados pelo Android TV Remote v2.
const androidTvKeyCodes = <RemoteKey, int>{
  RemoteKey.power: 26,
  RemoteKey.input: 178,
  RemoteKey.assistant: 84,
  RemoteKey.back: 4,
  RemoteKey.home: 3,
  RemoteKey.up: 19,
  RemoteKey.down: 20,
  RemoteKey.left: 21,
  RemoteKey.right: 22,
  RemoteKey.ok: 23,
  RemoteKey.volumeUp: 24,
  RemoteKey.volumeDown: 25,
  RemoteKey.mute: 164,
  RemoteKey.playPause: 85,
  RemoteKey.play: 126,
  RemoteKey.pause: 127,
  RemoteKey.stop: 86,
  RemoteKey.rewind: 89,
  RemoteKey.fastForward: 90,
  RemoteKey.next: 87,
  RemoteKey.previous: 88,
  RemoteKey.record: 130,
  RemoteKey.channelUp: 166,
  RemoteKey.channelDown: 167,
  RemoteKey.menu: 82,
  RemoteKey.info: 165,
  RemoteKey.guide: 172,
  RemoteKey.settings: 176,
  RemoteKey.exit: 111,
  RemoteKey.captions: 175,
  RemoteKey.num0: 7,
  RemoteKey.num1: 8,
  RemoteKey.num2: 9,
  RemoteKey.num3: 10,
  RemoteKey.num4: 11,
  RemoteKey.num5: 12,
  RemoteKey.num6: 13,
  RemoteKey.num7: 14,
  RemoteKey.num8: 15,
  RemoteKey.num9: 16,
  RemoteKey.dash: 69,
  RemoteKey.backspace: 67,
  RemoteKey.enter: 66,
  RemoteKey.red: 183,
  RemoteKey.green: 184,
  RemoteKey.yellow: 185,
  RemoteKey.blue: 186,
};

/// Mapeia caracteres para key codes Android (texto via eventos de tecla).
int? androidTvKeyCodeForChar(String ch) {
  final c = ch.toLowerCase();
  if (c.length != 1) return null;
  final code = c.codeUnitAt(0);
  if (code >= 0x61 && code <= 0x7a) return 29 + (code - 0x61); // a–z
  if (code >= 0x30 && code <= 0x39) return 7 + (code - 0x30); // 0–9
  return const {' ': 62, '.': 56, ',': 55, '-': 69, '@': 77, '/': 76, '=': 70, '+': 81, ';': 74, "'": 75, '\n': 66}[c];
}
