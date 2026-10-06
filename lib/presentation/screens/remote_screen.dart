import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_scope.dart';
import '../../app/theme.dart';
import '../../domain/entities/app_shortcut.dart';
import '../../domain/entities/connection_state.dart';
import '../../domain/entities/remote_device.dart';
import '../../domain/entities/remote_key.dart';
import '../../domain/errors.dart';
import '../../domain/ports/remote_controller.dart';
import '../widgets/dpad.dart';
import '../widgets/remote_button.dart';
import '../widgets/status_chip.dart';
import '../../infrastructure/net/log.dart';
import '../../application/device_service.dart';
import 'add_device_screen.dart';
import 'available_devices_sheet.dart';
import 'debug_log_screen.dart';
import 'devices_screen.dart';
import 'pairing_sheet.dart';
import 'settings_screen.dart';

/// Tela principal: seletor de dispositivo + controle.
class RemoteScreen extends StatefulWidget {
  const RemoteScreen({super.key});

  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen> with WidgetsBindingObserver {
  RemoteController? _controller;
  StreamSubscription<DeviceConnectionState>? _sub;
  DeviceConnectionState _state = DeviceConnectionState.disconnected;
  String? _boundId;
  String? _boundHost;
  bool _boundPaired = false;
  bool _pairingOpen = false;
  bool _finderOpen = false;
  bool _recovering = false;

  /// Já listou os disponíveis para a ligação atual (evita reabrir a cada falha).
  bool _autoListed = false;
  int _panel = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bind());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Ao voltar do segundo plano os sockets podem ter morrido: reconecta.
    final svc = AppScope.of(context).devices;
    final d = svc.active;
    if (d == null || !svc.isPaired(d) || _state == DeviceConnectionState.connected) return;
    KLog.d('ui', 'app retomado com estado ${_state.name}: reconectando');
    unawaited(_reconnect(auto: true));
  }

  bool get _isCurrent => ModalRoute.of(context)?.isCurrent ?? true;

  /// A ligação precisa ser refeita quando muda o aparelho ativo, o seu
  /// endereço, o estado de emparelhamento ou quando o serviço recriou o
  /// controlador (após emparelhar, atualizar ou redefinir confiança).
  bool _needsBind(DeviceService svc, RemoteDevice? d) {
    if (d == null) return _boundId != null;
    return d.id != _boundId ||
        d.host != _boundHost ||
        svc.isPaired(d) != _boundPaired ||
        !identical(svc.controllerIfCreated(d), _controller);
  }

  Future<void> _bind() async {
    if (!mounted) return;
    final svc = AppScope.of(context).devices;
    final d = svc.active;
    if (!_needsBind(svc, d)) return;
    unawaited(_sub?.cancel());
    _sub = null;
    _controller = null;
    if (d == null) {
      _boundId = null;
      _boundHost = null;
      setState(() => _state = DeviceConnectionState.disconnected);
      return;
    }
    final paired = svc.isPaired(d);
    // Marca antes de qualquer await para evitar bind duplicado no mesmo frame.
    _boundId = d.id;
    _boundHost = d.host;
    _boundPaired = paired;
    _autoListed = false;
    KLog.d('ui', 'ativo: ${d.name} (${d.protocol.name} ${d.host}:${d.port}) emparelhado=$paired');
    setState(() => _state = DeviceConnectionState.disconnected);
    final c = await svc.controller(d);
    if (!mounted || _boundId != d.id || _boundHost != d.host) return;
    setState(() => _controller = c);
    _sub = c.connectionState.listen((s) {
      if (mounted) setState(() => _state = s);
    });
    if (!paired) {
      // Só abre o emparelhamento se esta tela está em primeiro plano: outra
      // tela (ex.: cadastro) pode estar conduzindo o seu próprio fluxo.
      if (_isCurrent) unawaited(_pair(d));
      return;
    }
    unawaited(_reconnect(auto: true));
  }

  /// Conecta ao aparelho ativo. Se ele não responde no endereço gravado,
  /// procura-o na rede (IP mudou após reinício do roteador / troca de Wi-Fi)
  /// e, se ainda assim não o encontra, lista os aparelhos disponíveis.
  Future<void> _reconnect({bool auto = false}) async {
    if (_recovering) return;
    final svc = AppScope.of(context).devices;
    final d = svc.active;
    if (d == null || !svc.isPaired(d)) return;
    _recovering = true;
    try {
      if (await svc.isReachable(d)) {
        try {
          await svc.connect(d);
          return;
        } on PairingException {
          if (mounted && _isCurrent) unawaited(_pair(d));
          return;
        } on RemoteException catch (e) {
          if (!mounted) return;
          _toast(e);
        }
      } else {
        KLog.d('ui', '${d.name} não responde em ${d.host}:${d.port}; procurando na rede');
      }
      final located = await svc.relocate(d);
      if (!mounted) return;
      if (located != null && located.host != d.host) {
        // update() já notificou: a próxima construção refaz a ligação no
        // novo endereço e reconecta.
        _toast(ConnectionException('${d.name} encontrado em ${located.host}'));
        return;
      }
      if (located != null) {
        // Visto na rede no mesmo endereço, mas não conectou: uma nova tentativa.
        try {
          await svc.connect(d);
          return;
        } on PairingException {
          if (mounted && _isCurrent) unawaited(_pair(d));
          return;
        } on RemoteException catch (e) {
          if (mounted) _toast(e);
        }
      }
      if (auto && mounted && _isCurrent && !_autoListed) {
        _autoListed = true;
        unawaited(_showAvailable(reason: '${d.name} não foi encontrado na rede.'));
      }
    } finally {
      _recovering = false;
    }
  }

  Future<void> _showAvailable({String? reason}) async {
    if (_finderOpen || _pairingOpen) return;
    _finderOpen = true;
    try {
      await AvailableDevicesSheet.show(context, reason: reason);
    } finally {
      _finderOpen = false;
    }
  }

  /// Força novo emparelhamento (apaga credenciais e reabre o fluxo).
  Future<void> _repair(RemoteDevice d) async {
    await AppScope.of(context).devices.resetTrust(d.id);
    if (!mounted) return;
    await _bind();
  }

  void _toast(Object e) {
    final msg = e is RemoteException ? e.message : 'Erro: $e';
    KLog.d('ui', 'aviso: $msg');
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _key(RemoteKey k, {KeyPress press = KeyPress.short}) async {
    final svc = AppScope.of(context).devices;
    final d = svc.active;
    if (d == null) return;
    if (!svc.isPaired(d)) {
      unawaited(_pair(d));
      return;
    }
    try {
      await svc.sendKey(d, k, press: press);
    } on PairingException {
      if (mounted) unawaited(_pair(d));
    } on ConnectionException catch (e) {
      if (!mounted) return;
      // Pode ser mudança de IP: tenta reencontrar o aparelho antes de avisar.
      if (!_recovering && !await svc.isReachable(d)) {
        unawaited(_reconnect());
        return;
      }
      _toast(e);
    } catch (e) {
      _toast(e);
    }
  }

  Future<void> _pair(RemoteDevice d) async {
    KLog.d('ui', 'abrir emparelhamento ${d.name} (jaAberto=$_pairingOpen)');
    if (_pairingOpen || _finderOpen) return;
    _pairingOpen = true;
    try {
      final ok = await PairingSheet.show(context, d);
      KLog.d('ui', 'emparelhamento ${d.name} encerrado: ${ok == true ? 'sucesso' : 'cancelado/falha'}');
      if (ok == true && mounted) await _bind();
    } finally {
      _pairingOpen = false;
    }
  }

  bool _supports(RemoteKey k) => _controller?.supportedKeys.contains(k) ?? false;
  bool get _longPress => _controller?.device.protocol == RemoteProtocol.androidTv;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return ListenableBuilder(
      listenable: scope.devices,
      builder: (context, _) {
        final svc = scope.devices;
        final active = svc.active;
        if (_needsBind(svc, active)) WidgetsBinding.instance.addPostFrameCallback((_) => _bind());
        return Scaffold(
          appBar: AppBar(
            title: active == null
                ? const Text('kRemote')
                : _DeviceSwitcher(active: active, devices: svc.devices, onSelect: svc.setActive, onAdd: _openAdd),
            actions: [
              if (active != null)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Center(
                    child: GestureDetector(
                      onTap: () => svc.isPaired(active) ? _reconnect(auto: true) : _pair(active),
                      child: StatusChip(state: _state, paired: svc.isPaired(active)),
                    ),
                  ),
                ),
              IconButton(
                tooltip: 'Diagnóstico',
                icon: const Icon(Icons.bug_report_outlined),
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DebugLogScreen())),
              ),
              PopupMenuButton<String>(
                tooltip: 'Mais',
                onSelected: (v) => switch (v) {
                  'devices' => Navigator.of(
                    context,
                  ).push(MaterialPageRoute<void>(builder: (_) => const DevicesScreen())),
                  'add' => _openAdd(),
                  'available' => _showAvailable(),
                  'pair' => active == null ? null : _repair(active),
                  'settings' => Navigator.of(
                    context,
                  ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
                  _ => null,
                },
                itemBuilder: (_) => [
                  if (active != null && active.protocol.requiresPairing)
                    const PopupMenuItem(
                      value: 'pair',
                      child: ListTile(leading: Icon(Icons.link), title: Text('Emparelhar novamente')),
                    ),
                  const PopupMenuItem(
                    value: 'available',
                    child: ListTile(leading: Icon(Icons.wifi_find), title: Text('Aparelhos disponíveis')),
                  ),
                  const PopupMenuItem(
                    value: 'add',
                    child: ListTile(leading: Icon(Icons.add), title: Text('Adicionar dispositivo')),
                  ),
                  const PopupMenuItem(
                    value: 'devices',
                    child: ListTile(leading: Icon(Icons.devices), title: Text('Meus dispositivos')),
                  ),
                  const PopupMenuItem(
                    value: 'settings',
                    child: ListTile(leading: Icon(Icons.tune), title: Text('Aparência')),
                  ),
                ],
              ),
            ],
          ),
          body: active == null ? _EmptyState(onAdd: _openAdd) : _buildRemote(context, active, scope),
        );
      },
    );
  }

  void _openAdd() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AddDeviceScreen()));

  Widget _buildRemote(BuildContext context, RemoteDevice d, AppScope scope) {
    final haptics = scope.settings.haptics;
    final isHid = d.protocol == RemoteProtocol.bluetoothHid;
    final panels = <String, IconData>{
      'Controle': Icons.gamepad_outlined,
      'Mídia': Icons.play_circle_outline,
      'Números': Icons.dialpad,
      if (!isHid) 'Apps': Icons.apps,
      'Teclado': Icons.keyboard_alt_outlined,
    };
    final panelIndex = _panel.clamp(0, panels.length - 1);
    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: KeyedSubtree(
                key: ValueKey('${d.id}-$panelIndex'),
                child: switch (panels.keys.elementAt(panelIndex)) {
                  'Controle' => _MainPanel(remote: this, haptics: haptics, isHid: isHid),
                  'Mídia' => _MediaPanel(remote: this, haptics: haptics),
                  'Números' => _NumbersPanel(remote: this, haptics: haptics),
                  'Apps' => _AppsPanel(remote: this, device: d),
                  _ => _KeyboardPanel(remote: this, device: d),
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: NavigationBar(
              height: 64,
              selectedIndex: panelIndex,
              onDestinationSelected: (i) => setState(() => _panel = i),
              labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
              destinations: [for (final e in panels.entries) NavigationDestination(icon: Icon(e.value), label: e.key)],
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceSwitcher extends StatelessWidget {
  const _DeviceSwitcher({required this.active, required this.devices, required this.onSelect, required this.onAdd});
  final RemoteDevice active;
  final List<RemoteDevice> devices;
  final void Function(String id) onSelect;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      tooltip: 'Trocar dispositivo',
      position: PopupMenuPosition.under,
      onSelected: (v) => v == '__add' ? onAdd() : onSelect(v),
      itemBuilder: (_) => [
        for (final d in devices)
          PopupMenuItem(
            value: d.id,
            child: ListTile(
              leading: Icon(_iconFor(d.protocol), color: d.id == active.id ? cs.primary : null),
              title: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(d.protocol.label, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: d.id == active.id ? Icon(Icons.check, color: cs.primary) : null,
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: '__add',
          child: ListTile(leading: Icon(Icons.add), title: Text('Adicionar dispositivo')),
        ),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_iconFor(active.protocol), size: 22),
          const SizedBox(width: 8),
          Flexible(child: Text(active.name, overflow: TextOverflow.ellipsis)),
          const Icon(Icons.expand_more),
        ],
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

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});
  final VoidCallback onAdd;

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
              'Adicione sua Google TV, Chromecast ou outra TV da casa para começar.',
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

class _MainPanel extends StatelessWidget {
  const _MainPanel({required this.remote, required this.haptics, required this.isHid});
  final _RemoteScreenState remote;
  final bool haptics;
  final bool isHid;

  RemoteButton _btn(RemoteKey k, IconData icon, String label, {bool accent = false, double size = 64}) => RemoteButton(
    icon: icon,
    semanticLabel: label,
    size: size,
    accent: accent,
    haptics: haptics,
    enabled: remote._supports(k),
    onTap: () => remote._key(k),
    onLongPressStart: remote._longPress ? () => remote._key(k, press: KeyPress.longStart) : null,
    onLongPressEnd: remote._longPress ? () => remote._key(k, press: KeyPress.longEnd) : null,
  );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final dpad = (c.maxWidth * 0.62).clamp(180.0, 260.0);
        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _btn(RemoteKey.power, Icons.power_settings_new, 'Ligar/desligar'),
                  _btn(RemoteKey.input, Icons.input, 'Entrada'),
                  _btn(RemoteKey.assistant, Icons.mic, isHid ? 'Assistente' : 'Google Assistente'),
                ],
              ),
              const SizedBox(height: 20),
              DPad(
                size: dpad,
                onKey: (k) => remote._key(k),
                onLongStart: remote._longPress ? (k) => remote._key(k, press: KeyPress.longStart) : null,
                onLongEnd: remote._longPress ? (k) => remote._key(k, press: KeyPress.longEnd) : null,
                enabled: remote._supports(RemoteKey.ok),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _btn(RemoteKey.back, Icons.arrow_back, 'Voltar'),
                  _btn(RemoteKey.home, Icons.home_outlined, 'Início', accent: true),
                  _btn(RemoteKey.mute, Icons.volume_off_outlined, 'Mudo'),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  RemotePill(
                    topIcon: Icons.add,
                    bottomIcon: Icons.remove,
                    label: 'VOL',
                    enabled: remote._supports(RemoteKey.volumeUp),
                    onTop: () => remote._key(RemoteKey.volumeUp),
                    onBottom: () => remote._key(RemoteKey.volumeDown),
                  ),
                  Column(
                    children: [
                      _btn(RemoteKey.playPause, Icons.play_arrow, 'Reproduzir/pausar'),
                      const SizedBox(height: 22),
                      _btn(
                        isHid ? RemoteKey.exit : RemoteKey.menu,
                        isHid ? Icons.close : Icons.menu,
                        isHid ? 'Esc' : 'Menu',
                      ),
                    ],
                  ),
                  RemotePill(
                    topIcon: Icons.keyboard_arrow_up,
                    bottomIcon: Icons.keyboard_arrow_down,
                    label: isHid ? 'PG' : 'CH',
                    enabled: remote._supports(isHid ? RemoteKey.previous : RemoteKey.channelUp),
                    onTop: () => remote._key(isHid ? RemoteKey.previous : RemoteKey.channelUp),
                    onBottom: () => remote._key(isHid ? RemoteKey.next : RemoteKey.channelDown),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

class _MediaPanel extends StatelessWidget {
  const _MediaPanel({required this.remote, required this.haptics});
  final _RemoteScreenState remote;
  final bool haptics;

  Widget _b(RemoteKey k, IconData i, String l, {double size = 60, bool accent = false}) => RemoteButton(
    icon: i,
    semanticLabel: l,
    size: size,
    accent: accent,
    haptics: haptics,
    enabled: remote._supports(k),
    onTap: () => remote._key(k),
  );

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _b(RemoteKey.previous, Icons.skip_previous, 'Anterior'),
              _b(RemoteKey.rewind, Icons.fast_rewind, 'Retroceder'),
              _b(RemoteKey.playPause, Icons.play_arrow, 'Reproduzir/pausar', size: 76, accent: true),
              _b(RemoteKey.fastForward, Icons.fast_forward, 'Avançar'),
              _b(RemoteKey.next, Icons.skip_next, 'Próximo'),
            ],
          ),
          const SizedBox(height: 28),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _b(RemoteKey.play, Icons.play_arrow_outlined, 'Reproduzir'),
              _b(RemoteKey.pause, Icons.pause, 'Pausar'),
              _b(RemoteKey.stop, Icons.stop, 'Parar'),
              _b(RemoteKey.record, Icons.fiber_manual_record, 'Gravar'),
            ],
          ),
          const SizedBox(height: 36),
          Wrap(
            spacing: 18,
            runSpacing: 18,
            alignment: WrapAlignment.center,
            children: [
              _b(RemoteKey.menu, Icons.menu, 'Menu'),
              _b(RemoteKey.info, Icons.info_outline, 'Informações'),
              _b(RemoteKey.guide, Icons.list_alt, 'Guia'),
              _b(RemoteKey.settings, Icons.settings_outlined, 'Configurações'),
              _b(RemoteKey.captions, Icons.closed_caption_outlined, 'Legendas'),
              _b(RemoteKey.exit, Icons.exit_to_app, 'Sair'),
            ],
          ),
          const SizedBox(height: 36),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final (k, color, l) in [
                (RemoteKey.red, Colors.red, 'Vermelho'),
                (RemoteKey.green, Colors.green, 'Verde'),
                (RemoteKey.yellow, Colors.amber, 'Amarelo'),
                (RemoteKey.blue, Colors.blue, 'Azul'),
              ])
                RemoteButton(
                  size: 52,
                  semanticLabel: l,
                  haptics: haptics,
                  enabled: remote._supports(k),
                  onTap: () => remote._key(k),
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: remote._supports(k) ? color : color.withValues(alpha: 0.3),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _NumbersPanel extends StatelessWidget {
  const _NumbersPanel({required this.remote, required this.haptics});
  final _RemoteScreenState remote;
  final bool haptics;

  @override
  Widget build(BuildContext context) {
    Widget n(RemoteKey k, String label, {IconData? icon}) => RemoteButton(
      label: icon == null ? label : null,
      icon: icon,
      semanticLabel: label,
      size: 72,
      haptics: haptics,
      enabled: remote._supports(k),
      onTap: () => remote._key(k),
    );
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final row in [
              [1, 2, 3],
              [4, 5, 6],
              [7, 8, 9],
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [for (final d in row) n(RemoteKey.fromDigit(d), '$d')],
                ),
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                n(RemoteKey.dash, 'Traço', icon: Icons.remove),
                n(RemoteKey.num0, '0'),
                n(RemoteKey.backspace, 'Apagar', icon: Icons.backspace_outlined),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                RemotePill(
                  topIcon: Icons.keyboard_arrow_up,
                  bottomIcon: Icons.keyboard_arrow_down,
                  label: 'CH',
                  height: 120,
                  enabled: remote._supports(RemoteKey.channelUp),
                  onTop: () => remote._key(RemoteKey.channelUp),
                  onBottom: () => remote._key(RemoteKey.channelDown),
                ),
                n(RemoteKey.enter, 'Enter', icon: Icons.keyboard_return),
                n(RemoteKey.guide, 'Guia', icon: Icons.list_alt),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AppsPanel extends StatefulWidget {
  const _AppsPanel({required this.remote, required this.device});
  final _RemoteScreenState remote;
  final RemoteDevice device;

  @override
  State<_AppsPanel> createState() => _AppsPanelState();
}

class _AppsPanelState extends State<_AppsPanel> {
  /// Apps confirmados como instalados; `null` = não verificável ou ainda não consultado.
  Set<AppShortcut>? _installed;
  bool _checking = false;
  bool _showAll = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  List<AppShortcut> get _supported {
    final c = widget.remote._controller;
    return AppShortcut.all.where((a) => c?.supportsApp(a) ?? false).toList();
  }

  Future<void> _check() async {
    final c = widget.remote._controller;
    if (c == null || _checking) return;
    setState(() => _checking = true);
    try {
      final r = await c.installedApps(_supported);
      if (mounted) setState(() => _installed = r);
    } catch (e) {
      KLog.d('ui', 'verificação de apps: $e');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final supported = _supported;
    if (supported.isEmpty) {
      return Center(
        child: Text(
          'Este dispositivo não permite abrir apps pelo controle.',
          style: TextStyle(color: cs.onSurfaceVariant),
        ),
      );
    }
    final installed = _installed;
    final apps = installed == null || _showAll ? supported : supported.where(installed.contains).toList();
    final hidden = installed == null ? 0 : supported.length - supported.where(installed.contains).length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _checking
                      ? 'Verificando apps instalados…'
                      : installed == null
                      ? 'Atalhos disponíveis para este aparelho'
                      : hidden == 0
                      ? 'Apps instalados no aparelho'
                      : _showAll
                      ? 'Mostrando todos ($hidden não instalados)'
                      : 'Apps instalados ($hidden ocultos)',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                ),
              ),
              if (hidden > 0)
                TextButton(
                  onPressed: () => setState(() => _showAll = !_showAll),
                  child: Text(_showAll ? 'Só instalados' : 'Mostrar todos'),
                ),
              IconButton(
                tooltip: 'Verificar novamente',
                onPressed: _checking ? null : _check,
                icon: const Icon(Icons.refresh, size: 20),
              ),
            ],
          ),
        ),
        Expanded(
          child: apps.isEmpty
              ? Center(
                  child: Text('Nenhum dos atalhos está instalado.', style: TextStyle(color: cs.onSurfaceVariant)),
                )
              : GridView.count(
                  padding: const EdgeInsets.all(24),
                  crossAxisCount: 3,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 0.82,
                  children: [
                    for (final a in apps)
                      _AppTile(
                        app: a,
                        dimmed: installed != null && !installed.contains(a),
                        onTap: () async {
                          try {
                            await AppScope.of(context).devices.launchApp(widget.device, a);
                          } catch (e) {
                            widget.remote._toast(e);
                          }
                        },
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _AppTile extends StatelessWidget {
  const _AppTile({required this.app, required this.onTap, this.dimmed = false});
  final AppShortcut app;
  final VoidCallback onTap;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Abrir ${app.label}',
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Opacity(
          opacity: dimmed ? 0.4 : 1,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Image.asset(
                  app.asset,
                  width: 72,
                  height: 72,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, _, _) => Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    alignment: Alignment.center,
                    child: Text(app.label.substring(0, 1), style: Theme.of(context).textTheme.headlineSmall),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                app.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KeyboardPanel extends StatefulWidget {
  const _KeyboardPanel({required this.remote, required this.device});
  final _RemoteScreenState remote;
  final RemoteDevice device;

  @override
  State<_KeyboardPanel> createState() => _KeyboardPanelState();
}

/// Teclado do controle: modo ABC (letras) e 123 (números/símbolos), cada
/// toque enviado como pressionamento de tecla, igual ao painel Números.
/// Abaixo, campo para enviar uma frase inteira de uma vez.
class _KeyboardPanelState extends State<_KeyboardPanel> {
  static const _alpha = ['qwertyuiop', 'asdfghjkl', 'zxcvbnm'];
  static const _numeric = ['1234567890', '@.-_/', '+=,;\''];

  final _ctrl = TextEditingController();
  bool _sending = false;
  bool _numericMode = false;
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _char(String ch) async {
    if (_busy) return;
    _busy = true;
    try {
      await AppScope.of(context).devices.sendChar(widget.device, ch);
    } catch (e) {
      widget.remote._toast(e);
    } finally {
      _busy = false;
    }
  }

  Future<void> _send() async {
    final text = _ctrl.text;
    if (text.isEmpty) return;
    setState(() => _sending = true);
    try {
      await AppScope.of(context).devices.sendText(widget.device, text);
      _ctrl.clear();
    } catch (e) {
      widget.remote._toast(e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final supported = widget.remote._controller?.capabilities.contains(RemoteCapability.textInput) ?? false;
    final haptics = AppScope.of(context).settings.haptics;
    final cs = Theme.of(context).colorScheme;
    if (!supported) {
      return Center(
        child: Text('Este dispositivo não aceita digitação remota.', style: TextStyle(color: cs.onSurfaceVariant)),
      );
    }
    final rows = _numericMode ? _numeric : _alpha;
    return LayoutBuilder(
      builder: (context, c) {
        final keyW = ((c.maxWidth - 24) / 10 - 4).clamp(26.0, 40.0);
        Widget key(
          String ch, {
          String? label,
          IconData? icon,
          double? width,
          VoidCallback? onTap,
          bool accent = false,
        }) => _KeyCap(
          label: icon == null ? (label ?? ch) : null,
          icon: icon,
          semanticLabel: label ?? ch,
          width: width ?? keyW,
          height: keyW * 1.25,
          accent: accent,
          haptics: haptics,
          onTap: onTap ?? () => _char(ch),
        );
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          child: Column(
            children: [
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Wrap(
                    spacing: 4,
                    alignment: WrapAlignment.center,
                    children: [for (final ch in row.split('')) key(ch)],
                  ),
                ),
              Wrap(
                spacing: 4,
                alignment: WrapAlignment.center,
                children: [
                  key(
                    '',
                    label: _numericMode ? 'ABC' : '123',
                    width: keyW * 1.8,
                    onTap: () => setState(() => _numericMode = !_numericMode),
                  ),
                  key(' ', label: 'espaço', icon: Icons.space_bar, width: keyW * 3.6),
                  key(
                    '',
                    label: 'Apagar',
                    icon: Icons.backspace_outlined,
                    width: keyW * 1.8,
                    onTap: () => widget.remote._key(RemoteKey.backspace),
                  ),
                  key(
                    '',
                    label: 'Enter',
                    icon: Icons.keyboard_return,
                    width: keyW * 1.8,
                    accent: true,
                    onTap: () => widget.remote._key(RemoteKey.enter),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Ou envie uma frase inteira para o campo em foco na TV:',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      enabled: !_sending,
                      maxLength: 200,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(hintText: 'Texto para a TV', counterText: '', isDense: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _sending ? null : _send,
                    icon: const Icon(Icons.send, size: 18),
                    label: const Text('Enviar'),
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

/// Tecla retangular do teclado (largura variável), no estilo dos botões do controle.
class _KeyCap extends StatefulWidget {
  const _KeyCap({
    required this.onTap,
    required this.width,
    required this.height,
    this.label,
    this.icon,
    this.semanticLabel,
    this.accent = false,
    this.haptics = true,
  });
  final VoidCallback onTap;
  final double width;
  final double height;
  final String? label;
  final IconData? icon;
  final String? semanticLabel;
  final bool accent;
  final bool haptics;

  @override
  State<_KeyCap> createState() => _KeyCapState();
}

class _KeyCapState extends State<_KeyCap> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).extension<RemoteButtonStyle>()!;
    final fg = widget.accent ? style.onAccent : style.icon;
    final bg = _pressed
        ? (widget.accent ? style.accent.withValues(alpha: 0.7) : style.fillPressed)
        : (widget.accent ? style.accent : style.fill);
    return Semantics(
      button: true,
      label: widget.semanticLabel ?? widget.label,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: () {
          if (widget.haptics) HapticFeedback.lightImpact();
          widget.onTap();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          width: widget.width,
          height: widget.height,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
            border: style.border == BorderSide.none ? null : Border.fromBorderSide(style.border),
          ),
          child: widget.icon != null
              ? Icon(widget.icon, size: widget.height * 0.5, color: fg)
              : Text(
                  widget.label ?? '',
                  style: TextStyle(color: fg, fontSize: widget.height * 0.42, fontWeight: FontWeight.w600),
                ),
        ),
      ),
    );
  }
}
