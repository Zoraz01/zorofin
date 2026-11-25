import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Which interface the app shows. Android TV, Google TV and Fire TV keep the
/// remote-first TV layout; Android phones and tablets get the touch layout
/// that mirrors the iPhone and iPad app.
enum FormFactor {
  tv,
  phone,
  tablet;

  bool get isHandheld => this != FormFactor.tv;
}

class FormFactorDetector {
  static const _channel = MethodChannel('org.zorofin.tv/platform');

  /// `--dart-define=ZOROFIN_FORM_FACTOR=phone` forces a layout for desktop
  /// previews and screenshots.
  static const _override = String.fromEnvironment('ZOROFIN_FORM_FACTOR');

  static Future<FormFactor> detect() async {
    for (final value in FormFactor.values) {
      if (value.name == _override) return value;
    }
    // Only Android asks the platform; webOS, the web TV build and the Linux
    // preview are TV targets.
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return FormFactor.tv;
    }
    try {
      final answer = await _channel.invokeMethod<String>('formFactor');
      return FormFactor.values.firstWhere(
        (f) => f.name == answer,
        orElse: () => FormFactor.tv,
      );
    } on MissingPluginException {
      return FormFactor.tv;
    } on PlatformException {
      return FormFactor.tv;
    }
  }
}
