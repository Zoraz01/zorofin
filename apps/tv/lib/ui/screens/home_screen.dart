import 'dart:async';

import 'collections_screen.dart';

import 'package:flutter/material.dart';
import '../widgets/home_game_card.dart';

import '../../core/catalog.dart';
import '../../core/home_shelf_snapshot.dart';
import '../../core/errors.dart';
import '../../core/home.dart';
import '../../core/live_scores.dart';
import '../../core/models.dart';
import '../../core/playback.dart';
import '../../core/preferences.dart';
import '../../core/server_extras.dart';
import '../../extras_state.dart';
import '../player/player_panels.dart' show clockLabel;
import '../theme.dart';
import '../widgets/favorite_button.dart';
import '../widgets/focusable.dart';
import '../widgets/home_rail_focus.dart';
import '../widgets/live_score_view.dart';
import '../widgets/media_card.dart';
import '../widgets/trailer_preview_card.dart';
import '../widgets/section_title.dart';

/// Home (Apple `HomeView` TV layout): the featured banner, Continue
/// Watching, My requests and live sports pinned at the top, then personal,
/// library and discovery rows in a weighted random order. More rows load
/// automatically as the viewer approaches the end.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.catalog,
    required this.onOpen,
    required this.onPlay,
    required this.onAllChannels,
    this.onBrowseCollections,
    this.extras,
    this.revision = 0,
  });

  final Catalog catalog;
  final ExtrasState? extras;
  final ValueChanged<MediaItem> onOpen;
  final VoidCallback? onBrowseCollections;
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

sealed class _MixedRow {
  const _MixedRow();
}

class _PersonalRow extends _MixedRow {
  const _PersonalRow(this.row);
  final HomeFeedRow row;
}

class _LibraryRow extends _MixedRow {
  const _LibraryRow(this.shelf);
  final LibraryShelf shelf;
}

class _GeneratedRow extends _MixedRow {
  const _GeneratedRow(this.row);
  final DiscoveryRow row;
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  /// The preview keeps one layout so screenshots and reviews match.
  late final int? _seed = widget.catalog.isPreview
      ? HomeScreen.previewSeed
      : null;
  late final _banner = HomeBanner(seed: _seed);
  late var _order = HomeRowOrder(seed: _seed);
  var _discovery = DiscoveryFeed();
  final Map<int, LibraryShelf> _shelves = {};
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
  LiveTvSnapshot? _live;
  List<LiveEvent> _events = const [];
  LiveArtworkManifest? _artwork;
  final _scores = LiveScoresCache();
  int _load = 0;
  int _homeRevision = 0;
  HomeRowsContract? _homeContract;
  int _rowsRequest = 0;
  bool _foreground = true;
  DateTime _nextRowsRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _rowsTimer;
  Timer? _liveTimer;
  Timer? _clock;
  final _scroll = ScrollController();
  DateTime _now = DateTime.now();

