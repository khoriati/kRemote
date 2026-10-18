import '../entities/remote_device.dart';

/// Porta de saída: identifica o protocolo de controle de um host conhecido
/// (ex.: IP digitado pelo usuário) sondando as portas/APIs de cada marca.
abstract class DeviceIdentifier {
  /// Devolve o aparelho identificado em [host] ou `null` se nenhum protocolo
  /// suportado responder.
  Future<DiscoveredDevice?> identify(String host);
}
