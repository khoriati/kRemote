import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import '../../domain/errors.dart';
import '../../domain/ports/certificate_pin_store.dart';

/// Política de confiança TLS para dispositivos com certificado autoassinado.
///
/// - Se existe impressão digital fixada para o dispositivo, só ela é aceita.
/// - Se não existe e [trustOnFirstUse] é verdadeiro, o primeiro certificado
///   visto é aceito e fixado ao chamar [commit].
/// - Caso contrário a conexão é recusada.
class TlsTrust {
  TlsTrust({required this.deviceId, required this.store, this.trustOnFirstUse = true});

  final String deviceId;
  final CertificatePinStore store;
  final bool trustOnFirstUse;

  String? _pinned;
  String? _seen;
  bool _loaded = false;

  /// Deve ser chamado antes de abrir a conexão (callbacks TLS são síncronos).
  Future<void> load() async {
    _pinned = await store.read(deviceId);
    _loaded = true;
  }

  static String fingerprint(X509Certificate cert) => crypto.sha256.convert(cert.der).toString();

  /// Callback para `SecureSocket.connect(onBadCertificate:)` e
  /// `HttpClient.badCertificateCallback`.
  bool accept(X509Certificate cert) {
    assert(_loaded, 'TlsTrust.load() deve ser chamado antes da conexão');
    final fp = fingerprint(cert);
    if (_pinned != null) return _pinned == fp;
    if (!trustOnFirstUse) return false;
    _seen = fp;
    return true;
  }

  bool accept3(X509Certificate cert, String host, int port) => accept(cert);

  /// Persiste a impressão digital aceita no primeiro uso.
  Future<void> commit() async {
    if (_pinned == null && _seen != null) {
      await store.write(deviceId, _seen!);
      _pinned = _seen;
    }
  }

  /// Mensagem de erro amigável para falhas de handshake.
  static RemoteException describeHandshakeFailure({required bool hadPin}) => hadPin
      ? const ConnectionException(
          'O certificado do dispositivo mudou. Por segurança a conexão foi recusada; '
          'redefina a confiança do dispositivo se a troca for legítima.',
        )
      : const PairingException('Dispositivo precisa ser emparelhado');

  bool get hasPin => _pinned != null;

  /// [HttpClient] que aplica esta política.
  HttpClient httpClient({Duration timeout = const Duration(seconds: 5)}) => HttpClient()
    ..connectionTimeout = timeout
    ..badCertificateCallback = accept3;
}
