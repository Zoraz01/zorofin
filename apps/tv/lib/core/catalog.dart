import 'errors.dart';
import 'home.dart';
import 'jellyfin_client.dart';
import 'models.dart';
import 'playback.dart';
import 'viewer_settings.dart';

class HomeRow {
  HomeRow(this.title, this.items, {this.landscape = false});

  final String title;
  final List<MediaItem> items;

  /// Continue Watching uses 16:9 stills; library rows use posters.
  final bool landscape;
}

/// Library sections reachable from the TV navigation bar.
enum LibraryKind {
  movies('Movie', 'Movies'),
  shows('Series', 'TV Shows'),
  live('TvChannel', 'Live TV');

  const LibraryKind(this.itemType, this.title);

  final String itemType;
  final String title;
}

/// What the screens read from. The live implementation talks to Jellyfin; the
/// preview implementation uses fictional data so store reviewers can explore
/// the app without a server.
/// Episodes per page in the season browser, as on Apple.
const episodePageSize = 30;

abstract class Catalog {
  String get viewerName;
  String get serverName;
  bool get isPreview;
  Map<String, String> get imageHeaders;

  /// Home shelves in the Apple TV order: Continue Watching, then recently
  /// added movies and shows. The hero is the first recently added movie.
  Future<List<HomeRow>> home();
  Future<ItemPage> browse(
    LibraryKind kind, {
    int start = 0,
    bool favorites = false,
  });
  Future<List<MediaItem>> search(String query);
  Future<List<MediaItem>> recommendations();
  Future<MediaItem> item(String id);
  Future<List<MediaItem>> seasons(String seriesId);
  Future<List<MediaItem>> episodes(String seriesId, String seasonId);

  /// A page of [episodes] for the season browser's More episodes card.
  Future<ItemPage> episodePage(
    String seriesId,
    String seasonId, {
    int start = 0,
    int limit = episodePageSize,
  });
  Future<List<MediaItem>> similar(MediaItem item);

  /// The episode Play starts from a series or season page.
  Future<MediaItem?> nextEpisode(MediaItem seriesOrSeason);

  /// The episode after [episode], crossing into the next season; null at the
  /// end of the series.
  Future<MediaItem?> episodeAfter(MediaItem episode) async {
    final seriesId = episode.seriesId;
    final seasonId = episode.seasonId;
    if (seriesId == null || seasonId == null) return null;
    final inSeason = await episodes(seriesId, seasonId);
    final index = inSeason.indexWhere((e) => e.id == episode.id);
    if (index >= 0 && index + 1 < inSeason.length) return inSeason[index + 1];
    final allSeasons = await seasons(seriesId);
    final seasonIndex = allSeasons.indexWhere((s) => s.id == seasonId);
    for (final season in allSeasons.skip(seasonIndex + 1)) {
      final next = await episodes(seriesId, season.id);
      if (next.isNotEmpty) return next.first;
    }
    return null;
  }

  Future<bool> setFavorite(MediaItem item, bool value);
  Future<bool> setPlayed(MediaItem item, bool value);
  Uri? artwork(MediaItem item, {required bool landscape, required int width});
  Uri? backdrop(MediaItem item, {required int width});

  /// Null when this catalog has no playable media (preview mode).
  JellyfinClient? get client;

  /// Account settings from `Users/Me`; the preview keeps an in-memory copy.
  Future<ViewerSettings> viewerSettings();
  Future<ViewerSettings> saveViewerConfiguration(
    Map<String, Object> changes,
    ViewerSettings baseline,
  );
  Future<List<SettingsLanguage>> settingsLanguages();

  /// The signed-in viewer's photo, when they have one.
  Uri? viewerPhoto({int width = 256}) => null;
}

class JellyfinCatalog extends Catalog {
  JellyfinCatalog(this.client, {this.serverName = ''});

  @override
  final JellyfinClient client;
  @override
  final String serverName;

  @override
  bool get isPreview => false;
  @override
  String get viewerName => client.session?.viewer.name ?? '';
  @override
  Map<String, String> get imageHeaders => client.authHeaders;

  @override
  Future<List<HomeRow>> home() async {
    // Rows load together; one failing row must not hide the rest. An expired
    // session still surfaces so the app can return to sign-in.
    Future<List<MediaItem>> safe(Future<ItemPage> page) =>
        page.then((p) => p.items).catchError((Object e) {
          if (e is ClientError && e.kind == ClientErrorKind.unauthorized) {
            throw e;
          }
          return <MediaItem>[];
        });
    final results = await Future.wait([
      safe(client.resume()),
      safe(client.items(type: 'Movie')),
      safe(client.items(type: 'Series')),
    ]);
    final rows = [
      HomeRow('Continue Watching', results[0], landscape: true),
      HomeRow('Recently Added Movies', results[1]),
      HomeRow('Recently Added Shows', results[2]),
    ];
    return rows.where((r) => r.items.isNotEmpty).toList();
  }

