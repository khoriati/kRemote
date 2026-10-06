/// Protocolo de controle suportado.
enum RemoteProtocol {
  androidTv(
    'Google TV / Android TV',
    'Chromecast com Google TV, Sony, TCL, Philips (Android TV), Xiaomi, Nvidia Shield…',
  ),
  cast('Chromecast (Cast)', 'Chromecast clássico, Google Nest Hub e caixas com Cast integrado'),
  samsungTizen('Samsung (Tizen)', 'Smart TVs Samsung a partir de 2016'),
  lgWebOs('LG (webOS)', 'Smart TVs LG com webOS'),
  roku('Roku', 'Roku TV, Roku Express/Streaming Stick'),
  sonyBravia('Sony Bravia (IRCC)', 'Bravia com Pre-Shared Key configurada'),
  philipsJointSpace('Philips (JointSpace)', 'TVs Philips não-Android (JointSpace v1/v5)'),
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

  /// Nome da instância mDNS/SSDP com que o aparelho foi descoberto. É a
  /// identidade estável usada para reencontrá-lo quando o IP muda (roteador
  /// reiniciado, troca de Wi-Fi). `null` para cadastro manual por IP.
  final String? serviceName;

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
