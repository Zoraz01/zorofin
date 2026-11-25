import 'dart:async';

import 'package:flutter/material.dart';
import '../ui/widgets/episode_status.dart';

import '../core/catalog.dart';
import '../core/errors.dart';
import '../core/media_quality.dart';
import '../core/models.dart';
import '../core/playback.dart';
import '../core/preferences.dart';
import '../ui/theme.dart';
import '../ui/widgets/live_tv_notice.dart';
import '../ui/widgets/media_card.dart' show Artwork;
import 'phone_downloads.dart';
import 'phone_home.dart' show PhoneFavoriteButton;
import 'phone_scope.dart';
import 'phone_theme.dart';
import 'phone_widgets.dart';

/// Title details (Apple `DetailView` on iPhone and iPad): artwork beside the
/// heading, quality badges, a full-width Play with round actions under it,
/// synopsis, genres, seasons and episodes, cast and More Like This. Wide
/// windows put the artwork in a column beside everything else, as iPad does.
class PhoneDetailScreen extends StatefulWidget {
  const PhoneDetailScreen({super.key, required this.item});

  final MediaItem item;

  @override
  State<PhoneDetailScreen> createState() => _PhoneDetailScreenState();
}

class _PhoneDetailScreenState extends State<PhoneDetailScreen> {
  late MediaItem _item = widget.item;
  MediaItem? _next;
  List<MediaItem> _similar = const [];
  String? _failure;
  bool _loading = true;
  bool? _played;
  bool _changingPlayed = false;
  int? _audioIndex;
  int _subtitleIndex = PlaybackOptions.automatic;
  final _browserKey = GlobalKey();
  Catalog? _catalog;
  int _revision = -1;

  bool get _isPlayed => _played ?? _item.userData?.played ?? false;

  MediaItem? get _playable =>
      _item.isSeries || _item.type == 'Season' ? _next : _item;

  MediaItem get _qualityItem => _playable ?? _item;

  List<MediaStream> get _streams {
    final item = _qualityItem;
    final source = item.mediaSources.firstOrNull?.mediaStreams ?? const [];
    return source.isNotEmpty ? source : item.mediaStreams;
  }