  @override
  Future<ItemPage> browse(
    LibraryKind kind, {
    int start = 0,
    bool favorites = false,
  }) => kind == LibraryKind.live
      ? client.channels(start: start)
      : client.items(type: kind.itemType, start: start, favorites: favorites);

  @override
  Future<List<MediaItem>> search(String query) =>
      client.items(search: query.trim(), limit: 30).then((p) => p.items);

  /// Empty-search suggestions picked from the recently added movies and
  /// shows, as on Apple.
  @override
  Future<List<MediaItem>> recommendations() async {
    final pages = await Future.wait([
      client.items(type: 'Movie'),
      client.items(type: 'Series'),
    ]);
    return searchRecommendations([for (final p in pages) ...p.items]);
  }

  @override
  Future<MediaItem> item(String id) => client.item(id);

  @override
  Future<List<MediaItem>> seasons(String seriesId) =>
      client.seasons(seriesId).then((p) => p.items);

  @override
  Future<List<MediaItem>> episodes(String seriesId, String seasonId) =>
      client.episodes(seriesId, seasonId).then((p) => p.items);

  @override
  Future<ItemPage> episodePage(
    String seriesId,
    String seasonId, {
    int start = 0,
    int limit = episodePageSize,
  }) => client.episodes(seriesId, seasonId, start: start, limit: limit);

  @override
  Future<List<MediaItem>> similar(MediaItem item) => client
      .similar(item.id)
      .then((p) => p.items)
      .catchError((_) => <MediaItem>[]);

  @override
  Future<MediaItem?> nextEpisode(MediaItem seriesOrSeason) async {
    MediaItem? next;
    if (seriesOrSeason.isSeries) {
      next = (await client.nextUp(
        seriesId: seriesOrSeason.id,
      )).items.firstOrNull;
      if (next == null) {
        final seasons = (await client.seasons(seriesOrSeason.id)).items;
        final season =
            seasons.where((s) => (s.indexNumber ?? 0) > 0).firstOrNull ??
            seasons.firstOrNull;
        if (season != null) {
          next = (await client.episodes(
            seriesOrSeason.id,
            season.id,
          )).items.firstOrNull;
        }
      }
    } else if (seriesOrSeason.type == 'Season' &&
        seriesOrSeason.seriesId != null) {
      next = (await client.episodes(
        seriesOrSeason.seriesId!,
        seriesOrSeason.id,
      )).items.firstOrNull;
    }
    // One detail read for the chosen episode so playback has its sources.
    return next == null
        ? null
        : await client.item(next.id).catchError((_) => next!);
  }

  @override
  Future<bool> setFavorite(MediaItem item, bool value) =>
      client.favorite(item.id, value).then((d) => d.isFavorite ?? value);

  @override
  Future<bool> setPlayed(MediaItem item, bool value) =>
      client.played(item.id, value).then((d) => d.played ?? value);

  /// Episodes use their own still first; landscape cards fall back to
  /// backdrops, then the poster. Matches the Apple `MediaArtwork` order.
  @override
  Uri? artwork(MediaItem item, {required bool landscape, required int width}) {
    if (item.isEpisode) {
      for (final kind in ['Primary', 'Thumb']) {
        final tag = item.imageTags[kind];
        if (tag != null && tag.isNotEmpty) {
          return client.image(item.id, kind: kind, tag: tag, width: width);
        }
      }
    }
    if (landscape) {
      final b = backdrop(item, width: width);
      if (b != null) return b;
    }
    final tag = item.imageTags['Primary'];
    if (tag != null) return client.image(item.id, tag: tag, width: width);
    return null;
  }

  @override
  Uri? backdrop(MediaItem item, {required int width}) {
    if (item.backdropImageTags.isNotEmpty) {
      return client.image(
        item.id,
        kind: 'Backdrop',
        tag: item.backdropImageTags.first,
        width: width,
      );
    }
    final parent = item.parentBackdropItemId;
    if (parent != null && item.parentBackdropImageTags.isNotEmpty) {
      return client.image(
        parent,
        kind: 'Backdrop',
        tag: item.parentBackdropImageTags.first,
        width: width,
      );
    }
    return null;
  }

  @override
  Future<ViewerSettings> viewerSettings() => client.viewerSettings();

  @override
  Future<ViewerSettings> saveViewerConfiguration(
    Map<String, Object> changes,
    ViewerSettings baseline,
  ) => client.saveViewerConfiguration(changes, baseline);

  List<SettingsLanguage>? _languages;

  @override
  Future<List<SettingsLanguage>> settingsLanguages() async =>
      _languages ??= await client.settingsLanguages();

  @override
  Uri? viewerPhoto({int width = 256}) {
    final viewer = client.session?.viewer;
    final tag = viewer?.primaryImageTag;
    if (viewer == null || tag == null) return null;
    return client.userImage(viewer.id, tag: tag, width: width);
  }

  Future<PlaybackPlan> prepare(MediaItem item, PlaybackOptions options) async {
    final info = await client.playbackInfo(item, options);
    return PlaybackPlan.make(
      info,
      itemId: item.id,
      client: client,
      options: options,
    );
  }
}
