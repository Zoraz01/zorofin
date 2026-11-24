import 'package:flutter/material.dart';

import '../../core/catalog.dart';
import '../../core/errors.dart';
import '../../core/media_quality.dart';
import '../../core/models.dart';
import '../../core/playback.dart';
import '../../core/preferences.dart';
import '../theme.dart';
import '../widgets/choice_dialog.dart';
import '../widgets/favorite_button.dart';
import '../widgets/focusable.dart';
import '../widgets/live_tv_notice.dart';
import '../widgets/media_card.dart';
import '../widgets/section_title.dart';
import 'settings_screen.dart' show SettingsScaffold, SettingsFootnote;

/// Title details (Apple `DetailView` TV layout): artwork beside the heading,
/// green Play and circle actions, synopsis, genres, the season and episode
/// browser, cast and More Like This.
class DetailScreen extends StatefulWidget {
  const DetailScreen({
    super.key,
    required this.catalog,
    required this.item,
    required this.onOpen,
    required this.onPlay,
  });

  final Catalog catalog;
  final MediaItem item;
  final ValueChanged<MediaItem> onOpen;
  final PlayItem onPlay;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  late MediaItem _item = widget.item;
  MediaItem? _next;
  List<MediaItem> _similar = const [];
  String? _failure;
  bool _played = false;

  /// Detail-page track choices (Apple `DetailView` Audio and Subtitles);
  /// null audio and [PlaybackOptions.automatic] follow the account.
  int? _audioIndex;
  int _subtitleIndex = PlaybackOptions.automatic;
  final _browserKey = GlobalKey();
  final _playFocus = FocusNode(debugLabel: 'detail-play');

  Catalog get _catalog => widget.catalog;

  /// What Play starts: the next episode on series and season pages.
  MediaItem? get _playable =>
      _item.isSeries || _item.type == 'Season' ? _next : _item;

  /// Badges and tracks describe what Play starts.
  MediaItem get _qualityItem => _playable ?? _item;

  List<MediaStream> get _streams {
    final item = _qualityItem;
    final source = item.mediaSources.firstOrNull?.mediaStreams ?? const [];
    return source.isNotEmpty ? source : item.mediaStreams;
  }

  Future<void> _play(MediaItem playable, int startTicks) {
    final subtitle = _streams
        .where((s) => s.type == 'Subtitle' && s.index == _subtitleIndex)
        .firstOrNull;
    return widget.onPlay(
      playable,
      startTicks: startTicks,
      audioIndex: _audioIndex,
      subtitleIndex: _subtitleIndex,
      burnSubtitles: subtitle != null && !subtitle.isTextSubtitle,
    );
  }

  static String _streamTitle(MediaStream stream) =>
      stream.displayTitle ?? stream.language ?? 'Track ${stream.index}';

  /// The current choice, for the button's spoken label.
  String _trackValue(String type, int index) {
    final tracks = _streams.where((s) => s.type == type).toList();
    if (tracks.isEmpty) {
      return type == 'Audio' ? 'No audio tracks' : 'No subtitles available';
    }
    if (index == -1) return 'Off';
    final match = tracks.where((s) => s.index == index).firstOrNull;
    return match == null ? 'Automatic' : _streamTitle(match);
  }

  Future<void> _chooseAudio() async {
    final audio = _streams.where((s) => s.type == 'Audio').toList();
    final choice = await showChoices<int>(
      context,
      title: 'Audio',
      options: [
        (-999, 'Automatic'),
        for (final s in audio) (s.index, _streamTitle(s)),
      ],
      selected: _audioIndex ?? -999,
    );
    if (choice != null && mounted) {
      setState(() => _audioIndex = choice == -999 ? null : choice);
    }
  }

  Future<void> _chooseSubtitles() async {
    final subtitles = _streams.where((s) => s.type == 'Subtitle').toList();
    final choice = await showChoices<int>(
      context,
      title: 'Subtitles',
      options: [
        (PlaybackOptions.automatic, 'Automatic'),
        (-1, 'Off'),
        for (final s in subtitles) (s.index, _streamTitle(s)),
      ],
      selected: _subtitleIndex,
    );
    if (choice != null && mounted) setState(() => _subtitleIndex = choice);
  }

