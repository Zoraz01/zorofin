import 'dart:async';

import 'package:flutter/material.dart';
import '../ui/widgets/request_progress.dart';

import '../core/preferences.dart';
import '../core/requests.dart';
import '../extras_state.dart';
import '../ui/screens/requests_screen.dart'
    show RequestPoster, requestErrorMessage, requestPreviewTitles;
import '../ui/theme.dart';
import 'phone_connect.dart' show confirmPhone;
import 'phone_detail.dart' show showPhoneChoices;
import 'phone_scope.dart';
import 'phone_theme.dart';
import 'phone_widgets.dart';

/// Requests (Apple `RequestsView` on iPhone): search, Discover and My
/// requests, discovery rows or a paged grid, and request activity.
class PhoneRequestsScreen extends StatefulWidget {
  const PhoneRequestsScreen({super.key});

  @override
  State<PhoneRequestsScreen> createState() => _PhoneRequestsScreenState();
}

class _PhoneRequestsScreenState extends State<PhoneRequestsScreen> {
  static const _categories = [
    ('trending', 'Trending'),
    ('movies', 'Movies'),
    ('tv', 'TV shows'),
    ('upcoming', 'Coming soon'),
  ];
  static const _filters = [
    ('all', 'All statuses'),
    ('pending', 'Pending approval'),
    ('approved', 'Requested'),
    ('processing', 'Processing'),
    ('available', 'Available'),
  ];

  final _query = TextEditingController();
  final _scroll = ScrollController();
  String _category = 'discover';
  bool _mine = true;
  String _filter = 'all';
  int _page = 1;
  int _totalPages = 1;
  List<RequestTitle> _titles = [];
  List<RequestDiscoveryRow> _discovery = [];
  List<RequestActivityItem> _activity = [];
  RequestQueue? _queue;
  List<RequestActivityItem> _personal = [];
  RequestQueue? _personalQueue;
  List<RequestJournalEntry> _pending = [];
  String? _error;
  bool _loading = false;
  int _load = 0;
  Timer? _debounce;
  Timer? _refresh;
  ExtrasState? _extrasState;

