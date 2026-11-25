import 'dart:async';

import 'package:flutter/material.dart';

import '../core/catalog.dart';
import '../core/live_guide.dart';
import '../core/models.dart';
import '../ui/player/player_panels.dart' show clockLabel;
import '../ui/theme.dart';
import '../ui/widgets/live_tv_notice.dart';
import '../ui/widgets/media_card.dart' show Artwork;
import 'phone_scope.dart';
import 'phone_theme.dart';
import 'phone_widgets.dart';

/// Live TV (Apple `LiveGuideView` on iPhone): a two-hour guide fitted to the
/// screen, with channel search, Favorites and earlier/later windows. Tapping
/// a programme shows its details with Watch live.
class PhoneGuideScreen extends StatefulWidget {
  const PhoneGuideScreen({
    super.key,
    this.active = true,
    this.embedded = false,
  });

  final bool active;
  final bool embedded;

  @override
  State<PhoneGuideScreen> createState() => _PhoneGuideScreenState();
}

class _PhoneGuideScreenState extends State<PhoneGuideScreen> {
  static const _pageSize = 40;

  Catalog? _catalog;
  List<MediaItem> _channels = [];
  List<LiveProgram> _programs = [];
  DateTime _start = guideWindowStart(DateTime.now());
  int _page = 0, _request = 0;
  bool _loading = true, _favorites = false, _indexReady = false;
  String _query = '';
  String? _error;
  Timer? _refresh, _search;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final catalog = PhoneScope.of(context).catalog;
    if (catalog != _catalog) {
      _catalog = catalog;
      _request++;
      _channels = [];
      _programs = [];
      _indexReady = false;
      _page = 0;
      unawaited(_load());
      _refresh?.cancel();
      _refresh = Timer.periodic(const Duration(seconds: 60), (_) {
        if (mounted && widget.active) unawaited(_load());
      });
    }
  }

  @override
  void didUpdateWidget(PhoneGuideScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      _refresh?.cancel();
      _request++;
      _loading = false;
      if (widget.active) {
        unawaited(_load());
        _refresh = Timer.periodic(const Duration(seconds: 60), (_) => _load());
      }
    }
  }

  @override
  void dispose() {
    _request++;
    _refresh?.cancel();
    _search?.cancel();
    super.dispose();
  }

  Future<void> _chooseDate() async {
    final now = DateTime.now();
    final first = DateTime(now.year, now.month, now.day);
    final last = first.add(const Duration(days: 6));
    final initial = _start.isBefore(first)
        ? first
        : _start.isAfter(last)
        ? last
        : _start;
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
      helpText: 'Guide date',
    );
    if (!mounted || date == null) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_start),
      helpText: 'Guide time',
    );
    if (!mounted || time == null) return;
    setState(() {
      _start = guideWindowStart(
        DateTime(date.year, date.month, date.day, time.hour, time.minute),
      );
      _page = 0;
    });
    unawaited(_load());
  }

  List<MediaItem> get _filtered => _channels
      .where(
        (c) =>
            (!_favorites || c.userData?.isFavorite == true) &&
            '${c.channelNumber ?? ''} ${c.name}'.toLowerCase().contains(
              _query.toLowerCase(),
            ),
      )
      .toList();

  List<MediaItem> get _visible =>
      _filtered.take((_page + 1) * _pageSize).toList();

  Future<void> _load() async {
    if (!widget.active) return;
    final catalog = _catalog;
    final client = catalog is JellyfinCatalog ? catalog.client : null;
    if (client == null) {
      // The preview has no tuner: show its fictional channels only.
      final page = await catalog?.browse(LibraryKind.live);
      if (!mounted) return;
      setState(() {
        _channels = page?.items ?? const [];
        _loading = false;
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
    unawaited(_load());
  }

  void _filter() {
    _page = 0;
    _programs = [];
    unawaited(_load());
  }

  Future<void> _details(MediaItem channel, LiveProgram? program) async {
    final scope = PhoneScope.of(context);
    final now = DateTime.now();
    final airing =
        program == null ||
        !program.hasSchedule ||
        (!program.start!.isAfter(now) && program.end!.isAfter(now));
    final watch = await showModalBottomSheet<bool>(
      context: context,
      // Above the dock, which sits over pushed pages.
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                program?.name ?? channel.name,
                style: Zoro.font(20, weight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                channel.name +
                    (channel.channelNumber == null
                        ? ''
                        : ' · Ch ${channel.channelNumber}'),
                style: Zoro.font(14, color: Zoro.muted),
              ),
              if (program?.hasSchedule == true)
                Text(
                  '${clockLabel(program!.start!)} – ${clockLabel(program.end!)}',
                  style: Zoro.font(14),
                ),
              if (program?.overview?.isNotEmpty == true) ...[
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: Text(
                      program!.overview!,
                      style: Zoro.font(15, color: Zoro.muted),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              PillButton(
                label: airing ? 'Watch live' : 'Watch channel',
                icon: Icons.play_arrow_rounded,
                primary: true,
                expand: true,
                onPressed: () => Navigator.of(context).pop(true),
              ),
            ],
          ),
        ),
      ),
    );
    if (watch == true && mounted) await scope.play(channel);
  }

  @override
  Widget build(BuildContext context) {
    final scope = PhoneScope.of(context);
    final media = MediaQuery.of(context);
    final channels = _visible;
    final now = DateTime.now();
    final labelWidth = PhoneWindow.of(context).wide ? 180.0 : 104.0;
    return Scaffold(
      backgroundColor: Zoro.background,
      body: RefreshIndicator(
        color: Zoro.jade,
        onRefresh: () {
          _indexReady = false;
          return _load();
        },
        child: CustomScrollView(
          slivers: [
            if (!widget.embedded)
              SliverPadding(
                padding: EdgeInsets.only(top: media.padding.top + 8),
                sliver: SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(
                      left: 4,
                      right: Phone.gutter,
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: 'Back to Home',
                          icon: const Icon(
                            Icons.chevron_left_rounded,
                            size: 32,
                          ),
                          onPressed: () => scope.select(PhoneDestination.home),
                        ),
                        Expanded(
                          child: Text(
                            'Live TV',
                            style: Zoro.font(28, weight: FontWeight.w700),
                          ),
                        ),
                        Text(
                          '${_start.month}/${_start.day} · ${clockLabel(_start)}',
                          style: Zoro.font(14, color: Zoro.muted),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Phone.gutter,
                  12,
                  Phone.gutter,
                  0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.embedded)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          '${_start.month}/${_start.day} · ${clockLabel(_start)}',
                          style: Zoro.font(14, color: Zoro.muted),
                        ),
                      ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        icon: const Icon(Icons.calendar_month_rounded),
                        label: const Text('Choose date & time'),
                        onPressed: _chooseDate,
                      ),
                    ),
                    TextField(
                      style: Zoro.font(16),
                      decoration: const InputDecoration(
                        hintText: 'Search channels',
                        prefixIcon: Icon(Icons.search_rounded),
                      ),
                      onChanged: (v) {
                        _query = v;
                        _search?.cancel();
                        _search = Timer(
                          const Duration(milliseconds: 250),
                          _filter,
                        );
                      },
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        FilterChip(
                          label: const Text('Favorites'),
                          selected: _favorites,
                          showCheckmark: false,
                          selectedColor: Zoro.jade,
                          labelStyle: Zoro.font(
                            14,
                            weight: FontWeight.w600,
                            color: _favorites ? Zoro.background : Zoro.text,
                          ),
                          backgroundColor: Zoro.panel,
                          side: const BorderSide(color: Zoro.border),
                          shape: const StadiumBorder(),
                          onSelected: (v) {
                            _favorites = v;
                            _filter();
                          },
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: 'Earlier',
                          icon: const Icon(Icons.chevron_left_rounded),
                          onPressed: () => _move(-2),
                        ),
                        TextButton(
                          onPressed: () {
                            setState(() {
                              _start = guideWindowStart(DateTime.now());
                              _programs = [];
                            });
                            unawaited(_load());
                          },
                          child: const Text('Now'),
                        ),
                        IconButton(
                          tooltip: 'Later',
                          icon: const Icon(Icons.chevron_right_rounded),
                          onPressed: () => _move(2),
                        ),
                      ],
                    ),
                    if (widget.active)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: LiveTvNotice(
                          onJoin: (channel) =>
                              PhoneScope.of(context).play(channel),
                        ),
                      ),
                    if (_loading) const LinearProgressIndicator(minHeight: 2),
                    if (_error != null)
                      PhoneStatus(
                        title: _error!,
                        icon: Icons.wifi_off_rounded,
                        action: PillButton(
                          label: 'Try again',
                          onPressed: _load,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (!_loading && _error == null && channels.isEmpty)
              SliverToBoxAdapter(
                child: PhoneStatus(
                  title: scope.catalog.isPreview
                      ? 'Live TV needs your server'
                      : 'No channels',
                  icon: Icons.live_tv_rounded,
                  detail: scope.catalog.isPreview
                      ? 'Connect a Jellyfin server with a tuner or IPTV source to see its channels and guide here.'
                      : 'Channels your server offers will appear here.',
                ),
              ),
            if (channels.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: Phone.gutter),
                sliver: SliverToBoxAdapter(
                  child: _TimeHeader(start: _start, labelWidth: labelWidth),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: Phone.gutter),
              sliver: SliverList.builder(
                itemCount: channels.length,
                itemBuilder: (context, i) {
                  final channel = channels[i];
                  final slots = guideSlots(channel.id, _programs, _start);
                  return _GuideRow(
                    channel: channel,
                    slots: slots,
                    start: _start,
                    now: now,
                    labelWidth: labelWidth,
                    catalog: scope.catalog,
                    onChannel: () => _details(
                      channel,
                      slots
                          .where(
                            (s) =>
                                s.program != null &&
                                !s.start.isAfter(now) &&
                                s.end.isAfter(now),
                          )
                          .firstOrNull
                          ?.program,
                    ),
                    onProgram: (p) => _details(channel, p),
                  );
                },
              ),
            ),
            if (_filtered.length > channels.length)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Center(
                    child: PillButton(
                      label: 'More channels',
                      onPressed: () {
                        setState(() => _page++);
                        unawaited(_load());
                      },
                    ),
                  ),
                ),
              ),
            SliverPadding(
              padding: EdgeInsets.only(bottom: media.padding.bottom + 16),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimeHeader extends StatelessWidget {
  const _TimeHeader({required this.start, required this.labelWidth});

  final DateTime start;
  final double labelWidth;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 6),
    child: Row(
      children: [
        SizedBox(width: labelWidth + 8),
        for (var i = 0; i < 4; i++)
          Expanded(
            child: Text(
              clockLabel(start.add(Duration(minutes: 30 * i))),
              style: Zoro.font(11, weight: FontWeight.w600, color: Zoro.muted),
            ),
          ),
      ],
    ),
  );
}

