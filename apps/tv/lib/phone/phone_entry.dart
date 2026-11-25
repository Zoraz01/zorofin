import 'package:flutter/widgets.dart';

import '../app_state.dart';
import 'phone_app.dart';

/// The phone and tablet app. Web builds use `phone_entry_web.dart`, since
/// downloads and the player need `dart:io`.
Widget phoneApp(AppState state) => ZorofinPhoneApp(state: state);
