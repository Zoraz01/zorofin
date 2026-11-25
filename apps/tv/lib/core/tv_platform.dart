import 'package:flutter/services.dart';

/// Only platform capabilities actually implemented by this build are exposed.
/// Store links never start purchases or post reviews on the viewer's behalf.
class TvPlatform {
  static const channel = MethodChannel('org.zorofin.tv/platform');

  static Future<String?> store() async {
    try {
      return await channel.invokeMethod<String>('store');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static Future<bool> openRating() async {
    try {
      return await channel.invokeMethod<bool>('openRating') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Opens an http(s) page in the device browser (phones and tablets).
  static Future<bool> openUrl(Uri url) async {
    if (url.scheme != 'https' && url.scheme != 'http') return false;
    try {
      return await channel.invokeMethod<bool>('openUrl', {
            'url': url.toString(),
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
