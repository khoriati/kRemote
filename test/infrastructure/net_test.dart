import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kremote/domain/errors.dart';
import 'package:kremote/infrastructure/net/tls_trust.dart';
import 'package:kremote/infrastructure/net/wake_on_lan.dart';
import 'package:kremote/infrastructure/protocols/android_tv/android_tv_certificate.dart';

import '../support/fakes.dart';

void main() {
  group('WakeOnLan', () {
    test('magic packet = 6×FF + 16×MAC', () {
      final p = WakeOnLan.magicPacket('aa:bb:cc:dd:ee:ff');
      expect(p.length, 102);
      expect(p.sublist(0, 6), List.filled(6, 0xff));
      expect(p.sublist(6, 12), [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]);
      expect(p.sublist(96, 102), [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]);
    });
    test('aceita separador hífen e rejeita MAC inválido', () {
      expect(WakeOnLan.magicPacket('AA-BB-CC-DD-EE-FF').length, 102);
      expect(() => WakeOnLan.magicPacket('12:34'), throwsArgumentError);
    });
  });

  group('TlsTrust', () {
    late X509Certificate cert;
    late X509Certificate other;
    setUpAll(() async {
      // Obtém certificados X509 reais via handshake local.
      cert = await _serve(ClientIdentity.generate());
      other = await _serve(ClientIdentity.generate());
    });

    test('TOFU: aceita o primeiro e fixa no commit', () async {
      final store = MemoryPinStore();
      final t = TlsTrust(deviceId: 'd', store: store);
      await t.load();
      expect(t.hasPin, isFalse);
      expect(t.accept(cert), isTrue);
      await t.commit();
      expect(store.pins['d'], TlsTrust.fingerprint(cert));
      expect(t.hasPin, isTrue);
    });

    test('com pin, só aceita o mesmo certificado', () async {
      final store = MemoryPinStore()..pins['d'] = TlsTrust.fingerprint(cert);
      final t = TlsTrust(deviceId: 'd', store: store);
      await t.load();
      expect(t.accept(cert), isTrue);
      expect(t.accept(other), isFalse);
      await t.commit();
      expect(store.pins['d'], TlsTrust.fingerprint(cert), reason: 'não sobrescreve');
    });

    test('sem TOFU recusa desconhecidos', () async {
      final t = TlsTrust(deviceId: 'd', store: MemoryPinStore(), trustOnFirstUse: false);
      await t.load();
      expect(t.accept(cert), isFalse);
    });

    test('mensagens de falha distinguem pin divergente de emparelhamento', () {
      expect(TlsTrust.describeHandshakeFailure(hadPin: true), isA<ConnectionException>());
      expect(TlsTrust.describeHandshakeFailure(hadPin: false), isA<PairingException>());
    });
  });
}

Future<X509Certificate> _serve(ClientIdentity id) async {
  final ctx = SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(id.certificatePem.codeUnits)
    ..usePrivateKeyBytes(id.privateKeyPem.codeUnits);
  final server = await SecureServerSocket.bind('127.0.0.1', 0, ctx);
  server.listen((s) => s.destroy());
  final client = await SecureSocket.connect('127.0.0.1', server.port, onBadCertificate: (_) => true);
  final cert = client.peerCertificate!;
  client.destroy();
  await server.close();
  return cert;
}
