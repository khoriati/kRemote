import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kremote/domain/errors.dart';
import 'package:kremote/infrastructure/net/tls_trust.dart';
import 'package:kremote/infrastructure/net/wake_on_lan.dart';
import 'package:kremote/infrastructure/protocols/android_tv/android_tv_certificate.dart';
import 'package:kremote/infrastructure/voice/microphone_voice_source.dart';

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
      expect(TlsTrust.describeHandshakeFailure(pinMismatch: true), isA<DeviceMismatchException>());
      expect(TlsTrust.describeHandshakeFailure(pinMismatch: false), isA<PairingException>());
    });
  });
  group('MicrophoneVoiceSource.downsampleHalf', () {
    test('faz a média de pares e guarda sobras entre chamadas', () {
      Uint8List pcm(List<int> samples) {
        final b = ByteData(samples.length * 2);
        for (var i = 0; i < samples.length; i++) {
          b.setInt16(i * 2, samples[i], Endian.little);
        }
        return b.buffer.asUint8List();
      }

      List<int> read(Uint8List d) => [
        for (var i = 0; i < d.length; i += 2) ByteData.sublistView(d).getInt16(i, Endian.little),
      ];
      final carry = <int>[];
      expect(read(MicrophoneVoiceSource.downsampleHalf(pcm([100, 200, -300, -100]), carry)), [150, -200]);
      expect(carry, isEmpty);
      // 3 amostras: um par completo e uma sobra que casa com a próxima chamada.
      expect(read(MicrophoneVoiceSource.downsampleHalf(pcm([10, 20, 30]), carry)), [15]);
      expect(carry.length, 2);
      expect(read(MicrophoneVoiceSource.downsampleHalf(pcm([50]), carry)), [40]);
      expect(carry, isEmpty);
      expect(read(MicrophoneVoiceSource.downsampleHalf(pcm([32767, 32767]), carry)), [32767]);
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
