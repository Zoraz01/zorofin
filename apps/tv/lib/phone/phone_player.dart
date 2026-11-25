import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../core/adaptive_quality.dart';
import '../core/catalog.dart';
import '../core/device_playback.dart';
import '../core/errors.dart';
import '../core/models.dart';
import '../core/ass.dart';
import '../core/pgs.dart';
import '../core/playback.dart';
import '../core/playback_capabilities.dart';
import '../core/playback_recovery.dart';
import '../core/playback_reports.dart';
import '../extras_state.dart';
import '../core/player_extras.dart';
import '../core/preferences.dart';
import '../core/server_extras.dart';
import '../core/viewer_settings.dart';
import '../ui/player/player_controls.dart' show PlayerPhase, timeLabel;
import '../ui/player/player_extras_ui.dart' show ScrubPreview;
import '../ui/player/player_panels.dart' show clockLabel, playbackSourceSummary;
import '../ui/screens/settings_screen.dart' show speedLabel;
import '../ui/theme.dart';
import '../ui/widgets/live_tv_notice.dart';
import '../ui/widgets/ass_overlay.dart';
import '../ui/widgets/pgs_overlay.dart';
import '../ui/widgets/subtitle_text.dart';
import '../watch_together.dart';
import 'phone_downloads.dart';

/// Full-screen route that turns the phone sideways for playback and puts
/// the previous orientations back when it closes.
class PhonePlayerRoute extends MaterialPageRoute<void> {
  PhonePlayerRoute({required super.builder}) : super(fullscreenDialog: true);
}

/// Landscape, edge-to-edge playback while a player is open.
mixin _FullScreenPlayback<T extends StatefulWidget> on State<T> {
  static int _orientationEpoch = 0;
  bool _wasPortrait = false;

  void enterFullScreen() {
    _orientationEpoch++;
    final size = WidgetsBinding
        .instance
        .platformDispatcher
        .views
        .firstOrNull
        ?.physicalSize;
    _wasPortrait = size != null && size.height > size.width;
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]),
    );
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
  }

  /// With auto-rotate off, Android keeps whatever rotation an app last
  /// forced, so a phone that came in upright is turned back upright before
  /// the lock is released.
  void leaveFullScreen() {
    if (_wasPortrait) {
      final epoch = ++_orientationEpoch;
      unawaited(
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
        ]).then(
          (_) => Future<void>.delayed(
            const Duration(milliseconds: 600),
            () => epoch == _orientationEpoch
                ? SystemChrome.setPreferredOrientations(const [])
                : null,
          ),
        ),
      );
    } else {
      unawaited(SystemChrome.setPreferredOrientations(const []));
    }
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  }
}

/// Streaming playback (Apple `NativePlayerView` on iPhone): custom controls,
/// gestures, audio/subtitle/quality/speed options, Up Next, Live TV with
/// rewind and the guide, Watch together, and Jellyfin start/progress/stop
/// reporting so watch state stays in sync.
class PhonePlayerScreen extends StatefulWidget {
  const PhonePlayerScreen({
    super.key,
    required this.catalog,
    required this.item,
    this.startTicks,
    this.audioIndex,
    this.subtitleIndex,
    this.burnSubtitles = false,
    this.liveCapacityCheck = false,
    this.liveStreamsCheck = false,
    this.group,
  });

  final JellyfinCatalog catalog;
  final MediaItem item;
  final int? startTicks;
  final int? audioIndex;
  final int? subtitleIndex;
  final bool burnSubtitles;
  final bool liveCapacityCheck;

  /// The companion names the channel in use (Watch ESPN / Not now).
  final bool liveStreamsCheck;
  final WatchTogether? group;

  @override
  State<PhonePlayerScreen> createState() => _PhonePlayerScreenState();
}