  void _showFileDetails() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            FileDetailsScreen(item: _qualityItem, audioIndex: _audioIndex),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _played = _item.userData?.played ?? false;
    // Autofocus is skipped while the opening card still holds focus, so
    // move focus to Play once the page is built, as Apple TV does.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _playFocus.requestFocus();
    });
    _load();
  }

  @override
  void dispose() {
    _playFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final full = await _catalog.item(widget.item.id);
      final next = full.isSeries || full.type == 'Season'
          ? await _catalog.nextEpisode(full)
          : null;
      if (!mounted) return;
      setState(() {
        _item = full;
        _next = next;
        _played = full.userData?.played ?? false;
        _failure = null;
      });
    } on ClientError catch (e) {
      if (mounted) setState(() => _failure = e.message);
    }
    final similar = await _catalog.similar(widget.item);
    if (mounted) setState(() => _similar = similar);
  }

  Future<void> _togglePlayed() async {
    final next = !_played;
    setState(() => _played = next);
    try {
      final result = await _catalog.setPlayed(_item, next);
      if (mounted) setState(() => _played = result);
    } on ClientError catch (e) {
      if (!mounted) return;
      setState(() => _played = !next);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  void _showEpisodes() {
    final target = _browserKey.currentContext;
    if (target != null) {
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 300),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    final landscape = item.isEpisode || item.isLive;
    final seriesId = item.episodeSeriesId;
    return ListView(
      cacheExtent: 3000,
      padding: const EdgeInsets.only(top: 20, bottom: 48),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Zoro.gutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: landscape ? 460 : 300,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: AspectRatio(
                        aspectRatio: landscape ? 16 / 9 : 2 / 3,
                        child: Artwork(
                          url: _catalog.artwork(
                            item,
                            landscape: landscape,
                            width: 900,
                          ),
                          headers: _catalog.imageHeaders,
                          title: item.displayTitle,
                          seed: item.id,
                          showTitle: _catalog.isPreview,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 48),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Heading(item: item),
                        ..._qualityBadges(item),
                        const SizedBox(height: 24),
                        _actions(item, seriesId),
                        const SizedBox(height: 24),
                        if (item.taglines.isNotEmpty) ...[
                          Text(
                            item.taglines.first,
                            style: Zoro.font(26, weight: FontWeight.w600),
                          ),
                          const SizedBox(height: 16),
                        ],
                        if (item.plainOverview case final overview?
                            when overview.isNotEmpty)
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1100),
                            child: Text(
                              overview,
                              style: Zoro.font(
                                24,
                                color: Zoro.muted,
                              ).copyWith(height: 1.4),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              if (item.isLive) ...[
                const SizedBox(height: 28),
                LiveTvNotice(
                  channelId: item.id,
                  onJoin: (channel) => widget.onPlay(channel),
                ),
              ],
              if (item.genres.isNotEmpty) ...[
                const SizedBox(height: 28),
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
                      Text('Genres', style: Zoro.font(22, color: Zoro.muted)),
                      const SizedBox(width: 20),
                      Expanded(
                        child: Text(
                          item.genres.join(', '),
                          style: Zoro.font(22, color: Zoro.jade),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (seriesId != null) ...[
                const SizedBox(height: 28),
                SeasonEpisodeBrowser(
                  key: _browserKey,
                  catalog: _catalog,
                  context: item,
                  currentEpisodeId: item.isEpisode ? item.id : _next?.id,
                  onOpen: widget.onOpen,
                ),
              ],
              if (_failure != null) ...[
                const SizedBox(height: 28),
                StatusMessage(
                  title: "Some details couldn't load",
                  detail: _failure!,
                  icon: Icons.wifi_off_rounded,
                  action: ZoroButton(label: 'Try again', onPressed: _load),
                ),
              ],
            ],
          ),
        ),
        if (item.people.isNotEmpty) ...[
          const SizedBox(height: 32),
          _CastShelf(people: item.people.take(24).toList(), catalog: _catalog),
        ],
        if (_similar.isNotEmpty) ...[
          const SizedBox(height: 32),
          MediaShelf(
            title: 'More Like This',
            items: _similar,
            catalog: _catalog,
            onOpen: widget.onOpen,
            landscape: true,
          ),
        ],
      ],
    );
  }

  /// Source-file badges (Apple `qualityBadges`); a series shows the next
  /// episode's file, labelled.
  List<Widget> _qualityBadges(MediaItem item) {
    final badges = _qualityItem.quality(audioIndex: _audioIndex).badges;
    if (badges.isEmpty) return const [];
    return [
      const SizedBox(height: 24),
      if (item.isSeries || item.type == 'Season') ...[
        Text(
          'Next episode · ${_qualityItem.episodeLabel}',
          style: Zoro.font(18, color: Zoro.muted),
        ),
        const SizedBox(height: 8),
      ],
      Semantics(
        label: 'Quality, ${badges.join(', ')}',
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
                  style: Zoro.font(18, weight: FontWeight.w600),
                ),
              ),
          ],
        ),
      ),
    ];
  }

  Widget _actions(MediaItem item, String? seriesId) {
    final playable = _playable;
    final resume = (playable?.resumeTicks ?? 0) > 0;
    return FocusTraversalGroup(
      child: Row(
        children: [
          SizedBox(
            width: 260,
            child: ZoroButton(
              label: resume
                  ? 'Resume'
                  : (item.isSeries ? 'Play next episode' : 'Play'),
              icon: Icons.play_arrow_rounded,
              primary: true,
              expand: true,
              focusNode: _playFocus,
              onPressed: () {
                if (playable != null) {
                  _play(playable, playable.resumeTicks);
                }
              },
            ),
          ),
          const SizedBox(width: 24),
          FavoriteButton(item: item, catalog: _catalog),
          const SizedBox(width: 16),
          CircleIconButton(
            icon: _played
                ? Icons.check_circle_rounded
                : Icons.check_circle_outline_rounded,
            color: _played ? Zoro.jade : Zoro.text,
            label: _played ? 'Mark unwatched' : 'Mark watched',
            onPressed: _togglePlayed,
          ),
          if (resume && playable != null) ...[
            const SizedBox(width: 16),
            CircleIconButton(
              icon: Icons.replay_rounded,
              label: 'Start over',
              onPressed: () => _play(playable, 0),
            ),
          ],
          if (_streams.isNotEmpty) ...[
            const SizedBox(width: 16),
            CircleIconButton(
              icon: Icons.graphic_eq_rounded,
              color: Zoro.jade,
              label: 'Audio, ${_trackValue('Audio', _audioIndex ?? -999)}',
              onPressed: _chooseAudio,
            ),
            const SizedBox(width: 16),
            CircleIconButton(
              icon: Icons.closed_caption_outlined,
              color: Zoro.jade,
              label: 'Subtitles, ${_trackValue('Subtitle', _subtitleIndex)}',
              onPressed: _chooseSubtitles,
            ),
          ],
          if (seriesId != null) ...[
            const SizedBox(width: 16),
            CircleIconButton(
              icon: Icons.format_list_bulleted_rounded,
              label: 'Seasons and episodes',
              onPressed: _showEpisodes,
            ),
          ],
          if (_qualityItem.fileQualities.any((q) => q.facts.isNotEmpty)) ...[
            const SizedBox(width: 16),
            CircleIconButton(
              icon: Icons.info_outline_rounded,
              label: 'File details',
              onPressed: _showFileDetails,
            ),
          ],
        ],
      ),
    );
  }
}

