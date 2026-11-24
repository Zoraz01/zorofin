import 'catalog.dart';
import 'jellyfin_client.dart';
import 'models.dart';
import 'viewer_settings.dart';
import 'home.dart';

/// The same fictional library as the Apple app's preview
/// (`apps/apple/App/AppModel.swift`, `PreviewLibrary`). No network requests
/// are made and nothing is playable.
class PreviewCatalog extends Catalog {
  static const synopsis =
      'A journey through unfamiliar places, unexpected encounters, and the moments that stay with us. '
      'This fictional title is part of the app preview.';

  static String _id(int n) => n.toString().padLeft(32, '0');

  static final previewMovies = [
    for (final (i, name) in [
      'The Last Light',
      'Tideline',
      'Northbound',
      'After Hours',
      'Wild Blue',
      'The Quiet City',
    ].indexed)
      MediaItem(
        id: _id(i + 1),
        name: name,
        overview: synopsis,
        productionYear: 2026,
        runTimeTicks: (92 + i * 7) * 600000000,
        officialRating: 'PG-13',
        communityRating: 7.8 + i / 10,
        genres: const ['Drama', 'Adventure'],
        taglines: const ['Every ending is a new beginning.'],
        container: 'mkv',
        mediaStreams: _streams(i),
      ),
  ];

  /// Fictional file formats so quality badges and file details show.
  static List<MediaStream> _streams(int i) => [
    MediaStream(
      index: 0,
      type: 'Video',
      codec: i < 2 ? 'hevc' : 'h264',
      width: i < 2 ? 3840 : 1920,
      height: i < 2 ? 2160 : 1080,
      videoRangeType: i == 0 ? 'DOVIWithHDR10' : (i == 1 ? 'HDR10' : 'SDR'),
      bitDepth: i < 2 ? 10 : 8,
      frameRate: 23.976,
    ),
    MediaStream(
      index: 1,
      type: 'Audio',
      codec: i < 2 ? 'eac3' : 'aac',
      channels: i < 2 ? 6 : 2,
      language: 'eng',
      audioSpatialFormat: i == 0 ? 'DolbyAtmos' : null,
      isDefault: true,
    ),
    MediaStream(
      index: 2,
      type: 'Subtitle',
      language: 'eng',
      isTextSubtitle: true,
    ),
  ];

  static final previewShows = [
    for (final (i, name) in ['Orbital', 'Open Water', 'City Stories'].indexed)
      MediaItem(
        id: _id(i + 20),
        name: name,
        type: 'Series',
        overview: synopsis,
        productionYear: 2026,
      ),
  ];

  static final _season = MediaItem(
    id: _id(30),
    name: 'Season 1',
    type: 'Season',
    seriesId: previewShows[0].id,
    indexNumber: 1,
  );

  static final previewEpisodes = [
    for (final (i, name) in [
      'Arrival',
      'The Signal',
      'A New Orbit',
      'Into the Dark',
      'Homeward',
      'First Light',
    ].indexed)
      MediaItem(
        id: _id(i + 41),
        name: name,
        type: 'Episode',
        overview: synopsis,
        seriesId: previewShows[0].id,
        seriesName: 'Orbital',
        seasonId: _season.id,
        parentIndexNumber: 1,
        indexNumber: i + 1,
        runTimeTicks: 27000000000,
        container: 'mkv',
        mediaStreams: _streams(2),
        communityRating: 8.1,
        userData: UserData(playbackPositionTicks: i == 0 ? 9000000000 : 0),
      ),
  ];

  final _favorites = <String>{};

  var _settings = ViewerSettings(
    name: 'Preview',
    configuration: {
      'AudioLanguagePreference': '',
      'PlayDefaultAudioTrack': true,
      'RememberAudioSelections': true,
      'EnableNextEpisodeAutoPlay': true,
      'SubtitleLanguagePreference': '',
      'SubtitleMode': 'Default',
      'RememberSubtitleSelections': true,
    },
  );

