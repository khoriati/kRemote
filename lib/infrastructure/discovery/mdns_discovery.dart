import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show Uint8List;
import 'package:nsd/nsd.dart' as nsd;

import '../../domain/entities/remote_device.dart';
import '../../domain/ports/device_discovery.dart';
import '../net/log.dart';
import 'brand_catalog.dart';
import 'host_probe.dart';

export 'host_probe.dart' show PortCheck;

/// Descoberta via Bonjour/NSD nativo (não exige entitlement de multicast no iOS).
///
/// Dois tipos de anúncio (tabelas em [BrandCatalog]):
///
/// - **Diretos** ([BrandCatalog.mdnsTypes]): o tipo de serviço já diz o
///   protocolo (Google TV, Cast, Vizio, Philips JointSpace).
/// - **Pistas** ([BrandCatalog.mdnsHintTypes]): AirPlay 2 e HomeKit, que
///   Samsung, LG, Sony, Roku, Vizio e Philips anunciam. O TXT traz
///   fabricante/modelo; a [HostProbe] confirma o protocolo e completa nome,
///   modelo e MAC. É assim que as marcas sem mDNS próprio aparecem no iOS,
///   onde o SSDP (UDP multicast) não está disponível.
///
/// No Android o `NsdManager` rejeita tipos com mais de 15 caracteres
/// (`_androidtvremote2`, `_philipstv_s_rpc`). Quando o tipo Android TV
/// falha, o Google TV é inferido do anúncio Cast do mesmo host se a 6466
/// responde.
class MdnsDiscovery implements DeviceDiscovery {
  MdnsDiscovery({PortCheck? portCheck, HostProbe? probe})
    : _portCheck = portCheck ?? HostProbe.tcpCheck,
      _probe = probe ?? HostProbe(portCheck: portCheck);

  final PortCheck _portCheck;
  final HostProbe _probe;

  /// Tipos diretos (mantido como alias para compatibilidade/testes).
  static const serviceTypes = BrandCatalog.mdnsTypes;

  /// Categorias HomeKit (`ci`) que interessam: 31 TV, 35 set-top box,
  /// 36 streaming stick, 34 receiver. Outras (lâmpadas, sensores) são ignoradas.
  static const homeKitCategories = {'31', '34', '35', '36'};

  /// Modelos AirPlay que são equipamentos Apple/computadores, não TVs.
  static final _appleHardware = RegExp(r'^(appletv|macbook|macmini|imac|macpro|macstudio|iphone|ipad|audioaccessory)');

  /// Tipos que a plataforma já recusou: não tenta de novo nem loga a cada varredura.
  static final _unsupportedTypes = <String>{};