/// File details (Apple `MediaFileInfoView`): each version's source facts,
/// with no paths, stream URLs or credentials.
class FileDetailsScreen extends StatelessWidget {
  const FileDetailsScreen({super.key, required this.item, this.audioIndex});

  final MediaItem item;
  final int? audioIndex;

  @override
  Widget build(BuildContext context) {
    final versions = [...item.fileQualities];
    if (versions.isNotEmpty) versions[0] = item.quality(audioIndex: audioIndex);
    return SettingsScaffold(
      title: 'File details',
      actions: [
        ZoroButton(
          label: 'Done',
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      children: [
        Text(item.displayTitle, style: Zoro.font(32, weight: FontWeight.w700)),
        if (item.isEpisode) ...[
          const SizedBox(height: 6),
          Text(item.episodeLabel, style: Zoro.font(22, color: Zoro.muted)),
        ],
        for (final (i, quality) in versions.indexed) ...[
          const SizedBox(height: 20),
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
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      'Version ${i + 1}',
                      style: Zoro.font(24, weight: FontWeight.w600),
                    ),
                  ),
                if (quality.facts.isEmpty)
                  Text(
                    'File information is unavailable.',
                    style: Zoro.font(22, color: Zoro.muted),
                  ),
                for (final (title, value) in quality.facts)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: Zoro.font(22, color: Zoro.muted)),
                        const SizedBox(width: 20),
                        Expanded(
                          child: Text(
                            value,
                            textAlign: TextAlign.right,
                            style: Zoro.font(22),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 20),
        const SettingsFootnote(
          'Source file information. Playback quality can change with your '
          'connection, device and streaming settings.',
        ),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final rating = item.communityRating;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.circle, size: 10, color: Zoro.jade),
            const SizedBox(width: 8),
            Text(
              item.type.toUpperCase(),
              style: Zoro.font(
                16,
                weight: FontWeight.w700,
                color: Zoro.jade,
              ).copyWith(letterSpacing: 1.2),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(item.displayTitle, style: Zoro.font(46, weight: FontWeight.w700)),
        if (item.isEpisode) ...[
          const SizedBox(height: 6),
          Text(item.episodeLabel, style: Zoro.font(26, color: Zoro.muted)),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            MetadataLine(item),
            if (rating != null)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.star_rounded,
                    color: Colors.yellow,
                    size: 24,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    rating.toStringAsFixed(1),
                    style: Zoro.font(22, color: Colors.yellow),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

/// Seasons & episodes (Apple `SeasonEpisodeBrowser`): a season pill that
/// expands into choices, then a row of episode cards that open details.
class SeasonEpisodeBrowser extends StatefulWidget {
  const SeasonEpisodeBrowser({
    super.key,
    required this.catalog,
    required this.context,
    required this.onOpen,
    this.currentEpisodeId,
    this.inPlayer = false,
  });

  final Catalog catalog;
  final MediaItem context;
  final ValueChanged<MediaItem> onOpen;
  final String? currentEpisodeId;

  /// In the player's episode panel: no heading (the panel has one), and the
  /// current episode reads "Currently playing".
  final bool inPlayer;

  @override
  State<SeasonEpisodeBrowser> createState() => _SeasonEpisodeBrowserState();
}

class _SeasonEpisodeBrowserState extends State<SeasonEpisodeBrowser> {
  List<MediaItem>? _seasons;
  String? _seasonId;
  List<MediaItem>? _episodes;
  int? _total;
  bool _hasMore = false;
  bool _loadingMore = false;
  String? _error;
  bool _expanded = false;
  final _row = ScrollController();

  String get _seriesId => widget.context.episodeSeriesId!;

  @override
  void initState() {
    super.initState();
    _loadSeasons();
  }

  @override
  void dispose() {
    _row.dispose();
    super.dispose();
  }

  /// Bring the current episode into view, as Apple's `centerCurrent` does.
  void _showCurrent() {
    final index =
        _episodes?.indexWhere((e) => e.id == widget.currentEpisodeId) ?? -1;
    if (index <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_row.hasClients) return;
      final position = _row.position;
      _row.jumpTo(
        (index * 396.0 - 396).clamp(0, position.maxScrollExtent).toDouble(),
      );
    });
  }

  Future<void> _loadSeasons() async {
    setState(() => _error = null);
    try {
      final seasons = await widget.catalog.seasons(_seriesId);
      final c = widget.context;
      // Open on the page's own season, otherwise the first numbered season.
      final preferred = c.type == 'Season' ? c.id : c.seasonId;
      final initial =
          seasons.where((s) => s.id == preferred).firstOrNull ??
          seasons.where((s) => (s.indexNumber ?? 0) > 0).firstOrNull ??
          seasons.firstOrNull;
      if (!mounted) return;
      setState(() => _seasons = seasons);
      if (initial != null) await _select(initial.id);
    } on ClientError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _select(String seasonId) async {
    setState(() {
      _seasonId = seasonId;
      _episodes = null;
      _total = null;
      _hasMore = false;
      _expanded = false;
      _error = null;
    });
    await _loadMore();
    // Page forward until the current episode is in the row (at most ten
    // pages), so the row opens on it as Apple does.
    final current = widget.currentEpisodeId;
    for (var i = 0; i < 10 && current != null; i++) {
      if (!mounted || _seasonId != seasonId || !_hasMore) break;
      if (_episodes?.any((e) => e.id == current) ?? false) break;
      await _loadMore();
    }
    if (mounted && _seasonId == seasonId) _showCurrent();
  }

  /// The next page of episodes (Apple `EpisodeBrowser.loadMore`).
  Future<void> _loadMore() async {
    final seasonId = _seasonId;
    if (seasonId == null || _loadingMore) return;
    final have = _episodes ?? const <MediaItem>[];
    setState(() {
      _loadingMore = true;
      _error = null;
    });
    try {
      final page = await widget.catalog.episodePage(
        _seriesId,
        seasonId,
        start: have.length,
      );
      if (!mounted || _seasonId != seasonId) return;
      final seen = {for (final e in have) e.id};
      final fresh = page.items.where((e) => seen.add(e.id)).toList();
      final count = have.length + fresh.length;
      setState(() {
        _episodes = [...have, ...fresh];
        _total = page.totalRecordCount;
        _hasMore =
            fresh.isNotEmpty &&
            (_total == null
                ? page.items.length >= episodePageSize
                : count < _total!);
        _loadingMore = false;
      });
    } on ClientError catch (e) {
      if (mounted && _seasonId == seasonId) {
        setState(() {
          _error = e.message;
          _loadingMore = false;
        });
      }
    }
  }

  String _title(MediaItem season) => season.name.isNotEmpty
      ? season.name
      : 'Season ${season.indexNumber ?? ''}';

  @override
  Widget build(BuildContext context) {
    final c = widget.context;
    final seasons = _seasons;
    final selected = seasons?.where((s) => s.id == _seasonId).firstOrNull;
    return FocusTraversalGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!widget.inPlayer)
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  'Seasons & episodes',
                  style: Zoro.font(28, weight: FontWeight.w700),
                ),
                const Spacer(),
                if (c.isEpisode && c.seriesId != null)
                  Focusable(
                    onPressed: () => widget.onOpen(
                      MediaItem(
                        id: c.seriesId!,
                        name: c.seriesName ?? 'Series',
                        type: 'Series',
                      ),
                    ),
                    builder: (context, focused) => Container(
                      constraints: const BoxConstraints(minHeight: Zoro.target),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      alignment: Alignment.center,
                      decoration: ShapeDecoration(
                        shape: StadiumBorder(
                          side: BorderSide(
                            color: focused ? Colors.white : Colors.transparent,
                            width: 3,
                          ),
                        ),
                      ),
                      child: Text(
                        'View series',
                        style: Zoro.font(
                          20,
                          weight: FontWeight.w600,
                          color: Zoro.jade,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          if (!widget.inPlayer) const SizedBox(height: 16),
          if (seasons == null && _error == null)
            Text('Loading seasons…', style: Zoro.font(20, color: Zoro.muted))
          else if (seasons != null && seasons.isNotEmpty) ...[
            _Pill(
              label: selected == null ? 'Choose season' : _title(selected),
              trailing: _expanded
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              onPressed: () => setState(() => _expanded = !_expanded),
            ),
            if (_expanded) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Zoro.panel,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Wrap(
                  spacing: 20,
                  runSpacing: 4,
                  children: [
                    for (final season in seasons)
                      SizedBox(
                        width: 340,
                        child: _SeasonOption(
                          title: _title(season),
                          selected: season.id == _seasonId,
                          autofocus: season.id == _seasonId,
                          onPressed: () => _select(season.id),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
          ],
          if (_error != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_error!, style: Zoro.font(20, color: Zoro.muted)),
                const SizedBox(height: 12),
                ZoroButton(
                  label: 'Try again',
                  onPressed: _seasonId == null
                      ? _loadSeasons
                      : (_episodes?.isNotEmpty ?? false)
                      ? _loadMore
                      : () => _select(_seasonId!),
                ),
              ],
            )
          else if (seasons != null && _seasonId != null && _episodes == null)
            Text('Loading episodes…', style: Zoro.font(20, color: Zoro.muted))
          else if (_episodes case final episodes? when episodes.isNotEmpty)
            SizedBox(
              height: widget.inPlayer ? 290 : 420,
              child: ListView.separated(
                controller: _row,
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                padding: const EdgeInsets.all(4),
                itemCount: episodes.length + (_hasMore ? 1 : 0),
                separatorBuilder: (_, _) => const SizedBox(width: 16),
                itemBuilder: (context, i) => i == episodes.length
                    ? _MoreEpisodes(loading: _loadingMore, onPressed: _loadMore)
                    : _EpisodeCard(
                        item: episodes[i],
                        catalog: widget.catalog,
                        current: episodes[i].id == widget.currentEpisodeId,
                        inPlayer: widget.inPlayer,
                        onPressed: () => widget.onOpen(episodes[i]),
                      ),
              ),
            )
          else if (seasons != null)
            Text(
              seasons.isEmpty
                  ? 'No seasons are available.'
                  : 'No episodes are available in this season.',
              style: Zoro.font(20, color: Zoro.muted),
            ),
        ],
      ),
    );
  }
}

/// The More episodes card at the end of a paged season row.
class _MoreEpisodes extends StatelessWidget {
  const _MoreEpisodes({required this.loading, required this.onPressed});

  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Focusable(
    onPressed: loading ? () {} : onPressed,
    semanticLabel: 'More episodes',
    builder: (context, focused) => AnimatedContainer(
      duration: Zoro.focusDuration,
      width: 160,
      height: 214,
      decoration: BoxDecoration(
        color: focused ? Zoro.text : Zoro.panel,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chevron_right_rounded,
            size: 40,
            color: focused ? Zoro.background : Zoro.text,
          ),
          const SizedBox(height: 12),
          Text(
            loading ? 'Loading…' : 'More episodes',
            style: Zoro.font(
              20,
              weight: FontWeight.w600,
              color: focused ? Zoro.background : Zoro.text,
            ),
          ),
        ],
      ),
    ),
  );
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.trailing,
    required this.onPressed,
  });

  final String label;
  final IconData trailing;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Focusable(
      onPressed: onPressed,
      semanticLabel: 'Choose season, $label',
      builder: (context, focused) => AnimatedContainer(
        duration: Zoro.focusDuration,
        constraints: const BoxConstraints(minHeight: Zoro.target),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        decoration: ShapeDecoration(
          color: focused ? Zoro.text : Zoro.panel,
          shape: const StadiumBorder(),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: Zoro.font(
                24,
                weight: FontWeight.w600,
                color: focused ? Zoro.background : Zoro.text,
              ),
            ),
            const SizedBox(width: 16),
            Icon(
              trailing,
              size: 26,
              color: focused ? Zoro.background : Zoro.text,
            ),
          ],
        ),
      ),
    );
  }
}

