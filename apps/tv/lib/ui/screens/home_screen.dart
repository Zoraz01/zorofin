import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/catalog.dart';
import '../../core/errors.dart';
import '../../core/home.dart';
import '../../core/models.dart';
import '../../core/playback.dart';
import '../../core/preferences.dart';
import '../../extras_state.dart';
import '../player/player_panels.dart' show clockLabel;
import '../theme.dart';
import '../widgets/favorite_button.dart';
import '../widgets/focusable.dart';
import '../widgets/media_card.dart';
import '../widgets/section_title.dart';

/// Home (Apple `HomeView` TV layout): the featured banner, Continue
/// Watching, My requests and live sports pinned at the top, then personal,
/// library and discovery rows in a weighted random order, with Explore more
/// at the end.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.catalog,
    required this.onOpen,
    required this.onPlay,
    required this.onAllChannels,
    this.extras,
    this.revision = 0,
  });

  final Catalog catalog;
  final ExtrasState? extras;
  final ValueChanged<MediaItem> onOpen;
  final PlayItem onPlay;
  final VoidCallback onAllChannels;

  static const previewSeed = int.fromEnvironment(
    'ZOROFIN_PREVIEW_SEED',
    defaultValue: 1,
  );

  /// Bumped when watch state changes elsewhere, so shelves reload in place.
  final int revision;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// Shelf ids as on Apple: 0 Continue Watching, 2 movies, 3 shows.
class _Shelf {
  const _Shelf(this.id, this.title, this.items, {this.landscape = false});
  final int id;
  final String title;
  final List<MediaItem> items;
  final bool landscape;
}

sealed class _MixedRow {
  const _MixedRow();
}

class _PersonalRow extends _MixedRow {
  const _PersonalRow(this.row);
  final HomeFeedRow row;
}

class _LibraryRow extends _MixedRow {
  const _LibraryRow(this.shelf);
  final _Shelf shelf;
}

class _GeneratedRow extends _MixedRow {
  const _GeneratedRow(this.row);
  final DiscoveryRow row;
}

class _HomeScreenState extends State<HomeScreen> {
  /// The preview keeps one layout so screenshots and reviews match.
  late final int? _seed = widget.catalog.isPreview
      ? HomeScreen.previewSeed
      : null;
  late final _banner = HomeBanner(seed: _seed);
  late final _order = HomeRowOrder(seed: _seed);
  var _discovery = DiscoveryFeed();
  final Map<int, _Shelf> _shelves = {};
  List<MediaItem> _featured = const [];
  bool _loading = true;
  String? _failure;
  List<HomeFeedRow>? _feed;
  List<String> _teams = const [];
  String? _homeError;
  bool _loadingRows = false;
  final List<DiscoveryRow> _discoveryRows = [];
  bool _discoveryLoading = false;
  String? _discoveryError;
  bool _discoveryAutomatic = true;
  bool _mixPrepared = false;
  bool _shelvesDone = false;
  bool _rowsDone = false;
  LiveTvSnapshot? _live;
  List<LiveEvent> _events = const [];
  LiveArtworkManifest? _artwork;
  int _load = 0;
  int _homeRevision = 0;
  Timer? _rowsTimer;
  Timer? _liveTimer;
  Timer? _clock;
  DateTime _now = DateTime.now();

  Catalog get _catalog => widget.catalog;
  ExtrasState? get _extras => widget.extras;

