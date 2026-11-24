import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// A text field for remote control. Focus alone never opens the on-screen
/// keyboard, so the D-pad can move past it (as on Apple TV, where a field
/// opens the keyboard only when selected). OK, Enter or a pointer click
/// starts editing; submitting, moving up or down, or leaving the field ends
/// it.
///
/// While editing, the typed text is echoed in a strip at the top of the
/// screen, because TV keyboards often cover the lower half of the screen and
/// with it the field itself.
class TvTextField extends StatefulWidget {
  const TvTextField({
    super.key,
    this.controller,
    this.decoration = const InputDecoration(),
    this.style,
    this.autofocus = false,
    this.enabled = true,
    this.obscureText = false,
    this.autocorrect = false,
    this.enableSuggestions = true,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.onChanged,
    this.focusNode,
  });

  final TextEditingController? controller;
  final InputDecoration decoration;
  final TextStyle? style;
  final bool autofocus;
  final bool enabled;
  final bool obscureText;
  final bool autocorrect;
  final bool enableSuggestions;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final FocusNode? focusNode;

  @override
  State<TvTextField> createState() => TvTextFieldState();
}

class TvTextFieldState extends State<TvTextField> with WidgetsBindingObserver {
  double _inset = 0;
  FocusNode? _ownNode;
  TextEditingController? _ownController;
  final _echo = OverlayPortalController();
  bool _editing = false;

  FocusNode get _node => widget.focusNode ?? (_ownNode ??= FocusNode());
  TextEditingController get _text =>
      widget.controller ?? (_ownController ??= TextEditingController());

  /// Whether the keyboard is open for this field.
  bool get editing => _editing;

  @override
  void initState() {
    super.initState();
    _node.addListener(_focusChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  /// Android TV's Back closes the keyboard without a key event reaching
  /// Flutter, so end editing when the keyboard goes away. Otherwise the
  /// still-open input connection swallows the next D-pad press.
  @override
  void didChangeMetrics() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final inset = views.first.viewInsets.bottom;
    if (_editing && _inset > 0 && inset == 0) _stopEditing();
    _inset = inset;
  }

  @override
  void didUpdateWidget(TvTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _ownNode)?.removeListener(_focusChanged);
      _node.addListener(_focusChanged);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _node.removeListener(_focusChanged);
    _ownNode?.dispose();
    _ownController?.dispose();
    super.dispose();
  }

  void _focusChanged() {
    if (!_node.hasFocus && _editing) _setEditing(false);
  }

  void _setEditing(bool value) {
    setState(() => _editing = value);
    value ? _echo.show() : _echo.hide();
  }

  void _startEditing() {
    if (!widget.enabled || _editing) return;
    _setEditing(true);
    if (!_node.hasFocus) _node.requestFocus();
  }

  void _stopEditing() {
    if (!_editing) return;
    _setEditing(false);
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final select =
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA;
    if (!_editing) {
      if (select) {
        if (event is KeyDownEvent) _startEditing();
        return KeyEventResult.handled;
      }
      final direction = switch (key) {
        LogicalKeyboardKey.arrowUp => TraversalDirection.up,
        LogicalKeyboardKey.arrowDown => TraversalDirection.down,
        LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
        LogicalKeyboardKey.arrowRight => TraversalDirection.right,
        _ => null,
      };
      if (direction != null) {
        _node.focusInDirection(direction);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    // While editing, left and right move the cursor; up and down leave.
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      _stopEditing();
      _node.focusInDirection(
        key == LogicalKeyboardKey.arrowUp
            ? TraversalDirection.up
            : TraversalDirection.down,
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      _stopEditing();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// The strip at the top of the screen that shows what is being typed.
  Widget _echoStrip(BuildContext context) {
    final label = widget.decoration.labelText ?? widget.decoration.hintText;
    return Positioned(
      top: 32,
      left: Zoro.gutter,
      right: Zoro.gutter,
      child: IgnorePointer(
        child: Align(
          alignment: Alignment.topCenter,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 1000),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xF2232A26),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0x29FFFFFF)),
            ),
            child: ListenableBuilder(
              listenable: _text,
              builder: (context, _) {
                final value = widget.obscureText
                    ? '•' * _text.text.length
                    : _text.text;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (label != null && label.isNotEmpty) ...[
                      Text(label, style: Zoro.font(20, color: Zoro.muted)),
                      const SizedBox(width: 16),
                    ],
                    Flexible(
                      child: Text(
                        value.isEmpty ? ' ' : value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textDirection: TextDirection.ltr,
                        style: Zoro.font(26, weight: FontWeight.w600),
                      ),
                    ),
                    Container(width: 3, height: 30, color: Zoro.jade),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: _echo,
    overlayChildBuilder: _echoStrip,
    child: Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: TextField(
        controller: _text,
        focusNode: _node,
        autofocus: widget.autofocus,
        enabled: widget.enabled,
        readOnly: !_editing,
        showCursor: _editing,
        obscureText: widget.obscureText,
        autocorrect: widget.autocorrect,
        enableSuggestions: widget.enableSuggestions && !widget.obscureText,
        keyboardType: widget.keyboardType,
        textInputAction: widget.textInputAction,
        style: widget.style,
        decoration: widget.decoration,
        onTap: _startEditing,
        onChanged: widget.onChanged,
        onSubmitted: (value) {
          _stopEditing();
          widget.onSubmitted?.call(value);
        },
      ),
    ),
  );
}
