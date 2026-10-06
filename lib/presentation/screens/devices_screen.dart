import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../application/device_service.dart';
import '../../domain/entities/connection_state.dart';
import '../../domain/entities/remote_device.dart';
import 'add_device_screen.dart';
import 'available_devices_sheet.dart';
import 'pairing_sheet.dart';

/// Gestão dos dispositivos cadastrados, com presença na rede verificada
/// periodicamente enquanto a tela está aberta.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) AppScope.of(context).devices.watchPresence();
    });
  }

  @override
  void dispose() {
    AppScope.of(context).devices.unwatchPresence();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final svc = AppScope.of(context).devices;
    return Scaffold(
      appBar: AppBar(title: const Text('Meus dispositivos')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AddDeviceScreen())),
        icon: const Icon(Icons.add),
        label: const Text('Adicionar'),
      ),
      body: ListenableBuilder(
        listenable: svc,
        builder: (context, _) {
          final list = svc.devices;
          if (list.isEmpty) {
            return Center(
              child: Text(
                'Nenhum dispositivo cadastrado',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final d = list[i];
              final isActive = svc.active?.id == d.id;
              final p = d.protocol.isNetwork ? svc.presence(d) : null;
              final presence = switch (p) {
                Presence.online => ' · na rede',
                Presence.standby => ' · em repouso',
                Presence.offline => ' · fora da rede',
                null => '',
              };
              return Card(
                child: ListTile(
                  leading: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Icon(Icons.tv, color: isActive ? Theme.of(context).colorScheme.primary : null),
                      if (d.protocol.isNetwork) Positioned(right: -8, bottom: -6, child: PresenceDot(presence: p)),
                    ],
                  ),
                  title: Text(d.name),
                  subtitle: Text(
                    '${d.protocol.label}\n${d.protocol.isNetwork ? '${d.host}:${d.port}' : d.host}${svc.isPaired(d) ? '' : ' · não emparelhado'}$presence',
                  ),
                  isThreeLine: true,
                  onTap: () {
                    svc.setActive(d.id);
                    Navigator.of(context).pop();
                  },
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) => _action(context, v, d),
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'rename', child: Text('Renomear')),
                      if (d.protocol.requiresPairing)
                        const PopupMenuItem(value: 'pair', child: Text('Emparelhar novamente')),
                      if (d.protocol == RemoteProtocol.androidTv)
                        PopupMenuItem(
                          value: 'castvol',
                          child: Text(
                            d.volumeViaCast ? 'Volume por tecla (desligar Cast)' : 'Volume via Cast (recomendado)',
                          ),
                        ),
                      if (d.protocol.isNetwork)
                        PopupMenuItem(
                          value: 'mac',
                          child: Text(
                            d.macAddress == null ? 'Definir MAC (ligar pela rede)' : 'Alterar MAC (${d.macAddress})',
                          ),
                        ),
                      const PopupMenuItem(value: 'trust', child: Text('Redefinir confiança (certificado)')),
                      const PopupMenuItem(value: 'delete', child: Text('Remover')),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _action(BuildContext context, String action, RemoteDevice d) async {
    final svc = AppScope.of(context).devices;
    switch (action) {
      case 'rename':
        final ctrl = TextEditingController(text: d.name);
        final name = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Renomear'),
            content: TextField(controller: ctrl, autofocus: true, maxLength: 40),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Salvar')),
            ],
          ),
        );
        if (name != null && name.isNotEmpty) await svc.update(d.copyWith(name: name));
      case 'pair':
        await svc.resetTrust(d.id);
        if (context.mounted) await PairingSheet.show(context, d);
      case 'mac':
        final ctrl = TextEditingController(text: d.macAddress ?? '');
        final mac = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Endereço MAC'),
            content: TextField(
              controller: ctrl,
              autofocus: true,
              autocorrect: false,
              decoration: const InputDecoration(
                hintText: 'AA:BB:CC:DD:EE:FF',
                helperText: 'Chromecast: Configurações › Sistema › Sobre › Status',
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text.trim().toUpperCase()),
                child: const Text('Salvar'),
              ),
            ],
          ),
        );
        if (mac == null) return;
        if (mac.isNotEmpty && !isValidMac(mac)) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('MAC inválido')));
          }
          return;
        }
        await svc.update(mac.isEmpty ? d.copyWith(clearMac: true) : d.copyWith(macAddress: mac));
      case 'castvol':
        await svc.update(d.copyWith(volumeViaCast: !d.volumeViaCast));
      case 'trust':
        final ok = await _confirm(
          context,
          'Redefinir confiança?',
          'As credenciais e a impressão digital do certificado deste aparelho serão apagadas. Será preciso emparelhar de novo.',
        );
        if (ok) await svc.resetTrust(d.id);
      case 'delete':
        final ok = await _confirm(
          context,
          'Remover ${d.name}?',
          'O dispositivo e suas credenciais serão apagados deste celular.',
        );
        if (ok) await svc.remove(d.id);
    }
  }

  Future<bool> _confirm(BuildContext context, String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirmar')),
          ],
        ),
      ) ??
      false;
}
