import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/entities/app_shortcut.dart';
import '../domain/entities/remote_device.dart';
import '../domain/entities/remote_key.dart';
import '../domain/errors.dart';
import '../domain/ports/certificate_pin_store.dart';
import '../domain/ports/credential_store.dart';
import '../domain/ports/device_repository.dart';
import '../domain/ports/pairing_flow.dart';
import '../domain/ports/remote_controller.dart';
import '../infrastructure/controller_factory.dart';
import '../infrastructure/net/log.dart';
import '../infrastructure/protocols/base_controller.dart';
import 'network_scanner.dart';

/// Validação de host (IPv4, IPv6 ou hostname RFC 1123) para entrada manual.
bool isValidHost(String host) {
  final h = host.trim();
  if (h.isEmpty || h.length > 253) return false;
  final ipv4 = RegExp(r'^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}$');
  if (ipv4.hasMatch(h)) return true;
  // Algo só com dígitos e pontos é um IPv4 malformado, não um hostname.
  if (RegExp(r'^[\d.]+$').hasMatch(h)) return false;
  if (h.contains(':')) return Uri.tryParse('http://[$h]/')?.host.isNotEmpty ?? false;
  final hostname = RegExp(
    r'^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)*[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$',
  );
  return hostname.hasMatch(h);
}

bool isValidMac(String mac) => RegExp(r'^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$').hasMatch(mac.trim());

/// Verifica se `host:port` aceita conexão TCP (injetado pela infraestrutura).
typedef PortProbe = Future<bool> Function(String host, int port);

/// Caso de uso central: cadastro de dispositivos, dispositivo ativo,
/// ciclo de vida dos controladores e emparelhamento.
class DeviceService extends ChangeNotifier {
  DeviceService({
    required DeviceRepository repository,
    required CredentialStore credentials,
    required CertificatePinStore pins,
    required ControllerFactory factory,
    PortProbe? probe,
    NetworkScanner? scanner,
  }) : _probe = probe, // ignore: prefer_initializing_formals
       _scanner = scanner, // ignore: prefer_initializing_formals
       _repo = repository,
       _creds = credentials,
       // ignore: prefer_initializing_formals
       _pins = pins,
       // ignore: prefer_initializing_formals
       _factory = factory;

  final DeviceRepository _repo;
  final CredentialStore _creds;
  final CertificatePinStore _pins;
  final ControllerFactory _factory;
  final PortProbe? _probe;
  final NetworkScanner? _scanner;

  final List<RemoteDevice> _devices = [];
  final Map<String, RemoteController> _controllers = {};
  final Map<String, bool> _paired = {};
  final Map<String, bool> _online = {};
  String? _activeId;
  bool _loaded = false;

  /// Intervalo mínimo entre varreduras mDNS disparadas pela presença.
  static const relocateCooldown = Duration(seconds: 20);
  Timer? _presenceTimer;
  int _presenceWatchers = 0;
  bool _refreshingPresence = false;
  DateTime? _lastSweep;

  List<RemoteDevice> get devices => List.unmodifiable(_devices);
  bool get isLoaded => _loaded;
  RemoteDevice? get active => _devices.where((d) => d.id == _activeId).firstOrNull ?? _devices.firstOrNull;

  Future<void> load() async {
    _devices
      ..clear()
      ..addAll(await _repo.loadAll());
    for (final d in _devices) {
      _paired[d.id] = _factory.hasPairedCredentials(await _creds.read(d.id), d.protocol);
    }
    _loaded = true;
    notifyListeners();
    unawaited(_promoteCastDevices());
    // Pré-gera a identidade Android TV em segundo plano para emparelhar sem espera.
    unawaited(
      _factory.appIdentity().then(
        (_) {},
        onError: (Object e) => KLog.d('identity', 'falha ao preparar identidade: $e'),
      ),
    );
  }

  bool isPaired(RemoteDevice d) => !d.protocol.requiresPairing || (_paired[d.id] ?? false);

