import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorofin_tv/ui/widgets/home_rail_focus.dart';

// Deferred until the owner resumes testing; shared by Android/Fire/Google/Samsung.
void main() {
  testWidgets('rail edges stay put and deep Up returns to the chosen card', (
    tester,
  ) async {
    final nodes = List.generate(
      12,
      (_) => List.generate(8, (_) => FocusNode()),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeRailScope(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (var row = 0; row < nodes.length; row++)
                    HomeRailFocus(
                      key: ValueKey(row),
                      child: SizedBox(
                        height: 130,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (
                                var card = 0;
                                card < nodes[row].length;
                                card++
                              )
                                SizedBox(
                                  width: 180,
                                  height: 100,
                                  child: TextButton(
                                    focusNode: nodes[row][card],
                                    onPressed: () {},
                                    child: Text('$row-$card'),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    nodes[8][5].requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(nodes[9].any((node) => node.hasPrimaryFocus), true);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(nodes[8][5].hasPrimaryFocus, true);
    nodes[8][0].requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(nodes[8][0].hasPrimaryFocus, true);
    nodes[8][7].requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(nodes[8][7].hasPrimaryFocus, true);
    await tester.pumpWidget(const SizedBox.shrink());
    for (final row in nodes) {
      for (final node in row) {
        node.dispose();
      }
    }
  });
}
