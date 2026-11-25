import 'dart:async';

import 'package:flutter/material.dart';
import '../core/library_browse.dart';
import '../ui/widgets/library_filters.dart';

import '../core/catalog.dart';
import '../core/errors.dart';
import '../core/models.dart';
import '../ui/theme.dart';
import 'phone_scope.dart';
import 'phone_theme.dart';
import 'phone_widgets.dart';

/// Movies and TV Shows (Apple `CatalogView` on iPhone): a poster grid with a
/// Favorites filter, loading more pages near the end.
class PhoneLibraryScreen extends StatefulWidget {
  const PhoneLibraryScreen({super.key, required this.kind});

  final LibraryKind kind;

  @override
  State<PhoneLibraryScreen> createState() => _PhoneLibraryScreenState();
}

class _PhoneLibraryScreenState extends State<PhoneLibraryScreen> {
  final List<MediaItem> _items = [];
  final _scroll = ScrollController();
  bool _favorites = false;
  LibraryBrowseOptions _options = const LibraryBrowseOptions();
  List<String> _genres = const [];
  bool _genresFailed = false;
  int _offset = 0;
  Future<void> _loadGenres() async {
    final catalog = _catalog;
    if (catalog == null) return;
    try {
      final values = await catalog.libraryGenres(widget.kind);
      if (mounted && identical(catalog, _catalog)) {
        setState(() {
          _genres = values;
          _genresFailed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _genresFailed = true);
    }
  }

  Widget _filters() => LibraryFilters(
    options: _options,
    genres: _genres,
    genresFailed: _genresFailed,
    onRetryGenres: _loadGenres,
    onChanged: (value) {
      _options = value;
      _load(reset: true);
    },
  );
  bool _loading = false;
  bool _hasMore = true;
  String? _error;
  int _request = 0;
  Catalog? _catalog;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final catalog = PhoneScope.of(context).catalog;
    if (catalog != _catalog) {
      _catalog = catalog;
      _genres = const [];
      unawaited(_loadGenres());
      unawaited(_load(reset: true));
    }
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.hasClients && _scroll.position.extentAfter < 800) {
        unawaited(_load(reset: false));
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({required bool reset}) async {
    final catalog = _catalog;
    if (catalog == null) return;
    if (!reset && (_loading || !_hasMore || _error != null)) return;
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _items.clear();
        _offset = 0;
        _hasMore = true;
      }
    });
    try {
      final page = await catalog.browseFiltered(
        widget.kind,
        start: _offset,
        options: _options,
        favorites: _favorites,
      );
      if (!mounted || request != _request) return;
      final known = _items.map((i) => i.id).toSet();
      final additions = page.items.where((i) => known.add(i.id)).toList();
      setState(() {
        _items.addAll(additions);
        _offset += page.items.length;
        final total = page.totalRecordCount;
        _hasMore =
            page.items.isNotEmpty &&
            (total == null ? page.items.length >= 30 : _offset < total);
      });
    } on ClientError catch (e) {
      if (mounted && request == _request) setState(() => _error = e.message);
    } catch (_) {
      if (mounted && request == _request) {
        setState(() => _error = 'Something went wrong.');
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = PhoneScope.of(context);
    final window = PhoneWindow.of(context);
    final media = MediaQuery.of(context);
    final columns = window.gridColumns();
    return Scaffold(
      backgroundColor: Zoro.background,
      body: CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverPadding(
            padding: EdgeInsets.only(top: media.padding.top + 8),
            sliver: SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Back to Home',
                      icon: const Icon(Icons.chevron_left_rounded, size: 32),
                      onPressed: () => scope.select(PhoneDestination.home),
                    ),
                    Expanded(
                      child: Text(
                        widget.kind.title,
                        style: Zoro.font(28, weight: FontWeight.w700),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: Phone.gutter - 4),
                      child: FilterChip(
                        label: const Text('Favorites'),
                        selected: _favorites,
                        showCheckmark: false,
                        avatar: Icon(
                          _favorites
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          size: 18,
                          color: _favorites ? Zoro.background : Zoro.text,
                        ),
                        selectedColor: Zoro.jade,
                        labelStyle: Zoro.font(
                          14,
                          weight: FontWeight.w600,
                          color: _favorites ? Zoro.background : Zoro.text,
                        ),
                        backgroundColor: Zoro.panel,
                        side: const BorderSide(color: Zoro.border),
                        shape: const StadiumBorder(),
                        onSelected: (value) {
                          _favorites = value;
                          unawaited(_load(reset: true));
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              Phone.gutter,
              12,
              Phone.gutter,
              12,
            ),
            sliver: SliverToBoxAdapter(child: _filters()),
          ),
          if (_items.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _loading
                  ? const PhoneLoading()
                  : _error != null
                  ? PhoneStatus(
                      title: 'Library unavailable',
                      detail: _error,
                      icon: Icons.wifi_off_rounded,
                      action: PillButton(
                        label: 'Try again',
                        onPressed: () => _load(reset: true),
                      ),
                    )
                  : PhoneStatus(
                      title: _favorites
                          ? 'No favorites yet'
                          : 'Nothing here yet',
                      detail: _favorites
                          ? 'Tap the heart on a title to add it here.'
                          : 'Media added to your Jellyfin server will appear here.',
                    ),
            )
          else ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                Phone.gutter,
                12,
                Phone.gutter,
                0,
              ),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 18,
                  childAspectRatio: _aspect(context, columns),
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => PhoneCard(
                    item: _items[i],
                    catalog: scope.catalog,
                    onPressed: () => scope.open(_items[i]),
                  ),
                  childCount: _items.length,
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Center(
                  child: _loading
                      ? const CircularProgressIndicator()
                      : _error != null
                      ? PillButton(
                          label: 'Try again',
                          onPressed: () {
                            setState(() => _error = null);
                            unawaited(_load(reset: false));
                          },
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ),
          ],
          SliverPadding(padding: EdgeInsets.only(bottom: media.padding.bottom)),
        ],
      ),
    );
  }

  /// Card width over its poster and two caption lines.
  double _aspect(BuildContext context, int columns) {
    final width =
        (MediaQuery.sizeOf(context).width -
            Phone.gutter * 2 -
            12 * (columns - 1)) /
        columns;
    return width / PhoneCard.heightFor(context, width, landscape: false);
  }
}