  ExtrasState get _extras => _extrasState!;
  String get _text => _query.text.trim();
  bool get _activityMode => _category == 'activity' && _text.isEmpty;
  bool get _discoveryMode => _category == 'discover' && _text.isEmpty;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final extras = PhoneScope.of(context).extras;
    if (extras != _extrasState) {
      _extrasState = extras;
      unawaited(_reload());
    }
  }

  @override
  void initState() {
    super.initState();
    _refresh = Timer.periodic(const Duration(seconds: 30), (_) {
      if ((_activityMode || _discoveryMode) && !_extras.isPreview) {
        unawaited(_reload(quiet: true));
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _refresh?.cancel();
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _showActivity() {
    _query.clear();
    _set(() {
      _category = 'activity';
      _mine = true;
    });
  }

  void _set(VoidCallback change) {
    setState(() {
      change();
      _page = 1;
    });
    unawaited(_reload());
  }

  void _goToPage(int page) {
    setState(() => _page = page);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    unawaited(_reload());
  }

  void _queryChanged(String _) {
    _debounce?.cancel();
    setState(() {});
    _debounce = Timer(const Duration(milliseconds: 350), () {
      setState(() => _page = 1);
      unawaited(_reload());
    });
  }

  List<RequestTitle> _visible(List<RequestTitle> titles) =>
      Preferences.valueOf(context).hideAvailableRequests
      ? titles.where((t) => t.mediaInfo?.status != 5).toList()
      : titles;

  Future<void> _reload({bool quiet = false}) async {
    final load = ++_load;
    if (_extras.isPreview) {
      setState(() {
        _titles = requestPreviewTitles;
        _discovery = [
          for (final s in RequestDiscoverySection.values)
            RequestDiscoveryRow(s, requestPreviewTitles),
        ];
        _loading = false;
      });
      return;
    }
    final client = _extras.catalog.client;
    final service = _extras.requestService;
    if (client == null || service == null || !_extras.requestsEnabled) return;
    final activityMode = _activityMode;
    final discoveryMode = _discoveryMode;
    final category = _category == 'activity' || _category == 'discover'
        ? 'trending'
        : _category;
    final query = _text;
    final page = _page;
    setState(() {
      _loading = true;
      _error = null;
      if (!quiet) {
        _titles = [];
        _activity = [];
        _queue = null;
        _discovery = [];
      }
    });
    try {
      if (!await client.requestAccessAvailable()) {
        throw RequestFailure.unavailable;
      }
      final pending = service.journal.entries();
      if (discoveryMode) {
        final personal = client
            .requestActivity()
            .then<RequestActivityPage?>((p) => p)
            .catchError((_) => null);
        final rows = await client.requestDiscovery(
          includeRecommendations: _extras.features.support,
          onRow: (row) {
            if (!mounted || load != _load) return;
            setState(() {
              _discovery = [
                ..._discovery.where((r) => r.section != row.section),
                row,
              ]..sort((a, b) => a.section.index.compareTo(b.section.index));
            });
          },
        );
        final mine = await personal;
        RequestQueue? queue;
        if (mine != null && mine.requests.isNotEmpty) {
          try {
            queue = await client.requestQueue();
          } catch (_) {}
        }
        if (!mounted || load != _load) return;
        setState(() {
          _discovery = rows;
          _totalPages = 1;
          _personal = [
            for (final r in mine?.requests ?? const <RequestActivityItem>[])
              if (r.kind != null && r.tmdbId != null) r,
          ];
          _personalQueue = queue;
        });
      } else if (activityMode) {
        final result = await client.requestActivity(
          mine: _mine,
          page: page,
          filter: _filter,
        );
        RequestQueue? queue;
        try {
          queue = await client.requestQueue();
        } catch (_) {}
        if (!mounted || load != _load) return;
        setState(() {
          _activity = result.requests;
          _queue = queue;
          _totalPages = (result.totalPages ?? 1).clamp(1, 500);
        });
      } else {
        final result = await client.requestTitles(
          category: category,
          query: query,
          page: page,
        );
        if (!mounted || load != _load) return;
        final seen = <String>{};
        setState(() {
          _titles = [
            for (final t in result.results)
              if (t.id > 0 && t.kind != null && seen.add(t.identity)) t,
          ];
          _totalPages = (result.totalPages ?? 1).clamp(1, 500);
        });
      }
      if (mounted && load == _load) setState(() => _pending = pending);
    } catch (e) {
      if (mounted && load == _load) {
        setState(() => _error = requestErrorMessage(e));
      }
    } finally {
      if (mounted && load == _load) setState(() => _loading = false);
    }
  }

  Future<void> _openTitle(RequestKind kind, int id) async {
    // Section pages sit under the shell's scope, so details see it too.
    final showActivity = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PhoneRequestDetailsScreen(kind: kind, titleId: id),
      ),
    );
    if (!mounted) return;
    if (showActivity == true) {
      _showActivity();
    } else {
      unawaited(_reload(quiet: true));
    }
  }

  Future<void> _chooseCategory() async {
    final choice = await showPhoneChoices<String>(
      context,
      title: 'Browse',
      options: _categories,
      selected: _category,
    );
    if (choice == null) return;
    _query.clear();
    _set(() => _category = choice);
  }

  Future<void> _chooseFilter() async {
    final choice = await showPhoneChoices<String>(
      context,
      title: 'Status',
      options: _filters,
      selected: _filter,
    );
    if (choice != null) _set(() => _filter = choice);
  }

  bool get _isEmpty => _activityMode
      ? _activity.isEmpty
      : _discoveryMode
      ? _discovery.isEmpty
      : _titles.isEmpty;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final available = _extras.requestsEnabled || _extras.isPreview;
    final header = Padding(
      padding: EdgeInsets.fromLTRB(
        Phone.gutter,
        media.padding.top + 12,
        Phone.gutter,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Requests', style: Zoro.font(28, weight: FontWeight.w700)),
          if (available) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _query,
              autocorrect: false,
              textInputAction: TextInputAction.search,
              style: Zoro.font(17),
              decoration: InputDecoration(
                hintText: 'Search movies and TV shows',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.cancel_rounded),
                        onPressed: () {
                          _query.clear();
                          _queryChanged('');
                        },
                      ),
              ),
              onChanged: _queryChanged,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'discover', label: Text('Discover')),
                      ButtonSegment(
                        value: 'activity',
                        label: Text('My requests'),
                      ),
                    ],
                    selected: {
                      _category == 'activity' ? 'activity' : 'discover',
                    },
                    onSelectionChanged: (value) {
                      _query.clear();
                      _set(() => _category = value.first);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                RoundIconButton(
                  icon: Icons.tune_rounded,
                  label: 'Browse request categories',
                  onPressed: _chooseCategory,
                ),
              ],
            ),
            if (!_discoveryMode && !_activityMode && _text.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  _categories.firstWhere((c) => c.$1 == _category).$2,
                  style: Zoro.font(20, weight: FontWeight.w700),
                ),
              ),
          ],
        ],
      ),
    );
    final body = <Widget>[];
    if (!available) {
      body.add(
        const PhoneStatus(
          title: 'Requests unavailable',
          detail:
              'This server does not provide Requests. Your library remains available.',
        ),
      );
    } else {
      if (_activityMode) body.addAll(_activityFilters());
      if (_error != null) {
        body.add(
          PhoneStatus(
            title: 'Requests couldn’t load',
            detail: _error,
            icon: Icons.error_outline_rounded,
            action: PillButton(
              label: 'Try again',
              onPressed: () => unawaited(_reload()),
            ),
          ),
        );
      }
      if (_loading && _isEmpty) body.add(const PhoneLoading());
      if (_activityMode) {
        body.addAll(_activityList());
      } else if (_discoveryMode) {
        body.addAll(_personalPreview());
        body.addAll(_discoveryRows());
      } else {
        body.add(_grid());
      }
      if (!_loading && _error == null) body.addAll(_emptyAndPaging());
      if (_extras.isPreview) {
        body.add(
          Padding(
            padding: const EdgeInsets.all(20),
            child: Center(
              child: Text(
                'Preview only · Requests are never sent',
                style: Zoro.font(14, color: Zoro.muted),
              ),
            ),
          ),
        );
      }
    }
    return Scaffold(
      backgroundColor: Zoro.background,
      body: RefreshIndicator(
        color: Zoro.jade,
        onRefresh: _reload,
        child: ListView(
          controller: _scroll,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.only(bottom: media.padding.bottom + 16),
          children: [header, const SizedBox(height: 16), ...body],
        ),
      ),
    );
  }

  List<Widget> _emptyAndPaging() => [
    if (!_discoveryMode &&
        (_activityMode ? _activity.isEmpty : _visible(_titles).isEmpty))
      PhoneStatus(
        title: _activityMode ? 'No requests here yet' : 'No titles found',
        detail: _activityMode
            ? 'Request a title to follow its progress here.'
            : Preferences.valueOf(context).hideAvailableRequests
            ? 'Try the next page, or turn off Hide available titles in Display settings.'
            : 'Try another title or browse a different section.',
      ),
    if (_discoveryMode &&
        !_discovery.any((r) => r.failed || _visible(r.titles).isNotEmpty))
      const PhoneStatus(
        title: 'No discovery titles yet',
        detail: 'Search for a title or browse Movies and TV shows.',
      ),
    if (!_discoveryMode && _totalPages > 1)
      Padding(
        padding: const EdgeInsets.only(top: 20),
        child: Column(
          children: [
            Text(
              'Page $_page of $_totalPages',
              style: Zoro.font(14, color: Zoro.muted),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                PillButton(
                  label: 'Previous',
                  onPressed: _page > 1 ? () => _goToPage(_page - 1) : null,
                ),
                const SizedBox(width: 12),
                PillButton(
                  label: 'Next',
                  onPressed: _page < _totalPages
                      ? () => _goToPage(_page + 1)
                      : null,
                ),
              ],
            ),
          ],
        ),
      ),
  ];

  List<Widget> _activityFilters() => [
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: Phone.gutter),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ChoiceChip(
            label: const Text('Mine'),
            selected: _mine,
            onSelected: (_) => _set(() => _mine = true),
          ),
          ChoiceChip(
            label: const Text('All activity'),
            selected: !_mine,
            onSelected: (_) => _set(() => _mine = false),
          ),
          ActionChip(
            avatar: const Icon(Icons.filter_list_rounded, size: 18),
            label: Text(_filters.firstWhere((f) => f.$1 == _filter).$2),
            onPressed: _chooseFilter,
          ),
        ],
      ),
    ),
    if (!_mine)
      Padding(
        padding: const EdgeInsets.fromLTRB(Phone.gutter, 8, Phone.gutter, 0),
        child: Text(
          'Activity your server allows this account to see.',
          style: Zoro.font(13, color: Zoro.muted),
        ),
      ),
    const SizedBox(height: 14),
  ];

  List<Widget> _activityList() => [
    for (final entry in _pending.where((e) => e.receiptId == null))
      Padding(
        padding: const EdgeInsets.fromLTRB(Phone.gutter, 0, Phone.gutter, 10),
        child: PillButton(
          label:
              'Review unconfirmed ${entry.intent.kind == RequestKind.tv ? 'show' : 'movie'} request',
          icon: Icons.error_outline_rounded,
          onPressed: () => _openTitle(entry.intent.kind, entry.intent.id),
        ),
      ),
    for (final item in _activity)
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Phone.gutter),
        child: _ActivityRow(
          item: item,
          detail: _queue?.label(item),
          requestedBy: _mine ? null : item.requestedBy,
          onPressed: item.kind == null || item.tmdbId == null
              ? null
              : () => _openTitle(item.kind!, item.tmdbId!),
        ),
      ),
  ];

  List<Widget> _personalPreview() {
    if (_personal.isEmpty) return const [];
    return [
      SectionHeader(
        'Your requests',
        trailing: TextButton(
          style: TextButton.styleFrom(foregroundColor: Zoro.jade),
          onPressed: _showActivity,
          child: const Text('See all'),
        ),
      ),
      const SizedBox(height: 6),
      for (final item in _personal.take(3))
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Phone.gutter),
          child: _ActivityRow(
            item: item,
            compact: true,
            detail: _personalQueue?.label(item),
            onPressed: () => _openTitle(item.kind!, item.tmdbId!),
          ),
        ),
      const SizedBox(height: 20),
    ];
  }

  List<Widget> _discoveryRows() {
    final width = PhoneRequestCard.widthFor(context);
    return [
      for (final row in _discovery)
        if (row.failed || _visible(row.titles).isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionHeader(
                  row.section.title,
                  trailing: row.section == RequestDiscoverySection.recommended
                      ? null
                      : IconButton(
                          tooltip: 'See all ${row.section.title.toLowerCase()}',
                          color: Zoro.jade,
                          icon: const Icon(Icons.chevron_right_rounded),
                          onPressed: () => _set(
                            () => _category = switch (row.section) {
                              RequestDiscoverySection.movies => 'movies',
                              RequestDiscoverySection.tv => 'tv',
                              RequestDiscoverySection.upcoming => 'upcoming',
                              _ => 'trending',
                            },
                          ),
                        ),
                ),
                const SizedBox(height: 10),
                if (row.failed)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Phone.gutter,
                    ),
                    child: PillButton(
                      label: 'Couldn’t load this row. Retry',
                      onPressed: () => unawaited(_reload()),
                    ),
                  )
                else
                  SizedBox(
                    height: PhoneRequestCard.heightFor(context, width),
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                        horizontal: Phone.gutter,
                      ),
                      itemCount: _visible(row.titles).length,
                      separatorBuilder: (_, _) => const SizedBox(width: 14),
                      itemBuilder: (context, i) {
                        final title = _visible(row.titles)[i];
                        return PhoneRequestCard(
                          title: title,
                          width: width,
                          onPressed: () => _openTitle(title.kind!, title.id),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
    ];
  }

  Widget _grid() => LayoutBuilder(
    builder: (context, constraints) {
      final columns = PhoneWindow.of(context).gridColumns();
      const gap = 12.0;
      final width =
          (constraints.maxWidth - Phone.gutter * 2 - gap * (columns - 1)) /
          columns;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: Phone.gutter),
        child: Wrap(
          spacing: gap,
          runSpacing: 18,
          children: [
            for (final title in _visible(_titles))
              PhoneRequestCard(
                title: title,
                width: width,
                onPressed: () => _openTitle(title.kind!, title.id),
              ),
          ],
        ),
      );
    },
  );
}

