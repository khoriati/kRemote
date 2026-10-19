import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kremote/application/network_scanner.dart';
import 'package:kremote/domain/entities/remote_device.dart';
import 'package:kremote/domain/ports/device_discovery.dart';
import 'package:kremote/infrastructure/discovery/brand_catalog.dart';
import 'package:kremote/infrastructure/discovery/host_probe.dart';
import 'package:kremote/infrastructure/discovery/ssdp_discovery.dart';
import 'package:kremote/infrastructure/discovery/subnet_sweep_discovery.dart';
import 'package:kremote/domain/xml_entities.dart';

/// Rede falsa: hosts com portas abertas e respostas HTTP por URL.
class _FakeNet {
  final Map<String, Set<int>> open = {};
  final Map<String, http.Response> responses = {};
  final List<Uri> requests = [];

  Future<bool> portCheck(String host, int port) async => open[host]?.contains(port) ?? false;

  http.Client client() => MockClient((req) async {
    requests.add(req.url);
    final key = '${req.method} ${req.url.host}:${req.url.port}${req.url.path}';
    final res = responses[key];
    if (res != null) return res;
    if (open[req.url.host]?.contains(req.url.port) ?? false) return http.Response('not found', 404);
    throw http.ClientException('connection refused', req.url);
  });

  HostProbe probe() => HostProbe(client: client(), portCheck: portCheck, timeout: const Duration(seconds: 1));

  void samsung(String host, {bool token = true, String name = '[TV] Sala', String model = 'UN55AU7700'}) {
    open.putIfAbsent(host, () => {}).add(8001);
    responses['GET $host:8001/api/v2/'] = http.Response(
      jsonEncode({
        'device': {
          'name': name,
          'modelName': model,
          'wifiMac': 'aa:bb:cc:dd:ee:ff',
          'TokenAuthSupport': token ? 'true' : 'false',
        },
      }),
      200,
    );
  }

  void roku(String host, {String vendor = 'Philco', String model = 'PTV50RCG70BL'}) {
    open.putIfAbsent(host, () => {}).add(8060);
    responses['GET $host:8060/query/device-info'] = http.Response(
      '<?xml version="1.0"?><device-info><vendor-name>$vendor</vendor-name><model-name>$model</model-name>'
      '<user-device-name>TV Quarto</user-device-name><wifi-mac>11:22:33:44:55:66</wifi-mac><is-tv>true</is-tv>'
      '</device-info>',
      200,
    );
  }

  void philips(String host, {int version = 6}) {
    open.putIfAbsent(host, () => {}).add(1925);
    responses['GET $host:1925/$version/system'] = http.Response(
      jsonEncode({'name': 'Philips TV', 'model': '50PUG6654/78'}),
      200,
    );
  }

  void sony(String host) {
    open.putIfAbsent(host, () => {}).add(80);
    responses['POST $host:80/sony/system'] = http.Response(
      jsonEncode({
        'result': [
          {'productCategory': 'tv', 'modelName': 'KD-55X80J', 'serverName': 'BRAVIA Sala'},
        ],
        'id': 1,
      }),
      200,
    );
  }
}

