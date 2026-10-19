import '../xml_entities.dart';

/// Protocolo de controle suportado.
enum RemoteProtocol {
  androidTv(
    'Google TV / Android TV',
    'Chromecast com Google TV, Sony, TCL/Semp, Philips, Philco, AIWA, Multilaser, ViewSonic, Xiaomi, Nvidia Shield…',
  ),
  cast('Chromecast (Cast)', 'Chromecast clássico, Google Nest Hub e caixas com Cast integrado'),
  samsungTizen('Samsung (Tizen)', 'Smart TVs Samsung a partir de 2016 (porta 8002; 2016–2017 sem token: 8001)'),
  lgWebOs('LG (webOS)', 'Smart TVs LG com webOS (2014+); porta 3000 ou 3001 (TLS)'),
  roku('Roku', 'Roku TV (Philco, TCL/Semp, AIWA, Hisense…), Roku Express/Streaming Stick'),
  sonyBravia('Sony Bravia (IRCC)', 'Bravia não-Android com Pre-Shared Key configurada'),
  philipsJointSpace('Philips (JointSpace)', 'TVs Philips não-Android (JointSpace v1/v5/v6, porta 1925)'),
  vizioSmartCast('Vizio SmartCast', 'TVs Vizio SmartCast'),
  bluetoothHid(
    'Teclado Bluetooth (PC/Mac)',
    'Celular como teclado HID: apresentações, mídia e volume — somente Android',
  );

  const RemoteProtocol(this.label, this.hint);

  final String label;
  final String hint;

  /// Porta padrão do protocolo usada quando o dispositivo é adicionado
  /// manualmente por IP.
  int get defaultPort => switch (this) {
    androidTv => 6466,
    cast => 8009,
    samsungTizen => 8002,
    lgWebOs => 3000,
    roku => 8060,
    sonyBravia => 80,
    philipsJointSpace => 1925,
    vizioSmartCast => 7345,
    bluetoothHid => 0,
  };

  /// Protocolos de rede (adicionáveis por IP).
  bool get isNetwork => this != bluetoothHid;

  /// Porta que continua respondendo com o aparelho em repouso, se houver.
  /// Na Google TV é o receptor Cast (8009), que fica vivo em standby e serve
  /// para distinguir "desligada" de "fora da rede" — e para acordá-la.
  int? get standbyPort => switch (this) {
    androidTv => cast.defaultPort,
    _ => null,
  };

  /// Indica se o protocolo exige emparelhamento antes de controlar.
  bool get requiresPairing => switch (this) {
    androidTv || samsungTizen || lgWebOs || vizioSmartCast || sonyBravia => true,
    cast || roku || philipsJointSpace || bluetoothHid => false,
  };
}

