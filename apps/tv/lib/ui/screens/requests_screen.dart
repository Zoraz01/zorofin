import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/errors.dart';
import '../../core/models.dart';
import '../../core/preferences.dart';
import '../../core/requests.dart';
import '../../extras_state.dart';
import '../theme.dart';
import '../widgets/choice_dialog.dart';
import '../widgets/focusable.dart';
import '../widgets/media_card.dart';
import '../widgets/section_title.dart';
import 'request_details_screen.dart';
import '../widgets/tv_text_field.dart';

/// Fictional request titles for the app preview; nothing is ever sent.
final requestPreviewTitles = [
  for (var i = 1; i <= 12; i++)
    RequestTitle(
      id: i,
      mediaType: i % 3 == 0 ? 'tv' : 'movie',
      title: const [
        'The Last Light',
        'Northbound',
        'Open Water',
        'City Stories',
        'Tideline',
        'Wild Blue',
      ][(i - 1) % 6],
      overview:
          'A fictional title in the Zorofin preview. Connect your server to request real movies and shows.',
      releaseDate: '2026-01-01',
    ),
];

String requestErrorMessage(Object error) => switch (error) {
  RequestFailure f => f.message,
  ClientError e => e.message,
  _ => 'Requests couldn’t load. Try again.',
};

/// Requests (Apple `RequestsView` TV layout): search, Discover and My
/// requests, the category menu, discovery rows or a paged grid, and request
/// activity.
class RequestsScreen extends StatefulWidget {
  const RequestsScreen({super.key, required this.extras, required this.onOpen});

  final ExtrasState extras;
  final ValueChanged<MediaItem> onOpen;

  @override
  State<RequestsScreen> createState() => RequestsScreenState();
}

class RequestsScreenState extends State<RequestsScreen> {
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
  final _top = ScrollController();
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

