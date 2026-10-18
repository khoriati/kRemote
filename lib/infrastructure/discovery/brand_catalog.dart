import '../../domain/entities/remote_device.dart';

/// Tabelas de parâmetros por fabricante/protocolo usadas pela descoberta.
///
/// Este arquivo é a **única fonte** do que o app sabe sobre como cada marca
/// se anuncia na rede e como confirmar o protocolo de controle num host:
///
/// - [mdnsTypes]: tipos de serviço Bonjour/NSD que identificam o protocolo
///   diretamente (Google TV, Cast, Vizio, Philips JointSpace).
/// - [mdnsHintTypes]: tipos anunciados por quase toda Smart TV moderna
///   (AirPlay 2, HomeKit) cujo TXT traz `manufacturer`/`model`. Não dizem o
///   protocolo, mas entregam o host e a marca; a sonda confirma o resto.
///   É o caminho que funciona no iOS sem a entitlement de multicast.
/// - [ssdpTargets]: alvos `M-SEARCH` e a regra de classificação da resposta.
/// - [brands]: marca → protocolos candidatos em ordem de preferência, com
///   observações para a interface (ex.: Philco pode ser Google TV ou Roku TV).
/// - [signaturePorts]: portas que identificam cada protocolo numa varredura.
///
/// Para suportar uma marca nova, basta acrescentar linhas aqui (e, se for
/// um tipo mDNS novo, em `NSBonjourServices` no `Info.plist`).
class BrandCatalog {
  BrandCatalog._();

  // ---------------------------------------------------------------------
  // mDNS / Bonjour
  // ---------------------------------------------------------------------

  /// Tipos de serviço que identificam o protocolo sem sonda adicional.
  /// Todos devem constar em `NSBonjourServices` (iOS).
  static const mdnsTypes = <String, RemoteProtocol>{
    '_androidtvremote2._tcp': RemoteProtocol.androidTv,
    '_googlecast._tcp': RemoteProtocol.cast,
    '_viziocast._tcp': RemoteProtocol.vizioSmartCast,
    // Philips JointSpace: TVs 2016+ (não-Android) anunciam a API HTTP 1925.
    // O tipo seguro (1926) tem 16 caracteres e é recusado pelo NsdManager
    // do Android; no iOS funciona. Ambos são JointSpace.
    '_philipstv_rpc._tcp': RemoteProtocol.philipsJointSpace,
    '_philipstv_s_rpc._tcp': RemoteProtocol.philipsJointSpace,
  };

  /// Tipos "pista": entregam host + fabricante no TXT; a sonda decide.
  /// `_airplay._tcp` é anunciado por Samsung (2018+), LG (2019+), Sony,
  /// Roku (OS 9.4+), Vizio e Philips; `_hap._tcp` (HomeKit) por LG/Vizio/Roku.
  static const mdnsHintTypes = <String>['_airplay._tcp', '_hap._tcp'];

  /// Chaves do TXT que podem conter o fabricante, por ordem de confiança.
  static const txtManufacturerKeys = ['manufacturer', 'mf', 'vn', 'vendor'];

  /// Chaves do TXT que podem conter o modelo.
  static const txtModelKeys = ['model', 'md', 'am'];

  /// Chaves do TXT que podem conter o MAC (AirPlay usa `deviceid`).
  static const txtMacKeys = ['deviceid', 'mac'];

  // ---------------------------------------------------------------------
  // SSDP / UPnP
  // ---------------------------------------------------------------------

  /// Alvos `M-SEARCH`. Os específicos identificam o protocolo pelo `ST`; os
  /// genéricos (`ssdp:all`, `upnp:rootdevice`) pegam TVs que não respondem
  /// ao alvo da marca (firmware antigo, ou que só respondem a root) e são
  /// classificados pelos cabeçalhos e pela descrição XML.
  static const ssdpTargets = <String, RemoteProtocol?>{
    'urn:samsung.com:device:RemoteControlReceiver:1': RemoteProtocol.samsungTizen,
    'urn:samsung.com:service:MainTVAgent2:1': RemoteProtocol.samsungTizen,
    'urn:lge-com:service:webos-second-screen:1': RemoteProtocol.lgWebOs,
    'roku:ecp': RemoteProtocol.roku,
    'urn:schemas-sony-com:service:IRCC:1': RemoteProtocol.sonyBravia,
    'urn:schemas-sony-com:service:ScalarWebAPI:1': RemoteProtocol.sonyBravia,
    'urn:philips-com:device:DirectFBRemote:1': RemoteProtocol.philipsJointSpace,
    'urn:dial-multiscreen-org:service:dial:1': null,
    'upnp:rootdevice': null,
    'ssdp:all': null,
  };

