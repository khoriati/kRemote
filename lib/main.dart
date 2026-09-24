import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/app.dart';
import 'app/app_scope.dart';
import 'application/device_service.dart';
import 'application/settings_service.dart';
import 'infrastructure/controller_factory.dart';
import 'infrastructure/discovery/composite_discovery.dart';
import 'infrastructure/discovery/mdns_discovery.dart';
import 'infrastructure/discovery/ssdp_discovery.dart';
import 'infrastructure/net/log.dart';
import 'infrastructure/protocols/bluetooth_hid/bluetooth_hid_channel.dart';
import 'infrastructure/storage/prefs_device_repository.dart';
import 'infrastructure/storage/secure_credential_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kDebugMode) KLog.sink = (scope, msg) => debugPrint('[$scope] $msg');
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);

  final secure = SecureCredentialStore();
  final factory = ControllerFactory(credentials: secure, pins: secure.pins);
  final devices = DeviceService(
    repository: PrefsDeviceRepository(),
    credentials: secure,
    pins: secure.pins,
    factory: factory,
  );
  final settings = SettingsService();
  await Future.wait([devices.load(), settings.load()]);

  runApp(
    AppScope(
      devices: devices,
      settings: settings,
      discovery: CompositeDiscovery([MdnsDiscovery(), SsdpDiscovery()]),
      bluetooth: const BluetoothHidChannel(),
      child: const KRemoteApp(),
    ),
  );
}
