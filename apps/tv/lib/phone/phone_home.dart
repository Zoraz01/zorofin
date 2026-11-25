import 'dart:async';

import '../ui/screens/collections_screen.dart';

import 'package:flutter/material.dart';

import '../core/catalog.dart';
import '../core/home_shelf_snapshot.dart';
import '../core/errors.dart';
import '../core/home.dart';
import '../core/live_scores.dart';
import '../core/models.dart';
import '../core/server_extras.dart';
import '../extras_state.dart';
import '../ui/theme.dart';
import '../ui/widgets/media_card.dart' show Artwork;
import 'phone_extras.dart';
import 'phone_scope.dart';
import 'phone_theme.dart';
import 'phone_widgets.dart';

/// Home (Apple `HomeView` on iPhone/iPad): the header with Movies, Shows and
/// Live TV shortcuts, the featured banner, Continue Watching, My requests and
/// live sports pinned at the top, then personal, library and discovery rows
/// in a weighted random order. More rows load near the end.
class PhoneHomeScreen extends StatefulWidget {
  const PhoneHomeScreen({super.key});

  static const previewSeed = int.fromEnvironment(
    'ZOROFIN_PREVIEW_SEED',
    defaultValue: 1,
  );

  @override
  State<PhoneHomeScreen> createState() => _PhoneHomeScreenState();
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
  final LibraryShelf shelf;
}

class _GeneratedRow extends _MixedRow {
  const _GeneratedRow(this.row);
  final DiscoveryRow row;
}

