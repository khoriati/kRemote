import 'package:flutter_test/flutter_test.dart';
import 'package:kremote/domain/entities/app_shortcut.dart';
import 'package:kremote/domain/entities/remote_key.dart';
import 'package:kremote/infrastructure/protocols/bluetooth_hid/hid_usage.dart';
import 'package:kremote/infrastructure/protocols/lg/lg_controller.dart';
import 'package:kremote/infrastructure/protocols/philips/philips_controller.dart';
import 'package:kremote/infrastructure/protocols/roku/roku_controller.dart';
import 'package:kremote/infrastructure/protocols/samsung/samsung_controller.dart';
import 'package:kremote/infrastructure/protocols/sony/sony_controller.dart';
import 'package:kremote/infrastructure/protocols/vizio/vizio_controller.dart';

/// Teclas mínimas do controle Chromecast que todo protocolo de TV deve cobrir.
const chromecastCore = {
  RemoteKey.power,
  RemoteKey.back,
  RemoteKey.home,
  RemoteKey.up,
  RemoteKey.down,
  RemoteKey.left,
  RemoteKey.right,
  RemoteKey.ok,
  RemoteKey.volumeUp,
  RemoteKey.volumeDown,
  RemoteKey.mute,
};

void main() {
  group('Mapas de teclas por protocolo', () {
    final maps = <String, Set<RemoteKey>>{
      'samsung': samsungKeys.keys.toSet(),
      'lg': {...lgButtonNames.keys, ...lgSsapUris.keys},
      'roku': rokuKeys.keys.toSet(),
      'sony': sonyIrccCodes.keys.toSet(),
      'philips': philipsKeys.keys.toSet(),
      'vizio': vizioKeys.keys.toSet(),
    };
    for (final e in maps.entries) {
      test('${e.key} cobre o núcleo do controle Chromecast', () {
        expect(e.value, containsAll(chromecastCore));
      });
    }

    test('códigos IRCC Sony são base64 válido', () {
      for (final code in sonyIrccCodes.values) {
        expect(() => Uri.parse('data:;base64,$code'), returnsNormally);
        expect(code, matches(RegExp(r'^[A-Za-z0-9+/]+=*$')));
      }
    });

    test('HID cobre apresentação e volume', () {
      expect(hidKeyboardUsages[RemoteKey.right], (0, 0x4F));
      expect(hidKeyboardUsages[RemoteKey.ok], (0, 0x28));
      expect(hidKeyboardUsages[RemoteKey.back], (0, 0x29));
      expect(hidConsumerUsages[RemoteKey.volumeUp], 0xE9);
      expect(hidUsageForChar('a'), (0, 0x04));
      expect(hidUsageForChar('A'), (0x02, 0x04));
      expect(hidUsageForChar('ç'), isNull);
    });
  });

  group('RemoteKey', () {
    test('dígitos', () {
      expect(RemoteKey.num7.isDigit, isTrue);
      expect(RemoteKey.num7.digit, 7);
      expect(RemoteKey.fromDigit(0), RemoteKey.num0);
      expect(RemoteKey.home.isDigit, isFalse);
      expect(RemoteKey.home.digit, -1);
    });
  });

  group('AppShortcut', () {
    test('todo atalho tem deep link ou pacote Android TV (caminho crítico)', () {
      final valid = RegExp(r'^(https://\S+|market://launch\?id=[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+)$');
      for (final a in AppShortcut.all) {
        final spec = a.ids['androidTv'];
        expect(spec, isNotNull, reason: a.id);
        for (final candidate in spec!.split(' ')) {
          expect(candidate, matches(valid), reason: '${a.id}: $candidate');
        }
        expect(a.asset, 'assets/apps/${a.id}.png');
      }
    });
  });
}
