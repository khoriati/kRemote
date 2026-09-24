import 'dart:async';
import 'dart:collection';

/// Logger estruturado mínimo, sem dependência de Flutter, para que a camada de
/// protocolo rode também em ferramentas de linha de comando e testes.
///
/// Mantém um buffer circular em memória (exibido na tela de diagnóstico do
/// app). Nunca registre credenciais, tokens, PINs ou certificados.
typedef LogSink = void Function(String scope, String message);

class LogEntry {
  LogEntry(this.time, this.scope, this.message);
  final DateTime time;
  final String scope;
  final String message;

  String format() {
    String two(int n) => n.toString().padLeft(2, '0');
    final t =
        '${two(time.hour)}:${two(time.minute)}:${two(time.second)}.${time.millisecond.toString().padLeft(3, '0')}';
    return '$t [$scope] $message';
  }
}

class KLog {
  KLog._();

  static const maxEntries = 500;
  static final _entries = ListQueue<LogEntry>();
  static final _changes = StreamController<void>.broadcast();

  /// Saída adicional (ex.: `debugPrint` em modo debug).
  static LogSink sink = (_, _) {};

  static List<LogEntry> get entries => List.unmodifiable(_entries);
  static Stream<void> get changes => _changes.stream;

  static void d(String scope, String message) {
    _entries.addLast(LogEntry(DateTime.now(), scope, message));
    while (_entries.length > maxEntries) {
      _entries.removeFirst();
    }
    sink(scope, message);
    if (_changes.hasListener) _changes.add(null);
  }

  static void clear() {
    _entries.clear();
    if (_changes.hasListener) _changes.add(null);
  }

  /// Texto pronto para copiar/enviar.
  static String dump() => _entries.map((e) => e.format()).join('\n');
}