class _PhoneHomeScreenState extends State<PhoneHomeScreen> {
  late Catalog _catalog;
  ExtrasState? _extras;
  late final int? _seed;
  late final HomeBanner _banner;
  late final HomeRowOrder _order;
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
  final _scores = LiveScoresCache();
  LiveArtworkManifest? _artwork;
  int _load = 0;
  int _homeRevision = 0;
  int _revision = 0;
  Timer? _rowsTimer;
  int _rowsRequest = 0;
  HomeRowsContract? _homeContract;
  Timer? _liveTimer;
  Timer? _clock;
  final _scroll = ScrollController();
  DateTime _now = DateTime.now();
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = PhoneScope.of(context);
    if (!_started) {
      _started = true;
      _catalog = scope.catalog;
      _extras = scope.extras;
      _revision = scope.revision;
      _seed = _catalog.isPreview ? PhoneHomeScreen.previewSeed : null;
      _banner = HomeBanner(seed: _seed);
      _order = HomeRowOrder(seed: _seed);
      _scroll.addListener(_nearEnd);
      _homeRevision = _extras?.homeRevision ?? 0;
      _homeContract = _extras?.features.homeRowsContract;
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
      _clock = Timer.periodic(const Duration(seconds: 15), (_) {
        if (mounted) setState(() => _now = DateTime.now());
      });
    } else if (scope.revision != _revision) {
      // Playback changed watch state; shelves reload in place.
      _revision = scope.revision;
      unawaited(_loadShelves());
    }
  }

  @override
  void dispose() {
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
    if (_scroll.position.extentAfter < 600) unawaited(_loadDiscovery());
  }

  void _extrasChanged() {
    final revision = _extras?.homeRevision ?? 0;
    final contract = _extras?.features.homeRowsContract;
    if (revision != _homeRevision || contract != _homeContract) {
      _homeRevision = revision;
      if (contract != _homeContract) {
        _homeContract = contract;
        _rowsRequest++;
        _feed = [];
        _homeError = null;
      }
      unawaited(_loadRows());
    }
    if (mounted) setState(() {});
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
            failure = 'Some Continue Watching titles couldn’t load. Try again.';
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
    if (_catalog.isPreview || client == null) return;
    final load = _load, request = ++_rowsRequest, catalog = _catalog;
    final contract = _extras?.features.homeRowsContract;
    bool current() =>
        mounted &&
        load == _load &&
        request == _rowsRequest &&
        identical(catalog, _catalog) &&
        contract == _extras?.features.homeRowsContract;
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
            : 'Home rows couldn’t be refreshed.';
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
      if (current()) setState(() => _homeError = 'Home rows couldn’t load.');
    } finally {
      if (current()) setState(() => _loadingRows = false);
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
      // Live now order, favorite teams, the game cap and scores from the
      // companion; the guide-only row until (or unless) it answers.
      List<LiveEvent> arranged() => LiveScores.fromSnapshot(
        snapshot,
        _extras?.features.sportsEvents == true ? _scores.feedFor(client) : null,
        DateTime.now(),
        artwork: _artwork,
      );
      setState(() {
        _now = now;
        _live = snapshot;
        _events = arranged();
      });
      {
        final before = _scores.feedFor(client);
        final feed = _extras?.features.sportsEvents == true
            ? await _scores.load(client)
            : null;
        if (!mounted) return;
        if (!identical(feed, before)) {
          setState(() {
            _events = arranged();
          });
        }
      }
      final manifest = await artworkFuture;
      if (!mounted || manifest == null) return;
      setState(() {
        _artwork = manifest;
        _events = arranged();
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
    if (!_mixPrepared) return;
    _order.append([
      for (final (id, row) in _browseRows)
        (
          id,
          row is _GeneratedRow ? HomeRowKind.generated : HomeRowKind.deliberate,
        ),
    ]);
  }

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
        _discoveryAutomatic = rows.isNotEmpty;
      });
    } on ClientError catch (e) {
      if (mounted && load == _load) setState(() => _discoveryError = e.message);
    } catch (_) {
      if (mounted && load == _load) {
        setState(() => _discoveryError = 'More titles couldn’t load.');
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

  Widget _header(PhoneScope scope) {
    final extras = scope.extras;
    final shortcuts = [
      for (final d in const [
        PhoneDestination.movies,
        PhoneDestination.shows,
        PhoneDestination.live,
      ])
        Padding(
          padding: const EdgeInsets.only(right: 10),
          child: PillButton(
            label: d == PhoneDestination.shows ? 'Shows' : d.title,
            onPressed: () => scope.select(d),
          ),
        ),
    ];
    final utilities = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (extras.features.support)
          RoundIconButton(
            icon: Icons.support_agent_rounded,
            label: 'Support',
            fill: Colors.transparent,
            onPressed: () => openSupport(context),
          ),
        if (extras.hasNotifications) const NotificationBell(),
        RoundIconButton(
          icon: Icons.search_rounded,
          label: 'Search',
          fill: Colors.transparent,
          onPressed: () => scope.select(PhoneDestination.search),
        ),
      ],
    );
    final logo = Image.asset(
      'assets/images/mark-512.png',
      width: 40,
      height: 40,
      semanticLabel: 'Zorofin',
      errorBuilder: (_, _, _) => Image.asset(
        'assets/images/wordmark.png',
        height: 28,
        semanticLabel: 'Zorofin',
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Phone.gutter),
      child: LayoutBuilder(
        builder: (context, size) {
          if (size.maxWidth >= 640) {
            return Row(
              children: [
                logo,
                const SizedBox(width: 20),
                ...shortcuts,
                const Spacer(),
                utilities,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [logo, const Spacer(), utilities]),
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: shortcuts),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scope = PhoneScope.of(context);
    final media = MediaQuery.of(context);
    final hero = _banner.item;
    final shelvesEmpty = _shelves.values.every((s) => s.items.isEmpty);
    final mixed = {for (final (id, row) in _browseRows) id: row};
    final ready = _feed?.where((r) => r.id == 'requests-ready').firstOrNull;
    final continued = _shelves[0];
    final events = _live != null && _live!.isFresh(_now)
        ? _events.where((e) => e.isCurrent(_now)).toList()
        : const <LiveEvent>[];
    Widget shelf(
      String title,
      List<MediaItem> items, {
      bool landscape = false,
      Key? key,
    }) => PhoneShelf(
      key: key,
      title: title,
      items: items,
      landscape: landscape,
      catalog: _catalog,
      onOpen: scope.open,
    );
    final children = <Widget>[
      _header(scope),
      if (_loading) const PhoneLoading(label: 'Loading your library…'),
      if (hero != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Phone.gutter),
          child: PhoneHero(item: hero),
        ),
      if (_failure != null)
        PhoneStatus(
          title: shelvesEmpty
              ? 'Library unavailable'
              : 'Some shelves couldn’t load',
          detail: _failure,
          icon: Icons.wifi_off_rounded,
          action: PillButton(label: 'Try again', onPressed: _reloadAll),
        ),
      if (continued != null && continued.items.isNotEmpty)
        shelf(continued.title, continued.items, landscape: true),
      if (ready != null)
        PhoneHomeRowShelf(
          row: ready,
          title: 'My requests',
          catalog: _catalog,
          now: _now,
          onOpen: scope.open,
        ),
      if (events.isNotEmpty)
        PhoneLiveEventsShelf(
          events: events,
          catalog: _catalog,
          now: _now,
          onAllChannels: () => scope.select(PhoneDestination.live),
          onOpen: (event) {
            final now = DateTime.now();
            if (_live?.isFresh(now) == true && event.isCurrent(now)) {
              scope.play(event.channel);
            }
          },
        ),
      CollectionsHomeShelf(
        key: const ValueKey('collections'),
        catalog: _catalog,
        mobile: true,
        onOpen: scope.open,
        revision: _load,
        onBrowseAll: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => CollectionsScreen(
              catalog: _catalog,
              mobile: true,
              onOpen: scope.open,
              onBack: () => Navigator.of(context).pop(),
            ),
          ),
        ),
      ),
      if (_loadingRows && _feed == null)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: Phone.gutter),
          child: LinearProgressIndicator(),
        ),
      if (_homeError != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Phone.gutter),
          child: Align(
            alignment: Alignment.centerLeft,
            child: PillButton(
              label: 'Retry Home rows',
              onPressed: () => unawaited(_loadRows()),
            ),
          ),
        ),
      for (final id in _order.ids)
        if (mixed[id] case final row?)
          switch (row) {
            _PersonalRow(:final row) => PhoneHomeRowShelf(
              key: ValueKey(id),
              row: row,
              catalog: _catalog,
              now: _now,
              onOpen: scope.open,
            ),
            _LibraryRow(:final shelf) => PhoneShelf(
              key: ValueKey(id),
              title: shelf.title,
              items: shelf.items,
              landscape: shelf.landscape,
              catalog: _catalog,
              onOpen: scope.open,
            ),
            _GeneratedRow(:final row) => shelf(
              row.title,
              row.items,
              key: ValueKey(id),
            ),
          },
      if (!_mixPrepared || _catalog.isPreview)
        for (final (id, row) in _browseRows)
          if (!_order.ids.contains(id) && row is _LibraryRow)
            shelf(
              row.shelf.title,
              row.shelf.items,
              key: ValueKey(id),
              landscape: row.shelf.landscape,
            ),
      if (_mixPrepared &&
          !_loading &&
          !_catalog.isPreview &&
          _catalog.client != null &&
          _discovery.hasMore)
        Center(
          child: Column(
            children: [
              if (_discoveryLoading) const CircularProgressIndicator(),
              if (_discoveryError != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    _discoveryError!,
                    style: Zoro.font(14, color: Zoro.muted),
                  ),
                ),
              if (!_discoveryLoading)
                PillButton(
                  label: _discoveryError == null ? 'Load more' : 'Try again',
                  onPressed: () => unawaited(_loadDiscovery()),
                ),
            ],
          ),
        ),
      if (!_loading && _failure == null && shelvesEmpty)
        const PhoneStatus(
          title: 'Your library is ready for its first title',
          detail: 'Media added to your Jellyfin server will appear here.',
        ),
    ];
    return Scaffold(
      backgroundColor: Zoro.background,
      body: RefreshIndicator(
        color: Zoro.jade,
        onRefresh: _reloadAll,
        child: ListView.separated(
          controller: _scroll,
          padding: EdgeInsets.only(
            top: media.padding.top + (_catalog.isPreview ? 22 : 8),
            bottom: media.padding.bottom + 24,
          ),
          itemCount: children.length,
          findChildIndexCallback: (key) {
            final index = children.indexWhere((child) => child.key == key);
            return index < 0 ? null : index * 2;
          },
          separatorBuilder: (_, _) => const SizedBox(height: 28),
          itemBuilder: (_, i) => children[i],
        ),
      ),
    );
  }
}

