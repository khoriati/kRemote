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

/// Caso de uso central: cadastro de dispositivos, dispositivo ativo,
/// ciclo de vida dos controladores e emparelhamento.
class DeviceService extends ChangeNotifier {
  DeviceService({
    required DeviceRepository repository,
    required CredentialStore credentials,
    required CertificatePinStore pins,
    required ControllerFactory factory,
  }) : _repo = repository,
       _creds = credentials,
       // ignore: prefer_initializing_formals
       _pins = pins,
       // ignore: prefer_initializing_formals
       _factory = factory;

  final DeviceRepository _repo;
  final CredentialStore _creds;
  final CertificatePinStore _pins;
  final ControllerFactory _factory;

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
  }

  bool isPaired(RemoteDevice d) => _paired[d.id] ?? !d.protocol.requiresPairing;

  Future<void> add(RemoteDevice d) async {
    if (d.protocol.isNetwork && !isValidHost(d.host)) throw const ConnectionException('Endereço inválido');
    if (d.macAddress != null && d.macAddress!.isNotEmpty && !isValidMac(d.macAddress!)) {
      throw const ConnectionException('MAC inválido');
    }
    _devices.removeWhere((e) => e.id == d.id);
    _devices.add(d);
    _paired[d.id] = _factory.hasPairedCredentials(await _creds.read(d.id), d.protocol);
    _activeId = d.id;
    await _repo.saveAll(_devices);
    notifyListeners();
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

  Future<void> sendKey(RemoteDevice d, RemoteKey key, {KeyPress press = KeyPress.short}) async =>
      (await controller(d)).sendKey(key, press: press);

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
