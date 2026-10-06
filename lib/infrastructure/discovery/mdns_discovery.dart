import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show Uint8List;
import 'package:nsd/nsd.dart' as nsd;

import '../../domain/entities/remote_device.dart';
import '../../domain/ports/device_discovery.dart';
import '../net/log.dart';

/// Verifica se `host:port` aceita TCP (para inferir Android TV a partir do Cast).
typedef PortCheck = Future<bool> Function(String host, int port);

/// Descoberta via Bonjour/NSD nativo (não exige entitlement de multicast no iOS).
///
/// No Android o `NsdManager` rejeita `_androidtvremote2._tcp` (o nome tem 16
/// caracteres; o limite do DNS-SD é 15). Quando esse tipo falha, o Google TV
/// é inferido a partir do anúncio Cast do mesmo host se a porta 6466 responde.
class MdnsDiscovery implements DeviceDiscovery {
  MdnsDiscovery({PortCheck? portCheck}) : _portCheck = portCheck ?? _tcpCheck;

  final PortCheck _portCheck;

  /// Tipos de serviço e protocolo correspondente. Todos devem constar em
  /// `NSBonjourServices` (iOS).
  static const serviceTypes = <String, RemoteProtocol>{
    '_androidtvremote2._tcp': RemoteProtocol.androidTv,
    '_googlecast._tcp': RemoteProtocol.cast,
    '_viziocast._tcp': RemoteProtocol.vizioSmartCast,
  };

  /// Tipos que a plataforma já recusou: não tenta de novo nem loga a cada varredura.
  static final _unsupportedTypes = <String>{};

  static Future<bool> _tcpCheck(String host, int port) async {
    try {
      final s = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      s.destroy();
      return true;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  @override
  Stream<DiscoveredDevice> discover({Duration timeout = const Duration(seconds: 6)}) {
    final ctrl = StreamController<DiscoveredDevice>();
    final seen = <String>{};
    final discoveries = <nsd.Discovery>[];
    final pending = <Future<void>>[];
    var atvAvailable = true;

    void emit(DiscoveredDevice dev) {
      if (seen.add(dev.key) && !ctrl.isClosed) ctrl.add(dev);
    }

    Future<void> run() async {
      for (final entry in serviceTypes.entries) {
        if (_unsupportedTypes.contains(entry.key)) {
          if (entry.value == RemoteProtocol.androidTv) atvAvailable = false;
          continue;
        }
        try {
          final d = await nsd.startDiscovery(entry.key, ipLookupType: nsd.IpLookupType.v4);
          discoveries.add(d);
          d.addServiceListener((service, status) {
            if (status != nsd.ServiceStatus.found) return;
            final dev = _toDevice(service, entry.value);
            if (dev == null) {
              KLog.d('mdns', '${entry.key}: "${service.name}" ignorado (sem endereço)');
              return;
            }
            emit(dev);
            if (dev.protocol == RemoteProtocol.cast && !atvAvailable) {
              pending.add(_inferAndroidTv(dev, emit));
            }
          });
        } catch (e) {
          if (e is nsd.NsdError && e.cause == nsd.ErrorCause.illegalArgument) {
            _unsupportedTypes.add(entry.key);
            KLog.d(
              'mdns',
              '${entry.key} não é aceito nesta plataforma; Google TV será inferido pelo Cast + porta 6466',
            );
          } else {
            KLog.d('mdns', 'falha em ${entry.key}: $e');
          }
          if (entry.value == RemoteProtocol.androidTv) atvAvailable = false;
        }
      }
      await Future<void>.delayed(timeout);
      for (final d in discoveries) {
        await nsd.stopDiscovery(d).catchError((_) {});
      }
      await Future.wait(pending);
      KLog.d('mdns', 'varredura: ${seen.length} serviço(s)');
      await ctrl.close();
    }

    ctrl.onListen = run;
    ctrl.onCancel = () async {
      for (final d in discoveries) {
        await nsd.stopDiscovery(d).catchError((_) {});
      }
    };
    return ctrl.stream;
  }

  Future<void> _inferAndroidTv(DiscoveredDevice cast, void Function(DiscoveredDevice) emit) async {
    if (!await _portCheck(cast.host, RemoteProtocol.androidTv.defaultPort)) return;
    emit(
      DiscoveredDevice(
        name: cast.name,
        host: cast.host,
        port: RemoteProtocol.androidTv.defaultPort,
        protocol: RemoteProtocol.androidTv,
        model: cast.model,
        serviceName: cast.serviceName,
      ),
    );
  }

  static DiscoveredDevice? _toDevice(nsd.Service s, RemoteProtocol protocol) {
    final addr = s.addresses?.where((a) => a.type == InternetAddressType.IPv4).firstOrNull;
    final host = addr?.address ?? s.host;
    if (host == null || host.isEmpty) return null;
    final txt = <String, String>{
      for (final e in (s.txt ?? const <String, Uint8List?>{}).entries)
        if (e.value != null) e.key: utf8.decode(e.value!, allowMalformed: true),
    };
    var name = s.name ?? host;
    if (protocol == RemoteProtocol.cast) {
      // Chromecast com Google TV também anuncia _androidtvremote2; o Cast
      // puro ainda é útil para volume/mídia. `fn` é o nome amigável.
      name = txt['fn'] ?? name;
    }
    final port = s.port ?? protocol.defaultPort;
    return DiscoveredDevice(
      name: name,
      host: host,
      port: port,
      protocol: protocol,
      model: txt['md'] ?? txt['model'],
      serviceName: s.name,
    );
  }
}
