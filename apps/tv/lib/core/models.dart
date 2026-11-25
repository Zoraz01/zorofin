import 'server_address.dart';

/// Jellyfin DTOs use PascalCase keys. Only fields the TV client renders are
/// decoded; unknown fields are ignored.
T? _as<T>(Object? value) => value is T ? value : null;

List<T> _list<T>(Object? value, T Function(Map<String, dynamic>) decode) =>
    value is List
    ? value.whereType<Map<String, dynamic>>().map(decode).toList()
    : <T>[];

class PublicSystemInfo {
  PublicSystemInfo({this.serverName, this.version, this.id});

  factory PublicSystemInfo.fromJson(Map<String, dynamic> json) =>
      PublicSystemInfo(
        serverName: _as<String>(json['ServerName']),
        version: _as<String>(json['Version']),
        id: _as<String>(json['Id']),
      );

  final String? serverName;
  final String? version;
  final String? id;
}

class Viewer {
  Viewer({
    required this.id,
    required this.name,
    this.isAdministrator = false,
    this.primaryImageTag,
    this.syncPlayAccess,
    this.canAccessLiveTV = true,
  });

  factory Viewer.fromJson(Map<String, dynamic> json) {
    final policy = _as<Map<String, dynamic>>(json['Policy']);
    return Viewer(
      id: json['Id'] as String,
      name: json['Name'] as String? ?? '',
      isAdministrator: _as<bool>(policy?['IsAdministrator']) ?? false,
      primaryImageTag: _as<String>(json['PrimaryImageTag']),
      syncPlayAccess: _as<String>(policy?['SyncPlayAccess']),
      canAccessLiveTV: _as<bool>(policy?['EnableLiveTvAccess']) ?? true,
    );
  }

  final String id;
  final String name;
  final bool isAdministrator;

  /// Set when the viewer has a profile photo on the server.
  final String? primaryImageTag;

  /// `CreateAndJoinGroups`, `JoinGroups` or `None`.
  final String? syncPlayAccess;
  final bool canAccessLiveTV;

  Map<String, dynamic> toJson() => {
    'Id': id,
    'Name': name,
    'PrimaryImageTag': ?primaryImageTag,
    'Policy': {
      'IsAdministrator': isAdministrator,
      'SyncPlayAccess': ?syncPlayAccess,
      'EnableLiveTvAccess': canAccessLiveTV,
    },
  };
}

class Session {
  Session({
    required this.server,
    required this.viewer,
    required this.token,
    required this.deviceId,
  });

  factory Session.fromJson(Map<String, dynamic> json) => Session(
    server: ServerAddress.fromJson(json['server'] as Map<String, dynamic>),
    viewer: Viewer.fromJson(json['viewer'] as Map<String, dynamic>),
    token: json['token'] as String,
    deviceId: json['deviceId'] as String,
  );

  final ServerAddress server;
  final Viewer viewer;
  final String token;
  final String deviceId;

  Map<String, dynamic> toJson() => {
    'server': server.toJson(),
    'viewer': viewer.toJson(),
    'token': token,
    'deviceId': deviceId,
  };
}

class QuickConnectState {
  QuickConnectState({
    required this.authenticated,
    required this.secret,
    required this.code,
  });

  factory QuickConnectState.fromJson(Map<String, dynamic> json) =>
      QuickConnectState(
        authenticated: _as<bool>(json['Authenticated']) ?? false,
        secret: json['Secret'] as String,
        code: json['Code'] as String,
      );

  final bool authenticated;
  final String secret;
  final String code;
}

class UserData {
  UserData({
    this.playbackPositionTicks,
    this.playedPercentage,
    this.isFavorite,
    this.played,
    this.likes,
  });

  factory UserData.fromJson(Map<String, dynamic> json) => UserData(
    playbackPositionTicks: _as<num>(json['PlaybackPositionTicks'])?.toInt(),
    playedPercentage: _as<num>(json['PlayedPercentage'])?.toDouble(),
    isFavorite: _as<bool>(json['IsFavorite']),
    played: _as<bool>(json['Played']),
    likes: _as<bool>(json['Likes']),
  );

  final int? playbackPositionTicks;
  final double? playedPercentage;
  final bool? isFavorite;
  final bool? played;

