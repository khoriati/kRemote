import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../application/device_service.dart';
import '../../domain/entities/connection_state.dart';
import '../../domain/entities/remote_device.dart';
import '../../domain/errors.dart';
import 'add_device_screen.dart';
import 'available_devices_sheet.dart';
import 'debug_log_screen.dart';
import 'devices_screen.dart';
import 'remote_screen.dart';
import 'settings_screen.dart';

/// Tela inicial: escolha do aparelho a controlar.
///
/// Em vez de abrir o controle do último aparelho, lista os cadastrados como
/// botões grandes, com a presença verificada em tempo real (heartbeat do
/// `DeviceService`) e ordenados por disponibilidade: ligados primeiro, depois
/// em repouso, depois os que ainda não responderam. Novos aparelhos vistos
/// na rede aparecem logo abaixo para cadastro rápido.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> {
  AppScope? _scope;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = AppScope.of(context);
    if (identical(scope, _scope)) return;
    _unwatch();
    _scope = scope;
    scope.devices.watchPresence();
    scope.scanner.watch();
  }

  void _unwatch() {
    final s = _scope;
    if (s == null) return;
    s.devices.unwatchPresence();
    s.scanner.unwatch();
  }

  @override
  void dispose() {
    // Tela raiz: ao ser desmontada o escopo já não é consultável, por isso a
    // referência é guardada em didChangeDependencies.
    _unwatch();
    _scope = null;
    super.dispose();
  }

  /// Ordem: ligado, em repouso, não verificado (ou sem rede), fora da rede;
  /// empate por nome.
  static int presenceRank(Presence? p, RemoteDevice d) => switch (p) {
    Presence.online => 0,
    Presence.standby => 1,
    null => d.protocol.isNetwork ? 2 : 1,
    Presence.offline => 3,
  };

  static List<RemoteDevice> ordered(DeviceService svc) {
    final list = List.of(svc.devices);
    list.sort((a, b) {
      final ra = presenceRank(svc.presence(a), a);
      final rb = presenceRank(svc.presence(b), b);
      if (ra != rb) return ra.compareTo(rb);
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  void _open(RemoteDevice d) {
    AppScope.of(context).devices.setActive(d.id);
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RemoteScreen()));
  }

  void _push(Widget screen) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  Future<void> _add(DiscoveredDevice f) async {
    final svc = AppScope.of(context).devices;
    try {
      final d = await svc.add(f.toDevice());
      if (mounted) _open(d);
    } on RemoteException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('kRemote'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) => switch (v) {
              'devices' => _push(const DevicesScreen()),
              'settings' => _push(const SettingsScreen()),
              'debug' => _push(const DebugLogScreen()),
              _ => null,
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'devices',
                child: ListTile(leading: Icon(Icons.devices), title: Text('Meus dispositivos')),
              ),
              PopupMenuItem(
                value: 'settings',
                child: ListTile(leading: Icon(Icons.tune), title: Text('Aparência')),
              ),
              PopupMenuItem(
                value: 'debug',
                child: ListTile(leading: Icon(Icons.bug_report), title: Text('Diagnóstico')),
              ),
            ],
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([scope.devices, scope.scanner]),
        builder: (context, _) {
          final svc = scope.devices;
          final scanner = scope.scanner;
          final devices = ordered(svc);
          final fresh = scanner.found.where((f) => svc.findRegistered(f) == null).toList();
          final atvHosts = fresh.where((d) => d.protocol == RemoteProtocol.androidTv).map((d) => d.host).toSet();
          final newOnes = fresh
              .where((d) => !(d.protocol == RemoteProtocol.cast && atvHosts.contains(d.host)))
              .toList();
          if (devices.isEmpty && newOnes.isEmpty) {
            return _Empty(onAdd: () => _push(const AddDeviceScreen()), scanning: scanner.scanning);
          }
          final available = devices.where((d) => presenceRank(svc.presence(d), d) <= 1).length;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              if (devices.isNotEmpty) ...[
                _Header(
                  'Qual aparelho você quer controlar?',
                  subtitle: available == 0
                      ? 'Verificando quem está na rede…'
                      : '$available de ${devices.length} disponível(is) agora',
                ),
                for (final d in devices) _DeviceButton(device: d, presence: svc.presence(d), onTap: () => _open(d)),
              ],
              if (newOnes.isNotEmpty) ...[
                const SizedBox(height: 16),
                _Header(
                  'Novos na rede',
                  subtitle: 'Toque para cadastrar e abrir o controle',
                  trailing: scanner.scanning
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : null,
                ),
                for (final f in newOnes)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: Icon(_iconFor(f.protocol)),
                      title: Text(f.name),
                      subtitle: Text('${f.protocol.label} · ${f.host}'),
                      trailing: const Icon(Icons.add),
                      onTap: () => _add(f),
                    ),
                  ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _push(const AddDeviceScreen()),
                      icon: const Icon(Icons.add),
                      label: const Text('Adicionar dispositivo'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  IconButton.outlined(
                    tooltip: 'Buscar novamente',
                    onPressed: scanner.scanning
                        ? null
                        : () {
                            scanner.scan();
                            svc.refreshPresence();
                          },
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
                child: Text(
                  'Verde: ligado · Âmbar: em repouso (toque para ligar) · Cinza: fora da rede',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DeviceButton extends StatelessWidget {
  const _DeviceButton({required this.device, required this.presence, required this.onTap});
  final RemoteDevice device;
  final Presence? presence;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final offline = presence == Presence.offline;
    final status = switch (presence) {
      Presence.online => 'Ligado · na rede',
      Presence.standby => 'Em repouso · toque para ligar',
      Presence.offline => 'Fora da rede',
      null => device.protocol.isNetwork ? 'Verificando…' : 'Bluetooth',
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: offline ? cs.surfaceContainerLow : cs.surfaceContainerHigh,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(_iconFor(device.protocol), size: 36, color: offline ? cs.outline : cs.primary),
                  if (device.protocol.isNetwork)
                    Positioned(right: -8, bottom: -6, child: PresenceDot(presence: presence, size: 12)),
                ],
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.name,
                      style: text.titleMedium?.copyWith(color: offline ? cs.onSurfaceVariant : null),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${device.protocol.label} · $status',
                      style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.title, {this.subtitle, this.trailing});
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.titleMedium?.copyWith(color: cs.primary)),
                if (subtitle != null) Text(subtitle!, style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onAdd, required this.scanning});
  final VoidCallback onAdd;
  final bool scanning;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.settings_remote, size: 72, color: cs.primary),
            const SizedBox(height: 20),
            Text('Nenhum dispositivo', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              scanning
                  ? 'Procurando TVs na rede…'
                  : 'Adicione sua Google TV, Chromecast ou outra TV da casa para começar.',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Adicionar dispositivo'),
            ),
          ],
        ),
      ),
    );
  }
}

IconData _iconFor(RemoteProtocol p) => switch (p) {
  RemoteProtocol.androidTv => Icons.tv,
  RemoteProtocol.cast => Icons.cast,
  RemoteProtocol.bluetoothHid => Icons.laptop_mac,
  RemoteProtocol.roku => Icons.live_tv,
  _ => Icons.tv_outlined,
};
