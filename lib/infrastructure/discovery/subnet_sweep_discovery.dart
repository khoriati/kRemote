import 'dart:async';
import 'dart:io';

import '../../domain/entities/remote_device.dart';
import '../../domain/ports/device_discovery.dart';
import '../net/log.dart';
import 'brand_catalog.dart';
import 'host_probe.dart';

/// Lista as redes IPv4 locais (endereço + prefixo /24) a varrer.
typedef SubnetLister = Future<List<String>> Function();

/// Varredura ativa da sub-rede: testa as portas de assinatura de cada
/// protocolo ([BrandCatalog.signaturePorts]) em todos os hosts da(s) rede(s)
/// /24 do celular e confirma pela [HostProbe].
///
/// Não depende de multicast nem de anúncio da TV — encontra aparelhos que
/// não respondem a mDNS/SSDP (Wi-Fi com isolamento de multicast, firmware
/// antigo, iOS sem a entitlement de multicast). É mais lenta e barulhenta,
/// por isso só roda a pedido do usuário (*Varrer toda a rede*).
class SubnetSweepDiscovery implements DeviceDiscovery {
  SubnetSweepDiscovery({
    HostProbe? probe,
    PortCheck? portCheck,
    SubnetLister? subnets,
    this.concurrency = 48,
    this.connectTimeout = const Duration(milliseconds: 800),
  }) : _probe = probe ?? HostProbe(portCheck: portCheck),
       _portCheck = portCheck,
       _subnets = subnets ?? localSubnets;

  final HostProbe _probe;
  final PortCheck? _portCheck;
  final SubnetLister _subnets;
  final int concurrency;
  final Duration connectTimeout;

  /// Prefixos /24 das interfaces IPv4 locais (ex.: `192.168.0`), sem loopback
  /// nem link-local.
  static Future<List<String>> localSubnets() async {
    final out = <String>{};
    try {
      for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4, includeLinkLocal: false)) {
        for (final a in i.addresses) {
          if (a.isLoopback || a.isLinkLocal) continue;
          final parts = a.address.split('.');
          if (parts.length == 4) out.add(parts.take(3).join('.'));
        }
      }
    } catch (e) {
      KLog.d('sweep', 'interfaces indisponíveis: $e');
    }
    return out.toList();
  }

  Future<bool> _open(String host, int port) =>
      _portCheck?.call(host, port) ?? HostProbe.tcpCheck(host, port, timeout: connectTimeout);

  @override
  Stream<DiscoveredDevice> discover({Duration timeout = const Duration(seconds: 6)}) {
    final ctrl = StreamController<DiscoveredDevice>();
    var cancelled = false;

    Future<void> run() async {
      final subnets = await _subnets();
      if (subnets.isEmpty) {
        KLog.d('sweep', 'nenhuma rede IPv4 local');
        await ctrl.close();
        return;
      }
      final ports = BrandCatalog.allSignaturePorts;
      final tasks = <(String, int)>[
        for (final s in subnets)
          for (var h = 1; h < 255; h++)
            for (final p in ports) ('$s.$h', p),
      ];
      KLog.d('sweep', 'varrendo ${subnets.join(', ')} (${tasks.length} sondas)');
      final openByHost = <String, Set<int>>{};
      var next = 0;
      Future<void> worker() async {
        while (!cancelled && next < tasks.length) {
          final (host, port) = tasks[next++];
          if (await _open(host, port)) openByHost.putIfAbsent(host, () => {}).add(port);
        }
      }

      await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
      KLog.d('sweep', '${openByHost.length} host(s) com portas de interesse');
      final seen = <String>{};
      for (final e in openByHost.entries) {
        if (cancelled) break;
        // Candidatos na ordem do catálogo, restritos ao que as portas sugerem.
        final suggested = e.value.expand(BrandCatalog.protocolsForPort).toSet();
        final candidates = BrandCatalog.probeOrder.where(suggested.contains).toList();
        final dev = await _probe.probe(e.key, candidates: candidates);
        if (dev != null && seen.add(dev.key) && !ctrl.isClosed) ctrl.add(dev);
      }
      await ctrl.close();
    }

    ctrl.onListen = run;
    ctrl.onCancel = () => cancelled = true;
    return ctrl.stream;
  }
}
