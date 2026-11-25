import 'package:flutter/material.dart';

import '../ui/theme.dart';

/// Phone and tablet sizes from the iPhone/iPad app (`Theme.swift` and
/// `AdaptiveWindow.swift`). Colors and the type face come from [Zoro], which
/// is shared with every Zorofin client.
class Phone {
  static const gutter = 16.0;
  static const target = 48.0;
  static const radius = 12.0;

  static ThemeData theme() {
    final base = Zoro.theme();
    return base.copyWith(
      // Touch screens show press feedback; TVs use focus rings instead.
      splashFactory: InkSparkle.splashFactory,
      highlightColor: Colors.white10,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Zoro.panel,
        hintStyle: Zoro.font(16, color: Zoro.muted),
        labelStyle: Zoro.font(16, color: Zoro.muted),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Phone.radius),
          borderSide: const BorderSide(color: Zoro.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Phone.radius),
          borderSide: BorderSide(color: Zoro.jade, width: 2),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Zoro.panel,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: Zoro.border,
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: Zoro.panel,
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: Zoro.panel,
        contentTextStyle: Zoro.font(15),
        behavior: SnackBarBehavior.floating,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Zoro.background : null,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Zoro.jade : null,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: Zoro.jade),
    );
  }
}

/// The window classes the iPhone/iPad layouts switch on
/// (`AdaptiveWindow.swift`).
class PhoneWindow {
  const PhoneWindow(this.size);

  factory PhoneWindow.of(BuildContext context) =>
      PhoneWindow(MediaQuery.sizeOf(context));

  final Size size;

  double get width => size.width;
  double get height => size.height;

  /// iPad-style navigation: a full-width dock and side-by-side details.
  bool get tablet => width >= 700 && height >= 560;

  /// Wide content: bigger cards and the landscape banner.
  bool get wide => width >= 700 && height >= 440;

  double get posterWidth => wide ? 180 : 148;
  double get landscapeWidth => wide ? 320 : 270;

  /// A phone turned sideways: too short for the tablet layout, but wide
  /// enough that a poster banner would crop badly.
  bool get landscapePhone => !wide && width > height;

  /// Banner height; a landscape phone keeps the title and Play on screen
  /// above the dock.
  double get heroHeight => wide
      ? (width * 0.5).clamp(380, 520).toDouble()
      : landscapePhone
      ? (height * 0.6).clamp(220, 470).toDouble()
      : (height * 0.78).clamp(260, 470).toDouble();

  /// Columns for a poster grid that fills the width at about [posterWidth].
  int gridColumns({bool landscape = false}) {
    final card = landscape ? landscapeWidth : posterWidth;
    final usable = width - Phone.gutter * 2;
    return ((usable + 12) / (card + 12)).floor().clamp(2, 10);
  }
}
