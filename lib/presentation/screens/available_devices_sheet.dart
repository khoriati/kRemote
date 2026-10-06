import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../domain/entities/connection_state.dart';
import '../../domain/entities/remote_device.dart';
import '../../domain/errors.dart';
import 'add_device_screen.dart';

/// Lista os aparelhos disponíveis agora: cadastrados (com presença
/// verificada periodicamente) e novos encontrados na rede. Aberta
/// automaticamente quando o aparelho ativo não responde.
class AvailableDevicesSheet extends StatefulWidget {
  const AvailableDevicesSheet({super.key, this.reason});

  /// Texto explicando por que a lista foi aberta (ex.: aparelho não responde).
  final String? reason;

  static Future<void> show(BuildContext context, {String? reason}) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => AvailableDevicesSheet(reason: reason),
  );

  @override
  State<AvailableDevicesSheet> createState() => _AvailableDevicesSheetState();
}

class _AvailableDevicesSheetState extends State<AvailableDevicesSheet> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final scope = AppScope.of(context);
      scope.devices.watchPresence();
      scope.scanner.watch();
    });
  }

  @override
  void dispose() {
    final scope = AppScope.of(context);
    scope.devices.unwatchPresence();
    scope.scanner.unwatch();
    super.dispose();
  }

  Future<void> _add(DiscoveredDevice d) async {
    final svc = AppScope.of(context).devices;
    try {
      await svc.add(d.toDevice());
    } on RemoteException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([scope.devices, scope.scanner]),
      builder: (context, _) {
        final svc = scope.devices;
        final scanner = scope.scanner;
        final registered = svc.devices;
        final fresh = scanner.found.where((f) => svc.findRegistered(f) == null).toList();
        final atvHosts = fresh.where((d) => d.protocol == RemoteProtocol.androidTv).map((d) => d.host).toSet();
        final newOnes = fresh.where((d) => !(d.protocol == RemoteProtocol.cast && atvHosts.contains(d.host))).toList();
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          minChildSize: 0.35,
          maxChildSize: 0.92,
          builder: (context, controller) => ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              Text('Aparelhos disponíveis', style: Theme.of(context).textTheme.titleLarge),
              if (widget.reason != null) ...[
                const SizedBox(height: 4),
                Text(widget.reason!, style: TextStyle(color: cs.onSurfaceVariant)),
              ],
              const SizedBox(height: 16),
              _Header(
                'Meus dispositivos',
                trailing: scanner.scanning
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : null,
              ),
              if (registered.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text('Nenhum aparelho cadastrado', style: TextStyle(color: cs.onSurfaceVariant)),
                ),
              for (final d in registered)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: PresenceDot(presence: svc.presence(d), size: 14),
                  title: Text(d.name),
                  subtitle: Text('${d.protocol.label} · ${d.protocol.isNetwork ? d.host : ''}'),
                  trailing: svc.active?.id == d.id ? Icon(Icons.check, color: cs.primary) : null,
                  onTap: () {
                    svc.setActive(d.id);
                    Navigator.of(context).pop();
                  },
                ),
              const SizedBox(height: 12),
              const _Header('Novos na rede'),
              if (newOnes.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    scanner.scanning ? 'Procurando…' : 'Nenhum aparelho novo encontrado.',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                ),
              for (final d in newOnes)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(d.protocol == RemoteProtocol.androidTv ? Icons.tv : Icons.cast),
                  title: Text(d.name),
                  subtitle: Text('${d.protocol.label} · ${d.host}'),
                  trailing: const Icon(Icons.add),
                  onTap: () => _add(d),
                ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: scanner.scanning ? null : () => scanner.scan(),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Buscar novamente'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AddDeviceScreen()));
                      },
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Adicionar por IP'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.title, {this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
        ),
      ),
      ?trailing,
    ],
  );
}

/// Indicador de presença na rede: verde (ligado), âmbar (em repouso), cinza
/// (fora da rede), vazio (a verificar).
class PresenceDot extends StatelessWidget {
  const PresenceDot({super.key, required this.presence, this.size = 10});
  final Presence? presence;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = switch (presence) {
      Presence.online => Colors.green,
      Presence.standby => Colors.amber,
      Presence.offline => cs.outline,
      null => Colors.transparent,
    };
    return Semantics(
      label: switch (presence) {
        Presence.online => 'Na rede',
        Presence.standby => 'Em repouso',
        Presence.offline => 'Fora da rede',
        null => 'Verificando',
      },
      child: SizedBox(
        width: size + 8,
        height: size + 8,
        child: Center(
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: presence == null ? Border.all(color: cs.outline, width: 1.5) : null,
            ),
          ),
        ),
      ),
    );
  }
}
