import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/app.dart';
import 'app/app_scope.dart';
import 'application/device_service.dart';
import 'application/network_scanner.dart';
import 'application/settings_service.dart';
import 'infrastructure/controller_factory.dart';
import 'infrastructure/discovery/composite_discovery.dart';
import 'infrastructure/discovery/mdns_discovery.dart';
import 'infrastructure/discovery/ssdp_discovery.dart';
import 'infrastructure/net/log.dart';
import 'infrastructure/net/tls_fingerprint.dart';
import 'infrastructure/protocols/bluetooth_hid/bluetooth_hid_channel.dart';
import 'infrastructure/storage/prefs_device_repository.dart';
import 'infrastructure/storage/secure_credential_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kDebugMode) KLog.sink = (scope, msg) => debugPrint('[$scope] $msg');
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);

  final secure = SecureCredentialStore();
  final factory = ControllerFactory(credentials: secure, pins: secure.pins);
  final scanner = NetworkScanner(CompositeDiscovery([MdnsDiscovery(), SsdpDiscovery()]));
  final devices = DeviceService(
    repository: PrefsDeviceRepository(),
    credentials: secure,
    pins: secure.pins,
    factory: factory,
    scanner: scanner,
    fingerprintProbe: (host, port) async => tlsFingerprint(host, port, identity: await factory.appIdentity()),
    probe: (host, port) async {
      try {
        final s = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
        s.destroy();
        return true;
      } on SocketException {
        return false;
      } on TimeoutException {
        return false;
      }
    },
  );
  final settings = SettingsService();
  await Future.wait([devices.load(), settings.load()]);

  runApp(
    AppScope(
      devices: devices,
      settings: settings,
      scanner: scanner,
      bluetooth: const BluetoothHidChannel(),
      child: const KRemoteApp(),
    ),
  );
}
