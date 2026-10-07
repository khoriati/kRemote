import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../domain/entities/remote_device.dart';
import '../../infrastructure/net/log.dart';

/// Vincula a TV ao celular por Bluetooth (somente Android): o celular se
/// anuncia como teclado HID, o usuário o adiciona nos acessórios da TV e,
/// em seguida, escolhe aqui qual dos aparelhos pareados é a TV. Com isso o
/// Power liga a TV mesmo com o Wi-Fi dela desligado em repouso.
class BluetoothLinkSheet extends StatefulWidget {
  const BluetoothLinkSheet({super.key, required this.device});
  final RemoteDevice device;

  static Future<void> show(BuildContext context, RemoteDevice d) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => BluetoothLinkSheet(device: d),
  );

  @override
  State<BluetoothLinkSheet> createState() => _BluetoothLinkSheetState();
}

class _BluetoothLinkSheetState extends State<BluetoothLinkSheet> {
  List<({String name, String address})> _bonded = const [];
  String? _error;
  bool _advertising = false;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final bt = AppScope.of(context).bluetooth;
    try {
      if (!await bt.isSupported()) throw Exception('Este celular não pode atuar como teclado Bluetooth.');
      if (!await bt.requestPermission()) throw Exception('Permissão de Bluetooth negada.');
      await bt.registerApp();
      await bt.requestDiscoverable();
      if (mounted) setState(() => _advertising = true);
      await _load();
      _refresh = Timer.periodic(const Duration(seconds: 3), (_) => _load());
    } catch (e) {
      KLog.d('bt-link', 'falha: $e');
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _load() async {
    final bt = AppScope.of(context).bluetooth;
    try {
      final list = await bt.bondedDevices();
      if (mounted) setState(() => _bonded = list);
    } catch (e) {
      KLog.d('bt-link', 'bondedDevices: $e');
    }
  }

  Future<void> _link(String address) async {
    final svc = AppScope.of(context).devices;
    await svc.update(widget.device.copyWith(bluetoothAddress: address));
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final current = widget.device.bluetoothAddress;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Ligar pela Bluetooth', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            'Com o Wi-Fi da TV desligado em repouso, só o Bluetooth a acorda — como o controle físico. '
            'O celular fica visível como teclado "kRemote".',
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Text(_error!, style: TextStyle(color: cs.error))
          else ...[
            const _Step(1, 'Na TV, abra Configurações › Controles remotos e acessórios › Adicionar acessório.'),
            const _Step(2, 'Escolha "kRemote" na lista da TV e confirme o pareamento.'),
            const _Step(3, 'Volte aqui e toque na TV na lista abaixo.'),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  'Pareados neste celular',
                  style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (_advertising)
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            if (_bonded.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('Nenhum aparelho pareado ainda.', style: TextStyle(color: cs.onSurfaceVariant)),
              ),
            for (final b in _bonded)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(b.address == current ? Icons.bluetooth_connected : Icons.bluetooth),
                title: Text(b.name),
                subtitle: Text(b.address),
                trailing: b.address == current ? Icon(Icons.check, color: cs.primary) : null,
                onTap: () => _link(b.address),
              ),
          ],
          if (current != null) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () async {
                await AppScope.of(context).devices.update(widget.device.copyWith(clearBluetooth: true));
                if (context.mounted) Navigator.of(context).pop();
              },
              icon: const Icon(Icons.link_off),
              label: const Text('Desvincular Bluetooth'),
            ),
          ],
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(this.n, this.text);
  final int n;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 11,
            backgroundColor: cs.primaryContainer,
            child: Text('$n', style: const TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