  /// Classifica uma resposta SSDP pelos cabeçalhos (`ST`, `USN`, `SERVER`).
  /// Devolve `null` quando só a descrição XML / sonda podem decidir.
  static RemoteProtocol? classifySsdp(Map<String, String> headers) {
    final st = headers['ST'] ?? '';
    final direct = ssdpTargets[st];
    if (direct != null) return direct;
    final blob = '${headers['ST']} ${headers['USN']} ${headers['SERVER']}'.toLowerCase();
    if (blob.contains('roku')) return RemoteProtocol.roku;
    if (blob.contains('webos') || blob.contains('lge-com')) return RemoteProtocol.lgWebOs;
    if (blob.contains('samsung') && (blob.contains('remotecontrolreceiver') || blob.contains('maintvagent'))) {
      return RemoteProtocol.samsungTizen;
    }
    if (blob.contains('ircc') || blob.contains('scalarwebapi')) return RemoteProtocol.sonyBravia;
    if (blob.contains('directfbremote')) return RemoteProtocol.philipsJointSpace;
    return null;
  }

  // ---------------------------------------------------------------------
  // Marcas
  // ---------------------------------------------------------------------

  /// Marca → protocolos candidatos, em ordem de tentativa.
  ///
  /// A chave é um fragmento em minúsculas procurado no fabricante/modelo
  /// (TXT do mDNS, `<manufacturer>` UPnP, `vendor-name` do Roku, hostname).
  static const brands = <String, BrandInfo>{
    'samsung': BrandInfo('Samsung', [
      RemoteProtocol.samsungTizen,
    ], note: 'Tizen 2016+. Modelos 2011–2015 (porta 55000) não são suportados.'),
    'lg': BrandInfo('LG', [RemoteProtocol.lgWebOs], note: 'webOS 2014+. NetCast (anterior a 2014) não é suportado.'),
    'sony': BrandInfo('Sony', [
      RemoteProtocol.androidTv,
      RemoteProtocol.sonyBravia,
    ], note: 'Bravia Android/Google TV pelo protocolo Android TV; demais por IRCC com PSK.'),
    'philips': BrandInfo('Philips', [
      RemoteProtocol.androidTv,
      RemoteProtocol.philipsJointSpace,
    ], note: 'Philips Android/Google TV pelo protocolo Android TV; demais por JointSpace.'),
    'tp vision': BrandInfo('Philips', [RemoteProtocol.androidTv, RemoteProtocol.philipsJointSpace]),
    'roku': BrandInfo('Roku', [RemoteProtocol.roku]),
    'vizio': BrandInfo('Vizio', [RemoteProtocol.vizioSmartCast]),
    'google': BrandInfo('Google', [RemoteProtocol.androidTv, RemoteProtocol.cast]),
    'tcl': BrandInfo('TCL / Semp', [
      RemoteProtocol.androidTv,
      RemoteProtocol.roku,
    ], note: 'Linhas Google TV/Android TV e Roku TV.'),
    'semp': BrandInfo('TCL / Semp', [RemoteProtocol.androidTv, RemoteProtocol.roku]),
    'philco': BrandInfo('Philco', [
      RemoteProtocol.androidTv,
      RemoteProtocol.roku,
    ], note: 'Philco Google TV e Philco Roku TV. Modelos Linux antigos não têm controle por rede.'),
    'aiwa': BrandInfo('AIWA', [RemoteProtocol.androidTv, RemoteProtocol.roku]),
    'multilaser': BrandInfo('Multilaser', [RemoteProtocol.androidTv]),
    'viewsonic': BrandInfo('ViewSonic', [
      RemoteProtocol.androidTv,
      RemoteProtocol.cast,
    ], note: 'Displays/projetores inteligentes com Android ou Cast integrado.'),
    'xiaomi': BrandInfo('Xiaomi', [RemoteProtocol.androidTv]),
    'mi tv': BrandInfo('Xiaomi', [RemoteProtocol.androidTv]),
    'nvidia': BrandInfo('NVIDIA', [RemoteProtocol.androidTv]),
    'sharp': BrandInfo('Sharp', [RemoteProtocol.androidTv, RemoteProtocol.roku]),
    'hisense': BrandInfo('Hisense', [
      RemoteProtocol.androidTv,
      RemoteProtocol.roku,
    ], note: 'Modelos Android/Google TV e Roku TV. VIDAA ainda não é suportado.'),
    'toshiba': BrandInfo('Toshiba', [
      RemoteProtocol.androidTv,
    ], note: 'Modelos VIDAA e Fire TV ainda não são suportados.'),
    'panasonic': BrandInfo('Panasonic', [
      RemoteProtocol.androidTv,
    ], note: 'Modelos Google TV; Viera (My Home Screen) ainda não é suportado.'),
    'jvc': BrandInfo('JVC', [RemoteProtocol.androidTv, RemoteProtocol.roku]),
    'britania': BrandInfo('Britânia', [RemoteProtocol.androidTv, RemoteProtocol.roku]),
    'insignia': BrandInfo('Insignia', [RemoteProtocol.roku], note: 'Modelos Fire TV não são suportados.'),
    'onn': BrandInfo('onn.', [RemoteProtocol.roku, RemoteProtocol.androidTv]),
    'hitachi': BrandInfo('Hitachi', [RemoteProtocol.roku, RemoteProtocol.androidTv]),
    'element': BrandInfo('Element', [RemoteProtocol.roku]),
    'westinghouse': BrandInfo('Westinghouse', [RemoteProtocol.roku]),
    'amazon': BrandInfo('Amazon', [], note: 'Fire TV (ADB) ainda não é suportado.'),
    'apple': BrandInfo('Apple', [], note: 'Apple TV ainda não é suportado.'),
  };