  @override
  void initState() {
    super.initState();
    _homeRevision = _extras?.homeRevision ?? 0;
    _extras?.addListener(_extrasChanged);
    unawaited(_reloadAll());
    _rowsTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(_loadRows()),
    );
    _liveTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => unawaited(_loadLive()),
    );
    // Live cards and starting times follow the clock.
    _clock = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void didUpdateWidget(HomeScreen old) {
    super.didUpdateWidget(old);
    if (old.revision != widget.revision) unawaited(_loadShelves());
  }

  @override
  void dispose() {
    _extras?.removeListener(_extrasChanged);
    _rowsTimer?.cancel();
    _liveTimer?.cancel();
    _clock?.cancel();
    super.dispose();
  }

  /// A sent request or saved teams change the personal rows.
  void _extrasChanged() {
    final revision = _extras?.homeRevision ?? 0;
    if (revision != _homeRevision) {
      _homeRevision = revision;
      unawaited(_loadRows());
    }
  }

  Future<void> _reloadAll() async {
    final load = ++_load;
    setState(() {
      _discovery = DiscoveryFeed();
      _discoveryRows.clear();
      _discoveryError = null;
      _discoveryAutomatic = true;
      _mixPrepared = false;
      _shelvesDone = false;
      _rowsDone = false;
    });
    await Future.wait([_loadShelves(), _loadRows(), _loadLive()]);
    if (mounted && load == _load) await _prepareMix();
  }

  Future<void> _loadShelves() async {
    final load = _load;
    setState(() {
      _loading = _shelves.isEmpty;
      _failure = null;
    });
    if (_catalog.isPreview) {
      final rows = await _catalog.home();
      if (!mounted) return;
      setState(() {
        for (final (i, row) in rows.indexed) {
          final id = i == 0 ? 0 : i + 1;
          _shelves[id] = _Shelf(
            id,
            row.title,
            row.items,
            landscape: row.landscape,
          );
        }
        // The preview always features the first movie.
        _featured = [
          ...rows
              .expand((r) => r.items)
              .where((i) => i.type == 'Movie')
              .take(1),
        ];
        _loading = false;
        _shelvesDone = true;
        _updateBanner();
        _appendOrder();
      });
      return;
    }
    final client = _catalog.client;
    if (client == null) return;
    String? failure;
    Future<void> shelf(int id, Future<List<MediaItem>> items) async {
      try {
        final result = await items;
        if (!mounted || load != _load) return;
        setState(() {
          if (id == 1) {
            _featured = result;
          } else {
            _shelves[id] = _Shelf(
              id,
              const {
                0: 'Continue Watching',
                2: 'Recently Added Movies',
                3: 'Recently Added Shows',
              }[id]!,
              result,
              landscape: id == 0,
            );
            _loading = false;
          }
          _updateBanner();
          _appendOrder();
        });
      } on ClientError catch (e) {
        if (id != 1) failure = e.message;
      } catch (_) {
        if (id != 1) failure = 'Something went wrong.';
      }
    }

    await Future.wait([
      shelf(
        0,
        client.continueWatchingFeed().then((feed) {
          if (feed.partial) {
            failure =
                'Some Continue Watching titles couldn\'t load. Try again.';
          }
          return feed.items;
        }),
      ),
      shelf(1, client.homeBannerItems().then((p) => p.items)),
      shelf(2, client.items(type: 'Movie').then((p) => p.items)),
      shelf(3, client.items(type: 'Series').then((p) => p.items)),
    ]);
    if (!mounted || load != _load) return;
    setState(() {
      _loading = false;
      _failure = failure;
      _shelvesDone = true;
    });
  }

  Future<void> _loadRows() async {
    final client = _catalog.client;
    final extras = _extras;
    if (_catalog.isPreview || client == null) {
      _rowsDone = true;
      return;
    }
    final load = _load;
    final usesServer = extras?.features.homeRows ?? false;
    setState(() {
      _loadingRows = true;
      _homeError = null;
    });
    try {
      final serverFuture = usesServer
          ? client
                .homeFeed()
                .then<Object>((rows) => rows)
                .catchError((Object e) => e)
          : Future<Object?>.value();
      List<String> teams;
      try {
        teams = await client.homeTeams(serverFallback: usesServer);
      } catch (_) {
        teams = _teams;
      }
      final rows = await client.clientHomeRows(teams);
      final server = await serverFuture;
      if (!mounted || load != _load) return;
      if (server is ClientError) {
        if (server.kind == ClientErrorKind.unauthorized) throw server;
        _homeError = server.message;
      }
      final merged = ClientHomeRows.merge(
        rows,
        server is List<HomeFeedRow> ? server : null,
      );
      setState(() {
        _teams = teams;
        _feed = merged;
        _appendOrder();
      });
      final enriched = await client.enrichHomeRows(merged);
      if (mounted && load == _load) setState(() => _feed = enriched);
    } on ClientError catch (e) {
      if (mounted && load == _load) setState(() => _homeError = e.message);
    } catch (_) {
      if (mounted && load == _load) {
        setState(() => _homeError = 'Home rows couldn\'t load.');
      }
    } finally {
      if (mounted && load == _load) {
        setState(() {
          _loadingRows = false;
          _rowsDone = true;
        });
      }
    }
  }

  Future<void> _loadLive() async {
    if (_catalog.isPreview) {
      if (_live != null) return;
      final now = DateTime.now();
      final channels = [
        for (final (i, title) in const [
          'Live: NFL Football',
          'Live: NBA Basketball',
          'Live: Premier League Soccer',
        ].indexed)
          MediaItem(
            id: 'preview-live-$i',
            name: 'Preview Sports ${i + 1}',
            type: 'TvChannel',
            channelNumber: '${i + 1}',
            currentProgram: LiveProgram(
              name: title,
              start: now.subtract(const Duration(minutes: 15)),
              end: now.add(const Duration(hours: 1)),
              isLive: true,
            ),
          ),
      ];
      setState(() {
        _now = now;
        _live = LiveTvSnapshot(channels, now);
        _events = _live!.events(now);
      });
      return;
    }
    final client = _catalog.client;
    if (client == null) return;
    final wantsArtwork = _extras?.features.liveArtwork ?? false;
    if (!wantsArtwork) _artwork = null;
    try {
      final artworkFuture = wantsArtwork
          ? client
                .liveArtworkManifest()
                .then<LiveArtworkManifest?>((m) => m)
                .catchError((_) => null)
          : Future<LiveArtworkManifest?>.value(_artwork);
      final snapshot = await client.liveTvSnapshot();
      if (!mounted) return;
      final now = DateTime.now();
      setState(() {
        // The clock never runs behind the snapshot it judges.
        _now = now;
        _live = snapshot;
        _events = snapshot.events(now, artwork: _artwork);
      });
      final manifest = await artworkFuture;
      if (!mounted || manifest == null) return;
      setState(() {
        _artwork = manifest;
        _events = snapshot.events(DateTime.now(), artwork: manifest);
      });
    } on ClientError catch (e) {
      if (!mounted) return;
      if (e.kind == ClientErrorKind.unauthorized ||
          e.kind == ClientErrorKind.forbidden) {
        setState(() => _live = null);
      }
    } catch (_) {}
  }

  void _updateBanner() {
    final recent = [
      for (final s in _shelves.values)
        if (s.id >= 2) ...s.items,
    ];
    _banner.update([
      ...recent,
      ..._discoveryRows.expand((r) => r.items),
      ...?_shelves[0]?.items,
    ], featured: _featured);
  }

  List<(String, _MixedRow)> get _browseRows => [
    for (final row in _feed ?? const <HomeFeedRow>[])
      if (row.id != 'requests-ready' && row.cards.isNotEmpty)
        (row.id, _PersonalRow(row)),
    for (final s in _shelves.values.toList()..sort((a, b) => a.id - b.id))
      if (s.id >= 2 && s.items.isNotEmpty) ('shelf-${s.id}', _LibraryRow(s)),
    for (final r in _discoveryRows) (r.id, _GeneratedRow(r)),
  ];

  void _appendOrder() {
    if (!_mixPrepared || _discoveryLoading) return;
    _order.append([
      for (final (id, row) in _browseRows)
        (
          id,
          row is _GeneratedRow ? HomeRowKind.generated : HomeRowKind.deliberate,
        ),
    ]);
  }

  /// One discovery batch once the priority data is in, then the mix order.
  Future<void> _prepareMix() async {
    if (_mixPrepared || !_shelvesDone || !_rowsDone) return;
    _mixPrepared = true;
    await _loadDiscovery();
    if (mounted) setState(_appendOrder);
  }

  Future<void> _loadDiscovery() async {
    final client = _catalog.client;
    if (_discoveryLoading ||
        !_discovery.hasMore ||
        client == null ||
        _catalog.isPreview) {
      return;
    }
    final load = _load;
    setState(() {
      _discoveryLoading = true;
      _discoveryError = null;
    });
    final fixed = {
      for (final s in _shelves.values) ...s.items.map((i) => i.id),
      for (final r in _feed ?? const <HomeFeedRow>[])
        ...r.cards.map((c) => c.item.id),
    };
    try {
      final rows = await _discovery.next(client, excluding: fixed);
      if (!mounted || load != _load) return;
      setState(() {
        _discoveryRows.addAll(rows);
        _updateBanner();
        // A sparse page never starts a background request loop.
        _discoveryAutomatic = rows.isNotEmpty;
      });
    } on ClientError catch (e) {
      if (mounted && load == _load) setState(() => _discoveryError = e.message);
    } catch (_) {
      if (mounted && load == _load) {
        setState(() => _discoveryError = 'More titles couldn\'t load.');
      }
    } finally {
      if (mounted && load == _load) {
        setState(() {
          _discoveryLoading = false;
          _appendOrder();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hero = _banner.item;
    final shelvesEmpty = _shelves.values.every((s) => s.items.isEmpty);
    final mixed = {for (final (id, row) in _browseRows) id: row};
    final ready = _feed?.where((r) => r.id == 'requests-ready').firstOrNull;
    final continued = _shelves[0];
    final events = _live != null && _live!.isFresh(_now)
        ? _events.where((e) => e.isCurrent(_now)).toList()
        : const <LiveEvent>[];
    final children = <Widget>[
      if (_loading)
        Padding(
          padding: const EdgeInsets.all(50),
          child: Column(
            children: [
              const CircularProgressIndicator(color: Zoro.jade),
              const SizedBox(height: 16),
              Text('Loading your library…', style: Zoro.font(22)),
            ],
          ),
        ),
      if (hero != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Zoro.gutter),
          child: _Hero(
            item: hero,
            catalog: _catalog,
            onOpen: widget.onOpen,
            onPlay: widget.onPlay,
          ),
        ),
      if (_failure != null)
        StatusMessage(
          title: shelvesEmpty
              ? 'Library unavailable'
              : 'Some shelves couldn\'t load',
          detail: _failure!,
          icon: Icons.wifi_off_rounded,
          action: ZoroButton(
            label: 'Try again',
            autofocus: hero == null,
            onPressed: _reloadAll,
          ),
        ),
      if (continued != null && continued.items.isNotEmpty)
        MediaShelf(
          title: continued.title,
          items: continued.items,
          landscape: true,
          catalog: _catalog,
          onOpen: widget.onOpen,
        ),
      if (ready != null)
        HomeRowShelf(
          row: ready,
          title: 'My requests',
          catalog: _catalog,
          now: _now,
          onOpen: widget.onOpen,
        ),
      if (events.isNotEmpty)
        LiveEventsShelf(
          events: events,
          catalog: _catalog,
          now: _now,
          onAllChannels: widget.onAllChannels,
          onOpen: (event) {
            // Rechecked at activation, between clock ticks.
            final now = DateTime.now();
            if (_live?.isFresh(now) == true && event.isCurrent(now)) {
              widget.onOpen(event.channel);
            }
          },
        ),
      if (_loadingRows && _feed == null)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: Zoro.gutter),
          child: LinearProgressIndicator(color: Zoro.jade),
        ),
      if (_homeError != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Zoro.gutter),
          child: Align(
            alignment: Alignment.centerLeft,
            child: ZoroButton(
              label: 'Retry Home rows',
              onPressed: () => unawaited(_loadRows()),
            ),
          ),
        ),
      for (final id in _order.ids)
        if (mixed[id] case final row?)
          switch (row) {
            _PersonalRow(:final row) => HomeRowShelf(
              row: row,
              catalog: _catalog,
              now: _now,
              onOpen: widget.onOpen,
            ),
            _LibraryRow(:final shelf) => MediaShelf(
              title: shelf.title,
              items: shelf.items,
              landscape: shelf.landscape,
              catalog: _catalog,
              onOpen: widget.onOpen,
            ),
            _GeneratedRow(:final row) => MediaShelf(
              title: row.title,
              items: row.items,
              catalog: _catalog,
              onOpen: widget.onOpen,
            ),
          },
      // Rows not yet placed in the mix (preview and first paint).
      if (!_mixPrepared || _catalog.isPreview)
        for (final (id, row) in _browseRows)
          if (!_order.ids.contains(id) && row is _LibraryRow)
            MediaShelf(
              title: row.shelf.title,
              items: row.shelf.items,
              landscape: row.shelf.landscape,
              catalog: _catalog,
              onOpen: widget.onOpen,
            ),
      if (_mixPrepared &&
          !_loading &&
          !_catalog.isPreview &&
          _catalog.client != null &&
          _discovery.hasMore)
        _ExploreMore(
          key: ValueKey('explore-${_discoveryRows.length}'),
          loading: _discoveryLoading,
          error: _discoveryError,
          automatic: _discoveryAutomatic,
          onLoad: () => unawaited(_loadDiscovery()),
        ),
      if (!_loading && _failure == null && shelvesEmpty)
        const StatusMessage(
          title: 'Your library is ready for its first title',
          detail: 'Media added to your Jellyfin server will appear here.',
        ),
    ];
    return ListView.separated(
      // Keep shelves below the fold built so Down always has a target.
      cacheExtent: 2000,
      padding: const EdgeInsets.only(top: 16, bottom: 24),
      itemCount: children.length,
      separatorBuilder: (_, _) => const SizedBox(height: 36),
      itemBuilder: (_, i) => children[i],
    );
  }
}

