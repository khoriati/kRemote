import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:nsd/nsd.dart' as nsd;

import '../../domain/entities/remote_device.dart';
import '../../domain/ports/device_discovery.dart';

/// Descoberta via Bonjour/NSD nativo (não exige entitlement de multicast no iOS).
class MdnsDiscovery implements DeviceDiscovery {
  /// Tipos de serviço e protocolo correspondente. Todos devem constar em
  /// `NSBonjourServices` (iOS).
  static const serviceTypes = <String, RemoteProtocol>{
    '_androidtvremote2._tcp': RemoteProtocol.androidTv,
    '_googlecast._tcp': RemoteProtocol.cast,
    '_viziocast._tcp': RemoteProtocol.vizioSmartCast,
  };

  @override
  Stream<DiscoveredDevice> discover({Duration timeout = const Duration(seconds: 6)}) {
    final ctrl = StreamController<DiscoveredDevice>();
    final seen = <String>{};
    final discoveries = <nsd.Discovery>[];

    Future<void> run() async {
      for (final entry in serviceTypes.entries) {
        try {
          final d = await nsd.startDiscovery(entry.key, ipLookupType: nsd.IpLookupType.v4);
          discoveries.add(d);
          d.addServiceListener((service, status) {
            if (status != nsd.ServiceStatus.found) return;
            final dev = _toDevice(service, entry.value);
            if (dev != null && seen.add(dev.key) && !ctrl.isClosed) ctrl.add(dev);
          });
        } catch (e) {
          if (kDebugMode) debugPrint('[mdns] falha em ${entry.key}: $e');
        }
      }
      await Future<void>.delayed(timeout);
      for (final d in discoveries) {
        await nsd.stopDiscovery(d).catchError((_) {});
      }
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