  bool get _downloadable =>
      !_item.isLive && (_item.type == 'Movie' || _item.isEpisode);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = PhoneScope.of(context);
    // Reload after playback so Resume and watched state are current.
    if (scope.catalog != _catalog || scope.revision != _revision) {
      _catalog = scope.catalog;
      _revision = scope.revision;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final catalog = _catalog!;
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final full = await catalog.item(widget.item.id);
      MediaItem? next;
      if (full.isSeries || full.type == 'Season') {
        next = await catalog.nextEpisode(full);
        // One detail read for the next episode, for its tracks and file.
        if (next != null) {
          try {
            next = await catalog.item(next.id);
          } on ClientError {
            // The summary is enough to play.
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _item = full;
        _next = next;
        _played = null;
      });
    } on ClientError catch (e) {
      if (mounted) setState(() => _failure = e.message);
    } catch (_) {
      if (mounted) setState(() => _failure = 'Something went wrong.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    try {
      final similar = await catalog.similar(widget.item);
      if (mounted) setState(() => _similar = similar);
    } catch (_) {
      // More Like This is optional.
    }
  }

  Future<void> _play(MediaItem playable, int startTicks) {
    final subtitle = _streams
        .where((s) => s.type == 'Subtitle' && s.index == _subtitleIndex)
        .firstOrNull;
    return PhoneScope.of(context).play(
      playable,
      startTicks: startTicks,
      audioIndex: _audioIndex,
      subtitleIndex: _subtitleIndex,
      burnSubtitles: subtitle != null && !subtitle.isTextSubtitle,
    );
  }

  Future<void> _togglePlayed() async {
    if (_changingPlayed) return;
    final next = !_isPlayed;
    setState(() {
      _changingPlayed = true;
      _played = next;
    });
    try {
      final result = await _catalog!.setPlayed(_item, next);
      if (mounted) setState(() => _played = result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _played = !next);
      showPhoneMessage(
        context,
        e is ClientError ? e.message : 'Watched state couldn’t be saved.',
      );
    } finally {
      if (mounted) setState(() => _changingPlayed = false);
    }
  }

  static String _streamTitle(MediaStream stream) =>
      stream.displayTitle ?? stream.language ?? 'Track ${stream.index}';

  Future<void> _chooseTrack(String type) async {
    final tracks = _streams.where((s) => s.type == type).toList();
    if (tracks.isEmpty) {
      showPhoneMessage(
        context,
        type == 'Audio' ? 'No audio tracks.' : 'No subtitles available.',
      );
      return;
    }
    final audio = type == 'Audio';
    final options = <(int, String)>[
      (audio ? -999 : PlaybackOptions.automatic, 'Automatic'),
      if (!audio) (-1, 'Off'),
      for (final s in tracks) (s.index, _streamTitle(s)),
    ];
    final selected = audio ? (_audioIndex ?? -999) : _subtitleIndex;
    final choice = await showPhoneChoices<int>(
      context,
      title: audio ? 'Audio' : 'Subtitles',
      options: options,
      selected: selected,
    );
    if (choice == null || !mounted) return;
    setState(() {
      if (audio) {
        _audioIndex = choice == -999 ? null : choice;
      } else {
        _subtitleIndex = choice;
      }
    });
  }

  void _showEpisodes() {
    final target = _browserKey.currentContext;
    if (target != null) {
      unawaited(
        Scrollable.ensureVisible(
          target,
          duration: const Duration(milliseconds: 300),
        ),
      );
    }
  }

  void _showFileDetails() => unawaited(
    showModalBottomSheet<void>(
      context: context,
      // Above the dock, which sits over pushed pages.
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) =>
          PhoneFileDetails(item: _qualityItem, audioIndex: _audioIndex),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scope = PhoneScope.of(context);
    final catalog = scope.catalog;
    final media = MediaQuery.of(context);
    final item = _item;
    final columns = media.size.width >= 720 && !_largeText(context);
    final short = media.size.height < 500;
    final landscape = item.isEpisode || item.isLive;
    final artwork = ClipRRect(
      borderRadius: BorderRadius.circular(columns ? 16 : 14),
      child: AspectRatio(
        aspectRatio: landscape ? 16 / 9 : 2 / 3,
        child: Artwork(
          url: catalog.artwork(item, landscape: landscape, width: 900),
          headers: catalog.imageHeaders,
          title: item.displayTitle,
          seed: item.id,
          showTitle: catalog.isPreview,
        ),
      ),
    );
    final overview = <Widget>[
      if (columns)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: landscape
                  ? (media.size.width * .38).clamp(0, 360).toDouble()
                  : 220,
              child: artwork,
            ),
            const SizedBox(width: 28),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // A sideways phone is short: a smaller heading with the
                  // actions straight after it keeps them above the dock.
                  if (short) ...[
                    _Heading(item: item, compact: true),
                    const SizedBox(height: 14),
                    _actions(),
                    ..._badges(),
                  ] else ...[
                    _Heading(item: item, wide: true),
                    ..._badges(),
                    const SizedBox(height: 24),
                    _actions(),
                  ],
                  const SizedBox(height: 24),
                  ..._synopsis(),
                ],
              ),
            ),
          ],
        )
      else ...[
        if (landscape) ...[
          artwork,
          const SizedBox(height: 18),
          _Heading(item: item),
        ] else if (_largeText(context)) ...[
          SizedBox(width: 150, child: artwork),
          const SizedBox(height: 20),
          _Heading(item: item),
        ] else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: (media.size.width * .36).clamp(100, 150).toDouble(),
                child: artwork,
              ),
              const SizedBox(width: 18),
              Expanded(child: _Heading(item: item)),
            ],
          ),
        ..._badges(),
        const SizedBox(height: 18),
        _actions(),
        const SizedBox(height: 18),
        ..._synopsis(),
      ],
    ];
    final seriesId = item.episodeSeriesId;
    return Scaffold(
      backgroundColor: Zoro.background,
      appBar: AppBar(
        backgroundColor: Zoro.background.withValues(alpha: .92),
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        title: Text(
          item.displayTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Zoro.font(17, weight: FontWeight.w600),
        ),
      ),
      body: RefreshIndicator(
        color: Zoro.jade,
        onRefresh: _load,
        child: ListView(
          padding: EdgeInsets.only(top: 12, bottom: media.padding.bottom + 24),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Phone.gutter),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ...overview,
                  if (item.isLive) ...[
                    const SizedBox(height: 18),
                    LiveTvNotice(
                      channelId: item.id,
                      onJoin: (channel) => PhoneScope.of(context).play(channel),
                    ),
                  ],
                  if (item.genres.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Zoro.panel,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Genres',
                            style: Zoro.font(16, color: Zoro.muted),
                          ),
                          const SizedBox(width: 20),
                          Expanded(
                            child: Text(
                              item.genres.join(', '),
                              style: Zoro.font(16, color: Zoro.jade),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (seriesId != null) ...[
                    const SizedBox(height: 24),
                    PhoneSeasonBrowser(
                      key: _browserKey,
                      context: item,
                      currentEpisodeId: item.isEpisode ? item.id : _next?.id,
                      preferredEpisode: item.isEpisode ? item : _next,
                    ),
                  ],
                  if (_loading && _failure == null)
                    const Padding(
                      padding: EdgeInsets.only(top: 18),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  if (_failure != null)
                    PhoneStatus(
                      title: 'Some details couldn’t load',
                      detail: _failure,
                      icon: Icons.wifi_off_rounded,
                      action: PillButton(label: 'Try again', onPressed: _load),
                    ),
                ],
              ),
            ),
            if (item.people.isNotEmpty) ...[
              const SizedBox(height: 32),
              _CastShelf(people: item.people.take(24).toList()),
            ],
            if (_similar.isNotEmpty) ...[
              const SizedBox(height: 32),
              PhoneShelf(
                title: 'More Like This',
                items: _similar,
                catalog: catalog,
                onOpen: scope.open,
                landscape: true,
              ),
            ],
          ],
        ),
      ),
    );
  }

  static bool _largeText(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(1) > 1.6;

  List<Widget> _badges() {
    final badges = _qualityItem.quality(audioIndex: _audioIndex).badges;
    if (badges.isEmpty) return const [];
    return [
      const SizedBox(height: 16),
      if (_item.isSeries || _item.type == 'Season') ...[
        Text(
          'Next episode · ${_qualityItem.episodeLabel}',
          style: Zoro.font(12, color: Zoro.muted),
        ),
        const SizedBox(height: 8),
      ],
      Semantics(
        label: 'Quality, ${badges.join(', ')}',
        excludeSemantics: true,
        child: Wrap(
          spacing: 7,
          runSpacing: 7,
          children: [
            for (final badge in badges)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: Zoro.panel,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: Zoro.border),
                ),
                child: Text(
                  badge,
                  style: Zoro.font(12, weight: FontWeight.w600),
                ),
              ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _synopsis() => [
    if (_item.taglines.isNotEmpty) ...[
      Text(_item.taglines.first, style: Zoro.font(17, weight: FontWeight.w600)),
      const SizedBox(height: 10),
    ],
    if (_item.plainOverview case final overview? when overview.isNotEmpty)
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Text(
          overview,
          style: Zoro.font(16, color: Zoro.muted).copyWith(height: 1.45),
        ),
      ),
  ];

  String _trackValue(String type, int index) {
    final tracks = _streams.where((s) => s.type == type).toList();
    if (tracks.isEmpty) {
      return type == 'Audio' ? 'No audio tracks' : 'No subtitles available';
    }
    if (index == -1) return 'Off';
    final match = tracks.where((s) => s.index == index).firstOrNull;
    return match == null ? 'Automatic' : _streamTitle(match);
  }

  Widget _actions() {
    final playable = _playable;
    final resume = (playable?.resumeTicks ?? 0) > 0;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PillButton(
            label: resume
                ? 'Resume'
                : (_item.isSeries ? 'Play next episode' : 'Play'),
            icon: Icons.play_arrow_rounded,
            primary: true,
            expand: true,
            onPressed: playable == null
                ? null
                : () => _play(playable, playable.resumeTicks),
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            runSpacing: 10,
            children: [
              PhoneFavoriteButton(item: _item, labeled: true),
              PillButton(
                icon: _isPlayed
                    ? Icons.check_circle_rounded
                    : Icons.check_circle_outline_rounded,
                label: _isPlayed ? 'Mark unwatched' : 'Mark watched',
                onPressed: _changingPlayed ? null : _togglePlayed,
              ),
              if (resume && playable != null)
                PillButton(
                  icon: Icons.replay_rounded,
                  label: 'Start over',
                  onPressed: () => _play(playable, 0),
                ),
              if (_downloadable)
                PhoneDownloadButton(
                  item: _item,
                  audioIndex: _audioIndex,
                  subtitleIndex: _subtitleIndex,
                ),
              // Continue Watching opens episodes here, so the show is one
              // tap away (Apple `detail-view-series`).
              if (_item.isEpisode && _item.seriesId != null)
                PillButton(
                  icon: Icons.tv_rounded,
                  label: 'View series',
                  onPressed: () => PhoneScope.of(context).open(
                    MediaItem(
                      id: _item.seriesId!,
                      name: _item.seriesName ?? 'Series',
                      type: 'Series',
                    ),
                  ),
                ),
              if (_item.episodeSeriesId != null)
                PillButton(
                  icon: Icons.video_library_outlined,
                  label: 'Seasons and episodes',
                  onPressed: _showEpisodes,
                ),
              if (_qualityItem.fileQualities.any((q) => q.facts.isNotEmpty))
                PillButton(
                  icon: Icons.info_outline_rounded,
                  label: 'File details',
                  onPressed: _showFileDetails,
                ),
            ],
          ),
          if (_streams.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final type in ['Audio', 'Subtitle'])
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: Zoro.panel,
                  borderRadius: BorderRadius.circular(12),
                  child: ListTile(
                    title: Text(
                      type == 'Audio' ? 'Audio' : 'Subtitles',
                      style: Zoro.font(16, weight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      _trackValue(
                        type,
                        type == 'Audio' ? _audioIndex ?? -999 : _subtitleIndex,
                      ),
                      style: Zoro.font(14, color: Zoro.muted),
                    ),
                    leading: Icon(
                      type == 'Audio'
                          ? Icons.graphic_eq_rounded
                          : Icons.closed_caption_outlined,
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _chooseTrack(type),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// A list of choices in a bottom sheet (Apple `Menu` with a `Picker`).
Future<T?> showPhoneChoices<T>(
  BuildContext context, {
  required String title,
  required List<(T, String)> options,
  required T selected,
}) => showModalBottomSheet<T>(
  context: context,
  // Above the dock, which sits over pushed pages.
  useRootNavigator: true,
  useSafeArea: true,
  isScrollControlled: true,
  builder: (context) => ConstrainedBox(
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * .7,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text(title, style: Zoro.font(20, weight: FontWeight.w700)),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              for (final (value, label) in options)
                ListTile(
                  minTileHeight: Phone.target,
                  leading: SizedBox(
                    width: 24,
                    child: value == selected
                        ? Icon(Icons.check_rounded, color: Zoro.jade)
                        : null,
                  ),
                  title: Text(
                    label,
                    style: Zoro.font(
                      16,
                      weight: value == selected
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                  onTap: () => Navigator.of(context).pop(value),
                ),
            ],
          ),
        ),
      ],
    ),
  ),
);

class _Heading extends StatelessWidget {
  const _Heading({required this.item, this.wide = false, this.compact = false});

  final MediaItem item;
  final bool wide;

  /// Short landscape windows: one title line and no rating row.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final rating = item.communityRating;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.circle, size: 8, color: Zoro.jade),
            const SizedBox(width: 6),
            Text(
              item.type.toUpperCase(),
              style: Zoro.font(
                11,
                weight: FontWeight.w600,
                color: Zoro.jade,
              ).copyWith(letterSpacing: 1.1),
            ),
          ],
        ),
        SizedBox(height: wide ? 14 : (compact ? 6 : 10)),
        Text(
          item.displayTitle,
          maxLines: compact ? 1 : null,
          overflow: compact ? TextOverflow.ellipsis : null,
          style: Zoro.font(
            wide ? 40 : 27,
            weight: FontWeight.w700,
          ).copyWith(height: 1.12),
        ),
        if (item.isEpisode) ...[
          const SizedBox(height: 6),
          Text(item.episodeLabel, style: Zoro.font(17, color: Zoro.muted)),
        ],
        const SizedBox(height: 10),
        PhoneMetadataLine(item),
        if (rating != null && !compact) ...[
          const SizedBox(height: 10),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.star_rounded, color: Colors.yellow, size: 18),
              const SizedBox(width: 4),
              Text(
                rating.toStringAsFixed(1),
                style: Zoro.font(16, color: Colors.yellow),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// File details (Apple `MediaFileInfoView`): each version's source facts,
/// with no paths, stream URLs or credentials.
class PhoneFileDetails extends StatelessWidget {
  const PhoneFileDetails({super.key, required this.item, this.audioIndex});

  final MediaItem item;
  final int? audioIndex;

  @override
  Widget build(BuildContext context) {
    final versions = <MediaQuality>[...item.fileQualities];
    if (versions.isNotEmpty) versions[0] = item.quality(audioIndex: audioIndex);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .7,
      maxChildSize: .95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'File details',
                  style: Zoro.font(20, weight: FontWeight.w700),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            item.displayTitle,
            style: Zoro.font(17, weight: FontWeight.w600),
          ),
          if (item.isEpisode)
            Text(item.episodeLabel, style: Zoro.font(15, color: Zoro.muted)),
          for (final (i, quality) in versions.indexed) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Zoro.panel,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (versions.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Version ${i + 1}',
                        style: Zoro.font(16, weight: FontWeight.w600),
                      ),
                    ),
                  if (quality.facts.isEmpty)
                    Text(
                      'File information is unavailable.',
                      style: Zoro.font(15, color: Zoro.muted),
                    ),
                  for (final (title, value) in quality.facts)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: Zoro.font(15, color: Zoro.muted)),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(
                              value,
                              textAlign: TextAlign.right,
                              style: Zoro.font(15),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            'Source file information. Playback quality can change with your '
            'connection, device and streaming settings.',
            style: Zoro.font(13, color: Zoro.muted),
          ),
        ],
      ),
    );
  }
}