class _PhonePlayerScreenState extends State<PhonePlayerScreen>
    with _FullScreenPlayback
    implements GroupPlayer {
  static const _reportEvery = Duration(seconds: 10);
  static const _upNextSeconds = 5;

  late MediaItem _item = widget.item;
  late PlaybackOptions _options;
  AdaptiveQuality? _adaptive;
  Timer? _adaptiveTimer;
  bool _autoQuality = true;
  bool _adapting = false;
  Preferences? _prefs;
  bool _started = false;
  bool _streamReady = false;

  VideoPlayerController? _video;
  PlaybackPlan? _plan;
  PlayerPhase _phase = PlayerPhase.preparing;
  String? _error;
  int _generation = 0;
  bool _closing = false;
  bool _endHandled = false;

  /// The last position the decoder reported, so a retry or an automatic
  /// recovery reopens where the viewer was rather than at the start.
  Duration _lastPosition = Duration.zero;
  DateTime? _lastRecovery;

  final _controls = PlayerChromeController();
  Timer? _reporter;
  bool _resumeAfterSheet = false;

  MediaItem? _upNext;
  int? _countdown;
  Timer? _countdownTimer;

  List<LiveProgram> _guide = const [];
  Timer? _guideTimer;

  Future<ViewerSettings>? _viewer;
  List<Caption> _captions = const [];

  /// Blu-ray image subtitles drawn on the device, on the title's timeline.
  PgsSubtitles? _pgs;
  String? _pgsStatus;
  static const _pgsLoading = 'Loading Blu-ray subtitles';
  int _captionRequest = 0;

  /// Styled (ASS/SSA) subtitles drawn with their own look.
  AssSubtitles? _ass;

  /// Chapters and scrub thumbnails of the open title.
  PlayerExtras _extras = PlayerExtras.none;

  /// The show's (or movie's) remembered tracks and subtitle timing.
  TrackMemory? _memory;
  Duration _subtitleOffset = Duration.zero;
  Duration get _subtitleClock => _position - _subtitleOffset;

  Future<void> _loadExtras(MediaItem item, int generation) async {
    if (item.isLive) return;
    try {
      final extras = await widget.catalog.client.playerExtras(
        item.id,
        mediaSourceId: _plan?.source?.id,
      );
      if (mounted && generation == _generation) {
        final chapters = _prefs?.value.showChapters ?? false;
        setState(() => _extras = chapters ? extras : extras.withoutChapters());
      }
    } catch (_) {}
  }

  void _rememberChoice(PlaybackOptions before, PlaybackOptions after) {
    final prefs = _prefs;
    if (prefs == null || _item.isLive) return;
    final streams = _plan?.streams ?? const <MediaStream>[];
    final audioChanged = after.audioIndex != before.audioIndex;
    final subtitleChanged = after.subtitleIndex != before.subtitleIndex;
    if (!audioChanged && !subtitleChanged) return;
    final next = (_memory ?? const TrackMemory()).choosing(
      audio: audioChanged
          ? streams
                .where((s) => s.type == 'Audio' && s.index == after.audioIndex)
                .firstOrNull
          : null,
      subtitle: subtitleChanged
          ? streams
                .where(
                  (s) => s.type == 'Subtitle' && s.index == after.subtitleIndex,
                )
                .firstOrNull
          : null,
      off: subtitleChanged && after.subtitleIndex < 0 ? true : null,
    );
    _memory = next;
    unawaited(prefs.rememberTracks(TrackMemory.keyFor(_item), next));
  }

  void _setSubtitleOffset(Duration offset) {
    setState(() => _subtitleOffset = offset);
    final prefs = _prefs;
    if (prefs == null || _item.isLive) return;
    final next = (_memory ?? const TrackMemory()).withOffsets(subtitle: offset);
    _memory = next;
    unawaited(prefs.rememberTracks(TrackMemory.keyFor(_item), next));
  }

  ImageProvider _trickplaySheet(int sheet) {
    final client = widget.catalog.client;
    return NetworkImage(
      _extras.trickplay!
          .sheetUrl(
            client.server,
            _item.id,
            sheet,
            mediaSourceId: _plan?.source?.id,
          )
          .toString(),
      headers: client.authHeaders,
    );
  }

  ImageProvider? _chapterImage(int index) {
    final chapter = _extras.chapters[index];
    final tag = chapter.imageTag;
    if (tag == null) return null;
    final client = widget.catalog.client;
    return NetworkImage(
      client.chapterImage(_item.id, chapter.imageIndex, tag).toString(),
      headers: client.authHeaders,
    );
  }

  Widget _scrubPreview(Duration at) {
    final index = Chapter.indexAt(_extras.chapters, at);
    return ScrubPreview(
      position: at,
      width: 200,
      trickplay: _extras.trickplay,
      sheet: _extras.trickplay == null ? null : _trickplaySheet,
      chapter: index == null ? null : _extras.chapters[index].name,
    );
  }

  Future<void> _openChapters() async {
    final chapters = _extras.chapters;
    final current = Chapter.indexAt(chapters, _position);
    final chosen = await _sheet<Chapter>(
      (context) => _ChaptersSheet(
        chapters: chapters,
        current: current,
        image: _chapterImage,
      ),
    );
    if (!mounted) return;
    if (chosen != null) {
      _resumeAfterSheet = true;
      await _seekTo(chosen.start, resume: true);
    } else {
      _resumeAfter();
    }
  }

  bool _suspended = false;
  Timer? _buffering;

  /// Problems this player tells the server about, when the server collects
  /// them and the viewer left reporting on.
  PlayerProblems? _problems;
  ExtrasState? _serverExtras;
  String get _reportMethod =>
      playbackReportMethod(_plan?.method, live: _item.isLive);
  void _problem(PlaybackProblem problem, {String reason = ''}) =>
      _problems?.report(
        problem,
        _item,
        _reportMethod,
        reason: reason,
        position: _item.isLive ? null : _lastPosition,
      );
  Timer? _drift;
  double _speed = 1;

  late final _lifecycle = AppLifecycleListener(onHide: _leftApp);

  void _leftApp() {
    if (_prefs?.value.pauseInBackground ?? true) {
      if (_video?.value.isPlaying == true && _group == null) {
        unawaited(_video?.pause());
      }
    }
  }

  @override
  void initState() {
    super.initState();
    enterFullScreen();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _prefs = Preferences.maybeOf(context);
    _serverExtras = ExtrasScope.maybeOf(context);
    _problems = PlayerProblems(
      PlaybackReporter(
        client: widget.catalog.client,
        platform: 'Android phone',
        enabled: () =>
            (_serverExtras?.features.playbackReports ?? false) &&
            (_prefs?.value.sendPlaybackReports ?? true),
      ),
    );
    _speed = _prefs?.value.playbackSpeed ?? 1;
    _options = PlaybackOptions(
      startTicks: widget.startTicks ?? widget.item.resumeTicks,
      bitrate: _prefs?.bitrate ?? 40000000,
      audioIndex: widget.audioIndex,
      subtitleIndex: widget.subtitleIndex ?? PlaybackOptions.automatic,
      burnSubtitles: widget.burnSubtitles,
    );
    _adaptive = AdaptiveQuality(_options.bitrate);
    _adaptiveTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _adaptQuality(),
    );
    _lifecycle;
    widget.group?.addListener(_groupChanged);
    if (widget.group != null) {
      _drift = Timer.periodic(_reportEvery, (_) {
        if (_group != null) unawaited(_group!.correctDrift(this));
      });
    }
    unawaited(_open(_item, _options, resume: _group == null));
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
      _controls.reveal(stay: true);
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
    _controls.reveal(stay: true);
  }

  void _suspendForInterface() {
    final group = _group;
    if (group == null) return;
    _suspended = true;
    unawaited(group.pauseForInterface(this));
  }

  void _resumeAfterInterface() {
    _suspended = false;
    unawaited(_group?.playerReady(this, _item.id));
  }

  int get _skipBack => _prefs?.skipBack ?? 10;
  int get _skipForward => _prefs?.skipForward ?? 30;

  bool get _canTimeShift =>
      _item.isLive &&
      (_video?.value.duration ?? Duration.zero) >= const Duration(seconds: 30);

  Future<ViewerSettings> _settings() => _viewer ??= widget.catalog
      .viewerSettings()
      .catchError((_) => ViewerSettings(name: ''));

  bool get _playing =>
      _phase == PlayerPhase.playing || _phase == PlayerPhase.buffering;

  bool get _directPlay => _plan?.method == 'DirectPlay';

  Duration get _position {
    final value = _video?.value;
    if (!_streamReady || value == null || value.hasError) return _lastPosition;
    return value.position;
  }

  Duration? get _duration {
    if (_item.isLive) {
      final value = _video?.value;
      return value == null || value.duration == Duration.zero
          ? null
          : value.duration;
    }
    final ticks = _item.runTimeTicks;
    if (ticks != null && ticks > 0) return MediaTime.duration(ticks);
    final value = _video?.value;
    return value == null || value.duration == Duration.zero
        ? null
        : value.duration;
  }

  LiveProgram? get _liveNow {
    final now = DateTime.now();
    return _guide
            .where(
              (p) =>
                  p.hasSchedule &&
                  !p.start!.isAfter(now) &&
                  p.end!.isAfter(now),
            )
            .firstOrNull ??
        _item.currentProgram;
  }

  LiveProgram? get _liveNext {
    final now = DateTime.now();
    return _guide
        .where((p) => p.hasSchedule && p.start!.isAfter(now))
        .firstOrNull;
  }

  // Stream lifecycle

  List<IntroSegment> _intros = const [];

  Future<void> _loadIntros(String id, int generation) async {
    try {
      final markers = await widget.catalog.client.introSegments(id);
      if (mounted && generation == _generation) {
        setState(() => _intros = markers);
      }
    } catch (_) {
      // Older servers and episodes without markers use the ordinary transport.
    }
  }

  Future<void> _open(
    MediaItem item,
    PlaybackOptions options, {
    bool resume = true,
  }) async {
    final generation = ++_generation;
    _stall?.cancel();
    _serverWait.cancel();
    await _teardown();
    if (!mounted || generation != _generation) return;
    if (item.id != _item.id || _memory == null) {
      _memory = item.isLive
          ? null
          : _prefs?.trackMemory(TrackMemory.keyFor(item));
      _subtitleOffset = _memory?.subtitleOffset ?? Duration.zero;
    }
    if (item.id != _item.id) _extras = PlayerExtras.none;
    setState(() {
      _intros = const [];
      _item = item;
      _options = options;
      _phase = PlayerPhase.preparing;
      _streamReady = false;
      _parked = false;
      _error = null;
      _endHandled = false;
      _upNext = null;
      _countdown = null;
    });
    _countdownTimer?.cancel();
    _guideTimer?.cancel();
    _problems?.opening();
    if (item.isLive) {
      unawaited(_loadGuide(item.id));
      _guideTimer = Timer.periodic(
        const Duration(seconds: 60),
        (_) => _loadGuide(item.id),
      );
    }
    try {
      if (options.allowDirectPlay) {
        options = options.withDeviceCapabilities(
          await DevicePlayback.detect(),
          item,
        );
      }
      options = options.copyWith(
        selectAudioOnDevice:
            options.allowDirectPlay &&
            options.capabilities.detected &&
            DevicePlayback.supportsLocalAudioSelection &&
            !item.isLive &&
            _group == null,
      );
      if (!mounted || generation != _generation) return;
      if (item.isLive && options.subtitleIndex == PlaybackOptions.automatic) {
        options = options.copyWith(subtitleIndex: -1);
      }
      var plan = await widget.catalog.prepare(item, options);
      if (options.subtitleIndex == PlaybackOptions.automatic) {
        final choice = (await _settings()).chooseTracks(
          plan.source,
          audioIndex: options.audioIndex,
        );
        final remembered = options.audioIndex == null
            ? _memory?.pick(plan.streams)
            : null;
        final audioChoice = remembered?.audio ?? choice.audio;
        final subtitleChoice = remembered?.subtitle ?? choice.subtitle;
        final subtitle = plan.streams
            .where((s) => s.type == 'Subtitle' && s.index == subtitleChoice)
            .firstOrNull;
        options = options.copyWith(
          audioIndex: () => audioChoice,
          subtitleIndex: subtitle?.index ?? -1,
          burnSubtitles: plan.burnsIn(subtitle),
        );
        if (options.needsTranscode ||
            options.audioIndex != plan.options.audioIndex) {
          plan = await widget.catalog.prepare(item, options);
        }
      }
      if (!mounted || generation != _generation) {
        if (plan.liveStreamId != null) {
          try {
            await widget.catalog.client.closeLive(plan.liveStreamId!);
          } catch (_) {}
        }
        return;
      }
      _options = options;
      final video = VideoPlayerController.networkUrl(
        plan.url,
        viewType: DevicePlayback.viewType(plan),
        formatHint: plan.method == 'DirectPlay' ? null : VideoFormat.hls,
      );
      _plan = plan;
      _video = video;
      // Ask for subtitles while the video opens: the server can take most of
      // a minute to pull a Blu-ray track out of a file it has not served yet,
      // and every second saved here is a line that still shows.
      unawaited(_loadCaptions(generation));
      // A stream the device can't start must not sit on "Preparing video".
      await video.initialize().timeout(const Duration(seconds: 45));
      if (!mounted || generation != _generation) {
        await video.dispose();
        return;
      }
      await DevicePlayback.selectDirectAudio(
        video,
        plan,
        options,
      ).timeout(const Duration(seconds: 4));
      if (!mounted || generation != _generation) return;
      final start = MediaTime.duration(options.startTicks);
      if (!item.isLive) _lastPosition = start;
      if (!item.isLive && start > Duration.zero) await video.seekTo(start);
      if (!mounted || generation != _generation) return;
      _streamReady = true;
      video.addListener(_onVideo);
      final grouped = _group != null;
      if (grouped) resume = false;
      if (!item.isLive && _speed != 1 && !grouped) {
        await video.setPlaybackSpeed(_speed);
      }
      if (_extras == PlayerExtras.none) {
        unawaited(_loadExtras(item, generation));
      }
      if (item.isEpisode && _group == null) {
        unawaited(_loadIntros(item.id, generation));
      }
      if (resume) await video.play();
      if (!mounted || generation != _generation) return;
      setState(
        () => _phase = resume ? PlayerPhase.playing : PlayerPhase.paused,
      );
      _controls.reveal();
      _problems?.started(item, _reportMethod);
      unawaited(_report('start'));
      _reporter = Timer.periodic(_reportEvery, (_) => _report('progress'));
      if (grouped) unawaited(_group?.playerReady(this, item.id));
    } on ClientError catch (e) {
      _fail(generation, e.message);
    } catch (_) {
      if (!mounted || generation != _generation) return;
      if (_options.capabilities.detected && !item.isLive && _group == null) {
        // The device couldn't start what its decoders promised. Try once
        // more with the stream every device plays, at the same place.
        _problem(
          PlaybackProblem.fallback,
          reason: _video?.value.errorDescription ?? 'The stream did not open',
        );
        unawaited(
          _open(
            item,
            _options.copyWith(
              allowDirectPlay: false,
              capabilities: const PlaybackCapabilities(),
            ),
            resume: resume,
          ),
        );
        return;
      }
      _fail(
        generation,
        const ClientError(ClientErrorKind.playbackFailed).message,
      );
    }
  }

  Future<void> _loadCaptions(int generation) async {
    final request = ++_captionRequest;
    bool isCurrent() =>
        mounted && generation == _generation && request == _captionRequest;
    final plan = _plan;
    final path = plan == null || _options.burnSubtitles
        ? null
        : plan.subtitlePath(_options.subtitleIndex);
    final image = plan == null || _options.burnSubtitles
        ? null
        : plan.imageSubtitleUrl(_options.subtitleIndex);
    final styled = plan == null || _options.burnSubtitles
        ? null
        : plan.styledSubtitlePath(_options.subtitleIndex);
    setState(() {
      _captions = const [];
      _pgs = null;
      _pgsStatus = image == null ? null : _pgsLoading;
      _ass = null;
    });
    if (styled != null) {
      try {
        // The first request for an embedded track makes the server pull it
        // out of the file, which can outlast the usual wait on a long film.
        final text = await widget.catalog.client.requestText(
          styled,
          wait: const Duration(seconds: 90),
        );
        final ass = await compute(AssSubtitles.parse, text);
        if (!isCurrent()) return;
        setState(() => _ass = ass);
        return;
      } catch (_) {
        // Fall back to the plain WebVTT conversion below.
      }
    }
    if (image != null) {
      try {
        // Up to four 90-second waits: a long film's first extraction can
        // take more than one.
        final bytes = await widget.catalog.client.requestBytes(
          image,
          attempts: 4,
        );
        final pgs = await compute(PgsSubtitles.parse, bytes);
        if (!isCurrent()) return;
        setState(() {
          _pgs = pgs;
          _pgsStatus = null;
        });
      } catch (_) {
        if (isCurrent()) {
          setState(() => _pgsStatus = 'Blu-ray subtitles unavailable');
        }
      }
      return;
    }
    if (path == null) return;
    try {
      final text = await widget.catalog.client.requestText(path);
      if (!isCurrent()) return;
      setState(() => _captions = WebVTTCaptionFile(text).captions);
    } catch (_) {}
  }

  String? get _caption {
    // Say so while a Blu-ray track is still on its way, so missing lines at
    // the start are not mistaken for subtitles being off.
    if (_pgs == null && _pgsStatus == _pgsLoading && _streamReady) {
      return 'Loading subtitles…';
    }
    if (_captions.isEmpty) return null;
    final at = _subtitleClock;
    final cue = _captions.where((c) => c.start <= at && at < c.end).firstOrNull;
    return cue?.text.replaceAll(RegExp(r'<[^>]+>'), '').trim();
  }

  void _fail(int generation, String message) {
    if (!mounted || generation != _generation) return;
    final detail = _video?.value.errorDescription;
    _problem(
      _streamReady ? PlaybackProblem.stopped : PlaybackProblem.startFailed,
      reason: detail == null || detail.isEmpty ? message : '$message ($detail)',
    );
    setState(() {
      _phase = PlayerPhase.failed;
      _error = message;
    });
  }

  /// Some Android decoders give up while a stream sits paused. A paused
  /// player lets the stream go and reopens it at the same place when the
  /// viewer presses Play. While playing it reopens once; a second failure
  /// soon after shows "Try again", which also keeps the position.
  /// Waits for the server after the connection drops mid-playback.
  late final _serverWait = ServerWait(
    // Any answer will do: this asks whether the server is there at all.
    ping: () => widget.catalog.client.requestText(const [
      'System',
      'Info',
      'Public',
    ], authenticated: false),
  );
  bool _checkingServer = false;
  bool _reconnecting = false;
  Timer? _stall;

  /// A stream that had been playing broke, or sat buffering too long. If the
  /// server no longer answers, keep the place, show "Reconnecting…" and
  /// reopen when it is back. If it does answer, the stream is at fault and
  /// [whenReachable] applies the usual retry.
  Future<void> _reconnect(void Function() whenReachable) async {
    if (_checkingServer) return;
    _checkingServer = true;
    final generation = _generation;
    final at = MediaTime.ticks(_lastPosition);
    final result = await _serverWait.wait(
      onAway: () {
        if (!mounted || generation != _generation) return;
        _problem(
          PlaybackProblem.stalled,
          reason: 'Lost the connection to the server',
        );
        _video?.removeListener(_onVideo);
        setState(() {
          _reconnecting = true;
          _phase = PlayerPhase.buffering;
        });
      },
    );
    _checkingServer = false;
    if (!mounted || generation != _generation) {
      _reconnecting = false;
      return;
    }
    switch (result) {
      case ServerWaitResult.reachable:
        whenReachable();
      case ServerWaitResult.returned:
        setState(() => _reconnecting = false);
        _problem(
          PlaybackProblem.recovered,
          reason: 'Reconnected after the server came back',
        );
        unawaited(_open(_item, _options.copyWith(startTicks: at)));
      case ServerWaitResult.gaveUp:
        _reconnecting = false;
        _fail(
          generation,
          'Can’t reach your server. Check the connection, then try again.',
        );
      case ServerWaitResult.cancelled:
        _reconnecting = false;
    }
  }

  void _decoderFailed() {
    if (_video == null || _phase == PlayerPhase.failed) return;
    final playing =
        _phase == PlayerPhase.playing || _phase == PlayerPhase.buffering;
    if (_streamReady && playing && _group == null) {
      unawaited(_reconnect(_streamFailed));
      return;
    }
    _streamFailed();
  }

  void _streamFailed() {
    final video = _video;
    if (video == null || _phase == PlayerPhase.failed) return;
    video.removeListener(_onVideo);
    final playing =
        _phase == PlayerPhase.playing || _phase == PlayerPhase.buffering;
    if (!playing && !_item.isLive && _group == null) {
      unawaited(_park());
      return;
    }
    final now = DateTime.now();
    final recent =
        _lastRecovery != null &&
        now.difference(_lastRecovery!) < const Duration(seconds: 20);
    if (_item.isLive || recent || _group != null) {
      _fail(
        _generation,
        const ClientError(ClientErrorKind.playbackFailed).message,
      );
      return;
    }
    _lastRecovery = now;
    unawaited(
      _open(
        _item,
        _options.copyWith(startTicks: MediaTime.ticks(_lastPosition)),
      ),
    );
  }

  /// Paused with no stream open; Play reopens at [_lastPosition].
  bool _parked = false;

  Future<void> _park() async {
    ++_generation;
    await _teardown();
    if (!mounted) return;
    setState(() {
      _parked = true;
      _streamReady = false;
      _phase = PlayerPhase.paused;
    });
    _controls.reveal(stay: true);
  }

  void _unpark({bool resume = true}) => unawaited(
    _open(
      _item,
      _options.copyWith(startTicks: MediaTime.ticks(_lastPosition)),
      resume: resume,
    ),
  );

  Future<void> _teardown() async {
    _reporter?.cancel();
    final video = _video;
    if (video == null) return;
    video.removeListener(_onVideo);
    _video = null;
    final position = !_streamReady
        ? MediaTime.duration(_plan?.options.startTicks ?? 0)
        : video.value.hasError
        ? _lastPosition
        : video.value.position;
    try {
      await video.pause();
    } catch (_) {}
    final plan = _plan;
    await _report('stop', video: video, position: position);
    _plan = null;
    await video.dispose();
    if (plan != null) await widget.catalog.client.stopEncoding(plan);
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
    } catch (_) {}
  }

  void _onVideo() {
    final video = _video;
    if (video == null || !mounted) return;
    final value = video.value;
    if (value.hasError) {
      _decoderFailed();
      return;
    }
    if (_streamReady && !_item.isLive && value.position > Duration.zero) {
      _lastPosition = value.position;
    }
    final PlayerPhase phase;
    if (!_item.isLive &&
        value.isCompleted &&
        value.duration > Duration.zero &&
        !value.isPlaying) {
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
    if (phase != previous) {
      _stall?.cancel();
      if (phase == PlayerPhase.buffering &&
          _controls.scrub == null &&
          _group == null) {
        // Some players sit buffering forever on a lost connection instead of
        // reporting an error.
        final generation = _generation;
        _stall = Timer(const Duration(seconds: 20), () {
          if (_phase != PlayerPhase.buffering || generation != _generation) {
            return;
          }
          unawaited(_reconnect(() {}));
        });
      }
    }
    if (phase != previous && !_item.isLive) {
      _problems?.buffering(
        phase == PlayerPhase.buffering && _controls.scrub == null,
        _item,
        _reportMethod,
        () => _lastPosition,
      );
    }
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
    unawaited(_report('progress'));
    if (_group != null) {
      unawaited(_group!.nextItem());
      _controls.reveal(stay: true);
      return;
    }
    if (!_item.isEpisode) {
      _controls.reveal(stay: true);
      return;
    }
    final generation = _generation;
    MediaItem? next;
    try {
      next = await widget.catalog.episodeAfter(_item);
    } catch (_) {}
    if (!mounted || generation != _generation) return;
    if (next == null) {
      _controls.reveal(stay: true);
      return;
    }
    final autoplay = (await _settings()).autoplayNext;
    if (!mounted || generation != _generation) return;
    setState(() {
      _upNext = next;
      _countdown = autoplay ? _upNextSeconds : null;
    });
    _controls.hide();
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

  void _playUpNext() {
    final next = _upNext;
    _countdownTimer?.cancel();
    if (next == null) return;
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
    _controls.reveal(stay: true);
  }

  Future<void> _loadGuide(String channelId) async {
    try {
      final programs = await widget.catalog.client.livePrograms(channelId);
      if (!mounted || _item.id != channelId) return;
      setState(() => _guide = programs);
    } catch (_) {}
  }

  // Transport

  void _togglePlay() {
    if (_parked) {
      _unpark();
      return;
    }
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
      _controls.reveal();
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
    _controls.reveal();
  }

  void _skip(int seconds) {
    if (_item.isLive && !_canTimeShift) return;
    var target = _position + Duration(seconds: seconds);
    if (target.isNegative) target = Duration.zero;
    final total = _duration;
    if (total != null && target > total) target = total;
    if (_item.isLive) target = _clampLive(target);
    unawaited(_seekTo(target, resume: _playing));
  }

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
    _controls.reveal();
  }

  Future<void> _seekTo(Duration target, {required bool resume}) async {
    final group = _group;
    if (group != null) {
      _suspended = false;
      await group.requestSeek(target);
      return;
    }
    await _localSeek(target, resume: resume);
  }

  /// Direct play and Live TV rewind seek in place; a transcode restarts at
  /// the new position, as on TV.
  Future<void> _localSeek(Duration target, {required bool resume}) async {
    if (_parked) {
      setState(() => _lastPosition = target);
      if (resume) _unpark();
      return;
    }
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

  Future<void> _adaptQuality() async {
    final video = _video, plan = _plan;
    if (!mounted || video == null || plan == null || _adapting) return;
    final value = video.value;
    var ahead = 0.0;
    for (final range in value.buffered) {
      if (range.start <= value.position && range.end >= value.position) {
        ahead = (range.end - value.position).inMilliseconds / 1000;
      }
    }
    final next = _adaptive?.sample(
      now: DateTime.now().millisecondsSinceEpoch / 1000,
      position: _position.inMilliseconds / 1000,
      bitrate: _options.bitrate,
      sourceBitrate: plan.source?.bitrate,
      enabled: _autoQuality && _group == null && !_suspended && !_reconnecting,
      ready:
          value.isInitialized &&
          _phase != PlayerPhase.preparing &&
          _phase != PlayerPhase.ended &&
          _error == null,
      paused: !value.isPlaying,
      seeking: _controls.scrub != null,
      buffering: value.isBuffering,
      bufferedAhead: ahead,
    );
    if (next == null) return;
    if (next < _options.bitrate) {
      _problem(
        PlaybackProblem.qualityLowered,
        reason:
            '${_options.bitrate ~/ 1000000} to ${next ~/ 1000000} Mbps after buffering',
      );
    }
    _adapting = true;
    try {
      await _open(
        _item,
        _options.copyWith(
          bitrate: next,
          startTicks: MediaTime.ticks(_position),
        ),
      );
    } finally {
      _adapting = false;
    }
  }

  // Sheets

  Future<T?> _sheet<T>(WidgetBuilder builder) async {
    _resumeAfterSheet = _playing;
    _controls.hold();
    _suspendForInterface();
    if (_group == null) unawaited(_video?.pause());
    final result = await showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: builder,
    );
    if (!mounted) return result;
    _controls.release();
    return result;
  }

  void _resumeAfter({PlaybackOptions? next}) {
    if (next != null && !next.sameStream(_options)) {
      unawaited(
        _open(
          _item,
          next.copyWith(startTicks: MediaTime.ticks(_position)),
          resume: _resumeAfterSheet,
        ),
      );
      return;
    }
    if (next != null && next.subtitleIndex != _options.subtitleIndex) {
      _options = next.copyWith(startTicks: _options.startTicks);
      unawaited(_loadCaptions(_generation));
    }
    if (_group != null) {
      _resumeAfterInterface();
    } else if (_resumeAfterSheet) {
      if (_parked) {
        _unpark();
      } else {
        unawaited(_video?.play());
      }
    }
  }

  Future<void> _openOptions() async {
    var info = false;
    final next = await _sheet<PlaybackOptions>(
      (context) => _OptionsSheet(
        onInfo: () => info = true,
        streams: _plan?.streams ?? const [],
        options: _options,
        autoQuality: _autoQuality,
        speed: _speed,
        live: _item.isLive,
        grouped: _group != null,
        subtitleOffset: _subtitleOffset,
        onSubtitleOffset: _item.isLive ? null : _setSubtitleOffset,
        onAutoQuality: (value) => _autoQuality = value,
        onSpeed: (value) {
          _speed = value;
          unawaited(_video?.setPlaybackSpeed(value));
        },
      ),
    );
    if (next != null) _rememberChoice(_options, next);
    if (info && mounted) {
      final resume = _resumeAfterSheet;
      await _openInformation();
      _resumeAfterSheet = resume;
      if (!mounted) return;
    }
    _resumeAfter(next: next);
  }

  /// Playback info (Apple `playbackInformation`): how the server is sending
  /// this stream and why, plus what the phone is actually playing.
  Future<void> _openInformation() async {
    final plan = _plan;
    final client = widget.catalog.client;
    await _sheet<void>(
      (context) => _InformationSheet(
        load: plan == null
            ? Future.value(const [])
            : client
                  .playbackDiagnostics(plan)
                  .catchError((_) => PlaybackDiagnostics.fromPlan(plan))
                  .then(_facts),
        initial: _facts(
          plan == null ? null : PlaybackDiagnostics.fromPlan(plan),
        ),
        source: playbackSourceSummary(plan?.streams ?? const []),
      ),
    );
  }

  List<(String, String)> _facts(PlaybackDiagnostics? diagnostics) {
    final size = _video?.value.size;
    return [
      ...?diagnostics?.facts,
      (
        'Quality mode',
        _autoQuality
            ? 'Auto${_adaptive?.reason == null ? '' : ' · ${_adaptive!.reason}'}'
            : 'Fixed',
      ),
      if (!_item.isLive) ('Speed', speedLabel(_speed)),
      if (_options.subtitleIndex >= 0)
        (
          'Subtitles',
          _options.burnSubtitles
              ? 'Burned in by the server'
              : _pgs != null
              ? 'Blu-ray, drawn on this device'
              : _ass != null
              ? 'Styled, drawn on this device'
              : _pgsStatus ?? 'Text',
        ),
      if (size != null && size.width > 0 && size.height > 0)
        (
          'Playing resolution',
          '${size.width.round()} × ${size.height.round()}',
        ),
    ];
  }

  Future<void> _openEpisodes() async {
    final seriesId = _item.seriesId;
    final seasonId = _item.seasonId;
    if (seriesId == null || seasonId == null) return;
    final chosen = await _sheet<MediaItem>(
      (context) => _EpisodesSheet(
        catalog: widget.catalog,
        seriesId: seriesId,
        seasonId: seasonId,
        currentId: _item.id,
      ),
    );
    if (chosen == null || chosen.id == _item.id) {
      _resumeAfter();
      return;
    }
    final group = _group;
    if (group != null) {
      unawaited(group.selectForPlayback(chosen, chosen.resumeTicks));
      return;
    }
    unawaited(
      _open(
        chosen,
        _options.copyWith(
          startTicks: chosen.resumeTicks,
          audioIndex: () => null,
          subtitleIndex: PlaybackOptions.automatic,
          burnSubtitles: false,
        ),
      ),
    );
  }

  Future<void> _openChannels() async {
    final chosen = await _sheet<MediaItem>(
      (context) => _ChannelsSheet(
        catalog: widget.catalog,
        currentId: _item.id,
        now: _liveNow,
        next: _liveNext,
      ),
    );
    if (chosen == null || chosen.id == _item.id) {
      _resumeAfter();
      return;
    }
    var target = chosen;
    if (widget.liveCapacityCheck || widget.liveStreamsCheck) {
      try {
        await widget.catalog.client.checkLiveTvCapacity(
          chosen.id,
          enabled: widget.liveCapacityCheck,
          streams: widget.liveStreamsCheck,
        );
      } on LiveTvConflict catch (conflict) {
        if (!mounted) return;
        final join = await showLiveTvConflict(context, conflict);
        // The channel already playing needs no new stream.
        if (join == null || join.id == _item.id || !mounted) {
          _resumeAfter();
          return;
        }
        target = join;
      }
    }
    if (!mounted) return;
    _guide = const [];
    unawaited(_open(target, PlaybackOptions(bitrate: _options.bitrate)));
  }

  Future<void>? _closeOperation;
  Future<void> _close() => _closeOperation ??= _performClose();

  Future<void> _performClose() async {
    if (_closing) return;
    _closing = true;
    _generation++;
    _countdownTimer?.cancel();
    _guideTimer?.cancel();
    _buffering?.cancel();
    _drift?.cancel();
    final group = widget.group;
    if (group != null && group.isJoined) unawaited(group.playerClosed(this));
    await _teardown();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    leaveFullScreen();
    _adaptiveTimer?.cancel();
    _stall?.cancel();
    _serverWait.cancel();
    _problems?.dispose();
    _lifecycle.dispose();
    widget.group?.removeListener(_groupChanged);
    _buffering?.cancel();
    _drift?.cancel();
    _countdownTimer?.cancel();
    _guideTimer?.cancel();
    _controls.dispose();
    _generation++;
    if (!_closing) unawaited(_teardown());
    super.dispose();
  }

  String get _title =>
      _item.isLive ? (_liveNow?.name ?? _item.name) : _item.displayTitle;

  String get _subtitle {
    if (_item.isLive) {
      return [?_item.channelNumber, _item.name].join(' · ');
    }
    return _item.isEpisode ? '${_item.episodeLabel} · ${_item.name}' : '';
  }

  @override
  Widget build(BuildContext context) {
    final value = _video?.value;
    final introEnd = _group == null && _error == null && _streamReady
        ? introEndAt(_intros, _position, _duration)
        : null;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: PlayerChrome(
        controller: _controls,
        video: _video,
        phase: _phase,
        title: _title,
        subtitle: _subtitle,
        position: _position,
        duration: _duration,
        live: _item.isLive,
        canSeek: !_item.isLive || _canTimeShift,
        atLiveEdge:
            !_canTimeShift ||
            (value != null &&
                value.duration - value.position < const Duration(seconds: 6)),
        caption: _caption,
        pgsFrame: _pgs?.frameAt(_subtitleClock),
        styled: _ass,
        styledLines: _ass?.activeAt(_subtitleClock) ?? const [],
        error: _error,
        skipBack: _skipBack,
        skipForward: _skipForward,
        onClose: _close,
        onTogglePlay: _togglePlay,
        onSkip: _skip,
        onSeek: (target) => _seekTo(
          _item.isLive ? _clampLive(target) : target,
          resume: _playing,
        ),
        onScrubStart: _suspendForInterface,
        onGoLive: _item.isLive ? _goLive : null,
        onOptions: _openOptions,
        onEpisodes: _item.isEpisode ? _openEpisodes : null,
        onChannels: _item.isLive ? _openChannels : null,
        onChapters: _extras.chapters.isEmpty || _item.isLive
            ? null
            : _openChapters,
        marks: [for (final c in _extras.chapters) c.start],
        preview: _item.isLive ? null : _scrubPreview,
        onRetry: () => _open(
          _item,
          _options.copyWith(startTicks: MediaTime.ticks(_position)),
        ),
        liveInfo: _item.isLive
            ? _LiveInfo(now: _liveNow, next: _liveNext, channelId: _item.id)
            : null,
        overlay: _reconnecting
            ? const Center(child: _Reconnecting())
            : _upNext == null
            ? introEnd == null
                  ? null
                  : Positioned(
                      right: 20,
                      bottom: 96,
                      child: FilledButton(
                        onPressed: () => _seekTo(introEnd, resume: _playing),
                        child: const Text('Skip intro'),
                      ),
                    )
            : _UpNextCard(
                item: _upNext!,
                catalog: widget.catalog,
                countdown: _countdown,
                onPlay: _playUpNext,
                onCancel: _cancelUpNext,
              ),
      ),
    );
  }
}

