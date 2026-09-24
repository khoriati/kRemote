import '../../../domain/entities/remote_key.dart';

/// Relatório HID de teclado: (modificadores, usage). Usage IDs da HID Usage
/// Table, página Keyboard/Keypad (0x07).
const hidKeyboardUsages = <RemoteKey, (int, int)>{
  RemoteKey.right: (0, 0x4F), // → (próximo slide)
  RemoteKey.left: (0, 0x50), // ←
  RemoteKey.down: (0, 0x51),
  RemoteKey.up: (0, 0x52),
  RemoteKey.next: (0, 0x4E), // Page Down
  RemoteKey.previous: (0, 0x4B), // Page Up
  RemoteKey.ok: (0, 0x28), // Enter
  RemoteKey.enter: (0, 0x28),
  RemoteKey.back: (0, 0x29), // Esc
  RemoteKey.exit: (0, 0x29),
  RemoteKey.home: (0, 0x3E), // F5 — iniciar apresentação
  RemoteKey.menu: (0, 0x05), // B — tela preta (PowerPoint/Keynote)
  RemoteKey.info: (0, 0x1A), // W — tela branca
  RemoteKey.backspace: (0, 0x2A),
  RemoteKey.num0: (0, 0x27),
  RemoteKey.num1: (0, 0x1E),
  RemoteKey.num2: (0, 0x1F),
  RemoteKey.num3: (0, 0x20),
  RemoteKey.num4: (0, 0x21),
  RemoteKey.num5: (0, 0x22),
  RemoteKey.num6: (0, 0x23),
  RemoteKey.num7: (0, 0x24),
  RemoteKey.num8: (0, 0x25),
  RemoteKey.num9: (0, 0x26),
};

/// Usages da página Consumer (0x0C) para mídia e volume.
const hidConsumerUsages = <RemoteKey, int>{
  RemoteKey.volumeUp: 0xE9,
  RemoteKey.volumeDown: 0xEA,
  RemoteKey.mute: 0xE2,
  RemoteKey.playPause: 0xCD,
  RemoteKey.play: 0xB0,
  RemoteKey.pause: 0xB1,
  RemoteKey.stop: 0xB7,
  RemoteKey.fastForward: 0xB3,
  RemoteKey.rewind: 0xB4,
  RemoteKey.power: 0x30,
};

/// Usage de teclado para um caractere ASCII simples (letras, dígitos, espaço).
(int, int)? hidUsageForChar(String ch) {
  if (ch.length != 1) return null;
  final c = ch.codeUnitAt(0);
  if (c >= 0x61 && c <= 0x7a) return (0, 0x04 + (c - 0x61));
  if (c >= 0x41 && c <= 0x5a) return (0x02, 0x04 + (c - 0x41)); // Shift
  if (c >= 0x31 && c <= 0x39) return (0, 0x1E + (c - 0x31));
  if (c == 0x30) return (0, 0x27);
  return const {' ': (0, 0x2C), '\n': (0, 0x28), '.': (0, 0x37), ',': (0, 0x36), '-': (0, 0x2D)}[ch];
}
