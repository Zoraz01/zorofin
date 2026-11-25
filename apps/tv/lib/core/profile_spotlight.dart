import 'dart:convert';

import 'home.dart';
import 'jellyfin_client.dart';
import 'models.dart';

/// An image on the profile's own server.
class SpotlightImage {
  const SpotlightImage(this.itemId, this.kind, this.tag);

  factory SpotlightImage.fromJson(Map<String, dynamic> json) => SpotlightImage(
    json['itemId'] as String,
    json['kind'] as String,
    json['tag'] as String,
  );

  final String itemId;
  final String kind;
  final String tag;

  String get cacheKey => '$itemId-$kind-$tag';
  Map<String, dynamic> toJson() => {'itemId': itemId, 'kind': kind, 'tag': tag};

  @override
  bool operator ==(Object other) =>
      other is SpotlightImage && other.cacheKey == cacheKey;
  @override
  int get hashCode => cacheKey.hashCode;
}

/// What a saved profile was last watching, shown behind "Who's watching?"
/// (Apple `ProfileSpotlight`). Built from that profile's own Continue
/// Watching with its own session.
class ProfileSpotlight {
  const ProfileSpotlight({
    required this.itemId,
    required this.title,
    required this.detail,
    this.progress,
    this.backdrop,
    this.thumbnail,
  });

  factory ProfileSpotlight.fromJson(Map<String, dynamic> json) =>
      ProfileSpotlight(
        itemId: json['itemId'] as String,
        title: json['title'] as String? ?? '',
        detail: json['detail'] as String? ?? '',
        progress: (json['progress'] as num?)?.toDouble(),
        backdrop: json['backdrop'] is Map<String, dynamic>
            ? SpotlightImage.fromJson(json['backdrop'] as Map<String, dynamic>)
            : null,
        thumbnail: json['thumbnail'] is Map<String, dynamic>
            ? SpotlightImage.fromJson(json['thumbnail'] as Map<String, dynamic>)
            : null,
      );

  final String itemId;

  /// Show name for an episode, otherwise the title.
  final String title;

  /// "S2 E4 · The Long Dark" for an episode, empty for a movie.
  final String detail;

  /// 0 to 1 when the item has a resume position.
  final double? progress;
  final SpotlightImage? backdrop;
  final SpotlightImage? thumbnail;

  String get line => detail.isEmpty ? title : '$title · $detail';

  Map<String, dynamic> toJson() => {
    'itemId': itemId,
    'title': title,
    'detail': detail,
    'progress': ?progress,
    'backdrop': ?backdrop?.toJson(),
    'thumbnail': ?thumbnail?.toJson(),
  };

  /// The first item with wide art leads; without any art the first item
  /// still names what they were watching.
  static ProfileSpotlight? pick(List<MediaItem> items) {
    final usable = items.where((i) => i.id.isNotEmpty && i.name.isNotEmpty);
    final item =
        usable.where((i) => backdropFor(i) != null).firstOrNull ??
        usable.firstOrNull;
    if (item == null) return null;
    double? progress;
    final runtime = item.runTimeTicks ?? 0;
    if (runtime > 0 && item.resumeTicks > 0) {
      progress = (item.resumeTicks / runtime).clamp(0.0, 1.0);
    } else if ((item.userData?.playedPercentage ?? 0) > 0) {
      progress = (item.userData!.playedPercentage! / 100).clamp(0.0, 1.0);
    }
    return ProfileSpotlight(
      itemId: item.id,
      title: item.displayTitle,
      detail: item.episodeLabel,
      progress: progress,
      backdrop: backdropFor(item),
      thumbnail: thumbnailFor(item),
    );
  }

  /// Show/movie backdrop first; an episode still only as a fallback.
  static SpotlightImage? backdropFor(MediaItem item) {
    String? ok(String? v) => (v == null || v.trim().isEmpty) ? null : v;
    final own = ok(item.backdropImageTags.firstOrNull);
    if (own != null) return SpotlightImage(item.id, 'Backdrop', own);
    final parent = ok(item.parentBackdropItemId);
    final parentTag = ok(item.parentBackdropImageTags.firstOrNull);
    if (parent != null && parentTag != null) {
      return SpotlightImage(parent, 'Backdrop', parentTag);
    }
    final thumb = ok(item.imageTags['Thumb']);
    if (thumb != null) return SpotlightImage(item.id, 'Thumb', thumb);
    final primary = ok(item.imageTags['Primary']);
    if (item.isEpisode && primary != null) {
      return SpotlightImage(item.id, 'Primary', primary);
    }
    return null;
  }

  static SpotlightImage? thumbnailFor(MediaItem item) {
    String? ok(String? v) => (v == null || v.trim().isEmpty) ? null : v;
    final primary = ok(item.imageTags['Primary']);
    if (item.isEpisode && primary != null) {
      return SpotlightImage(item.id, 'Primary', primary);
    }
    final thumb = ok(item.imageTags['Thumb']);
    if (thumb != null) return SpotlightImage(item.id, 'Thumb', thumb);
    return backdropFor(item);
  }
}

extension ProfileSpotlightReads on JellyfinClient {
  /// Continue Watching for this client's viewer, reduced to one item.
  Future<ProfileSpotlight?> profileSpotlight() async =>
      ProfileSpotlight.pick((await continueWatchingFeed()).items);
}

/// Built-in avatars for profiles without a photo (Apple `SceneAvatar`).
const sceneAvatars = [
  'northbound',
  'orbital',
  'ember',
  'tide',
  'harbor',
  'saltflats',
  'lastlight',
];

/// Sum of UTF-8 bytes mod 7, so a viewer gets the same scene on every app.
String sceneAvatarFor(String viewerId) {
  var sum = 0;
  for (final b in utf8.encode(viewerId.toLowerCase())) {
    sum += b;
  }
  return sceneAvatars[sum % sceneAvatars.length];
}

String sceneAvatarAsset(String viewerId) =>
    'assets/images/scene-${sceneAvatarFor(viewerId)}.jpg';
