import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorofin_tv/ui/player/in_app_player.dart';

class ProbePlayer extends StatefulWidget {
  const ProbePlayer({
    super.key,
    required this.presentation,
    required this.events,
  });
  final PlayerPresentation presentation;
  final List<String> events;
  @override
  State<ProbePlayer> createState() => _ProbePlayerState();
}

class _ProbePlayerState extends State<ProbePlayer> {
  @override
  void initState() {
    super.initState();
    widget.events.add('start');
    widget.presentation.onStop = () async {
      widget.events.add('stop');
      widget.presentation.closed();
    };
    widget.presentation.onBack = () => widget.presentation.closed();
  }

  @override
  void dispose() {
    widget.events.add('dispose');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(color: Colors.black, child: Text('Video'));
}

void main() {
  testWidgets(
    'minimize and expand retain the player and restore library focus',
    (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final key = GlobalKey<InAppPlayerHostState>();
      final libraryFocus = FocusNode();
      addTearDown(libraryFocus.dispose);
      final events = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: InAppPlayerHost(
            key: key,
            child: TextButton(
              autofocus: true,
              focusNode: libraryFocus,
              onPressed: () {},
              child: const Text('Library'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      late PlayerPresentation presentation;
      var done = false;
      unawaited(
        key.currentState!
            .open((p) {
              presentation = p;
              return ProbePlayer(presentation: p, events: events);
            })
            .then((_) => done = true),
      );
      await tester.pumpAndSettle();
      final playerState = tester.state(find.byType(ProbePlayer));
      expect(libraryFocus.canRequestFocus, false);
      expect(tester.getSize(find.byType(ProbePlayer)), const Size(1920, 1080));
      presentation.minimize();
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(ProbePlayer)), const Size(520, 360));
      expect(libraryFocus.hasFocus, true);
      expect(tester.state(find.byType(ProbePlayer)), same(playerState));
      presentation.expand();
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(ProbePlayer)), same(playerState));
      expect(events, ['start']);
      expect(done, false);
      await key.currentState!.closePlayer();
      await tester.pumpAndSettle();
      expect(events, ['start', 'stop', 'dispose']);
      expect(done, true);
      expect(libraryFocus.hasFocus, true);
    },
  );

  testWidgets('replacing playback stops the previous player first', (
    tester,
  ) async {
    final key = GlobalKey<InAppPlayerHostState>();
    final events = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: InAppPlayerHost(key: key, child: const SizedBox.expand()),
      ),
    );
    unawaited(
      key.currentState!.open(
        (p) => ProbePlayer(presentation: p, events: events),
      ),
    );
    await tester.pumpAndSettle();
    unawaited(
      key.currentState!.open(
        (p) => ProbePlayer(presentation: p, events: events),
      ),
    );
    await tester.pumpAndSettle();
    expect(events.where((e) => e == 'start').length, 2);
    expect(events.indexOf('stop'), lessThan(events.lastIndexOf('start')));
    await key.currentState!.closePlayer();
    await tester.pumpAndSettle();
    expect(events.where((e) => e == 'dispose').length, 2);
  });

  testWidgets('account removal disposes the visible mini-player', (
    tester,
  ) async {
    final key = GlobalKey<InAppPlayerHostState>();
    final events = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: InAppPlayerHost(key: key, child: const SizedBox.expand()),
      ),
    );
    late PlayerPresentation presentation;
    unawaited(
      key.currentState!.open((p) {
        presentation = p;
        return ProbePlayer(presentation: p, events: events);
      }),
    );
    await tester.pumpAndSettle();
    presentation.minimize();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const MaterialApp(home: Text('Signed out')));
    await tester.pumpAndSettle();
    expect(events, ['start', 'dispose']);
    expect(find.text('Video'), findsNothing);
  });
}
