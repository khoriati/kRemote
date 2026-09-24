import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kremote/domain/entities/app_shortcut.dart';
import 'package:kremote/domain/entities/connection_state.dart';
import 'package:kremote/domain/entities/remote_device.dart';
import 'package:kremote/domain/entities/remote_key.dart';
import 'package:kremote/domain/errors.dart';
import 'package:kremote/domain/ports/pairing_flow.dart';
import 'package:kremote/infrastructure/net/protobuf.dart';
import 'package:kremote/infrastructure/net/tls_trust.dart';
import 'package:kremote/infrastructure/protocols/android_tv/android_tv_certificate.dart';
import 'package:kremote/infrastructure/protocols/android_tv/android_tv_controller.dart';
import 'package:kremote/infrastructure/protocols/android_tv/android_tv_keys.dart';
import 'package:kremote/infrastructure/protocols/android_tv/android_tv_pairing.dart';
import 'package:kremote/infrastructure/protocols/base_controller.dart';

import '../support/fake_android_tv.dart';
import '../support/fakes.dart';

void main() {
  // Geração RSA-2048 é cara; compartilhada entre os testes.
  late ClientIdentity client;
  late ClientIdentity tv;
  setUpAll(() {
    client = ClientIdentity.generate();
    tv = ClientIdentity.generate(commonName: 'atvremote');
  });

  group('ClientIdentity', () {
    test('gera par RSA-2048 com e=65537 e PEMs aceitos pelo SecurityContext', () {
      final n = client.publicNumbers;
      expect(n.modulus.bitLength, 2048);
      expect(n.exponent, BigInt.from(65537));
      expect(client.certificatePem, contains('BEGIN CERTIFICATE'));
      expect(client.privateKeyPem, contains('BEGIN PRIVATE KEY'));
      final ctx = SecurityContext(withTrustedRoots: false)
        ..useCertificateChainBytes(client.certificatePem.codeUnits)
        ..usePrivateKeyBytes(client.privateKeyPem.codeUnits);
      expect(ctx, isNotNull);
    });

    test('serializa/desserializa credenciais', () {
      final restored = ClientIdentity.fromCredentials(client.toCredentials());
      expect(restored?.certificatePem, client.certificatePem);
      expect(ClientIdentity.fromCredentials({'x': 'y'}), isNull);
      expect(ClientIdentity.fromCredentials(null), isNull);
    });

    test('minimalBytes remove zeros à esquerda', () {
      expect(RsaPublicNumbers.minimalBytes(BigInt.from(65537)), [1, 0, 1]);
      expect(RsaPublicNumbers.minimalBytes(BigInt.from(0xAB)), [0xAB]);
    });
  });

  group('PairingSecret', () {
    test('aceita PIN cujo prefixo confere com o hash e rejeita os demais', () {
      final c = RsaPublicNumbers(BigInt.parse('C0FFEE', radix: 16), BigInt.from(65537));
      final s = RsaPublicNumbers(BigInt.parse('BADC0DE', radix: 16), BigInt.from(3));
      // Descobre um PIN válido por força bruta sobre o primeiro byte.
      String? valid;
      for (var check = 0; check < 256 && valid == null; check++) {
        final pin = '${check.toRadixString(16).padLeft(2, '0')}1a2b';
        try {
          PairingSecret.compute(client: c, server: s, pin: pin);
          valid = pin;
        } on PairingException {
          // continua
        }
      }
      expect(valid, isNotNull);
      final hash = PairingSecret.compute(client: c, server: s, pin: valid!.toUpperCase());
      expect(hash.length, 32);
      expect(hash[0], int.parse(valid.substring(0, 2), radix: 16));
      expect(() => PairingSecret.compute(client: c, server: s, pin: 'ZZZZZZ'), throwsA(isA<PairingException>()));
      expect(() => PairingSecret.compute(client: c, server: s, pin: '12'), throwsA(isA<PairingException>()));
    });
  });

  group('PairingMessages / RemoteMessages', () {
    test('PairingRequest tem versão 2, status 200 e nomes corretos', () {
      final frame = ProtoReader.takeVarintFrame(PairingMessages.pairingRequest('kRemote').toList())!;
      final m = ProtoReader(frame).readAll();
      expect(m[1]!.asInt, 2);
      expect(m[2]!.asInt, 200);
      final req = m[10]!.asMessage.readAll();
      expect(req[1]!.asString, 'androidtvremote');
      expect(req[2]!.asString, 'kRemote');
    });

    test('PairingOption/Configuration usam HEXADECIMAL(3), 6 símbolos, papel INPUT', () {
      final opt = ProtoReader(
        ProtoReader.takeVarintFrame(PairingMessages.pairingOption().toList())!,
      ).readAll()[20]!.asMessage.readAll();
      final enc = opt[1]!.asMessage.readAll();
      expect(enc[1]!.asInt, 3);
      expect(enc[2]!.asInt, 6);
      expect(opt[3]!.asInt, 1);
      final cfg = ProtoReader(
        ProtoReader.takeVarintFrame(PairingMessages.pairingConfiguration().toList())!,
      ).readAll()[30]!.asMessage.readAll();
      expect(cfg[2]!.asInt, 1);
    });

    test('keyInject codifica código e direção', () {
      final m = ProtoReader(ProtoReader.takeVarintFrame(RemoteMessages.keyInject(164, 3).toList())!).readAll();
      final k = m[10]!.asMessage.readAll();
      expect(k[1]!.asInt, 164);
      expect(k[2]!.asInt, 3);
    });

    test('configure responde com código 622', () {
      final m = ProtoReader(ProtoReader.takeVarintFrame(RemoteMessages.configure().toList())!).readAll();
      expect(m[1]!.asMessage.readAll()[1]!.asInt, 622);
      final a = ProtoReader(ProtoReader.takeVarintFrame(RemoteMessages.setActive().toList())!).readAll();
      expect(a[2]!.asMessage.readAll()[1]!.asInt, 622);
    });
  });

  group('Mapa de teclas Android TV', () {
    test('cobre todas as teclas do domínio (Google TV é o caminho crítico)', () {
      for (final k in RemoteKey.values) {
        expect(androidTvKeyCodes.containsKey(k), isTrue, reason: 'falta ${k.name}');
      }
    });
    test('códigos essenciais do controle Chromecast', () {
      expect(androidTvKeyCodes[RemoteKey.ok], 23);
      expect(androidTvKeyCodes[RemoteKey.back], 4);
      expect(androidTvKeyCodes[RemoteKey.home], 3);
      expect(androidTvKeyCodes[RemoteKey.volumeUp], 24);
      expect(androidTvKeyCodes[RemoteKey.mute], 164);
      expect(androidTvKeyCodes[RemoteKey.power], 26);
    });
    test('texto para key codes', () {
      expect(androidTvKeyCodeForChar('a'), 29);
      expect(androidTvKeyCodeForChar('Z'), 54);
      expect(androidTvKeyCodeForChar('0'), 7);
      expect(androidTvKeyCodeForChar(' '), 62);
      expect(androidTvKeyCodeForChar('ç'), isNull);
    });
  });

  group('Emparelhamento ponta a ponta (servidor falso, TLS mútuo)', () {
    test('conclui com PIN correto e fixa o certificado da TV', () async {
      final server = FakePairingServer(tv, trustedClientPem: client.certificatePem);
      await server.start();
      addTearDown(server.close);
      final pins = MemoryPinStore();
      final dev = device(pairingPort: server.port);
      final flow = AndroidTvPairingFlow(
        dev,
        TlsTrust(deviceId: dev.id, store: pins),
        identity: client,
      );
      final stages = <PairingStage>[];
      final done = Completer<void>();
      flow.state.listen((s) {
        stages.add(s.stage);
        if (s.stage == PairingStage.awaitingPin) server.pin.then(flow.submit);
        if (s.stage == PairingStage.success || s.stage == PairingStage.failure) done.complete();
      });
      await flow.start();
      await done.future.timeout(const Duration(seconds: 15));
      expect(stages.last, PairingStage.success, reason: stages.toString());
      expect(server.received, [10, 20, 30, 40]);
      expect(server.lastSecretStatus, 200);
      expect(flow.credentials, isNotNull);
      expect(pins.pins[dev.id], TlsTrust.fingerprint(X509CertificateFake(tv)));
    });

    test('PIN errado é rejeitado localmente sem enviar segredo', () async {
      final server = FakePairingServer(tv, trustedClientPem: client.certificatePem);
      await server.start();
      addTearDown(server.close);
      final dev = device(pairingPort: server.port);
      final flow = AndroidTvPairingFlow(
        dev,
        TlsTrust(deviceId: dev.id, store: MemoryPinStore()),
        identity: client,
      );
      final awaiting = Completer<void>();
      final messages = <String?>[];
      flow.state.listen((s) {
        messages.add(s.message);
        if (s.stage == PairingStage.awaitingPin && !awaiting.isCompleted) awaiting.complete();
      });
      await flow.start();
      await awaiting.future.timeout(const Duration(seconds: 10));
      final pin = await server.pin;
      final wrong =
          '${((int.parse(pin.substring(0, 2), radix: 16) + 1) % 256).toRadixString(16).padLeft(2, '0')}${pin.substring(2)}';
      await flow.submit(wrong);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(server.received, isNot(contains(40)));
      expect(messages.last, contains('Código incorreto'));
      await flow.cancel();
    });

    test('certificado da TV diferente do fixado é recusado', () async {
      final server = FakePairingServer(tv, trustedClientPem: client.certificatePem);
      await server.start();
      addTearDown(server.close);
      final pins = MemoryPinStore()..pins['dev-1'] = 'f' * 64;
      final dev = device(pairingPort: server.port);
      final flow = AndroidTvPairingFlow(
        dev,
        TlsTrust(deviceId: dev.id, store: pins),
        identity: client,
      );
      final result = flow.state.firstWhere((s) => s.stage == PairingStage.failure);
      await flow.start();
      final s = await result.timeout(const Duration(seconds: 10));
      expect(s.message, contains('certificado do dispositivo mudou'));
    });
  });

  group('Controle ponta a ponta (servidor falso)', () {
    test('handshake configure/set_active/ping e envio de tecla e app', () async {
      final server = FakeRemoteServer(tv, trustedClientPem: client.certificatePem);
      await server.start();
      addTearDown(server.close);
      final dev = device(port: server.port);
      final c = AndroidTvController(dev, client, TlsTrust(deviceId: dev.id, store: MemoryPinStore()));
      addTearDown(c.dispose);
      await c.connect();
      expect(c.currentState, DeviceConnectionState.connected);
      await server.configured.future.timeout(const Duration(seconds: 5));
      await server.activated.future.timeout(const Duration(seconds: 5));
      expect(await server.ponged.future.timeout(const Duration(seconds: 5)), 42);

      await c.sendKey(RemoteKey.mute);
      await c.sendKey(RemoteKey.up, press: KeyPress.longStart);
      await c.sendKey(RemoteKey.up, press: KeyPress.longEnd);
      await c.launchApp(AppShortcut.youtube);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(server.keyInjects, [(164, 3), (19, 1), (19, 2)]);
      expect(server.appLinks, ['https://www.youtube.com']);
      expect(c.supportedKeys, containsAll(RemoteKey.values));
      expect(c.supportsApp(AppShortcut.globoplay), isTrue);
    });

    test('cliente não confiável pela TV cai em needsPairing', () async {
      final other = ClientIdentity.generate();
      final server = FakeRemoteServer(tv, trustedClientPem: other.certificatePem);
      await server.start();
      addTearDown(server.close);
      final dev = device(port: server.port);
      final c = AndroidTvController(dev, client, TlsTrust(deviceId: dev.id, store: MemoryPinStore()));
      addTearDown(c.dispose);
      await expectLater(c.connect(), throwsA(isA<PairingException>()));
      expect(c.currentState, DeviceConnectionState.needsPairing);
    });

    test('volume é delegado ao Cast quando volumeViaCast está ativo, com fallback para tecla', () async {
      final server = FakeRemoteServer(tv, trustedClientPem: client.certificatePem);
      await server.start();
      addTearDown(server.close);
      final dev = RemoteDevice(
        id: 'dev-1',
        name: 'TV',
        host: '127.0.0.1',
        port: server.port,
        protocol: RemoteProtocol.androidTv,
        volumeViaCast: true,
      );
      final cast = _RecordingController(dev);
      final c = AndroidTvController(
        dev,
        client,
        TlsTrust(deviceId: dev.id, store: MemoryPinStore()),
        volumeFallback: cast,
      );
      addTearDown(c.dispose);
      await c.sendKey(RemoteKey.volumeUp);
      await c.sendKey(RemoteKey.mute);
      await c.sendKey(RemoteKey.home);
      expect(cast.keys, [RemoteKey.volumeUp, RemoteKey.mute]);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(server.keyInjects, [(3, 3)], reason: 'só a tecla home foi injetada');

      cast.fail = true;
      await c.sendKey(RemoteKey.volumeDown);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(server.keyInjects.last, (25, 3), reason: 'Cast falhou → injeta tecla');
    });

    test('sem identidade emparelhada vai direto para needsPairing, sem rede', () async {
      final dev = device(port: 1);
      final c = AndroidTvController(dev, null, TlsTrust(deviceId: dev.id, store: MemoryPinStore()));
      addTearDown(c.dispose);
      await expectLater(c.connect(), throwsA(isA<PairingException>()));
      expect(c.currentState, DeviceConnectionState.needsPairing);
    });

    test('tecla sem conexão possível gera ConnectionException', () async {
      final dev = device(port: 1); // porta fechada
      final c = AndroidTvController(dev, client, TlsTrust(deviceId: dev.id, store: MemoryPinStore()));
      addTearDown(c.dispose);
      await expectLater(c.sendKey(RemoteKey.home), throwsA(isA<RemoteException>()));
    });
  });
}

/// Certificado X509 mínimo para calcular a impressão digital esperada.
class X509CertificateFake implements X509Certificate {
  X509CertificateFake(this.identity);
  final ClientIdentity identity;
  @override
  Uint8List get der {
    final body = identity.certificatePem
        .split(RegExp(r'\r?\n'))
        .where((l) => l.isNotEmpty && !l.startsWith('-----'))
        .join();
    return Uint8List.fromList(const Base64Decoder().convert(body));
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Controlador que só registra teclas (simula o Cast).
class _RecordingController extends BaseRemoteController {
  _RecordingController(super.device);
  final keys = <RemoteKey>[];
  bool fail = false;
  @override
  Set<RemoteKey> get supportedKeys => RemoteKey.values.toSet();
  @override
  Set<RemoteCapability> get capabilities => const {};
  @override
  Future<void> connect() async => setState(DeviceConnectionState.connected);
  @override
  Future<void> disconnect() async => setState(DeviceConnectionState.disconnected);
  @override
  Future<void> sendKey(RemoteKey key, {KeyPress press = KeyPress.short}) async {
    if (fail) throw const ConnectionException('cast indisponível');
    keys.add(key);
  }
}
