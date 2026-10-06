/// Estado da conexão com um dispositivo.
///
/// [standby]: o aparelho está na rede em repouso — o serviço de controle não
/// responde, mas a porta de repouso (receptor Cast) sim. Não é falha.
enum DeviceConnectionState { disconnected, connecting, connected, needsPairing, error, standby }

/// Presença de um aparelho na rede.
///
/// [standby]: só a porta de repouso responde (Google TV desligada com
/// "standby em rede"); dá para ligá-la, mas não para controlá-la ainda.
enum Presence { online, standby, offline }

/// Capacidades opcionais de um controlador.
enum RemoteCapability { textInput, appLaunch, wakeOnLan, volumeLevel }
