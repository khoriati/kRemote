/// Etapas de um emparelhamento.
enum PairingStage {
  idle,
  connecting,

  /// A TV exibe um código; o usuário deve digitá-lo no app.
  awaitingPin,

  /// A TV exibe um pedido de permissão; o usuário deve aceitar na TV.
  awaitingTvConfirmation,

  /// O usuário deve informar uma credencial pré-configurada (ex.: PSK Sony).
  awaitingSecret,
  success,
  failure,
}

class PairingState {
  const PairingState(this.stage, {this.message});
  final PairingStage stage;
  final String? message;

  @override
  String toString() => 'PairingState($stage, $message)';
}

/// Porta de saída: conduz o emparelhamento com um dispositivo e devolve as
/// credenciais a persistir.
abstract class PairingFlow {
  Stream<PairingState> get state;

  Future<void> start();

  /// Envia PIN/segredo digitado pelo usuário. Só válido em
  /// [PairingStage.awaitingPin] / [PairingStage.awaitingSecret].
  Future<void> submit(String value);

  Future<void> cancel();

  /// Credenciais obtidas (disponível após [PairingStage.success]).
  Map<String, String>? get credentials;
}