/// Seasons & episodes (Apple `SeasonEpisodeBrowser` on iPhone): a season
/// menu, then episode cards stacked down the page (a row on wide windows).
class PhoneSeasonBrowser extends StatefulWidget {
  const PhoneSeasonBrowser({
    super.key,
    required this.context,
    this.currentEpisodeId,
    this.preferredEpisode,
  });

  final MediaItem context;
  final String? currentEpisodeId;
  final MediaItem? preferredEpisode;

  @override
  State<PhoneSeasonBrowser> createState() => _PhoneSeasonBrowserState();
}

class _PhoneSeasonBrowserState extends State<PhoneSeasonBrowser> {
  List<MediaItem>? _seasons;
  String? _seasonId;
  List<MediaItem>? _episodes;
  bool _hasMore = false;
  bool _loadingMore = false;
  String? _error;
  Catalog? _catalog;
  int _scope = 0, _request = 0, _selection = 0;
  final _currentKey = GlobalKey();
  bool _returning = false;
  MediaItem? get _target =>
      widget.context.isEpisode ? widget.context : widget.preferredEpisode;
  bool _manuallySelected = false;
  @override
  void didUpdateWidget(covariant PhoneSeasonBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    final season = _target?.seasonId;
    if (!_manuallySelected &&
        widget.context.type == 'Series' &&
        season != null &&
        oldWidget.preferredEpisode?.id != widget.preferredEpisode?.id &&
        (_seasons?.any((s) => s.id == season) ?? false)) {
      unawaited(_select(season));
    }
  }

