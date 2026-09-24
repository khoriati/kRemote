import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../infrastructure/net/log.dart';

/// Diagnóstico: últimas mensagens de log do app, com cópia para a área de
/// transferência. Não contém credenciais, PINs nem certificados.
class DebugLogScreen extends StatefulWidget {
  const DebugLogScreen({super.key});

  @override
  State<DebugLogScreen> createState() => _DebugLogScreenState();
}

class _DebugLogScreenState extends State<DebugLogScreen> {
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = KLog.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: KLog.dump()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Log copiado')));
  }

  @override
  Widget build(BuildContext context) {
    final entries = KLog.entries.reversed.toList();
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnóstico'),
        actions: [
          const IconButton(tooltip: 'Limpar', onPressed: KLog.clear, icon: Icon(Icons.delete_outline)),
          IconButton(tooltip: 'Copiar', onPressed: _copy, icon: const Icon(Icons.copy)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _copy,
        icon: const Icon(Icons.copy),
        label: const Text('Copiar'),
      ),
      body: entries.isEmpty
          ? Center(
              child: Text('Sem mensagens ainda', style: TextStyle(color: cs.onSurfaceVariant)),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
              itemCount: entries.length,
              itemBuilder: (context, i) {
                final e = entries[i];
                final isError = RegExp('falh|erro|error|exception|recus', caseSensitive: false).hasMatch(e.message);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: SelectableText.rich(
                    TextSpan(
                      style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: cs.onSurface, height: 1.35),
                      children: [
                        TextSpan(
                          text: '${e.format().substring(0, 12)} ',
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                        TextSpan(
                          text: '[${e.scope}] ',
                          style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600),
                        ),
                        TextSpan(
                          text: e.message,
                          style: isError ? TextStyle(color: cs.error) : null,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
