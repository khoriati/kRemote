import 'dart:convert';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:pointycastle/asn1.dart';

/// Par certificado/chave RSA usado como identidade do cliente no protocolo
/// Android TV Remote v2. A TV associa o certificado ao emparelhamento.
class ClientIdentity {
  const ClientIdentity({required this.certificatePem, required this.privateKeyPem});

  final String certificatePem;
  final String privateKeyPem;

  static const keyCert = 'atv_cert';
  static const keyPrivate = 'atv_key';

  Map<String, String> toCredentials() => {keyCert: certificatePem, keyPrivate: privateKeyPem};

  static ClientIdentity? fromCredentials(Map<String, String>? c) {
    if (c == null || c[keyCert] == null || c[keyPrivate] == null) return null;
    return ClientIdentity(certificatePem: c[keyCert]!, privateKeyPem: c[keyPrivate]!);
  }

  /// Gera um novo certificado autoassinado RSA-2048 válido por 10 anos.
  static ClientIdentity generate({String commonName = 'kRemote'}) {
    final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
    final priv = pair.privateKey as RSAPrivateKey;
    final pub = pair.publicKey as RSAPublicKey;
    final csr = X509Utils.generateRsaCsrPem({'CN': commonName, 'O': 'kRemote', 'C': 'BR'}, priv, pub);
    final cert = X509Utils.generateSelfSignedCertificate(priv, csr, 3650);
    return ClientIdentity(certificatePem: cert, privateKeyPem: CryptoUtils.encodeRSAPrivateKeyToPem(priv));
  }

  /// Módulo e expoente RSA do certificado do cliente.
  RsaPublicNumbers get publicNumbers => RsaPublicNumbers.fromCertificateDer(_pemToDer(certificatePem));

  static Uint8List _pemToDer(String pem) {
    final body = pem
        .split(RegExp(r'\r?\n'))
        .where((l) => l.isNotEmpty && !l.startsWith('-----'))
        .map((l) => l.trim())
        .join();
    return base64.decode(body);
  }
}

/// Módulo e expoente públicos de uma chave RSA, extraídos de um certificado
/// X.509 em DER. Necessários para calcular o segredo do emparelhamento.
class RsaPublicNumbers {
  const RsaPublicNumbers(this.modulus, this.exponent);

  final BigInt modulus;
  final BigInt exponent;

  static RsaPublicNumbers fromCertificateDer(Uint8List der) {
    final cert = ASN1Parser(der).nextObject() as ASN1Sequence;
    final tbs = cert.elements![0] as ASN1Sequence;
    final els = tbs.elements!;
    // version é EXPLICIT [0] opcional: quando presente desloca os índices.
    final hasVersion = els[0].tag == 0xA0;
    final spki = els[hasVersion ? 6 : 5] as ASN1Sequence;
    final bits = spki.elements![1] as ASN1BitString;
    final keySeq = ASN1Parser(Uint8List.fromList(bits.stringValues!)).nextObject() as ASN1Sequence;
    final n = (keySeq.elements![0] as ASN1Integer).integer!;
    final e = (keySeq.elements![1] as ASN1Integer).integer!;
    return RsaPublicNumbers(n, e);
  }

  /// Bytes big-endian mínimos (sem zeros à esquerda), como exige o protocolo.
  static Uint8List minimalBytes(BigInt v) {
    var hex = v.toRadixString(16);
    if (hex.length.isOdd) hex = '0$hex';
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
