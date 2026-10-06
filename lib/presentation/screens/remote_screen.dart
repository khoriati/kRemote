import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
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
      // Antes de concluir falha, sonda também a porta de repouso: uma TV
      // desligada com "standby em rede" responde só nela. Duas sondagens,
      // porque o Wi-Fi da TV em economia de energia perde o primeiro pacote.
      final presence = await svc.probePresence(d, attempts: 2);
      if (!mounted) return;
      if (presence == Presence.standby) {
        KLog.d('ui', '${d.name} em repouso (porta de repouso responde); aguardando Power');
        setState(() => _state = DeviceConnectionState.standby);
        return;
      }
      if (presence == Presence.online) {
        try {
          await svc.connect(d);
          return;
        } on PairingException {
          if (mounted && _isCurrent) unawaited(_pair(d));
          return;
        } on DeviceMismatchException {
          // Outro aparelho ocupa o IP antigo: a TV cadastrada está em outro
          // endereço (ou fora da rede). Nunca é caso de reemparelhar.
          KLog.d('ui', '${d.name}: outro aparelho responde em ${d.host}; procurando a TV pelo certificado');
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
        // Vista na rede no mesmo endereço: se o serviço de controle segue
        // mudo, a TV está em repouso — não é falha e não adianta insistir.
        if (await svc.probePresence(d) != Presence.online) {
          if (!mounted) return;
          KLog.d('ui', '${d.name} anunciada em ${d.host} mas sem serviço de controle: em repouso');
          setState(() => _state = DeviceConnectionState.standby);
          return;
        }
        try {
          await svc.connect(d);
          return;
        } on PairingException {
          if (mounted && _isCurrent) unawaited(_pair(d));
          return;
        } on DeviceMismatchException {
          if (mounted) {
            _toast(ConnectionException('${d.name} não foi encontrado; outro aparelho responde em ${d.host}.'));
          }
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
    } on DeviceMismatchException {
      if (mounted && !_recovering) unawaited(_reconnect());
    } on ConnectionException catch (e) {
      if (!mounted) return;
      if (_recovering) {
        _toast(e);
        return;
      }
      switch (await svc.probePresence(d)) {
        case Presence.standby:
          if (mounted) setState(() => _state = DeviceConnectionState.standby);
          _toast(k == RemoteKey.power ? e : const ConnectionException('TV em repouso. Toque em Power para ligar.'));
        case Presence.offline:
          // Pode ser mudança de IP: tenta reencontrar o aparelho antes de avisar.
          unawaited(_reconnect());
        case Presence.online:
          _toast(e);
      }
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
                      onTap: () => !svc.isPaired(active)
                          ? _pair(active)
                          : _state == DeviceConnectionState.standby
                          ? _key(RemoteKey.power)
                          : _reconnect(auto: true),
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
                  _ => _NumbersPanel(remote: this, haptics: haptics),
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

class _NumbersPanel extends StatefulWidget {
  const _NumbersPanel({required this.remote, required this.haptics});
  final _RemoteScreenState remote;
  final bool haptics;

  @override
  State<_NumbersPanel> createState() => _NumbersPanelState();
}

/// Teclado numérico e, no modo ABC, as letras — tudo pelo mesmo caminho de
/// tecla (`sendKey`), que funciona em qualquer campo da TV.
class _NumbersPanelState extends State<_NumbersPanel> {
  static const _alphaRows = ['qwertyuiop', 'asdfghjkl', 'zxcvbnm'];
  bool _alpha = false;

  @override
  Widget build(BuildContext context) {
    final remote = widget.remote;
    final haptics = widget.haptics;
    Widget n(RemoteKey k, String label, {IconData? icon, double size = 72}) => RemoteButton(
      label: icon == null ? label : null,
      icon: icon,
      semanticLabel: label,
      size: size,
      haptics: haptics,
      enabled: remote._supports(k),
      onTap: () => remote._key(k),
    );
    final lettersSupported = remote._supports(RemoteKey.letterA);
    return LayoutBuilder(
      builder: (context, c) {
        final keyW = ((c.maxWidth - 24) / 10 - 6).clamp(28.0, 44.0);
        Widget letter(RemoteKey k) => RemoteButton(
          label: k.char.toUpperCase(),
          semanticLabel: 'Letra ${k.char.toUpperCase()}',
          size: keyW,
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
                if (_alpha) ...[
                  for (final row in _alphaRows)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Wrap(
                        spacing: 6,
                        alignment: WrapAlignment.center,
                        children: [for (final ch in row.split('')) letter(RemoteKey.fromLetter(ch)!)],
                      ),
                    ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      n(RemoteKey.space, 'Espaço', icon: Icons.space_bar),
                      n(RemoteKey.backspace, 'Apagar', icon: Icons.backspace_outlined),
                      n(RemoteKey.enter, 'Enter', icon: Icons.keyboard_return),
                    ],
                  ),
                ] else ...[
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
                const SizedBox(height: 24),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('123'), icon: Icon(Icons.dialpad)),
                    ButtonSegment(value: true, label: Text('ABC'), icon: Icon(Icons.abc)),
                  ],
                  selected: {_alpha},
                  showSelectedIcon: false,
                  onSelectionChanged: lettersSupported ? (v) => setState(() => _alpha = v.first) : null,
                ),
                if (!lettersSupported)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Este aparelho não aceita letras pelo controle.',
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