  Catalog get _catalog => widget.catalog;
  ExtrasState? get _extras => widget.extras;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _scroll.addListener(_nearEnd);
    _homeRevision = _extras?.homeRevision ?? 0;
    _homeContract = _extras?.features.homeRowsContract;
    _extras?.addListener(_extrasChanged);
    unawaited(_reloadAll());
    _rowsTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_foreground && DateTime.now().isAfter(_nextRowsRefresh)) {
        unawaited(_loadRows());
      }
    });
    _liveTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (_foreground) unawaited(_loadLive());
    });
    // Live cards and starting times follow the clock.
    _clock = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted && _foreground) setState(() => _now = DateTime.now());
    });
  }

  @override
  void didUpdateWidget(HomeScreen old) {
    super.didUpdateWidget(old);
    if (!identical(old.catalog, widget.catalog) ||
        !identical(old.extras, widget.extras)) {
      old.extras?.removeListener(_extrasChanged);
      _extras?.addListener(_extrasChanged);
      _rowsRequest++;
      _homeRevision = _extras?.homeRevision ?? 0;
      _homeContract = _extras?.features.homeRowsContract;
      _feed = null;
      _teams = [];
      _homeError = null;
      _shelves.clear();
      _featured = [];
      _banner.item = null;
      _order = HomeRowOrder(seed: _seed);
      _live = null;
      _events = [];
      _artwork = null;
      _scores.reset();
      unawaited(_reloadAll());
    } else if (old.revision != widget.revision) {
      unawaited(_loadShelves());
      unawaited(_loadRows());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      unawaited(() async {
        await _extras?.checkFeatures();
        if (mounted && _foreground) {
          await Future.wait([_loadRows(), _loadLive()]);
        }
      }());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _extras?.removeListener(_extrasChanged);
    _rowsTimer?.cancel();
    _liveTimer?.cancel();
    _clock?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _nearEnd() {
    if (!_scroll.hasClients ||
        !_mixPrepared ||
        !_discoveryAutomatic ||
        _discoveryError != null ||
        _discoveryLoading ||
        !_discovery.hasMore) {
      return;
    }
    if (_scroll.position.extentAfter < 700) unawaited(_loadDiscovery());
  }

  /// A sent request or saved teams change the personal rows.
  void _extrasChanged() {
    final revision = _extras?.homeRevision ?? 0;
    final contract = _extras?.features.homeRowsContract;
    if (revision != _homeRevision || contract != _homeContract) {
      _homeRevision = revision;
      if (contract != _homeContract) {
        _homeContract = contract;
        _rowsRequest++;
        setState(() {
          _feed = [];
          _homeError = null;
        });
      }
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
    });
    await Future.wait([
      _loadShelves().then((_) {
        if (mounted && load == _load) return _prepareMix();
      }),
      _loadRows(),
      _loadLive(),
    ]);
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
          _shelves[id] = LibraryShelf(
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
        _updateBanner();
        _appendOrder();
      });
      return;
    }
    final catalog = _catalog;
    final cache = catalog is JellyfinCatalog ? catalog.homeSnapshot : null;
    if (_shelves.isEmpty && cache != null) {
      for (final row in cache.read()) {
        if (row.items.isNotEmpty) _shelves[row.id] = row;
      }
      if (_shelves.isNotEmpty) {
        _loading = false;
        _updateBanner();
        _appendOrder();
      }
    }
    final client = _catalog.client;
    if (client == null) return;
    String? failure;
    bool accessDenied = false;
    Future<void> shelf(int id, Future<List<MediaItem>> items) async {
      try {
        final result = await items;
        if (!mounted || load != _load || accessDenied) return;
        setState(() {
          if (id == 1) {
            _featured = result;
          } else {
            _shelves[id] = LibraryShelf.forItems(id, result);
            _loading = false;
          }
          _updateBanner();
          _appendOrder();
        });
      } on ClientError catch (e) {
        if (mounted &&
            load == _load &&
            (e.kind == ClientErrorKind.forbidden ||
                e.kind == ClientErrorKind.unauthorized)) {
          accessDenied = true;
          failure = e.message;
          setState(() {
            _shelves.clear();
            _featured = [];
            _banner.item = null;
          });
          await cache?.clear();
        }
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
    if (failure == null && cache != null) {
      unawaited(cache.save(_shelves.values));
    }
    setState(() {
      _loading = false;
      _failure = failure;
    });
  }

  Future<void> _loadRows() async {
    final client = _catalog.client;
    final extras = _extras;
    if (_catalog.isPreview || client == null) {
      return;
    }
    final load = _load, request = ++_rowsRequest;
    final catalog = _catalog;
    final contract = extras?.features.homeRowsContract;
    bool current() =>
        mounted &&
        load == _load &&
        request == _rowsRequest &&
        identical(catalog, _catalog) &&
        contract == _extras?.features.homeRowsContract;
    _nextRowsRefresh = DateTime.now().add(const Duration(seconds: 30));
    setState(() {
      _loadingRows = true;
      _homeError = null;
    });
    try {
      final loaded = await client.loadHomeRows(
        contract: contract,
        fallbackTeams: _teams,
      );
      if (!current()) return;
      setState(() {
        _teams = loaded.teams;
        _feed = loaded.rows;
        _homeError = loaded.serverError == null
            ? null
            : 'Home rows couldn\'t be refreshed.';
        _nextRowsRefresh = DateTime.now().add(
          Duration(
            seconds: loaded.serverError != null
                ? 30
                : contract == HomeRowsContract.plugin
                ? 60
                : 300,
          ),
        );
        _appendOrder();
      });
      final enriched = await client.enrichHomeRows(loaded.rows);
      if (current()) setState(() => _feed = enriched);
    } on ClientError catch (e) {
      if (current()) {
        setState(() {
          _feed = [];
          _homeError = e.message;
        });
      }
    } catch (_) {
      if (current()) setState(() => _homeError = 'Home rows couldn\'t load.');
    } finally {
      if (current()) setState(() => _loadingRows = false);
    }
  }

  Future<void> _loadLive() async {
    final catalog = _catalog, load = _load;
    bool current() => mounted && identical(catalog, _catalog) && load == _load;
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
      if (!current()) return;
      final now = DateTime.now();
      // Live now order, favorite teams, the game cap and scores from the
      // companion; the guide-only row until (or unless) it answers.
      List<LiveEvent> arranged() => LiveScores.fromSnapshot(
        snapshot,
        _extras?.features.sportsEvents == true ? _scores.feedFor(client) : null,
        DateTime.now(),
        artwork: _artwork,
      );
      setState(() {
        // The clock never runs behind the snapshot it judges.
        _now = now;
        _live = snapshot;
        _events = arranged();
      });
      {
        final before = _scores.feedFor(client);
        final feed = _extras?.features.sportsEvents == true
            ? await _scores.load(client)
            : null;
        if (!current()) return;
        if (!identical(feed, before)) {
          setState(() {
            _events = arranged();
          });
        }
      }
      final manifest = await artworkFuture;
      if (!current() || manifest == null) return;
      setState(() {
        _artwork = manifest;
        _events = arranged();
      });
    } on ClientError catch (e) {
      if (!current()) return;
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
    if (!_mixPrepared) return;
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
    if (_mixPrepared) return;
    setState(() {
      _mixPrepared = true;
      _appendOrder();
    });
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
              CircularProgressIndicator(color: Zoro.jade),
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
          key: const ValueKey('continue-watching'),
          title: continued.title,
          items: continued.items,
          landscape: true,
          catalog: _catalog,
          // Opens the episode page (Resume, View series) rather than playing.
          onOpen: widget.onOpen,
        ),
      if (ready != null)
        HomeRowShelf(
          key: const ValueKey('requests-ready'),
          row: ready,
          title: 'My requests',
          catalog: _catalog,
          now: _now,
          onOpen: widget.onOpen,
        ),
      if (events.isNotEmpty)
        LiveEventsShelf(
          key: const ValueKey('sports-live-events'),
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
      CollectionsHomeShelf(
        key: const ValueKey('collections'),
        catalog: _catalog,
        onOpen: widget.onOpen,
        onBrowseAll: widget.onBrowseCollections,
        revision: _load,
      ),
      if (_loadingRows && _feed == null)
        Padding(
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
              key: ValueKey(id),
              row: row,
              catalog: _catalog,
              now: _now,
              onOpen: widget.onOpen,
            ),
            _LibraryRow(:final shelf) => MediaShelf(
              key: ValueKey(id),
              title: shelf.title,
              items: shelf.items,
              landscape: shelf.landscape,
              catalog: _catalog,
              onOpen: widget.onOpen,
              previews: true,
            ),
            _GeneratedRow(:final row) => MediaShelf(
              key: ValueKey(id),
              title: row.title,
              items: row.items,
              catalog: _catalog,
              onOpen: widget.onOpen,
              previews: true,
            ),
          },
      // Rows not yet placed in the mix (preview and first paint).
      if (!_mixPrepared || _catalog.isPreview)
        for (final (id, row) in _browseRows)
          if (!_order.ids.contains(id) && row is _LibraryRow)
            MediaShelf(
              key: ValueKey(id),
              title: row.shelf.title,
              items: row.shelf.items,
              landscape: row.shelf.landscape,
              catalog: _catalog,
              onOpen: widget.onOpen,
              previews: true,
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
          onLoad: () => unawaited(_loadDiscovery()),
        ),
      if (!_loading && _failure == null && shelvesEmpty)
        const StatusMessage(
          title: 'Your library is ready for its first title',
          detail: 'Media added to your Jellyfin server will appear here.',
        ),
    ];
    return HomeRailScope(
      child: ListView.separated(
        controller: _scroll,
        // Keep shelves below the fold built so Down always has a target.
        cacheExtent: 2000,
        padding: const EdgeInsets.only(top: 16, bottom: 24),
        itemCount: children.length,
        findChildIndexCallback: (key) {
          final index = children.indexWhere((child) => child.key == key);
          return index < 0 ? null : index * 2;
        },
        separatorBuilder: (_, _) => const SizedBox(height: 36),
        itemBuilder: (_, i) => children[i],
      ),
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
    required this.onLoad,
  });

  final bool loading;
  final String? error;
  final VoidCallback onLoad;

  @override
  State<_ExploreMore> createState() => _ExploreMoreState();
}