  /// Migração: receptores Cast já cadastrados que também são Google TV
  /// passam a ser controlados pelo protocolo completo.
  Future<void> _promoteCastDevices() async {
    final probe = _probe;
    if (probe == null) return;
    for (final d in List.of(_devices.where((d) => d.protocol == RemoteProtocol.cast))) {
      if (!await probe(d.host, RemoteProtocol.androidTv.defaultPort)) continue;
      final promoted = DiscoveredDevice(
        name: d.name,
        host: d.host,
        port: 6466,
        protocol: RemoteProtocol.androidTv,
        model: d.model,
      ).toDevice();
      if (_devices.any((e) => e.id == promoted.id)) continue;
      KLog.d('devices', '${d.name}: promovido de Cast para Google TV');
      final i = _devices.indexOf(d);
      await _disposeController(d.id);
      _devices[i] = promoted;
      _paired[promoted.id] = _factory.hasPairedCredentials(await _creds.read(promoted.id), promoted.protocol);
      if (_activeId == d.id) _activeId = promoted.id;
      await _repo.saveAll(_devices);
      notifyListeners();
    }
  }

  /// Cadastra o aparelho. Um receptor Cast cujo host também atende na porta
  /// do Android TV Remote (6466) é promovido a Google TV: o Chromecast com
  /// Google TV anuncia os dois serviços e só o Android TV dá controle completo.
  Future<RemoteDevice> add(RemoteDevice input) async {
    var d = input;
    if (d.protocol.isNetwork && !isValidHost(d.host)) throw const ConnectionException('Endereço inválido');
    if (d.macAddress != null && d.macAddress!.isNotEmpty && !isValidMac(d.macAddress!)) {
      throw const ConnectionException('MAC inválido');
    }
    if (d.protocol == RemoteProtocol.cast &&
        _probe != null &&
        await _probe(d.host, RemoteProtocol.androidTv.defaultPort)) {
      KLog.d('devices', '${d.name}: porta 6466 aberta → cadastrando como Google TV');
      d = DiscoveredDevice(
        name: d.name,
        host: d.host,
        port: 6466,
        protocol: RemoteProtocol.androidTv,
        model: d.model,
      ).toDevice();
    }
    _devices.removeWhere((e) => e.id == d.id);
    _devices.add(d);
    _paired[d.id] = _factory.hasPairedCredentials(await _creds.read(d.id), d.protocol);
    _activeId = d.id;
    await _repo.saveAll(_devices);
    notifyListeners();
    return d;
  }

  Future<void> update(RemoteDevice d) async {
    final i = _devices.indexWhere((e) => e.id == d.id);
    if (i < 0) return;
    _devices[i] = d;
    await _disposeController(d.id);
    await _repo.saveAll(_devices);
    notifyListeners();
  }

  Future<void> remove(String id) async {
    _devices.removeWhere((e) => e.id == id);
    await _disposeController(id);
    await _creds.delete(id);
    await _pins.delete(id);
    await _pins.delete('$id-cast');
    _paired.remove(id);
    _online.remove(id);
    if (_activeId == id) _activeId = _devices.firstOrNull?.id;
    await _repo.saveAll(_devices);
    notifyListeners();
  }

  /// Esquece credenciais e pin TLS, exigindo novo emparelhamento.
  Future<void> resetTrust(String id) async {
    await _disposeController(id);
    await _creds.delete(id);
    await _pins.delete(id);
    await _pins.delete('$id-cast');
    _paired[id] = false;
    notifyListeners();
  }

