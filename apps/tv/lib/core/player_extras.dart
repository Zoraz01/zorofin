import 'jellyfin_client.dart';
import 'models.dart';
import 'server_address.dart';
import 'viewer_settings.dart';

/// A chapter marker from Jellyfin (`Fields=Chapters`).
class Chapter {
  const Chapter({
    required this.start,
    required this.name,
    this.imageTag,
    this.imageIndex = 0,
  });

  final Duration start;
  final String name;
  final String? imageTag;

  /// The chapter's place in Jellyfin's list, which its image URL uses.
  final int imageIndex;

  /// Chapters in time order. Unnamed ones are numbered in that order.
  static List<Chapter> fromItem(Map<String, dynamic> json) {
    final list = json['Chapters'];
    if (list is! List) return const [];
    final found = <({Duration start, String? name, String? tag, int index})>[];
    for (var i = 0; i < list.length; i++) {
      final entry = list[i];
      if (entry is! Map) continue;
      final ticks = entry['StartPositionTicks'];
      if (ticks is! num || ticks < 0) continue;
      final name = entry['Name'];
      final tag = entry['ImageTag'];
      found.add((
        start: Duration(microseconds: ticks.toInt() ~/ 10),
        name: name is String && name.trim().isNotEmpty ? name.trim() : null,
        tag: tag is String ? tag : null,
        index: i,
      ));
    }
    // A single chapter at 0:00 is no navigation at all.
    if (found.length < 2) return const [];
    found.sort((a, b) => a.start.compareTo(b.start));
    return List.unmodifiable([
      for (var i = 0; i < found.length; i++)
        Chapter(
          start: found[i].start,
          name: found[i].name ?? 'Chapter ${i + 1}',
          imageTag: found[i].tag,
          imageIndex: found[i].index,
        ),
    ]);
  }

  /// The chapter playing at [position], or null before the first one.
  static int? indexAt(List<Chapter> chapters, Duration position) {
    int? current;
    for (var i = 0; i < chapters.length; i++) {
      if (chapters[i].start <= position) {
        current = i;
      } else {
        break;
      }
    }
    return current;
  }
}

/// Jellyfin's scrub thumbnails (`Fields=Trickplay`): sheets of
/// [tileWidth] x [tileHeight] frames, one every [interval].
class Trickplay {
  const Trickplay({
    required this.width,
    required this.height,
    required this.tileWidth,
    required this.tileHeight,
    required this.count,
    required this.interval,
  });

  final int width;
  final int height;
  final int tileWidth;
  final int tileHeight;
  final int count;
  final Duration interval;

  /// The smallest resolution at least [preferredWidth] wide (or the largest
  /// there is) for [mediaSourceId].
  static Trickplay? fromItem(
    Map<String, dynamic> json, {
    String? mediaSourceId,
    int preferredWidth = 320,
  }) {
    final all = json['Trickplay'];
    if (all is! Map || all.isEmpty) return null;
    final bySource = all[mediaSourceId ?? json['Id']] ?? all.values.first;
    if (bySource is! Map) return null;
    final options = <Trickplay>[];
    for (final value in bySource.values) {
      if (value is! Map) continue;
      int read(String key) => (value[key] as num?)?.toInt() ?? 0;
      final info = Trickplay(
        width: read('Width'),
        height: read('Height'),
        tileWidth: read('TileWidth'),
        tileHeight: read('TileHeight'),
        count: read('ThumbnailCount'),
        interval: Duration(milliseconds: read('Interval')),
      );
      if (info.isValid) options.add(info);
    }
    if (options.isEmpty) return null;
    options.sort((a, b) => a.width.compareTo(b.width));
    return options.firstWhere(
      (o) => o.width >= preferredWidth,
      orElse: () => options.last,
    );
  }

  bool get isValid =>
      width > 0 &&
      height > 0 &&
      tileWidth > 0 &&
      tileHeight > 0 &&
      count > 0 &&
      interval > Duration.zero;

  int get _perSheet => tileWidth * tileHeight;

  /// Which sheet holds the frame for [position], and where in it.
  ({int sheet, int column, int row}) frameAt(Duration position) {
    final frame = (position.inMilliseconds ~/ interval.inMilliseconds).clamp(
      0,
      count - 1,
    );
    final inSheet = frame % _perSheet;
    return (
      sheet: frame ~/ _perSheet,
      column: inSheet % tileWidth,
      row: inSheet ~/ tileWidth,
    );
  }

  /// `Videos/{id}/Trickplay/{width}/{sheet}.jpg`; fetched with the
  /// client's auth headers, never a token in the URL.
  Uri sheetUrl(
    ServerAddress server,
    String itemId,
    int sheet, {
    String? mediaSourceId,
  }) => server.endpoint(
    ['Videos', itemId, 'Trickplay', '$width', '$sheet.jpg'],
    {'mediaSourceId': ?mediaSourceId},
  );
}

/// What the viewer last picked for a show, so later episodes follow it.
class TrackMemory {
  const TrackMemory({
    this.audioLanguage,
    this.subtitleLanguage,
    this.subtitlesOff = false,
    this.subtitleForced = false,
    this.subtitleOffset = Duration.zero,
    this.audioOffset = Duration.zero,
  });

  final String? audioLanguage;
  final String? subtitleLanguage;
  final bool subtitlesOff;
  final bool subtitleForced;

  /// Positive: subtitles appear later. Kept for this show or movie.
  final Duration subtitleOffset;

  /// Positive: sound plays later. Only players that own the audio apply it.
  final Duration audioOffset;

