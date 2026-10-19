import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../domain/entities/remote_device.dart';
import '../../domain/ports/device_identifier.dart';
import '../net/log.dart';
import '../../domain/xml_entities.dart';
import 'brand_catalog.dart';

/// Verifica se `host:port` aceita conexão TCP.
typedef PortCheck = Future<bool> Function(String host, int port);

/// Pistas sobre um host vindas do anúncio (mDNS/SSDP) que o encontrou.
class HostHints {
  const HostHints({this.name, this.manufacturer, this.model, this.mac, this.serviceName});
  final String? name;
  final String? manufacturer;
  final String? model;
  final String? mac;
  final String? serviceName;

  /// Marca inferida do fabricante ou, na falta, do modelo/nome.
  BrandInfo? get brand =>
      BrandCatalog.brandOf(manufacturer) ?? BrandCatalog.brandOf(model) ?? BrandCatalog.brandOf(name);
}

/// Sonda um host e confirma qual protocolo de controle ele oferece.
///
/// Cada protocolo tem uma verificação própria, descrita no [BrandCatalog]:
/// as que respondem por HTTP (Samsung 8001, Roku 8060, Philips 1925, Sony
/// `/sony/system`) são confirmação forte e ainda devolvem nome, modelo e
/// MAC; as que só abrem TCP (Android TV 6466, Cast 8009, LG 3000, Vizio
/// 7345) são aceitas por último ou quando a marca é conhecida.
///
/// Usada (1) pela descoberta mDNS a partir dos anúncios AirPlay/HomeKit —
/// o caminho que funciona no iOS sem multicast UDP —, (2) pela descoberta
/// SSDP para respostas genéricas, (3) pela varredura de sub-rede e (4) pelo
/// botão *Detectar* do cadastro por IP.
class HostProbe implements DeviceIdentifier {
  HostProbe({http.Client? client, PortCheck? portCheck, this.timeout = const Duration(seconds: 3)})
    : _client = client ?? http.Client(),
      _portCheck = portCheck ?? tcpCheck;

  final http.Client _client;
  final PortCheck _portCheck;
  final Duration timeout;

