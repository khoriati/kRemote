import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../application/device_service.dart';
import '../../domain/entities/remote_device.dart';
import '../../domain/errors.dart';

/// Descoberta automática + cadastro manual + computadores Bluetooth.
class AddDeviceScreen extends StatefulWidget {
  const AddDeviceScreen({super.key});

  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends State<AddDeviceScreen> {
  List<({String name, String address})> _bonded = const [];
  String? _btError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Varredura contínua enquanto a tela estiver aberta (heartbeat da lista).
      AppScope.of(context).scanner.watch();
      _loadBluetooth();
    });
  }

  Future<void> _loadBluetooth() async {
    if (!Platform.isAndroid) return;
    final bt = AppScope.of(context).bluetooth;
    try {
      if (!await bt.isSupported()) return;
      if (!await bt.requestPermission()) {
        if (mounted) setState(() => _btError = 'Permissão de Bluetooth negada');
        return;
      }
      final list = await bt.bondedDevices();
      if (mounted) setState(() => _bonded = list);
    } catch (e) {
      if (mounted) setState(() => _btError = 'Bluetooth indisponível');
    }
  }

  @override
  void dispose() {
    AppScope.of(context).scanner.unwatch();
    super.dispose();
  }

  /// Cadastra e volta ao controle, que abre o emparelhamento se necessário
  /// (um único fluxo de emparelhamento por vez).
  Future<void> _add(RemoteDevice d) async {
    final svc = AppScope.of(context).devices;
    try {
      await svc.add(d);
    } on RemoteException catch (e) {
      _snack(e.message);
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final scope = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([scope.scanner, scope.devices]),
      builder: (context, _) => _buildBody(context, cs, scope),
    );
  }

  Widget _buildBody(BuildContext context, ColorScheme cs, AppScope scope) {
    final svc = scope.devices;
    final scanner = scope.scanner;
    final scanning = scanner.scanning || scanner.deepScanning;
    final all = scanner.found;
    final atvHosts = all.where((d) => d.protocol == RemoteProtocol.androidTv).map((d) => d.host).toSet();
    final castModelByHost = {
      for (final d in all)
        if (d.protocol == RemoteProtocol.cast && d.model != null) d.host: d.model!,
    };
    // Chromecast com Google TV anuncia os dois serviços; o Android TV é o completo.
    final found = all.where((d) => !(d.protocol == RemoteProtocol.cast && atvHosts.contains(d.host))).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Adicionar dispositivo'),
        actions: [
          IconButton(
            tooltip: 'Buscar novamente',
            onPressed: scanning ? null : () => scanner.scan(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _SectionHeader(
            title: 'Encontrados na rede',
            trailing: scanning
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : null,
          ),
          if (found.isEmpty && !scanning)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'Nenhum aparelho encontrado. Confira se o celular está no mesmo Wi-Fi da TV, '
                'varra toda a rede ou adicione pelo IP abaixo.',
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
            ),
          for (final d in found)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: Icon(
                  d.protocol == RemoteProtocol.androidTv
                      ? Icons.tv
                      : d.protocol == RemoteProtocol.cast
                      ? Icons.cast
                      : Icons.tv_outlined,
                ),
                title: Text(d.name),
                subtitle: Text('${d.protocol.label} · ${d.host}${d.model != null ? ' · ${d.model}' : ''}'),
                trailing: svc.findRegistered(d) != null ? const Icon(Icons.check) : const Icon(Icons.add),
                onTap: svc.findRegistered(d) != null ? null : () => _add(_withModel(d, castModelByHost).toDevice()),
              ),
            ),
          if (scanner.canScanDeep)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: OutlinedButton.icon(
                onPressed: scanner.deepScanning ? null : () => scanner.scanDeep(),
                icon: scanner.deepScanning
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.radar),
                label: Text(scanner.deepScanning ? 'Varrendo a rede…' : 'Varrer toda a rede'),
              ),
            ),
          if (scanner.canScanDeep)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
              child: Text(
                'Testa as portas de Samsung, LG, Roku, Sony, Philips, Vizio e Google TV em todos os IPs da rede. '
                'Leva cerca de um minuto; útil quando a TV não se anuncia (iPhone, Wi-Fi com isolamento).',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
          const SizedBox(height: 16),
          const _SectionHeader(title: 'Adicionar por IP'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _ManualForm(onSubmit: _add, identify: scanner.canIdentify ? scanner.identify : null),
            ),
          ),
          if (Platform.isAndroid) ...[
            const SizedBox(height: 16),
            const _SectionHeader(title: 'Computadores (teclado Bluetooth)'),
            Card(
              child: Column(
                children: [
                  if (_btError != null) ListTile(leading: const Icon(Icons.bluetooth_disabled), title: Text(_btError!)),
                  for (final b in _bonded)
                    ListTile(
                      leading: const Icon(Icons.laptop_mac),
                      title: Text(b.name),
                      subtitle: const Text('Pareado no sistema'),
                      trailing: const Icon(Icons.add),
                      onTap: () => _add(
                        RemoteDevice(
                          id: 'bt-${b.address.replaceAll(':', '')}',
                          name: b.name,
                          host: b.address,
                          port: 0,
                          protocol: RemoteProtocol.bluetoothHid,
                        ),
                      ),
                    ),
                  ListTile(
                    leading: const Icon(Icons.bluetooth_searching),
                    title: const Text('Parear um novo computador'),
                    subtitle: const Text('Anuncia o celular como teclado por 2 min; conclua o pareamento pelo PC/Mac.'),
                    onTap: () async {
                      final bt = AppScope.of(context).bluetooth;
                      try {
                        await bt.registerApp();
                        await bt.requestDiscoverable();
                      } catch (_) {
                        _snack('Não foi possível ativar o modo teclado');
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Android TV não anuncia modelo via mDNS; herda o `md` do serviço Cast do mesmo host.
DiscoveredDevice _withModel(DiscoveredDevice d, Map<String, String> castModelByHost) {
  if (d.protocol != RemoteProtocol.androidTv || d.model != null) return d;
  final m = castModelByHost[d.host];
  if (m == null) return d;
  return DiscoveredDevice(
    name: d.name,
    host: d.host,
    port: d.port,
    protocol: d.protocol,
    model: m,
    serviceName: d.serviceName,
  );
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

class _ManualForm extends StatefulWidget {
  const _ManualForm({required this.onSubmit, this.identify});
  final Future<void> Function(RemoteDevice) onSubmit;

  /// Sonda o host e devolve o protocolo/nome/MAC detectados (opcional).
  final Future<DiscoveredDevice?> Function(String host)? identify;

  @override
  State<_ManualForm> createState() => _ManualFormState();
}

class _ManualFormState extends State<_ManualForm> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _mac = TextEditingController();
  RemoteProtocol _protocol = RemoteProtocol.androidTv;
  bool _detecting = false;
  String? _detectMessage;

  @override
  void initState() {
    super.initState();
    _port.text = '${_protocol.defaultPort}';
  }

  /// Sonda o IP digitado e preenche tipo, porta, nome, modelo e MAC.
  Future<void> _detect() async {
    final identify = widget.identify;
    final host = _host.text.trim();
    if (identify == null || !isValidHost(host)) {
      setState(() => _detectMessage = 'Digite um IP ou host válido');
      return;
    }
    setState(() {
      _detecting = true;
      _detectMessage = null;
    });
    final d = await identify(host);
    if (!mounted) return;
    setState(() {
      _detecting = false;
      if (d == null) {
        _detectMessage = 'Nenhum protocolo suportado respondeu nesse endereço. Confira se a TV está ligada.';
        return;
      }
      _protocol = d.protocol;
      _port.text = '${d.port}';
      if (_name.text.trim().isEmpty) _name.text = d.name;
      if (d.macAddress != null) _mac.text = d.macAddress!;
      _detectMessage = 'Detectado: ${d.protocol.label}${d.model != null ? ' · ${d.model}' : ''}';
    });
  }

  @override
  void dispose() {
    for (final c in [_name, _host, _port, _mac]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _wantsMac => const {
    RemoteProtocol.androidTv,
    RemoteProtocol.samsungTizen,
    RemoteProtocol.lgWebOs,
    RemoteProtocol.sonyBravia,
    RemoteProtocol.philipsJointSpace,
    RemoteProtocol.roku,
  }.contains(_protocol);

  void _submit() {
    if (!_form.currentState!.validate()) return;
    final host = _host.text.trim();
    final port = int.parse(_port.text.trim());
    widget.onSubmit(
      RemoteDevice(
        id: '${_protocol.name}-${host.replaceAll(RegExp(r'[^A-Za-z0-9]'), '-')}-$port',
        name: _name.text.trim().isEmpty ? '${_protocol.label} ($host)' : _name.text.trim(),
        host: host,
        port: port,
        protocol: _protocol,
        macAddress: _wantsMac && _mac.text.trim().isNotEmpty ? _mac.text.trim().toUpperCase() : null,
        pairingPort: _protocol == RemoteProtocol.androidTv ? 6467 : null,
        volumeViaCast: _protocol == RemoteProtocol.androidTv,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<RemoteProtocol>(
            initialValue: _protocol,
            decoration: const InputDecoration(labelText: 'Tipo de aparelho'),
            items: [
              for (final p in RemoteProtocol.values.where((p) => p.isNetwork))
                DropdownMenuItem(
                  value: p,
                  child: Text(p.label, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (p) {
              if (p == null) return;
              setState(() {
                _protocol = p;
                _port.text = '${p.defaultPort}';
              });
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 12),
            child: Text(
              _protocol.hint,
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
          TextFormField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Nome (opcional)'),
            maxLength: 40,
            buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextFormField(
                  controller: _host,
                  decoration: InputDecoration(
                    labelText: 'IP ou host',
                    suffixIcon: widget.identify == null
                        ? null
                        : _detecting
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                          )
                        : IconButton(
                            tooltip: 'Detectar tipo de aparelho',
                            icon: const Icon(Icons.search),
                            onPressed: _detect,
                          ),
                  ),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  validator: (v) => isValidHost(v ?? '') ? null : 'Endereço inválido',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: _port,
                  decoration: const InputDecoration(labelText: 'Porta'),
                  keyboardType: TextInputType.number,
                  validator: (v) {
                    final n = int.tryParse(v ?? '');
                    return n != null && n > 0 && n < 65536 ? null : 'Inválida';
                  },
                ),
              ),
            ],
          ),
          if (_detectMessage != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
              child: Text(
                _detectMessage!,
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          if (_wantsMac) ...[
            const SizedBox(height: 12),
            TextFormField(
              controller: _mac,
              decoration: const InputDecoration(
                labelText: 'MAC (opcional, para ligar a TV)',
                hintText: 'AA:BB:CC:DD:EE:FF',
              ),
              autocorrect: false,
              validator: (v) => (v == null || v.trim().isEmpty || isValidMac(v)) ? null : 'MAC inválido',
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: _submit, icon: const Icon(Icons.add), label: const Text('Adicionar')),
        ],
      ),
    );
  }
}