/// Offline playback of a downloaded copy, with progress saved on the device
/// and sent to the server when it is reachable.
class PhoneOfflinePlayerScreen extends StatefulWidget {
  const PhoneOfflinePlayerScreen({super.key, required this.record});

  final DownloadRecord record;

  @override
  State<PhoneOfflinePlayerScreen> createState() =>
      _PhoneOfflinePlayerScreenState();
}

class _PhoneOfflinePlayerScreenState extends State<PhoneOfflinePlayerScreen>
    with _FullScreenPlayback {
  VideoPlayerController? _video;
  PlayerPhase _phase = PlayerPhase.preparing;
  String? _error;
  final _controls = PlayerChromeController();
  Timer? _saver;
  bool _closing = false;

  /// Where playback was last seen, so a retry or recovery keeps the place.
  late Duration _lastPosition = MediaTime.duration(widget.record.resumeTicks);
  DateTime? _lastRecovery;

  @override
  void initState() {
    super.initState();
    enterFullScreen();
    unawaited(_open());
  }

  /// Some files (older Data saver downloads) carry no duration; the
  /// title's runtime stands in so the timeline still shows progress.
  Duration? get _duration {
    final reported = _video?.value.duration ?? Duration.zero;
    if (reported > Duration.zero) return reported;
    final ticks = widget.record.media.runTimeTicks ?? 0;
    return ticks > 0 ? MediaTime.duration(ticks) : null;
  }

  Duration get _position {
    final value = _video?.value;
    if (value == null || !value.isInitialized || value.hasError) {
      return _lastPosition;
    }
    return value.position;
  }

  Future<void> _open({bool resume = true}) async {
    final file = PhoneDownloads.instance.fileOf(widget.record);
    if (file == null || !file.existsSync()) {
      setState(() {
        _phase = PlayerPhase.failed;
        _error = 'This download is missing. Remove it and download it again.';
      });
      return;
    }
    final old = _video;
    old?.removeListener(_onVideo);
    final video = VideoPlayerController.file(File(file.path));
    setState(() {
      _video = video;
      _parked = false;
      _phase = PlayerPhase.preparing;
      _error = null;
    });
    if (old != null) unawaited(old.dispose());
    try {
      await video.initialize();
      if (_lastPosition > Duration.zero) await video.seekTo(_lastPosition);
      if (!mounted || _video != video) return;
      video.addListener(_onVideo);
      if (resume) await video.play();
      if (!mounted) return;
      setState(
        () => _phase = resume ? PlayerPhase.playing : PlayerPhase.paused,
      );
      _controls.reveal();
      _saver ??= Timer.periodic(const Duration(seconds: 10), (_) => _save());
    } catch (_) {
      if (mounted && _video == video) {
        setState(() {
          _phase = PlayerPhase.failed;
          _error = 'This download can’t be played on this device.';
        });
      }
    }
  }

  /// Paused with the file closed; Play reopens at [_lastPosition].
  bool _parked = false;

  /// When the decoder gives up (seen while paused on some Android devices),
  /// a paused player closes the file and reopens it on Play; a playing one
  /// reopens once at the same place, then shows "Try again".
  void _decoderFailed() {
    final video = _video;
    if (video == null || _phase == PlayerPhase.failed) return;
    video.removeListener(_onVideo);
    if (_phase == PlayerPhase.paused) {
      unawaited(_save());
      setState(() {
        _video = null;
        _parked = true;
      });
      unawaited(video.dispose());
      _controls.reveal(stay: true);
      return;
    }
    final now = DateTime.now();
    if (_lastRecovery != null &&
        now.difference(_lastRecovery!) < const Duration(seconds: 20)) {
      setState(() {
        _phase = PlayerPhase.failed;
        _error = 'This download stopped playing. Try again.';
      });
      return;
    }
    _lastRecovery = now;
    unawaited(_open());
  }

  void _onVideo() {
    final value = _video?.value;
    if (value == null || !mounted) return;
    if (value.hasError) {
      _decoderFailed();
      return;
    }
    if (value.isInitialized && value.position > Duration.zero) {
      _lastPosition = value.position;
    }
    setState(() {
      _phase = value.isCompleted && !value.isPlaying
          ? PlayerPhase.ended
          : value.isPlaying
          ? (value.isBuffering ? PlayerPhase.buffering : PlayerPhase.playing)
          : PlayerPhase.paused;
    });
  }

  Future<void> _seek(Duration target) async {
    if (_parked) {
      setState(() => _lastPosition = target);
      return;
    }
    await _video?.seekTo(target);
  }

  Future<void> _save() async {
    if (_video == null && !_parked) return;
    await PhoneDownloads.instance.saveProgress(widget.record, _position);
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    _saver?.cancel();
    await _save();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    leaveFullScreen();
    _saver?.cancel();
    _controls.dispose();
    _video?.removeListener(_onVideo);
    unawaited(_video?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final prefs = Preferences.valueOf(context);
    final media = widget.record.media;
    final video = _video;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: PlayerChrome(
        controller: _controls,
        video: video,
        phase: _phase,
        title: media.displayTitle,
        subtitle: media.isEpisode
            ? '${media.episodeLabel} · ${media.name} · Downloaded'
            : 'Downloaded',
        position: _position,
        duration: _duration,
        live: false,
        canSeek: true,
        atLiveEdge: true,
        error: _error,
        skipBack: prefs.skipBack,
        skipForward: prefs.skipForward,
        onClose: _close,
        onTogglePlay: () {
          if (_parked) {
            unawaited(_open());
            return;
          }
          final v = _video;
          if (v == null) return;
          if (_phase == PlayerPhase.ended) {
            unawaited(v.seekTo(Duration.zero).then((_) => v.play()));
          } else if (v.value.isPlaying) {
            unawaited(v.pause());
          } else {
            unawaited(v.play());
          }
          _controls.reveal();
        },
        onSkip: (seconds) {
          var target = _position + Duration(seconds: seconds);
          if (target.isNegative) target = Duration.zero;
          final total = _duration;
          if (total != null && target > total) target = total;
          unawaited(_seek(target));
        },
        onSeek: _seek,
        onRetry: _open,
      ),
    );
  }
}

