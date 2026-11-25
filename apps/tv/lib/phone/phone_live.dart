import 'dart:async';
import 'package:flutter/material.dart';
import '../core/catalog.dart';
import '../core/errors.dart';
import '../extras_state.dart';
import '../ui/screens/home_screen.dart' show LiveEventsShelf;
import '../ui/widgets/focusable.dart';
import '../ui/widgets/home_rail_focus.dart';
import '../ui/widgets/section_title.dart';
import '../core/home.dart';
import '../core/live_scores.dart';
import '../core/models.dart';
import '../ui/theme.dart';
import '../ui/widgets/live_tv_notice.dart';
import '../core/preferences.dart';
import '../ui/player/player_panels.dart' show clockLabel;
import 'phone_guide.dart';
import 'phone_scope.dart';
import 'phone_theme.dart';
import 'phone_widgets.dart';

/// Browse live programs first; the guide retains its filters while hidden.
class PhoneLiveScreen extends StatelessWidget {
  const PhoneLiveScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = PhoneScope.of(context);
    return LiveBrowseScreen(
      catalog: scope.catalog,
      extras: scope.extras,
      onOpen: scope.open,
      onPlay: (channel) => scope.play(channel),
      onBack: () => scope.select(PhoneDestination.home),
    );
  }
}

/// The Programs data and card behavior are shared by the touch and TV shells.
class LiveBrowseScreen extends StatefulWidget {
  const LiveBrowseScreen({
    super.key,
    required this.catalog,
    required this.extras,
    required this.onOpen,
    required this.onPlay,
    this.onBack,
    this.tvGuideBuilder,
  });

  final Catalog catalog;
  final ExtrasState extras;
  final ValueChanged<MediaItem> onOpen;
  final ValueChanged<MediaItem> onPlay;
  final VoidCallback? onBack;
  final Widget Function(bool active)? tvGuideBuilder;

  bool get remote => tvGuideBuilder != null;

  @override
  State<LiveBrowseScreen> createState() => _LiveBrowseScreenState();
}

