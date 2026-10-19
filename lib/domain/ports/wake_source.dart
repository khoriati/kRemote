/// Porta de saída: canal capaz de acordar um aparelho em repouso (ex.: o
/// receptor Cast de uma Google TV, que fica ativo em standby).
abstract interface class WakeSource {
  /// Pede ao aparelho que acorde. Conclui quando o pedido foi aceito pelo
  /// canal de repouso; o serviço de controle pode levar alguns segundos.
  Future<void> wakeUp();
}