class _GuideRow extends StatelessWidget {
  const _GuideRow({
    required this.channel,
    required this.slots,
    required this.start,
    required this.now,
    required this.labelWidth,
    required this.catalog,
    required this.onChannel,
    required this.onProgram,
  });

  final MediaItem channel;
  final List<GuideSlot> slots;
  final DateTime start;
  final DateTime now;
  final double labelWidth;
  final Catalog catalog;
  final VoidCallback onChannel;
  final ValueChanged<LiveProgram?> onProgram;

  @override
  Widget build(BuildContext context) {
    const total = 120.0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: SizedBox(
        height: 60,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              button: true,
              label: 'Watch ${channel.name}',
              excludeSemantics: true,
              child: GestureDetector(
                onTap: onChannel,
                child: Container(
                  width: labelWidth,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: Zoro.panel,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      if (channel.imageTags['Primary'] != null)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: SizedBox(
                            width: 28,
                            height: 28,
                            child: Artwork(
                              fit: BoxFit.contain,
                              url: catalog.artwork(
                                channel,
                                landscape: false,
                                width: 96,
                              ),
                              headers: catalog.imageHeaders,
                              title: channel.name,
                              seed: channel.id,
                            ),
                          ),
                        ),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (channel.channelNumber != null)
                              Text(
                                channel.channelNumber!,
                                style: Zoro.font(11, color: Zoro.muted),
                              ),
                            Text(
                              channel.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Zoro.font(12, weight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: slots.isEmpty
                  ? _cell(null, 1, false)
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final slot in slots)
                          Expanded(
                            flex:
                                (slot.end.difference(slot.start).inMinutes /
                                        total *
                                        1000)
                                    .round()
                                    .clamp(1, 1000),
                            child: _cell(
                              slot.program,
                              1,
                              !slot.start.isAfter(now) && slot.end.isAfter(now),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cell(LiveProgram? program, int _, bool airing) => Padding(
    padding: const EdgeInsets.only(right: 3),
    child: Semantics(
      button: true,
      label: program == null
          ? '${channel.name}, no guide information'
          : '${program.name}${airing ? ', on now' : ''}',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: () => onProgram(program),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          decoration: BoxDecoration(
            color: airing ? const Color(0xFF24543E) : const Color(0xFF161B18),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: airing ? Zoro.jade.withValues(alpha: .5) : Zoro.border,
              width: .6,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                program?.name ?? 'No information',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Zoro.font(
                  11,
                  weight: FontWeight.w600,
                  color: program == null ? Zoro.muted : Zoro.text,
                ),
              ),
              if (program?.hasSchedule == true)
                Text(
                  clockLabel(program!.start!),
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: Zoro.font(10, color: Zoro.muted),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