void main() {
  group('BrandCatalog', () {
    test('reconhece marcas em fabricante/modelo e devolve candidatos ordenados', () {
      expect(BrandCatalog.brandOf('Samsung Electronics')?.label, 'Samsung');
      expect(BrandCatalog.brandOf('LG Electronics')?.protocols, [RemoteProtocol.lgWebOs]);
      expect(BrandCatalog.brandOf('Google Inc.')?.protocols.first, RemoteProtocol.androidTv);
      expect(BrandCatalog.brandOf('Sony Corporation')?.protocols, [
        RemoteProtocol.androidTv,
        RemoteProtocol.sonyBravia,
      ]);
      expect(BrandCatalog.brandOf('PHILCO')?.protocols, [RemoteProtocol.androidTv, RemoteProtocol.roku]);
      expect(BrandCatalog.brandOf('AIWA')?.protocols, contains(RemoteProtocol.androidTv));
      expect(BrandCatalog.brandOf('ViewSonic')?.protocols.first, RemoteProtocol.androidTv);
      expect(BrandCatalog.brandOf('TP Vision')?.label, 'Philips');
      expect(BrandCatalog.brandOf('Amazon')?.isSupported, isFalse);
      expect(BrandCatalog.brandOf('Roteador Qualquer'), isNull);
      expect(BrandCatalog.brandOf(null), isNull);
    });

    test('marcas curtas casam por palavra, não dentro de outras', () {
      expect(BrandCatalog.brandOf('Google Chromecast')?.label, 'Google');
      expect(BrandCatalog.brandOf('connected device'), isNull);
      expect(BrandCatalog.brandOf('LG webOS TV')?.label, 'LG');
      expect(BrandCatalog.brandOf('[LG] webOS TV UQ8050')?.label, 'LG');
    });

    test('sem marca, sonda todos os protocolos de rede', () {
      expect(BrandCatalog.candidatesFor(null), BrandCatalog.probeOrder);
      expect(BrandCatalog.probeOrder.toSet(), RemoteProtocol.values.where((p) => p.isNetwork).toSet());
    });

    test('tipos mDNS diretos cobrem Google TV, Cast, Vizio e Philips', () {
      expect(BrandCatalog.mdnsTypes['_androidtvremote2._tcp'], RemoteProtocol.androidTv);
      expect(BrandCatalog.mdnsTypes['_philipstv_rpc._tcp'], RemoteProtocol.philipsJointSpace);
      expect(BrandCatalog.mdnsHintTypes, containsAll(['_airplay._tcp', '_hap._tcp']));
    });

    test('classifica respostas SSDP por ST/USN/SERVER', () {
      expect(
        BrandCatalog.classifySsdp({'ST': 'urn:samsung.com:device:RemoteControlReceiver:1'}),
        RemoteProtocol.samsungTizen,
      );
      expect(BrandCatalog.classifySsdp({'ST': 'roku:ecp', 'USN': 'uuid:roku:ecp:X'}), RemoteProtocol.roku);
      expect(
        BrandCatalog.classifySsdp({'ST': 'upnp:rootdevice', 'SERVER': 'Roku/12.0 UPnP/1.0 Roku/12.0'}),
        RemoteProtocol.roku,
      );
      expect(
        BrandCatalog.classifySsdp({'ST': 'upnp:rootdevice', 'SERVER': 'WebOS/4.0 UPnP/1.0'}),
        RemoteProtocol.lgWebOs,
      );
      expect(
        BrandCatalog.classifySsdp({'ST': 'ssdp:all', 'USN': 'uuid:x::urn:schemas-sony-com:service:IRCC:1'}),
        RemoteProtocol.sonyBravia,
      );
      expect(
        BrandCatalog.classifySsdp({'ST': 'upnp:rootdevice', 'SERVER': 'Samsung UPnP SDK/1.0'}),
        isNull,
        reason: 'root Samsung genérico precisa da descrição XML',
      );
      expect(BrandCatalog.classifySsdp({'ST': 'upnp:rootdevice', 'SERVER': 'Linux UPnP/1.0 MiniDLNA'}), isNull);
    });

    test('portas de assinatura cobrem todos os protocolos de rede', () {
      for (final p in RemoteProtocol.values.where((p) => p.isNetwork)) {
        expect(BrandCatalog.signaturePorts[p], isNotEmpty, reason: p.name);
      }
      expect(BrandCatalog.protocolsForPort(8060), [RemoteProtocol.roku]);
      expect(BrandCatalog.allSignaturePorts, containsAll([6466, 8001, 8060, 3000, 1925, 80, 7345, 8009]));
    });
  });

  group('HostProbe', () {
    test('Samsung: API 8001 dá nome, modelo, MAC e porta conforme TokenAuthSupport', () async {
      final net = _FakeNet()..samsung('10.0.0.2');
      final d = await net.probe().probe('10.0.0.2');
      expect(d?.protocol, RemoteProtocol.samsungTizen);
      expect(d?.port, 8002);
      expect(d?.name, '[TV] Sala');
      expect(d?.model, 'UN55AU7700');
      expect(d?.macAddress, 'AA:BB:CC:DD:EE:FF');

      final old = _FakeNet()..samsung('10.0.0.3', token: false);
      expect((await old.probe().probe('10.0.0.3'))?.port, 8001);
    });

    test('Roku TV (Philco): device-info dá fabricante, modelo e MAC', () async {
      final net = _FakeNet()..roku('10.0.0.4');
      final d = await net.probe().probe('10.0.0.4');
      expect(d?.protocol, RemoteProtocol.roku);
      expect(d?.name, 'TV Quarto');
      expect(d?.model, 'Philco PTV50RCG70BL');
      expect(d?.macAddress, '11:22:33:44:55:66');
    });

    test('Philips JointSpace: tenta v6, v5 e v1', () async {
      final net = _FakeNet()..philips('10.0.0.5', version: 1);
      final d = await net.probe().probe('10.0.0.5');
      expect(d?.protocol, RemoteProtocol.philipsJointSpace);
      expect(d?.port, 1925);
      expect(d?.model, '50PUG6654/78');
    });

    test('Sony Bravia: getInterfaceInformation sem PSK', () async {
      final net = _FakeNet()..sony('10.0.0.6');
      final d = await net.probe().probe('10.0.0.6');
      expect(d?.protocol, RemoteProtocol.sonyBravia);
      expect(d?.name, 'BRAVIA Sala');
      expect(d?.model, 'KD-55X80J');
    });

    test('Sony com Google TV: Android TV vence o IRCC', () async {
      final net = _FakeNet()..sony('10.0.0.7');
      net.open['10.0.0.7']!.add(6466);
      final d = await net.probe().probe('10.0.0.7', hints: const HostHints(manufacturer: 'Sony Corporation'));
      expect(d?.protocol, RemoteProtocol.androidTv);
      expect(d?.port, 6466);
    });

    test('LG: só 3000 aberta exige marca conhecida; 3000+3001 basta', () async {
      final net = _FakeNet()..open['10.0.0.8'] = {3000};
      expect(await net.probe().probe('10.0.0.8'), isNull);
      final hinted = await net.probe().probe(
        '10.0.0.8',
        hints: const HostHints(manufacturer: 'LG Electronics', name: 'LG webOS TV'),
      );
      expect(hinted?.protocol, RemoteProtocol.lgWebOs);
      expect(hinted?.name, 'LG webOS TV');
      net.open['10.0.0.8']!.add(3001);
      expect((await net.probe().probe('10.0.0.8'))?.protocol, RemoteProtocol.lgWebOs);
    });

    test('marca sem suporte não é sondada', () async {
      final net = _FakeNet()..open['10.0.0.9'] = {8060, 6466};
      final d = await net.probe().probe('10.0.0.9', hints: const HostHints(manufacturer: 'Amazon'));
      expect(d, isNull);
      expect(net.requests, isEmpty);
    });

    test('pistas preenchem nome/MAC quando a sonda não traz', () async {
      final net = _FakeNet()..open['10.0.0.10'] = {6466};
      final d = await net.probe().probe(
        '10.0.0.10',
        hints: const HostHints(name: 'Sala', manufacturer: 'Philco', mac: 'a1b2c3d4e5f6', serviceName: 'Sala'),
      );
      expect(d?.protocol, RemoteProtocol.androidTv);
      expect(d?.name, 'Sala');
      expect(d?.macAddress, 'A1:B2:C3:D4:E5:F6');
      expect(d?.serviceName, 'Sala');
    });

    test('host sem nada aberto devolve null sem lançar', () async {
      expect(await _FakeNet().probe().probe('10.0.0.11'), isNull);
    });

    test('decodifica entidades XML em nomes e modelos', () async {
      final net = _FakeNet()..roku('10.0.0.12', model: '43&quot; FHD &amp; HDR');
      final d = await net.probe().probe('10.0.0.12');
      expect(d?.model, 'Philco 43" FHD & HDR');
      expect(decodeXmlEntities('TV &#39;Sala&#x27; &lt;1&gt; &zz;'), "TV 'Sala' <1> &zz;");
      expect(decodeXmlEntities('43&amp;quot; FHD'), '43" FHD');
      const raw = DiscoveredDevice(
        name: '43&quot; FHD',
        host: '1.2.3.4',
        port: 6466,
        protocol: RemoteProtocol.androidTv,
      );
      expect(raw.normalized().name, '43" FHD');
    });

    test('normaliza MAC em vários formatos', () {
      expect(HostProbe.normalizeMac('aa-bb-cc-dd-ee-ff'), 'AA:BB:CC:DD:EE:FF');
      expect(HostProbe.normalizeMac('AABBCCDDEEFF'), 'AA:BB:CC:DD:EE:FF');
      expect(HostProbe.normalizeMac('xyz'), isNull);
      expect(HostProbe.normalizeMac(null), isNull);
    });
  });

  group('SsdpDiscovery.handle', () {
    test('resposta root genérica com fabricante conhecido leva à sonda', () async {
      final net = _FakeNet()..samsung('10.0.0.20');
      net.responses['GET 10.0.0.20:7676/smp_2_'] = http.Response(
        '<root><device><manufacturer>Samsung Electronics</manufacturer><friendlyName>[TV] Sala</friendlyName>'
        '<modelName>UN55AU7700</modelName></device></root>',
        200,
      );
      final ssdp = SsdpDiscovery(client: net.client(), probe: net.probe());
      final out = StreamController<DiscoveredDevice>();
      final got = <DiscoveredDevice>[];
      out.stream.listen(got.add);
      final f = ssdp.handle(
        'HTTP/1.1 200 OK\r\nST: upnp:rootdevice\r\nLOCATION: http://10.0.0.20:7676/smp_2_\r\nSERVER: Samsung UPnP SDK/1.0\r\n\r\n',
        '10.0.0.20',
        {},
        {},
        out,
      );
      await f;
      await out.close();
      expect(got.single.protocol, RemoteProtocol.samsungTizen);
      expect(got.single.port, 8002);
    });

    test('resposta root de fabricante desconhecido é ignorada sem sondar', () async {
      final net = _FakeNet();
      net.responses['GET 10.0.0.21:80/desc.xml'] = http.Response(
        '<root><device><manufacturer>Acme Routers</manufacturer></device></root>',
        200,
      );
      final ssdp = SsdpDiscovery(client: net.client(), probe: net.probe());
      final out = StreamController<DiscoveredDevice>();
      final got = <DiscoveredDevice>[];
      out.stream.listen(got.add);
      await ssdp.handle(
        'HTTP/1.1 200 OK\r\nST: upnp:rootdevice\r\nLOCATION: http://10.0.0.21/desc.xml\r\n\r\n',
        '10.0.0.21',
        {},
        {},
        out,
      );
      await out.close();
      expect(got, isEmpty);
      expect(net.requests.length, 1);
    });

    test('ST específico classifica direto e descreve pela LOCATION', () async {
      final net = _FakeNet();
      net.responses['GET 10.0.0.22:8060/'] = http.Response(
        '<root><device><friendlyName>Roku Sala</friendlyName><modelName>3810X</modelName></device></root>',
        200,
      );
      final ssdp = SsdpDiscovery(client: net.client(), probe: net.probe());
      final out = StreamController<DiscoveredDevice>();
      final got = <DiscoveredDevice>[];
      out.stream.listen(got.add);
      await ssdp.handle(
        'HTTP/1.1 200 OK\r\nST: roku:ecp\r\nLOCATION: http://10.0.0.22:8060/\r\n\r\n',
        '10.0.0.22',
        {},
        {},
        out,
      );
      await out.close();
      expect(got.single.protocol, RemoteProtocol.roku);
      expect(got.single.name, 'Roku Sala');
    });
  });

  group('SubnetSweepDiscovery', () {
    test('acha aparelhos pelas portas de assinatura e confirma pela sonda', () async {
      final net = _FakeNet()
        ..samsung('192.168.0.10')
        ..roku('192.168.0.20')
        ..open['192.168.0.30'] = {6466, 8009}
        ..open['192.168.0.40'] = {3000}; // só 3000: não é webOS confirmado
      final sweep = SubnetSweepDiscovery(
        probe: net.probe(),
        portCheck: net.portCheck,
        subnets: () async => ['192.168.0'],
        concurrency: 16,
      );
      final found = await sweep.discover().toList();
      final byHost = {for (final d in found) d.host: d};
      expect(byHost.keys, unorderedEquals(['192.168.0.10', '192.168.0.20', '192.168.0.30']));
      expect(byHost['192.168.0.10']?.protocol, RemoteProtocol.samsungTizen);
      expect(byHost['192.168.0.20']?.protocol, RemoteProtocol.roku);
      expect(byHost['192.168.0.30']?.protocol, RemoteProtocol.androidTv);
    });

    test('sem rede local termina vazio', () async {
      final sweep = SubnetSweepDiscovery(probe: _FakeNet().probe(), subnets: () async => []);
      expect(await sweep.discover().toList(), isEmpty);
    });
  });

  group('NetworkScanner profundo e identificação', () {
    test('scanDeep usa a descoberta profunda e mescla na lista', () async {
      final disc = _Static(const []);
      final deep = _Static(const [
        DiscoveredDevice(name: 'Samsung', host: '10.0.0.2', port: 8002, protocol: RemoteProtocol.samsungTizen),
      ]);
      final scanner = NetworkScanner(disc, deep: deep);
      expect(scanner.canScanDeep, isTrue);
      final found = await scanner.scanDeep();
      expect(found.single.protocol, RemoteProtocol.samsungTizen);
      expect(scanner.found.length, 1);
      expect(scanner.deepScanning, isFalse);
    });

    test('identify sonda o host e registra o achado', () async {
      final net = _FakeNet()..roku('10.0.0.4');
      final scanner = NetworkScanner(_Static(const []), identifier: net.probe());
      expect(scanner.canIdentify, isTrue);
      final d = await scanner.identify('10.0.0.4');
      expect(d?.protocol, RemoteProtocol.roku);
      expect(scanner.found.single.host, '10.0.0.4');
      expect(await scanner.identify('10.0.0.99'), isNull);
    });

    test('sem profundo nem identificador, os recursos ficam desligados', () async {
      final scanner = NetworkScanner(_Static(const []));
      expect(scanner.canScanDeep, isFalse);
      expect(scanner.canIdentify, isFalse);
      expect(await scanner.identify('10.0.0.1'), isNull);
    });
  });
}

class _Static implements DeviceDiscovery {
  _Static(this.items);
  final List<DiscoveredDevice> items;
  @override
  Stream<DiscoveredDevice> discover({Duration timeout = const Duration(seconds: 6)}) => Stream.fromIterable(items);
}