  Future<void> _returnCurrent() async {
    final season = _target?.seasonId;
    if (season == null) return;
    _returning = true;
    await _select(season);
    if (!mounted || !_returning) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final current = _currentKey.currentContext;
      if (mounted && _returning && current != null) {
        Scrollable.ensureVisible(current, alignment: .25);
      }
      _returning = false;
    });
  }

  String get _seriesId => widget.context.episodeSeriesId!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final catalog = PhoneScope.of(context).catalog;
    if (catalog != _catalog) {
      _catalog = catalog;
      unawaited(PhoneDownloads.instance.refreshPermission());
      _scope++;
      _request++;
      _selection++;
      _loadingMore = false;
      _seasons = null;
      _episodes = null;
      _seasonId = null;
      unawaited(_loadSeasons());
    }
  }

  Future<void> _loadSeasons() async {
    final scope = _scope;
    final catalog = _catalog!;
    setState(() => _error = null);
    try {
      final seasons = await catalog.seasons(_seriesId);
      if (!mounted || scope != _scope || !identical(catalog, _catalog)) return;
      final c = widget.context;
      final preferred = c.type == 'Season'
          ? c.id
          : _target?.seasonId ?? c.seasonId;
      final initial =
          seasons.where((s) => s.id == preferred).firstOrNull ??
          seasons.where((s) => (s.indexNumber ?? 0) > 0).firstOrNull ??
          seasons.firstOrNull;
      if (!mounted) return;
      setState(() => _seasons = seasons);
      if (initial != null) await _select(initial.id);
    } on ClientError catch (e) {
      if (mounted && scope == _scope) setState(() => _error = e.message);
    } catch (_) {
      if (mounted && scope == _scope) {
        setState(() => _error = 'Seasons couldn’t load.');
      }
    }
  }

  Future<void> _select(String seasonId) async {
    final selection = ++_selection;
    ++_request;
    setState(() {
      _loadingMore = false;
      _seasonId = seasonId;
      _episodes = null;
      _hasMore = false;
      _error = null;
    });
    await _loadMore();
    final current = widget.currentEpisodeId;
    for (var i = 0; i < 10 && current != null; i++) {
      if (!mounted ||
          selection != _selection ||
          _seasonId != seasonId ||
          !_hasMore ||
          _target?.seasonId != seasonId) {
        break;
      }
      if (_episodes?.any((e) => e.id == current) ?? false) break;
      await _loadMore();
    }
  }

  Future<void> _loadMore() async {
    final seasonId = _seasonId;
    if (seasonId == null || _loadingMore) return;
    final request = ++_request;
    final catalog = _catalog!;
    final have = _episodes ?? const <MediaItem>[];
    setState(() {
      _loadingMore = true;
      _error = null;
    });
    try {
      final page = await catalog.episodePage(
        _seriesId,
        seasonId,
        start: have.length,
      );
      if (!mounted ||
          _seasonId != seasonId ||
          request != _request ||
          !identical(catalog, _catalog)) {
        return;
      }
      final seen = {for (final e in have) e.id};
      final fresh = page.items.where((e) => seen.add(e.id)).toList();
      final count = have.length + fresh.length;
      final total = page.totalRecordCount;
      setState(() {
        _episodes = [...have, ...fresh];
        _hasMore =
            fresh.isNotEmpty &&
            (total == null
                ? page.items.length >= episodePageSize
                : count < total);
      });
    } on ClientError catch (e) {
      if (mounted && _seasonId == seasonId && request == _request) {
        setState(() => _error = e.message);
      }
    } catch (_) {
      if (mounted && _seasonId == seasonId && request == _request) {
        setState(() => _error = 'Episodes couldn’t load.');
      }
    } finally {
      if (mounted && request == _request) setState(() => _loadingMore = false);
    }
  }

  static String _title(MediaItem season) => season.name.isNotEmpty
      ? season.name
      : 'Season ${season.indexNumber ?? ''}';

  Future<void> _chooseSeason() async {
    final seasons = _seasons;
    if (seasons == null || seasons.isEmpty) return;
    final choice = await showPhoneChoices<String>(
      context,
      title: 'Season',
      options: [for (final s in seasons) (s.id, _title(s))],
      selected: _seasonId ?? '',
    );
    if (choice != null && choice != _seasonId && mounted) {
      _manuallySelected = true;
      _returning = false;
      await _select(choice);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = PhoneScope.of(context);
    final c = widget.context;
    final seasons = _seasons;
    final selected = seasons?.where((s) => s.id == _seasonId).firstOrNull;
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final episodes = _episodes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Seasons & episodes',
                style: Zoro.font(20, weight: FontWeight.w700),
              ),
            ),
            if (c.isEpisode && c.seriesId != null)
              TextButton(
                style: TextButton.styleFrom(foregroundColor: Zoro.jade),
                onPressed: () => scope.open(
                  MediaItem(
                    id: c.seriesId!,
                    name: c.seriesName ?? 'Series',
                    type: 'Series',
                  ),
                ),
                child: const Text('View series'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (seasons == null && _error == null)
          const EpisodeStatus(
            title: 'Loading seasons…',
            detail: 'Finding seasons for this series.',
            loading: true,
          )
        else if (seasons != null && seasons.isNotEmpty) ...[
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Material(
                color: Zoro.panel,
                shape: const StadiumBorder(),
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: _chooseSeason,
                  child: Container(
                    constraints: const BoxConstraints(minHeight: Phone.target),
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          selected == null ? 'Choose season' : _title(selected),
                          style: Zoro.font(16, weight: FontWeight.w600),
                        ),
                        const SizedBox(width: 12),
                        const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
                      ],
                    ),
                  ),
                ),
              ),
              if (_target?.seasonId != null)
                TextButton(
                  onPressed: _returnCurrent,
                  child: const Text('Return to current episode'),
                ),
            ],
          ),
          const SizedBox(height: 14),
        ],
        if (_error != null)
          EpisodeStatus(
            title: 'Episodes unavailable',
            detail: _error,
            onRetry: _seasonId == null
                ? _loadSeasons
                : (episodes?.isNotEmpty ?? false)
                ? _loadMore
                : () => _select(_seasonId!),
            onChooseSeason: (seasons?.length ?? 0) > 1 ? _chooseSeason : null,
          ),
        if (_error == null &&
            seasons != null &&
            _seasonId != null &&
            episodes == null)
          EpisodeStatus(
            title: 'Loading episodes…',
            detail:
                '${selected == null ? 'Selected season' : _title(selected)} · Your place is saved.',
            loading: true,
          )
        else if (episodes != null && episodes.isNotEmpty) ...[
          if (wide)
            SizedBox(
              height: 360,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: episodes.length,
                separatorBuilder: (_, _) => const SizedBox(width: 16),
                itemBuilder: (context, i) => SizedBox(
                  width: 300,
                  child: PhoneEpisodeCard(
                    key: episodes[i].id == widget.currentEpisodeId
                        ? _currentKey
                        : null,
                    item: episodes[i],
                    current: episodes[i].id == widget.currentEpisodeId,
                    onPressed: () => scope.open(episodes[i]),
                  ),
                ),
              ),
            )
          else
            for (final episode in episodes)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: PhoneEpisodeCard(
                        key: episode.id == widget.currentEpisodeId
                            ? _currentKey
                            : null,
                        item: episode,
                        current: episode.id == widget.currentEpisodeId,
                        row: true,
                        onPressed: () => scope.open(episode),
                      ),
                    ),
                    ...[
                      const SizedBox(width: 8),
                      PhoneDownloadButton(
                        item: episode,
                        refreshPermission: false,
                      ),
                    ],
                  ],
                ),
              ),
          if (_hasMore)
            Center(
              child: PillButton(
                label: _loadingMore ? 'Loading…' : 'More episodes',
                busy: _loadingMore,
                onPressed: _loadingMore ? null : _loadMore,
              ),
            ),
        ] else if (seasons != null && _error == null)
          EpisodeStatus(
            title: seasons.isEmpty
                ? 'No seasons available'
                : 'This season has no episodes',
            detail: seasons.isEmpty
                ? 'No seasons are available to your account yet. Try again later.'
                : 'Choose another season, or check again when episodes have been added.',
            onRetry: _seasonId == null
                ? _loadSeasons
                : () => _select(_seasonId!),
            onChooseSeason: seasons.length > 1 ? _chooseSeason : null,
          ),
      ],
    );
  }
}