class _LiveBrowseScreenState extends State<LiveBrowseScreen>
    with WidgetsBindingObserver {
  Catalog? _catalog;
  LiveTvSnapshot? _snapshot;
  List<LiveEvent> _events = const [];
  bool _hasSportsFeed = false;
  final _scores = LiveScoresCache();
  bool _guide = false, _visitedGuide = false, _loading = false;
  bool _foreground = true;
  int _request = 0;
  String? _error;
  Timer? _timer, _clock;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _resetCatalog();
  }

  @override
  void didUpdateWidget(LiveBrowseScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.catalog, widget.catalog)) _resetCatalog();
  }

  void _resetCatalog() {
    _request++;
    _catalog = widget.catalog;
    _snapshot = null;
    _events = const [];
    _hasSportsFeed = false;
    _error = null;
    _loading = false;
    _schedule();
    unawaited(_load());
  }

  void _schedule() {
    _timer?.cancel();
    _clock?.cancel();
    if (_foreground && !_guide) {
      _timer = Timer.periodic(const Duration(seconds: 60), (_) => _load());
      _clock = Timer.periodic(const Duration(seconds: 15), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _request++;
      _loading = false;
    }
    _schedule();
    if (_foreground) unawaited(_load());
  }

  void _select(bool guide) {
    if (_guide == guide) return;
    setState(() {
      _guide = guide;
      _visitedGuide |= guide;
    });
    _schedule();
    if (!guide) unawaited(_load());
  }

  Future<void> _load() async {
    if (!_foreground || _guide || _loading) return;
    final catalog = _catalog;
    if (catalog == null) return;
    final request = ++_request;
    bool current() =>
        mounted && request == _request && identical(catalog, _catalog);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = catalog.client;
      final snapshot = client == null
          ? LiveTvSnapshot(
              (await catalog.browse(LibraryKind.live)).items,
              DateTime.now(),
            )
          : await client.liveTvSnapshot();
      if (!current()) return;
      final cachedFeed = client != null && widget.extras.features.sportsEvents
          ? _scores.feedFor(client)
          : null;
      setState(() {
        _snapshot = snapshot;
        _hasSportsFeed = cachedFeed != null;
        _events = LiveScores.fromSnapshot(snapshot, cachedFeed, DateTime.now());
      });
      if (client != null) {
        // Scores, ordering and spoilers use the same feed as Home and TV.
        final feed = widget.extras.features.sportsEvents
            ? await _scores.load(client)
            : null;
        if (!current()) return;
        // Optional artwork failure must not discard a valid guide/scores feed.
        final artwork = widget.extras.features.liveArtwork
            ? await client
                  .liveArtworkManifest()
                  .then<LiveArtworkManifest?>((value) => value)
                  .catchError((_) => null)
            : null;
        if (!current()) return;
        setState(() {
          _hasSportsFeed = feed != null;
          _events = LiveScores.fromSnapshot(
            snapshot,
            feed,
            DateTime.now(),
            artwork: artwork,
          );
        });
      }
    } catch (e) {
      if (!current()) return;
      setState(() {
        _error = 'Live programs could not be refreshed.';
        if (e is ClientError &&
            (e.kind == ClientErrorKind.unauthorized ||
                e.kind == ClientErrorKind.forbidden)) {
          _snapshot = null;
          _events = const [];
        }
      });
    } finally {
      if (current()) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _request++;
    _timer?.cancel();
    _clock?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remote = widget.remote;
    final gutter = remote ? Zoro.gutter : Phone.gutter;
    final now = DateTime.now();
    final fresh = _snapshot?.isFresh(now) == true;
    final channels = fresh ? _snapshot!.channels : const <MediaItem>[];
    final events = fresh
        ? _events.where((e) => e.isCurrent(now)).toList()
        : <LiveEvent>[];
    final sports = events.isEmpty && !_hasSportsFeed
        ? channels.where(LiveProgramListing.isSports).toList()
        : <MediaItem>[];
    void open(MediaItem channel, {bool requireCurrent = false}) {
      final at = DateTime.now();
      if (_snapshot?.isFresh(at) == true &&
          (!requireCurrent || LiveProgramListing.isCurrent(channel, at))) {
        widget.onOpen(channel);
      }
    }

    Widget guideAction() => remote
        ? ZoroButton(
            label: 'All channels · Guide',
            onPressed: () => _select(true),
          )
        : PillButton(
            label: 'All channels · Guide',
            icon: Icons.grid_view_rounded,
            onPressed: () => _select(true),
          );
    final browse = RefreshIndicator(
      onRefresh: _load,
      color: Zoro.jade,
      child: HomeRailScope(
        child: ListView(
          key: const PageStorageKey('live-programs-scroll'),
          padding: EdgeInsets.only(bottom: remote ? 24 : 120),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            if (_error != null)
              Padding(
                padding: EdgeInsets.all(gutter),
                child: remote
                    ? StatusMessage(
                        title: _error!,
                        detail: '',
                        action: ZoroButton(
                          label: 'Try again',
                          onPressed: _load,
                        ),
                      )
                    : PhoneStatus(
                        title: _error!,
                        action: PillButton(
                          label: 'Try again',
                          onPressed: _load,
                        ),
                      ),
              ),
            if (!_guide && _foreground)
              Padding(
                padding: EdgeInsets.all(gutter),
                child: LiveTvNotice(onJoin: widget.onPlay),
              ),
            if (events.isNotEmpty)
              if (remote)
                LiveEventsShelf(
                  events: events,
                  catalog: widget.catalog,
                  now: now,
                  onAllChannels: () => _select(true),
                  onOpen: (e) {
                    if (e.isCurrent(DateTime.now())) open(e.channel);
                  },
                )
              else
                PhoneLiveEventsShelf(
                  events: events,
                  catalog: widget.catalog,
                  now: now,
                  onAllChannels: () => _select(true),
                  onOpen: (e) {
                    if (e.isCurrent(DateTime.now())) open(e.channel);
                  },
                ),
            if (sports.isNotEmpty)
              _ProgramShelf(
                title: 'Sports & live events',
                channels: sports,
                catalog: widget.catalog,
                remote: remote,
                now: now,
                onGuide: () => _select(true),
                onOpen: open,
              ),
            // Owner rule (Nov 24): no "On now" row in any app. Programs shows
            // Sports & live events; the Guide has every channel.
            if (events.isEmpty && sports.isEmpty && !_loading && _error == null)
              Padding(
                padding: EdgeInsets.all(gutter),
                child: Text(
                  'No sports or live events right now',
                  style: Zoro.font(remote ? 24 : 16, color: Zoro.muted),
                ),
              ),
            Padding(
              padding: EdgeInsets.all(gutter),
              child: Align(
                alignment: Alignment.centerLeft,
                child: guideAction(),
              ),
            ),
          ],
        ),
      ),
    );
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(gutter, remote ? 12 : 0, gutter, 0),
          child: Row(
            children: [
              if (widget.onBack != null)
                IconButton(
                  tooltip: 'Back to Home',
                  icon: const Icon(Icons.chevron_left_rounded),
                  onPressed: widget.onBack,
                ),
              Text(
                'Live TV',
                style: Zoro.font(remote ? 34 : 28, weight: FontWeight.w700),
              ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 12),
          child: remote
              ? Row(
                  children: [
                    ZoroButton(
                      label: 'Programs',
                      primary: !_guide,
                      autofocus: true,
                      onPressed: () => _select(false),
                    ),
                    const SizedBox(width: 16),
                    ZoroButton(
                      label: 'Guide',
                      primary: _guide,
                      onPressed: () => _select(true),
                    ),
                  ],
                )
              : SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                      value: false,
                      label: Text('Programs'),
                      icon: Icon(Icons.live_tv_rounded),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text('Guide'),
                      icon: Icon(Icons.grid_view_rounded),
                    ),
                  ],
                  selected: {_guide},
                  onSelectionChanged: (value) => _select(value.first),
                ),
        ),
        Expanded(
          child: IndexedStack(
            index: _guide ? 1 : 0,
            children: [
              ExcludeFocus(excluding: _guide, child: browse),
              ExcludeFocus(
                excluding: !_guide,
                child: !_visitedGuide
                    ? const SizedBox.shrink()
                    : widget.tvGuideBuilder?.call(_guide && _foreground) ??
                          PhoneGuideScreen(
                            active: _guide && _foreground,
                            embedded: true,
                          ),
              ),
            ],
          ),
        ),
      ],
    );
    return remote
        ? content
        : Scaffold(
            backgroundColor: Zoro.background,
            body: SafeArea(bottom: false, child: content),
          );
  }
}

