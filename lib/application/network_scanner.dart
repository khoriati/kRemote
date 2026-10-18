import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/entities/remote_device.dart';
import '../domain/ports/device_discovery.dart';
import '../domain/ports/device_identifier.dart';
import '../infrastructure/net/log.dart';

/// Busca de aparelhos na rede compartilhada por toda a UI.
///
/// - Uma varredura em andamento é reaproveitada por quem pedir outra
///   (evita várias descobertas mDNS simultâneas no iOS).
/// - Enquanto houver observadores ([watch]), repete a varredura a cada
///   [interval] e descarta aparelhos que não são vistos há [staleAfter]:
///   é o *heartbeat* da lista de disponíveis.
/// - [scanDeep] roda a descoberta profunda (varredura de sub-rede), só a
///   pedido do usuário; os achados entram na mesma lista.
/// - [identify] sonda um host digitado e diz qual protocolo ele fala.
class NetworkScanner extends ChangeNotifier {
  NetworkScanner(
    this._discovery, {
    DeviceDiscovery? deep,
    DeviceIdentifier? identifier,
    this.interval = const Duration(seconds: 10),
    this.scanTimeout = const Duration(seconds: 6),
    this.staleAfter = const Duration(seconds: 25),
  }) : _deep = deep, // ignore: prefer_initializing_formals
       _identifier = identifier; // ignore: prefer_initializing_formals

  final DeviceDiscovery _discovery;
  final DeviceDiscovery? _deep;
  final DeviceIdentifier? _identifier;
  final Duration interval;
  final Duration scanTimeout;
  final Duration staleAfter;

  final Map<String, ({DiscoveredDevice device, DateTime seen})> _found = {};
  Future<List<DiscoveredDevice>>? _running;
  Future<List<DiscoveredDevice>>? _runningDeep;
  Timer? _timer;
  int _watchers = 0;
  DateTime? _lastScan;

  bool get scanning => _running != null;
  bool get deepScanning => _runningDeep != null;
  bool get canScanDeep => _deep != null;
  bool get canIdentify => _identifier != null;
  DateTime? get lastScan => _lastScan;

  /// Aparelhos vistos recentemente (Android TV primeiro, depois por nome).
  List<DiscoveredDevice> get found {
    _evict();
    return _found.values.map((e) => e.device).toList()..sort(_compare);
  }

  /// Mantém a varredura periódica enquanto houver ao menos um observador.
  void watch() {
    if (++_watchers > 1) return;
    unawaited(scan());
    _timer = Timer.periodic(interval, (_) => scan());
  }

  void unwatch() {
    if (_watchers == 0) return;
    if (--_watchers == 0) {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Executa (ou aguarda) uma varredura e devolve o que está visível ao final.
  Future<List<DiscoveredDevice>> scan({Duration? timeout}) {
    final inFlight = _running;
    if (inFlight != null) return inFlight;
    final f = _run(_discovery, timeout ?? scanTimeout).whenComplete(() {
      _running = null;
      _lastScan = DateTime.now();
      notifyListeners();
    });
    _running = f;
    notifyListeners();
    return f;
  }

  /// Varredura profunda (sub-rede), a pedido. Aparelhos achados aqui ficam
  /// na lista por [staleAfter] como os demais; o heartbeat normal os
  /// mantém se responderem ao mDNS/SSDP.
  Future<List<DiscoveredDevice>> scanDeep() {
    final deep = _deep;
    if (deep == null) return scan();
    final inFlight = _runningDeep;
    if (inFlight != null) return inFlight;
    final f = _run(deep, scanTimeout).whenComplete(() {
      _runningDeep = null;
      notifyListeners();
    });
    _runningDeep = f;
    notifyListeners();
    return f;
  }

  /// Identifica o protocolo de um host (cadastro por IP); `null` se nada
  /// suportado respondeu ou se não há identificador configurado.
  Future<DiscoveredDevice?> identify(String host) async {
    final id = _identifier;
    if (id == null) return null;
    final d = (await id.identify(host))?.normalized();
    if (d != null) {
      _found[d.key] = (device: d, seen: DateTime.now());
      notifyListeners();
    }
    return d;
  }

  Future<List<DiscoveredDevice>> _run(DeviceDiscovery discovery, Duration timeout) async {
    var changed = false;
    try {
      await for (final raw in discovery.discover(timeout: timeout)) {
        final d = raw.normalized();
        final prev = _found[d.key];
        _found[d.key] = (device: d, seen: DateTime.now());
        if (prev == null) {
          KLog.d('scanner', 'novo: ${d.name} (${d.protocol.name} ${d.host}:${d.port})');
        } else if (prev.device.host != d.host) {
          KLog.d('scanner', '${d.name}: ${prev.device.host} → ${d.host}');
        }
        if (prev == null || prev.device.host != d.host || prev.device.name != d.name) {
          changed = true;
          notifyListeners();
        }
      }
    } catch (e) {
      KLog.d('scanner', 'falha na varredura: $e');
    }
    if (_evict() || changed) notifyListeners();
    return found;
  }

  bool _evict() {
    final limit = DateTime.now().subtract(staleAfter);
    final before = _found.length;
    _found.removeWhere((_, e) {
      final stale = e.seen.isBefore(limit);
      if (stale) KLog.d('scanner', 'sumiu da rede: ${e.device.name} (${e.device.host})');
      return stale;
    });
    return _found.length != before;
  }

  static int _compare(DiscoveredDevice a, DiscoveredDevice b) {
    final pa = a.protocol == RemoteProtocol.androidTv ? 0 : 1;
    final pb = b.protocol == RemoteProtocol.androidTv ? 0 : 1;
    return pa != pb ? pa.compareTo(pb) : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
