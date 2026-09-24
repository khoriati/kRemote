import 'dart:async';

import 'package:kremote/domain/entities/remote_device.dart';
import 'package:kremote/domain/ports/certificate_pin_store.dart';
import 'package:kremote/domain/ports/credential_store.dart';
import 'package:kremote/domain/ports/device_discovery.dart';
import 'package:kremote/domain/ports/device_repository.dart';

class MemoryPinStore implements CertificatePinStore {
  final Map<String, String> pins = {};
  @override
  Future<String?> read(String deviceId) async => pins[deviceId];
  @override
  Future<void> write(String deviceId, String sha256Hex) async => pins[deviceId] = sha256Hex;
  @override
  Future<void> delete(String deviceId) async => pins.remove(deviceId);
}

class MemoryCredentialStore implements CredentialStore {
  final Map<String, Map<String, String>> data = {};
  @override
  Future<Map<String, String>?> read(String deviceId) async => data[deviceId];
  @override
  Future<void> write(String deviceId, Map<String, String> credentials) async => data[deviceId] = Map.of(credentials);
  @override
  Future<void> delete(String deviceId) async => data.remove(deviceId);
}

class MemoryDeviceRepository implements DeviceRepository {
  List<RemoteDevice> saved = [];
  @override
  Future<List<RemoteDevice>> loadAll() async => List.of(saved);
  @override
  Future<void> saveAll(List<RemoteDevice> devices) async => saved = List.of(devices);
}

class FakeDiscovery implements DeviceDiscovery {
  FakeDiscovery(this.items);
  final List<DiscoveredDevice> items;
  @override
  Stream<DiscoveredDevice> discover({Duration timeout = const Duration(seconds: 6)}) => Stream.fromIterable(items);
}

RemoteDevice device({
  String id = 'dev-1',
  String name = 'TV Sala',
  String host = '127.0.0.1',
  int port = 6466,
  RemoteProtocol protocol = RemoteProtocol.androidTv,
  int? pairingPort,
}) => RemoteDevice(id: id, name: name, host: host, port: port, protocol: protocol, pairingPort: pairingPort);
