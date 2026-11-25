import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/catalog.dart';
import '../../core/models.dart';
import '../../core/playback.dart';
import '../../core/live_guide.dart';
import '../theme.dart';
import '../widgets/focusable.dart';
import '../widgets/live_tv_notice.dart';
import '../player/player_panels.dart' show clockLabel;

class GuideScreen extends StatefulWidget {
  const GuideScreen({
    super.key,
    required this.catalog,
    required this.onPlay,
    this.active = true,
    this.embedded = false,
  });
  final Catalog catalog;
  final PlayItem onPlay;
  final bool active;
  final bool embedded;
  @override
  State<GuideScreen> createState() => _GuideScreenState();
}

class _GuideScreenState extends State<GuideScreen> {
  List<MediaItem> _channels = [];
  List<LiveProgram> _programs = [];
  DateTime _start = guideWindowStart(DateTime.now());
  int _page = 0, _request = 0;
  bool _loading = true, _favorites = false, _indexReady = false;
  String _query = '';
  String? _error;
  Timer? _refresh, _search;
  final _scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    _load();
    _refresh = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted && widget.active) _load();
    });
  }

  @override
  void didUpdateWidget(GuideScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) _request++;
    if (!identical(oldWidget.catalog, widget.catalog)) {
      _request++;
      _channels = [];
      _programs = [];
      _indexReady = false;
      _page = 0;
      _load();
    } else if (!oldWidget.active && widget.active) {
      _load();
    }
  }

  @override
  void dispose() {
    _request++;
    _refresh?.cancel();
    _search?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  List<MediaItem> get _filtered => _channels
      .where(
        (c) =>
            (!_favorites || c.userData?.isFavorite == true) &&
            ('${c.channelNumber ?? ''} ${c.name}').toLowerCase().contains(
              _query.toLowerCase(),
            ),
      )
      .toList();
  List<MediaItem> get _visible => _filtered.skip(_page * 40).take(40).toList();
  Future<void> _load() async {
    if (!mounted || !widget.active) return;
    final client = widget.catalog is JellyfinCatalog
        ? (widget.catalog as JellyfinCatalog).client
        : null;
    if (client == null) {
      setState(() {
        _loading = false;
        _error = null;
      });
      return;
    }
    final turn = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (!_indexReady) {
        final items = <MediaItem>[], known = <String>{};
        var offset = 0;
        for (var i = 0; i < 20; i++) {
          final page = await client.guideChannels(start: offset);
          if (!mounted || turn != _request) return;
          final additions = page.items.where((c) => known.add(c.id)).toList();
          items.addAll(additions);
          offset += page.items.length;
          if (page.items.isEmpty ||
              (page.totalRecordCount == null
                  ? page.items.length < 200
                  : offset >= page.totalRecordCount!)) {
            break;
          }
          if (additions.isEmpty || i == 19) {
            throw StateError('Channel index is incomplete');
          }
        }
        _channels = items;
        _indexReady = true;
      }
      final channels = _visible;
      final programs = channels.isEmpty
          ? <LiveProgram>[]
          : await client.guidePrograms(
              channels.map((c) => c.id).toList(),
              _start,
            );
      if (!mounted || turn != _request) return;
      setState(() {
        _programs = programs;
        _loading = false;
      });
    } catch (_) {
      if (mounted && turn == _request) {
        setState(() {
          _error = 'The guide could not be loaded.';
          _loading = false;
        });
      }
    }
  }

  void _move(int hours) {
    final next = _start.add(Duration(hours: hours)), now = DateTime.now();
    if (next.isBefore(now.subtract(const Duration(days: 1))) ||
        next.isAfter(now.add(const Duration(days: 7)))) {
      return;
    }
    setState(() {
      _start = next;
      _programs = [];
    });
    _load();
  }

  void _filter() {
    _page = 0;
    _programs = [];
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load();
  }

  Future<void> _details(MediaItem channel, LiveProgram? program) async {
    final watch = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(program?.name ?? channel.name),
        content: SizedBox(
          width: 760,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(channel.name, style: Zoro.font(23, color: Zoro.muted)),
                if (program?.hasSchedule == true)
                  Text(
                    '${clockLabel(program!.start!)} – ${clockLabel(program.end!)}',
                    style: Zoro.font(23),
                  ),
                if (program?.overview?.isNotEmpty == true)
                  Padding(
                    padding: const EdgeInsets.only(top: 18),
                    child: Text(program!.overview!, style: Zoro.font(24)),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          ZoroButton(
            label: 'Close',
            onPressed: () => Navigator.pop(context, false),
          ),
          ZoroButton(
            label: 'Watch live',
            autofocus: true,
            primary: true,
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    if (watch == true && mounted) await widget.onPlay(channel);
  }

  @override
  Widget build(BuildContext context) {
    final channels = _visible;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Zoro.gutter, 20, Zoro.gutter, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (!widget.embedded)
                Text('Live TV', style: Zoro.font(34, weight: FontWeight.w700)),
              const Spacer(),
              Text(
                '${_start.month}/${_start.day} · ${clockLabel(_start)}',
                style: Zoro.font(24),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 14,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ZoroButton(
                label: _favorites ? 'Favorites' : 'All channels',
                onPressed: () {
                  _favorites = !_favorites;
                  _filter();
                },
              ),
              const SizedBox(width: 14),
              SizedBox(
                width: 360,
                child: TextField(
                  style: Zoro.font(24),
                  decoration: const InputDecoration(
                    hintText: 'Search channels',
                  ),
                  onChanged: (v) {
                    _query = v;
                    _search?.cancel();
                    _search = Timer(const Duration(milliseconds: 250), _filter);
                  },
                ),
              ),
              ZoroButton(label: 'Previous', onPressed: () => _move(-2)),
              const SizedBox(width: 12),
              ZoroButton(
                label: 'Now',
                onPressed: () {
                  setState(() {
                    _start = guideWindowStart(DateTime.now());
                    _programs = [];
                  });
                  _load();
                },
              ),
              const SizedBox(width: 12),
              ZoroButton(label: 'Next', onPressed: () => _move(2)),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: LiveTvNotice(onJoin: (channel) => widget.onPlay(channel)),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 3),
          if (_error != null)
            Row(
              children: [
                Text(_error!, style: Zoro.font(24)),
                const SizedBox(width: 20),
                ZoroButton(label: 'Try again', onPressed: _load),
              ],
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                const labelWidth = 260.0;
                final timelineWidth = (constraints.maxWidth - labelWidth).clamp(
                  200.0,
                  3000.0,
                );
                return Column(
                  children: [
                    Row(
                      children: [
                        const SizedBox(width: labelWidth),
                        for (var i = 0; i < 4; i++)
                          SizedBox(
                            width: timelineWidth / 4,
                            child: Text(
                              clockLabel(_start.add(Duration(minutes: i * 30))),
                              style: Zoro.font(21, color: Zoro.muted),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: channels.isEmpty && !_loading
                          ? Center(
                              child: Text(
                                _query.isEmpty
                                    ? 'No channels available'
                                    : 'No matching channels',
                                style: Zoro.font(28),
                              ),
                            )
                          : ListView.builder(
                              controller: _scroll,
                              itemCount: channels.length,
                              itemBuilder: (context, index) {
                                final channel = channels[index],
                                    slots = guideSlots(
                                      channel.id,
                                      _programs,
                                      _start,
                                    );
                                return SizedBox(
                                  height: 108,
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: labelWidth - 12,
                                        child: Focusable(
                                          onPressed: () =>
                                              _details(channel, null),
                                          builder: (context, focused) => Container(
                                            height: 96,
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 18,
                                            ),
                                            alignment: Alignment.centerLeft,
                                            decoration: BoxDecoration(
                                              color: Zoro.panel,
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                              border: Border.all(
                                                color: focused
                                                    ? Colors.white
                                                    : Zoro.border,
                                                width: focused ? 3 : 1,
                                              ),
                                            ),
                                            child: Text(
                                              '${channel.channelNumber ?? ''} ${channel.name}'
                                                  .trim(),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: Zoro.font(
                                                22,
                                                weight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      for (final slot in slots)
                                        SizedBox(
                                          width:
                                              timelineWidth *
                                              slot.end
                                                  .difference(slot.start)
                                                  .inMilliseconds /
                                              7200000,
                                          child: Padding(
                                            padding: const EdgeInsets.only(
                                              right: 6,
                                              bottom: 8,
                                            ),
                                            child: Focusable(
                                              onPressed: () => _details(
                                                channel,
                                                slot.program,
                                              ),
                                              builder: (context, focused) =>
                                                  Container(
                                                    padding:
                                                        const EdgeInsets.all(
                                                          14,
                                                        ),
                                                    decoration: BoxDecoration(
                                                      color: focused
                                                          ? Zoro.jade
                                                          : Zoro.panel,
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            10,
                                                          ),
                                                      border: Border.all(
                                                        color:
                                                            slot.program?.isAiring(
                                                                  DateTime.now(),
                                                                ) ==
                                                                true
                                                            ? Zoro.jade
                                                            : Colors
                                                                  .transparent,
                                                      ),
                                                    ),
                                                    child: Text(
                                                      slot.program?.name ??
                                                          (_loading
                                                              ? 'Loading…'
                                                              : 'No listings'),
                                                      maxLines: 2,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: Zoro.font(
                                                        22,
                                                        color: focused
                                                            ? Zoro.background
                                                            : Zoro.text,
                                                      ),
                                                    ),
                                                  ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (_page > 0)
                ZoroButton(
                  label: 'Previous channels',
                  onPressed: () {
                    _page--;
                    _programs = [];
                    _scroll.jumpTo(0);
                    _load();
                  },
                ),
              const SizedBox(width: 12),
              if ((_page + 1) * 40 < _filtered.length)
                ZoroButton(
                  label: 'More channels',
                  onPressed: () {
                    _page++;
                    _programs = [];
                    _scroll.jumpTo(0);
                    _load();
                  },
                ),
            ],
          ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }
}