/// Explore more (Apple `BrowseContinuation`): loads one batch when it comes
/// into view, and on request after a sparse page or an error.
class _ExploreMore extends StatefulWidget {
  const _ExploreMore({
    super.key,
    required this.loading,
    required this.error,
    required this.automatic,
    required this.onLoad,
  });

  final bool loading;
  final String? error;
  final bool automatic;
  final VoidCallback onLoad;

  @override
  State<_ExploreMore> createState() => _ExploreMoreState();
}

class _ExploreMoreState extends State<_ExploreMore> {
  @override
  void initState() {
    super.initState();
    if (widget.automatic && widget.error == null && !widget.loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onLoad();
      });
    }
  }

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      children: [
        if (widget.loading)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: CircularProgressIndicator(color: Zoro.jade),
          ),
        if (widget.error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(widget.error!, style: Zoro.font(18, color: Zoro.muted)),
          ),
        ZoroButton(
          label: widget.error == null ? 'Explore more' : 'Try again',
          onPressed: widget.loading ? () {} : widget.onLoad,
        ),
      ],
    ),
  );
}

/// A personal row (Apple `CustomHomeShelf`): cards with their context badge,
/// time or length, and the start time for broadcasts.
class HomeRowShelf extends StatelessWidget {
  const HomeRowShelf({
    super.key,
    required this.row,
    required this.catalog,
    required this.now,
    required this.onOpen,
    this.title,
  });

