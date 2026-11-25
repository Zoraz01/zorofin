import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../core/catalog.dart';
import '../../core/models.dart';
import '../../core/preferences.dart';
import '../../core/trailer_previews.dart';
import '../theme.dart';
import 'media_card.dart';

/// Opens a trailer stream for a preview. Tests replace it.
typedef PreviewPlayerFactory = VideoPlayerController Function(Uri url);

/// A Home poster with Apple TV's trailer preview: rest on a movie or show for
/// two seconds and its local trailer plays muted in the widened card.
/// Play/Pause pauses or replays it, moving away stops it, and it returns to
/// the artwork after 30 seconds of playback. Never reports playback.
class TrailerPreviewCard extends StatefulWidget {
  const TrailerPreviewCard({
    super.key,
    required this.item,
    required this.catalog,
    required this.onPressed,
    this.formats,
    this.caption,
    this.autofocus = false,
    this.onFocus,
    this.focusNode,
  });

  final MediaItem item;
  final Catalog catalog;
  final VoidCallback onPressed;
  final List<String>? formats;
  final String? caption;
  final bool autofocus;
  final VoidCallback? onFocus;
  final FocusNode? focusNode;

  static const dwell = Duration(seconds: 2);
  static const firstFrame = Duration(seconds: 3);
  static const cap = Duration(seconds: 30);

  static PreviewPlayerFactory playerFactory = (url) =>
      VideoPlayerController.networkUrl(
        url,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );

  /// Trailer lookup; tests replace it.
  static Future<({Uri url, List<String>? subtitlePath})?> Function(
    Catalog catalog,
    MediaItem item,
  )
  lookup = (catalog, item) async {
    if (catalog is! JellyfinCatalog) return null;
    final trailer = await catalog.client.previewTrailer(item);
    return trailer == null
        ? null
        : (url: Uri.parse(trailer.url), subtitlePath: trailer.subtitlePath);
  };

  @override
  State<TrailerPreviewCard> createState() => _TrailerPreviewCardState();
}

class _TrailerPreviewCardState extends State<TrailerPreviewCard> {
  FocusNode? _own;
  FocusNode get _node => widget.focusNode ?? (_own ??= FocusNode());
  Timer? _timer, _guard;
  VideoPlayerController? _video;
  bool _visible = false, _paused = false, _none = false;
  int _turn = 0;
  Duration _played = Duration.zero, _last = Duration.zero;

  bool get _eligible =>
      widget.item.type == 'Movie' || widget.item.type == 'Series';

  @override
  void initState() {
    super.initState();
    _node.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(TrailerPreviewCard old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      (old.focusNode ?? _own)?.removeListener(_focusChanged);
      _node.addListener(_focusChanged);
    }
    if (old.item.id != widget.item.id) _stop();
  }

  @override
  void dispose() {
    _node.removeListener(_focusChanged);
    _stop(rebuild: false);
    _own?.dispose();
    super.dispose();
  }

  void _focusChanged() {
    if (_node.hasFocus) {
      _none = false;
      if (_eligible && Preferences.valueOf(context).autoplayPreviews) {
        _timer?.cancel();
        _timer = Timer(TrailerPreviewCard.dwell, _start);
      }
    } else {
      _stop();
    }
  }

  Future<void> _start() async {
    final turn = ++_turn;
    ({Uri url, List<String>? subtitlePath})? trailer;
    try {
      trailer = await TrailerPreviewCard.lookup(widget.catalog, widget.item);
    } catch (_) {
      trailer = null;
    }
    if (!mounted || turn != _turn || !_node.hasFocus) return;
    if (trailer == null) {
      _none = true;
      return;
    }
    final video = TrailerPreviewCard.playerFactory(trailer.url);
    _video = video;
    _played = Duration.zero;
    _last = Duration.zero;
    _guard = Timer(TrailerPreviewCard.firstFrame, () {
      if (turn == _turn && !_visible) _stop();
    });
    try {
      await video.initialize();
      if (!mounted || turn != _turn) return;
      setState(() {}); // Mount the initialized texture behind the backdrop.
      await video.setVolume(0);
      if (!mounted || turn != _turn) return;
      video.addListener(() => _progress(turn));
      await video.play();
      final path = trailer.subtitlePath;
      final catalog = widget.catalog;
      if (path != null && catalog is JellyfinCatalog && turn == _turn) {
        unawaited(_loadCaptions(catalog, path, video, turn));
      }
    } catch (_) {
      if (turn == _turn) _stop();
    }
  }

