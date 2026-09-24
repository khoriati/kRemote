import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../application/settings_service.dart';

/// Aparência e comportamento.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Aparência')),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Tema',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
            ),
            const SizedBox(height: 8),
            Card(
              child: RadioGroup<AppThemeMode>(
                groupValue: settings.theme,
                onChanged: (v) => v == null ? null : settings.setTheme(v),
                child: Column(
                  children: [
                    for (final m in AppThemeMode.values)
                      RadioListTile<AppThemeMode>(
                        value: m,
                        title: Text(m.label),
                        secondary: Icon(switch (m) {
                          AppThemeMode.light => Icons.light_mode_outlined,
                          AppThemeMode.dark => Icons.dark_mode_outlined,
                          AppThemeMode.highContrast => Icons.contrast,
                        }),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Card(
              child: SwitchListTile(
                value: settings.haptics,
                onChanged: settings.setHaptics,
                title: const Text('Vibração ao tocar'),
                secondary: const Icon(Icons.vibration),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Sobre',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
            ),
            const SizedBox(height: 8),
            const Card(
              child: ListTile(
                leading: Icon(Icons.settings_remote),
                title: Text('kRemote'),
                subtitle: Text(
                  'Controle remoto universal. Credenciais ficam apenas neste aparelho, em armazenamento seguro.',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