  /// Identifica a marca num texto livre (fabricante, modelo, hostname).
  static BrandInfo? brandOf(String? text) {
    if (text == null || text.isEmpty) return null;
    final t = text.toLowerCase();
    // Correspondência por palavra para marcas curtas ("lg", "onn") não
    // casarem dentro de outras palavras ("google", "connect").
    for (final e in brands.entries) {
      final k = e.key;
      final matched = k.length <= 3 ? RegExp('(^|[^a-z])${RegExp.escape(k)}([^a-z]|\$)').hasMatch(t) : t.contains(k);
      if (matched) return e.value;
    }
    return null;
  }

  /// Protocolos a sondar num host sobre o qual só se conhece a marca.
  /// Sem marca, sonda todos os protocolos de rede.
  static List<RemoteProtocol> candidatesFor(String? manufacturerOrModel) {
    final brand = brandOf(manufacturerOrModel);
    if (brand != null) return brand.protocols;
    return probeOrder;
  }

  // ---------------------------------------------------------------------
  // Portas
  // ---------------------------------------------------------------------

  /// Ordem de sonda quando a marca é desconhecida: primeiro o que confirma
  /// por HTTP (identidade forte), por último o que só abre TCP.
  static const probeOrder = <RemoteProtocol>[
    RemoteProtocol.androidTv,
    RemoteProtocol.samsungTizen,
    RemoteProtocol.roku,
    RemoteProtocol.philipsJointSpace,
    RemoteProtocol.sonyBravia,
    RemoteProtocol.lgWebOs,
    RemoteProtocol.vizioSmartCast,
    RemoteProtocol.cast,
  ];

  /// Portas que, abertas, sugerem o protocolo (varredura de sub-rede).
  /// Samsung 8001 é a API de informações (HTTP), sempre ligada no Tizen.
  static const signaturePorts = <RemoteProtocol, List<int>>{
    RemoteProtocol.androidTv: [6466],
    RemoteProtocol.cast: [8009],
    RemoteProtocol.samsungTizen: [8001],
    RemoteProtocol.lgWebOs: [3000, 3001],
    RemoteProtocol.roku: [8060],
    RemoteProtocol.sonyBravia: [80],
    RemoteProtocol.philipsJointSpace: [1925],
    RemoteProtocol.vizioSmartCast: [7345, 9000],
  };

  /// Todas as portas de assinatura, sem repetição.
  static List<int> get allSignaturePorts => signaturePorts.values.expand((p) => p).toSet().toList()..sort();

  /// Protocolos cuja porta de assinatura é [port].
  static List<RemoteProtocol> protocolsForPort(int port) => [
    for (final e in signaturePorts.entries)
      if (e.value.contains(port)) e.key,
  ];
}

/// Dados de uma marca no catálogo.
class BrandInfo {
  const BrandInfo(this.label, this.protocols, {this.note});

  /// Nome de exibição.
  final String label;

  /// Protocolos em ordem de tentativa; vazio = marca reconhecida, sem suporte.
  final List<RemoteProtocol> protocols;

  /// Observação para a interface (modelos suportados ou não).
  final String? note;

  bool get isSupported => protocols.isNotEmpty;
}
