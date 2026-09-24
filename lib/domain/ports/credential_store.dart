/// Porta de saída: armazenamento seguro de credenciais (certificados, tokens).
abstract class CredentialStore {
  Future<Map<String, String>?> read(String deviceId);
  Future<void> write(String deviceId, Map<String, String> credentials);
  Future<void> delete(String deviceId);
}
