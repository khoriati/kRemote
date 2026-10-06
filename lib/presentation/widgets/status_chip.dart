import 'package:flutter/material.dart';

import '../../domain/entities/connection_state.dart';

/// Indicador compacto do estado de conexão.
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.state, this.paired = true});
  final DeviceConnectionState state;
  final bool paired;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (label, color, icon) = !paired
        ? ('Emparelhar', cs.tertiary, Icons.link_off)
        : switch (state) {
            DeviceConnectionState.connected => ('Conectado', cs.primary, Icons.check_circle),
            DeviceConnectionState.connecting => ('Conectando…', cs.secondary, Icons.sync),
            DeviceConnectionState.needsPairing => ('Emparelhar', cs.tertiary, Icons.link_off),
            DeviceConnectionState.error => ('Falha', cs.error, Icons.error_outline),
            DeviceConnectionState.standby => ('Em repouso', cs.secondary, Icons.bedtime_outlined),
            DeviceConnectionState.disconnected => ('Desconectado', cs.onSurfaceVariant, Icons.radio_button_unchecked),
          };
    return Semantics(
      label: 'Estado: $label',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(999)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
