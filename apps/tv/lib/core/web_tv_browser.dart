import 'package:web/web.dart' as web;

bool get isWebTv => const bool.fromEnvironment('ZOROFIN_WEBOS_WEB');
void closeWebTv() {
  if (isWebTv) web.window.close();
}
