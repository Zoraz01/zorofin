import 'dart:async';
import 'package:flutter/material.dart';

/// Presentation only: the player owns the decoder, timeline and reporting.
class PlayerPresentation extends ChangeNotifier {
  bool minimized = false;
  VoidCallback? onBack;
  VoidCallback? onExpanded;
  Future<void> Function()? onStop;
  VoidCallback? onClosed;

  void minimize() {
    minimized = true;
    notifyListeners();
  }

  void expand() {
    minimized = false;
    notifyListeners();
    WidgetsBinding.instance.addPostFrameCallback((_) => onExpanded?.call());
  }

  Future<void>? _stopping;
  Future<void> stop() => _stopping ??= _stop();
  Future<void> _stop() async {
    if (onStop == null) {
      closed();
    } else {
      await onStop!();
    }
  }

  void closed() => onClosed?.call();
}

/// Keeps one player mounted while its bounds change. No system PiP or overlay
/// permission is used. The background library retains its navigation state.
class InAppPlayerHost extends StatefulWidget {
  const InAppPlayerHost({super.key, required this.child});
  final Widget child;
  @override
  State<InAppPlayerHost> createState() => InAppPlayerHostState();
}

class InAppPlayerHostState extends State<InAppPlayerHost> {
  PlayerPresentation? _presentation;
  Widget? _player;
  Completer<void>? _finished;
  FocusNode? _returnFocus;
  int _opening = 0;
  bool get hasPlayer => _presentation != null;

  Future<void> closePlayer() async {
    _opening++;
    await _presentation?.stop();
  }

  Future<void> open(Widget Function(PlayerPresentation) builder) async {
    final operation = ++_opening;
    await _presentation?.stop();
    if (!mounted || operation != _opening) return;
    final presentation = PlayerPresentation();
    final finished = Completer<void>();
    _returnFocus = FocusManager.instance.primaryFocus;
    presentation.onClosed = () {
      if (!identical(_presentation, presentation)) return;
      presentation.removeListener(_changed);
      setState(() {
        _presentation = null;
        _player = null;
        _finished = null;
      });
      if (!finished.isCompleted) finished.complete();
      _restoreLibraryFocus();
      // The mounted player unregisters its callbacks during its dispose.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => presentation.dispose(),
      );
    };
    presentation.addListener(_changed);
    setState(() {
      _presentation = presentation;
      _finished = finished;
      _player = KeyedSubtree(
        key: ObjectKey(presentation),
        child: builder(presentation),
      );
    });
    await finished.future;
  }

  void _restoreLibraryFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _returnFocus?.context != null) {
        _returnFocus!.requestFocus();
      }
    });
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (_presentation?.minimized == true) _restoreLibraryFocus();
  }

  @override
  void dispose() {
    _opening++;
    final presentation = _presentation;
    presentation?.removeListener(_changed);
    presentation?.onClosed = null;
    if (_finished?.isCompleted == false) _finished!.complete();
    // PlayerScreen.dispose tears down decoder/network work on account changes.
    presentation?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final presentation = _presentation;
    final mini = presentation?.minimized ?? false;
    return PopScope(
      canPop: presentation == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || presentation == null) return;
        if (mini) {
          presentation.expand();
        } else {
          presentation.onBack?.call();
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          ExcludeFocus(
            excluding: presentation != null && !mini,
            child: widget.child,
          ),
          if (presentation != null)
            Positioned(
              left: mini ? null : 0,
              top: mini ? null : 0,
              right: mini ? 48 : 0,
              bottom: mini ? 32 : 0,
              width: mini ? 520 : null,
              height: mini ? 360 : null,
              // Share the enclosing scope with the library so directional
              // traversal can enter and leave the mini-player with a remote.
              child: FocusTraversalGroup(child: _player!),
            ),
        ],
      ),
    );
  }
}
