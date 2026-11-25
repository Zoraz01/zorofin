import 'dart:async';

import 'package:flutter/material.dart';
import '../ui/widgets/search_results.dart';

import '../core/catalog.dart';
import '../core/errors.dart';
import '../core/models.dart';
import '../ui/theme.dart';
import 'phone_scope.dart';
import 'phone_theme.dart';
import 'phone_widgets.dart';

/// Search (Apple `SearchView` on iPhone): a search field over suggestions,
/// then results as you type. Can't find it? opens Requests when available.
class PhoneSearchScreen extends StatefulWidget {
  const PhoneSearchScreen({super.key});

  @override
  State<PhoneSearchScreen> createState() => _PhoneSearchScreenState();
}

class _PhoneSearchScreenState extends State<PhoneSearchScreen> {
  final _query = TextEditingController();
  Timer? _debounce;
  Catalog? _catalog;
  List<MediaItem> _recommended = const [];
  bool _recommending = true;
  bool _recommendationsFailed = false;
  List<MediaItem> _results = const [];
  String? _loadedQuery;
  String _type = 'Movie,Series';
  String? _loadedType;
  int _offset = 0;
  bool _hasMore = false;
  void _changeType(String value) {
    if (value == _type) return;
    _debounce?.cancel();
    setState(() {
      _type = value;
      _results = const [];
    });
    _search(_text);
  }

  bool _searching = false;
  String? _error;
  int _request = 0;

  String get _text => _query.text.trim();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final catalog = PhoneScope.of(context).catalog;
    if (catalog != _catalog) {
      _catalog = catalog;
      unawaited(_loadRecommendations());
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _loadRecommendations() async {
    setState(() {
      _recommending = true;
      _recommendationsFailed = false;
    });
    try {
      final items = await _catalog!.recommendations();
      if (mounted) setState(() => _recommended = items);
    } catch (_) {
      if (mounted) setState(() => _recommendationsFailed = true);
    } finally {
      if (mounted) setState(() => _recommending = false);
    }
  }

  void _changed(String _) {
    _debounce?.cancel();
    final text = _text;
    _request++;
    setState(() {
      _error = null;
      _searching =
          text.isNotEmpty && (text != _loadedQuery || _type != _loadedType);
    });
    if (text.isEmpty || (text == _loadedQuery && _type == _loadedType)) return;
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(text));
  }

