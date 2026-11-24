import 'package:flutter/material.dart';

import 'app_state.dart';
import 'core/preferences.dart';
import 'core/session_store.dart';
import 'ui/screens/accounts_screen.dart';
import 'ui/screens/connect_screen.dart';
import 'ui/screens/shell.dart';
import 'ui/theme.dart';
import 'ui/widgets/focusable.dart';
import 'ui/widgets/tv_scale.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await SessionStore.open();
  final state = AppState(store, deviceName: 'Zorofin TV')..restore();
  runApp(ZorofinTvApp(state: state));
}

class ZorofinTvApp extends StatefulWidget {
  const ZorofinTvApp({super.key, required this.state});

  final AppState state;

  @override
  State<ZorofinTvApp> createState() => _ZorofinTvAppState();
}

class _ZorofinTvAppState extends State<ZorofinTvApp> {
  final _navigator = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    // Signing in or out returns to the root screen.
    widget.state.addListener(_resetRoutes);
  }

  @override
  void dispose() {
    widget.state.removeListener(_resetRoutes);
    super.dispose();
  }

  void _resetRoutes() =>
      _navigator.currentState?.popUntil((route) => route.isFirst);

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return BackKeyGuard(
      child: MaterialApp(
        title: 'Zorofin',
        debugShowCheckedModeBanner: false,
        navigatorKey: _navigator,
        theme: Zoro.theme(),
        shortcuts: {...WidgetsApp.defaultShortcuts, ...selectKeys, ...backKeys},
        actions: {
          ...WidgetsApp.defaultActions,
          BackIntent: CallbackAction<BackIntent>(
            onInvoke: (_) => _navigator.currentState?.maybePop(),
          ),
        },
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
                  child: TvScale(child: child ?? const SizedBox()),
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
                  ? ConnectScreen(key: const ValueKey('connect'), state: state)
                  : AccountsScreen(
                      key: const ValueKey('accounts'),
                      state: state,
                    );
            }
            return TvShell(
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