class _SeasonOption extends StatelessWidget {
  const _SeasonOption({
    required this.title,
    required this.selected,
    required this.onPressed,
    this.autofocus = false,
  });

  final String title;
  final bool selected;
  final bool autofocus;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Focusable(
      onPressed: onPressed,
      autofocus: autofocus,
      builder: (context, focused) => AnimatedContainer(
        duration: Zoro.focusDuration,
        constraints: const BoxConstraints(minHeight: Zoro.target),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: focused ? Zoro.text : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: selected
                  ? Icon(
                      Icons.check_rounded,
                      color: focused ? Zoro.background : Zoro.jade,
                    )
                  : null,
            ),
            const SizedBox(width: 14),
            Text(
              title,
              style: Zoro.font(
                26,
                weight: selected ? FontWeight.w600 : FontWeight.w400,
                color: focused ? Zoro.background : Zoro.text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Episode card (Apple `EpisodeBrowseCard`): 16:9 still, "N. Name", runtime
/// with current or watched state, and three lines of overview.
class _EpisodeCard extends StatelessWidget {
  const _EpisodeCard({
    required this.item,
    required this.catalog,
    required this.current,
    this.inPlayer = false,
    required this.onPressed,
  });

  final MediaItem item;
  final Catalog catalog;
  final bool current;
  final bool inPlayer;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final number = item.indexNumber == null ? '' : '${item.indexNumber}. ';
    return Focusable(
      onPressed: onPressed,
      semanticLabel:
          'Episode ${item.indexNumber ?? ''}, ${item.name}${current ? ', current episode' : ''}',
      builder: (context, focused) => SizedBox(
        width: inPlayer ? 300 : 380,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedScale(
              scale: Zoro.lift(context, focused, 1.045),
              duration: Zoro.focusDuration,
              child: Container(
                foregroundDecoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: focused ? Colors.white : Colors.transparent,
                    width: 4,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Artwork(
                          url: catalog.artwork(
                            item,
                            landscape: true,
                            width: 640,
                          ),
                          headers: catalog.imageHeaders,
                          title: item.name,
                          seed: item.id,
                          showTitle: catalog.isPreview,
                        ),
                        if ((Preferences.maybeOf(context)?.showProgress ??
                                true) &&
                            item.progress > 0)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            height: 5,
                            child: ColoredBox(
                              color: const Color(0x2EFFFFFF),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: FractionallySizedBox(
                                  widthFactor: item.progress,
                                  child: const ColoredBox(color: Zoro.jade),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 9),
            Text(
              '$number${item.name}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Zoro.font(23, weight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Text(
                  item.durationLabel,
                  style: Zoro.font(18, color: Zoro.muted),
                ),
                const SizedBox(width: 8),
                if (current)
                  Text(
                    inPlayer ? 'Currently playing' : 'Current episode',
                    style: Zoro.font(18, color: Zoro.jade),
                  )
                else if (item.userData?.played == true) ...[
                  const Icon(Icons.check_rounded, size: 18, color: Zoro.muted),
                  const SizedBox(width: 4),
                  Text('Watched', style: Zoro.font(18, color: Zoro.muted)),
                ],
              ],
            ),
            if (item.plainOverview case final overview?
                when overview.isNotEmpty && !inPlayer) ...[
              const SizedBox(height: 4),
              Text(
                overview,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Zoro.font(19, color: Zoro.muted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Cast & Crew portraits (Apple detail people shelf).
class _CastShelf extends StatelessWidget {
  const _CastShelf({required this.people, required this.catalog});

  final List<Person> people;
  final Catalog catalog;

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: Zoro.gutter),
            child: SectionTitle('Cast & Crew'),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 400,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              padding: const EdgeInsets.symmetric(
                horizontal: Zoro.gutter,
                vertical: 8,
              ),
              itemCount: people.length,
              separatorBuilder: (_, _) => const SizedBox(width: 16),
              itemBuilder: (context, i) {
                final person = people[i];
                // Focusable so the remote can scroll the row; people pages
                // are not part of the TV app yet.
                return Focusable(
                  onPressed: () {},
                  semanticLabel:
                      '${person.name}, ${person.role ?? person.type ?? ''}',
                  builder: (context, focused) => SizedBox(
                    width: 180,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          foregroundDecoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: focused
                                  ? Colors.white
                                  : Colors.transparent,
                              width: 4,
                            ),
                          ),
                          child: ClipRRect(
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
                        ),
                        const SizedBox(height: 8),
                        Text(
                          person.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Zoro.font(20, weight: FontWeight.w600),
                        ),
                        Text(
                          person.role ?? person.type ?? '',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Zoro.font(17, color: Zoro.muted),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