/// Shows and hides the player controls, and holds them during a scrub or
/// while a sheet is open.
class PlayerChromeController extends ChangeNotifier {
  bool visible = true;
  bool locked = false;
  Duration? scrub;
  bool _held = false;
  Timer? _hide;
  bool _disposed = false;

  void reveal({bool stay = false}) {
    visible = true;
    _hide?.cancel();
    if (!stay && !_held) {
      _hide = Timer(const Duration(seconds: 4), () {
        if (scrub == null && !_held) hide();
      });
    }
    _notify();
  }

  void hide() {
    _hide?.cancel();
    visible = false;
    _notify();
  }

  void toggle() => visible ? hide() : reveal();

  void hold() {
    _held = true;
    _hide?.cancel();
    _notify();
  }

  void release() {
    _held = false;
    reveal();
  }

  void setLocked(bool value) {
    locked = value;
    value ? hide() : reveal();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _hide?.cancel();
    super.dispose();
  }
}

String _clock(Duration d) {
  final total = d.inSeconds.abs();
  final h = total ~/ 3600, m = (total % 3600) ~/ 60, s = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// The iPhone player surface: video, subtitles, a gesture layer (tap to
/// show controls, double-tap a side to skip), and the controls over a
/// top and bottom gradient.
class PlayerChrome extends StatefulWidget {
  const PlayerChrome({
    super.key,
    required this.controller,
    required this.video,
    required this.phase,
    required this.title,
    required this.subtitle,
    required this.position,
    required this.duration,
    required this.live,
    required this.canSeek,
    required this.atLiveEdge,
    required this.skipBack,
    required this.skipForward,
    required this.onClose,
    required this.onTogglePlay,
    required this.onSkip,
    required this.onSeek,
    this.onRetry,
    this.onScrubStart,
    this.onGoLive,
    this.onOptions,
    this.onEpisodes,
    this.onChannels,
    this.onChapters,
    this.marks = const [],
    this.preview,
    this.caption,
    this.pgsFrame,
    this.styled,
    this.styledLines = const [],
    this.error,
    this.liveInfo,
    this.overlay,
  });

  final PlayerChromeController controller;
  final VideoPlayerController? video;
  final PlayerPhase phase;
  final String title;
  final String subtitle;
  final Duration position;
  final Duration? duration;
  final bool live;
  final bool canSeek;
  final bool atLiveEdge;
  final int skipBack;
  final int skipForward;
  final String? caption;

  /// A Blu-ray subtitle frame drawn over the picture.
  final PgsFrame? pgsFrame;

  /// Styled subtitles and the lines on screen now.
  final AssSubtitles? styled;
  final List<AssEvent> styledLines;
  final String? error;
  final VoidCallback onClose;
  final VoidCallback onTogglePlay;
  final ValueChanged<int> onSkip;
  final Future<void> Function(Duration target) onSeek;
  final VoidCallback? onRetry;
  final VoidCallback? onScrubStart;
  final VoidCallback? onGoLive;
  final VoidCallback? onOptions;
  final VoidCallback? onEpisodes;
  final VoidCallback? onChannels;
  final VoidCallback? onChapters;

  /// Chapter starts, drawn as breaks on the seek bar.
  final List<Duration> marks;

  /// Floats over the seek bar while dragging.
  final Widget Function(Duration position)? preview;
  final Widget? liveInfo;
  final Widget? overlay;

  @override
  State<PlayerChrome> createState() => _PlayerChromeState();
}

class _PlayerChromeState extends State<PlayerChrome> {
  bool _fill = false;
  int? _feedback;
  Timer? _feedbackTimer;

  PlayerChromeController get _c => widget.controller;

  @override
  void dispose() {
    _feedbackTimer?.cancel();
    super.dispose();
  }

  void _doubleTap(TapDownDetails details, double width) {
    if (!widget.canSeek || _c.locked) return;
    final back = details.localPosition.dx < width / 2;
    final seconds = back ? -widget.skipBack : widget.skipForward;
    widget.onSkip(seconds);
    _feedbackTimer?.cancel();
    setState(() => _feedback = seconds);
    _feedbackTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _feedback = null);
    });
  }

  /// Chapter breaks on the seek bar, and the preview above it while dragging.
  Widget _seekExtras(Duration duration, Widget slider) => LayoutBuilder(
    builder: (context, size) {
      const inset = 12.0;
      final width = size.maxWidth - inset * 2;
      final total = duration.inMilliseconds;
      final scrub = _c.scrub;
      final fraction = scrub == null || total <= 0
          ? 0.0
          : (scrub.inMilliseconds / total).clamp(0.0, 1.0);
      return Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          slider,
          if (total > 0)
            for (final mark in widget.marks)
              if (mark > Duration.zero && mark.inMilliseconds < total)
                Positioned(
                  left: inset + width * mark.inMilliseconds / total - 1,
                  child: IgnorePointer(
                    child: Container(
                      width: 2,
                      height: 4,
                      color: Colors.black54,
                    ),
                  ),
                ),
          if (scrub != null && widget.preview != null)
            Positioned(
              left: inset,
              right: inset,
              bottom: 26,
              child: Align(
                alignment: Alignment(fraction * 2 - 1, 1),
                child: widget.preview!(scrub),
              ),
            ),
        ],
      );
    },
  );

  Widget _icon(
    IconData icon,
    String label,
    VoidCallback? onPressed, {
    double size = 24,
  }) => IconButton(
    tooltip: label,
    onPressed: onPressed,
    iconSize: size,
    color: Colors.white,
    style: IconButton.styleFrom(
      backgroundColor: Colors.black45,
      minimumSize: const Size(44, 44),
    ),
    icon: Icon(icon),
  );

  @override
  Widget build(BuildContext context) {
    final video = widget.video;
    final prefs = Preferences.valueOf(context);
    final motion = !MediaQuery.disableAnimationsOf(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: ListenableBuilder(
        listenable: _c,
        builder: (context, _) {
          final showControls = _c.visible && !_c.locked;
          return LayoutBuilder(
            builder: (context, size) {
              final shallow = size.maxHeight < 420;
              return Stack(
                fit: StackFit.expand,
                children: [
                  if (video != null && video.value.isInitialized)
                    Center(
                      child: _fill
                          ? SizedBox.expand(
                              child: FittedBox(
                                fit: BoxFit.cover,
                                clipBehavior: Clip.hardEdge,
                                child: SizedBox(
                                  width: video.value.size.width,
                                  height: video.value.size.height,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      VideoPlayer(video),
                                      PgsOverlay(widget.pgsFrame),
                                      if (widget.styled case final script?)
                                        AssOverlay(
                                          script: script,
                                          lines: widget.styledLines,
                                          at: widget.position,
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            )
                          : SafeArea(
                              child: AspectRatio(
                                aspectRatio: video.value.aspectRatio,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    VideoPlayer(video),
                                    PgsOverlay(widget.pgsFrame),
                                    if (widget.styled case final script?)
                                      AssOverlay(
                                        script: script,
                                        lines: widget.styledLines,
                                        at: widget.position,
                                      ),
                                  ],
                                ),
                              ),
                            ),
                    ),
                  if (widget.caption case final text? when text.isNotEmpty)
                    Positioned(
                      left: 24,
                      right: 24,
                      bottom: showControls ? (shallow ? 92 : 120) : 28,
                      child: Center(
                        child: SubtitleText(
                          text,
                          appearance: prefs.subtitleAppearance,
                          baseSize: shallow ? 20 : 24,
                        ),
                      ),
                    ),
                  // Gesture surface below the controls.
                  Positioned.fill(
                    child: Semantics(
                      button: true,
                      label: 'Show playback controls',
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _c.locked ? _c.reveal : _c.toggle,
                        onDoubleTapDown: (d) => _doubleTap(d, size.maxWidth),
                        onDoubleTap: () {},
                      ),
                    ),
                  ),
                  if (_feedback case final seconds?)
                    Positioned(
                      left: seconds < 0 ? size.maxWidth * 0.12 : null,
                      right: seconds > 0 ? size.maxWidth * 0.12 : null,
                      top: size.maxHeight / 2 - 28,
                      child: IgnorePointer(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: const ShapeDecoration(
                            color: Color(0xA6000000),
                            shape: StadiumBorder(),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                seconds < 0
                                    ? Icons.replay_rounded
                                    : Icons.forward_rounded,
                                color: Colors.white,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '${seconds.abs()}s',
                                style: Zoro.font(17, weight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (_c.locked && _c.visible)
                    Positioned(
                      bottom: 24,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.black54,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () => _c.setLocked(false),
                          icon: const Icon(Icons.lock_open_rounded),
                          label: const Text('Unlock'),
                        ),
                      ),
                    ),
                  AnimatedOpacity(
                    opacity: showControls ? 1 : 0,
                    duration: motion
                        ? const Duration(milliseconds: 180)
                        : Duration.zero,
                    child: IgnorePointer(
                      ignoring: !showControls,
                      child: _controls(context, size, shallow),
                    ),
                  ),
                  if (widget.phase == PlayerPhase.preparing && !showControls)
                    const Center(child: CircularProgressIndicator()),
                  if (widget.error != null) _failure(),
                  ?widget.overlay,
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _failure() => ColoredBox(
    color: const Color(0xE6000000),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              size: 40,
              color: Zoro.muted,
            ),
            const SizedBox(height: 12),
            Text(
              'This video can’t play right now',
              style: Zoro.font(20, weight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              widget.error!,
              textAlign: TextAlign.center,
              style: Zoro.font(15, color: Zoro.muted),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 12,
              children: [
                if (widget.onRetry != null)
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Zoro.play,
                      foregroundColor: Zoro.background,
                    ),
                    onPressed: widget.onRetry,
                    child: const Text('Try again'),
                  ),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(foregroundColor: Zoro.text),
                  onPressed: widget.onClose,
                  child: const Text('Close'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  Widget _controls(BuildContext context, BoxConstraints size, bool shallow) {
    final phase = widget.phase;
    final playing =
        phase == PlayerPhase.playing || phase == PlayerPhase.buffering;
    final duration = widget.duration;
    final scrub = _c.scrub;
    final shown = scrub ?? widget.position;
    final busy =
        phase == PlayerPhase.preparing || phase == PlayerPhase.buffering;
    return Stack(
      fit: StackFit.expand,
      children: [
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0, .3, .55, 1],
                colors: [
                  Color(0xB8000000),
                  Colors.transparent,
                  Colors.transparent,
                  Color(0xE0000000),
                ],
              ),
            ),
          ),
        ),
        SafeArea(
          minimum: const EdgeInsets.all(12),
          child: Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _icon(
                    Icons.chevron_left_rounded,
                    'Close player',
                    widget.onClose,
                    size: 28,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            maxLines: shallow ? 1 : 2,
                            overflow: TextOverflow.ellipsis,
                            style: Zoro.font(17, weight: FontWeight.w600),
                          ),
                          if (widget.subtitle.isNotEmpty)
                            Text(
                              widget.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Zoro.font(13, color: Colors.white70),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (widget.onChannels != null)
                    _icon(
                      Icons.view_list_rounded,
                      'Channels and guide',
                      widget.onChannels,
                    ),
                  if (widget.onChapters != null)
                    _icon(
                      Icons.view_carousel_outlined,
                      'Chapters',
                      widget.onChapters,
                    ),
                  if (widget.onEpisodes != null)
                    _icon(
                      Icons.video_library_rounded,
                      'Seasons and episodes',
                      widget.onEpisodes,
                    ),
                  const SizedBox(width: 8),
                  _icon(
                    Icons.lock_outline_rounded,
                    'Lock controls',
                    () => _c.setLocked(true),
                  ),
                ],
              ),
              const Spacer(),
              if (widget.liveInfo != null) widget.liveInfo!,
              if (busy)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        phase == PlayerPhase.preparing
                            ? (widget.live
                                  ? 'Connecting to channel…'
                                  : 'Preparing video…')
                            : 'Buffering…',
                        style: Zoro.font(13),
                      ),
                    ],
                  ),
                ),
              if (widget.canSeek &&
                  duration != null &&
                  duration > Duration.zero)
                Row(
                  children: [
                    Text(
                      _clock(shown),
                      style: Zoro.font(13).copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    Expanded(
                      child: _seekExtras(
                        duration,
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 4,
                            activeTrackColor: Zoro.jade,
                            inactiveTrackColor: Colors.white24,
                            thumbColor: Colors.white,
                            overlayShape: SliderComponentShape.noOverlay,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 7,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Slider(
                              value: shown.inMilliseconds
                                  .clamp(0, duration.inMilliseconds)
                                  .toDouble(),
                              max: duration.inMilliseconds.toDouble(),
                              semanticFormatterCallback: (_) =>
                                  '${_clock(shown)} of ${_clock(duration)}',
                              onChangeStart: (_) {
                                widget.onScrubStart?.call();
                                _c.hold();
                                _c.scrub = widget.position;
                              },
                              onChanged: (v) => setState(
                                () => _c.scrub = Duration(
                                  milliseconds: v.round(),
                                ),
                              ),
                              onChangeEnd: (v) {
                                _c.scrub = null;
                                _c.release();
                                unawaited(
                                  widget.onSeek(
                                    Duration(milliseconds: v.round()),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                    Text(
                      widget.live
                          ? (widget.atLiveEdge
                                ? 'LIVE'
                                : '-${_clock(duration - shown)}')
                          : '-${_clock(duration - shown)}',
                      style: Zoro.font(13).copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              Row(
                children: [
                  if (widget.live)
                    _LiveStatus(
                      playing: playing,
                      atEdge: widget.atLiveEdge,
                      onGoLive: widget.onGoLive,
                    ),
                  const Spacer(),
                  if (widget.onOptions != null)
                    _icon(
                      Icons.subtitles_outlined,
                      'Audio, subtitles and quality',
                      widget.onOptions,
                    ),
                  const SizedBox(width: 8),
                  _icon(
                    _fill ? Icons.fit_screen_rounded : Icons.fullscreen_rounded,
                    _fill ? 'Fit to screen' : 'Fill screen',
                    () => setState(() => _fill = !_fill),
                  ),
                ],
              ),
            ],
          ),
        ),
        // Transport in the middle.
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.canSeek)
                _transport(
                  Icons.replay_10_rounded,
                  'Back ${widget.skipBack} seconds',
                  () => widget.onSkip(-widget.skipBack),
                ),
              const SizedBox(width: 28),
              _transport(
                phase == PlayerPhase.ended
                    ? Icons.replay_rounded
                    : playing
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                playing ? 'Pause' : 'Play',
                phase == PlayerPhase.preparing ? null : widget.onTogglePlay,
                size: 64,
              ),
              const SizedBox(width: 28),
              if (widget.canSeek)
                _transport(
                  Icons.forward_30_rounded,
                  'Forward ${widget.skipForward} seconds',
                  () => widget.onSkip(widget.skipForward),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _transport(
    IconData icon,
    String label,
    VoidCallback? onPressed, {
    double size = 44,
  }) => IconButton(
    tooltip: label,
    onPressed: onPressed,
    iconSize: size,
    color: Colors.white,
    disabledColor: Colors.white38,
    style: IconButton.styleFrom(backgroundColor: Colors.black38),
    icon: Icon(icon),
  );
}

class _Reconnecting extends StatelessWidget {
  const _Reconnecting();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
    decoration: BoxDecoration(
      color: Colors.black87,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
        const SizedBox(width: 12),
        Text('Reconnecting…', style: Zoro.font(16, color: Colors.white)),
      ],
    ),
  );
}

class _LiveStatus extends StatelessWidget {
  const _LiveStatus({
    required this.playing,
    required this.atEdge,
    required this.onGoLive,
  });

  final bool playing;
  final bool atEdge;
  final VoidCallback? onGoLive;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: atEdge ? null : onGoLive,
    style: TextButton.styleFrom(
      foregroundColor: Colors.white,
      disabledForegroundColor: Colors.white,
    ),
    icon: Icon(
      Icons.circle,
      size: 10,
      color: atEdge ? const Color(0xFFFF453A) : Colors.white54,
    ),
    label: Text(
      !playing ? 'Paused' : (atEdge ? 'Live' : 'Go live'),
      style: Zoro.font(14, weight: FontWeight.w600),
    ),
  );
}

class _LiveInfo extends StatelessWidget {
  const _LiveInfo({
    required this.now,
    required this.next,
    required this.channelId,
  });

  final LiveProgram? now;
  final LiveProgram? next;
  final String channelId;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (now?.hasSchedule == true)
            Text(
              'Now · ${clockLabel(now!.start!)} – ${clockLabel(now!.end!)}',
              style: Zoro.font(13, color: Colors.white70),
            ),
          if (next != null)
            Text(
              'Next · ${next!.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Zoro.font(13, color: Colors.white70),
            ),
          LiveTvNotice(channelId: channelId),
        ],
      ),
    ),
  );
}

class _UpNextCard extends StatelessWidget {
  const _UpNextCard({
    required this.item,
    required this.catalog,
    required this.countdown,
    required this.onPlay,
    required this.onCancel,
  });

  final MediaItem item;
  final Catalog catalog;
  final int? countdown;
  final VoidCallback onPlay;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Positioned(
    right: 24,
    bottom: 24,
    child: SafeArea(
      child: Container(
        width: 300,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xEB1B211E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Zoro.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              countdown == null ? 'Up next' : 'Up next in $countdown',
              style: Zoro.font(15, weight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              '${item.episodeLabel} · ${item.name}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Zoro.font(14, color: Zoro.muted),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Zoro.text,
                    foregroundColor: Zoro.background,
                  ),
                  onPressed: onPlay,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Play now'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: Zoro.text),
                  onPressed: onCancel,
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// Audio, subtitles, quality and speed (Apple player options).
class _OptionsSheet extends StatefulWidget {
  const _OptionsSheet({
    required this.onInfo,
    required this.streams,
    required this.options,
    required this.autoQuality,
    required this.speed,
    required this.live,
    required this.grouped,
    required this.onAutoQuality,
    required this.onSpeed,
    this.subtitleOffset = Duration.zero,
    this.onSubtitleOffset,
  });

  final Duration subtitleOffset;
  final ValueChanged<Duration>? onSubtitleOffset;
  final List<MediaStream> streams;
  final PlaybackOptions options;
  final bool autoQuality;
  final double speed;
  final bool live;
  final bool grouped;
  final ValueChanged<bool> onAutoQuality;
  final ValueChanged<double> onSpeed;

  /// Asks for Playback info once this sheet closes.
  final VoidCallback onInfo;

  @override
  State<_OptionsSheet> createState() => _OptionsSheetState();
}

class _OptionsSheetState extends State<_OptionsSheet> {
  late PlaybackOptions _next = widget.options;
  late bool _auto = widget.autoQuality;
  late double _speed = widget.speed;
  late Duration _offset = widget.subtitleOffset;

  void _shift(Duration next) {
    if (next.abs() > TrackMemory.maxOffset) return;
    setState(() => _offset = next);
    widget.onSubtitleOffset?.call(next);
  }

  Widget _timing() => ListTile(
    dense: true,
    title: Text('Subtitle timing', style: Zoro.font(15)),
    subtitle: Text(
      _offset == Duration.zero
          ? 'Shift subtitles earlier or later'
          : (_offset.isNegative ? 'Shown earlier' : 'Shown later'),
      style: Zoro.font(12, color: Zoro.muted),
    ),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Earlier',
          icon: const Icon(Icons.remove_rounded),
          onPressed: () => _shift(_offset - timingStep),
        ),
        GestureDetector(
          onTap: () => _shift(Duration.zero),
          child: SizedBox(
            width: 64,
            child: Text(
              timingLabel(_offset),
              textAlign: TextAlign.center,
              style: Zoro.font(
                14,
                weight: FontWeight.w600,
                color: _offset == Duration.zero ? Zoro.muted : Zoro.text,
              ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Later',
          icon: const Icon(Icons.add_rounded),
          onPressed: () => _shift(_offset + timingStep),
        ),
      ],
    ),
  );

  static String _title(MediaStream s) =>
      s.displayTitle ?? s.language ?? 'Track ${s.index}';

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
    child: Text(
      text,
      style: Zoro.font(15, weight: FontWeight.w700, color: Zoro.jade),
    ),
  );

  Widget _choice(String label, bool selected, VoidCallback onTap) => ListTile(
    dense: true,
    title: Text(label, style: Zoro.font(15)),
    trailing: selected ? Icon(Icons.check_rounded, color: Zoro.jade) : null,
    onTap: onTap,
  );

  @override
  Widget build(BuildContext context) {
    final audio = widget.streams.where((s) => s.type == 'Audio').toList();
    final subtitles = widget.streams
        .where((s) => s.type == 'Subtitle')
        .toList();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_next);
      },
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: .7,
        maxChildSize: .95,
        builder: (context, scroll) => ListView(
          controller: scroll,
          children: [
            Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text(
                      'Playback options',
                      style: Zoro.font(19, weight: FontWeight.w700),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(_next),
                  child: const Text('Done'),
                ),
              ],
            ),
            if (audio.isNotEmpty) ...[
              _heading('Audio'),
              for (final s in audio)
                _choice(
                  _title(s),
                  (_next.audioIndex ??
                          audio.where((a) => a.isDefault).firstOrNull?.index) ==
                      s.index,
                  () => setState(
                    () => _next = _next.copyWith(audioIndex: () => s.index),
                  ),
                ),
            ],
            _heading('Subtitles'),
            _choice(
              'Off',
              _next.subtitleIndex < 0,
              () => setState(
                () => _next = _next.copyWith(
                  subtitleIndex: -1,
                  burnSubtitles: false,
                ),
              ),
            ),
            for (final s in subtitles)
              _choice(
                _title(s),
                _next.subtitleIndex == s.index,
                () => setState(
                  () => _next = _next.copyWith(
                    subtitleIndex: s.index,
                    burnSubtitles: widget.options.burnsIn(s),
                  ),
                ),
              ),
            if (widget.onSubtitleOffset != null && _next.subtitleIndex >= 0)
              _timing(),
            _heading('Quality'),
            if (!widget.grouped)
              SwitchListTile(
                dense: true,
                title: Text('Auto', style: Zoro.font(15)),
                subtitle: Text(
                  'Lowers quality when your connection can’t keep up',
                  style: Zoro.font(12, color: Zoro.muted),
                ),
                value: _auto,
                onChanged: (v) {
                  setState(() => _auto = v);
                  widget.onAutoQuality(v);
                },
              ),
            for (final mbps in DevicePreferences.bitrates.reversed)
              _choice(
                mbps >= 120 ? 'Maximum (120 Mbps)' : '$mbps Mbps',
                _next.bitrate == mbps * 1000000,
                () => setState(
                  () => _next = _next.copyWith(bitrate: mbps * 1000000),
                ),
              ),
            if (!widget.live && !widget.grouped) ...[
              _heading('Speed'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final s in DevicePreferences.speeds)
                      ChoiceChip(
                        label: Text(s == 1 ? 'Normal' : '${s}x'),
                        selected: _speed == s,
                        selectedColor: Zoro.jade,
                        labelStyle: Zoro.font(
                          14,
                          weight: FontWeight.w600,
                          color: _speed == s ? Zoro.background : Zoro.text,
                        ),
                        onSelected: (_) {
                          setState(() => _speed = s);
                          widget.onSpeed(s);
                        },
                      ),
                  ],
                ),
              ),
            ],
            const Divider(height: 32),
            ListTile(
              key: const ValueKey('phone-playback-info'),
              leading: const Icon(Icons.info_outline_rounded),
              title: Text('Playback info', style: Zoro.font(15)),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () {
                widget.onInfo();
                Navigator.of(context).pop(_next);
              },
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

/// Chapters with their stills; the playing one is marked. Returns the pick.
class _ChaptersSheet extends StatelessWidget {
  const _ChaptersSheet({
    required this.chapters,
    required this.current,
    required this.image,
  });

  final List<Chapter> chapters;
  final int? current;
  final ImageProvider? Function(int index) image;

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: .6,
    maxChildSize: .95,
    builder: (context, scroll) => ListView.builder(
      controller: scroll,
      itemCount: chapters.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text(
              'Chapters',
              style: Zoro.font(19, weight: FontWeight.w700),
            ),
          );
        }
        final index = i - 1;
        final chapter = chapters[index];
        final still = image(index);
        final playing = index == current;
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Container(
              width: 96,
              height: 54,
              color: Colors.white10,
              alignment: Alignment.center,
              child: still == null
                  ? Text(
                      '${index + 1}',
                      style: Zoro.font(16, color: Zoro.muted),
                    )
                  : Image(
                      image: still,
                      width: 96,
                      height: 54,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox(),
                    ),
            ),
          ),
          title: Text(
            chapter.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Zoro.font(
              15,
              weight: playing ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
          subtitle: Text(
            playing
                ? 'Playing · ${timeLabel(chapter.start)}'
                : timeLabel(chapter.start),
            style: Zoro.font(12, color: playing ? Zoro.jade : Zoro.muted),
          ),
          onTap: () => Navigator.of(context).pop(chapter),
        );
      },
    ),
  );
}

/// Playback info: method, bitrates, reasons, quality mode and source file.
class _InformationSheet extends StatelessWidget {
  const _InformationSheet({
    required this.load,
    required this.initial,
    required this.source,
  });

  final Future<List<(String, String)>> load;
  final List<(String, String)> initial;
  final String source;

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: .6,
    maxChildSize: .95,
    builder: (context, scroll) => FutureBuilder<List<(String, String)>>(
      future: load,
      builder: (context, snapshot) {
        final facts = snapshot.data ?? initial;
        return ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Playback info',
                    style: Zoro.font(19, weight: FontWeight.w700),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Done'),
                ),
              ],
            ),
            for (final (title, value) in facts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Zoro.font(14, color: Zoro.muted)),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        value,
                        textAlign: TextAlign.end,
                        style: Zoro.font(14),
                      ),
                    ),
                  ],
                ),
              ),
            if (source.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                'Source file',
                style: Zoro.font(15, weight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(source, style: Zoro.font(14, color: Zoro.muted)),
              const SizedBox(height: 4),
              Text(
                'Source formats can differ from playback output.',
                style: Zoro.font(12, color: Zoro.muted),
              ),
            ],
          ],
        );
      },
    ),
  );
}