  static const maxOffset = Duration(seconds: 10);

  /// The key a choice is remembered under: the show, or the movie itself.
  static String keyFor(MediaItem item) => item.seriesId ?? item.id;

  factory TrackMemory.fromJson(Map<String, dynamic> json) => TrackMemory(
    audioLanguage: json['audio'] as String?,
    subtitleLanguage: json['subtitle'] as String?,
    subtitlesOff: json['off'] == true,
    subtitleForced: json['forced'] == true,
    subtitleOffset: _offset(json['subtitleOffsetMs']),
    audioOffset: _offset(json['audioOffsetMs']),
  );

  static Duration _offset(Object? value) {
    final ms = value is num ? value.toInt() : 0;
    final clamped = ms.clamp(
      -maxOffset.inMilliseconds,
      maxOffset.inMilliseconds,
    );
    return Duration(milliseconds: clamped);
  }

  Map<String, dynamic> toJson() => {
    'audio': ?audioLanguage,
    'subtitle': ?subtitleLanguage,
    if (subtitlesOff) 'off': true,
    if (subtitleForced) 'forced': true,
    if (subtitleOffset != Duration.zero)
      'subtitleOffsetMs': subtitleOffset.inMilliseconds,
    if (audioOffset != Duration.zero)
      'audioOffsetMs': audioOffset.inMilliseconds,
  };

  /// Records the tracks just chosen. Unchanged parts are kept.
  TrackMemory choosing({MediaStream? audio, MediaStream? subtitle, bool? off}) {
    final turningOff = off == true;
    return TrackMemory(
      audioLanguage: _language(audio) ?? audioLanguage,
      subtitleLanguage: turningOff
          ? subtitleLanguage
          : _language(subtitle) ?? subtitleLanguage,
      subtitlesOff: turningOff
          ? true
          : (subtitle != null ? false : subtitlesOff),
      subtitleForced: subtitle != null ? subtitle.isForced : subtitleForced,
      subtitleOffset: subtitleOffset,
      audioOffset: audioOffset,
    );
  }

  TrackMemory withOffsets({Duration? subtitle, Duration? audio}) => TrackMemory(
    audioLanguage: audioLanguage,
    subtitleLanguage: subtitleLanguage,
    subtitlesOff: subtitlesOff,
    subtitleForced: subtitleForced,
    subtitleOffset: subtitle == null
        ? subtitleOffset
        : _offset(subtitle.inMilliseconds),
    audioOffset: audio == null ? audioOffset : _offset(audio.inMilliseconds),
  );

  static String? _language(MediaStream? stream) {
    final language = stream?.language?.trim();
    return language == null || language.isEmpty ? null : language;
  }

  /// Stream indexes in [streams] that match this choice; null where there is
  /// nothing remembered or no track in that language.
  ({int? audio, int? subtitle}) pick(List<MediaStream> streams) {
    int? audio;
    if (audioLanguage != null) {
      audio = streams
          .where(
            (s) =>
                s.type == 'Audio' &&
                ViewerSettings.sameLanguage(s.language, audioLanguage!),
          )
          .firstOrNull
          ?.index;
    }
    int? subtitle;
    if (subtitlesOff) {
      subtitle = -1;
    } else if (subtitleLanguage != null) {
      final matches = streams
          .where(
            (s) =>
                s.type == 'Subtitle' &&
                ViewerSettings.sameLanguage(s.language, subtitleLanguage!),
          )
          .toList();
      subtitle =
          (matches.where((s) => s.isForced == subtitleForced).firstOrNull ??
                  matches.firstOrNull)
              ?.index;
    }
    return (audio: audio, subtitle: subtitle);
  }
}

/// Steps for the timing controls.
const timingStep = Duration(milliseconds: 100);

/// `+0.3 s`, `−1.2 s`, `In sync`.
String timingLabel(Duration offset) {
  if (offset == Duration.zero) return 'In sync';
  final seconds = offset.inMilliseconds.abs() / 1000;
  final sign = offset.isNegative ? '−' : '+';
  return '$sign${seconds.toStringAsFixed(1)} s';
}

/// Chapters and scrub thumbnails for one title, loaded when it opens.
class PlayerExtras {
  const PlayerExtras({this.chapters = const [], this.trickplay});

  final List<Chapter> chapters;
  final Trickplay? trickplay;

  static const none = PlayerExtras();

  /// Without chapter names, marks and pictures, for viewers who keep
  /// "Show chapters" off. Scrub thumbnails stay.
  PlayerExtras withoutChapters() => PlayerExtras(trickplay: trickplay);
}

extension PlayerExtrasRequests on JellyfinClient {
  /// Optional: a server without chapters or trickplay just has none.
  Future<PlayerExtras> playerExtras(String id, {String? mediaSourceId}) async {
    final json = await requestJson(
      ['Items', id],
      query: {'userId': ?session?.viewer.id, 'fields': 'Chapters,Trickplay'},
    );
    if (json is! Map<String, dynamic>) return PlayerExtras.none;
    return PlayerExtras(
      chapters: Chapter.fromItem(json),
      trickplay: Trickplay.fromItem(json, mediaSourceId: mediaSourceId),
    );
  }

  /// A chapter's still, fetched with [authHeaders].
  Uri chapterImage(String itemId, int index, String tag) => server.endpoint(
    ['Items', itemId, 'Images', 'Chapter', '$index'],
    {'maxWidth': '400', 'quality': '80', 'tag': tag},
  );
}
