import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kremote/app/app.dart';
import 'package:kremote/app/app_scope.dart';
import 'package:kremote/app/theme.dart';
import 'package:kremote/application/device_service.dart';
import 'package:kremote/application/settings_service.dart';
import 'package:kremote/domain/entities/remote_device.dart';
import 'package:kremote/domain/entities/remote_key.dart';
import 'package:kremote/infrastructure/controller_factory.dart';
import 'package:kremote/infrastructure/protocols/bluetooth_hid/bluetooth_hid_channel.dart';
import 'package:kremote/presentation/widgets/dpad.dart';
import 'package:kremote/presentation/widgets/remote_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

Future<Widget> buildApp({List<RemoteDevice> devices = const []}) async {
  SharedPreferences.setMockInitialValues({});
  final creds = MemoryCredentialStore();
  final pins = MemoryPinStore();
  final svc = DeviceService(
    repository: MemoryDeviceRepository()..saved = devices,
    credentials: creds,
    pins: pins,
    factory: ControllerFactory(credentials: creds, pins: pins),
  );
  await svc.load();
  final settings = SettingsService();
  await settings.load();
  return AppScope(
    devices: svc,
    settings: settings,
    discovery: FakeDiscovery(const []),
    bluetooth: const BluetoothHidChannel(),
    child: const KRemoteApp(),
  );
}

void main() {
  testWidgets('estado vazio convida a adicionar dispositivo', (tester) async {
    await tester.pumpWidget(await buildApp());
    await tester.pumpAndSettle();
    expect(find.text('Nenhum dispositivo'), findsOneWidget);
    expect(find.text('Adicionar dispositivo'), findsOneWidget);
  });

  testWidgets('com dispositivo cadastrado mostra o controle e o seletor', (tester) async {
    await tester.pumpWidget(
      await buildApp(
        devices: [
          device(id: 'a', name: 'Sala'),
          device(id: 'b', name: 'Quarto'),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sala'), findsOneWidget);
    expect(find.byType(DPad), findsOneWidget);
    expect(find.text('Emparelhar'), findsOneWidget, reason: 'sem credenciais → precisa emparelhar');
    // Alterna de dispositivo pelo seletor.
    await tester.tap(find.text('Sala'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quarto').last);
    await tester.pumpAndSettle();
    expect(find.text('Quarto'), findsOneWidget);
    // Painéis
    await tester.tap(find.text('Números'));
    await tester.pumpAndSettle();
    expect(find.text('5'), findsOneWidget);
  });

  testWidgets('temas constroem sem erro e o alto contraste tem borda', (tester) async {
    for (final m in AppThemeMode.values) {
      final theme = KRemoteTheme.of(m);
      expect(theme.colorScheme, isNotNull);
      final style = theme.extension<RemoteButtonStyle>()!;
      if (m == AppThemeMode.highContrast) expect(style.border.width, greaterThan(0));
    }
  });

  testWidgets('DPad mapeia toques por setor', (tester) async {
    final hits = <RemoteKey>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: KRemoteTheme.of(AppThemeMode.dark),
        home: Center(child: DPad(size: 200, onKey: hits.add)),
      ),
    );
    final center = tester.getCenter(find.byType(DPad));
    await tester.tapAt(center);
    await tester.tapAt(center + const Offset(0, -80));
    await tester.tapAt(center + const Offset(80, 0));
    await tester.tapAt(center + const Offset(0, 80));
    await tester.tapAt(center + const Offset(-80, 0));
    expect(hits, [RemoteKey.ok, RemoteKey.up, RemoteKey.right, RemoteKey.down, RemoteKey.left]);
  });

  testWidgets('RemoteButton desabilitado não dispara', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: KRemoteTheme.of(AppThemeMode.light),
        home: Center(
          child: RemoteButton(icon: Icons.home, enabled: false, onTap: () => taps++),
        ),
      ),
    );
    await tester.tap(find.byType(RemoteButton));
    expect(taps, 0);
  });
}