  Future<void> _loadCaptions(
    JellyfinCatalog catalog,
    List<String> path,
    VideoPlayerController video,
    int turn,
  ) async {
    try {
      final text = await catalog.client.requestText(path);
      if (!mounted || turn != _turn) return;
      await video.setClosedCaptionFile(Future.value(WebVTTCaptionFile(text)));
    } catch (_) {
      // Missing captions leave the muted preview playable.
    }
  }

  void _progress(int turn) {
    final video = _video;
    if (!mounted || turn != _turn || video == null) return;
    final value = video.value;
    if (value.hasError) return _stop();
    if (value.isPlaying &&
        !value.isBuffering &&
        value.position > Duration.zero &&
        !_visible) {
      _guard?.cancel();
      setState(() => _visible = true);
    }
    final now = value.position;
    if (value.isPlaying &&
        now > _last &&
        now - _last < const Duration(seconds: 2)) {
      _played += now - _last;
    }
    _last = now;
    if (_played >= TrailerPreviewCard.cap || value.isCompleted) _stop();
  }

  void _stop({bool rebuild = true}) {
    _turn++;
    _timer?.cancel();
    _guard?.cancel();
    final video = _video;
    _video = null;
    if (video != null) unawaited(video.dispose());
    if (rebuild && mounted && (video != null || _visible || _paused)) {
      setState(() {
        _visible = false;
        _paused = false;
      });
    } else {
      _visible = false;
      _paused = false;
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.mediaPlayPause &&
        key != LogicalKeyboardKey.mediaPlay &&
        key != LogicalKeyboardKey.mediaPause) {
      return KeyEventResult.ignored;
    }
    if (!_eligible || _none) return KeyEventResult.ignored;
    final video = _video;
    if (video != null && _visible) {
      if (video.value.isPlaying) {
        video.pause();
        setState(() => _paused = true);
      } else {
        video.play();
        setState(() => _paused = false);
      }
    } else if (video == null) {
      _timer?.cancel();
      unawaited(_start());
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final video = _video;
    final preview = video != null && video.value.isInitialized
        ? AnimatedOpacity(
            opacity: _visible ? 1 : 0,
            duration: Preferences.valueOf(context).reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 200),
            curve: Curves.easeIn,
            child: Stack(
              fit: StackFit.expand,
              children: [
                FittedBox(
                  fit: BoxFit.cover,
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox(
                    width: video.value.size.width,
                    height: video.value.size.height,
                    child: VideoPlayer(video),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: ValueListenableBuilder<VideoPlayerValue>(
                    valueListenable: video,
                    builder: (_, value, child) =>
                        ClosedCaption(text: value.caption.text),
                  ),
                ),
                if (_paused)
                  ColoredBox(
                    color: const Color(0x55000000),
                    child: Center(
                      child: Text(
                        'Paused',
                        style: Zoro.font(22, weight: FontWeight.w600),
                      ),
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 5,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor:
                          (_played.inMilliseconds /
                                  TrailerPreviewCard.cap.inMilliseconds)
                              .clamp(0.0, 1.0),
                      child: ColoredBox(color: Zoro.jade),
                    ),
                  ),
                ),
              ],
            ),
          )
        : null;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _key,
      child: MediaCard(
        item: widget.item,
        catalog: widget.catalog,
        onPressed: widget.onPressed,
        formats: widget.formats,
        caption: widget.caption,
        autofocus: widget.autofocus,
        onFocus: widget.onFocus,
        focusNode: _node,
        preview: preview,
        widenOnFocus: _eligible,
      ),
    );
  }
}