  /// Jellyfin’s liked flag; separate from Catch Up’s seen/skipped choices.
  final bool? likes;
}

class Person {
  Person({
    required this.id,
    required this.name,
    this.role,
    this.type,
    this.primaryImageTag,
  });

  factory Person.fromJson(Map<String, dynamic> json) => Person(
    id: json['Id'] as String,
    name: json['Name'] as String? ?? '',
    role: _as<String>(json['Role']),
    type: _as<String>(json['Type']),
    primaryImageTag: _as<String>(json['PrimaryImageTag']),
  );

  final String id;
  final String name;
  final String? role;
  final String? type;
  final String? primaryImageTag;

  /// Lets cast portraits reuse the artwork pipeline.
  MediaItem get asItem => MediaItem(
    id: id,
    name: name,
    type: 'Person',
    imageTags: {'Primary': ?primaryImageTag},
  );
}

/// A Live TV guide entry.
class LiveProgram {
  LiveProgram({
    required this.name,
    this.id,
    this.channelId,
    this.start,
    this.end,
    this.overview,
    this.episodeTitle,
    this.isLive,
    this.isRepeat,
    this.isSports,
    this.genres = const [],
    this.imageTags = const {},
    this.backdropImageTags = const [],
  });

  factory LiveProgram.fromJson(Map<String, dynamic> json) => LiveProgram(
    id: _as<String>(json['Id']),
    channelId: _as<String>(json['ChannelId']),
    name: _as<String>(json['Name']) ?? '',
    overview: _as<String>(json['Overview']),
    start: jellyfinDate(_as<String>(json['StartDate'])),
    end: jellyfinDate(_as<String>(json['EndDate'])),
    episodeTitle: _as<String>(json['EpisodeTitle']),
    isLive: _as<bool>(json['IsLive']),
    isRepeat: _as<bool>(json['IsRepeat']),
    isSports: _as<bool>(json['IsSports']),
    genres: (_as<List>(json['Genres']) ?? []).whereType<String>().toList(),
    imageTags: {
      for (final e
          in (_as<Map<String, dynamic>>(json['ImageTags']) ?? {}).entries)
        if (e.value is String) e.key: e.value as String,
    },
    backdropImageTags: (_as<List>(json['BackdropImageTags']) ?? [])
        .whereType<String>()
        .toList(),
  );

  final String? id;
  final String? channelId;
  final String name;
  final String? overview;
  final DateTime? start;
  final DateTime? end;
  final String? episodeTitle;
  final bool? isLive;
  final bool? isRepeat;
  final bool? isSports;
  final List<String> genres;
  final Map<String, String> imageTags;
  final List<String> backdropImageTags;

  bool get hasSchedule => start != null && end != null && end!.isAfter(start!);

  bool isAiring(DateTime now) =>
      hasSchedule && !now.isBefore(start!) && now.isBefore(end!);
}

/// Jellyfin dates, which may omit the UTC designator; read as UTC then shown
/// in local time.
DateTime? jellyfinDate(String? text) {
  if (text == null || text.isEmpty) return null;
  final zoned = RegExp(r'(Z|[+-]\d{2}:?\d{2})$').hasMatch(text);
  return DateTime.tryParse(zoned ? text : '${text}Z')?.toLocal();
}

class MediaStream {
  MediaStream({
    required this.index,
    required this.type,
    this.language,
    this.displayTitle,
    this.codec,
    this.channels,
    this.isDefault = false,
    this.isForced = false,
    this.width,
    this.height,
    this.isTextSubtitle = false,
    this.isExternal = false,
    this.deliveryUrl,
    this.videoRange,
    this.videoRangeType,
    this.bitDepth,
    this.frameRate,
    this.profile,
    this.audioSpatialFormat,
    this.channelLayout,
    this.isInterlaced = false,
    this.isAttachedPicture = false,
  });

