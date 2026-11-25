import 'package:flutter/widgets.dart';

import '../app_state.dart';

/// Web TV builds never show the phone layout.
Widget phoneApp(AppState state) =>
    throw UnsupportedError('The phone layout needs Android.');