  ExtrasState get _extras => widget.extras;
  String get _text => _query.text.trim();
  bool get _activityMode => _category == 'activity' && _text.isEmpty;
  bool get _discoveryMode => _category == 'discover' && _text.isEmpty;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
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
    _top.dispose();
    super.dispose();
  }

  /// Opens My requests, as from Home or a title's View request activity.
  void showActivity() {
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
    if (_top.hasClients) _top.jumpTo(0);
    unawaited(_reload());
  }

  void _queryChanged(String _) {
    _debounce?.cancel();
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
    final showActivity = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RequestDetailsScreen(
          extras: _extras,
          kind: kind,
          titleId: id,
          onOpen: (item) {
            Navigator.of(context).pop();
            widget.onOpen(item);
          },
        ),
      ),
    );
    if (!mounted) return;
    if (showActivity == true) {
      this.showActivity();
    } else {
      unawaited(_reload(quiet: true));
    }
  }

  Future<void> _chooseCategory() async {
    final choice = await showChoices<String>(
      context,
      title: 'Browse request categories',
      options: _categories,
      selected: _category,
    );
    if (choice == null) return;
    _query.clear();
    _set(() => _category = choice);
  }

  Future<void> _chooseFilter() async {
    final choice = await showChoices<String>(
      context,
      title: 'Status',
      options: _filters,
      selected: _filter,
    );
    if (choice != null) _set(() => _filter = choice);
  }

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    if (!_extras.requestsEnabled && !_extras.isPreview) {
      children.add(
        const StatusMessage(
          title: 'Requests unavailable',
          detail:
              'This server does not provide Requests. Your library remains available.',
        ),
      );
    } else {
      children.addAll([
        SizedBox(
          width: 900,
          child: TvTextField(
            controller: _query,
            autocorrect: false,
            style: Zoro.font(26),
            decoration: const InputDecoration(
              labelText: 'Search movies and TV shows',
              prefixIcon: Icon(
                Icons.search_rounded,
                color: Zoro.muted,
                size: 30,
              ),
            ),
            onChanged: _queryChanged,
          ),
        ),
        const SizedBox(height: 20),
        FocusTraversalGroup(
          child: Row(
            children: [
              for (final (value, label) in const [
                ('discover', 'Discover'),
                ('activity', 'My requests'),
              ]) ...[
                _Tab(
                  label: label,
                  selected: _category == value,
                  onPressed: () {
                    _query.clear();
                    _set(() => _category = value);
                  },
                ),
                const SizedBox(width: 30),
              ],
              const Spacer(),
              CircleIconButton(
                icon: Icons.filter_list_rounded,
                label: 'Browse request categories',
                onPressed: _chooseCategory,
              ),
            ],
          ),
        ),
        if (!_discoveryMode && !_activityMode && _text.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _categories.firstWhere((c) => c.$1 == _category).$2,
              style: Zoro.font(28, weight: FontWeight.w700),
            ),
          ),
        const SizedBox(height: 24),
        if (_activityMode) ..._activityFilters(),
        if (_error != null)
          StatusMessage(
            title: 'Requests couldn’t load',
            detail: _error!,
            icon: Icons.error_outline_rounded,
            action: ZoroButton(
              label: 'Try again',
              onPressed: () => unawaited(_reload()),
            ),
          ),
        if (_loading && _isEmpty)
          const Padding(
            padding: EdgeInsets.all(40),
            child: Center(child: CircularProgressIndicator(color: Zoro.jade)),
          ),
        if (_activityMode)
          ..._activityList()
        else if (_discoveryMode) ...[
          ..._personalPreview(),
          ..._discoveryRows(),
        ] else
          _grid(),
        if (!_loading && _error == null) ..._emptyAndPaging(),
        if (_extras.isPreview)
          Padding(
            padding: const EdgeInsets.only(top: 24),
            child: Text(
              'Preview only · Requests are never sent',
              style: Zoro.font(20, color: Zoro.muted),
            ),
          ),
      ]);
    }
    return ListView(
      controller: _top,
      padding: const EdgeInsets.fromLTRB(Zoro.gutter, 20, Zoro.gutter, 48),
      children: children,
    );
  }

  bool get _isEmpty => _activityMode
      ? _activity.isEmpty
      : _discoveryMode
      ? _discovery.isEmpty
      : _titles.isEmpty;

  List<Widget> _emptyAndPaging() => [
    if (!_discoveryMode &&
        (_activityMode ? _activity.isEmpty : _visible(_titles).isEmpty))
      StatusMessage(
        title: _activityMode ? 'No requests here yet' : 'No titles found',
        detail: _activityMode
            ? 'Request a title to follow its progress here.'
            : Preferences.valueOf(context).hideAvailableRequests
            ? 'Try the next page, or turn off Hide available titles in Display settings.'
            : 'Try another title or browse a different section.',
      ),
    if (_discoveryMode &&
        !_discovery.any((r) => r.failed || _visible(r.titles).isNotEmpty))
      const StatusMessage(
        title: 'No discovery titles yet',
        detail: 'Search for a title or browse Movies and TV shows.',
      ),
    if (!_discoveryMode && _totalPages > 1)
      Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Column(
          children: [
            Text(
              'Page $_page of $_totalPages',
              style: Zoro.font(18, color: Zoro.muted),
            ),
            const SizedBox(height: 10),
            FocusTraversalGroup(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Opacity(
                    opacity: _page > 1 ? 1 : 0.4,
                    child: ZoroButton(
                      label: 'Previous',
                      onPressed: _page > 1 ? () => _goToPage(_page - 1) : () {},
                    ),
                  ),
                  const SizedBox(width: 16),
                  Opacity(
                    opacity: _page < _totalPages ? 1 : 0.4,
                    child: ZoroButton(
                      label: 'Next',
                      onPressed: _page < _totalPages
                          ? () => _goToPage(_page + 1)
                          : () {},
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
  ];

  List<Widget> _activityFilters() => [
    FocusTraversalGroup(
      child: Row(
        children: [
          ZoroButton(
            label: 'My requests',
            primary: _mine,
            onPressed: () => _set(() => _mine = true),
          ),
          const SizedBox(width: 12),
          ZoroButton(
            label: 'All activity',
            primary: !_mine,
            onPressed: () => _set(() => _mine = false),
          ),
          const SizedBox(width: 12),
          ZoroButton(
            label: 'Status: ${_filters.firstWhere((f) => f.$1 == _filter).$2}',
            onPressed: _chooseFilter,
          ),
          const Spacer(),
          CircleIconButton(
            icon: Icons.refresh_rounded,
            label: 'Refresh request activity',
            onPressed: () => unawaited(_reload()),
          ),
        ],
      ),
    ),
    if (!_mine)
      Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(
          'Activity your server allows this account to see.',
          style: Zoro.font(18, color: Zoro.muted),
        ),
      ),
    const SizedBox(height: 20),
  ];

  List<Widget> _activityList() => [
    for (final entry in _pending.where((e) => e.receiptId == null))
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: ZoroButton(
            label:
                'Review unconfirmed ${entry.intent.kind == RequestKind.tv ? 'show' : 'movie'} request',
            icon: Icons.error_outline_rounded,
            onPressed: () => _openTitle(entry.intent.kind, entry.intent.id),
          ),
        ),
      ),
    for (final item in _activity)
      _ActivityRow(
        item: item,
        detail: _queue?.label(item),
        requestedBy: _mine ? null : item.requestedBy,
        onPressed: item.kind == null || item.tmdbId == null
            ? null
            : () => _openTitle(item.kind!, item.tmdbId!),
      ),
  ];

  List<Widget> _personalPreview() {
    if (_personal.isEmpty) return const [];
    return [
      FocusTraversalGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  'Your requests',
                  style: Zoro.font(28, weight: FontWeight.w600),
                ),
                const Spacer(),
                ZoroButton(label: 'See all', onPressed: showActivity),
              ],
            ),
            const SizedBox(height: 10),
            for (final item in _personal.take(3))
              _ActivityRow(
                item: item,
                compact: true,
                detail: _personalQueue?.label(item),
                onPressed: () => _openTitle(item.kind!, item.tmdbId!),
              ),
          ],
        ),
      ),
      const SizedBox(height: 28),
    ];
  }

  List<Widget> _discoveryRows() => [
    for (final row in _discovery)
      if (row.failed || _visible(row.titles).isNotEmpty)
        FocusTraversalGroup(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 36),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      row.section.title,
                      style: Zoro.font(28, weight: FontWeight.w700),
                    ),
                    const Spacer(),
                    if (row.section != RequestDiscoverySection.recommended)
                      CircleIconButton(
                        icon: Icons.chevron_right_rounded,
                        label: 'See all ${row.section.title.toLowerCase()}',
                        color: Zoro.jade,
                        onPressed: () => _set(
                          () => _category = switch (row.section) {
                            RequestDiscoverySection.movies => 'movies',
                            RequestDiscoverySection.tv => 'tv',
                            RequestDiscoverySection.upcoming => 'upcoming',
                            _ => 'trending',
                          },
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (row.failed)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: ZoroButton(
                      label: 'Couldn’t load this row. Retry',
                      onPressed: () => unawaited(_reload()),
                    ),
                  )
                else
                  SizedBox(
                    height: _RequestCard.heightFor(context),
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      clipBehavior: Clip.none,
                      itemCount: _visible(row.titles).length,
                      separatorBuilder: (_, _) => const SizedBox(width: 24),
                      itemBuilder: (context, i) {
                        final title = _visible(row.titles)[i];
                        return _RequestCard(
                          title: title,
                          onPressed: () => _openTitle(title.kind!, title.id),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
  ];

  Widget _grid() => FocusTraversalGroup(
    child: Wrap(
      spacing: 20,
      runSpacing: 28,
      children: [
        for (final title in _visible(_titles))
          _RequestCard(
            title: title,
            onPressed: () => _openTitle(title.kind!, title.id),
          ),
      ],
    ),
  );
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Focusable(
    onPressed: onPressed,
    semanticLabel: label,
    builder: (context, focused) => AnimatedContainer(
      duration: Zoro.focusDuration,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: focused ? Zoro.text : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: Zoro.font(
              25,
              weight: selected ? FontWeight.w600 : FontWeight.w400,
              color: focused ? Zoro.background : Zoro.text,
            ),
          ),
          const SizedBox(height: 9),
          Container(
            width: 60,
            height: 2,
            color: selected ? Zoro.jade : Colors.transparent,
          ),
        ],
      ),
    ),
  );
}