/// Dispositivo controlável cadastrado no app.
class RemoteDevice {
  const RemoteDevice({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.protocol,
    this.model,
    this.macAddress,
    this.pairingPort,
    this.volumeViaCast = false,
    this.serviceName,
    this.bluetoothAddress,
    this.lastConnectedAt,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final RemoteProtocol protocol;
  final String? model;

  /// MAC usado para Wake-on-LAN (Samsung, LG, Sony, Philips).
  final String? macAddress;

  /// Porta de emparelhamento (Android TV usa 6467).
  final int? pairingPort;

  /// Google TV: ajustar volume/mudo pelo protocolo Cast (porta 8009) em vez de
  /// injetar teclas. Várias TVs (ex.: Philips) recusam a tecla de volume com
  /// "use um controle remoto", mas aceitam o volume via Cast, como faz o
  /// app Google Home.
  final bool volumeViaCast;

  /// Endereço Bluetooth da TV, quando o celular foi pareado a ela como
  /// teclado HID. Permite ligá-la mesmo com o Wi-Fi desligado em repouso
  /// (somente Android, que pode atuar como periférico HID).
  final String? bluetoothAddress;

  /// Nome da instância mDNS/SSDP com que o aparelho foi descoberto. É a
  /// identidade estável usada para reencontrá-lo quando o IP muda (roteador
  /// reiniciado, troca de Wi-Fi). `null` para cadastro manual por IP.
  final String? serviceName;

  /// Última vez em que uma sessão de controle foi estabelecida com sucesso.
  /// Prova de que o emparelhamento atual já funcionou: a partir daí, uma
  /// conexão fechada pela TV sem alerta TLS é tratada como falha transitória,
  /// nunca como "precisa emparelhar de novo".
  final DateTime? lastConnectedAt;

  bool get everConnected => lastConnectedAt != null;

  RemoteDevice copyWith({
    String? name,
    String? host,
    int? port,
    String? model,
    String? macAddress,
    bool clearMac = false,
    int? pairingPort,
    bool? volumeViaCast,
    String? serviceName,
    String? bluetoothAddress,
    bool clearBluetooth = false,
    DateTime? lastConnectedAt,
    bool clearLastConnected = false,
  }) => RemoteDevice(
    id: id,
    name: name ?? this.name,
    host: host ?? this.host,
    port: port ?? this.port,
    protocol: protocol,
    model: model ?? this.model,
    macAddress: clearMac ? null : (macAddress ?? this.macAddress),
    pairingPort: pairingPort ?? this.pairingPort,
    volumeViaCast: volumeViaCast ?? this.volumeViaCast,
    serviceName: serviceName ?? this.serviceName,
    bluetoothAddress: clearBluetooth ? null : (bluetoothAddress ?? this.bluetoothAddress),
    lastConnectedAt: clearLastConnected ? null : (lastConnectedAt ?? this.lastConnectedAt),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'protocol': protocol.name,
    'model': model,
    'macAddress': macAddress,
    'pairingPort': pairingPort,
    'volumeViaCast': volumeViaCast,
    'serviceName': serviceName,
    'bluetoothAddress': bluetoothAddress,
    'lastConnectedAt': lastConnectedAt?.toIso8601String(),
  };

  factory RemoteDevice.fromJson(Map<String, dynamic> json) => RemoteDevice(
    id: json['id'] as String,
    name: json['name'] as String,
    host: json['host'] as String,
    port: json['port'] as int,
    protocol: RemoteProtocol.values.byName(json['protocol'] as String),
    model: json['model'] as String?,
    macAddress: json['macAddress'] as String?,
    pairingPort: json['pairingPort'] as int?,
    volumeViaCast: json['volumeViaCast'] as bool? ?? false,
    serviceName: json['serviceName'] as String?,
    bluetoothAddress: json['bluetoothAddress'] as String?,
    lastConnectedAt: json['lastConnectedAt'] is String ? DateTime.tryParse(json['lastConnectedAt'] as String) : null,
  );

  @override
  bool operator ==(Object other) => other is RemoteDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'RemoteDevice($name, ${protocol.name}, $host:$port)';
}

/// Dispositivo encontrado na rede, ainda não cadastrado.
class DiscoveredDevice {
  const DiscoveredDevice({
    required this.name,
    required this.host,
    required this.port,
    required this.protocol,
    this.model,
    this.macAddress,
    this.serviceName,
  });

  final String name;
  final String host;
  final int port;
  final RemoteProtocol protocol;
  final String? model;
  final String? macAddress;

  /// Nome do serviço mDNS/SSDP (útil para Android TV).
  final String? serviceName;

  String get key => '${protocol.name}@$host:$port';

  /// Cópia com nome e modelo sem entidades XML/HTML (`43&quot; FHD` → `43" FHD`),
  /// que chegam escapadas de descrições UPnP, TXT mDNS e `device-info`.
  DiscoveredDevice normalized() {
    final n = decodeXmlEntities(name);
    final m = model == null ? null : decodeXmlEntities(model!);
    if (n == name && m == model) return this;
    return DiscoveredDevice(
      name: n,
      host: host,
      port: port,
      protocol: protocol,
      model: m,
      macAddress: macAddress,
      serviceName: serviceName,
    );
  }

  RemoteDevice toDevice() => RemoteDevice(
    id: '${protocol.name}-${host.replaceAll('.', '-')}-$port',
    name: name,
    host: host,
    port: port,
    protocol: protocol,
    model: model,
    macAddress: macAddress,
    pairingPort: protocol == RemoteProtocol.androidTv ? 6467 : null,
    // Chromecast com Google TV manda volume à TV por CEC a partir da tecla;
    // TVs com Google TV embutida costumam recusar a tecla e aceitar o Cast.
    volumeViaCast: protocol == RemoteProtocol.androidTv && !(model ?? '').toLowerCase().startsWith('chromecast'),
    serviceName: serviceName,
  );
}
