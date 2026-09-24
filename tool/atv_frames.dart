// Utilitário auxiliar: gera identidade + frame PairingRequest em arquivos, ou
// decodifica um dump de resposta. Usado quando o processo Dart não tem acesso
// à rede local (ex.: macOS sem permissão "Rede local"), delegando o TLS ao
// `openssl s_client`.
//
//   dart run tool/atv_frames.dart gen <dir>
//   dart run tool/atv_frames.dart decode <arquivo>
import 'dart:io';

import 'package:kremote/infrastructure/net/protobuf.dart';
import 'package:kremote/infrastructure/protocols/android_tv/android_tv_certificate.dart';
import 'package:kremote/infrastructure/protocols/android_tv/android_tv_pairing.dart';

void main(List<String> args) {
  switch (args) {
    case ['gen', final dir]:
      final id = ClientIdentity.generate();
      File('$dir/cert.pem').writeAsStringSync(id.certificatePem);
      File('$dir/key.pem').writeAsStringSync(id.privateKeyPem);
      File('$dir/pairing_request.bin').writeAsBytesSync(PairingMessages.pairingRequest('kRemote-probe'));
      File('$dir/pairing_option.bin').writeAsBytesSync(PairingMessages.pairingOption());
      File('$dir/pairing_configuration.bin').writeAsBytesSync(PairingMessages.pairingConfiguration());
      final n = id.publicNumbers;
      stdout.writeln('identidade: modulus=${n.modulus.bitLength} bits, e=${n.exponent}');
    case ['decode', final file]:
      final buf = File(file).readAsBytesSync().toList();
      while (true) {
        final frame = ProtoReader.takeVarintFrame(buf);
        if (frame == null) break;
        final m = ProtoReader(frame).readAll();
        final kind = m.keys
            .where((k) => k >= 10)
            .map(
              (k) => switch (k) {
                11 => 'PairingRequestAck(server_name=${m[11]!.asMessage.readAll()[1]?.asString})',
                20 => 'PairingOption',
                31 => 'PairingConfigurationAck',
                41 => 'PairingSecretAck',
                _ => 'campo $k',
              },
            );
        stdout.writeln('frame: protocol_version=${m[1]?.asInt} status=${m[2]?.asInt} ${kind.join(', ')}');
      }
      if (buf.isNotEmpty) stdout.writeln('bytes residuais: ${buf.length}');
    default:
      stderr.writeln('uso: gen <dir> | decode <arquivo>');
      exit(64);
  }
}
