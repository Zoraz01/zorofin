import 'package:flutter/material.dart';

import '../../core/catalog.dart';
import '../../core/errors.dart';
import '../../core/models.dart';
import '../../core/plugin_extras.dart';
import '../player/player_panels.dart' show clockLabel;
import '../theme.dart';
import '../widgets/focusable.dart';
import 'settings_screen.dart';

/// Calendar (the plugin's extra, web `zorofin-extras-pages.js`): the next four
/// weeks of new episodes and movie releases from Sonarr and Radarr, by day.
/// Titles already on the server open their page. Phones show it inside
/// [CompactSettings].
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({
    super.key,
    required this.catalog,
    required this.onOpen,
    this.now,
  });

  final Catalog catalog;

  /// Opens a library title after this page closes.
  final ValueChanged<MediaItem> onOpen;

  /// For tests and screenshots.
  final DateTime Function()? now;

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  CalendarFilter _filter = CalendarFilter.all;
  List<CalendarEvent>? _events;
  String? _error;
  bool _opening = false;

  DateTime get _now => widget.now?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = widget.catalog.client;
    setState(() {
      _events = null;
      _error = null;
    });
    if (client == null) {
      setState(() => _events = const []);
      return;
    }
    try {
      final now = _now;
      final events = await client.calendar(
        DateTime(now.year, now.month, now.day),
      );
      if (mounted) setState(() => _events = events);
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _error =
            e is ClientError &&
                e.kind == ClientErrorKind.unavailable &&
                e.status == 404
            ? 'The Calendar is turned off on this server.'
            : 'Sonarr or Radarr didn’t answer. Try again in a moment.',
      );
    }
  }

  Future<void> _open(String id) async {
    if (_opening) return;
    _opening = true;
    try {
      final item = await widget.catalog.item(id);
      if (!mounted) return;
      Navigator.of(context).maybePop();
      widget.onOpen(item);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text('That title couldn’t be opened. Try again.'),
          ),
        );
      }
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final events = _events;
    final now = _now;
    final days = events == null
        ? const <CalendarDay>[]
        : CalendarAgenda.group(events, _filter, now);
    final filters = [
      for (final (i, f) in CalendarFilter.values.indexed) ...[
        if (i > 0) const SizedBox(width: 10),
        ZoroButton(
          label: f.label,
          primary: f == _filter,
          autofocus: f == _filter,
          onPressed: () => setState(() => _filter = f),
        ),
      ],
    ];
    final compact = CompactSettings.of(context);
    return SettingsScaffold(
      title: 'Calendar',
      // Phones: the filter sits under the title bar, not in it.
      actions: compact ? const [] : filters,
      children: [
        if (compact)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: filters),
          ),
        if (_error case final error?) ...[
          _Message(title: 'Couldn’t load the calendar', detail: error),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: ZoroButton(label: 'Try again', onPressed: _load),
          ),
        ] else if (events == null)
          // Not const: the accent can come from the server.
          Padding(
            padding: const EdgeInsets.all(40),
            child: Center(child: CircularProgressIndicator(color: Zoro.jade)),
          )
        else if (days.isEmpty)
          _Message(
            title: 'Nothing coming up',
            detail: _filter == CalendarFilter.all
                ? 'New episodes and movie releases from the next four weeks show here.'
                : 'Try Everything to see the rest.',
          )
        else
          for (final day in days) ...[
            Padding(
              padding: const EdgeInsets.only(top: 18, bottom: 8),
              child: Text(
                CalendarAgenda.label(day.day, now),
                style: settingsFont(context, 26, weight: FontWeight.w700),
              ),
            ),
            for (final e in day.events) _EventRow(event: e, onOpen: _open),
          ],
      ],
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event, required this.onOpen});

  final CalendarEvent event;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final compact = CompactSettings.of(context);
    final e = event;
    final id = e.itemId;
    final meta = [
      if (!e.allDay) clockLabel(e.at),
      if (e.badge.isNotEmpty) e.badge,
      if (e.hasFile) 'On the server',
      if ((e.network ?? '').isNotEmpty) e.network!,
    ];
    final posterWidth = compact ? 54.0 : 80.0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Focusable(
        // Rows without a library title stay focusable so a remote can scroll.
        onPressed: id == null ? () {} : () => onOpen(id),
        semanticLabel: [
          e.title,
          ?e.subtitle,
          ...meta,
          if (id != null) 'Open title',
        ].join(', '),
        builder: (context, focused) => AnimatedContainer(
          duration: Zoro.focusDuration,
          padding: EdgeInsets.all(compact ? 8 : 12),
          decoration: BoxDecoration(
            color: focused ? Zoro.text.withValues(alpha: 0.12) : Zoro.panel,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: focused ? Colors.white : Colors.transparent,
              width: 3,
            ),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: posterWidth,
                  height: posterWidth * 1.5,
                  child: _Poster(event: e),
                ),
              ),
              SizedBox(width: compact ? 12 : 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: settingsFont(context, 24, weight: FontWeight.w600),
                    ),
                    if (e.subtitle case final s? when s.isNotEmpty)
                      Text(
                        s,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: settingsFont(context, 20, color: Zoro.muted),
                      ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        meta.join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: settingsFont(
                          context,
                          18,
                          color: e.premiere ? Zoro.jade : Zoro.muted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (id != null)
                Icon(
                  Icons.chevron_right_rounded,
                  color: Zoro.muted,
                  size: compact ? 22 : 32,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Poster extends StatelessWidget {
  const _Poster({required this.event});

  final CalendarEvent event;

  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: const Color(0xFF151C18),
      child: Icon(
        event.isEpisode ? Icons.tv_rounded : Icons.movie_rounded,
        color: Zoro.border,
      ),
    );
    final url = event.posterUrl;
    if (url == null) return fallback;
    // Sonarr/Radarr's own public poster hosts; no server credentials sent.
    return Image.network(
      url.toString(),
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => fallback,
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.title, required this.detail});

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: settingsFont(context, 28, weight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(detail, style: settingsFont(context, 22, color: Zoro.muted)),
      ],
    ),
  );
}