  Future<void> _search(String text, {bool more = false}) async {
    if (text.isEmpty || (more && (_searching || !_hasMore))) return;
    final type = _type;
    final catalog = _catalog!;
    final request = ++_request;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final page = await catalog.searchPage(
        text,
        type: type,
        start: more ? _offset : 0,
      );
      final results = page.items;
      if (!mounted ||
          request != _request ||
          text != _text ||
          type != _type ||
          !identical(catalog, _catalog)) {
        return;
      }
      setState(() {
        final seen = <String>{};
        _results = [
          ...(more ? _results : const <MediaItem>[]),
          ...results,
        ].where((v) => seen.add(v.id)).toList();
        _offset = (more ? _offset : 0) + results.length;
        _hasMore =
            results.isNotEmpty &&
            (page.totalRecordCount == null
                ? results.length >= 30
                : _offset < page.totalRecordCount!);
        _loadedQuery = text;
        _loadedType = type;
      });
    } on ClientError catch (e) {
      if (mounted && request == _request) setState(() => _error = e.message);
    } catch (_) {
      if (mounted && request == _request) {
        setState(() => _error = 'Search couldn’t finish. Try again.');
      }
    } finally {
      if (mounted && request == _request) setState(() => _searching = false);
    }
  }

  SliverGrid _grid(BuildContext context, List<MediaItem> items) {
    final scope = PhoneScope.of(context);
    final columns = PhoneWindow.of(context).gridColumns();
    final width =
        (MediaQuery.sizeOf(context).width -
            Phone.gutter * 2 -
            12 * (columns - 1)) /
        columns;
    return SliverGrid(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: 12,
        mainAxisSpacing: 18,
        childAspectRatio:
            width / PhoneCard.heightFor(context, width, landscape: false),
      ),
      delegate: SliverChildBuilderDelegate(
        (context, i) => PhoneCard(
          item: items[i],
          catalog: scope.catalog,
          onPressed: () => scope.open(items[i]),
        ),
        childCount: items.length,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scope = PhoneScope.of(context);
    final media = MediaQuery.of(context);
    final text = _text;
    final showingResults = text.isNotEmpty;
    final requests = scope.extras.requestsEnabled || scope.extras.isPreview;
    final items = showingResults
        ? (_loadedQuery == text && _loadedType == _type
              ? _results
              : const <MediaItem>[])
        : _recommended;
    return Scaffold(
      backgroundColor: Zoro.background,
      body: CustomScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              Phone.gutter,
              media.padding.top + 12,
              Phone.gutter,
              12,
            ),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Search', style: Zoro.font(28, weight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _query,
                    autocorrect: false,
                    textInputAction: TextInputAction.search,
                    style: Zoro.font(17),
                    decoration: InputDecoration(
                      hintText: 'Movies, shows and more',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              icon: const Icon(Icons.cancel_rounded),
                              onPressed: () {
                                _query.clear();
                                _changed('');
                              },
                            ),
                    ),
                    onChanged: _changed,
                    onSubmitted: (value) {
                      _debounce?.cancel();
                      if (value.trim().isNotEmpty) _search(value.trim());
                    },
                  ),
                ],
              ),
            ),
          ),
          if (showingResults)
            SliverPadding(
              padding: const EdgeInsets.symmetric(
                horizontal: Phone.gutter,
                vertical: 8,
              ),
              sliver: SliverToBoxAdapter(
                child: SearchTypeFilters(value: _type, onChanged: _changeType),
              ),
            ),
          if (showingResults && _searching)
            const SliverToBoxAdapter(
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (showingResults && _error != null)
            SliverToBoxAdapter(
              child: PhoneStatus(
                title: 'Search unavailable',
                detail: _error,
                icon: Icons.wifi_off_rounded,
                action: PillButton(
                  label: 'Try again',
                  onPressed: () => _search(text),
                ),
              ),
            ),
          if (!showingResults)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: SectionHeader(
                  _recommendationsFailed
                      ? 'Suggestions unavailable'
                      : 'Suggested',
                ),
              ),
            ),
          if (!showingResults && _recommending)
            const SliverToBoxAdapter(child: PhoneLoading()),
          if (showingResults &&
              !_searching &&
              _error == null &&
              _loadedQuery == text &&
              _results.isEmpty)
            SliverToBoxAdapter(
              child: PhoneStatus(
                title: 'No results for “$text”',
                detail: requests
                    ? 'Can’t find it? You can request it.'
                    : 'Try a different title, person or genre.',
                action: requests
                    ? PillButton(
                        label: 'Request a title',
                        icon: Icons.add_to_queue_rounded,
                        onPressed: () =>
                            scope.select(PhoneDestination.requests),
                      )
                    : null,
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: Phone.gutter),
            sliver: showingResults
                ? SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => SearchResultRow(
                        item: items[i],
                        catalog: scope.catalog,
                        onOpen: () => scope.open(items[i]),
                      ),
                      childCount: items.length,
                    ),
                  )
                : _grid(context, items),
          ),
          if (showingResults &&
              _hasMore &&
              _loadedQuery == text &&
              _loadedType == _type)
            SliverToBoxAdapter(
              child: Center(
                child: PillButton(
                  label: 'More results',
                  busy: _searching,
                  onPressed: _searching
                      ? null
                      : () => _search(text, more: true),
                ),
              ),
            ),
          if (showingResults && requests && _results.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Center(
                  child: TextButton.icon(
                    icon: const Icon(Icons.add_to_queue_rounded),
                    label: const Text('Can’t find it? Request a title'),
                    style: TextButton.styleFrom(foregroundColor: Zoro.jade),
                    onPressed: () => scope.select(PhoneDestination.requests),
                  ),
                ),
              ),
            ),
          SliverPadding(
            padding: EdgeInsets.only(bottom: media.padding.bottom + 16),
          ),
        ],
      ),
    );
  }
}