class _EpisodesSheet extends StatefulWidget {
  const _EpisodesSheet({
    required this.catalog,
    required this.seriesId,
    required this.seasonId,
    required this.currentId,
  });

  final Catalog catalog;
  final String seriesId;
  final String seasonId;
  final String currentId;

  @override
  State<_EpisodesSheet> createState() => _EpisodesSheetState();
}

class _EpisodesSheetState extends State<_EpisodesSheet> {
  List<MediaItem> _seasons = const [];
  late String _season = widget.seasonId;
  List<MediaItem>? _episodes;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSeasons());
    unawaited(_load());
  }

  Future<void> _loadSeasons() async {
    try {
      final s = await widget.catalog.seasons(widget.seriesId);
      if (mounted) setState(() => _seasons = s);
    } catch (_) {}
  }

  Future<void> _load() async {
    setState(() => _episodes = null);
    try {
      final e = await widget.catalog.episodes(widget.seriesId, _season);
      if (mounted) setState(() => _episodes = e);
    } catch (_) {
      if (mounted) setState(() => _episodes = const []);
    }
  }

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: .8,
    maxChildSize: .95,
    builder: (context, scroll) => Column(
      children: [
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final s in _seasons)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(s.name),
                    selected: s.id == _season,
                    selectedColor: Zoro.jade,
                    labelStyle: Zoro.font(
                      14,
                      weight: FontWeight.w600,
                      color: s.id == _season ? Zoro.background : Zoro.text,
                    ),
                    onSelected: (_) {
                      setState(() => _season = s.id);
                      unawaited(_load());
                    },
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: _episodes == null
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  controller: scroll,
                  itemCount: _episodes!.length,
                  itemBuilder: (context, i) {
                    final e = _episodes![i];
                    final current = e.id == widget.currentId;
                    return ListTile(
                      selected: current,
                      selectedColor: Zoro.jade,
                      leading: Text(
                        '${e.indexNumber ?? ''}',
                        style: Zoro.font(15, weight: FontWeight.w700),
                      ),
                      title: Text(e.name),
                      subtitle: Text(
                        current
                            ? 'Playing now'
                            : e.userData?.played == true
                            ? 'Watched'
                            : e.durationLabel,
                        style: Zoro.font(12, color: Zoro.muted),
                      ),
                      onTap: () => Navigator.of(context).pop(e),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}

class _ChannelsSheet extends StatefulWidget {
  const _ChannelsSheet({
    required this.catalog,
    required this.currentId,
    required this.now,
    required this.next,
  });

  final JellyfinCatalog catalog;
  final String currentId;
  final LiveProgram? now;
  final LiveProgram? next;

  @override
  State<_ChannelsSheet> createState() => _ChannelsSheetState();
}

class _ChannelsSheetState extends State<_ChannelsSheet> {
  List<MediaItem>? _channels;
  String _query = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final items = <MediaItem>[];
      var start = 0;
      for (var i = 0; i < 10; i++) {
        final page = await widget.catalog.client.channels(
          start: start,
          limit: 100,
        );
        items.addAll(page.items);
        start += page.items.length;
        if (page.items.isEmpty ||
            (page.totalRecordCount != null &&
                start >= page.totalRecordCount!)) {
          break;
        }
      }
      if (mounted) setState(() => _channels = items);
    } catch (_) {
      if (mounted) setState(() => _error = 'Channels couldn’t load.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = (_channels ?? const <MediaItem>[])
        .where(
          (c) => '${c.channelNumber ?? ''} ${c.name}'.toLowerCase().contains(
            _query.toLowerCase(),
          ),
        )
        .toList();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .85,
      maxChildSize: .95,
      builder: (context, scroll) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.now != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                'Now · ${widget.now!.name}',
                style: Zoro.font(16, weight: FontWeight.w600),
              ),
            ),
          if (widget.next != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Next · ${widget.next!.name}',
                style: Zoro.font(14, color: Zoro.muted),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Find a channel',
                prefixIcon: Icon(Icons.search_rounded),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: _error != null
                ? Center(child: Text(_error!))
                : _channels == null
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: scroll,
                    itemCount: visible.length,
                    itemBuilder: (context, i) {
                      final c = visible[i];
                      return ListTile(
                        selected: c.id == widget.currentId,
                        selectedColor: Zoro.jade,
                        leading: SizedBox(
                          width: 44,
                          child: Text(
                            c.channelNumber ?? '',
                            style: Zoro.font(14, color: Zoro.muted),
                          ),
                        ),
                        title: Text(c.name),
                        subtitle: c.currentProgram == null
                            ? null
                            : Text(
                                c.currentProgram!.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Zoro.font(12, color: Zoro.muted),
                              ),
                        onTap: () => Navigator.of(context).pop(c),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
