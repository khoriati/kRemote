import 'package:flutter_test/flutter_test.dart';
import 'package:kremote/domain/entities/remote_device.dart';

void main() {
  group('RemoteDevice', () {
    test('JSON roundtrip preserva todos os campos', () {
      const d = RemoteDevice(
        id: 'androidTv-192-168-1-10-6466',
        name: 'TV',
        host: '192.168.1.10',
        port: 6466,
        protocol: RemoteProtocol.androidTv,
        model: 'Chromecast',
        macAddress: 'AA:BB:CC:DD:EE:FF',
        pairingPort: 6467,
      );
      final back = RemoteDevice.fromJson(d.toJson());
      expect(back, d);
      expect(back.model, 'Chromecast');
      expect(back.macAddress, 'AA:BB:CC:DD:EE:FF');
      expect(back.pairingPort, 6467);
    });

    test('igualdade por id', () {
      const a = RemoteDevice(id: 'x', name: 'A', host: '1.1.1.1', port: 1, protocol: RemoteProtocol.roku);
      const b = RemoteDevice(id: 'x', name: 'B', host: '2.2.2.2', port: 2, protocol: RemoteProtocol.roku);
      expect(a, b);
      expect(a.copyWith(name: 'C').name, 'C');
    });
  });

  group('DiscoveredDevice', () {
    test('gera id estável e porta de emparelhamento para Android TV', () {
      const found = DiscoveredDevice(name: 'TV', host: '192.168.1.96', port: 6466, protocol: RemoteProtocol.androidTv);
      final d = found.toDevice();
      expect(d.id, 'androidTv-192-168-1-96-6466');
      expect(d.pairingPort, 6467);
      expect(found.key, 'androidTv@192.168.1.96:6466');
    });
  });

  group('RemoteProtocol', () {
    test('portas padrão e exigência de emparelhamento', () {
      expect(RemoteProtocol.androidTv.defaultPort, 6466);
      expect(RemoteProtocol.cast.defaultPort, 8009);
      expect(RemoteProtocol.androidTv.requiresPairing, isTrue);
      expect(RemoteProtocol.roku.requiresPairing, isFalse);
      expect(RemoteProtocol.bluetoothHid.isNetwork, isFalse);
      for (final p in RemoteProtocol.values) {
        expect(p.label, isNotEmpty);
        expect(p.hint, isNotEmpty);
      }
    });
  });
}
