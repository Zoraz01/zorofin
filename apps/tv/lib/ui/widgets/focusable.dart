import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// A remote-friendly control: D-pad focus, OK/Enter to activate, and Magic
/// Remote pointer hover moves focus so pointer and arrow navigation agree.
class Focusable extends StatefulWidget {
  const Focusable({
    super.key,
    required this.onPressed,
    required this.builder,
    this.autofocus = false,
    this.focusNode,
    this.onFocus,
    this.semanticLabel,
  });

  final VoidCallback onPressed;
  final Widget Function(BuildContext context, bool focused) builder;
  final bool autofocus;
  final FocusNode? focusNode;
  final VoidCallback? onFocus;
  final String? semanticLabel;

  @override
  State<Focusable> createState() => _FocusableState();
}

class _FocusableState extends State<Focusable> {
  FocusNode? _own;
  FocusNode get _node => widget.focusNode ?? (_own ??= FocusNode());
  bool _focused = false;

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  /// Avoid recentering an already visible control on every remote press.
  /// This also checks outer viewports: a card can be visible in its horizontal
  /// shelf while that entire shelf is clipped by the vertical Home list.
  void _revealIfClipped() {
    final target = context.findRenderObject();
    if (target == null || !target.attached) return;
    for (
      var ancestor = target.parent;
      ancestor != null;
      ancestor = ancestor.parent
    ) {
      if (ancestor is! RenderAbstractViewport || ancestor is! RenderBox) {
        continue;
      }
      final viewportBox = ancestor as RenderBox;
      if (!viewportBox.hasSize) continue;
      final bounds = MatrixUtils.transformRect(
        target.getTransformTo(ancestor),
        target.paintBounds,
      );
      final visible = viewportBox.paintBounds.inflate(0.5);
      if (visible.contains(bounds.topLeft) &&
          visible.contains(bounds.bottomRight)) {
        continue;
      }
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: Zoro.focusDuration,
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
      );
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: FocusableActionDetector(
        focusNode: _node,
        autofocus: widget.autofocus,
        mouseCursor: SystemMouseCursors.click,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed();
              return null;
            },
          ),
        },
        onShowHoverHighlight: (hovering) {
          if (hovering && !_node.hasFocus) _node.requestFocus();
        },
        onFocusChange: (value) {
          setState(() => _focused = value);
          if (value) {
            widget.onFocus?.call();
            _revealIfClipped();
          }
        },
        child: GestureDetector(
          onTap: () {
            _node.requestFocus();
            widget.onPressed();
          },
          child: widget.builder(context, _focused),
        ),
      ),
    );
  }
}

/// Capsule button matching the Apple `ZoroButtonStyle`: white (Home hero
/// Play), green primary (detail Play) or panel, with a white focus border.
class ZoroButton extends StatelessWidget {
  const ZoroButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.primary = false,
    this.white = false,
    this.autofocus = false,
    this.expand = false,
    this.focusNode,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final bool primary;
  final bool white;
  final bool autofocus;
  final bool expand;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final fg = primary || white ? Zoro.background : Zoro.text;
    return Focusable(
      autofocus: autofocus,
      focusNode: focusNode,
      onPressed: onPressed,
      builder: (context, focused) => AnimatedScale(
        scale: Zoro.lift(context, focused, 1.04),
        duration: Zoro.focusDuration,
        child: AnimatedContainer(
          duration: Zoro.focusDuration,
          constraints: const BoxConstraints(minHeight: Zoro.target),
          padding: const EdgeInsets.symmetric(horizontal: 28),
          decoration: BoxDecoration(
            color: white ? Zoro.text : (primary ? Zoro.play : Zoro.panel),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: focused ? Colors.white : Zoro.border,
              width: focused ? 3 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, color: fg, size: 28),
                const SizedBox(width: 10),
              ],
              Text(
                label,
                style: Zoro.font(22, weight: FontWeight.w600, color: fg),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Circular icon control (Apple `DetailIconStyle` / hero circle buttons).
class CircleIconButton extends StatelessWidget {
  const CircleIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.label,
    this.color = Zoro.text,
    this.filled = true,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String label;
  final Color color;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Focusable(
      onPressed: onPressed,
      semanticLabel: label,
      builder: (context, focused) => AnimatedScale(
        scale: Zoro.lift(context, focused, 1.08),
        duration: Zoro.focusDuration,
        child: Container(
          width: Zoro.target,
          height: Zoro.target,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled ? Zoro.panel : const Color(0x1FFFFFFF),
            border: Border.all(
              color: focused ? Colors.white : Zoro.border,
              width: focused ? 3 : 1,
            ),
          ),
          child: Icon(icon, color: color, size: 28),
        ),
      ),
    );
  }
}

/// Shell navigation control (Apple `NavigationButtonStyle`): a jade focus ring
/// with a dark gap, a small lift and scale, distinct from the white selection.
class NavButton extends StatelessWidget {
  const NavButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.selected = false,
    this.label,
    this.focusNode,
    this.autofocus = false,
  });

