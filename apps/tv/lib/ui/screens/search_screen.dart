import 'dart:async';

import 'package:flutter/material.dart';
import '../widgets/search_results.dart';

import '../../core/catalog.dart';
import '../../core/errors.dart';
import '../../core/models.dart';
import '../../core/preferences.dart';
import '../theme.dart';
import '../widgets/focusable.dart';
import '../widgets/media_card.dart';
import '../widgets/section_title.dart';
import '../widgets/tv_text_field.dart';

/// Search (Apple `SearchView`): one field; an empty query shows Recommended,
/// typing replaces it with debounced library results.
class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    required this.catalog,
    required this.onOpen,
    this.onOpenRequests,
  });

  final Catalog catalog;
  final ValueChanged<MediaItem> onOpen;

  /// Offered under results when the server has Requests.
  final VoidCallback? onOpenRequests;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  static const _spacing = 28.0;

  final _query = TextEditingController();
  Timer? _debounce;
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
  void initState() {
    super.initState();
    unawaited(_loadRecommendations());
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
      final items = await widget.catalog.recommendations();
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

  void _clear() {
    _query.clear();
    _changed('');
  }

  Future<void> _search(String text, {bool more = false}) async {
    if (text.isEmpty || (more && (_searching || !_hasMore))) return;
    final type = _type;
    final catalog = widget.catalog;
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
          !identical(catalog, widget.catalog)) {
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
    } finally {
      if (mounted && request == _request) setState(() => _searching = false);
    }
  }

  /// Poster grid like Apple's `MediaGrid`, sized to the viewer's poster
  /// scale.
  Widget _grid(List<MediaItem> items) => LayoutBuilder(
    builder: (context, constraints) {
      final prefs = Preferences.valueOf(context);
      final minWidth = MediaCard.posterWidth * prefs.posterScale;
      final columns =
          ((constraints.maxWidth + _spacing) / (minWidth + _spacing))
              .floor()
              .clamp(1, 12);
      final width = (constraints.maxWidth - _spacing * (columns - 1)) / columns;
      return Wrap(
        spacing: _spacing,
        runSpacing: 28,
        children: [
          for (final item in items)
            MediaCard(
              item: item,
              catalog: widget.catalog,
              width: width,
              onPressed: () => widget.onOpen(item),
            ),
        ],
      );
    },
  );

  List<Widget> _recommendations() => [
    if (_recommended.isNotEmpty) ...[
      const SectionTitle('Recommended'),
      const SizedBox(height: 16),
      _grid(_recommended),
    ] else if (_recommending)
      const _Progress('Finding recommendations…')
    else if (!_recommendationsFailed)
      const StatusMessage(
        title: 'Explore your library',
        detail:
            'Recommended movies and shows will appear here as your library grows.',
        icon: Icons.movie_outlined,
      ),
    if (_recommendationsFailed)
      Align(
        alignment: Alignment.centerLeft,
        child: ZoroButton(
          label: 'Retry recommendations',
          onPressed: () => unawaited(_loadRecommendations()),
        ),
      ),
  ];

  List<Widget> _resultsSection() {
    final text = _text;
    final matching = _loadedQuery == text && _loadedType == _type
        ? _results
        : const <MediaItem>[];
    return [
      SearchTypeFilters(value: _type, onChanged: _changeType),
      const SizedBox(height: 16),
      if (_searching) const _Progress('Searching…'),
      if (matching.isNotEmpty)
        for (final item in matching)
          SearchResultRow(
            item: item,
            catalog: widget.catalog,
            onOpen: () => widget.onOpen(item),
          )
      else if (!_searching && _loadedQuery == text && _error == null)
        const StatusMessage(
          title: 'No matching titles',
          detail: 'Try another title or spelling.',
          icon: Icons.search_rounded,
        ),
      if (_error != null) ...[
        Text(_error!, style: Zoro.font(22, color: const Color(0xFFFFB74D))),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: ZoroButton(
            label: 'Retry search',
            onPressed: () => unawaited(_search(text)),
          ),
        ),
      ],
      if (_hasMore && _loadedQuery == text && _loadedType == _type)
        Align(
          alignment: Alignment.centerLeft,
          child: ZoroButton(
            label: _searching ? 'Loading…' : 'More results',
            onPressed: () => _search(text, more: true),
          ),
        ),
      if (widget.onOpenRequests != null) ...[
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerLeft,
          child: ZoroButton(
            label: "Can't find it? Open Requests",
            onPressed: widget.onOpenRequests!,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Search your library or request a title from this server.',
          style: Zoro.font(18, color: Zoro.muted),
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(Zoro.gutter, 20, Zoro.gutter, 48),
      children: [
        Text('Search', style: Zoro.font(44, weight: FontWeight.w700)),
        const SizedBox(height: 24),
        TvTextField(
          controller: _query,
          autofocus: true,
          autocorrect: false,
          style: Zoro.font(26),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Search your library',
            prefixIcon: const Icon(
              Icons.search_rounded,
              color: Zoro.muted,
              size: 30,
            ),
            suffixIcon: _query.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.cancel_rounded, color: Zoro.muted),
                    onPressed: _clear,
                  ),
          ),
          onChanged: _changed,
          onSubmitted: (_) {
            _debounce?.cancel();
            if (_text.isNotEmpty) unawaited(_search(_text));
          },
        ),
        const SizedBox(height: 24),
        ...(_text.isEmpty ? _recommendations() : _resultsSection()),
      ],
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      children: [
        CircularProgressIndicator(color: Zoro.jade),
        const SizedBox(height: 12),
        Text(label, style: Zoro.font(20, color: Zoro.muted)),
      ],
    ),
  );
}
