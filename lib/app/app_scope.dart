import 'package:flutter/widgets.dart';

import '../application/device_service.dart';
import '../application/settings_service.dart';
import '../application/network_scanner.dart';
import '../infrastructure/protocols/bluetooth_hid/bluetooth_hid_channel.dart';

/// Injeção de dependências simples: expõe os serviços da aplicação à árvore
/// de widgets sem acoplar a UI às implementações de infraestrutura.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.devices,
    required this.settings,
    required this.scanner,
    required this.bluetooth,
    required super.child,
  });

  final DeviceService devices;
  final SettingsService settings;
  final NetworkScanner scanner;
  final BluetoothHidChannel bluetooth;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope ausente na árvore');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope old) => devices != old.devices || settings != old.settings || scanner != old.scanner;
}
