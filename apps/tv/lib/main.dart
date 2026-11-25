import 'package:flutter/material.dart';

import 'app_state.dart';
import 'core/form_factor.dart';
import 'core/preferences.dart';
import 'core/web_tv.dart';
import 'core/session_store.dart';
import 'phone/phone_entry.dart'
    if (dart.library.js_interop) 'phone/phone_entry_web.dart';
import 'ui/screens/accounts_screen.dart';
import 'ui/screens/connect_screen.dart';
import 'ui/screens/shell.dart';
import 'ui/theme.dart';
import 'ui/widgets/focusable.dart';
import 'ui/widgets/tv_scale.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SessionBootstrap());
}

class SessionBootstrap extends StatefulWidget {
  const SessionBootstrap({super.key});

  @override
  State<SessionBootstrap> createState() => _SessionBootstrapState();
}

class _SessionBootstrapState extends State<SessionBootstrap> {
  late Future<AppState> _opening = _open();
  FormFactor _formFactor = FormFactor.tv;

  Future<AppState> _open() async {
    _formFactor = await FormFactorDetector.detect();
    return AppState(
      await SessionStore.open(),
      deviceName: _formFactor.isHandheld ? 'Zorofin Android' : 'Zorofin TV',
    )..restore(sharedDevice: !_formFactor.isHandheld);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<AppState>(
    future: _opening,
    builder: (context, snapshot) {
      final state = snapshot.data;
      if (state != null) {
        return _formFactor.isHandheld
            ? phoneApp(state)
            : ZorofinTvApp(state: state);
      }
      return MaterialApp(
        theme: Zoro.theme(),
        shortcuts: {...WidgetsApp.defaultShortcuts, ...selectKeys},
        home: Scaffold(
          body: Center(
            child: snapshot.hasError
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Saved sign-ins are unavailable.',
                        style: Zoro.font(28),
                      ),
                      const SizedBox(height: 24),
                      ZoroButton(
                        label: 'Try again',
                        autofocus: true,
                        onPressed: () => setState(() => _opening = _open()),
                      ),
                    ],
                  )
                : const CircularProgressIndicator(),
          ),
        ),
      );
    },
  );
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

  bool _exitPrompt = false;
  Future<void> _rootBack() async {
    final navigator = _navigator.currentState;
    if (navigator == null) return;
    if (navigator.canPop()) {
      await navigator.maybePop();
      return;
    }
    if (!isWebTv || _exitPrompt) return;
    _exitPrompt = true;
    final exit = await showDialog<bool>(
      context: navigator.context,
      builder: (context) => AlertDialog(
        title: const Text('Exit Zorofin?'),
        actions: [
          ZoroButton(
            label: 'Cancel',
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
          ),
          ZoroButton(
            label: 'Exit',
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    _exitPrompt = false;
    if (exit == true) closeWebTv();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return BackKeyGuard(
      child: AccentScope(
        builder: (context) => MaterialApp(
          title: 'Zorofin',
          debugShowCheckedModeBanner: false,
          navigatorKey: _navigator,
          theme: Zoro.theme(),
          shortcuts: {
            ...WidgetsApp.defaultShortcuts,
            ...selectKeys,
            ...backKeys,
          },
          actions: {
            ...WidgetsApp.defaultActions,
            BackIntent: CallbackAction<BackIntent>(
              onInvoke: (_) => _rootBack(),
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
                    ? ConnectScreen(
                        key: const ValueKey('connect'),
                        state: state,
                      )
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
      ),
    );
  }
}
