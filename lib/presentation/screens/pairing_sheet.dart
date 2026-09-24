import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../domain/entities/remote_device.dart';
import '../../domain/ports/pairing_flow.dart';
import '../../infrastructure/net/log.dart';

/// Bottom sheet que conduz o emparelhamento de um dispositivo.
class PairingSheet extends StatefulWidget {
  const PairingSheet({super.key, required this.device});
  final RemoteDevice device;

  /// Retorna `true` quando o emparelhamento foi concluído.
  static Future<bool?> show(BuildContext context, RemoteDevice d) => showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    builder: (_) => PairingSheet(device: d),
  );

  @override
  State<PairingSheet> createState() => _PairingSheetState();
}

class _PairingSheetState extends State<PairingSheet> {
  PairingFlow? _flow;
  StreamSubscription<PairingState>? _sub;
  PairingState _state = const PairingState(PairingStage.connecting);
  final _pin = TextEditingController();
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  void _start() {
    final flow = AppScope.of(context).devices.startPairing(widget.device);
    if (flow == null) {
      Navigator.of(context).pop(true);
      return;
    }
    _flow = flow;
    _sub = flow.state.listen((s) {
      KLog.d('pairing', '${widget.device.name}: ${s.stage.name} ${s.message ?? ''}');
      if (!mounted) return;
      setState(() => _state = s);
      if (s.stage == PairingStage.success) {
        Future<void>.delayed(const Duration(milliseconds: 700), () {
          if (mounted) Navigator.of(context).pop(true);
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _flow?.cancel();
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final stage = _state.stage;
    final isSecret = stage == PairingStage.awaitingSecret;
    final isPin = stage == PairingStage.awaitingPin;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 8, 24, 24 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Emparelhar com ${widget.device.name}', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(widget.device.protocol.label, style: TextStyle(color: cs.onSurfaceVariant)),
          const SizedBox(height: 24),
          Center(
            child: switch (stage) {
              PairingStage.success => Icon(Icons.check_circle, size: 56, color: cs.primary),
              PairingStage.failure => Icon(Icons.error_outline, size: 56, color: cs.error),
              PairingStage.awaitingTvConfirmation => Icon(Icons.tv, size: 56, color: cs.primary),
              PairingStage.awaitingPin || PairingStage.awaitingSecret => Icon(Icons.pin, size: 56, color: cs.primary),
              _ => const SizedBox(width: 48, height: 48, child: CircularProgressIndicator(strokeWidth: 3)),
            },
          ),
          const SizedBox(height: 16),
          Text(
            _state.message ?? _defaultMessage(stage),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          if (isPin || isSecret) ...[
            const SizedBox(height: 20),
            TextField(
              controller: _pin,
              autofocus: true,
              obscureText: isSecret && _obscure,
              textCapitalization: TextCapitalization.characters,
              keyboardType: isSecret ? TextInputType.text : TextInputType.visiblePassword,
              maxLength: isSecret ? 64 : 6,
              style: const TextStyle(fontSize: 26, letterSpacing: 6, fontFamily: 'monospace'),
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                counterText: '',
                hintText: isSecret ? 'Pre-Shared Key' : 'CÓDIGO',
                suffixIcon: isSecret
                    ? IconButton(
                        icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      )
                    : null,
              ),
              onSubmitted: (v) => _flow?.submit(v),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: () => _flow?.submit(_pin.text), child: const Text('Confirmar')),
          ],
          const SizedBox(height: 12),
          if (stage == PairingStage.failure)
            FilledButton.tonal(
              onPressed: () {
                _sub?.cancel();
                _flow?.cancel();
                setState(() => _state = const PairingState(PairingStage.connecting));
                _start();
              },
              child: const Text('Tentar novamente'),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(stage == PairingStage.success ? 'Fechar' : 'Cancelar'),
          ),
        ],
      ),
    );
  }

  String _defaultMessage(PairingStage s) => switch (s) {
    PairingStage.connecting => 'Conectando…',
    PairingStage.awaitingPin => 'Digite o código exibido na TV',
    PairingStage.awaitingTvConfirmation => 'Aceite a solicitação na tela da TV',
    PairingStage.awaitingSecret => 'Informe a chave configurada na TV',
    PairingStage.success => 'Emparelhado!',
    PairingStage.failure => 'Não foi possível emparelhar',
    PairingStage.idle => '',
  };
}
