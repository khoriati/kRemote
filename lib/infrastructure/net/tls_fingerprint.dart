import 'dart:async';
import 'dart:io';

import '../protocols/android_tv/android_tv_certificate.dart';
import 'log.dart';
import 'tls_trust.dart';

/// Impressão digital (SHA-256 do DER) do certificado que `host:port`
/// apresenta no handshake TLS, ou `null` se não foi possível obtê-la.
///
/// É a identidade forte de uma Google TV / Android TV: independe do IP, do
/// nome amigável e do nome da instância mDNS. O callback de certificado é
/// chamado antes de o servidor validar o nosso, então a leitura funciona
/// mesmo sem identidade emparelhada (o handshake pode falhar depois, sem
/// prejuízo). Com [identity] o handshake completa e a conexão é encerrada
/// logo em seguida, sem trocar mensagens do protocolo.
Future<String?> tlsFingerprint(
  String host,
  int port, {
  ClientIdentity? identity,
  Duration timeout = const Duration(seconds: 3),
}) async {
  String? seen;
  final ctx = SecurityContext(withTrustedRoots: false);
  if (identity != null) {
    ctx
      ..useCertificateChainBytes(identity.certificatePem.codeUnits)
      ..usePrivateKeyBytes(identity.privateKeyPem.codeUnits);
  }
  try {
    final s = await SecureSocket.connect(
      host,
      port,
      context: ctx,
      timeout: timeout,
      onBadCertificate: (cert) {
        seen = TlsTrust.fingerprint(cert);
        return true;
      },
    );
    s.destroy();
  } on SocketException {
    return seen;
  } on TimeoutException {
    return seen;
  } on TlsException {
    // Servidor recusou o nosso certificado: a impressão dele já foi lida.
    return seen;
  } catch (e) {
    KLog.d('tls', 'fingerprint $host:$port: $e');
  }
  return seen;
}