class _ExploreMoreState extends State<_ExploreMore> {
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      children: [
        if (widget.loading)
          Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: CircularProgressIndicator(color: Zoro.jade),
          ),
        if (widget.error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(widget.error!, style: Zoro.font(18, color: Zoro.muted)),
          ),
        ZoroButton(
          label: widget.error == null ? 'Load more' : 'Try again',
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
    final hasGames = row.id == 'sports' && cards.any((c) => c.game != null);
    final height =
        cardHeight + 36 + 8 + (hasGames && prefs.showTitles ? 65 : 0);
    return HomeRailFocus(
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
              findChildIndexCallback: (key) {
                final index = cards.indexWhere(
                  (card) => ValueKey(card.id) == key,
                );
                return index < 0 ? null : index * 2;
              },
              separatorBuilder: (_, _) => const SizedBox(width: 28),
              itemBuilder: (context, i) => _card(cards[i], prefs),
            ),
          ),
        ],
      ),
    );
  }

  /// Live and episode rows use wide cards; movies and shows use posters.
  bool _landscape(HomeRowCard card) =>
      row.id == 'sports' ||
      row.cards.any((c) => c.item.isEpisode || c.item.isLive);

  /// The one line under a card's title, matching the Apple apps: a live
  /// card's program and time, a short movie's length, or the row's badge.
  String? _caption(HomeRowCard card) {
    final start = jellyfinDate(card.startsAt);
    if (start != null) {
      final when = start.isAfter(now)
          ? 'Starts ${clockLabel(start)}'
          : 'On now';
      return card.subtitle.isEmpty ? when : '${card.subtitle} · $when';
    }
    return homeCardLabel(card, row.id);
  }

  Widget _card(HomeRowCard card, DevicePreferences prefs) {
    final landscape = _landscape(card);
    if (row.id == 'sports' && card.game != null) {
      return HomeGameCard(
        key: ValueKey(card.id),
        card: card,
        catalog: catalog,
        width: MediaCard.widthFor(landscape: true, prefs: prefs),
        small: false,
        caption: _caption(card),
        status: homeGameStatus(card, now, clockLabel),
        onPressed: () => onOpen(card.item),
      );
    }
    return KeyedSubtree(
      key: ValueKey(card.id),
      child: landscape
          ? MediaCard(
              item: card.item,
              catalog: catalog,
              landscape: true,
              formats: card.qualityBadges,
              caption: _caption(card),
              onPressed: () => onOpen(card.item),
            )
          : TrailerPreviewCard(
              item: card.item,
              catalog: catalog,
              formats: card.qualityBadges,
              caption: _caption(card),
              onPressed: () => onOpen(card.item),
            ),
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
  Widget build(BuildContext context) => HomeRailFocus(
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
            findChildIndexCallback: (key) {
              final index = events.indexWhere(
                (event) => ValueKey(event.id) == key,
              );
              return index < 0 ? null : index * 2;
            },
            separatorBuilder: (_, _) => const SizedBox(width: 28),
            itemBuilder: (context, i) => _LiveEventCard(
              key: ValueKey(events[i].id),
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
    super.key,
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
          '${event.title}${event.score == null ? '' : ', ${event.score!.text}'}${event.favoriteTeam ? ', favorite team' : ''}, live on ${channel.name}, ${clockLabel(event.start)} to ${clockLabel(event.end)}. Open channel.',
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
                  border: focused
                      ? Border.all(color: Colors.white, width: 4)
                      : Border.all(color: Zoro.border),
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF151C18),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (event.score case final score?) ...[
                      // The matchup art stays underneath the scores.
                      LiveEventArtworkView(event: event, catalog: catalog),
                      LiveScoreArt(score: score),
                      if (!score.isFinal)
                        const Positioned(
                          top: 12,
                          left: 12,
                          child: LiveScoreBadge(),
                        ),
                    ] else ...[
                      LiveEventArtworkView(event: event, catalog: catalog),
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
                    if (event.favoriteTeam)
                      const Positioned(
                        top: 10,
                        right: 10,
                        child: FavoriteTeamBadge(),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            if (event.score case final score?)
              LiveScoreCaption(event: event, score: score)
            else ...[
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
            ],
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
class LiveEventArtworkView extends StatelessWidget {
  const LiveEventArtworkView({
    super.key,
    required this.event,
    required this.catalog,
    this.width = _LiveEventCard.width,
  });

  final LiveEvent event;
  final Catalog catalog;

  /// Card width the team crests are sized against.
  final double width;

  @override
  Widget build(BuildContext context) {
    // Scored cards: no generic sport drawing; the team tint stands in, and
    // crests sit higher so the score lines don't cover them.
    final score = event.score;
    final fallback = score != null
        ? LiveScoreArt.tinted(score)
        : Image.asset(
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
          // Guide images that aren't a 16:9 picture are usually a channel
          // logo or a presenter headshot; move on to crests or the sport
          // illustration, as the web does (PR #199).
          return WideGuideImage(
            image: NetworkImage(
              client
                  .image(
                    source.itemId!,
                    kind: source.imageKind!,
                    tag: source.tag,
                    width: 720,
                  )
                  .toString(),
              headers: catalog.imageHeaders,
            ),
            orElse: () => chain(sources.sublist(1)),
          );
        default:
          final crests = [
            for (final p in source.paths) client.liveArtworkUrl(p),
          ].nonNulls.toList();
          if (crests.length != 2) return chain(sources.sublist(1));
          final row = Padding(
            padding: EdgeInsets.fromLTRB(14, score == null ? 16 : 12, 14, 0),
            child: Row(
              crossAxisAlignment: score == null
                  ? CrossAxisAlignment.center
                  : CrossAxisAlignment.start,
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
                    width: width * 0.34,
                    height: width * 9 / 16 * (score == null ? 0.72 : 0.46),
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
          );
          if (score != null) return LiveScoreArt.tinted(score, child: row);
          return DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF213F36), Color(0xFF0E201A)],
              ),
            ),
            child: row,
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

/// Shows [image] only once it has loaded as a wide picture; anything else
/// (an error, a logo, a headshot) shows [orElse] instead.
class WideGuideImage extends StatefulWidget {
  const WideGuideImage({super.key, required this.image, required this.orElse});

  final ImageProvider image;
  final Widget Function() orElse;

  @override
  State<WideGuideImage> createState() => _WideGuideImageState();
}

class _WideGuideImageState extends State<WideGuideImage> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  bool? _wide;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(WideGuideImage old) {
    super.didUpdateWidget(old);
    if (old.image != widget.image) {
      _wide = null;
      _resolve();
    }
  }

  void _resolve() {
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _stop();
    final listener = ImageStreamListener(
      (info, _) {
        if (mounted) {
          setState(
            () =>
                _wide = isWideGuidePicture(info.image.width, info.image.height),
          );
        }
      },
      onError: (_, _) {
        if (mounted) setState(() => _wide = false);
      },
    );
    _stream = stream..addListener(listener);
    _listener = listener;
  }

  void _stop() {
    final listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => switch (_wide) {
    null => const SizedBox.expand(),
    true => Image(
      image: widget.image,
      fit: BoxFit.contain,
      excludeFromSemantics: true,
    ),
    false => widget.orElse(),
  };
}