  factory MediaStream.fromJson(Map<String, dynamic> json) => MediaStream(
    index: _as<num>(json['Index'])?.toInt() ?? -1,
    type: _as<String>(json['Type']) ?? '',
    language: _as<String>(json['Language']),
    displayTitle: _as<String>(json['DisplayTitle']),
    codec: _as<String>(json['Codec']),
    channels: _as<num>(json['Channels'])?.toInt(),
    isDefault: _as<bool>(json['IsDefault']) ?? false,
    isForced: _as<bool>(json['IsForced']) ?? false,
    width: _as<num>(json['Width'])?.toInt(),
    height: _as<num>(json['Height'])?.toInt(),
    isTextSubtitle: _as<bool>(json['IsTextSubtitleStream']) ?? false,
    isExternal: _as<bool>(json['IsExternal']) ?? false,
    deliveryUrl: _as<String>(json['DeliveryUrl']),
    videoRange: _as<String>(json['VideoRange']),
    videoRangeType: _as<String>(json['VideoRangeType']),
    bitDepth: _as<num>(json['BitDepth'])?.toInt(),
    frameRate:
        _as<num>(json['AverageFrameRate'])?.toDouble() ??
        _as<num>(json['RealFrameRate'])?.toDouble(),
    profile: _as<String>(json['Profile']),
    audioSpatialFormat: _as<String>(json['AudioSpatialFormat']),
    channelLayout: _as<String>(json['ChannelLayout']),
    isInterlaced: _as<bool>(json['IsInterlaced']) ?? false,
    isAttachedPicture: _as<bool>(json['IsAttachedPic']) ?? false,
  );

  final int index;

  /// `Video`, `Audio` or `Subtitle`.
  final String type;
  final String? language;
  final String? displayTitle;
  final String? codec;

  /// A PGS (Blu-ray image) subtitle stream.
  /// ASS/SSA: styled text subtitles (colours, positions, fonts sizes).
  bool get isStyled =>
      type == 'Subtitle' && {'ass', 'ssa'}.contains(codec?.toLowerCase());
  bool get isPgs =>
      type == 'Subtitle' && {'pgssub', 'pgs'}.contains(codec?.toLowerCase());
  final int? channels;
  final bool isDefault;
  final bool isForced;
  final int? width;
  final int? height;

  /// Text subtitles can be delivered as WebVTT and styled on the device;
  /// image subtitles are burned in by the server.
  final bool isTextSubtitle;
  final bool isExternal;
  final String? deliveryUrl;
  final String? videoRange;
  final String? videoRangeType;
  final int? bitDepth;
  final double? frameRate;
  final String? profile;
  final String? audioSpatialFormat;
  final String? channelLayout;
  final bool isInterlaced;
  final bool isAttachedPicture;
}

class MediaSource {
  MediaSource({
    this.id,
    this.container,
    this.supportsDirectPlay,
    this.supportsDirectStream,
    this.supportsTranscoding,
    this.transcodingUrl,
    this.transcodingSubProtocol,
    this.requiresOpening,
    this.openToken,
    this.requiresClosing,
    this.liveStreamId,
    this.mediaStreams = const [],
    this.name,
    this.size,
    this.bitrate,
    this.defaultAudioStreamIndex,
    this.defaultSubtitleStreamIndex,
  });

  factory MediaSource.fromJson(Map<String, dynamic> json) => MediaSource(
    id: _as<String>(json['Id']),
    container: _as<String>(json['Container']),
    supportsDirectPlay: _as<bool>(json['SupportsDirectPlay']),
    supportsDirectStream: _as<bool>(json['SupportsDirectStream']),
    supportsTranscoding: _as<bool>(json['SupportsTranscoding']),
    transcodingUrl: _as<String>(json['TranscodingUrl']),
    transcodingSubProtocol: _as<String>(json['TranscodingSubProtocol']),
    requiresOpening: _as<bool>(json['RequiresOpening']),
    openToken: _as<String>(json['OpenToken']),
    requiresClosing: _as<bool>(json['RequiresClosing']),
    liveStreamId: _as<String>(json['LiveStreamId']),
    mediaStreams: _list(json['MediaStreams'], MediaStream.fromJson),
    name: _as<String>(json['Name']),
    size: _as<num>(json['Size'])?.toInt(),
    bitrate: _as<num>(json['Bitrate'])?.toInt(),
    defaultAudioStreamIndex: _as<num>(json['DefaultAudioStreamIndex'])?.toInt(),
    defaultSubtitleStreamIndex: _as<num>(
      json['DefaultSubtitleStreamIndex'],
    )?.toInt(),
  );

