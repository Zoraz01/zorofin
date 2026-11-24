import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../core/catalog.dart';
import '../../core/errors.dart';
import '../../core/models.dart';
import '../../core/playback.dart';
import '../../core/preferences.dart';
import '../../core/server_extras.dart';
import '../../core/viewer_settings.dart';
import '../../watch_together.dart';
import '../player/player_controls.dart';
import '../player/player_panels.dart';
import '../theme.dart';
import '../widgets/focusable.dart';
import '../widgets/live_tv_notice.dart';
import '../widgets/subtitle_text.dart';
import 'detail_screen.dart';
import 'settings_screen.dart';

/// Full-screen playback with the Apple TV custom player's controls and
/// Jellyfin start/progress/stop reporting so watch state stays in sync.
///
/// Remote: with controls hidden, OK pauses and any arrow shows them; Play/
/// Pause toggles; Back closes an options page, cancels seeking, hides the
/// controls, then leaves the player.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.catalog,
    required this.item,
    this.startTicks,
    this.audioIndex,
    this.subtitleIndex = PlaybackOptions.automatic,
    this.burnSubtitles = false,
    this.liveCapacityCheck = false,
    this.liveStreamsCheck = false,
    this.group,
  });

  final JellyfinCatalog catalog;
  final MediaItem item;

  /// Where playback begins; defaults to the saved resume point.
  final int? startTicks;

  /// Tracks chosen on the details page; the defaults follow the account.
  final int? audioIndex;
  final int subtitleIndex;
  final bool burnSubtitles;

  /// Checks the server's Live TV limit before switching to another channel.
  final bool liveCapacityCheck;
  final bool liveStreamsCheck;

  /// Watch together: while joined, the group's server drives play, pause
  /// and seek.
  final WatchTogether? group;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> implements GroupPlayer {
  static const _reportEvery = Duration(seconds: 10);
  static const _hideAfter = Duration(seconds: 4);
  static const _upNextSeconds = 5;

  late MediaItem _item = widget.item;
  late PlaybackOptions _options;
  late Preferences? _prefs;
  bool _started = false;

  VideoPlayerController? _video;
  PlaybackPlan? _plan;
  PlayerPhase _phase = PlayerPhase.preparing;
  String? _error;

  /// Transcoded streams begin at the requested position, so the player's
  /// clock is offset from the title's timeline.
  Duration _offset = Duration.zero;

  /// Bumped on every stream change so late results of an older one are dropped.
  int _generation = 0;
  bool _closing = false;
  bool _endHandled = false;

  bool _controls = true;
  Timer? _hide;
  Timer? _reporter;

  Duration? _scrub;
  bool _resumeAfterScrub = false;

  PlayerPanel? _panel;
  bool _resumeAfterPanel = false;
  PlaybackOptions? _queued;

  MediaItem? _upNext;
  int? _countdown;
  Timer? _countdownTimer;

  List<LiveProgram> _guide = const [];
  DateTime? _guideAt;
  Timer? _guideTimer;
  List<MediaItem>? _channels;
  String? _channelError;

  /// Account defaults for track choice and autoplay, read once per player.
  Future<ViewerSettings>? _viewer;

  /// Cues of the text subtitle being drawn, on the title's own timeline.
  List<Caption> _captions = const [];

  /// Watch together: a menu or scrub holds this device out of the group.
  bool _suspended = false;
  Timer? _buffering;
  Timer? _drift;

  /// Pauses when the TV switches to another app or input, if the viewer
  /// keeps that setting on (Apple `pauseInBackground`).
  late final _lifecycle = AppLifecycleListener(onHide: _leftApp);

  void _leftApp() {
    if (_prefs?.value.pauseInBackground == false || !_playing) return;
    _suspendForInterface();
    unawaited(_video?.pause());
    unawaited(_report('progress'));
    _reveal(stay: true);
  }

  final _playFocus = FocusNode(debugLabel: 'player-play');

  /// The control that opened the options card, refocused when it closes.
  FocusNode? _panelOrigin;
  final _surfaceFocus = FocusNode(debugLabel: 'player-surface');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _prefs = Preferences.maybeOf(context);
    _options = PlaybackOptions(
      startTicks: widget.startTicks ?? widget.item.resumeTicks,
      bitrate: _prefs?.bitrate ?? 40000000,
      audioIndex: widget.audioIndex,
      subtitleIndex: widget.subtitleIndex,
      burnSubtitles: widget.burnSubtitles,
    );
    _lifecycle;
    widget.group?.addListener(_groupChanged);
    if (widget.group != null) {
      _drift = Timer.periodic(_reportEvery, (_) {
        if (_group != null) unawaited(_group!.correctDrift(this));
      });
    }
    unawaited(_open(_item, _options, resume: _group == null));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _playFocus.requestFocus();
    });
  }

  WatchTogether? get _group =>
      widget.group?.isJoined == true ? widget.group : null;

  @override
  String get syncItemId => _item.id;

  @override
  int get syncPositionTicks => MediaTime.ticks(_position);

  @override
  bool get isPlaying => _video?.value.isPlaying ?? false;

  @override
  bool get groupPlaybackSuspended => _suspended;

  /// The group chose another title while this player is open.
  void _groupChanged() {
    final group = widget.group;
    if (!mounted || _closing || group == null) return;
    final request = group.playbackRequest;
    if (request == null) return;
    group.takePlaybackRequest();
    _suspended = false;
    unawaited(
      _open(
        request.item,
        _options.copyWith(
          startTicks: request.startTicks,
          audioIndex: () => null,
          subtitleIndex: PlaybackOptions.automatic,
          burnSubtitles: false,
        ),
        resume: false,
      ),
    );
  }

  @override
  Future<void> applyGroupCommand(String command, int ticks) async {
    final video = _video;
    if (video == null ||
        _phase == PlayerPhase.preparing ||
        _phase == PlayerPhase.failed) {
      return;
    }
    if (command == 'Stop') {
      await video.pause();
      _reveal(stay: true);
      return;
    }
    if (!const {'Pause', 'Unpause', 'Seek'}.contains(command)) return;
    final shouldPlay =
        command == 'Unpause' ||
        command == 'Seek' && widget.group?.group?.state == 'Playing';
    await video.pause();
    final target = MediaTime.duration(ticks);
    if ((target - _position).abs() > const Duration(milliseconds: 150)) {
      await _localSeek(target, resume: false);
    }
    if (!mounted) return;
    if (shouldPlay) await _video?.play();
    if (command == 'Seek') await _group?.reportReadiness(buffering: false);
  }

  @override
  void applyGroupStop() {
    _suspended = true;
    unawaited(_video?.pause());
    _reveal(stay: true);
  }

  /// Menus pause this device without holding up the group.
  void _suspendForInterface() {
    final group = _group;
    if (group == null) return;
    _suspended = true;
    unawaited(group.pauseForInterface(this));
  }

  /// Back from a menu: rejoin the group's timeline.
  void _resumeAfterInterface() {
    _suspended = false;
    unawaited(_group?.playerReady(this, _item.id));
  }

  int get _skipBack => _prefs?.skipBack ?? 10;
  int get _skipForward => _prefs?.skipForward ?? 30;
  double get _speed => _prefs?.value.playbackSpeed ?? 1;

  /// A useful Live TV rewind window (Apple `canTimeShiftLive`).
  bool get _canTimeShift =>
      _item.isLive &&
      (_video?.value.duration ?? Duration.zero) >= const Duration(seconds: 30);

  /// How far a rewound broadcast is behind live; null at the live edge.
  Duration? get _behindLive {
    final value = _video?.value;
    if (!_canTimeShift || value == null) return null;
    final behind = value.duration - value.position;
    return behind > const Duration(seconds: 3) ? behind : null;
  }

  Future<ViewerSettings> _settings() => _viewer ??= widget.catalog
      .viewerSettings()
      .catchError((_) => ViewerSettings(name: ''));
  bool get _playing =>
      _phase == PlayerPhase.playing || _phase == PlayerPhase.buffering;
  bool get _directPlay => _plan?.method == 'DirectPlay';

  Duration get _position => (_video?.value.position ?? Duration.zero) + _offset;

  Duration? get _duration {
    final ticks = _item.runTimeTicks;
    if (ticks != null && ticks > 0) return MediaTime.duration(ticks);
    final value = _video?.value;
    return value == null || value.duration == Duration.zero
        ? null
        : value.duration + _offset;
  }

  // Stream lifecycle

  Future<void> _open(
    MediaItem item,
    PlaybackOptions options, {
    bool resume = true,
  }) async {
    final generation = ++_generation;
    await _teardown();
    if (!mounted || generation != _generation) return;
    setState(() {
      _item = item;
      _options = options;
      _phase = PlayerPhase.preparing;
      _error = null;
      _endHandled = false;
      _upNext = null;
      _countdown = null;
    });
    _countdownTimer?.cancel();
    _guideTimer?.cancel();
    if (item.isLive) {
      if (_guide.isNotEmpty && _guide.first.channelId != item.id) {
        _guide = const [];
      }
      unawaited(_loadGuide(item.id));
      _guideTimer = Timer.periodic(
        const Duration(seconds: 60),
        (_) => _loadGuide(item.id),
      );
    }
    try {
      if (item.isLive && options.subtitleIndex == PlaybackOptions.automatic) {
        options = options.copyWith(subtitleIndex: -1);
      }
      var plan = await widget.catalog.prepare(item, options);
      if (options.subtitleIndex == PlaybackOptions.automatic) {
        // The server's per-viewer defaults arrive with the first answer;
        // only a choice that needs a transcode asks again.
        final choice = (await _settings()).chooseTracks(
          plan.source,
          audioIndex: options.audioIndex,
        );
        final subtitle = plan.streams
            .where((s) => s.type == 'Subtitle' && s.index == choice.subtitle)
            .firstOrNull;
        options = options.copyWith(
          audioIndex: () => choice.audio,
          subtitleIndex: subtitle?.index ?? -1,
          burnSubtitles: subtitle != null && !subtitle.isTextSubtitle,
        );
        if (options.needsTranscode) {
          plan = await widget.catalog.prepare(item, options);
        }
      }
      if (!mounted || generation != _generation) return;
      _options = options;
      final video = VideoPlayerController.networkUrl(plan.url);
      _plan = plan;
      _video = video;
      await video.initialize();
      if (!mounted || generation != _generation) {
        await video.dispose();
        return;
      }
      final start = MediaTime.duration(options.startTicks);
      if (plan.method == 'DirectPlay') {
        _offset = Duration.zero;
        if (start > Duration.zero) await video.seekTo(start);
      } else {
        _offset = start;
      }
      video.addListener(_onVideo);
      final grouped = _group != null;
      if (grouped) resume = false;
      if (!item.isLive && _speed != 1 && !grouped) {
        await video.setPlaybackSpeed(_speed);
      }
      unawaited(_loadCaptions(generation));
      if (resume) await video.play();
      if (!mounted || generation != _generation) return;
      setState(
        () => _phase = resume ? PlayerPhase.playing : PlayerPhase.paused,
      );
      _reveal();
      unawaited(_report('start'));
      _reporter = Timer.periodic(_reportEvery, (_) => _report('progress'));
      if (grouped) unawaited(_group?.playerReady(this, item.id));
    } on ClientError catch (e) {
      _fail(generation, e.message);
    } catch (_) {
      _fail(
        generation,
        const ClientError(ClientErrorKind.unsupportedPlayback).message,
      );
    }
  }

  /// Fetches the chosen text subtitle as WebVTT; image subtitles are part
  /// of the video and need nothing here.
  Future<void> _loadCaptions(int generation) async {
    final plan = _plan;
    final path = plan == null || _options.burnSubtitles
        ? null
        : plan.subtitlePath(_options.subtitleIndex);
    setState(() => _captions = const []);
    if (path == null) return;
    try {
      final text = await widget.catalog.client.requestText(path);
      if (!mounted || generation != _generation) return;
      setState(() => _captions = WebVTTCaptionFile(text).captions);
    } catch (_) {
      // Playback continues without subtitles.
    }
  }

  String? get _caption {
    if (_captions.isEmpty) return null;
    final at = _position;
    final cue = _captions.where((c) => c.start <= at && at < c.end).firstOrNull;
    return cue?.text.replaceAll(RegExp(r'<[^>]+>'), '').trim();
  }

  void _fail(int generation, String message) {
    if (!mounted || generation != _generation) return;
    setState(() {
      _phase = PlayerPhase.failed;
      _error = message;
      _controls = false;
    });
  }

  /// Reports the stop for the current stream and releases it.
  Future<void> _teardown() async {
    _reporter?.cancel();
    final video = _video;
    if (video == null) return;
    video.removeListener(_onVideo);
    _video = null;
    final position = video.value.position + _offset;
    try {
      await video.pause();
    } catch (_) {}
    await _report('stop', video: video, position: position);
    _plan = null;
    await video.dispose();
  }

  Future<void> _report(
    String event, {
    VideoPlayerController? video,
    Duration? position,
  }) async {
    final plan = _plan;
    final player = video ?? _video;
    if (plan == null || player == null) return;
    try {
      await widget.catalog.client.reportPlayback(
        event,
        plan.report(
          positionTicks: MediaTime.ticks(position ?? _position),
          paused: event == 'stop' || !player.value.isPlaying,
          canSeek: !_item.isLive || _canTimeShift,
        ),
      );
    } catch (_) {
      // Reporting is best effort; playback continues.
    }
  }

  void _onVideo() {
    final video = _video;
    if (video == null || !mounted) return;
    final value = video.value;
    if (value.hasError) {
      _fail(
        _generation,
        const ClientError(ClientErrorKind.unsupportedPlayback).message,
      );
      return;
    }
    final PlayerPhase phase;
    if (value.isCompleted) {
      phase = PlayerPhase.ended;
    } else if (_phase == PlayerPhase.preparing) {
      phase = PlayerPhase.preparing;
    } else if (value.isPlaying) {
      phase = value.isBuffering ? PlayerPhase.buffering : PlayerPhase.playing;
    } else {
      phase = PlayerPhase.paused;
    }
    final previous = _phase;
    setState(() => _phase = phase);
    final group = _group;
    if (group != null && !_suspended && phase != previous) {
      _buffering?.cancel();
      if (phase == PlayerPhase.buffering) {
        _buffering = Timer(const Duration(seconds: 3), () {
          if (_phase == PlayerPhase.buffering) {
            unawaited(group.reportReadiness(buffering: true));
          }
        });
      } else if (phase == PlayerPhase.playing &&
          group.group?.state == 'Waiting') {
        unawaited(group.reportReadiness(buffering: false));
      }
    }
    if (phase == PlayerPhase.ended && !_endHandled) {
      _endHandled = true;
      unawaited(_onEnded());
    }
  }

  Future<void> _onEnded() async {
    _hide?.cancel();
    unawaited(_report('progress'));
    if (_group != null) {
      // The group moves on together.
      unawaited(_group!.nextItem());
      _reveal(stay: true);
      return;
    }
    if (!_item.isEpisode) {
      _reveal(stay: true);
      return;
    }
    final generation = _generation;
    MediaItem? next;
    try {
      next = await widget.catalog.episodeAfter(_item);
    } catch (_) {}
    if (!mounted || generation != _generation) return;
    if (next == null) {
      _reveal(stay: true);
      return;
    }
    final autoplay = (await _settings()).autoplayNext;
    if (!mounted || generation != _generation) return;
    setState(() {
      _upNext = next;
      _countdown = autoplay ? _upNextSeconds : null;
      _controls = false;
    });
    if (autoplay) {
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) return;
        final left = (_countdown ?? 0) - 1;
        if (left <= 0) {
          timer.cancel();
          _playUpNext();
        } else {
          setState(() => _countdown = left);
        }
      });
    }
  }

  Future<void> _loadGuide(String channelId) async {
    try {
      final programs = await widget.catalog.client.livePrograms(channelId);
      if (!mounted || _item.id != channelId) return;
      setState(() {
        _guide = programs;
        _guideAt = DateTime.now();
      });
    } catch (_) {
      // The guide is optional; the broadcast keeps playing.
    }
  }

  /// What is airing on the current channel, from a guide read in the last
  /// two minutes or the channel's own current program.
  LiveProgram? get _liveNow {
    final now = DateTime.now();
    final fresh =
        _guideAt != null &&
        now.difference(_guideAt!) < const Duration(minutes: 2);
    if (fresh) {
      final airing = _guide.where((p) => p.isAiring(now)).firstOrNull;
      if (airing != null) return airing;
    }
    final fallback = _item.currentProgram;
    return fallback != null && fallback.isAiring(now) ? fallback : null;
  }

  LiveProgram? get _liveNext {
    final after = _liveNow?.end ?? DateTime.now();
    return _guide.where((p) => !p.start!.isBefore(after)).firstOrNull;
  }

  Future<void> _loadChannels() async {
    setState(() {
      _channels = null;
      _channelError = null;
    });
    try {
      final page = await widget.catalog.client.channels(limit: 500);
      final seen = <String>{};
      if (mounted) {
        setState(
          () => _channels = page.items
              .where((c) => c.isLive && seen.add(c.id))
              .toList(),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _channelError =
              'Channels could not load. Your current broadcast can keep playing.',
        );
      }
    }
  }

  void _chooseChannel(MediaItem channel) {
    setState(() => _panel = null);
    if (channel.id == _item.id) {
      if (_resumeAfterPanel) unawaited(_video?.play());
      _controls = false;
      _reveal();
      return;
    }
    unawaited(_switchChannel(channel));
  }

  Future<void> _switchChannel(MediaItem channel) async {
    try {
      await widget.catalog.client.checkLiveTvCapacity(
        channel.id,
        enabled: widget.liveCapacityCheck,
        streams: widget.liveStreamsCheck,
      );
    } on LiveTvConflict catch (conflict) {
      if (!mounted) return;
      final join = await showLiveTvConflict(context, conflict);
      // The channel already playing needs no new stream.
      if (join != null && mounted) {
        await _open(join, PlaybackOptions(bitrate: _options.bitrate));
      }
      return;
    }
    if (!mounted) return;
    await _open(channel, PlaybackOptions(bitrate: _options.bitrate));
  }

  void _playUpNext() {
    final next = _upNext;
    if (next == null) return;
    _countdownTimer?.cancel();
    unawaited(
      _open(
        next,
        _options.copyWith(
          startTicks: next.resumeTicks,
          audioIndex: () => null,
          subtitleIndex: PlaybackOptions.automatic,
          burnSubtitles: false,
        ),
      ),
    );
  }

  void _cancelUpNext() {
    _countdownTimer?.cancel();
    setState(() {
      _upNext = null;
      _countdown = null;
    });
    _reveal(stay: true);
  }

  // Controls

  /// Shows the controls and restarts the hide timer. [stay] keeps them up,
  /// for example at the end of a title.
  void _reveal({bool stay = false}) {
    if (!mounted) return;
    final wasHidden = !_controls;
    _hide?.cancel();
    if (wasHidden) setState(() => _controls = true);
    if (wasHidden) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_controls || _panel != null) return;
        final origin = _panelOrigin;
        _panelOrigin = null;
        (origin != null && origin.context != null && origin.canRequestFocus
                ? origin
                : _playFocus)
            .requestFocus();
      });
    }
    if (stay || !_playing || _scrub != null || _panel != null) return;
    _hide = Timer(_hideAfter, () {
      if (!mounted || !_playing || _scrub != null || _panel != null) return;
      setState(() => _controls = false);
      _surfaceFocus.requestFocus();
    });
  }

  void _hideControls() {
    _hide?.cancel();
    setState(() => _controls = false);
    _surfaceFocus.requestFocus();
  }

  void _togglePlay() {
    final video = _video;
    if (video == null ||
        _phase == PlayerPhase.preparing ||
        _phase == PlayerPhase.failed) {
      return;
    }
    final group = _group;
    if (group != null) {
      _suspended = false;
      unawaited(group.requestPause(video.value.isPlaying));
      _reveal();
      return;
    }
    if (_phase == PlayerPhase.ended) {
      unawaited(_seekTo(Duration.zero, resume: true));
    } else if (video.value.isPlaying) {
      unawaited(video.pause());
    } else {
      unawaited(video.play());
    }
    unawaited(_report('progress'));
    _reveal();
  }

  void _skip(int seconds) {
    if (_item.isLive && !_canTimeShift) return;
    var target = _position + Duration(seconds: seconds);
    if (target.isNegative) target = Duration.zero;
    final total = _duration;
    if (total != null && target > total) target = total;
    if (_item.isLive) target = _clampLive(target);
    unawaited(_seekTo(target, resume: _playing));
    _reveal();
  }

  /// Stays a little behind the live edge so playback never outruns it.
  Duration _clampLive(Duration target) {
    final edge =
        (_video?.value.duration ?? Duration.zero) - const Duration(seconds: 2);
    return target > edge ? edge : target;
  }

  void _goLive() {
    if (_canTimeShift) {
      unawaited(_seekTo(_clampLive(_video!.value.duration), resume: true));
    } else {
      unawaited(_open(_item, PlaybackOptions(bitrate: _options.bitrate)));
    }
    _reveal();
  }

  /// Direct play and Live TV rewind seek in place; a transcode restarts at
  /// the new position.
  Future<void> _seekTo(Duration target, {required bool resume}) async {
    final group = _group;
    if (group != null) {
      _suspended = false;
      await group.requestSeek(target);
      return;
    }
    await _localSeek(target, resume: resume);
  }

  Future<void> _localSeek(Duration target, {required bool resume}) async {
    final video = _video;
    if (video == null) return;
    if (_directPlay || _item.isLive) {
      await video.seekTo(target);
      if (resume) await video.play();
      _endHandled = false;
      unawaited(_report('progress'));
    } else {
      await _open(
        _item,
        _options.copyWith(startTicks: MediaTime.ticks(target)),
        resume: resume,
      );
    }
  }

  void _scrubStart() {
    _resumeAfterScrub = _playing;
    _suspendForInterface();
    unawaited(_video?.pause());
    _hide?.cancel();
    setState(() => _scrub = _position);
  }

  void _scrubCommit() {
    final target = _scrub;
    setState(() => _scrub = null);
    if (target != null) {
      unawaited(
        _seekTo(
          _item.isLive ? _clampLive(target) : target,
          resume: _resumeAfterScrub,
        ),
      );
    }
    _reveal();
  }

  void _scrubCancel() {
    if (_scrub == null) return;
    setState(() => _scrub = null);
    if (_group != null) {
      _resumeAfterInterface();
    } else if (_resumeAfterScrub) {
      unawaited(_video?.play());
    }
    _reveal();
  }

  void _openPanel(PlayerPanel panel) {
    _hide?.cancel();
    _panelOrigin = FocusManager.instance.primaryFocus;
    _resumeAfterPanel = _playing;
    _suspendForInterface();
    unawaited(_video?.pause());
    setState(() {
      _panel = panel;
      _queued = null;
    });
    if (panel == PlayerPanel.channels) unawaited(_loadChannels());
  }

  void _closePanel() {
    final queued = _queued;
    setState(() {
      _panel = null;
      _queued = null;
    });
    if (queued != null &&
        queued.sameStream(_options) &&
        queued.subtitleIndex != _options.subtitleIndex) {
      // Text subtitles switch without restarting the stream.
      _options = queued.copyWith(startTicks: _options.startTicks);
      unawaited(_loadCaptions(_generation));
    }
    if (queued != null && !queued.sameStream(_options)) {
      unawaited(
        _open(
          _item,
          queued.copyWith(startTicks: MediaTime.ticks(_position)),
          resume: _resumeAfterPanel,
        ),
      );
    } else if (_group != null) {
      _resumeAfterInterface();
    } else if (_resumeAfterPanel) {
      unawaited(_video?.play());
    }
    _controls = false;
    _reveal();
  }

  void _chooseEpisode(MediaItem episode) {
    setState(() => _panel = null);
    final group = _group;
    if (group != null) {
      // The whole group switches; the new queue reopens this player.
      if (episode.id == _item.id) {
        _resumeAfterInterface();
      } else {
        unawaited(group.selectForPlayback(episode, episode.resumeTicks));
      }
      _controls = false;
      _reveal();
      return;
    }
    if (episode.id == _item.id) {
      if (_resumeAfterPanel) unawaited(_video?.play());
      _controls = false;
      _reveal();
      return;
    }
    unawaited(
      _open(
        episode,
        _options.copyWith(
          startTicks: episode.resumeTicks,
          audioIndex: () => null,
          subtitleIndex: PlaybackOptions.automatic,
          burnSubtitles: false,
        ),
      ),
    );
  }

  void _queue(PlaybackOptions next) => setState(() => _queued = next);

  /// Remote Back, innermost first.
  void _back() {
    if (_panel != null) {
      _closePanel();
    } else if (_scrub != null) {
      _scrubCancel();
    } else if (_upNext != null) {
      _cancelUpNext();
    } else if (_controls && _playing) {
      _hideControls();
    } else {
      unawaited(_close());
    }
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    _generation++;
    _hide?.cancel();
    _countdownTimer?.cancel();
    _guideTimer?.cancel();
    _buffering?.cancel();
    _drift?.cancel();
    final group = widget.group;
    if (group != null && group.isJoined) {
      unawaited(group.playerClosed(this));
    }
    await _teardown();
    if (mounted) Navigator.of(context).pop();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent ||
        _panel != null ||
        _upNext != null ||
        _error != null) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaFastForward ||
        key == LogicalKeyboardKey.mediaRewind) {
      _skip(key == LogicalKeyboardKey.mediaRewind ? -_skipBack : _skipForward);
      return KeyEventResult.handled;
    }
    if (!_controls) {
      final select = selectKeys.keys.any(
        (a) => a is SingleActivator && a.trigger == key,
      );
      final arrows = {
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
      };
      if (select) {
        // Apple TV: Select on the hidden surface pauses and shows controls.
        if (_playing) unawaited(_video?.pause());
        _reveal();
        return KeyEventResult.handled;
      }
      if (arrows.contains(key)) {
        _reveal();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    _reveal();
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    widget.group?.removeListener(_groupChanged);
    _buffering?.cancel();
    _drift?.cancel();
    _hide?.cancel();
    _countdownTimer?.cancel();
    _guideTimer?.cancel();
    _generation++;
    if (!_closing) unawaited(_teardown());
    _playFocus.dispose();
    _surfaceFocus.dispose();
    super.dispose();
  }

  // Presentation

  /// Live TV shows the program as the title and the channel beneath it.
  String get _title =>
      _item.isLive ? (_liveNow?.name ?? _item.name) : _item.displayTitle;

  String get _subtitle {
    if (_item.isLive) {
      return _liveNow == null
          ? 'Live TV'
          : [?_item.channelNumber, _item.name].join(' · ');
    }
    return _item.isEpisode ? _item.episodeLabel : '';
  }

  List<(String, String)> get _facts {
    final method = _plan?.method;
    final size = _video?.value.size;
    return [
      (
        'Playback',
        method == 'DirectPlay'
            ? 'Direct play'
            : (method == 'Transcode' ? 'Transcoding' : 'Preparing'),
      ),
      ('Quality limit', '${_options.bitrate ~/ 1000000} Mbps'),
      if (!_item.isLive) ('Speed', speedLabel(_speed)),
      if (_options.subtitleIndex >= 0)
        (
          'Subtitles',
          _options.burnSubtitles ? 'Burned in by the server' : 'Text',
        ),
      if (size != null && size.width > 0 && size.height > 0)
        (
          'Playing resolution',
          '${size.width.round()} × ${size.height.round()}',
        ),
    ];
  }

  String get _sourceSummary {
    final streams = _plan?.streams ?? const <MediaStream>[];
    final video = streams.where((s) => s.type == 'Video').firstOrNull;
    final audio =
        streams.where((s) => s.type == 'Audio' && s.isDefault).firstOrNull ??
        streams.where((s) => s.type == 'Audio').firstOrNull;
    return [
      if (video?.height != null) '${video!.height}p',
      ?video?.codec?.toUpperCase(),
      if (audio != null)
        [
          audio.codec?.toUpperCase(),
          if (audio.channels != null) '${audio.channels} ch',
        ].nonNulls.join(' '),
    ].where((s) => s.isNotEmpty).join(' · ');
  }

  Widget _panelSurface(PlayerPanel panel) {
    final options = _queued ?? _options;
    final pending = _queued != null && !_queued!.sameStream(_options);
    return switch (panel) {
      PlayerPanel.channels => PlayerOptionsSurface(
        title: 'Channels & guide',
        wide: true,
        onClose: _closePanel,
        child: ChannelChoices(
          currentId: _item.id,
          channels: _channels,
          error: _channelError,
          now: _liveNow,
          next: _liveNext,
          onRetry: _loadChannels,
          onSelect: _chooseChannel,
        ),
      ),
      PlayerPanel.episodes => PlayerOptionsSurface(
        title: 'Seasons & episodes',
        fullWidth: true,
        onClose: _closePanel,
        child: SeasonEpisodeBrowser(
          catalog: widget.catalog,
          context: _item,
          currentEpisodeId: _item.id,
          inPlayer: true,
          onOpen: _chooseEpisode,
        ),
      ),
      PlayerPanel.quality => PlayerOptionsSurface(
        title: 'Quality',
        onClose: _closePanel,
        footer: pending ? const PendingChangeNote() : null,
        child: QualityChoices(
          selected: options.bitrate,
          isLive: _item.isLive,
          onSelect: (bitrate) => _queue(options.copyWith(bitrate: bitrate)),
        ),
      ),
      PlayerPanel.tracks => PlayerOptionsSurface(
        title: 'Audio & subtitles',
        onClose: _closePanel,
        footer: pending ? const PendingChangeNote() : null,
        child: TrackChoices(
          streams: _plan?.streams ?? const [],
          options: options,
          isLive: _item.isLive,
          onAudio: (index) => _queue(options.copyWith(audioIndex: () => index)),
          onSubtitles: (index) {
            final stream = (_plan?.streams ?? const <MediaStream>[])
                .where((s) => s.type == 'Subtitle' && s.index == index)
                .firstOrNull;
            _queue(
              options.copyWith(
                subtitleIndex: index,
                burnSubtitles: stream != null && !stream.isTextSubtitle,
              ),
            );
          },
        ),
      ),
      PlayerPanel.information => PlayerOptionsSurface(
        title: 'Playback info',
        onClose: _closePanel,
        child: PlaybackInformation(facts: _facts, source: _sourceSummary),
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final video = _video;
    final streams = _plan?.streams ?? const <MediaStream>[];
    final upNext = _upNext;
    return Actions(
      actions: {
        BackIntent: CallbackAction<BackIntent>(onInvoke: (_) => _back()),
      },
      child: PopScope(
        canPop: _closing,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _back();
        },
        child: Focus(
          onKeyEvent: _onKey,
          child: Scaffold(
            // Transparent so the webOS video plane can show through.
            backgroundColor: Colors.transparent,
            body: Stack(
              fit: StackFit.expand,
              children: [
                if (video != null && video.value.isInitialized)
                  Center(
                    child: AspectRatio(
                      aspectRatio: video.value.aspectRatio,
                      child: VideoPlayer(video),
                    ),
                  ),
                Focus(focusNode: _surfaceFocus, child: const SizedBox.expand()),
                if (_caption case final caption? when caption.isNotEmpty)
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 180),
                    left: 160,
                    right: 160,
                    bottom: _controls ? 190 : 70,
                    child: IgnorePointer(
                      child: Center(
                        child: SubtitleText(
                          caption,
                          appearance: _prefs?.value.subtitleAppearance,
                        ),
                      ),
                    ),
                  ),
                ExcludeFocus(
                  excluding:
                      !_controls ||
                      _panel != null ||
                      _error != null ||
                      upNext != null,
                  child: IgnorePointer(
                    ignoring: !_controls,
                    child: AnimatedOpacity(
                      opacity: _controls && _error == null ? 1 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: PlayerControls(
                        title: _title,
                        subtitle: _subtitle,
                        phase: _phase,
                        position: _position,
                        duration: _duration,
                        scrubPosition: _scrub,
                        skipBack: _skipBack,
                        skipForward: _skipForward,
                        canSeek: !_item.isLive || _canTimeShift,
                        behindLive: _behindLive,
                        onGoLive:
                            _item.isLive &&
                                (_phase == PlayerPhase.paused ||
                                    _behindLive != null)
                            ? _goLive
                            : null,
                        hasEpisodes: _item.isEpisode && _item.seriesId != null,
                        hasTracks: streams.any(
                          (s) => s.type == 'Audio' || s.type == 'Subtitle',
                        ),
                        isLive: _item.isLive,
                        playFocus: _playFocus,
                        onClose: () => unawaited(_close()),
                        onTogglePlay: _togglePlay,
                        onSkip: _skip,
                        onPanel: _openPanel,
                        onScrubStart: _scrubStart,
                        onScrubMove: (t) => setState(() => _scrub = t),
                        onScrubCommit: _scrubCommit,
                        onScrubCancel: _scrubCancel,
                        onInteract: _reveal,
                      ),
                    ),
                  ),
                ),
                if (_error != null)
                  Center(
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 760),
                      padding: const EdgeInsets.all(32),
                      decoration: BoxDecoration(
                        color: const Color(0xD9000000),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.play_disabled_rounded,
                            size: 48,
                            color: Zoro.jade,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Unable to play',
                            style: Zoro.font(32, weight: FontWeight.w600),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: Zoro.font(22, color: Zoro.muted),
                          ),
                          const SizedBox(height: 24),
                          FocusTraversalGroup(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ZoroButton(
                                  label: 'Try again',
                                  primary: true,
                                  autofocus: true,
                                  onPressed: () => unawaited(
                                    _open(
                                      _item,
                                      _options.copyWith(
                                        startTicks: MediaTime.ticks(_position),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                ZoroButton(
                                  label: 'Close',
                                  onPressed: () => unawaited(_close()),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (upNext != null)
                  Positioned(
                    right: 48,
                    bottom: 48,
                    child: UpNextCard(
                      item: upNext,
                      countdown: _countdown,
                      onPlay: _playUpNext,
                      onCancel: _cancelUpNext,
                    ),
                  ),
                if (_panel != null)
                  Positioned.fill(child: _panelSurface(_panel!)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