  final VoidCallback onPressed;
  final Widget Function(bool focused) child;
  final bool selected;
  final String? label;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Focusable(
      onPressed: onPressed,
      semanticLabel: label,
      focusNode: focusNode,
      autofocus: autofocus,
      builder: (context, focused) => AnimatedSlide(
        offset: Offset(0, focused ? -0.03 : 0),
        duration: Zoro.focusDuration,
        child: AnimatedScale(
          scale: Zoro.lift(context, focused, 1.06),
          duration: Zoro.focusDuration,
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: ShapeDecoration(
              shape: StadiumBorder(
                side: BorderSide(
                  color: focused ? Zoro.jade : Colors.transparent,
                  width: 3,
                ),
              ),
            ),
            child: AnimatedContainer(
              duration: Zoro.focusDuration,
              decoration: ShapeDecoration(
                shape: const StadiumBorder(),
                color: selected
                    ? Zoro.text
                    : (focused ? const Color(0x14F5F7F5) : Colors.transparent),
              ),
              child: child(focused),
            ),
          ),
        ),
      ),
    );
  }
}

/// Remote Back. Screens may override it with their own [Actions], for
/// example the player stops playback before leaving.
class BackIntent extends Intent {
  const BackIntent();
}

/// Remote keys that mean "go back": Escape, Android TV/Fire TV Back, webOS
/// Back (key code 461, delivered as goBack/browserBack).
final backKeys = <ShortcutActivator, Intent>{
  const SingleActivator(LogicalKeyboardKey.escape): const BackIntent(),
  const SingleActivator(LogicalKeyboardKey.goBack): const BackIntent(),
  const SingleActivator(LogicalKeyboardKey.browserBack): const BackIntent(),
};

/// Keeps a Back press the app handled from also reaching the platform.
///
/// Shortcuts act on key down, but Android TV leaves the app on an unhandled
/// Back key *up*. So after the app closes a menu or page on Back's key down,
/// the matching key up is swallowed here. A Back the app did not handle
/// (nothing left to close) passes through on both edges, so Back at the root
/// still leaves the app. Wrap this around the whole app: it only sees key
/// events that nothing inside handled.
class BackKeyGuard extends StatefulWidget {
  const BackKeyGuard({super.key, required this.child});

  final Widget child;

  @override
  State<BackKeyGuard> createState() => _BackKeyGuardState();
}

class _BackKeyGuardState extends State<BackKeyGuard> {
  /// Back keys whose key down nothing in the app handled.
  final _passing = <LogicalKeyboardKey>{};

  static bool _isBack(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.escape ||
      key == LogicalKeyboardKey.goBack ||
      key == LogicalKeyboardKey.browserBack;

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    final key = event.logicalKey;
    if (!_isBack(key)) return KeyEventResult.ignored;
    if (event is KeyDownEvent) {
      _passing.add(key);
      return KeyEventResult.ignored;
    }
    if (event is KeyUpEvent) {
      return _passing.remove(key)
          ? KeyEventResult.ignored
          : KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: _onKey,
    child: widget.child,
  );
}

/// OK/Select on TV remotes activates the focused control.
final selectKeys = <ShortcutActivator, Intent>{
  const SingleActivator(LogicalKeyboardKey.select): const ActivateIntent(),
  const SingleActivator(LogicalKeyboardKey.enter): const ActivateIntent(),
  const SingleActivator(LogicalKeyboardKey.numpadEnter): const ActivateIntent(),
  const SingleActivator(LogicalKeyboardKey.gameButtonA): const ActivateIntent(),
};

/// Handles Back only while [canHandle] is true, so an unhandled Back at the
/// app root reaches the platform (Android/Fire TV/webOS leave the app).
class ConditionalBackAction extends Action<BackIntent> {
  ConditionalBackAction({required this.canHandle, required this.onBack});

  final bool Function() canHandle;
  final VoidCallback onBack;

  /// Whether the last check found Back handleable. [consumesKey] is asked
  /// after [invoke], when handling may already have changed the answer.
  bool _enabled = false;

  @override
  bool isEnabled(BackIntent intent) => _enabled = canHandle();

  @override
  bool consumesKey(BackIntent intent) => _enabled;

  @override
  Object? invoke(BackIntent intent) {
    onBack();
    return null;
  }
}