  final String? id;
  final String? container;
  final bool? supportsDirectPlay;
  final bool? supportsDirectStream;
  final bool? supportsTranscoding;
  final String? transcodingUrl;
  final String? transcodingSubProtocol;
  final bool? requiresOpening;
  final String? openToken;
  final bool? requiresClosing;
  final String? liveStreamId;
  final List<MediaStream> mediaStreams;
  final String? name;
  final int? size;
  final int? bitrate;

  /// The server's per-viewer track defaults, including remembered choices.
  final int? defaultAudioStreamIndex;
  final int? defaultSubtitleStreamIndex;
}

class MediaItem {
  MediaItem({
    required this.id,
    required this.name,
    this.type = 'Movie',
    this.overview,
    this.productionYear,
    this.officialRating,
    this.communityRating,
    this.runTimeTicks,
    this.imageTags = const {},
    this.backdropImageTags = const [],
    this.parentBackdropItemId,
    this.parentBackdropImageTags = const [],
    this.seriesId,
    this.seriesName,
    this.seasonId,
    this.indexNumber,
    this.parentIndexNumber,
    this.genres = const [],
    this.userData,
    this.mediaSources = const [],
    this.taglines = const [],
    this.channelNumber,
    this.people = const [],
    this.currentProgram,
    this.mediaStreams = const [],
    this.container,
    this.endDate,
  });

  factory MediaItem.fromJson(Map<String, dynamic> json) => MediaItem(
    id: json['Id'] as String,
    name: json['Name'] as String? ?? '',
    type: _as<String>(json['Type']) ?? 'Movie',
    overview: _as<String>(json['Overview']),
    productionYear: _as<num>(json['ProductionYear'])?.toInt(),
    officialRating: _as<String>(json['OfficialRating']),
    communityRating: _as<num>(json['CommunityRating'])?.toDouble(),
    runTimeTicks: _as<num>(json['RunTimeTicks'])?.toInt(),
    imageTags: {
      for (final e
          in (_as<Map<String, dynamic>>(json['ImageTags']) ?? {}).entries)
        if (e.value is String) e.key: e.value as String,
    },
    backdropImageTags: (_as<List>(json['BackdropImageTags']) ?? [])
        .whereType<String>()
        .toList(),
    parentBackdropItemId: _as<String>(json['ParentBackdropItemId']),
    parentBackdropImageTags: (_as<List>(json['ParentBackdropImageTags']) ?? [])
        .whereType<String>()
        .toList(),
    seriesId: _as<String>(json['SeriesId']),
    seriesName: _as<String>(json['SeriesName']),
    seasonId: _as<String>(json['SeasonId']),
    indexNumber: _as<num>(json['IndexNumber'])?.toInt(),
    parentIndexNumber: _as<num>(json['ParentIndexNumber'])?.toInt(),
    genres: (_as<List>(json['Genres']) ?? []).whereType<String>().toList(),
    userData: _as<Map<String, dynamic>>(json['UserData']) == null
        ? null
        : UserData.fromJson(json['UserData'] as Map<String, dynamic>),
    mediaSources: _list(json['MediaSources'], MediaSource.fromJson),
    taglines: (_as<List>(json['Taglines']) ?? []).whereType<String>().toList(),
    channelNumber: _as<String>(json['ChannelNumber']),
    people: _list(json['People'], Person.fromJson),
    currentProgram: _as<Map<String, dynamic>>(json['CurrentProgram']) == null
        ? null
        : LiveProgram.fromJson(json['CurrentProgram'] as Map<String, dynamic>),
    mediaStreams: _list(json['MediaStreams'], MediaStream.fromJson),
    container: _as<String>(json['Container']),
    endDate: DateTime.tryParse(_as<String>(json['EndDate']) ?? '')?.toLocal(),
  );

