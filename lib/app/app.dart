import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../presentation/screens/remote_screen.dart';
import 'app_scope.dart';
import 'theme.dart';

class KRemoteApp extends StatelessWidget {
  const KRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).settings;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final theme = KRemoteTheme.of(settings.theme);
        SystemChrome.setSystemUIOverlayStyle(
          SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: theme.brightness == Brightness.dark ? Brightness.light : Brightness.dark,
            statusBarBrightness: theme.brightness,
          ),
        );
        return MaterialApp(
          title: 'kRemote',
          debugShowCheckedModeBanner: false,
          theme: theme,
          locale: const Locale('pt', 'BR'),
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: const [Locale('pt', 'BR'), Locale('en')],
          home: const RemoteScreen(),
        );
      },
    );
  }
}