  void setActive(String id) {
    if (_activeId == id) return;
    _activeId = id;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Presença na rede (heartbeat) e relocalização por mudança de IP
  // ---------------------------------------------------------------------------

  /// Última verificação de presença: `true`/`false`, ou `null` se ainda não
  /// verificado (ou protocolo sem rede).
  bool? isOnline(RemoteDevice d) => _online[d.id];

  /// Verifica se `host:port` do aparelho responde a TCP (rápido, ~2 s).
  Future<bool> isReachable(RemoteDevice d) async {
    final probe = _probe;
    if (probe == null || !d.protocol.isNetwork) return true;
    final ok = await probe(d.host, d.port);
    if (_online[d.id] != ok) {
      _online[d.id] = ok;
      notifyListeners();
    }
    return ok;
  }

  /// Mantém a verificação periódica de presença enquanto houver observadores
  /// (telas que listam aparelhos). Aparelhos fora da rede são procurados por
  /// mDNS/SSDP e, se reapareceram com outro IP, têm o endereço atualizado.
  void watchPresence({Duration every = const Duration(seconds: 5)}) {
    if (++_presenceWatchers > 1) return;
    unawaited(refreshPresence());
    _presenceTimer = Timer.periodic(every, (_) => refreshPresence());
  }

  void unwatchPresence() {
    if (_presenceWatchers == 0) return;
    if (--_presenceWatchers == 0) {
      _presenceTimer?.cancel();
      _presenceTimer = null;
    }
  }

  Future<void> refreshPresence() async {
    final probe = _probe;
    if (probe == null || _refreshingPresence) return;
    _refreshingPresence = true;
    try {
      final targets = _devices.where((d) => d.protocol.isNetwork).toList();
      final results = await Future.wait(targets.map((d) => probe(d.host, d.port)));
      var changed = false;
      for (var i = 0; i < targets.length; i++) {
        if (_online[targets[i].id] != results[i]) {
          _online[targets[i].id] = results[i];
          changed = true;
        }
      }
      if (changed) notifyListeners();
      final offline = targets.where((d) => _online[d.id] == false).toList();
      final now = DateTime.now();
      if (offline.isNotEmpty &&
          _scanner != null &&
          (_lastSweep == null || now.difference(_lastSweep!) >= relocateCooldown)) {
        _lastSweep = now;
        await _sweep(offline);
      }
    } finally {
      _refreshingPresence = false;
    }
  }

  /// Uma varredura para todos os aparelhos [offline] de uma vez.
  Future<void> _sweep(List<RemoteDevice> offline) async {
    final found = await _scanner!.scan();
    for (final d in offline) {
      final match = _bestMatch(d, found);
      if (match == null || match.host == d.host) continue;
      await _moveTo(d, match);
    }
  }

  /// Procura o aparelho na rede pela identidade (nome do serviço/nome).
  /// Retorna o cadastro atualizado se o IP mudou, o próprio [d] se foi visto
  /// no mesmo endereço, ou `null` se não foi encontrado.
  Future<RemoteDevice?> relocate(RemoteDevice d, {Duration? timeout}) async {
    final scanner = _scanner;
    if (scanner == null || !d.protocol.isNetwork) return null;
    KLog.d('devices', '${d.name}: procurando na rede (atual ${d.host})');
    final found = await scanner.scan(timeout: timeout);
    final match = _bestMatch(d, found);
    if (match == null) {
      KLog.d('devices', '${d.name}: não encontrado na rede');
      return null;
    }
    if (match.host == d.host) return d;
    return _moveTo(d, match);
  }

  Future<RemoteDevice> _moveTo(RemoteDevice d, DiscoveredDevice match) async {
    KLog.d('devices', '${d.name}: endereço ${d.host} → ${match.host}');
    final moved = d.copyWith(
      host: match.host,
      serviceName: d.serviceName ?? (match.protocol == d.protocol ? match.serviceName : null),
    );
    _online[d.id] = true;
    await update(moved);
    return moved;
  }

  /// Cadastro correspondente a um aparelho descoberto (mesma identidade),
  /// ainda que o IP tenha mudado desde o cadastro.
  RemoteDevice? findRegistered(DiscoveredDevice f) =>
      _devices.where((d) => d.id == f.toDevice().id || matches(d, f)).firstOrNull;

  /// Um achado [f] é o mesmo aparelho que o cadastro [d]?
  ///
  /// Um Google TV cadastrado pode ser visto tanto como Android TV quanto como
  /// receptor Cast (mesmo host). A identidade forte é o nome da instância
  /// mDNS/SSDP; o nome amigável é o recurso para cadastros antigos/manuais.
  static bool matches(RemoteDevice d, DiscoveredDevice f) {
    final family =
        d.protocol == f.protocol || (d.protocol == RemoteProtocol.androidTv && f.protocol == RemoteProtocol.cast);
    if (!family) return false;
    final sn = d.serviceName;
    if (sn != null && f.serviceName != null && d.protocol == f.protocol) return sn == f.serviceName;
    return f.name.trim().toLowerCase() == d.name.trim().toLowerCase();
  }

  DiscoveredDevice? _bestMatch(RemoteDevice d, List<DiscoveredDevice> found) {
    final candidates = found.where((f) => matches(d, f)).toList();
    if (candidates.isEmpty) return null;
    // Prefere o mesmo protocolo (identidade mais forte) e, entre iguais, o
    // que responde no host atual.
    candidates.sort((a, b) {
      final pa = a.protocol == d.protocol ? 0 : 1;
      final pb = b.protocol == d.protocol ? 0 : 1;
      if (pa != pb) return pa.compareTo(pb);
      return (a.host == d.host ? 0 : 1).compareTo(b.host == d.host ? 0 : 1);
    });
    return candidates.first;
  }

  /// Controlador do dispositivo (criado sob demanda e mantido vivo para
  /// alternância instantânea entre aparelhos).
  Future<RemoteController> controller(RemoteDevice d) async => _controllers[d.id] ??= await _factory.create(d);

  RemoteController? controllerIfCreated(RemoteDevice d) => _controllers[d.id];

  Future<void> connect(RemoteDevice d) async => (await controller(d)).connect();

  Future<void> sendKey(RemoteDevice d, RemoteKey key, {KeyPress press = KeyPress.short}) async {
    KLog.d('ui', 'tecla ${key.name}${press == KeyPress.short ? '' : ' (${press.name})'} → ${d.name}');
    try {
      await (await controller(d)).sendKey(key, press: press);
    } catch (e) {
      KLog.d('ui', 'tecla ${key.name} falhou: $e');
      rethrow;
    }
  }

  Future<void> sendText(RemoteDevice d, String text) async => (await controller(d)).sendText(text);

  Future<void> sendChar(RemoteDevice d, String ch) async => (await controller(d)).sendChar(ch);

  Future<void> launchApp(RemoteDevice d, AppShortcut app) async => (await controller(d)).launchApp(app);

  /// Inicia o emparelhamento; ao concluir, persiste credenciais e recria o
  /// controlador. Retorna `null` se o protocolo não exige emparelhamento.
  PairingFlow? startPairing(RemoteDevice d) {
    final flow = _factory.pairing(d);
    if (flow == null) return null;
    late StreamSubscription<PairingState> sub;
    // Só o sucesso encerra a escuta: uma falha transitória (ex.: socket
    // fechado pela TV logo após o ack) não pode descartar um sucesso que
    // chegue em seguida. O fluxo fecha o stream ao ser cancelado pela UI.
    sub = flow.state.listen((s) async {
      if (s.stage == PairingStage.success && flow.credentials != null) {
        await _creds.write(d.id, flow.credentials!);
        await _disposeController(d.id);
        _paired[d.id] = true;
        KLog.d('devices', '${d.name}: credenciais gravadas, emparelhado');
        notifyListeners();
        await sub.cancel();
      }
    });
    flow.start();
    return flow;
  }

  Future<void> _disposeController(String id) async {
    final c = _controllers.remove(id);
    if (c == null) return;
    await c.disconnect();
    if (c is BaseRemoteController) c.dispose();
  }

  @override
  void dispose() {
    _presenceTimer?.cancel();
    for (final c in _controllers.values) {
      c.disconnect();
      if (c is BaseRemoteController) c.dispose();
    }
    _controllers.clear();
    super.dispose();
  }
}
