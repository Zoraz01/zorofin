import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../core/catalog.dart';
import '../../core/device_playback.dart';
import '../../core/adaptive_quality.dart';
import '../../core/errors.dart';
import '../../core/models.dart';
import '../../core/ass.dart';
import '../../core/pgs.dart';
import '../../core/playback.dart';
import '../../core/playback_capabilities.dart';
import '../../core/playback_recovery.dart';
import '../../core/playback_reports.dart';
import '../../extras_state.dart';
import '../../core/player_extras.dart';
import '../../core/preferences.dart';
import '../../core/server_extras.dart';
import '../../core/viewer_settings.dart';
import '../../watch_together.dart';
import '../player/player_controls.dart';
import '../player/in_app_player.dart';
import '../player/player_panels.dart';
import '../player/player_extras_ui.dart';
import '../theme.dart';
import '../widgets/focusable.dart';
import '../widgets/live_tv_notice.dart';
import '../widgets/ass_overlay.dart';
import '../widgets/pgs_overlay.dart';
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
    this.presentation,
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
  final PlayerPresentation? presentation;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> implements GroupPlayer {
  static const _reportEvery = Duration(seconds: 10);
  static const _hideAfter = Duration(seconds: 4);
  static const _upNextSeconds = 5;
  static const _samsungOpenTimeout = Duration(seconds: 20);
  static const _samsungCommandTimeout = Duration(seconds: 8);
  static const _samsungReleaseTimeout = Duration(seconds: 2);

  late MediaItem _item = widget.item;
  late PlaybackOptions _options;
  PlaybackDiagnostics? _diagnostics;
  AdaptiveQuality? _adaptive;
  Timer? _adaptiveTimer;
  bool _autoQuality = true;
  bool _adapting = false;
  late Preferences? _prefs;
  bool _started = false;
  bool _streamReady = false;

  VideoPlayerController? _video;
  VideoPlayerController? _pendingSamsungSeek;
  PlaybackPlan? _plan;
  PlayerPhase _phase = PlayerPhase.preparing;
  String? _error;

  /// Transcoded streams begin at the requested position, so the player's
  /// clock is offset from the title's timeline.
  Duration _offset = Duration.zero;
  Duration _lastGoodPosition = Duration.zero;

  /// Bumped on every stream change so late results of an older one are dropped.
  int _generation = 0;
  bool _closing = false;
  bool _endHandled = false;

  bool _controls = true;
  final _seasonMenu = MenuController();
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

  /// Positive: subtitles appear later than the file says.
  Duration _subtitleOffset = Duration.zero;

  /// Where subtitles are read from: the picture's time, shifted.
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
    } catch (_) {
      // Optional: the player works without chapters or thumbnails.
    }
  }

  void _remember({MediaStream? audio, MediaStream? subtitle, bool? off}) {
    final prefs = _prefs;
    if (prefs == null || _item.isLive) return;
    final next = (_memory ?? const TrackMemory()).choosing(
      audio: audio,
      subtitle: subtitle,
      off: off,
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
    final chapters = _extras.chapters;
    final index = Chapter.indexAt(chapters, at);
    return ScrubPreview(
      position: at,
      trickplay: _extras.trickplay,
      sheet: _extras.trickplay == null ? null : _trickplaySheet,
      chapter: index == null ? null : chapters[index].name,
    );
  }

  /// Watch together: a menu or scrub holds this device out of the group.
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
        position: _item.isLive ? null : _lastGoodPosition,
      );
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

  bool get _mini => widget.presentation?.minimized ?? false;

  @override
  void initState() {
    super.initState();
    final presentation = widget.presentation;
    presentation?.onBack = _back;
    presentation?.onStop = _close;
    presentation?.onExpanded = () {
      if (!mounted) return;
      _reveal(stay: true);
      _playFocus.requestFocus();
    };
    presentation?.addListener(_presentationChanged);
  }

  void _presentationChanged() {
    if (mounted) setState(() {});
  }

  void _minimize() {
    _hide?.cancel();
    setState(() => _controls = false);
    widget.presentation?.minimize();
  }

  final _playFocus = FocusNode(debugLabel: 'player-play');
  final _miniPlayFocus = FocusNode(debugLabel: 'mini-play');
  final _miniExpandFocus = FocusNode(debugLabel: 'mini-expand');
  final _miniCloseFocus = FocusNode(debugLabel: 'mini-close');

  /// The control that opened the options card, refocused when it closes.
  FocusNode? _panelOrigin;
  final _surfaceFocus = FocusNode(debugLabel: 'player-surface');

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
        platform: DevicePlayback.isSamsungTv ? 'Samsung TV' : 'Android TV',
        enabled: () =>
            (_serverExtras?.features.playbackReports ?? false) &&
            (_prefs?.value.sendPlaybackReports ?? true),
      ),
    );
    _options = PlaybackOptions(
      startTicks: widget.startTicks ?? widget.item.resumeTicks,
      bitrate: _prefs?.bitrate ?? 40000000,
      audioIndex: widget.audioIndex,
      subtitleIndex: widget.subtitleIndex,
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

  Future<T> _nativeOperation<T>(Future<T> operation, Duration timeout) =>
      DevicePlayback.isSamsungTv ? operation.timeout(timeout) : operation;

  /// How long a stream may take to open before the player gives up, so a
  /// stream the device can't start never sits on "Preparing video".
  static const _openTimeout = Duration(seconds: 45);

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
    if (item.id != _item.id) options = options.copyWith(allowDirectPlay: true);
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
      _lastGoodPosition = MediaTime.duration(options.startTicks);
      _error = null;
      _diagnostics = null;
      _endHandled = false;
      _upNext = null;
      _countdown = null;
    });
    _countdownTimer?.cancel();
    _guideTimer?.cancel();
    _problems?.opening();
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
        // The server's per-viewer defaults arrive with the first answer;
        // only a choice that needs a transcode asks again.
        final choice = (await _settings()).chooseTracks(
          plan.source,
          audioIndex: options.audioIndex,
        );
        // What the viewer picked earlier in this show wins over the account
        // defaults, where this episode has a track in that language.
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
      );
      _plan = plan;
      _video = video;
      // Ask for subtitles while the video opens: the server can take most of
      // a minute to pull a Blu-ray track out of a file it has not served yet,
      // and every second saved here is a line that still shows.
      unawaited(_loadCaptions(generation));
      await video.initialize().timeout(
        DevicePlayback.isSamsungTv ? _samsungOpenTimeout : _openTimeout,
      );
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
      // Jellyfin HLS VOD has the full title timeline. Adding the requested
      // resume point as an offset makes the clock advance over the opening
      // scene without seeking the actual media. Match AVPlayer's real seek.
      _offset = Duration.zero;
      if (!item.isLive && start > Duration.zero) {
        await _nativeOperation(video.seekTo(start), _samsungCommandTimeout);
      }
      if (!mounted || generation != _generation) return;
      _streamReady = true;
      video.addListener(_onVideo);
      final grouped = _group != null;
      if (grouped) resume = false;
      if (!item.isLive && _speed != 1 && !grouped) {
        await _nativeOperation(
          video.setPlaybackSpeed(_speed),
          _samsungCommandTimeout,
        );
      }
      if (_extras == PlayerExtras.none) {
        unawaited(_loadExtras(item, generation));
      }
      if (item.isEpisode && _group == null) {
        unawaited(_loadIntros(item.id, generation));
      }
      if (resume) await _nativeOperation(video.play(), _samsungCommandTimeout);
      if (!mounted || generation != _generation) return;
      if (DevicePlayback.isSamsungTv && video.value.hasError) {
        _playbackFailed(generation, resume: resume);
        return;
      }
      setState(
        () => _phase = resume ? PlayerPhase.playing : PlayerPhase.paused,
      );
      _reveal();
      _problems?.started(item, _reportMethod);
      unawaited(_report('start'));
      _reporter = Timer.periodic(_reportEvery, (_) => _report('progress'));
      if (grouped) unawaited(_group?.playerReady(this, item.id));
    } on ClientError catch (e) {
      _fail(generation, e.message);
    } on TimeoutException {
      _playbackFailed(generation, resume: resume, timedOut: true);
    } catch (_) {
      _playbackFailed(generation, resume: resume);
    }
  }

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
  Future<void> _reconnect(int generation, void Function() whenReachable) async {
    if (_checkingServer) return;
    _checkingServer = true;
    final at = MediaTime.ticks(_lastGoodPosition);
    final result = await _serverWait.wait(
      onAway: () {
        if (!mounted || _closing || generation != _generation) return;
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
    if (!mounted || _closing || generation != _generation) {
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

  void _playbackFailed(
    int generation, {
    required bool resume,
    bool timedOut = false,
    int? startTicks,
  }) {
    if (!mounted || _closing || generation != _generation) return;
    if (_streamReady && _group == null) {
      unawaited(
        _reconnect(
          generation,
          () => _streamFailed(
            generation,
            resume: resume,
            timedOut: timedOut,
            startTicks: startTicks,
          ),
        ),
      );
      return;
    }
    _streamFailed(
      generation,
      resume: resume,
      timedOut: timedOut,
      startTicks: startTicks,
    );
  }

  void _streamFailed(
    int generation, {
    required bool resume,
    bool timedOut = false,
    int? startTicks,
  }) {
    if (!mounted || _closing || generation != _generation) return;
    // Samsung retries a failed direct play. Other devices retry any stream
    // negotiated with their detected decoders, once, since the compatibility
    // profile it falls back to is no longer "detected".
    final retry = DevicePlayback.isSamsungTv
        ? _options.allowDirectPlay && _plan?.method == 'DirectPlay'
        : _options.capabilities.detected;
    if (retry && !_item.isLive && _group == null) {
      _problem(
        PlaybackProblem.fallback,
        reason: timedOut
            ? 'The player did not open the stream in time'
            : _video?.value.errorDescription ?? 'Player error',
      );
      // Retry only this item and use Jellyfin's compatible HLS stream. Keep
      // the chosen tracks and position. Live tuners and groups stay untouched.
      unawaited(
        _open(
          _item,
          _options.copyWith(
            allowDirectPlay: false,
            capabilities: const PlaybackCapabilities(),
            startTicks: startTicks ?? MediaTime.ticks(_lastGoodPosition),
          ),
          resume: resume,
        ),
      );
      return;
    }
    _fail(
      generation,
      timedOut
          ? 'The TV player did not respond. Try again or close playback.'
          : const ClientError(ClientErrorKind.playbackFailed).message,
    );
  }

  /// Fetches the chosen text subtitle as WebVTT, or a Blu-ray (PGS) track to
  /// draw on the device. Burned-in subtitles are part of the video.
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
    } catch (_) {
      // Playback continues without subtitles.
    }
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
    final position = _streamReady
        ? video.value.hasError
              ? _lastGoodPosition
              : video.value.position + _offset
        : MediaTime.duration(_plan?.options.startTicks ?? 0);
    final plan = _plan;
    _plan = null;
    try {
      await _nativeOperation(video.pause(), _samsungReleaseTimeout);
    } catch (_) {}
    final report = plan == null
        ? Future<void>.value()
        : _report('stop', video: video, position: position, stream: plan);
    if (DevicePlayback.isSamsungTv) {
      // A slow Jellyfin response or native dispose must not trap Back on
      // the player. Finish server cleanup with the old session's own plan.
      if (plan != null) {
        final client = widget.catalog.client;
        unawaited(report.then((_) => client.stopEncoding(plan)));
      }
      try {
        await video.dispose().timeout(_samsungReleaseTimeout);
      } catch (_) {}
      return;
    }
    await report;
    await video.dispose();
    if (plan != null) await widget.catalog.client.stopEncoding(plan);
  }

  Future<void> _report(
    String event, {
    VideoPlayerController? video,
    Duration? position,
    PlaybackPlan? stream,
  }) async {
    final plan = stream ?? _plan;
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
      // The open operation handles errors that arrive before play completes.
      if (!DevicePlayback.isSamsungTv ||
          _phase != PlayerPhase.preparing &&
              _phase != PlayerPhase.failed &&
              !identical(_pendingSamsungSeek, video)) {
        _playbackFailed(
          _generation,
          resume:
              _phase == PlayerPhase.playing || _phase == PlayerPhase.buffering,
        );
      }
      return;
    }
    _lastGoodPosition = _position;
    final PlayerPhase phase;
    // The plugin also marks a polled position at its reported duration as
    // completed. Live streams can report zero or a stale window duration while
    // the native decoder is still playing. Only a stopped, finite stream has
    // reached its end. A live buffer is not a finite title: pausing at its
    // reported edge must stay resumable, even when its duration is nonzero.
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
    if (phase == PlayerPhase.playing &&
        previous != PlayerPhase.playing &&
        _controls &&
        _hide?.isActive != true) {
      _reveal();
    }
    if (phase != previous) {
      _stall?.cancel();
      if (phase == PlayerPhase.buffering && _scrub == null && _group == null) {
        // Some players sit buffering forever on a lost connection instead of
        // reporting an error.
        final generation = _generation;
        _stall = Timer(const Duration(seconds: 20), () {
          if (_phase != PlayerPhase.buffering || generation != _generation) {
            return;
          }
          unawaited(_reconnect(generation, () {}));
        });
      }
    }
    if (phase != previous && !_item.isLive) {
      _problems?.buffering(
        phase == PlayerPhase.buffering && _scrub == null,
        _item,
        _reportMethod,
        () => _position,
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
    if (!mounted || _mini) return;
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
      if (DevicePlayback.isSamsungTv && identical(_pendingSamsungSeek, video)) {
        return;
      }
      final generation = _generation;
      if (DevicePlayback.isSamsungTv) _pendingSamsungSeek = video;
      try {
        await _nativeOperation(video.seekTo(target), _samsungCommandTimeout);
        if (!mounted || generation != _generation) return;
        if (resume) {
          await _nativeOperation(video.play(), _samsungCommandTimeout);
        }
        if (!mounted || generation != _generation) return;
        if (DevicePlayback.isSamsungTv && video.value.hasError) {
          _playbackFailed(
            generation,
            resume: resume,
            startTicks: MediaTime.ticks(target),
          );
          return;
        }
        _endHandled = false;
        unawaited(_report('progress'));
      } catch (error) {
        if (!DevicePlayback.isSamsungTv) rethrow;
        _playbackFailed(
          generation,
          resume: resume,
          timedOut: error is TimeoutException,
          startTicks: MediaTime.ticks(target),
        );
      } finally {
        if (identical(_pendingSamsungSeek, video)) _pendingSamsungSeek = null;
      }
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
    if (panel == PlayerPanel.information) unawaited(_loadPlaybackDiagnostics());
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
      paused: !value.isPlaying || _panel != null,
      seeking: _scrub != null,
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

  Future<void> _loadPlaybackDiagnostics() async {
    final plan = _plan;
    final generation = _generation;
    if (plan == null) return;
    final info = await widget.catalog.client.playbackDiagnostics(plan);
    if (mounted && generation == _generation && identical(plan, _plan)) {
      setState(() => _diagnostics = info);
    }
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
    if (_seasonMenu.isOpen) {
      _seasonMenu.close();
    } else if (_mini) {
      widget.presentation?.expand();
    } else if (_panel != null) {
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

  Future<void>? _closeOperation;
  Future<void> _close() => _closeOperation ??= _performClose();

  Future<void> _performClose() async {
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
    if (mounted) {
      if (widget.presentation != null) {
        widget.presentation!.closed();
      } else {
        Navigator.of(context).pop();
      }
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent ||
        _panel != null ||
        _upNext != null ||
        _error != null) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.mediaStop) {
      unawaited(_close());
      return KeyEventResult.handled;
    }
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
    if (_mini) {
      // Keep horizontal movement stable when Play changes to Pause or the
      // library and player belong to different traversal groups. At the
      // edges, normal directional traversal returns to the library.
      if (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight) {
        final controls = [_miniPlayFocus, _miniExpandFocus, _miniCloseFocus];
        final index = controls.indexWhere((focus) => focus.hasFocus);
        final target = index + (key == LogicalKeyboardKey.arrowRight ? 1 : -1);
        if (index >= 0 && target >= 0 && target < controls.length) {
          controls[target].requestFocus();
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
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
    _adaptiveTimer?.cancel();
    _stall?.cancel();
    _serverWait.cancel();
    _problems?.dispose();
    widget.presentation?.removeListener(_presentationChanged);
    widget.presentation?.onBack = null;
    widget.presentation?.onStop = null;
    widget.presentation?.onExpanded = null;
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
    _miniPlayFocus.dispose();
    _miniExpandFocus.dispose();
    _miniCloseFocus.dispose();
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
    final plan = _plan;
    final size = _video?.value.size;
    return [
      ...?(_diagnostics ??
              (plan == null ? null : PlaybackDiagnostics.fromPlan(plan)))
          ?.facts,
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
              ? 'Blu-ray, drawn on this TV'
              : _ass != null
              ? 'Styled, drawn on this TV'
              : _pgsStatus ?? 'Text',
        ),
      if (size != null && size.width > 0 && size.height > 0)
        (
          'Playing resolution',
          '${size.width.round()} × ${size.height.round()}',
        ),
    ];
  }

  String get _sourceSummary =>
      playbackSourceSummary(_plan?.streams ?? const <MediaStream>[]);

  Widget _panelSurface(PlayerPanel panel) {
    final options = _queued ?? _options;
    final pending = _queued != null && !_queued!.sameStream(_options);
    return switch (panel) {
      PlayerPanel.channels => PlayerOptionsSurface(
        title: 'Channels & guide',
        liveSchedule: true,
        focusClose: true,
        wide: true,
        onClose: _closePanel,
        child: ChannelChoices(
          currentId: _item.id,
          channels: _channels,
          error: _channelError,
          now: _liveNow,
          next: _liveNext,
          upcoming:
              _guideAt != null &&
                  DateTime.now().difference(_guideAt!) <
                      const Duration(minutes: 2)
              ? _guide
                    .where(
                      (p) =>
                          p.start != null &&
                          p.end != null &&
                          p.start!.isAfter(DateTime.now()),
                    )
                    .take(4)
                    .toList()
              : const [],
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
          seasonMenuController: _seasonMenu,
          onOpen: _chooseEpisode,
        ),
      ),
      PlayerPanel.quality => PlayerOptionsSurface(
        title: 'Quality',
        onClose: _closePanel,
        footer: pending ? const PendingChangeNote() : null,
        child: QualityChoices(
          selected: options.bitrate,
          automatic: _autoQuality,
          ceiling: _adaptive?.ceiling ?? options.bitrate,
          onAuto: () {
            setState(() => _autoQuality = true);
            _queue(
              options.copyWith(bitrate: _adaptive?.ceiling ?? options.bitrate),
            );
          },
          isLive: _item.isLive,
          onSelect: (bitrate) {
            setState(() => _autoQuality = false);
            _queue(options.copyWith(bitrate: bitrate));
          },
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
          subtitleOffset: _subtitleOffset,
          onSubtitleOffset: _item.isLive ? null : _setSubtitleOffset,
          onAudio: (index) {
            _remember(
              audio: (_plan?.streams ?? const <MediaStream>[])
                  .where((s) => s.type == 'Audio' && s.index == index)
                  .firstOrNull,
            );
            _queue(options.copyWith(audioIndex: () => index));
          },
          onSubtitles: (index) {
            final stream = (_plan?.streams ?? const <MediaStream>[])
                .where((s) => s.type == 'Subtitle' && s.index == index)
                .firstOrNull;
            _remember(subtitle: stream, off: index == -1);
            _queue(
              options.copyWith(
                subtitleIndex: index,
                burnSubtitles: _plan?.burnsIn(stream) ?? false,
              ),
            );
          },
        ),
      ),
      PlayerPanel.chapters => PlayerOptionsSurface(
        title: 'Chapters',
        fullWidth: true,
        onClose: _closePanel,
        child: ChapterChoices(
          chapters: _extras.chapters,
          current: Chapter.indexAt(_extras.chapters, _position),
          image: _chapterImage,
          onSelect: (chapter) {
            _resumeAfterPanel = true;
            _closePanel();
            unawaited(_seekTo(chapter.start, resume: true));
          },
        ),
      ),
      PlayerPanel.information => PlayerOptionsSurface(
        title: 'Playback info',
        focusClose: true,
        onClose: _closePanel,
        child: PlaybackInformation(facts: _facts, source: _sourceSummary),
      ),
    };
  }

  Widget _miniPlayer() {
    final video = _video;
    return Actions(
      actions: {
        BackIntent: CallbackAction<BackIntent>(
          onInvoke: (_) => widget.presentation?.expand(),
        ),
      },
      child: Focus(
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: Material(
          color: Zoro.background,
          elevation: 16,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (video != null && video.value.isInitialized)
                      Center(
                        child: AspectRatio(
                          aspectRatio: video.value.aspectRatio,
                          child: VideoPlayer(video),
                        ),
                      ),
                    if (_caption case final caption? when caption.isNotEmpty)
                      Positioned(
                        left: 16,
                        right: 16,
                        bottom: 12,
                        child: Text(
                          caption,
                          maxLines: 3,
                          textAlign: TextAlign.center,
                          style: Zoro.font(
                            17,
                            color: Colors.white,
                          ).copyWith(backgroundColor: Colors.black87),
                        ),
                      ),
                    if (_phase == PlayerPhase.preparing ||
                        _phase == PlayerPhase.buffering)
                      const Center(child: CircularProgressIndicator()),
                    if (_reconnecting)
                      Align(
                        alignment: const Alignment(0, 0.22),
                        child: Text('Reconnecting…', style: Zoro.font(20)),
                      ),
                    if (_error != null ||
                        _upNext != null ||
                        _phase == PlayerPhase.ended)
                      Center(
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          color: Colors.black87,
                          child: Text(
                            _error != null
                                ? 'Unable to play'
                                : _upNext != null
                                ? 'Up next'
                                : 'Playback ended',
                            style: Zoro.font(22),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    PlayerIconButton(
                      focusNode: _miniPlayFocus,
                      icon: _playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      label: _playing ? 'Pause' : 'Play',
                      onPressed: _togglePlay,
                      enabled:
                          _phase == PlayerPhase.playing ||
                          _phase == PlayerPhase.paused ||
                          _phase == PlayerPhase.buffering,
                    ),
                    Expanded(
                      child: Text(
                        _title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Zoro.font(18),
                      ),
                    ),
                    PlayerIconButton(
                      icon: Icons.fullscreen_rounded,
                      label: 'Expand player',
                      focusNode: _miniExpandFocus,
                      onPressed: () => widget.presentation?.expand(),
                    ),
                    PlayerIconButton(
                      icon: Icons.close_rounded,
                      label: 'Close mini-player',
                      focusNode: _miniCloseFocus,
                      onPressed: () => unawaited(_close()),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final video = _video;
    final streams = _plan?.streams ?? const <MediaStream>[];
    final upNext = _upNext;
    final introEnd =
        _group == null && _error == null && _panel == null && _streamReady
        ? introEndAt(_intros, _position, _duration)
        : null;
    if (_mini) return _miniPlayer();
    return Actions(
      actions: {
        BackIntent: CallbackAction<BackIntent>(onInvoke: (_) => _back()),
      },
      child: PopScope(
        canPop: widget.presentation != null || _closing,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && widget.presentation == null) _back();
        },
        child: Focus(
          onKeyEvent: _onKey,
          child: Scaffold(
            // Android renders video in a Flutter texture, so letterbox margins
            // must cover the library. Native webOS needs its video plane below.
            backgroundColor: defaultTargetPlatform == TargetPlatform.android
                ? Colors.black
                : Colors.transparent,
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
                if (video != null && video.value.isInitialized && _pgs != null)
                  Center(
                    child: AspectRatio(
                      aspectRatio: video.value.aspectRatio,
                      child: PgsOverlay(_pgs!.frameAt(_subtitleClock)),
                    ),
                  ),
                if (video != null && video.value.isInitialized && _ass != null)
                  Center(
                    child: AspectRatio(
                      aspectRatio: video.value.aspectRatio,
                      child: AssOverlay(
                        script: _ass!,
                        lines: _ass!.activeAt(_subtitleClock),
                        at: _position,
                      ),
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
                if (_reconnecting)
                  Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 26,
                        vertical: 16,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text('Reconnecting…', style: Zoro.font(24)),
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
                        hasChapters: _extras.chapters.isNotEmpty,
                        marks: [for (final c in _extras.chapters) c.start],
                        preview: _item.isLive ? null : _scrubPreview,
                        playFocus: _playFocus,
                        onClose: () => unawaited(_close()),
                        onMinimize: widget.presentation == null
                            ? null
                            : _minimize,
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
                if (introEnd != null && upNext == null)
                  Positioned(
                    right: 48,
                    bottom: 160,
                    child: ZoroButton(
                      label: 'Skip intro',
                      onPressed: () => _seekTo(introEnd, resume: _playing),
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
                          Icon(
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