/// TMDB poster, or the preview artwork when there is none.
class RequestPoster extends StatelessWidget {
  const RequestPoster({super.key, required this.url, required this.title});

  final Uri? url;
  final String title;

  @override
  Widget build(BuildContext context) {
    final placeholder = PreviewArtwork(
      title: title,
      seed: title,
      showTitle: true,
    );
    final source = url;
    return ExcludeSemantics(
      child: source == null
          ? placeholder
          : Image.network(
              source.toString(),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => placeholder,
            ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({required this.title, required this.onPressed});

  final RequestTitle title;
  final VoidCallback onPressed;

  static double widthFor(BuildContext context) =>
      210 * Preferences.valueOf(context).posterScale;

  static double heightFor(BuildContext context) =>
      widthFor(context) * 1.5 + 8 + 56 + 24 + 24 + 16;

  @override
  Widget build(BuildContext context) {
    final width = widthFor(context);
    final caption = [
      title.year,
      title.kind == RequestKind.tv ? 'TV show' : 'Movie',
    ].where((s) => s.isNotEmpty).join(' · ');
    return Focusable(
      onPressed: onPressed,
      semanticLabel: '${title.displayTitle}, ${title.status()}',
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
                height: width * 1.5,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: focused ? Zoro.text : Colors.transparent,
                    width: 4,
                  ),
                ),
                child: RequestPoster(
                  url: RequestArtwork.path(title.posterPath),
                  title: title.displayTitle,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              title.displayTitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Zoro.font(20, weight: FontWeight.w600),
            ),
            Text(caption, style: Zoro.font(16, color: Zoro.muted)),
            if (title.mediaInfo != null)
              Text(title.status(), style: Zoro.font(16, color: Zoro.jade)),
          ],
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
      child: Focusable(
        onPressed: onPressed ?? () {},
        semanticLabel: '$title, $status',
        builder: (context, focused) => AnimatedContainer(
          duration: Zoro.focusDuration,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: focused ? Zoro.panel : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: focused ? Zoro.jade : Colors.transparent,
              width: 3,
            ),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(compact ? 7 : 10),
                child: SizedBox(
                  width: compact ? 64 : 88,
                  height: compact ? 96 : 132,
                  child: RequestPoster(
                    url: RequestArtwork.absolute(item.posterUrl),
                    title: title,
                  ),
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Zoro.font(
                        compact ? 23 : 24,
                        weight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(status, style: Zoro.font(19, color: Zoro.jade)),
                    if (!compact && detail != null)
                      Text(detail!, style: Zoro.font(19, color: Zoro.muted)),
                    if (requestedBy != null)
                      Text(
                        requestedBy!,
                        style: Zoro.font(16, color: Zoro.muted),
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
    );
  }
}
