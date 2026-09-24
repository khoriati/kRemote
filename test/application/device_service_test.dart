import 'package:flutter_test/flutter_test.dart';
import 'package:kremote/application/device_service.dart';
import 'package:kremote/domain/entities/remote_device.dart';
import 'package:kremote/domain/errors.dart';
import 'package:kremote/infrastructure/controller_factory.dart';
import 'package:kremote/infrastructure/protocols/android_tv/android_tv_certificate.dart';
import 'package:kremote/infrastructure/protocols/android_tv/android_tv_controller.dart';
import 'package:kremote/infrastructure/protocols/roku/roku_controller.dart';

import '../support/fakes.dart';

void main() {
  late MemoryDeviceRepository repo;
  late MemoryCredentialStore creds;
  late MemoryPinStore pins;
  late DeviceService svc;

  setUp(() {
    repo = MemoryDeviceRepository();
    creds = MemoryCredentialStore();
    pins = MemoryPinStore();
    svc = DeviceService(
      repository: repo,
      credentials: creds,
      pins: pins,
      factory: ControllerFactory(credentials: creds, pins: pins),
    );
  });

  group('validação de entrada', () {
    test('hosts', () {
      expect(isValidHost('192.168.1.96'), isTrue);
      expect(isValidHost('tv-sala.local'), isTrue);
      expect(isValidHost('fe80::1'), isTrue);
      expect(isValidHost('999.1.1.1'), isFalse);
      expect(isValidHost('http://x'), isFalse);
      expect(isValidHost(''), isFalse);
      expect(isValidHost('a b'), isFalse);
    });
    test('MAC', () {
      expect(isValidMac('AA:BB:CC:DD:EE:FF'), isTrue);
      expect(isValidMac('aa-bb-cc-dd-ee-ff'), isTrue);
      expect(isValidMac('AABBCCDDEEFF'), isFalse);
    });
  });

  group('cadastro e dispositivo ativo', () {
    test('add persiste, torna ativo e permite alternar', () async {
      await svc.load();
      expect(svc.active, isNull);
      await svc.add(device(id: 'a', name: 'Sala'));
      await svc.add(device(id: 'b', name: 'Quarto', protocol: RemoteProtocol.roku, port: 8060));
      expect(svc.devices.length, 2);
      expect(svc.active?.id, 'b');
      svc.setActive('a');
      expect(svc.active?.id, 'a');
      expect(repo.saved.length, 2);
    });

    test('rejeita host inválido', () async {
      await expectLater(svc.add(device(host: 'não é host')), throwsA(isA<ConnectionException>()));
    });

    test('remove apaga credenciais e pin e realoca ativo', () async {
      await svc.add(device(id: 'a'));
      await svc.add(device(id: 'b'));
      creds.data['b'] = {'x': 'y'};
      pins.pins['b'] = 'abc';
      await svc.remove('b');
      expect(svc.devices.map((d) => d.id), ['a']);
      expect(svc.active?.id, 'a');
      expect(creds.data.containsKey('b'), isFalse);
      expect(pins.pins.containsKey('b'), isFalse);
    });

    test('isPaired reflete credenciais existentes por protocolo', () async {
      final atv = device(id: 'atv');
      final roku = device(id: 'roku', protocol: RemoteProtocol.roku, port: 8060);
      repo.saved = [atv, roku];
      creds.data['atv'] = ClientIdentity.generate().toCredentials();
      await svc.load();
      expect(svc.isPaired(atv), isTrue);
      expect(svc.isPaired(roku), isTrue);
      await svc.resetTrust('atv');
      expect(svc.isPaired(atv), isFalse);
    });

    test('mantém um controlador por dispositivo e recria após update', () async {
      final d = device(id: 'a');
      await svc.add(d);
      final c1 = await svc.controller(d);
      final c2 = await svc.controller(d);
      expect(identical(c1, c2), isTrue);
      expect(c1, isA<AndroidTvController>());
      await svc.update(d.copyWith(name: 'Novo'));
      final c3 = await svc.controller(svc.devices.first);
      expect(identical(c1, c3), isFalse);
      expect(svc.devices.first.name, 'Novo');
    });

    test('identidade Android TV do app é única, persistida e reutilizada', () async {
      final factory = ControllerFactory(credentials: creds, pins: pins);
      final a = await factory.appIdentity();
      final b = await factory.appIdentity();
      expect(identical(a, b), isTrue);
      expect(creds.data[ControllerFactory.appIdentityKey], isNotNull);
      final again = await ControllerFactory(credentials: creds, pins: pins).appIdentity();
      expect(again.certificatePem, a.certificatePem);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('protocolo sem emparelhamento é sempre "emparelhado", mesmo após resetTrust', () async {
      final cast = device(id: 'c', protocol: RemoteProtocol.cast, port: 8009);
      await svc.add(cast);
      expect(svc.isPaired(cast), isTrue);
      await svc.resetTrust('c');
      expect(svc.isPaired(cast), isTrue);
    });

    test('Cast cujo host atende em 6466 é promovido a Google TV', () async {
      final promoted = DeviceService(
        repository: repo,
        credentials: creds,
        pins: pins,
        factory: ControllerFactory(credentials: creds, pins: pins),
        probe: (host, port) async => port == 6466,
      );
      final added = await promoted.add(
        const RemoteDevice(
          id: 'cast-x',
          name: 'Projetor',
          host: '192.168.1.43',
          port: 8009,
          protocol: RemoteProtocol.cast,
          model: 'Chromecast',
        ),
      );
      expect(added.protocol, RemoteProtocol.androidTv);
      expect(added.port, 6466);
      expect(added.pairingPort, 6467);
      expect(added.name, 'Projetor');
      expect(added.volumeViaCast, isFalse, reason: 'Chromecast usa tecla de volume');
      expect(promoted.isPaired(added), isFalse);
      expect(promoted.devices.single.id, added.id);

      final notPromoted = DeviceService(
        repository: MemoryDeviceRepository(),
        credentials: creds,
        pins: pins,
        factory: ControllerFactory(credentials: creds, pins: pins),
        probe: (host, port) async => false,
      );
      final kept = await notPromoted.add(device(id: 'c2', protocol: RemoteProtocol.cast, port: 8009));
      expect(kept.protocol, RemoteProtocol.cast);
    });

    test('load migra Cast já cadastrado para Google TV quando 6466 responde', () async {
      repo.saved = [device(id: 'cast-old', name: 'Projetor', protocol: RemoteProtocol.cast, port: 8009)];
      final s = DeviceService(
        repository: repo,
        credentials: creds,
        pins: pins,
        factory: ControllerFactory(credentials: creds, pins: pins),
        probe: (host, port) async => true,
      );
      await s.load();
      await Future<void>.delayed(Duration.zero);
      expect(s.devices.single.protocol, RemoteProtocol.androidTv);
      expect(s.active?.protocol, RemoteProtocol.androidTv);
      expect(repo.saved.single.protocol, RemoteProtocol.androidTv);
    });

    test('fábrica escolhe o adapter pelo protocolo', () async {
      final r = device(id: 'r', protocol: RemoteProtocol.roku, port: 8060);
      await svc.add(r);
      expect(await svc.controller(r), isA<RokuController>());
      expect(svc.startPairing(r), isNull, reason: 'Roku não emparelha');
    });
  });
}
