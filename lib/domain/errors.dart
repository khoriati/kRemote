/// Erros de domínio do kRemote.
sealed class RemoteException implements Exception {
  const RemoteException(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

class ConnectionException extends RemoteException {
  const ConnectionException(super.message);
}

/// A TV fechou a conexão durante a abertura da sessão, sem alerta TLS.
/// Transitório (TV acordando, rede trocada, sessão anterior viva); o
/// controlador repete antes de desistir. Nunca é, por si só, "precisa
/// emparelhar".
class ClosedDuringConnectException extends ConnectionException {
  const ClosedDuringConnectException(super.message);
}

class PairingException extends RemoteException {
  const PairingException(super.message);
}

/// O aparelho que responde no endereço gravado não é o cadastrado (o
/// certificado TLS difere do fixado): tipicamente outra TV ocupando o mesmo
/// IP depois de uma troca de rede. Não é motivo para reemparelhar.
class DeviceMismatchException extends RemoteException {
  const DeviceMismatchException(super.message);
}

class UnsupportedKeyException extends RemoteException {
  UnsupportedKeyException(Object key) : super('Tecla não suportada: $key');
}

class ProtocolException extends RemoteException {
  const ProtocolException(super.message);
}