  static Future<bool> tcpCheck(String host, int port, {Duration timeout = const Duration(seconds: 2)}) async {
    try {
      final s = await Socket.connect(host, port, timeout: timeout);
      s.destroy();
      return true;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  @override
  Future<DiscoveredDevice?> identify(String host) => probe(host);

  /// Tenta os [candidates] (ou a ordem padrão do catálogo, ou os protocolos
  /// da marca das [hints]) e devolve o primeiro confirmado.
  Future<DiscoveredDevice?> probe(
    String host, {
    List<RemoteProtocol>? candidates,
    HostHints hints = const HostHints(),
  }) async {
    final brand = hints.brand;
    final list = candidates ?? (brand != null ? brand.protocols : BrandCatalog.probeOrder);
    if (list.isEmpty) {
      KLog.d('probe', '$host: marca ${brand?.label} sem protocolo suportado');
      return null;
    }
    for (final p in list) {
      final dev = await probeProtocol(host, p, hints: hints, brandKnown: brand != null);
      if (dev != null) {
        KLog.d('probe', '$host: ${p.name} confirmado (${dev.name})');
        return dev;
      }
    }
    return null;
  }

  /// Confirma um único protocolo em [host]. [brandKnown] relaxa as
  /// verificações fracas (somente TCP) quando a marca já é conhecida.
  Future<DiscoveredDevice?> probeProtocol(
    String host,
    RemoteProtocol p, {
    HostHints hints = const HostHints(),
    bool brandKnown = false,
  }) async {
    try {
      return switch (p) {
        RemoteProtocol.samsungTizen => await _samsung(host, hints),
        RemoteProtocol.roku => await _roku(host, hints),
        RemoteProtocol.philipsJointSpace => await _philips(host, hints),
        RemoteProtocol.sonyBravia => await _sony(host, hints),
        RemoteProtocol.lgWebOs => await _lg(host, hints, brandKnown),
        RemoteProtocol.vizioSmartCast => await _tcpOnly(host, p, hints, ports: const [7345]),
        RemoteProtocol.androidTv => await _tcpOnly(host, p, hints, ports: const [6466]),
        RemoteProtocol.cast => await _tcpOnly(host, p, hints, ports: const [8009]),
        RemoteProtocol.bluetoothHid => null,
      };
    } catch (e) {
      KLog.d('probe', '$host ${p.name}: $e');
      return null;
    }
  }

  DiscoveredDevice _device(
    String host,
    RemoteProtocol p,
    HostHints hints, {
    int? port,
    String? name,
    String? model,
    String? mac,
  }) => DiscoveredDevice(
    name: _clean(name) ?? _clean(hints.name) ?? '${p.label} ($host)',
    host: host,
    port: port ?? p.defaultPort,
    protocol: p,
    model: _clean(model) ?? _clean(hints.model),
    macAddress: normalizeMac(mac) ?? normalizeMac(hints.mac),
    serviceName: hints.serviceName,
  );

  static String? _clean(String? s) {
    final t = s?.trim();
    return t == null || t.isEmpty ? null : t;
  }

  /// Aceita `AA:BB:CC:DD:EE:FF`, `aa-bb-...` ou `AABBCCDDEEFF`.
  static String? normalizeMac(String? raw) {
    if (raw == null) return null;
    final hex = raw.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '').toUpperCase();
    if (hex.length != 12) return null;
    return [for (var i = 0; i < 12; i += 2) hex.substring(i, i + 2)].join(':');
  }

  Future<http.Response> _get(Uri uri) => _client.get(uri).timeout(timeout);

  Future<DiscoveredDevice?> _samsung(String host, HostHints hints) async {
    final res = await _get(Uri.http('$host:8001', '/api/v2/'));
    if (res.statusCode != 200) return null;
    final json = jsonDecode(res.body);
    if (json is! Map<String, dynamic>) return null;
    final info = json['device'] as Map<String, dynamic>?;
    if (info == null) return null;
    // Tizen 2016–2017 sem TokenAuthSupport usa ws:// na 8001; os demais, wss:// 8002.
    final token = '${info['TokenAuthSupport'] ?? 'true'}'.toLowerCase() == 'true';
    return _device(
      host,
      RemoteProtocol.samsungTizen,
      hints,
      port: token ? 8002 : 8001,
      name: info['name'] as String?,
      model: info['modelName'] as String?,
      mac: info['wifiMac'] as String?,
    );
  }

  Future<DiscoveredDevice?> _roku(String host, HostHints hints) async {
    final res = await _get(Uri.http('$host:8060', '/query/device-info'));
    if (res.statusCode != 200 || !res.body.contains('<device-info')) return null;
    final x = res.body;
    final vendor = xmlTag(x, 'vendor-name');
    final modelName = xmlTag(x, 'model-name');
    return _device(
      host,
      RemoteProtocol.roku,
      hints,
      name: xmlTag(x, 'user-device-name') ?? xmlTag(x, 'friendly-device-name'),
      model: vendor != null && modelName != null && !modelName.toLowerCase().contains(vendor.toLowerCase())
          ? '$vendor $modelName'
          : modelName,
      mac: xmlTag(x, 'wifi-mac') ?? xmlTag(x, 'ethernet-mac'),
    );
  }

  Future<DiscoveredDevice?> _philips(String host, HostHints hints) async {
    for (final v in const [6, 5, 1]) {
      try {
        final res = await _get(Uri.http('$host:1925', '/$v/system'));
        if (res.statusCode != 200) continue;
        final json = jsonDecode(res.body);
        if (json is! Map<String, dynamic>) continue;
        return _device(
          host,
          RemoteProtocol.philipsJointSpace,
          hints,
          name: json['name'] as String?,
          model: json['model'] as String?,
        );
      } on FormatException {
        continue;
      } on http.ClientException {
        return null;
      } on SocketException {
        return null;
      } on TimeoutException {
        return null;
      }
    }
    return null;
  }

  Future<DiscoveredDevice?> _sony(String host, HostHints hints) async {
    // `getInterfaceInformation` não exige PSK e identifica a Bravia.
    final res = await _client
        .post(
          Uri.http(host, '/sony/system'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'method': 'getInterfaceInformation', 'id': 1, 'params': <Object>[], 'version': '1.0'}),
        )
        .timeout(timeout);
    if (res.statusCode != 200) return null;
    final json = jsonDecode(res.body);
    if (json is! Map<String, dynamic>) return null;
    final result = json['result'];
    if (result is! List || result.isEmpty || result.first is! Map) return null;
    final info = result.first as Map;
    return _device(
      host,
      RemoteProtocol.sonyBravia,
      hints,
      name: info['serverName'] as String?,
      model: info['modelName'] as String?,
    );
  }

  Future<DiscoveredDevice?> _lg(String host, HostHints hints, bool brandKnown) async {
    final (plain, secure) = await (_portCheck(host, 3000), _portCheck(host, 3001)).wait;
    // Sem marca conhecida, a 3000 sozinha é fraca (qualquer serviço de dev);
    // o par 3000+3001 é característico do webOS.
    if (!plain && !secure) return null;
    if (!brandKnown && !(plain && secure)) return null;
    return _device(host, RemoteProtocol.lgWebOs, hints, port: plain ? 3000 : 3001);
  }

  Future<DiscoveredDevice?> _tcpOnly(String host, RemoteProtocol p, HostHints hints, {required List<int> ports}) async {
    for (final port in ports) {
      if (await _portCheck(host, port)) return _device(host, p, hints, port: port);
    }
    return null;
  }

  static String? xmlTag(String xml, String tag) {
    final m = RegExp('<$tag>([^<]*)</$tag>', caseSensitive: false).firstMatch(xml);
    final v = m?.group(1)?.trim();
    return v == null || v.isEmpty ? null : decodeXmlEntities(v);
  }
}