  final HomeFeedRow row;
  final String? title;
  final Catalog catalog;
  final DateTime now;
  final ValueChanged<MediaItem> onOpen;

  @override
  Widget build(BuildContext context) {
    final cards = row.cards.where((c) => !c.isExpired(now)).toList();
    if (cards.isEmpty) return const SizedBox.shrink();
    final prefs = Preferences.valueOf(context);
    // Size the row for its tallest card: posters are taller than landscape
    // stills, and each card can add up to a few caption lines of its own.
    final shapes = cards.map(_landscape).toSet();
    final cardHeight = shapes
        .map((l) => MediaCard.heightFor(landscape: l, prefs: prefs))
        .reduce((a, b) => a > b ? a : b);
    final lines = cards.map(_extraLines).reduce((a, b) => a > b ? a : b);
    final height = cardHeight + 36 + lines * _lineHeight + 8;
    return FocusTraversalGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Zoro.gutter),
            child: SectionTitle(title ?? row.title),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: height,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              padding: const EdgeInsets.symmetric(
                horizontal: Zoro.gutter,
                vertical: 18,
              ),
              itemCount: cards.length,
              separatorBuilder: (_, _) => const SizedBox(width: 28),
              itemBuilder: (context, i) => _card(cards[i], prefs),
            ),
          ),
        ],
      ),
    );
  }

  static const _lineHeight = 26.0;

  bool _landscape(HomeRowCard card) =>
      row.id == 'sports' || card.item.isEpisode;

  bool _showsSubtitle(HomeRowCard card) =>
      const ['short-movies', 'sports'].contains(row.id) &&
      card.subtitle.isNotEmpty;

  /// Caption lines this row adds under a card's own title and year.
  int _extraLines(HomeRowCard card) =>
      (card.contextBadges.isNotEmpty ? 1 : 0) +
      (_showsSubtitle(card) ? (row.id == 'sports' ? 2 : 1) : 0) +
      (jellyfinDate(card.startsAt) != null ? 1 : 0);

  Widget _card(HomeRowCard card, DevicePreferences prefs) {
    final landscape = _landscape(card);
    final start = jellyfinDate(card.startsAt);
    final context = card.contextBadges;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        MediaCard(
          item: card.item,
          catalog: catalog,
          landscape: landscape,
          formats: card.qualityBadges,
          onPressed: () => onOpen(card.item),
        ),
        SizedBox(
          width: MediaCard.widthFor(landscape: landscape, prefs: prefs),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (context.isNotEmpty)
                Text(
                  start == null
                      ? context.join(' · ')
                      : (start.isAfter(now) ? 'Starting soon' : 'On now'),
                  style: Zoro.font(
                    19,
                    weight: FontWeight.w600,
                    color: Zoro.jade,
                  ),
                ),
              if (_showsSubtitle(card))
                Text(
                  card.subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Zoro.font(19, color: Zoro.muted),
                ),
              if (start != null)
                Text(
                  '${start.isAfter(now) ? 'Starts' : 'Started'} ${clockLabel(start)}',
                  style: Zoro.font(19, color: Zoro.muted),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Sports & live events (Apple `LiveEventsShelf`): what is airing now, with
/// All channels.
class LiveEventsShelf extends StatelessWidget {
  const LiveEventsShelf({
    super.key,
    required this.events,
    required this.catalog,
    required this.now,
    required this.onOpen,
    required this.onAllChannels,
  });

  final List<LiveEvent> events;
  final Catalog catalog;
  final DateTime now;
  final ValueChanged<LiveEvent> onOpen;
  final VoidCallback onAllChannels;

  @override
  Widget build(BuildContext context) => FocusTraversalGroup(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Zoro.gutter),
          child: Row(
            children: [
              const SectionTitle('Sports & live events'),
              const Spacer(),
              Focusable(
                onPressed: onAllChannels,
                semanticLabel: 'All channels',
                builder: (context, focused) => AnimatedContainer(
                  duration: Zoro.focusDuration,
                  constraints: const BoxConstraints(minHeight: Zoro.target),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: focused ? Zoro.text : Colors.transparent,
                    borderRadius: BorderRadius.circular(30),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'All channels',
                        style: Zoro.font(
                          20,
                          weight: FontWeight.w600,
                          color: focused ? Zoro.background : Zoro.jade,
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: focused ? Zoro.background : Zoro.jade,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 360 * 9 / 16 + 190,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            padding: const EdgeInsets.symmetric(
              horizontal: Zoro.gutter,
              vertical: 18,
            ),
            itemCount: events.length,
            separatorBuilder: (_, _) => const SizedBox(width: 28),
            itemBuilder: (context, i) => _LiveEventCard(
              event: events[i],
              catalog: catalog,
              now: now,
              onPressed: () => onOpen(events[i]),
            ),
          ),
        ),
      ],
    ),
  );
}

class _LiveEventCard extends StatelessWidget {
  const _LiveEventCard({
    required this.event,
    required this.catalog,
    required this.now,
    required this.onPressed,
  });

  final LiveEvent event;
  final Catalog catalog;
  final DateTime now;
  final VoidCallback onPressed;

  static const width = 360.0;

  @override
  Widget build(BuildContext context) {
    final channel = event.channel;
    return Focusable(
      onPressed: onPressed,
      semanticLabel:
          '${event.title}, live on ${channel.name}, ${clockLabel(event.start)} to ${clockLabel(event.end)}. Open channel.',
      builder: (context, focused) => SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedScale(
              scale: Zoro.lift(context, focused, 1.045),
              duration: Zoro.focusDuration,
              child: Container(
                width: width,
                height: width * 9 / 16,
                clipBehavior: Clip.antiAlias,
                foregroundDecoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: focused ? Colors.white : Colors.transparent,
                    width: 4,
                  ),
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF151C18),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _LiveArtwork(event: event, catalog: catalog),
                    Positioned(
                      top: 10,
                      left: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xBF000000),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.circle,
                              size: 10,
                              color: Color(0xFFFF453A),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              'LIVE',
                              style: Zoro.font(14, weight: FontWeight.w700),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              event.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Zoro.font(23, weight: FontWeight.w600),
            ),
            Text(
              channel.name +
                  (channel.channelNumber == null
                      ? ''
                      : ' · Ch ${channel.channelNumber}'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Zoro.font(18, color: Zoro.muted),
            ),
            Text(
              '${clockLabel(event.start)} – ${clockLabel(event.end)}',
              style: Zoro.font(17, color: Zoro.muted),
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: event.progress(now),
                minHeight: 3,
                color: Zoro.jade,
                backgroundColor: Zoro.border,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fixture image, programme image, team crests, then the bundled sport
/// illustration (Apple `LiveEventArtworkView`).
class _LiveArtwork extends StatelessWidget {
  const _LiveArtwork({required this.event, required this.catalog});

  final LiveEvent event;
  final Catalog catalog;

  @override
  Widget build(BuildContext context) {
    final fallback = Image.asset(
      event.sport.asset,
      fit: BoxFit.contain,
      excludeFromSemantics: true,
    );
    final client = catalog.client;
    if (client == null) return fallback;
    Widget chain(List<LiveArtworkSource> sources) {
      if (sources.isEmpty) return fallback;
      final source = sources.first;
      Widget next(BuildContext _, Object _, StackTrace? _) =>
          chain(sources.sublist(1));
      switch (source.kind) {
        case 'catalogue':
          final url = client.liveArtworkUrl(source.path!);
          if (url == null) return chain(sources.sublist(1));
          return Image.network(
            url.toString(),
            fit: BoxFit.contain,
            excludeFromSemantics: true,
            errorBuilder: next,
          );
        case 'program':
          return Image.network(
            client
                .image(
                  source.itemId!,
                  kind: source.imageKind!,
                  tag: source.tag,
                  width: 720,
                )
                .toString(),
            headers: catalog.imageHeaders,
            fit: BoxFit.contain,
            excludeFromSemantics: true,
            errorBuilder: next,
          );
        default:
          final crests = [
            for (final p in source.paths) client.liveArtworkUrl(p),
          ].nonNulls.toList();
          if (crests.length != 2) return chain(sources.sublist(1));
          return DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF213F36), Color(0xFF0E201A)],
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 16, 14, 0),
              child: Row(
                children: [
                  for (final (i, url) in crests.indexed) ...[
                    if (i == 1)
                      Expanded(
                        child: Center(
                          child: Text(
                            'VS',
                            style: Zoro.font(
                              18,
                              weight: FontWeight.w700,
                              color: const Color(0xFFBCE2C8),
                            ),
                          ),
                        ),
                      ),
                    SizedBox(
                      width: _LiveEventCard.width * 0.34,
                      height: _LiveEventCard.width * 9 / 16 * 0.72,
                      child: Image.network(
                        url.toString(),
                        fit: BoxFit.contain,
                        excludeFromSemantics: true,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
      }
    }

    return chain(event.artworkSources);
  }
}

class _Hero extends StatelessWidget {
  const _Hero({
    required this.item,
    required this.catalog,
    required this.onOpen,
    required this.onPlay,
  });

  final MediaItem item;
  final Catalog catalog;
  final ValueChanged<MediaItem> onOpen;
  final PlayItem onPlay;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: SizedBox(
        height: 480,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Artwork(
              url: catalog.artwork(item, landscape: true, width: 1600),
              headers: catalog.imageHeaders,
              title: item.displayTitle,
              seed: item.id,
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Color(0x26000000),
                    Color(0xEB000000),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(40),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Zoro.font(48, weight: FontWeight.w700),
                  ),
                  const SizedBox(height: 14),
                  MetadataLine(item),
                  if (item.overview != null) ...[
                    const SizedBox(height: 14),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 620),
                      child: Text(
                        item.overview!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Zoro.font(20, color: Zoro.muted),
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  FocusTraversalGroup(
                    child: Row(
                      children: [
                        ZoroButton(
                          white: true,
                          autofocus: true,
                          icon: Icons.play_arrow_rounded,
                          label: item.resumeTicks > 0 ? 'Resume' : 'Play',
                          onPressed: () =>
                              onPlay(item, startTicks: item.resumeTicks),
                        ),
                        const SizedBox(width: 12),
                        CircleIconButton(
                          icon: Icons.info_outline_rounded,
                          filled: false,
                          label: 'Details for ${item.name}',
                          onPressed: () => onOpen(item),
                        ),
                        const SizedBox(width: 12),
                        FavoriteButton(item: item, catalog: catalog),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
