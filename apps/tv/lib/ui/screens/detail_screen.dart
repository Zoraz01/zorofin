import 'package:flutter/material.dart';
import '../widgets/episode_status.dart';

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
    this.revision = 0,
  });

  final Catalog catalog;
  final MediaItem item;
  final ValueChanged<MediaItem> onOpen;
  final PlayItem onPlay;
  final int revision;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  late MediaItem _item = widget.item;
  MediaItem? _next;
  List<MediaItem> _similar = const [];
  String? _failure;
  bool _played = false;
  int _detailRequest = 0;

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
  void didUpdateWidget(covariant DetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) _load();
  }

  @override
  void dispose() {
    _playFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_detailRequest;
    try {
      final full = await _catalog.item(widget.item.id);
      final next = full.isSeries || full.type == 'Season'
          ? await _catalog.nextEpisode(full)
          : null;
      if (!mounted || request != _detailRequest) return;
      setState(() {
        _item = full;
        _next = next;
        _played = full.userData?.played ?? false;
        _failure = null;
      });
    } on ClientError catch (e) {
      if (mounted && request == _detailRequest) {
        setState(() => _failure = e.message);
      }
    }
    if (!mounted || request != _detailRequest) return;
    final similar = await _catalog.similar(widget.item);
    if (mounted && request == _detailRequest) {
      setState(() => _similar = similar);
    }
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
                  revision: widget.revision,
                  context: item,
                  currentEpisodeId: item.isEpisode ? item.id : _next?.id,
                  preferredEpisode: _next,
                  onPlay: widget.onPlay,
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
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
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
          FavoriteButton(item: item, catalog: _catalog, labeled: true),
          ZoroButton(
            icon: _played
                ? Icons.check_circle_rounded
                : Icons.check_circle_outline_rounded,
            label: _played ? 'Mark unwatched' : 'Mark watched',
            onPressed: _togglePlayed,
          ),
          if (resume && playable != null) ...[
            ZoroButton(
              icon: Icons.replay_rounded,
              label: 'Start over',
              onPressed: () => _play(playable, 0),
            ),
          ],
          if (_streams.isNotEmpty) ...[
            ZoroButton(
              icon: Icons.graphic_eq_rounded,
              label: 'Audio, ${_trackValue('Audio', _audioIndex ?? -999)}',
              onPressed: _chooseAudio,
            ),
            ZoroButton(
              icon: Icons.closed_caption_outlined,
              label: 'Subtitles, ${_trackValue('Subtitle', _subtitleIndex)}',
              onPressed: _chooseSubtitles,
            ),
          ],
          // Continue Watching opens episodes here, so the show is one step
          // away (Apple `detail-view-series`).
          if (item.isEpisode && item.seriesId != null) ...[
            ZoroButton(
              icon: Icons.tv_rounded,
              label: 'View series',
              onPressed: () => widget.onOpen(
                MediaItem(
                  id: item.seriesId!,
                  name: item.seriesName ?? 'Series',
                  type: 'Series',
                ),
              ),
            ),
          ],
          if (seriesId != null) ...[
            ZoroButton(
              icon: Icons.format_list_bulleted_rounded,
              label: 'Seasons and episodes',
              onPressed: _showEpisodes,
            ),
          ],
          if (_qualityItem.fileQualities.any((q) => q.facts.isNotEmpty)) ...[
            ZoroButton(
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
            Icon(Icons.circle, size: 10, color: Zoro.jade),
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
    this.preferredEpisode,
    this.onPlay,
    this.inPlayer = false,
    this.seasonMenuController,
    this.revision = 0,
  });

  final Catalog catalog;
  final MediaItem context;
  final ValueChanged<MediaItem> onOpen;
  final String? currentEpisodeId;
  final MediaItem? preferredEpisode;
  final PlayItem? onPlay;

  /// In the player's episode panel: no heading (the panel has one), and the
  /// current episode reads "Currently playing".
  final bool inPlayer;

  /// Lets the player consume platform Back before dismissing its parent panel.
  final MenuController? seasonMenuController;
  final int revision;

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
  int _episodeRequest = 0, _scopeRevision = 0, _selectionRevision = 0;
  int _interaction = 0;
  MediaItem? get _target =>
      widget.context.isEpisode ? widget.context : widget.preferredEpisode;
  String? _error;
  late final _seasonMenu = widget.seasonMenuController ?? MenuController();
  final _row = ScrollController();
  static const _episodeGap = 16.0, _rowPadding = 4.0;
  final _seasonFocus = FocusNode(debugLabel: 'player-current-season');

  String get _seriesId => widget.context.episodeSeriesId!;

  @override
  void initState() {
    super.initState();
    _loadSeasons();
  }

  @override
  void didUpdateWidget(covariant SeasonEpisodeBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.catalog, widget.catalog) ||
        oldWidget.context.episodeSeriesId != _seriesId) {
      _scopeRevision++;
      _selectionRevision++;
      _episodeRequest++;
      _seasons = null;
      _episodes = null;
      _seasonId = null;
      _interaction = 0;
      _loadSeasons();
    } else if (oldWidget.preferredEpisode == null &&
        widget.preferredEpisode != null &&
        _interaction == 0) {
      _loadSeasons();
    } else if (oldWidget.revision != widget.revision) {
      _refreshEpisodes();
    }
  }

  // Refresh the loaded range without resetting season, scroll or card focus.
  Future<void> _refreshEpisodes() async {
    final seasonId = _seasonId;
    if (seasonId == null) return;
    final request = ++_episodeRequest;
    final count = _episodes?.length ?? episodePageSize;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.catalog.episodePage(
        _seriesId,
        seasonId,
        limit: count > 0 ? count : episodePageSize,
      );
      if (!mounted || request != _episodeRequest || seasonId != _seasonId) {
        return;
      }
      setState(() {
        _episodes = page.items;
        _total = page.totalRecordCount;
        _hasMore =
            page.items.isNotEmpty &&
            (_total == null
                ? page.items.length >= count
                : page.items.length < _total!);
        _loadingMore = false;
        _error = null;
      });
    } on ClientError catch (e) {
      if (mounted && request == _episodeRequest) {
        setState(() {
          _loadingMore = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  void dispose() {
    _seasonFocus.dispose();
    _row.dispose();
    super.dispose();
  }

  /// Center the current card without using a lazy list's estimated end offset.
  void _showCurrent(int intent, int selection) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_row.hasClients ||
          intent != _interaction ||
          selection != _selectionRevision) {
        return;
      }
      final episodes = _episodes;
      final index =
          episodes?.indexWhere((e) => e.id == widget.currentEpisodeId) ?? -1;
      if (episodes == null || index < 0) return;
      final position = _row.position;
      if (!position.hasViewportDimension) return;
      final cardWidth = _EpisodeCard.widthFor(widget.inPlayer);
      final count = episodes.length + (_hasMore ? 1 : 0);
      final contentWidth =
          2 * _rowPadding +
          episodes.length * cardWidth +
          (_hasMore ? _MoreEpisodes.width : 0) +
          (count - 1) * _episodeGap;
      final end = (contentWidth - position.viewportDimension).clamp(
        0.0,
        double.infinity,
      );
      final centered =
          _rowPadding +
          index * (cardWidth + _episodeGap) -
          (position.viewportDimension - cardWidth) / 2;
      _row.jumpTo(centered.clamp(0.0, end).toDouble());
    });
  }

  Future<void> _loadSeasons() async {
    final scope = ++_scopeRevision, intent = _interaction;
    ++_episodeRequest;
    final catalog = widget.catalog, c = widget.context;
    setState(() => _error = null);
    try {
      final seasons = await catalog.seasons(_seriesId);
      if (!mounted || scope != _scopeRevision) {
        return;
      }
      // Series pages carry the resolved resume/up-next episode and its season.
      final preferred = c.type == 'Season'
          ? c.id
          : _target?.seasonId ?? c.seasonId;
      final initial =
          seasons.where((s) => s.id == preferred).firstOrNull ??
          seasons.where((s) => (s.indexNumber ?? 0) > 0).firstOrNull ??
          seasons.firstOrNull;
      if (!mounted) return;
      setState(() => _seasons = seasons);
      if (initial != null) {
        await _select(initial.id, target: intent == _interaction);
        if (_target == null && c.isSeries) {
          for (final next in seasons.skip(seasons.indexOf(initial) + 1)) {
            if (!mounted ||
                scope != _scopeRevision ||
                _interaction != 0 ||
                _error != null ||
                (_episodes?.isNotEmpty ?? false)) {
              break;
            }
            await _select(next.id);
          }
          if (mounted &&
              scope == _scopeRevision &&
              _interaction == 0 &&
              _error == null &&
              (_episodes?.isEmpty ?? false)) {
            await _select(initial.id);
          }
        }
      }
    } on ClientError catch (e) {
      if (mounted && scope == _scopeRevision) {
        setState(() => _error = e.message);
      }
    }
  }

  Future<void> _select(String seasonId, {bool target = true}) async {
    final selection = ++_selectionRevision, intent = _interaction;
    ++_episodeRequest;
    _seasonMenu.close();
    setState(() {
      _seasonId = seasonId;
      _loadingMore = false;
      _episodes = null;
      _total = null;
      _hasMore = false;
      _error = null;
    });
    if (widget.inPlayer && target) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            selection == _selectionRevision &&
            intent == _interaction) {
          _seasonFocus.requestFocus();
        }
      });
    }
    await _loadMore();
    // Stop targeting as soon as the viewer interacts or changes the selection.
    final current = widget.currentEpisodeId;
    for (var i = 0; target && i < 100 && current != null; i++) {
      if (!mounted ||
          selection != _selectionRevision ||
          intent != _interaction ||
          _seasonId != seasonId ||
          !_hasMore ||
          _error != null ||
          (_target?.seasonId != null && _target!.seasonId != seasonId)) {
        break;
      }
      if (_episodes?.any((e) => e.id == current) ?? false) break;
      await _loadMore();
    }
    if (target &&
        mounted &&
        selection == _selectionRevision &&
        _seasonId == seasonId) {
      _showCurrent(intent, selection);
    }
  }

  /// The next page of episodes (Apple `EpisodeBrowser.loadMore`).
  Future<void> _loadMore() async {
    final seasonId = _seasonId;
    if (seasonId == null || _loadingMore) return;
    final request = ++_episodeRequest;
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
      if (!mounted || _seasonId != seasonId || request != _episodeRequest) {
        return;
      }
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
      if (mounted && _seasonId == seasonId && request == _episodeRequest) {
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
    final seasons = _seasons;
    final selected = seasons?.where((s) => s.id == _seasonId).firstOrNull;
    return FocusTraversalGroup(
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, event) {
          _interaction++;
          return KeyEventResult.ignored;
        },
        child: Listener(
          onPointerDown: (_) => _interaction++,
          onPointerSignal: (_) => _interaction++,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!widget.inPlayer)
                Text(
                  'Seasons & episodes',
                  style: Zoro.font(28, weight: FontWeight.w700),
                ),
              if (!widget.inPlayer) const SizedBox(height: 16),
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
                    MenuAnchor(
                      controller: _seasonMenu,
                      childFocusNode: _seasonFocus,
                      alignmentOffset: const Offset(0, 10),
                      consumeOutsideTap: true,
                      style: MenuStyle(
                        backgroundColor: const WidgetStatePropertyAll(
                          Zoro.panel,
                        ),
                        maximumSize: const WidgetStatePropertyAll(
                          Size(380, 360),
                        ),
                        padding: const WidgetStatePropertyAll(
                          EdgeInsets.all(10),
                        ),
                        shape: WidgetStatePropertyAll(
                          RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                      menuChildren: [
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
                      builder: (context, controller, child) => _Pill(
                        focusNode: _seasonFocus,
                        autofocus: widget.inPlayer,
                        label: selected == null
                            ? 'Choose season'
                            : _title(selected),
                        trailing: Icons.keyboard_arrow_down_rounded,
                        onPressed: () => controller.isOpen
                            ? controller.close()
                            : controller.open(),
                      ),
                    ),
                    if (_target?.seasonId != null)
                      ZoroButton(
                        label: 'Return to current episode',
                        onPressed: () => _select(_target!.seasonId!),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
              if (_error != null)
                EpisodeStatus(
                  title: 'Episodes unavailable',
                  detail: _error,
                  onRetry: _seasonId == null
                      ? _loadSeasons
                      : (_episodes?.isNotEmpty ?? false)
                      ? _loadMore
                      : () => _select(_seasonId!),
                  onChooseSeason: (seasons?.length ?? 0) > 1
                      ? () => _seasonMenu.open()
                      : null,
                ),
              if (_error == null &&
                  seasons != null &&
                  _seasonId != null &&
                  _episodes == null)
                EpisodeStatus(
                  title: 'Loading episodes…',
                  detail: selected == null
                      ? 'Your place is saved.'
                      : '${_title(selected)} · Your place is saved.',
                  loading: true,
                )
              else if (_episodes case final episodes? when episodes.isNotEmpty)
                SizedBox(
                  height: widget.inPlayer
                      ? 290
                      : (widget.onPlay == null ? 420 : 490),
                  child: ListView.builder(
                    controller: _row,
                    scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.none,
                    padding: const EdgeInsets.all(_rowPadding),
                    itemCount: episodes.length + (_hasMore ? 1 : 0),
                    // Known extents let the lazy viewport jump beyond its first
                    // rendered page without estimating from mixed separators.
                    itemExtentBuilder: (i, _) {
                      final count = episodes.length + (_hasMore ? 1 : 0);
                      if (i >= count) return null;
                      final width = i == episodes.length
                          ? _MoreEpisodes.width
                          : _EpisodeCard.widthFor(widget.inPlayer);
                      return width + (i < count - 1 ? _episodeGap : 0);
                    },
                    itemBuilder: (context, i) => Padding(
                      padding: EdgeInsetsDirectional.only(
                        end: i < episodes.length + (_hasMore ? 1 : 0) - 1
                            ? _episodeGap
                            : 0,
                      ),
                      child: i == episodes.length
                          ? _MoreEpisodes(
                              loading: _loadingMore,
                              onPressed: _loadMore,
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _EpisodeCard(
                                  item: episodes[i],
                                  catalog: widget.catalog,
                                  current:
                                      episodes[i].id == widget.currentEpisodeId,
                                  inPlayer: widget.inPlayer,
                                  onPressed: () => widget.onOpen(episodes[i]),
                                ),
                                if (!widget.inPlayer && widget.onPlay != null)
                                  ZoroButton(
                                    label: 'Play',
                                    icon: Icons.play_arrow_rounded,
                                    onPressed: () => widget.onPlay!(
                                      episodes[i],
                                      startTicks: episodes[i].resumeTicks,
                                    ),
                                  ),
                              ],
                            ),
                    ),
                  ),
                )
              else if (seasons != null && _error == null)
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
                  onChooseSeason: seasons.length > 1
                      ? () => _seasonMenu.open()
                      : null,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The More episodes card at the end of a paged season row.
class _MoreEpisodes extends StatelessWidget {
  static const width = 160.0;
  const _MoreEpisodes({required this.loading, required this.onPressed});

  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Focusable(
    onPressed: loading ? () {} : onPressed,
    semanticLabel: 'More episodes',
    builder: (context, focused) => AnimatedContainer(
      duration: Zoro.focusDuration,
      width: width,
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
    this.focusNode,
    this.autofocus = false,
  });
  final FocusNode? focusNode;
  final bool autofocus;

  final String label;
  final IconData trailing;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Focusable(
      onPressed: onPressed,
      semanticLabel: 'Choose season, $label',
      focusNode: focusNode,
      autofocus: autofocus,
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
  static double widthFor(bool inPlayer) => inPlayer ? 300 : 380;
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
        width: widthFor(inPlayer),
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
                                  child: ColoredBox(color: Zoro.jade),
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
                if (item.durationLabel.isNotEmpty) ...[
                  Text(
                    item.durationLabel,
                    style: Zoro.font(18, color: Zoro.muted),
                  ),
                  const SizedBox(width: 8),
                ],
                if (current)
                  Flexible(
                    child: Text(
                      inPlayer ? 'Currently playing' : 'Current episode',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Zoro.font(18, color: Zoro.jade),
                    ),
                  )
                else if (item.userData?.played == true) ...[
                  const Icon(Icons.check_rounded, size: 18, color: Zoro.muted),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      'Watched',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Zoro.font(18, color: Zoro.muted),
                    ),
                  ),
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