  final String id;
  final String name;
  final String type;
  final String? overview;
  final int? productionYear;
  final String? officialRating;
  final double? communityRating;
  final int? runTimeTicks;
  final Map<String, String> imageTags;
  final List<String> backdropImageTags;
  final String? parentBackdropItemId;
  final List<String> parentBackdropImageTags;
  final String? seriesId;
  final String? seriesName;
  final String? seasonId;
  final int? indexNumber;
  final int? parentIndexNumber;
  final List<String> genres;
  final UserData? userData;
  final List<MediaSource> mediaSources;
  final List<String> taglines;
  final String? channelNumber;
  final List<Person> people;

  /// What a Live TV channel is airing, when the server included it.
  final LiveProgram? currentProgram;

  /// List endpoints return the default version's streams here when asked
  /// for the `MediaStreams` field; detail reads use [mediaSources].
  final List<MediaStream> mediaStreams;
  final String? container;

  /// Series end date, used by Requests and seasonal rows.
  final DateTime? endDate;

  /// The series an episode, season or series page browses.
  String? get episodeSeriesId =>
      isSeries ? id : (isEpisode || type == 'Season' ? seriesId : null);

  /// Overview text without the HTML tags some metadata providers include.
  String? get plainOverview => overview?.replaceAll(RegExp(r'<[^>]+>'), '');

  /// Copy with new user data, for optimistic watched/favorite updates.
  MediaItem withUserData(UserData? data) => MediaItem(
    id: id,
    name: name,
    type: type,
    overview: overview,
    productionYear: productionYear,
    officialRating: officialRating,
    communityRating: communityRating,
    runTimeTicks: runTimeTicks,
    imageTags: imageTags,
    backdropImageTags: backdropImageTags,
    parentBackdropItemId: parentBackdropItemId,
    parentBackdropImageTags: parentBackdropImageTags,
    seriesId: seriesId,
    seriesName: seriesName,
    seasonId: seasonId,
    indexNumber: indexNumber,
    parentIndexNumber: parentIndexNumber,
    genres: genres,
    userData: data,
    mediaSources: mediaSources,
    taglines: taglines,
    channelNumber: channelNumber,
    people: people,
    currentProgram: currentProgram,
    mediaStreams: mediaStreams,
    container: container,
    endDate: endDate,
  );

  bool get isSeries => type == 'Series';
  bool get isEpisode => type == 'Episode';
  bool get isLive => type == 'TvChannel';
  String get displayTitle => isEpisode ? (seriesName ?? name) : name;
  String get episodeLabel => isEpisode
      ? 'S${parentIndexNumber ?? 1} E${indexNumber ?? 1} · $name'
      : '';
  // Dart compiled to JavaScript uses 32-bit bitwise shifts: `1 << 62`
  // evaluates to zero there. Keep Jellyfin's 100ns ticks in the exact shared
  // integer range instead of collapsing every web resume position to zero.
  int get resumeTicks =>
      (userData?.playbackPositionTicks ?? 0).clamp(0, 9007199254740991);

  /// Watched fraction for progress bars, from 0 to 1.
  double get progress {
    final total = runTimeTicks ?? 0;
    if (total <= 0 || resumeTicks <= 0) return 0;
    return (resumeTicks / total).clamp(0.0, 1.0);
  }

  String get durationLabel {
    final minutes = (runTimeTicks ?? 0) ~/ 600000000;
    if (minutes <= 0) return '';
    return minutes >= 60 ? '${minutes ~/ 60}h ${minutes % 60}m' : '${minutes}m';
  }
}

class ItemPage {
  ItemPage({required this.items, this.totalRecordCount});

  factory ItemPage.fromJson(Map<String, dynamic> json) => ItemPage(
    items: _list(json['Items'], MediaItem.fromJson),
    totalRecordCount: _as<num>(json['TotalRecordCount'])?.toInt(),
  );

  final List<MediaItem> items;
  final int? totalRecordCount;
}

class PlaybackInfo {
  PlaybackInfo({
    this.mediaSources = const [],
    this.playSessionId,
    this.errorCode,
  });

  factory PlaybackInfo.fromJson(Map<String, dynamic> json) => PlaybackInfo(
    mediaSources: _list(json['MediaSources'], MediaSource.fromJson),
    playSessionId: _as<String>(json['PlaySessionId']),
    errorCode: _as<String>(json['ErrorCode']),
  );

  final List<MediaSource> mediaSources;
  final String? playSessionId;
  final String? errorCode;
}
