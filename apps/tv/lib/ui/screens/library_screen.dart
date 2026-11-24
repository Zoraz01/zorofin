import 'package:flutter/material.dart';

import '../../core/catalog.dart';
import '../../core/preferences.dart';
import '../../core/errors.dart';
import '../../core/models.dart';
import '../theme.dart';
import '../widgets/focusable.dart';
import '../widgets/live_tv_notice.dart';
import '../widgets/media_card.dart';
import '../widgets/section_title.dart';

/// Movies, TV Shows and Live TV catalogues (Apple `CatalogView`): a paged
/// poster grid with a Favorites filter (not for channels).
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.catalog,
    required this.kind,
    required this.onOpen,
    this.onPlay,
  });

  final Catalog catalog;
  final LibraryKind kind;
  final ValueChanged<MediaItem> onOpen;

  /// Plays a channel straight away (Join on Live TV).
  final ValueChanged<MediaItem>? onPlay;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  static const _spacing = 28.0;
  static const _minCard = 210.0;

  final List<MediaItem> _items = [];
  bool _favorites = false;
  bool _loading = false;
  bool _hasMore = true;
  String? _error;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({required bool reset}) async {
    if (!reset && (_loading || !_hasMore)) return;
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _items.clear();
        _hasMore = true;
      }
    });
    try {
      final page = await widget.catalog.browse(
        widget.kind,
        start: _items.length,
        favorites: _favorites,
      );
      if (!mounted || request != _request) return;
      final known = _items.map((i) => i.id).toSet();
      final additions = page.items.where((i) => known.add(i.id)).toList();
      setState(() {
        _items.addAll(additions);
        final total = page.totalRecordCount;
        _hasMore =
            additions.isNotEmpty && (total == null || _items.length < total);
      });
    } on ClientError catch (e) {
      if (mounted && request == _request) setState(() => _error = e.message);
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final landscape = widget.kind == LibraryKind.live;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Zoro.gutter, 20, Zoro.gutter, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SectionTitle(widget.kind.title),
              const Spacer(),
              if (widget.kind != LibraryKind.live)
                ZoroButton(
                  label: _favorites ? 'All titles' : 'Favorites',
                  onPressed: () {
                    _favorites = !_favorites;
                    _load(reset: true);
                  },
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (widget.kind == LibraryKind.live)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: LiveTvNotice(onJoin: widget.onPlay),
            ),
          Expanded(child: _body(landscape)),
        ],
      ),
    );
  }

  Widget _body(bool landscape) {
    if (_items.isEmpty) {
      if (_loading) {
        return const Center(child: CircularProgressIndicator(color: Zoro.jade));
      }
      if (_error != null) {
        return StatusMessage(
          title: 'Library unavailable',
          detail: _error!,
          icon: Icons.wifi_off_rounded,
          action: ZoroButton(
            label: 'Try again',
            onPressed: () => _load(reset: true),
          ),
        );
      }
      return StatusMessage(
        title: 'No titles here yet',
        detail: _favorites
            ? "Add favorites from a title's details."
            : 'Titles available to your account will appear here.',
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final prefs = Preferences.valueOf(context);
        final minWidth =
            (landscape ? MediaCard.landscapeWidth : _minCard) *
            prefs.posterScale;
        final columns =
            ((constraints.maxWidth + _spacing) / (minWidth + _spacing))
                .floor()
                .clamp(1, 12);
        final width =
            (constraints.maxWidth - _spacing * (columns - 1)) / columns;
        final height = MediaCard.heightFor(
          landscape: landscape,
          width: width,
          prefs: prefs,
        );
        return GridView.builder(
          clipBehavior: Clip.none,
          cacheExtent: 1200,
          padding: const EdgeInsets.symmetric(vertical: 16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: _spacing,
            mainAxisSpacing: 28,
            childAspectRatio: width / height,
          ),
          itemCount: _items.length,
          itemBuilder: (context, i) {
            // Page in more titles as focus approaches the end.
            if (i >= _items.length - columns * 2) {
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => _load(reset: false),
              );
            }
            return MediaCard(
              item: _items[i],
              catalog: widget.catalog,
              landscape: landscape,
              width: width,
              onPressed: () => widget.onOpen(_items[i]),
            );
          },
        );
      },
    );
  }
}
