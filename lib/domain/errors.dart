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

class PairingException extends RemoteException {
  const PairingException(super.message);
}

class UnsupportedKeyException extends RemoteException {
  UnsupportedKeyException(Object key) : super('Tecla não suportada: $key');
}

class ProtocolException extends RemoteException {
  const ProtocolException(super.message);
}
