import 'package:flutter/material.dart';

import '../../core/catalog.dart';
import '../../core/errors.dart';
import '../../core/home.dart';
import '../../core/models.dart';
import '../../core/preferences.dart';
import '../../phone/phone_theme.dart';
import '../../phone/phone_widgets.dart';
import '../theme.dart';
import '../widgets/focusable.dart';
import '../widgets/media_card.dart';

/// A Home shelf, not another tab. The server supplies real BoxSet items.
class CollectionsHomeShelf extends StatefulWidget {
  const CollectionsHomeShelf({
    super.key,
    required this.catalog,
    required this.onOpen,
    required this.onBrowseAll,
    this.mobile = false,
    this.revision = 0,
  });
  final Catalog catalog;
  final ValueChanged<MediaItem> onOpen;
  final VoidCallback? onBrowseAll;
  final bool mobile;
  final int revision;
  @override
  State<CollectionsHomeShelf> createState() => _CollectionsHomeShelfState();
}

class _CollectionsHomeShelfState extends State<CollectionsHomeShelf> {
  List<MediaItem> _items = const [];
  String? _error;
  int _request = 0;
  bool _loading = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CollectionsHomeShelf old) {
    super.didUpdateWidget(old);
    if (!identical(old.catalog, widget.catalog) ||
        old.revision != widget.revision) {
      _items = const [];
      _loading = false;
      _load();
    }
  }

  Future<void> _load() async {
    if (_loading) return;
    final request = ++_request;
    final catalog = widget.catalog;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await catalog.collections();
      if (!mounted ||
          request != _request ||
          !identical(catalog, widget.catalog)) {
        return;
      }
      final seen = <String>{};
      setState(
        () => _items = page.items
            .where((i) => i.type == 'BoxSet' && seen.add(i.id))
            .take(20)
            .toList(),
      );
    } catch (e) {
      if (mounted && request == _request) {
        setState(
          () =>
              _error = e is ClientError ? e.message : 'Try again in a moment.',
        );
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) {
      if (_error == null) return const SizedBox.shrink();
      return Padding(
        padding: EdgeInsets.symmetric(
          horizontal: widget.mobile ? Phone.gutter : Zoro.gutter,
        ),
        child: widget.mobile
            ? PillButton(label: 'Collections · Retry', onPressed: _load)
            : ZoroButton(label: 'Collections · Retry', onPressed: _load),
      );
    }
    final action = widget.onBrowseAll == null
        ? null
        : widget.mobile
        ? PillButton(label: 'Browse all', onPressed: widget.onBrowseAll!)
        : ZoroButton(label: 'Browse all', onPressed: widget.onBrowseAll!);
    return widget.mobile
        ? PhoneShelf(
            title: 'Collections',
            items: _items,
            catalog: widget.catalog,
            onOpen: widget.onOpen,
            trailing: action,
          )
        : MediaShelf(
            title: 'Collections',
            items: _items,
            catalog: widget.catalog,
            onOpen: widget.onOpen,
            trailing: action,
          );
  }
}

/// The same paged collection browser under touch and remote shells.
class CollectionsScreen extends StatefulWidget {
  const CollectionsScreen({
    super.key,
    required this.catalog,
    required this.onOpen,
    required this.onBack,
    this.collection,
    this.mobile = false,
  });
  final Catalog catalog;
  final MediaItem? collection;
  final ValueChanged<MediaItem> onOpen;
  final VoidCallback onBack;
  final bool mobile;
  @override
  State<CollectionsScreen> createState() => _CollectionsScreenState();
}

class _CollectionsScreenState extends State<CollectionsScreen> {
  final _scroll = ScrollController();
  final _items = <MediaItem>[];
  var _cursor = LibraryPageCursor();
  bool _loading = false;
  String? _error;
  int _request = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CollectionsScreen old) {
    super.didUpdateWidget(old);
    if (!identical(old.catalog, widget.catalog) ||
        old.collection?.id != widget.collection?.id) {
      _request++;
      _items.clear();
      _cursor = LibraryPageCursor();
      _loading = false;
      _load();
    }
  }

  @override
  void dispose() {
    _request++;
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading || !_cursor.hasMore) return;
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.catalog.collections(
        parentId: widget.collection?.id,
        start: _cursor.offset,
      );
      if (!mounted || request != _request) return;
      final known = _items.map((i) => i.id).toSet();
      final additions = page.items.where((i) => known.add(i.id)).toList();
      setState(() {
        _cursor.accept(page, 48);
        if (additions.isEmpty) _cursor.accept(ItemPage(items: const []), 48);
        _items.addAll(additions);
      });
    } catch (e) {
      if (mounted && request == _request) {
        setState(
          () =>
              _error = e is ClientError ? e.message : 'Try again in a moment.',
        );
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Widget _action(
    String title,
    VoidCallback onPressed, {
    bool autofocus = false,
  }) => widget.mobile
      ? PillButton(label: title, onPressed: onPressed)
      : ZoroButton(label: title, onPressed: onPressed, autofocus: autofocus);
  @override
  Widget build(BuildContext context) {
    final prefs = Preferences.valueOf(context);
    final mobile = widget.mobile;
    final gap = mobile ? 14.0 : 28.0;
    return Scaffold(
      backgroundColor: Zoro.background,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: mobile ? Phone.gutter : Zoro.gutter,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Row(
                  children: [
                    _action('Back', widget.onBack, autofocus: !mobile),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        widget.collection?.displayTitle ?? 'Collections',
                        style: Zoro.font(
                          mobile ? 28 : 40,
                          weight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, size) {
                    final columns = mobile
                        ? PhoneWindow.of(context).gridColumns()
                        : (size.maxWidth / (212 * prefs.posterScale + gap))
                              .floor()
                              .clamp(1, 10);
                    final width =
                        (size.maxWidth - gap * (columns - 1)) / columns;
                    final height = mobile
                        ? PhoneCard.heightFor(
                            context,
                            width,
                            landscape: false,
                            titles: prefs.showTitles,
                          )
                        : MediaCard.heightFor(
                            landscape: false,
                            width: width,
                            prefs: prefs,
                          );
                    return CustomScrollView(
                      controller: _scroll,
                      slivers: [
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          sliver: SliverGrid(
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: columns,
                                  mainAxisExtent: height,
                                  mainAxisSpacing: gap,
                                  crossAxisSpacing: gap,
                                ),
                            delegate: SliverChildBuilderDelegate((context, i) {
                              final item = _items[i];
                              return mobile
                                  ? PhoneCard(
                                      key: ValueKey(item.id),
                                      item: item,
                                      catalog: widget.catalog,
                                      onPressed: () => widget.onOpen(item),
                                    )
                                  : MediaCard(
                                      key: ValueKey(item.id),
                                      item: item,
                                      catalog: widget.catalog,
                                      width: width,
                                      onPressed: () => widget.onOpen(item),
                                    );
                            }, childCount: _items.length),
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 20),
                            child: _loading
                                ? const Center(
                                    child: CircularProgressIndicator(),
                                  )
                                : _error != null
                                ? Column(
                                    children: [
                                      Text(_error!),
                                      _action('Try again', _load),
                                    ],
                                  )
                                : _items.isEmpty
                                ? Text(
                                    widget.collection == null
                                        ? 'No collections here yet'
                                        : 'This collection is empty',
                                  )
                                : _cursor.hasMore
                                ? Align(
                                    alignment: Alignment.centerLeft,
                                    child: _action('More titles', _load),
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