class _ProgramShelf extends StatelessWidget {
  const _ProgramShelf({
    required this.title,
    required this.channels,
    required this.catalog,
    required this.remote,
    required this.now,
    required this.onGuide,
    required this.onOpen,
  });
  final String title;
  final List<MediaItem> channels;
  final Catalog catalog;
  final bool remote;
  final DateTime now;
  final VoidCallback onGuide;
  final ValueChanged<MediaItem> onOpen;
  @override
  Widget build(BuildContext context) {
    final gutter = remote ? Zoro.gutter : Phone.gutter;
    final width =
        (remote ? 360.0 : PhoneWindow.of(context).landscapeWidth) *
        Preferences.valueOf(context).posterScale;
    final text = MediaQuery.textScalerOf(context);
    final caption = _ProgramCaption(remote);
    final height = width * 9 / 16 + caption.height(text) + (remote ? 24 : 0);
    return HomeRailFocus(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (remote)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: gutter),
              child: SectionTitle(title),
            )
          else
            SectionHeader(
              title,
              trailing: IconButton(
                tooltip: 'Open Guide',
                onPressed: onGuide,
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ),
          const SizedBox(height: 10),
          SizedBox(
            height: height,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(
                horizontal: gutter,
                vertical: remote ? 12 : 0,
              ),
              itemCount: channels.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (context, i) => _ProgramCard(
                key: ValueKey(channels[i].id),
                channel: channels[i],
                catalog: catalog,
                remote: remote,
                width: width,
                now: now,
                onPressed: () => onOpen(channels[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgramCaption {
  const _ProgramCaption(this.remote);
  final bool remote;
  static const lineHeight = 1.3;

  double get titleSize => remote ? 22 : 17;
  double get channelSize => remote ? 18 : 14;
  double get scheduleSize => remote ? 17 : 13;

  double height(TextScaler text) =>
      (text.scale(titleSize) * 2 +
              text.scale(channelSize) +
              text.scale(scheduleSize) * 2) *
          lineHeight +
      34;
}

class _ProgramCard extends StatelessWidget {
  const _ProgramCard({
    super.key,
    required this.channel,
    required this.catalog,
    required this.remote,
    required this.width,
    required this.now,
    required this.onPressed,
  });
  final MediaItem channel;
  final Catalog catalog;
  final double width;
  final bool remote;
  final DateTime now;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    final p = channel.currentProgram;
    final name = p?.name.trim() ?? '';
    final title = name.isEmpty ? channel.name : name;
    final live = LiveProgramListing.isLive(channel, now);
    final channelLine =
        title.trim().toLowerCase() == channel.name.trim().toLowerCase()
        ? (channel.channelNumber == null
              ? 'Channel'
              : 'Ch ${channel.channelNumber}')
        : channel.name +
              (channel.channelNumber == null
                  ? ''
                  : ' · Ch ${channel.channelNumber}');
    final timed = p?.hasSchedule == true;
    final start = timed ? p!.start! : null, end = timed ? p!.end! : null;
    String date(DateTime d) => '${d.month}/${d.day}';
    final time = start == null || end == null
        ? 'Open channel'
        : '${date(start)} · ${clockLabel(start)} – ${date(start) == date(end) ? '' : '${date(end)} · '}${clockLabel(end)}';
    final progress = start == null || end == null
        ? null
        : (now.difference(start).inMilliseconds /
                  end.difference(start).inMilliseconds)
              .clamp(0.0, 1.0)
              .toDouble();
    final label =
        '$title, $channelLine, $time${live ? ', live broadcast' : ''}. Open channel.';
    final caption = _ProgramCaption(remote);
    final card = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _ProgramArtwork(channel: channel, catalog: catalog),
                if (live)
                  Positioned(
                    top: 9,
                    left: 9,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(30),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.circle,
                            color: Colors.redAccent,
                            size: 7,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            'LIVE',
                            style: Zoro.font(12, weight: FontWeight.w700),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 9),
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Zoro.font(
            caption.titleSize,
            weight: FontWeight.w600,
          ).copyWith(height: _ProgramCaption.lineHeight),
        ),
        const SizedBox(height: 5),
        Text(
          channelLine,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Zoro.font(
            caption.channelSize,
            color: Zoro.muted,
          ).copyWith(height: _ProgramCaption.lineHeight),
        ),
        const SizedBox(height: 4),
        Text(
          time,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Zoro.font(
            caption.scheduleSize,
            color: Zoro.muted,
          ).copyWith(height: _ProgramCaption.lineHeight),
        ),
        if (progress != null)
          Padding(
            padding: const EdgeInsets.only(top: 9),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 3,
              color: Zoro.jade,
              backgroundColor: Zoro.border,
            ),
          ),
      ],
    );
    return SizedBox(
      width: width,
      child: remote
          ? Focusable(
              semanticLabel: label,
              onPressed: onPressed,
              builder: (context, focused) => DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: focused
                      ? Border.all(color: Zoro.text, width: 3)
                      : null,
                ),
                child: card,
              ),
            )
          : Semantics(
              button: true,
              label: label,
              excludeSemantics: true,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: onPressed,
                  child: card,
                ),
              ),
            ),
    );
  }
}

