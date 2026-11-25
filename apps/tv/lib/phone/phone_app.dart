import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/catalog.dart';
import '../core/preferences.dart';
import '../ui/theme.dart';
import 'phone_connect.dart';
import 'phone_downloads.dart';
import 'phone_shell.dart';
import 'phone_theme.dart';

/// Android phones and tablets (Apple `ZorofinApp` on iPhone and iPad): the
/// connect, Who's watching and signed-in shell screens with touch layouts.
class ZorofinPhoneApp extends StatefulWidget {
  const ZorofinPhoneApp({super.key, required this.state});

  final AppState state;

  @override
  State<ZorofinPhoneApp> createState() => _ZorofinPhoneAppState();
}

class _ZorofinPhoneAppState extends State<ZorofinPhoneApp> {
  final _navigator = GlobalKey<NavigatorState>();
  Catalog? _catalog;

  @override
  void initState() {
    super.initState();
    // Edge to edge like the iPhone app; the player hides the bars itself.
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
    widget.state.addListener(_stateChanged);
    _stateChanged();
  }

  @override
  void dispose() {
    widget.state.removeListener(_stateChanged);
    super.dispose();
  }

  /// Signing in or out returns to the root screen and moves downloads to
  /// the new account; removed accounts lose their downloads.
  void _stateChanged() {
    final catalog = widget.state.catalog;
    if (catalog != _catalog) {
      _catalog = catalog;
      _navigator.currentState?.popUntil((route) => route.isFirst);
      unawaited(PhoneDownloads.instance.use(catalog?.client));
    }
    final client = catalog?.client;
    unawaited(
      PhoneDownloads.instance.prune({
        for (final account in widget.state.connections.accounts) account.scope,
        if (client?.session != null) PhoneDownloads.accountKey(client!),
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return AccentScope(
      builder: (context) => MaterialApp(
        title: 'Zorofin',
        debugShowCheckedModeBanner: false,
        navigatorKey: _navigator,
        theme: Phone.theme(),
        builder: (context, child) => ColoredBox(
          color: Zoro.background,
          child: PreferencesScope(
            preferences: state.preferences,
            child: ListenableBuilder(
              listenable: state.preferences,
              builder: (context, _) {
                final media = MediaQuery.of(context);
                return MediaQuery(
                  data: media.copyWith(
                    disableAnimations:
                        media.disableAnimations ||
                        state.preferences.value.reduceMotion,
                  ),
                  child: child ?? const SizedBox(),
                );
              },
            ),
          ),
        ),
        home: ListenableBuilder(
          listenable: state,
          builder: (context, _) {
            final catalog = state.catalog;
            if (catalog == null) {
              return state.connections.accounts.isEmpty
                  ? PhoneConnectScreen(
                      key: const ValueKey('connect'),
                      state: state,
                    )
                  : PhoneAccountsScreen(
                      key: const ValueKey('accounts'),
                      state: state,
                    );
            }
            return PhoneShell(
              key: ObjectKey(catalog),
              state: state,
              catalog: catalog,
            );
          },
        ),
      ),
    );
  }
}