/// A requestable title: TMDB poster, name, year and kind, and status.
class PhoneRequestCard extends StatelessWidget {
  const PhoneRequestCard({
    super.key,
    required this.title,
    required this.width,
    required this.onPressed,
  });

  final RequestTitle title;
  final double width;
  final VoidCallback onPressed;

  static double widthFor(BuildContext context) =>
      (PhoneWindow.of(context).tablet ? 180.0 : 132.0) *
      Preferences.valueOf(context).posterScale;

  static double heightFor(BuildContext context, double width) =>
      width * 1.5 + 8 + 62 * MediaQuery.textScalerOf(context).scale(1);

  @override
  Widget build(BuildContext context) {
    final caption = [
      title.year,
      title.kind == RequestKind.tv ? 'TV show' : 'Movie',
    ].where((s) => s.isNotEmpty).join(' · ');
    return Semantics(
      button: true,
      label: '${title.displayTitle}, ${title.status()}',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: width,
                  height: width * 1.5,
                  child: RequestPoster(
                    url: RequestArtwork.path(title.posterPath),
                    title: title.displayTitle,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                title.displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Zoro.font(14, weight: FontWeight.w600),
              ),
              Text(
                caption,
                maxLines: 1,
                style: Zoro.font(12, color: Zoro.muted),
              ),
              if (title.mediaInfo != null)
                Text(
                  title.status(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Zoro.font(12, color: Zoro.jade),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({
    required this.item,
    required this.onPressed,
    this.detail,
    this.requestedBy,
    this.compact = false,
  });

  final RequestActivityItem item;
  final VoidCallback? onPressed;
  final String? detail;
  final String? requestedBy;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final title = item.title ?? 'Untitled';
    final status = compact ? (detail ?? item.statusLabel) : item.statusLabel;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Semantics(
        button: onPressed != null,
        label: '$title, $status',
        excludeSemantics: true,
        child: Material(
          color: compact ? Colors.transparent : Zoro.panel,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(7),
                    child: SizedBox(
                      width: compact ? 48 : 60,
                      height: compact ? 72 : 90,
                      child: RequestPoster(
                        url: RequestArtwork.absolute(item.posterUrl),
                        title: title,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Zoro.font(16, weight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(status, style: Zoro.font(14, color: Zoro.jade)),
                        if (!compact && detail != null && detail != status)
                          Text(
                            detail!,
                            style: Zoro.font(13, color: Zoro.muted),
                          ),
                        if (requestedBy != null)
                          Text(
                            requestedBy!,
                            style: Zoro.font(13, color: Zoro.muted),
                          ),
                      ],
                    ),
                  ),
                  Icon(
                    item.statusLabel == 'Available' && compact
                        ? Icons.play_arrow_rounded
                        : Icons.chevron_right_rounded,
                    color: Zoro.muted,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One title in Requests (Apple `RequestDetailsView` on iPhone): status,
/// season groups and one confirmed request. Pops with true for View request
/// activity.
class PhoneRequestDetailsScreen extends StatefulWidget {
  const PhoneRequestDetailsScreen({
    super.key,
    required this.kind,
    required this.titleId,
  });

  final RequestKind kind;
  final int titleId;

  @override
  State<PhoneRequestDetailsScreen> createState() =>
      _PhoneRequestDetailsScreenState();
}

class _PhoneRequestDetailsScreenState extends State<PhoneRequestDetailsScreen> {
  RequestTitle? _title;
  RequestSeasonSettings? _settings;
  RequestQuota? _quota;
  Set<int> _seasons = {};
  List<RequestJournalEntry> _entries = [];
  RequestActivityItem? _activity;
  String? _download;
  double? _downloadProgress;
  bool _loading = true;
  bool _updating = false;
  bool _sending = false;
  String? _error;
  String? _outcome;
  int? _receiptStatus;
  bool _blocked = false;
  bool _unconfirmed = false;
  bool _initializedChoices = false;
  int _load = 0;
  Timer? _timer;
  ExtrasState? _extrasState;

  ExtrasState get _extras => _extrasState!;
  bool get _tv => widget.kind == RequestKind.tv;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final extras = PhoneScope.of(context).extras;
    if (extras != _extrasState) {
      _extrasState = extras;
      unawaited(_reload());
    }
  }

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!_sending && !_extras.isPreview) unawaited(_reload(quiet: true));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  RequestIntent get _intent => RequestIntent(
    kind: widget.kind,
    id: widget.titleId,
    seasons: _seasons,
    tvdbId: _title?.tvdbId,
  );

  bool get _canSend {
    final title = _title;
    if (_loading ||
        _sending ||
        _blocked ||
        _extras.isPreview ||
        title == null ||
        !_extras.requestsEnabled) {
      return false;
    }
    if (!_tv &&
        (title.mediaInfo?.status4k == 5 ||
            (title.mediaInfo?.requests ?? []).any(
              (r) => const [1, 2].contains(r.status ?? 0),
            ))) {
      return false;
    }
    try {
      _intent.validate(title, settings: _settings, quota: _quota);
      return true;
    } catch (_) {
      return false;
    }
  }

  bool get _movieCanBeRequested {
    final title = _title;
    if (title == null ||
        _tv ||
        _entries.isNotEmpty ||
        _receiptStatus != null ||
        title.mediaInfo?.status4k == 5) {
      return false;
    }
    try {
      RequestIntent(
        kind: RequestKind.movie,
        id: widget.titleId,
      ).validate(title);
      return true;
    } catch (_) {
      return false;
    }
  }

  List<RequestSeason> get _visibleSeasons {
    final minimum = _settings?.enableSpecialEpisodes == true ? 0 : 1;
    return [
      for (final s in _title?.seasons ?? const <RequestSeason>[])
        if (s.seasonNumber >= minimum && (s.episodeCount ?? 0) > 0) s,
    ]..sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));
  }

  RequestSeasonState _state(RequestSeason season) {
    final title = _title;
    if (title == null) return RequestSeasonState.unknown;
    final server = title.requestSeasonState(season.seasonNumber);
    if (server.requestable &&
        _entries.any(
          (e) => (e.intent.seasons ?? []).contains(season.seasonNumber),
        )) {
      return _receiptStatus == 1
          ? RequestSeasonState.pendingApproval
          : RequestSeasonState.requested;
    }
    return server;
  }

  List<RequestSeason> get _missing =>
      _visibleSeasons.where((s) => _state(s).requestable).toList();

  String get _statusLabel {
    final title = _title;
    if (_unconfirmed) return 'Confirmation pending';
    if (_activity?.statusLabel == 'Available') return 'Ready to watch';
    if (_download != null) return _download!;
    if (_activity != null) return _activity!.statusLabel;
    if (_receiptStatus == 1) return 'Awaiting approval';
    if (title != null &&
        (title.mediaInfo?.status == 5 || title.mediaInfo?.status4k == 5)) {
      return 'Ready to watch';
    }
    if (_outcome != null) return _outcome!;
    return title?.status() ?? 'Status unavailable';
  }

  bool get _showsStatus =>
      _unconfirmed ||
      _outcome != null ||
      _activity != null ||
      (_title != null && _title!.status() != 'Not requested') ||
      _title?.mediaInfo?.status4k == 5;

  void _updateSelection() {
    final eligible = _missing.map((s) => s.seasonNumber).toSet();
    if (!_initializedChoices || _settings?.partialRequestsEnabled != true) {
      _seasons = eligible;
    } else {
      _seasons = _seasons.intersection(eligible);
    }
    _initializedChoices = true;
  }

  Future<void> _reload({bool quiet = false}) async {
    if (_updating || _sending) return;
    if (_extras.isPreview) {
      setState(() {
        _title = requestPreviewTitles
            .where((t) => t.id == widget.titleId)
            .firstOrNull;
        _settings = const RequestSeasonSettings(partialRequestsEnabled: true);
        _loading = false;
      });
      return;
    }
    final client = _extras.catalog.client;
    final service = _extras.requestService;
    if (client == null || service == null || !_extras.requestsEnabled) {
      setState(() {
        _loading = false;
        _error = RequestFailure.unavailable.message;
      });
      return;
    }
    final load = ++_load;
    setState(() {
      _updating = true;
      _loading = !quiet && _title == null;
    });
    try {
      final results = await Future.wait([
        client.requestTitle(widget.kind, widget.titleId),
        client.requestQuota(),
      ]);
      final fresh = results[0] as RequestTitle;
      final quota = results[1] as RequestQuota;
      final settings = _tv ? await client.requestSeasonSettings() : null;
      await service.journal.reconcile(fresh);
      final saved = service.journal
          .entries()
          .where(
            (e) =>
                e.intent.id == widget.titleId && e.intent.kind == widget.kind,
          )
          .toList();
      RequestActivityItem? personal;
      String? queueLabel;
      double? queueProgress;
      try {
        final page = await client.requestActivity();
        personal = page.requests
            .where((r) => r.tmdbId == widget.titleId && r.kind == widget.kind)
            .firstOrNull;
        if (personal != null) {
          final download = (await client.requestQueue()).download(personal);
          queueLabel = download?.label;
          queueProgress = download?.progress;
        }
      } catch (_) {}
      if (!mounted || load != _load) return;
      setState(() {
        _title = fresh;
        _quota = quota;
        _settings = settings;
        _entries = saved;
        _activity = personal;
        _download = queueLabel;
        _downloadProgress = queueProgress;
        _error = null;
        _blocked = saved.any((e) => e.receiptId == null);
        _unconfirmed = _blocked;
        if (_blocked) {
          _outcome = null;
        } else if (saved.isNotEmpty) {
          _outcome = 'Request received';
        } else {
          _outcome = null;
          _receiptStatus = null;
        }
        _updateSelection();
      });
    } catch (e) {
      if (mounted && load == _load) {
        setState(() {
          _error = requestErrorMessage(e);
          _blocked = true;
        });
      }
    } finally {
      if (mounted && load == _load) {
        setState(() {
          _updating = false;
          _loading = false;
        });
      }
    }
  }

  Future<void> _confirmSend() async {
    final title = _title;
    if (title == null || !_canSend) return;
    final seasons = (_seasons.toList()..sort())
        .map((n) => n == 0 ? 'Specials' : 'Season $n')
        .join(', ');
    final ok = await confirmPhone(
      context,
      title: 'Request ${title.displayTitle}?',
      action: 'Send request',
      detail: _tv ? seasons : 'Your server manages quality and approval.',
      destructive: false,
    );
    if (ok) await _send();
  }

  Future<void> _send() async {
    final service = _extras.requestService;
    if (!_canSend || service == null) return;
    _load++;
    setState(() {
      _updating = false;
      _sending = true;
      _error = null;
    });
    try {
      final receipt = await service.submit(_intent);
      if (!mounted) return;
      setState(() {
        _blocked = true;
        _receiptStatus = receipt.status;
        _outcome = 'Request received';
        _sending = false;
      });
      _extras.requestSent();
      await _reload(quiet: true);
    } catch (e) {
      if (!mounted) return;
      final unconfirmed = e == RequestFailure.unconfirmed;
      setState(() {
        _blocked = true;
        _unconfirmed = unconfirmed;
        _sending = false;
      });
      await _reload(quiet: true);
      if (mounted && !unconfirmed) {
        setState(() => _error = requestErrorMessage(e));
      }
    }
  }

  Future<void> _allowRetry() async {
    final service = _extras.requestService;
    if (service == null || _sending) return;
    final ok = await confirmPhone(
      context,
      title: 'Check Activity before trying again',
      action: 'I checked · Allow another attempt',
      detail:
          'The first request may have reached the server. Continue only after checking Activity or confirming with your server owner. Nothing is resent automatically.',
    );
    if (!ok || !mounted) return;
    setState(() => _sending = true);
    try {
      await service.allowAnotherAttempt(widget.kind, widget.titleId);
      if (!mounted) return;
      setState(() {
        _unconfirmed = false;
        _blocked = false;
        _outcome = null;
        _sending = false;
      });
      await _reload();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = requestErrorMessage(e);
          _sending = false;
        });
      }
    }
  }

  Future<void> _openLibrary(String id, {int? season}) async {
    final client = _extras.catalog.client;
    if (client == null) return;
    final open = PhoneScope.of(context).open;
    try {
      var item = await client.item(id);
      if (season != null && item.isSeries) {
        final seasons = await _extras.catalog.seasons(id);
        item =
            seasons.where((s) => s.indexNumber == season).firstOrNull ?? item;
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      open(item);
    } catch (e) {
      if (mounted) setState(() => _error = requestErrorMessage(e));
    }
  }

  String? _libraryId(RequestSeason season) {
    final title = _title;
    if (title == null) return null;
    return title.seasonState(season.seasonNumber) ==
            RequestSeasonState.available
        ? title.mediaInfo?.jellyfinMediaId
        : title.mediaInfo?.jellyfinMediaId4k;
  }

  @override
  Widget build(BuildContext context) {
    final title = _title;
    final media = MediaQuery.of(context);
    return Scaffold(
      backgroundColor: Zoro.background,
      appBar: AppBar(
        backgroundColor: Zoro.background,
        surfaceTintColor: Colors.transparent,
        title: Text(
          title?.displayTitle ?? 'Requests',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Zoro.font(17, weight: FontWeight.w600),
        ),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          Phone.gutter,
          8,
          Phone.gutter,
          media.padding.bottom + 24,
        ),
        children: [
          if (_loading) const PhoneLoading(label: 'Loading title…'),
          if (title != null)
            ..._titleContent(title)
          else if (_error != null && !_loading)
            PhoneStatus(
              title: 'Title unavailable',
              detail: _error,
              icon: Icons.error_outline_rounded,
              action: PillButton(label: 'Try again', onPressed: _reload),
            ),
        ],
      ),
    );
  }

  List<Widget> _titleContent(RequestTitle title) {
    final libraryId =
        title.mediaInfo?.jellyfinMediaId ?? title.mediaInfo?.jellyfinMediaId4k;
    final limit = _quota?.limit(widget.kind);
    final remaining = limit?.remaining;
    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 120,
              height: 180,
              child: RequestPoster(
                url: RequestArtwork.path(title.posterPath),
                title: title.displayTitle,
              ),
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title.displayTitle,
                  style: Zoro.font(24, weight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Text(
                  [
                    title.year,
                    _tv ? 'TV show' : 'Movie',
                  ].where((s) => s.isNotEmpty).join(' · '),
                  style: Zoro.font(15, color: Zoro.muted),
                ),
              ],
            ),
          ),
        ],
      ),
      if (_movieCanBeRequested) ...[
        const SizedBox(height: 18),
        _requestButton(),
      ],
      const SizedBox(height: 20),
      if (_showsStatus) ...[_status(), const SizedBox(height: 20)],
      if (_error != null) ...[
        Text(_error!, style: Zoro.font(15, color: Zoro.muted)),
        if (!_unconfirmed)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: PillButton(label: 'Try again', onPressed: _reload),
          ),
        const SizedBox(height: 20),
      ],
      if (_tv) ..._seasonGroups(),
      if (_tv && _missing.isNotEmpty) ...[
        _requestButton(),
        const SizedBox(height: 16),
      ],
      if (_unconfirmed)
        PillButton(
          label: 'Review another attempt',
          onPressed: _sending || _updating ? null : _allowRetry,
        ),
      if (remaining != null)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            '$remaining ${_tv ? 'seasons' : 'movies'} remaining in your ${limit?.days ?? 7}-day request limit.',
            style: Zoro.font(13, color: Zoro.muted),
          ),
        ),
      if (libraryId != null &&
          (!_tv ||
              !_visibleSeasons.any(
                (s) => _state(s) == RequestSeasonState.available,
              )))
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: PillButton(
            label: 'Open in library',
            icon: Icons.play_arrow_rounded,
            expand: true,
            onPressed: () => _openLibrary(libraryId),
          ),
        ),
      if (title.overview case final overview? when overview.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 20),
          child: Text(
            overview,
            style: Zoro.font(16, color: Zoro.muted).copyWith(height: 1.45),
          ),
        ),
    ];
  }

  Widget _requestButton() {
    final count = _seasons.length;
    final label = _sending
        ? 'Sending…'
        : _tv
        ? 'Request $count ${count == 1 ? 'season' : 'seasons'}'
        : 'Request movie';
    return PillButton(
      label: label,
      icon: Icons.add_rounded,
      primary: true,
      expand: true,
      busy: _sending,
      onPressed: _canSend ? _confirmSend : null,
    );
  }

  Widget _status() {
    final ready = _statusLabel == 'Ready to watch';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Zoro.panel,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _unconfirmed
                    ? Icons.error_outline_rounded
                    : ready
                    ? Icons.check_circle_outline_rounded
                    : Icons.schedule_rounded,
                color: _unconfirmed ? const Color(0xFFFFD54F) : Zoro.jade,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _statusLabel,
                      style: Zoro.font(17, weight: FontWeight.w600),
                    ),
                    if (_statusLabel.startsWith('Downloading')) ...[
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        value: _downloadProgress?.isFinite == true
                            ? (_downloadProgress! / 100).clamp(0, 1)
                            : null,
                      ),
                    ],
                    if (!_unconfirmed &&
                        (_activity != null || _receiptStatus != null))
                      Text(
                        ready
                            ? 'Ready to watch in your library.'
                            : _statusLabel.startsWith('Downloading')
                            ? 'Downloading to your server. It will be added to your library when ready.'
                            : 'Your server is processing this request. Refresh to check its progress.',
                        style: Zoro.font(14, color: Zoro.muted),
                      ),
                    if (_unconfirmed)
                      Text(
                        'The server may have received your request. We’ll keep checking; nothing is resent automatically.',
                        style: Zoro.font(14, color: Zoro.muted),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (!_unconfirmed) RequestProgress(status: _statusLabel),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: Zoro.jade),
            icon: const Icon(Icons.arrow_forward_rounded),
            label: const Text('View request activity'),
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ),
      ],
    );
  }

  List<Widget> _seasonGroups() {
    final seasons = _visibleSeasons;
    final available = seasons
        .where((s) => _state(s) == RequestSeasonState.available)
        .toList();
    final progress = seasons
        .where(
          (s) => const [
            RequestSeasonState.pendingApproval,
            RequestSeasonState.requested,
          ].contains(_state(s)),
        )
        .toList();
    final unknown = seasons
        .where((s) => _state(s) == RequestSeasonState.unknown)
        .toList();
    final missing = _missing;
    final partial = _settings?.partialRequestsEnabled == true;
    return [
      if (available.isNotEmpty) ...[
        _heading('Available to watch', available.length),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final season in available)
              if (_libraryId(season) case final id?)
                PillButton(
                  label: season.displayName,
                  icon: Icons.play_arrow_rounded,
                  onPressed: () =>
                      _openLibrary(id, season: season.seasonNumber),
                )
              else
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text('✓ ${season.displayName}', style: Zoro.font(15)),
                ),
          ],
        ),
        const SizedBox(height: 22),
      ],
      if (progress.isNotEmpty) ...[
        _heading('Already requested', progress.length),
        for (final season in progress)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(child: Text(season.displayName, style: Zoro.font(15))),
                Text(
                  _unconfirmed ? 'Confirmation pending' : _state(season).label,
                  style: Zoro.font(15, color: Zoro.muted),
                ),
              ],
            ),
          ),
        const SizedBox(height: 22),
      ],
      if (missing.isNotEmpty) ...[
        _heading('Missing seasons', missing.length),
        if (!partial)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Your server requests all missing seasons together.',
              style: Zoro.font(13, color: Zoro.muted),
            ),
          ),
        for (final season in missing)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            activeColor: Zoro.jade,
            checkColor: Zoro.background,
            value: _seasons.contains(season.seasonNumber),
            title: Text(season.displayName, style: Zoro.font(16)),
            subtitle: _state(season) == RequestSeasonState.partlyAvailable
                ? Text(
                    'Missing episodes',
                    style: Zoro.font(13, color: Zoro.muted),
                  )
                : null,
            onChanged: partial && !_sending && !_loading
                ? (_) => setState(() {
                    if (!_seasons.remove(season.seasonNumber)) {
                      _seasons.add(season.seasonNumber);
                    }
                  })
                : null,
          ),
        const SizedBox(height: 16),
      ],
      if (unknown.isNotEmpty) ...[
        Text(
          'Availability not confirmed',
          style: Zoro.font(16, weight: FontWeight.w600),
        ),
        Text(
          unknown.map((s) => s.displayName).join(', '),
          style: Zoro.font(15, color: Zoro.muted),
        ),
        const SizedBox(height: 16),
      ],
    ];
  }

  Widget _heading(String text, int count) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Expanded(
          child: Text(text, style: Zoro.font(18, weight: FontWeight.w600)),
        ),
        Text('$count', style: Zoro.font(14, color: Zoro.muted)),
      ],
    ),
  );
}