class _ProgramArtwork extends StatelessWidget {
  const _ProgramArtwork({required this.channel, required this.catalog});
  final MediaItem channel;
  final Catalog catalog;
  @override
  Widget build(BuildContext context) {
    final client = catalog.client,
        sources = LiveProgramListing.artwork(channel);
    final fallback = ColoredBox(
      color: Zoro.panel,
      child: Center(
        child: Icon(Icons.live_tv_rounded, color: Zoro.muted, size: 40),
      ),
    );
    Widget attempt(int index) {
      if (client == null || index >= sources.length) return fallback;
      final source = sources[index];
      final uri = client.image(
        source.itemId,
        kind: source.kind,
        tag: source.tag,
        width: 720,
      );
      return _GuideArt(
        key: ValueKey('${identityHashCode(catalog)}-$uri'),
        image: NetworkImage(uri.toString(), headers: catalog.imageHeaders),
        // A channel's own art is always a logo. A programme's picture often
        // is too (the guide falls back to the station's logo), so its shape
        // decides once it has loaded.
        mayFill: source.isProgram,
        placeholder: fallback,
        onError: () => attempt(index + 1),
      );
    }

    return attempt(0);
  }
}

/// Guide art that fills the card only when it is a real 16:9 picture. Logos
/// and other shapes show whole on the panel colour, never cropped.
class _GuideArt extends StatefulWidget {
  const _GuideArt({
    super.key,
    required this.image,
    required this.mayFill,
    required this.placeholder,
    required this.onError,
  });
  final ImageProvider image;
  final bool mayFill;
  final Widget placeholder;
  final Widget Function() onError;
  @override
  State<_GuideArt> createState() => _GuideArtState();
}

class _GuideArtState extends State<_GuideArt> {
  ImageStream? _stream;
  late final _listener = ImageStreamListener(
    (info, _) {
      final wide = isWideGuidePicture(info.image.width, info.image.height);
      info.dispose();
      if (mounted && wide != _wide) setState(() => _wide = wide);
    },
    onError: (_, _) {
      if (mounted) setState(() => _failed = true);
    },
  );
  bool? _wide;
  bool _failed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _stream = stream..addListener(_listener);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return widget.onError();
    final wide = _wide;
    if (wide == null) return widget.placeholder;
    // A programme picture that isn't a wide still is a presenter headshot or
    // a station logo: try the channel's own art instead (web, Roku and LG
    // reject it the same way).
    if (widget.mayFill && !wide) return widget.onError();
    final fill = widget.mayFill && wide;
    final art = Image(
      image: widget.image,
      fit: fill ? BoxFit.cover : BoxFit.contain,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => widget.onError(),
    );
    return ColoredBox(
      color: Zoro.panel,
      child: fill
          ? art
          : Padding(padding: const EdgeInsets.all(20), child: art),
    );
  }
}
