import 'package:flutter/material.dart';

import '../application/settings_service.dart';

/// Temas do kRemote. Um único ponto de verdade para cores e formas, para que
/// todos os botões e telas sejam consistentes entre si.
class KRemoteTheme {
  static const seed = Color(0xFF3D7BFF);

  static ThemeData of(AppThemeMode mode) => switch (mode) {
    AppThemeMode.light => _base(ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light)),
    AppThemeMode.dark => _base(
      ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark).copyWith(
        surface: const Color(0xFF101318),
        surfaceContainerHighest: const Color(0xFF232830),
        surfaceContainerHigh: const Color(0xFF1C2128),
        surfaceContainer: const Color(0xFF171B21),
      ),
    ),
    AppThemeMode.highContrast => _base(
      const ColorScheme.highContrastDark(
        primary: Color(0xFFFFE14D),
        onPrimary: Colors.black,
        secondary: Color(0xFF7CF6FF),
        onSecondary: Colors.black,
        surface: Colors.black,
        onSurface: Colors.white,
        error: Color(0xFFFF7A7A),
        onError: Colors.black,
      ).copyWith(
        surfaceContainerHighest: const Color(0xFF1A1A1A),
        surfaceContainerHigh: const Color(0xFF141414),
        surfaceContainer: const Color(0xFF0D0D0D),
        outline: Colors.white,
        onSurfaceVariant: Colors.white,
      ),
      highContrast: true,
    ),
  };

  static ThemeData _base(ColorScheme scheme, {bool highContrast = false}) {
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(20));
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.standard,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
          letterSpacing: -0.2,
        ),
      ),
      cardTheme: CardThemeData(shape: shape, elevation: 0, color: scheme.surfaceContainer, margin: EdgeInsets.zero),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(shape: shape, padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: shape,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          side: BorderSide(color: highContrast ? scheme.outline : scheme.outlineVariant, width: highContrast ? 2 : 1),
        ),
      ),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: shape)),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: highContrast ? BorderSide(color: scheme.outline) : BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),
      listTileTheme: ListTileThemeData(shape: shape, iconColor: scheme.onSurfaceVariant),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
      snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating, shape: shape),
      bottomSheetTheme: BottomSheetThemeData(
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
        backgroundColor: scheme.surfaceContainer,
        showDragHandle: true,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          side: BorderSide(color: highContrast ? scheme.outline : scheme.outlineVariant),
        ),
      ),
      extensions: [RemoteButtonStyle.from(scheme, highContrast: highContrast)],
    );
  }
}

/// Tokens visuais dos botões do controle (extensão de tema).
class RemoteButtonStyle extends ThemeExtension<RemoteButtonStyle> {
  const RemoteButtonStyle({
    required this.fill,
    required this.fillPressed,
    required this.icon,
    required this.accent,
    required this.onAccent,
    required this.disabled,
    required this.border,
    required this.dpadRing,
    required this.dpadCenter,
  });

  final Color fill;
  final Color fillPressed;
  final Color icon;
  final Color accent;
  final Color onAccent;
  final Color disabled;
  final BorderSide border;
  final Color dpadRing;
  final Color dpadCenter;

  factory RemoteButtonStyle.from(ColorScheme s, {bool highContrast = false}) => RemoteButtonStyle(
    fill: s.surfaceContainerHighest,
    fillPressed: s.primary.withValues(alpha: highContrast ? 0.6 : 0.25),
    icon: s.onSurface,
    accent: s.primary,
    onAccent: s.onPrimary,
    disabled: s.onSurface.withValues(alpha: 0.28),
    border: highContrast ? BorderSide(color: s.outline, width: 2) : BorderSide.none,
    dpadRing: s.surfaceContainerHigh,
    dpadCenter: s.surfaceContainerHighest,
  );

  @override
  RemoteButtonStyle copyWith() => this;

  @override
  RemoteButtonStyle lerp(RemoteButtonStyle? other, double t) => t < 0.5 ? this : (other ?? this);
}
