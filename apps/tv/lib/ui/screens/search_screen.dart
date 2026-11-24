import 'dart:async';

import 'package:flutter/material.dart';

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
      _searching = text.isNotEmpty && text != _loadedQuery;
    });
    if (text.isEmpty || text == _loadedQuery) return;
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(text));
  }

  void _clear() {
    _query.clear();
    _changed('');
  }

  Future<void> _search(String text) async {
    final request = ++_request;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await widget.catalog.search(text);
      if (!mounted || request != _request || text != _text) return;
      setState(() {
        _results = results;
        _loadedQuery = text;
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
    final matching = _loadedQuery == text ? _results : const <MediaItem>[];
    return [
      if (_searching) const _Progress('Searching…'),
      if (matching.isNotEmpty)
        _grid(matching)
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
          'Showing up to 30 library matches. Refine your search to narrow the results.',
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
        const CircularProgressIndicator(color: Zoro.jade),
        const SizedBox(height: 12),
        Text(label, style: Zoro.font(20, color: Zoro.muted)),
      ],
    ),
  );
}
