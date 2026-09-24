/// Logger estruturado mínimo, sem dependência de Flutter, para que a camada de
/// protocolo rode também em ferramentas de linha de comando e testes.
///
/// Nunca registre credenciais, tokens, PINs ou certificados.
typedef LogSink = void Function(String scope, String message);

class KLog {
  KLog._();

  static LogSink sink = (_, _) {};

  static void d(String scope, String message) => sink(scope, message);
}
