import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kremote/application/network_scanner.dart';
import 'package:kremote/domain/entities/remote_device.dart';
import 'package:kremote/domain/ports/device_discovery.dart';

/// Descoberta controlável: cada varredura devolve o lote atual.
class _ScriptedDiscovery implements DeviceDiscovery {
  List<DiscoveredDevice> next = const [];
  int scans = 0;
  @override
  Stream<DiscoveredDevice> discover({Duration timeout = const Duration(seconds: 6)}) {
    scans++;
    return Stream.fromIterable(List.of(next));
  }
}

DiscoveredDevice _d(String name, String host) =>
    DiscoveredDevice(name: name, host: host, port: 6466, protocol: RemoteProtocol.androidTv, serviceName: name);

void main() {
  test('varredura em andamento é compartilhada e o resultado ordena Android TV primeiro', () async {
    final disc = _ScriptedDiscovery()
      ..next = [
        const DiscoveredDevice(name: 'Caixa', host: '10.0.0.9', port: 8009, protocol: RemoteProtocol.cast),
        _d('Sala', '10.0.0.5'),
      ];
    final scanner = NetworkScanner(disc);
    final a = scanner.scan();
    final b = scanner.scan();
    expect(identical(a, b), isTrue);
    final found = await a;
    expect(disc.scans, 1);
    expect(found.map((e) => e.name), ['Sala', 'Caixa']);
    expect(scanner.scanning, isFalse);
  });

  test('aparelhos que somem da rede expiram após staleAfter', () async {
    final disc = _ScriptedDiscovery()..next = [_d('Sala', '10.0.0.5')];
    final scanner = NetworkScanner(disc, staleAfter: const Duration(milliseconds: 50));
    await scanner.scan();
    expect(scanner.found, hasLength(1));
    disc.next = const [];
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await scanner.scan();
    expect(scanner.found, isEmpty);
  });

  test('watch repete a varredura periodicamente e unwatch encerra', () async {
    final disc = _ScriptedDiscovery()..next = [_d('Sala', '10.0.0.5')];
    final scanner = NetworkScanner(disc, interval: const Duration(milliseconds: 30));
    var notified = 0;
    scanner.addListener(() => notified++);
    scanner.watch();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    scanner.unwatch();
    final after = disc.scans;
    expect(after, greaterThanOrEqualTo(3));
    await Future<void>.delayed(const Duration(milliseconds: 70));
    expect(disc.scans, after, reason: 'sem observadores não varre');
    expect(notified, greaterThan(0));
    scanner.dispose();
  });
}
