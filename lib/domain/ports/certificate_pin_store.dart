/// Porta de saída: impressões digitais (SHA-256) de certificados TLS fixadas
/// por dispositivo. Implementa confiança no primeiro uso (TOFU) e detecta
/// troca de certificado (possível interceptação) nas conexões seguintes.
abstract class CertificatePinStore {
  Future<String?> read(String deviceId);
  Future<void> write(String deviceId, String sha256Hex);
  Future<void> delete(String deviceId);
}
