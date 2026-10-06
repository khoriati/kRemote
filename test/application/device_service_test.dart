import 'package:flutter_test/flutter_test.dart';
import 'package:kremote/application/device_service.dart';
import 'package:kremote/application/network_scanner.dart';
import 'package:kremote/domain/entities/remote_device.dart';
import 'package:kremote/domain/errors.dart';
import 'package:kremote/domain/ports/device_discovery.dart';
import 'package:kremote/infrastructure/controller_factory.dart';
import 'package:kremote/infrastructure/protocols/android_tv/android_tv_certificate.dart';
import 'package:kremote/infrastructure/protocols/android_tv/android_tv_controller.dart';
import 'package:kremote/infrastructure/protocols/roku/roku_controller.dart';

import '../support/fakes.dart';

void main() {
  relocationTests();
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

class _ScriptedDiscovery implements DeviceDiscovery {
  List<DiscoveredDevice> next = const [];
  @override
  Stream<DiscoveredDevice> discover({Duration timeout = const Duration(seconds: 6)}) =>
      Stream.fromIterable(List.of(next));
}

void relocationTests() {
  group('identidade por certificado (troca de rede, TV homônima, TV renomeada)', () {
    const pinSala = 'aa11';
    late MemoryDeviceRepository repo;
    late MemoryCredentialStore creds;
    late MemoryPinStore pins;
    late _ScriptedDiscovery disc;
    late Map<String, String?> certs; // host → impressão digital
    late DeviceService svc;

    RemoteDevice sala() => const RemoteDevice(
      id: 'androidTv-192-168-1-50-6466',
      name: 'Sala',
      host: '192.168.1.50',
      port: 6466,
      protocol: RemoteProtocol.androidTv,
      pairingPort: 6467,
      serviceName: 'Sala',
    );

    DiscoveredDevice seen(String name, String host) =>
        DiscoveredDevice(name: name, host: host, port: 6466, protocol: RemoteProtocol.androidTv, serviceName: name);

    setUp(() async {
      repo = MemoryDeviceRepository()..saved = [sala()];
      creds = MemoryCredentialStore()..data[sala().id] = ClientIdentity.generate().toCredentials();
      pins = MemoryPinStore()..pins[sala().id] = pinSala;
      disc = _ScriptedDiscovery();
      certs = {};
      svc = DeviceService(
        repository: repo,
        credentials: creds,
        pins: pins,
        factory: ControllerFactory(credentials: creds, pins: pins),
        scanner: NetworkScanner(disc, staleAfter: const Duration(milliseconds: 40)),
        probe: (host, port) async => false,
        fingerprintProbe: (host, port) async => certs[host],
      );
      await svc.load();
    });

    test('TV homônima em outra rede com certificado diferente não é confundida com a cadastrada', () async {
      disc.next = [seen('Sala', '192.168.0.9')];
      certs['192.168.0.9'] = 'outra';
      expect(await svc.relocate(svc.active!), isNull);
      expect(svc.active!.host, '192.168.1.50', reason: 'cadastro intocado');
    });

    test('TV renomeada é reencontrada pelo certificado mesmo sem casar por nome', () async {
      disc.next = [seen('Quarto', '192.168.1.80'), seen('Outra', '192.168.1.81')];
      certs['192.168.1.80'] = pinSala;
      certs['192.168.1.81'] = 'x';
      final moved = await svc.relocate(svc.active!);
      expect(moved?.host, '192.168.1.80');
      expect(moved?.id, sala().id);
      expect(svc.isPaired(moved!), isTrue);
    });

    test('entre duas homônimas, escolhe a que tem o certificado fixado', () async {
      disc.next = [seen('Sala', '192.168.1.60'), seen('Sala', '192.168.1.61')];
      certs['192.168.1.60'] = 'x';
      certs['192.168.1.61'] = pinSala;
      expect((await svc.relocate(svc.active!))?.host, '192.168.1.61');
    });

    test('sem conseguir ler certificados, vale a heurística por nome', () async {
      disc.next = [seen('Sala', '192.168.1.70')];
      expect((await svc.relocate(svc.active!))?.host, '192.168.1.70');
    });

    test('add de aparelho já cadastrado em outro IP atualiza o cadastro em vez de duplicar', () async {
      final added = await svc.add(seen('Sala', '192.168.7.7').toDevice());
      expect(added.id, sala().id, reason: 'mesmo cadastro, mesmas credenciais');
      expect(added.host, '192.168.7.7');
      expect(svc.devices, hasLength(1));
      expect(svc.isPaired(added), isTrue);
      expect(repo.saved.single.host, '192.168.7.7');
    });
  });

  group('relocalização e presença (IP muda após reinício do roteador / troca de Wi-Fi)', () {
    late MemoryDeviceRepository repo;
    late MemoryCredentialStore creds;
    late _ScriptedDiscovery disc;
    late Set<String> reachable;
    late DeviceService svc;

    setUp(() {
      repo = MemoryDeviceRepository();
      creds = MemoryCredentialStore();
      disc = _ScriptedDiscovery();
      reachable = {};
      svc = DeviceService(
        repository: repo,
        credentials: creds,
        pins: MemoryPinStore(),
        factory: ControllerFactory(credentials: creds, pins: MemoryPinStore()),
        scanner: NetworkScanner(disc, staleAfter: const Duration(milliseconds: 40)),
        probe: (host, port) async => reachable.contains('$host:$port'),
      );
    });

    RemoteDevice sala({String host = '192.168.1.50'}) => RemoteDevice(
      id: 'androidTv-192-168-1-50-6466',
      name: 'Sala',
      host: host,
      port: 6466,
      protocol: RemoteProtocol.androidTv,
      pairingPort: 6467,
      serviceName: 'Sala',
    );

    test('relocate atualiza o host mantendo id e credenciais quando o serviço reaparece em outro IP', () async {
      repo.saved = [sala()];
      creds.data['androidTv-192-168-1-50-6466'] = ClientIdentity.generate().toCredentials();
      await svc.load();
      disc.next = [
        const DiscoveredDevice(
          name: 'Sala',
          host: '192.168.1.77',
          port: 6466,
          protocol: RemoteProtocol.androidTv,
          serviceName: 'Sala',
        ),
      ];
      final moved = await svc.relocate(svc.active!);
      expect(moved?.host, '192.168.1.77');
      expect(moved?.id, 'androidTv-192-168-1-50-6466', reason: 'id estável');
      expect(svc.active?.host, '192.168.1.77');
      expect(repo.saved.single.host, '192.168.1.77');
      expect(svc.isPaired(svc.active!), isTrue, reason: 'credenciais seguem válidas');
      expect(svc.isOnline(svc.active!), isTrue);
    });

    test('relocate devolve o próprio aparelho se visto no mesmo IP e null se ausente', () async {
      repo.saved = [sala()];
      await svc.load();
      disc.next = [
        const DiscoveredDevice(name: 'Sala', host: '192.168.1.50', port: 6466, protocol: RemoteProtocol.androidTv),
      ];
      expect((await svc.relocate(svc.active!))?.host, '192.168.1.50');
      disc.next = const [];
      await Future<void>.delayed(const Duration(milliseconds: 60)); // expira o cache do scanner
      expect(await svc.relocate(svc.active!), isNull);
    });

    test('Google TV cadastrado casa também com o anúncio Cast (mesmo aparelho)', () async {
      repo.saved = [sala()];
      await svc.load();
      disc.next = [
        const DiscoveredDevice(
          name: 'Sala',
          host: '192.168.1.60',
          port: 8009,
          protocol: RemoteProtocol.cast,
          serviceName: 'Chromecast-abc',
        ),
      ];
      final moved = await svc.relocate(svc.active!);
      expect(moved?.host, '192.168.1.60');
      expect(moved?.port, 6466, reason: 'porta do protocolo original preservada');
      expect(moved?.serviceName, 'Sala', reason: 'não adota o nome de serviço de outro protocolo');
    });

    test('nome de serviço diferente não casa mesmo com nome amigável igual', () async {
      repo.saved = [sala()];
      await svc.load();
      disc.next = [
        const DiscoveredDevice(
          name: 'Sala',
          host: '192.168.1.99',
          port: 6466,
          protocol: RemoteProtocol.androidTv,
          serviceName: 'Outra',
        ),
      ];
      expect(await svc.relocate(svc.active!), isNull);
    });

    test('findRegistered reconhece aparelho cadastrado mesmo com IP novo', () async {
      repo.saved = [sala()];
      await svc.load();
      const f = DiscoveredDevice(
        name: 'Sala',
        host: '192.168.1.77',
        port: 6466,
        protocol: RemoteProtocol.androidTv,
        serviceName: 'Sala',
      );
      expect(svc.findRegistered(f)?.id, 'androidTv-192-168-1-50-6466');
      const other = DiscoveredDevice(
        name: 'Quarto',
        host: '192.168.1.78',
        port: 6466,
        protocol: RemoteProtocol.androidTv,
      );
      expect(svc.findRegistered(other), isNull);
    });

    test('presença: verifica todos, notifica mudanças e realoca quem está fora', () async {
      repo.saved = [
        sala(),
        device(id: 'roku', name: 'Quarto', host: '192.168.1.51', port: 8060, protocol: RemoteProtocol.roku),
      ];
      await svc.load();
      reachable = {'192.168.1.51:8060'};
      disc.next = [
        const DiscoveredDevice(
          name: 'Sala',
          host: '192.168.1.77',
          port: 6466,
          protocol: RemoteProtocol.androidTv,
          serviceName: 'Sala',
        ),
      ];
      var notified = 0;
      svc.addListener(() => notified++);
      await svc.refreshPresence();
      expect(svc.isOnline(svc.devices.last), isTrue);
      expect(svc.devices.first.host, '192.168.1.77', reason: 'fora da rede → varredura → IP novo');
      expect(svc.isOnline(svc.devices.first), isTrue);
      expect(notified, greaterThan(0));
    });

    test('isReachable usa o probe e registra presença', () async {
      repo.saved = [sala()];
      await svc.load();
      expect(await svc.isReachable(svc.active!), isFalse);
      expect(svc.isOnline(svc.active!), isFalse);
      reachable = {'192.168.1.50:6466'};
      expect(await svc.isReachable(svc.active!), isTrue);
    });

    test('serviceName sobrevive à serialização', () {
      final json = sala().toJson();
      expect(RemoteDevice.fromJson(json).serviceName, 'Sala');
      expect(RemoteDevice.fromJson(json..remove('serviceName')).serviceName, isNull, reason: 'cadastros antigos');
    });
  });
}
