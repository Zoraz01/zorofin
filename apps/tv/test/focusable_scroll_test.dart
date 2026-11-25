import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorofin_tv/ui/widgets/focusable.dart';

Widget _row(List<FocusNode> nodes, ScrollController controller) => SizedBox(
  width: 400,
  height: 100,
  child: SingleChildScrollView(
    key: const ValueKey('horizontal'),
    controller: controller,
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (var i = 0; i < nodes.length; i++)
          Focusable(
            focusNode: nodes[i],
            onPressed: () {},
            builder: (_, focused) => SizedBox(
              key: ValueKey('card-$i'),
              width: 100,
              height: 100,
              child: ColoredBox(color: focused ? Colors.white : Colors.black),
            ),
          ),
      ],
    ),
  ),
);

Widget _app(Widget child) => MaterialApp(
  home: Scaffold(
    body: Align(alignment: Alignment.topLeft, child: child),
  ),
);

Future<void> _focus(WidgetTester tester, FocusNode node) async {
  node.requestFocus();
  await tester.pump();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'focus keeps fully visible cards at their existing scroll offset',
    (tester) async {
      final nodes = List.generate(10, (_) => FocusNode());
      final controller = ScrollController(initialScrollOffset: 100);
      await tester.pumpWidget(_app(_row(nodes, controller)));
      await _focus(tester, nodes[2]);
      expect(nodes[2].hasFocus, isTrue);
      expect(controller.offset, 100);
      await _focus(tester, nodes[3]);
      expect(controller.offset, 100);
      await tester.pumpWidget(const SizedBox());
      for (final node in nodes) {
        node.dispose();
      }
      controller.dispose();
    },
  );

  testWidgets('programmatic focus reveals cards beyond either edge', (
    tester,
  ) async {
    final nodes = List.generate(10, (_) => FocusNode());
    final controller = ScrollController(initialScrollOffset: 300);
    await tester.pumpWidget(_app(_row(nodes, controller)));
    for (final index in [0, 8]) {
      await _focus(tester, nodes[index]);
      final viewport = tester.getRect(find.byKey(const ValueKey('horizontal')));
      final card = tester.getRect(find.byKey(ValueKey('card-$index')));
      expect(card.left, greaterThanOrEqualTo(viewport.left));
      expect(card.right, lessThanOrEqualTo(viewport.right));
    }
    await tester.pumpWidget(const SizedBox());
    for (final node in nodes) {
      node.dispose();
    }
    controller.dispose();
  });

  testWidgets(
    'visible focus does not recenter nested Home-style scroll views',
    (tester) async {
      final nodes = List.generate(10, (_) => FocusNode());
      final horizontal = ScrollController(initialScrollOffset: 100);
      final vertical = ScrollController(initialScrollOffset: 240);
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 400,
            height: 220,
            child: SingleChildScrollView(
              controller: vertical,
              child: Column(
                children: [
                  const SizedBox(height: 300),
                  _row(nodes, horizontal),
                  const SizedBox(height: 500),
                ],
              ),
            ),
          ),
        ),
      );
      await _focus(tester, nodes[2]);
      expect(horizontal.offset, 100);
      expect(vertical.offset, 240);
      await tester.pumpWidget(const SizedBox());
      for (final node in nodes) {
        node.dispose();
      }
      horizontal.dispose();
      vertical.dispose();
    },
  );

  testWidgets(
    'remote navigation leaves visible cards still and reveals the next',
    (tester) async {
      final nodes = List.generate(10, (_) => FocusNode());
      final controller = ScrollController();
      await tester.pumpWidget(_app(_row(nodes, controller)));
      await _focus(tester, nodes.first);
      for (var index = 1; index <= 4; index++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(nodes[index].hasFocus, isTrue);
        if (index < 4) {
          expect(controller.offset, 0);
        }
      }
      expect(controller.offset, greaterThan(0));
      await tester.pumpWidget(const SizedBox());
      for (final node in nodes) {
        node.dispose();
      }
      controller.dispose();
    },
  );
}
