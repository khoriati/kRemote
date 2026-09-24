import '../entities/remote_device.dart';

/// Porta de saída: descoberta de dispositivos na rede local.
abstract class DeviceDiscovery {
  /// Emite dispositivos conforme são encontrados até [timeout].
  Stream<DiscoveredDevice> discover({Duration timeout = const Duration(seconds: 6)});
}
