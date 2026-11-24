import 'package:flutter/material.dart';

/// Design tokens shared with the Apple TV app (`apps/apple/App/Theme.swift`).
/// Keep values in sync so every Zorofin client reads as one product.
class Zoro {
  static const background = Color(0xFF111513);
  static const panel = Color(0xFF1B211E);
  static const border = Color(0xFF39423C);
  static const text = Color(0xFFF5F7F5);
  static const muted = Color(0xFFBBC5BD);
  static const jade = Color(0xFF72E79B);
  static const play = Color(0xFF1CB956);
  static const avatar = Color(0xFF24543E);

  /// Screen gutter and minimum control height at 1920x1080 logical pixels.
  static const gutter = 48.0;
  static const target = 60.0;
  static const focusDuration = Duration(milliseconds: 140);

  static ThemeData theme() {
    const fontFamily = 'Inter';
    final base = ThemeData(
      brightness: Brightness.dark,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: background,
      colorScheme: const ColorScheme.dark(
        primary: jade,
        surface: panel,
        onSurface: text,
        secondary: play,
      ),
      useMaterial3: true,
      // TVs have no touch ripple; focus rings carry state instead.
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(bodyColor: text, displayColor: text),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: panel,
        labelStyle: const TextStyle(color: muted, fontSize: 22),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 24,
          vertical: 20,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Colors.white, width: 3),
        ),
      ),
    );
  }

  /// Focus lift, or none when the viewer reduces motion (app setting or
  /// the TV's accessibility setting, both via `disableAnimations`).
  static double lift(BuildContext context, bool focused, double amount) =>
      focused && !MediaQuery.disableAnimationsOf(context) ? amount : 1;

  static TextStyle font(
    double size, {
    FontWeight weight = FontWeight.w400,
    Color color = text,
  }) => TextStyle(
    fontFamily: 'Inter',
    fontSize: size,
    fontWeight: weight,
    color: color,
  );
}
