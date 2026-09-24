import '../entities/remote_device.dart';

/// Porta de saída: persistência dos dispositivos cadastrados.
abstract class DeviceRepository {
  Future<List<RemoteDevice>> loadAll();
  Future<void> saveAll(List<RemoteDevice> devices);
}
