import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../domain/entities/remote_device.dart';
import '../../domain/ports/device_discovery.dart';

/// Descoberta SSDP (UPnP) para Samsung, LG, Roku, Sony e Philips.
///
/// Usa UDP multicast direto; no iOS isso requer a entitlement
/// `com.apple.developer.networking.multicast`. Sem ela a busca falha em
/// silêncio e o usuário pode adicionar o aparelho por IP.
class SsdpDiscovery implements DeviceDiscovery {
  SsdpDiscovery({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  static const _targets = <String, RemoteProtocol>{
    'urn:samsung.com:device:RemoteControlReceiver:1': RemoteProtocol.samsungTizen,
    'urn:lge-com:service:webos-second-screen:1': RemoteProtocol.lgWebOs,
    'roku:ecp': RemoteProtocol.roku,
    'urn:schemas-sony-com:service:IRCC:1': RemoteProtocol.sonyBravia,
    'urn:philips-com:device:DirectFBRemote:1': RemoteProtocol.philipsJointSpace,
  };

  @override
  Stream<DiscoveredDevice> discover({Duration timeout = const Duration(seconds: 6)}) {
    final ctrl = StreamController<DiscoveredDevice>();
    final seen = <String>{};
    RawDatagramSocket? socket;

    Future<void> run() async {
      try {
        socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        final group = InternetAddress('239.255.255.250');
        socket!.listen((event) {
          if (event != RawSocketEvent.read) return;
          final dg = socket!.receive();
          if (dg == null) return;
          _handle(utf8.decode(dg.data, allowMalformed: true), dg.address.address, seen, ctrl);
        });
        for (final st in _targets.keys) {
          final msg =
              'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 3\r\nST: $st\r\n\r\n';
          socket!.send(utf8.encode(msg), group, 1900);
        }
      } catch (e) {
        if (kDebugMode) debugPrint('[ssdp] indisponível: $e');
      }
      await Future<void>.delayed(timeout);
      socket?.close();
      await ctrl.close();
    }

    ctrl.onListen = run;
    ctrl.onCancel = () => socket?.close();
    return ctrl.stream;
  }

  void _handle(String response, String fromIp, Set<String> seen, StreamController<DiscoveredDevice> out) {
    final headers = <String, String>{};
    for (final line in response.split('\r\n').skip(1)) {
      final i = line.indexOf(':');
      if (i > 0) headers[line.substring(0, i).trim().toUpperCase()] = line.substring(i + 1).trim();
    }
    final st = headers['ST'];
    final protocol = _targets[st];
    if (protocol == null) return;
    final key = '${protocol.name}@$fromIp';
    if (!seen.add(key)) return;
    _describe(protocol, fromIp, headers['LOCATION']).then((dev) {
      if (!out.isClosed) out.add(dev);
    });
  }

  Future<DiscoveredDevice> _describe(RemoteProtocol protocol, String ip, String? location) async {
    var name = '${protocol.label} ($ip)';
    String? model;
    String? mac;
    try {
      if (protocol == RemoteProtocol.samsungTizen) {
        final res = await _client.get(Uri.http('$ip:8001', '/api/v2/')).timeout(const Duration(seconds: 3));
        final info = (jsonDecode(res.body) as Map<String, dynamic>)['device'] as Map<String, dynamic>?;
        name = info?['name'] as String? ?? name;
        model = info?['modelName'] as String?;
        mac = info?['wifiMac'] as String?;
      } else if (location != null) {
        final res = await _client.get(Uri.parse(location)).timeout(const Duration(seconds: 3));
        name = _xmlTag(res.body, 'friendlyName') ?? _xmlTag(res.body, 'friendly-device-name') ?? name;
        model = _xmlTag(res.body, 'modelName') ?? _xmlTag(res.body, 'model-name');
        mac = _xmlTag(res.body, 'wifi-mac') ?? _xmlTag(res.body, 'ethernet-mac');
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
      macAddress: mac,
    );
  }

  static String? _xmlTag(String xml, String tag) {
    final m = RegExp('<$tag>([^<]*)</$tag>', caseSensitive: false).firstMatch(xml);
    return m?.group(1)?.trim();
  }
}