  @override
  Stream<DiscoveredDevice> discover({Duration timeout = const Duration(seconds: 6)}) {
    final ctrl = StreamController<DiscoveredDevice>();
    final seen = <String>{};
    final probedHosts = <String>{};
    final discoveries = <nsd.Discovery>[];
    final pending = <Future<void>>[];
    var atvAvailable = true;

    void emit(DiscoveredDevice dev) {
      if (seen.add(dev.key) && !ctrl.isClosed) ctrl.add(dev);
    }

    bool identified(String host) =>
        seen.any((k) => k.contains('@$host:') && !k.startsWith('${RemoteProtocol.cast.name}@'));

    Future<nsd.Discovery?> start(String type) async {
      if (_unsupportedTypes.contains(type)) return null;
      try {
        final d = await nsd.startDiscovery(type, ipLookupType: nsd.IpLookupType.v4);
        discoveries.add(d);
        return d;
      } catch (e) {
        if (e is nsd.NsdError && e.cause == nsd.ErrorCause.illegalArgument) {
          _unsupportedTypes.add(type);
          KLog.d('mdns', '$type não é aceito nesta plataforma');
        } else {
          KLog.d('mdns', 'falha em $type: $e');
        }
        return null;
      }
    }

    Future<void> run() async {
      for (final entry in BrandCatalog.mdnsTypes.entries) {
        final d = await start(entry.key);
        if (d == null) {
          if (entry.value == RemoteProtocol.androidTv) atvAvailable = false;
          continue;
        }
        d.addServiceListener((service, status) {
          if (status != nsd.ServiceStatus.found) return;
          final dev = toDevice(service, entry.value);
          if (dev == null) {
            KLog.d('mdns', '${entry.key}: "${service.name}" ignorado (sem endereço)');
            return;
          }
          emit(dev);
          if (dev.protocol == RemoteProtocol.cast && !atvAvailable) {
            pending.add(_inferAndroidTv(dev, emit));
          }
        });
      }
      for (final type in BrandCatalog.mdnsHintTypes) {
        final d = await start(type);
        if (d == null) continue;
        d.addServiceListener((service, status) {
          if (status != nsd.ServiceStatus.found) return;
          final hint = toHint(service, type);
          if (hint == null) return;
          final (host, hints) = hint;
          if (identified(host) || !probedHosts.add(host)) return;
          pending.add(
            _probe.probe(host, hints: hints).then((dev) {
              if (dev != null && !identified(host)) emit(dev);
            }),
          );
        });
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

  static Map<String, String> txtOf(nsd.Service s) => {
    for (final e in (s.txt ?? const <String, Uint8List?>{}).entries)
      if (e.value != null) e.key.toLowerCase(): utf8.decode(e.value!, allowMalformed: true),
  };

  static String? hostOf(nsd.Service s) {
    final addr = s.addresses?.where((a) => a.type == InternetAddressType.IPv4).firstOrNull;
    final host = addr?.address ?? s.host;
    return host == null || host.isEmpty ? null : host;
  }

  static String? _first(Map<String, String> txt, List<String> keys) {
    for (final k in keys) {
      final v = txt[k]?.trim();
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }

  /// Converte um serviço de tipo direto em aparelho.
  static DiscoveredDevice? toDevice(nsd.Service s, RemoteProtocol protocol) {
    final host = hostOf(s);
    if (host == null) return null;
    final txt = txtOf(s);
    var name = s.name ?? host;
    if (protocol == RemoteProtocol.cast) {
      // Chromecast com Google TV também anuncia _androidtvremote2; o Cast
      // puro ainda é útil para volume/mídia. `fn` é o nome amigável.
      name = txt['fn'] ?? name;
    }
    // Philips anuncia a API; a porta de controle é sempre a 1925 (HTTP).
    final port = protocol == RemoteProtocol.philipsJointSpace ? protocol.defaultPort : (s.port ?? protocol.defaultPort);
    return DiscoveredDevice(
      name: name,
      host: host,
      port: port,
      protocol: protocol,
      model: txt['md'] ?? txt['model'],
      serviceName: s.name,
    );
  }

  /// Extrai host e pistas de um anúncio AirPlay/HomeKit; `null` quando o
  /// serviço claramente não é uma TV (hardware Apple, acessório HomeKit).
  static (String, HostHints)? toHint(nsd.Service s, String type) {
    final host = hostOf(s);
    if (host == null) return null;
    final txt = txtOf(s);
    final model = _first(txt, BrandCatalog.txtModelKeys);
    final manufacturer = _first(txt, BrandCatalog.txtManufacturerKeys);
    if (type == '_hap._tcp') {
      final ci = txt['ci'];
      if (ci != null && !homeKitCategories.contains(ci)) return null;
    }
    if (manufacturer == null && model != null && _appleHardware.hasMatch(model.toLowerCase().replaceAll(' ', ''))) {
      return null;
    }
    return (
      host,
      HostHints(
        name: s.name,
        manufacturer: manufacturer,
        model: model,
        mac: _first(txt, BrandCatalog.txtMacKeys),
        serviceName: s.name,
      ),
    );
  }
}