/// Episode card (Apple `EpisodeBrowseCard`): a 16:9 still, "N. Name",
/// runtime with current or watched state, and the overview. On phones the
/// still sits beside the text.
class PhoneEpisodeCard extends StatelessWidget {
  const PhoneEpisodeCard({
    super.key,
    required this.item,
    required this.current,
    required this.onPressed,
    this.row = false,
  });

  final MediaItem item;
  final bool current;
  final bool row;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final catalog = PhoneScope.of(context).catalog;
    final number = item.indexNumber == null ? '' : '${item.indexNumber}. ';
    final showProgress = Preferences.maybeOf(context)?.showProgress ?? true;
    final still = ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Artwork(
              url: catalog.artwork(item, landscape: true, width: 640),
              headers: catalog.imageHeaders,
              title: item.name,
              seed: item.id,
              showTitle: catalog.isPreview,
            ),
            if (showProgress && item.progress > 0)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 4,
                child: ColoredBox(
                  color: const Color(0x2EFFFFFF),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: item.progress,
                      child: ColoredBox(color: Zoro.jade),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$number${item.name}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Zoro.font(15, weight: FontWeight.w600),
        ),
        const SizedBox(height: 3),
        Wrap(
          spacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (item.durationLabel.isNotEmpty)
              Text(item.durationLabel, style: Zoro.font(13, color: Zoro.muted)),
            if (current)
              Text('Current episode', style: Zoro.font(13, color: Zoro.jade))
            else if (item.userData?.played == true)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.check_rounded, size: 14, color: Zoro.muted),
                  const SizedBox(width: 3),
                  Text('Watched', style: Zoro.font(13, color: Zoro.muted)),
                ],
              ),
          ],
        ),
        if (item.plainOverview case final overview? when overview.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              overview,
              maxLines: row ? 2 : 3,
              overflow: TextOverflow.ellipsis,
              style: Zoro.font(13, color: Zoro.muted),
            ),
          ),
      ],
    );
    final details = Semantics(
      button: true,
      onTap: onPressed,
      label:
          'Episode ${item.indexNumber ?? ''}, ${item.name}${current ? ', current episode' : ''}',
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onPressed,
        child: row
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: MediaQuery.sizeOf(context).width < 380 ? 96 : 128,
                    child: still,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: text),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [still, const SizedBox(height: 8), text],
              ),
      ),
    );
    final play = IconButton(
      tooltip: 'Play ${item.name}',
      icon: const Icon(Icons.play_arrow_rounded),
      onPressed: () =>
          PhoneScope.of(context).play(item, startTicks: item.resumeTicks),
    );
    return row
        ? Row(
            children: [
              Expanded(child: details),
              play,
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [details, play],
          );
  }
}

class _CastShelf extends StatelessWidget {
  const _CastShelf({required this.people});

  final List<Person> people;

  @override
  Widget build(BuildContext context) {
    final catalog = PhoneScope.of(context).catalog;
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('Cast & Crew'),
        const SizedBox(height: 12),
        SizedBox(
          height: 138 * 1.5 + 8 + 44 * scale,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Phone.gutter),
            itemCount: people.length,
            separatorBuilder: (_, _) => const SizedBox(width: 16),
            itemBuilder: (context, i) {
              final person = people[i];
              return Semantics(
                label: '${person.name}, ${person.role ?? person.type ?? ''}',
                excludeSemantics: true,
                child: SizedBox(
                  width: 138,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: AspectRatio(
                          aspectRatio: 2 / 3,
                          child: Artwork(
                            url: catalog.artwork(
                              person.asItem,
                              landscape: false,
                              width: 360,
                            ),
                            headers: catalog.imageHeaders,
                            title: person.name,
                            seed: person.id,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        person.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Zoro.font(14, weight: FontWeight.w600),
                      ),
                      Text(
                        person.role ?? person.type ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Zoro.font(12, color: Zoro.muted),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
