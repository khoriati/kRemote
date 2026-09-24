import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../domain/entities/remote_device.dart';
import 'add_device_screen.dart';
import 'pairing_sheet.dart';

/// Gestão dos dispositivos cadastrados.
class DevicesScreen extends StatelessWidget {
  const DevicesScreen({super.key});

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
              return Card(
                child: ListTile(
                  leading: Icon(Icons.tv, color: isActive ? Theme.of(context).colorScheme.primary : null),
                  title: Text(d.name),
                  subtitle: Text(
                    '${d.protocol.label}\n${d.protocol.isNetwork ? '${d.host}:${d.port}' : d.host}${svc.isPaired(d) ? '' : ' · não emparelhado'}',
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