  @override
  Future<ViewerSettings> viewerSettings() async => _settings;

  @override
  Future<ViewerSettings> saveViewerConfiguration(
    Map<String, Object> changes,
    ViewerSettings baseline,
  ) async {
    ViewerSettings.validate(changes);
    _settings = ViewerSettings(
      name: _settings.name,
      configuration: {..._settings.configuration, ...changes},
    );
    return _settings;
  }

  @override
  Future<List<SettingsLanguage>> settingsLanguages() async => const [
    SettingsLanguage('ara', 'Arabic'),
    SettingsLanguage('eng', 'English'),
    SettingsLanguage('fra', 'French'),
    SettingsLanguage('spa', 'Spanish'),
    SettingsLanguage('urd', 'Urdu'),
  ];

  @override
  String get viewerName => 'Preview';
  @override
  String get serverName => 'Preview library';
  @override
  bool get isPreview => true;
  @override
  Map<String, String> get imageHeaders => const {};
  @override
  JellyfinClient? get client => null;

  @override
  Future<List<HomeRow>> home() async => [
    HomeRow(
      'Continue Watching',
      previewEpisodes.take(2).toList(),
      landscape: true,
    ),
    HomeRow('Recently Added Movies', previewMovies),
    HomeRow('Recently Added Shows', previewShows),
  ];

  @override
  Future<ItemPage> browse(
    LibraryKind kind, {
    int start = 0,
    bool favorites = false,
  }) async {
    final all = switch (kind) {
      LibraryKind.movies => previewMovies,
      LibraryKind.shows => previewShows,
      LibraryKind.live => <MediaItem>[],
    };
    final items = favorites
        ? all.where((i) => _favorites.contains(i.id)).toList()
        : all;
    return ItemPage(
      items: start == 0 ? items : [],
      totalRecordCount: items.length,
    );
  }

  @override
  Future<List<MediaItem>> search(String query) async {
    final q = query.trim().toLowerCase();
    return [
      ...previewMovies,
      ...previewShows,
    ].where((i) => i.name.toLowerCase().contains(q)).toList();
  }

  @override
  Future<List<MediaItem>> recommendations() async =>
      searchRecommendations([...previewMovies, ...previewShows]);

  @override
  Future<MediaItem> item(String id) async => [
    ...previewMovies,
    ...previewShows,
    ...previewEpisodes,
  ].firstWhere((i) => i.id == id);

  @override
  Future<List<MediaItem>> seasons(String seriesId) async =>
      seriesId == previewShows[0].id ? [_season] : [];

  @override
  Future<List<MediaItem>> episodes(String seriesId, String seasonId) async =>
      seriesId == previewShows[0].id ? previewEpisodes : [];

  @override
  Future<ItemPage> episodePage(
    String seriesId,
    String seasonId, {
    int start = 0,
    int limit = episodePageSize,
  }) async {
    final all = await episodes(seriesId, seasonId);
    return ItemPage(
      items: all.skip(start).take(limit).toList(),
      totalRecordCount: all.length,
    );
  }

  @override
  Future<List<MediaItem>> similar(MediaItem item) async =>
      previewMovies.where((m) => m.id != item.id).toList();

  @override
  Future<MediaItem?> nextEpisode(MediaItem seriesOrSeason) async =>
      seriesOrSeason.id == previewShows[0].id ||
          seriesOrSeason.seriesId == previewShows[0].id
      ? previewEpisodes.first
      : null;

  @override
  Future<bool> setFavorite(MediaItem item, bool value) async {
    value ? _favorites.add(item.id) : _favorites.remove(item.id);
    return value;
  }

  @override
  Future<bool> setPlayed(MediaItem item, bool value) async => value;

  @override
  Uri? artwork(MediaItem item, {required bool landscape, required int width}) =>
      null;

  @override
  Uri? backdrop(MediaItem item, {required int width}) => null;
}
