import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Rect? _bounds(FocusNode node) {
  final box = node.context?.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// Home moves vertically by adjacent shelves, independently of horizontal offsets.
class HomeRailScope extends StatefulWidget {
  const HomeRailScope({super.key, required this.child});
  final Widget child;
  @override
  State<HomeRailScope> createState() => _HomeRailScopeState();
}

class _HomeRailScopeState extends State<HomeRailScope> {
  final rails = <_HomeRailFocusState>{};

  KeyEventResult _move(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowUp &&
        key != LogicalKeyboardKey.arrowDown) {
      return KeyEventResult.ignored;
    }
    final current = FocusManager.instance.primaryFocus;
    if (current == null) return KeyEventResult.ignored;
    final ordered =
        rails.where((r) => r.mounted && _bounds(r.node) != null).toList()..sort(
          (a, b) => _bounds(a.node)!.top.compareTo(_bounds(b.node)!.top),
        );
    final index = ordered.indexWhere((r) => r.node.hasFocus);
    if (index < 0) return KeyEventResult.ignored;
    ordered[index].last = current;
    final next = index + (key == LogicalKeyboardKey.arrowDown ? 1 : -1);
    // Hero, header and continuation keep normal traversal outside the shelves.
    if (next < 0 || next >= ordered.length) return KeyEventResult.ignored;
    final target = ordered[next];
    final candidates = target.candidates;
    if (candidates.isEmpty) return KeyEventResult.handled;
    final x = _bounds(current)?.center.dx ?? 0;
    candidates.sort(
      (a, b) => (_bounds(a)!.center.dx - x).abs().compareTo(
        (_bounds(b)!.center.dx - x).abs(),
      ),
    );
    (candidates.contains(target.last) ? target.last! : candidates.first)
        .requestFocus();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => _HomeRailRegistry(
    owner: this,
    child: Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _move,
      child: widget.child,
    ),
  );
}

class _HomeRailRegistry extends InheritedWidget {
  const _HomeRailRegistry({required this.owner, required super.child});
  final _HomeRailScopeState owner;
  @override
  bool updateShouldNotify(_HomeRailRegistry old) => owner != old.owner;
}

/// Left/Right stays in a rail; Home's ancestor handles adjacent Up/Down.
class HomeRailFocus extends StatefulWidget {
  const HomeRailFocus({super.key, required this.child});
  final Widget child;
  @override
  State<HomeRailFocus> createState() => _HomeRailFocusState();
}

class _HomeRailFocusState extends State<HomeRailFocus> {
  final node = FocusNode(
    debugLabel: 'home-rail',
    skipTraversal: true,
    canRequestFocus: false,
  );
  _HomeRailScopeState? owner;
  FocusNode? last;
  List<FocusNode> get candidates => node.descendants
      .where((n) => n.canRequestFocus && !n.skipTraversal && _bounds(n) != null)
      .toList();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = context
        .dependOnInheritedWidgetOfExactType<_HomeRailRegistry>()
        ?.owner;
    if (next != owner) {
      owner?.rails.remove(this);
      owner = next;
      owner?.rails.add(this);
    }
  }

  @override
  void dispose() {
    owner?.rails.remove(this);
    node.dispose();
    super.dispose();
  }

  KeyEventResult _move(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowLeft &&
        key != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }
    final current = FocusManager.instance.primaryFocus;
    if (current == null || !node.hasFocus) return KeyEventResult.ignored;
    last = current;
    final from = _bounds(current);
    if (from == null) return KeyEventResult.handled;
    final targets =
        candidates.where((n) {
          final rect = _bounds(n)!;
          final dx = rect.center.dx - from.center.dx;
          return n != current &&
              rect.top < from.bottom &&
              rect.bottom > from.top &&
              (key == LogicalKeyboardKey.arrowRight ? dx > 1 : dx < -1);
        }).toList()..sort(
          (a, b) => (_bounds(a)!.center.dx - from.center.dx).abs().compareTo(
            (_bounds(b)!.center.dx - from.center.dx).abs(),
          ),
        );
    if (targets.isNotEmpty) targets.first.requestFocus();
    return KeyEventResult.handled; // No diagonal fallback at either rail edge.
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: node,
    onKeyEvent: _move,
    child: FocusTraversalGroup(child: widget.child),
  );
}
