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
  }) : _probe = probe, // ignore: prefer_initializing_formals
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

  final List<RemoteDevice> _devices = [];
  final Map<String, RemoteController> _controllers = {};
  final Map<String, bool> _paired = {};
  String? _activeId;
  bool _loaded = false;

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

  Future<void> launchApp(RemoteDevice d, AppShortcut app) async => (await controller(d)).launchApp(app);

  /// Inicia o emparelhamento; ao concluir, persiste credenciais e recria o
  /// controlador. Retorna `null` se o protocolo não exige emparelhamento.
  PairingFlow? startPairing(RemoteDevice d) {
    final flow = _factory.pairing(d);
    if (flow == null) return null;
    late StreamSubscription<PairingState> sub;
    sub = flow.state.listen((s) async {
      if (s.stage == PairingStage.success && flow.credentials != null) {
        await _creds.write(d.id, flow.credentials!);
        await _disposeController(d.id);
        _paired[d.id] = true;
        notifyListeners();
        await sub.cancel();
      } else if (s.stage == PairingStage.failure) {
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
    for (final c in _controllers.values) {
      c.disconnect();
      if (c is BaseRemoteController) c.dispose();
    }
    _controllers.clear();
    super.dispose();
  }
}