/// The featured banner (Apple `HeroView`): poster art on phones, a wide
/// backdrop on tablets, with Play/Resume, details and favorite.
class PhoneHero extends StatelessWidget {
  const PhoneHero({super.key, required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final scope = PhoneScope.of(context);
    final window = PhoneWindow.of(context);
    final wide = window.wide;
    final sideways = window.landscapePhone;
    final banner = wide || sideways;
    final catalog = scope.catalog;
    return Semantics(
      container: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(wide ? 20 : 18),
        child: SizedBox(
          height: window.heroHeight,
          child: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                onTap: () => scope.open(item),
                child: Artwork(
                  url: catalog.artwork(
                    item,
                    landscape: banner,
                    width: banner ? 1600 : 900,
                  ),
                  headers: catalog.imageHeaders,
                  title: item.displayTitle,
                  seed: item.id,
                ),
              ),
              if (banner)
                const IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Color(0xA6000000), Colors.transparent],
                      ),
                    ),
                  ),
                ),
              const IgnorePointer(
                child: DecoratedBox(
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
              ),
              Padding(
                padding: EdgeInsets.all(
                  wide
                      ? 32
                      : sideways
                      ? 20
                      : 24,
                ),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: banner ? 620 : double.infinity,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.name,
                          maxLines: sideways ? 1 : 2,
                          overflow: TextOverflow.ellipsis,
                          style: Zoro.font(
                            wide
                                ? 48
                                : sideways
                                ? 30
                                : 36,
                            weight: FontWeight.w700,
                          ).copyWith(height: 1.1),
                        ),
                        const SizedBox(height: 14),
                        PhoneMetadataLine(item),
                        if (wide && item.plainOverview != null) ...[
                          const SizedBox(height: 14),
                          Text(
                            item.plainOverview!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Zoro.font(18, color: Zoro.muted),
                          ),
                        ],
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            PillButton(
                              white: true,
                              icon: Icons.play_arrow_rounded,
                              label: item.resumeTicks > 0 ? 'Resume' : 'Play',
                              onPressed: () => scope.play(
                                item,
                                startTicks: item.resumeTicks,
                              ),
                            ),
                            const SizedBox(width: 12),
                            RoundIconButton(
                              icon: Icons.info_outline_rounded,
                              label: 'Details for ${item.name}',
                              onPressed: () => scope.open(item),
                            ),
                            const SizedBox(width: 12),
                            PhoneFavoriteButton(item: item),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Heart toggle that saves to the server (Apple `FavoriteButton`).
class PhoneFavoriteButton extends StatefulWidget {
  const PhoneFavoriteButton({
    super.key,
    required this.item,
    this.fill,
    this.labeled = false,
  });

  final MediaItem item;
  final Color? fill;
  final bool labeled;

  @override
  State<PhoneFavoriteButton> createState() => _PhoneFavoriteButtonState();
}

class _PhoneFavoriteButtonState extends State<PhoneFavoriteButton> {
  bool? _favorite;
  bool _busy = false;

  bool get _value => _favorite ?? widget.item.userData?.isFavorite ?? false;

  @override
  void didUpdateWidget(PhoneFavoriteButton old) {
    super.didUpdateWidget(old);
    if (old.item.id != widget.item.id) _favorite = null;
  }

  Future<void> _toggle() async {
    if (_busy) return;
    final catalog = PhoneScope.of(context).catalog;
    final next = !_value;
    setState(() {
      _busy = true;
      _favorite = next;
    });
    try {
      final saved = await catalog.setFavorite(widget.item, next);
      if (mounted) setState(() => _favorite = saved);
    } catch (_) {
      if (mounted) {
        setState(() => _favorite = !next);
        showPhoneMessage(context, 'Favorites couldn’t be updated. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => widget.labeled
      ? PillButton(
          label: _value ? 'Favorited' : 'Favorite',
          icon: _value ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          onPressed: _busy ? null : _toggle,
        )
      : RoundIconButton(
          icon: _value ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          label: _value ? 'Remove from favorites' : 'Add to favorites',
          color: _value ? Zoro.jade : Zoro.text,
          fill: widget.fill ?? const Color(0x14FFFFFF),
          onPressed: _busy ? null : _toggle,
        );
}
