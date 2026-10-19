import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../domain/entities/remote_device.dart';
import '../../domain/ports/device_discovery.dart';
import '../net/log.dart';
import 'brand_catalog.dart';
import 'host_probe.dart';

/// Descoberta SSDP (UPnP) para Samsung, LG, Roku, Sony e Philips.
///
/// Além dos alvos específicos de cada marca, pergunta por `ssdp:all` e
/// `upnp:rootdevice`: TVs com firmware antigo (ou que só anunciam o root)
/// respondem a esses, e a resposta é classificada pelos cabeçalhos
/// ([BrandCatalog.classifySsdp]) ou pelo `<manufacturer>` da descrição XML,
/// que leva à [HostProbe] da marca.
///
/// Usa UDP multicast direto; no iOS isso requer a entitlement
/// `com.apple.developer.networking.multicast`. Sem ela a busca falha em
/// silêncio e as marcas são encontradas pelo mDNS (AirPlay/HomeKit) ou
/// pela varredura de sub-rede.
class SsdpDiscovery implements DeviceDiscovery {
  SsdpDiscovery({http.Client? client, HostProbe? probe})
    : _client = client ?? http.Client(),
      _probe = probe ?? HostProbe(client: client);

  final http.Client _client;
  final HostProbe _probe;

  @override
  Stream<DiscoveredDevice> discover({Duration timeout = const Duration(seconds: 6)}) {
    final ctrl = StreamController<DiscoveredDevice>();
    final seen = <String>{};
    final describedHosts = <String>{};
    final pending = <Future<void>>[];
    RawDatagramSocket? socket;

    Future<void> run() async {
      try {
        socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        final group = InternetAddress('239.255.255.250');
        socket!.listen((event) {
          if (event != RawSocketEvent.read) return;
          final dg = socket!.receive();
          if (dg == null) return;
          final f = handle(utf8.decode(dg.data, allowMalformed: true), dg.address.address, seen, describedHosts, ctrl);
          if (f != null) pending.add(f);
        });
        for (final st in BrandCatalog.ssdpTargets.keys) {
          final msg =
              'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 3\r\nST: $st\r\n\r\n';
          socket!.send(utf8.encode(msg), group, 1900);
        }
      } catch (e) {
        KLog.d('ssdp', 'indisponível: $e');
      }
      await Future<void>.delayed(timeout);
      socket?.close();
      await Future.wait(pending);
      await ctrl.close();
    }

    ctrl.onListen = run;
    ctrl.onCancel = () => socket?.close();
    return ctrl.stream;
  }

  static Map<String, String> parseHeaders(String response) {
    final headers = <String, String>{};
    for (final line in response.split('\r\n').skip(1)) {
      final i = line.indexOf(':');
      if (i > 0) headers[line.substring(0, i).trim().toUpperCase()] = line.substring(i + 1).trim();
    }
    return headers;
  }

  /// Trata uma resposta; devolve o trabalho assíncrono pendente, se houver.
  Future<void>? handle(
    String response,
    String fromIp,
    Set<String> seen,
    Set<String> describedHosts,
    StreamController<DiscoveredDevice> out,
  ) {
    final headers = parseHeaders(response);
    final protocol = BrandCatalog.classifySsdp(headers);
    final location = headers['LOCATION'];
    if (protocol != null) {
      if (!seen.add('${protocol.name}@$fromIp')) return null;
      return _describe(protocol, fromIp, location).then((dev) {
        if (!out.isClosed) out.add(dev);
      });
    }
    // Resposta genérica (root/all): identifica a marca pela descrição e sonda.
    if (location == null || !describedHosts.add(fromIp)) return null;
    return _identifyGeneric(fromIp, location).then((dev) {
      if (dev == null || !seen.add('${dev.protocol.name}@$fromIp')) return;
      if (!out.isClosed) out.add(dev);
    });
  }

  Future<DiscoveredDevice> _describe(RemoteProtocol protocol, String ip, String? location) async {
    var name = '${protocol.label} ($ip)';
    String? model;
    String? mac;
    try {
      if (protocol == RemoteProtocol.samsungTizen) {
        final probed = await _probe.probeProtocol(ip, protocol, brandKnown: true);
        if (probed != null) return probed;
      } else if (location != null) {
        final res = await _client.get(Uri.parse(location)).timeout(const Duration(seconds: 3));
        name = HostProbe.xmlTag(res.body, 'friendlyName') ?? HostProbe.xmlTag(res.body, 'friendly-device-name') ?? name;
        model = HostProbe.xmlTag(res.body, 'modelName') ?? HostProbe.xmlTag(res.body, 'model-name');
        mac = HostProbe.xmlTag(res.body, 'wifi-mac') ?? HostProbe.xmlTag(res.body, 'ethernet-mac');
      }
    } catch (_) {
      // descrição é opcional
    }
    return DiscoveredDevice(
      name: name,
      host: ip,
      port: protocol.defaultPort,
      protocol: protocol,
      model: model,
      macAddress: HostProbe.normalizeMac(mac),
    );
  }

  Future<DiscoveredDevice?> _identifyGeneric(String ip, String location) async {
    String? manufacturer;
    String? name;
    String? model;
    try {
      final res = await _client.get(Uri.parse(location)).timeout(const Duration(seconds: 3));
      manufacturer = HostProbe.xmlTag(res.body, 'manufacturer');
      name = HostProbe.xmlTag(res.body, 'friendlyName');
      model = HostProbe.xmlTag(res.body, 'modelName');
    } catch (_) {
      return null;
    }
    final hints = HostHints(name: name, manufacturer: manufacturer, model: model);
    // Sem marca reconhecida não vale a pena sondar: roteadores, NAS e
    // impressoras também respondem a `ssdp:all`.
    if (hints.brand == null) return null;
    return _probe.probe(ip, hints: hints);
  }
}
