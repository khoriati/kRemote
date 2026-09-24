/// Estado da conexão com um dispositivo.
enum DeviceConnectionState { disconnected, connecting, connected, needsPairing, error }

/// Capacidades opcionais de um controlador.
enum RemoteCapability { textInput, appLaunch, wakeOnLan, volumeLevel }
