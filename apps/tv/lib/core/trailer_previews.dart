// Trailer previews on TV Home: rest on a movie or show and its local trailer
// plays muted inside the widened card. Standard Jellyfin local-trailer extras
// only; previews never report playback, touch resume points or Continue
// Watching. Mirrors apps/apple/Core/Sources/ZorofinCore/TrailerPreviews.swift.

import 'jellyfin_client.dart';
import 'models.dart';

/// Direct play only: mp4/mov, H.264 (HEVC when allowed), ≤1080p,
/// AAC/AC-3/E-AC-3. Never transcode for a preview.
bool trailerPreviewCompatible(MediaSource source, {bool allowHevc = true}) {
  final containers = (source.container ?? '').toLowerCase().split(',');
  if (!containers.any(const {'mp4', 'mov', 'm4v'}.contains)) return false;
  final streams = source.mediaStreams;
  final video = streams.where((s) => s.type == 'Video').firstOrNull;
  final codec = video?.codec?.toLowerCase();
  if (video == null ||
      !(codec == 'h264' ||
          (allowHevc && (codec == 'hevc' || codec == 'h265'))) ||
      (video.height ?? 0) > 1080) {
    return false;
  }
  final audio = streams.where((s) => s.type == 'Audio');
  return audio.isEmpty ||
      audio.any(
        (s) => const {'aac', 'ac3', 'eac3'}.contains(s.codec?.toLowerCase()),
      );
}

extension TrailerPreviewClient on JellyfinClient {
  /// The first playable local trailer as a direct stream URL carrying the
  /// viewer's token (for the video element only; never log it), or null.
  Future<({String url, String? subtitleUrl, List<String>? subtitlePath})?>
  previewTrailer(MediaItem item, {bool allowHevc = true}) async {
    final session = this.session;
    if (session == null || (item.type != 'Movie' && item.type != 'Series')) {
      return null;
    }
    final trailers = await requestJson(
      ['Items', item.id, 'LocalTrailers'],
      query: {'userId': session.viewer.id},
    );
    if (trailers is! List || trailers.isEmpty || trailers.first is! Map) {
      return null;
    }
    var trailer = MediaItem.fromJson(
      Map<String, dynamic>.from(trailers.first as Map),
    );
    if (trailer.mediaSources.isEmpty) {
      final full = await requestJson(
        ['Items', trailer.id],
        query: {'userId': session.viewer.id, 'fields': 'MediaSources'},
      );
      if (full is! Map) return null;
      trailer = MediaItem.fromJson(Map<String, dynamic>.from(full));
    }
    final source = trailer.mediaSources.firstOrNull;
    if (source == null ||
        !trailerPreviewCompatible(source, allowHevc: allowHevc)) {
      return null;
    }
    final sourceId = source.id ?? trailer.id;
    final stream = server.endpoint(
      ['Videos', trailer.id, 'stream.mp4'],
      {'static': 'true', 'mediaSourceId': sourceId},
    );
    String? subtitle;
    final text = source.mediaStreams
        .where(
          (s) =>
              s.type == 'Subtitle' &&
              const {
                'srt',
                'subrip',
                'vtt',
                'webvtt',
              }.contains(s.codec?.toLowerCase()),
        )
        .firstOrNull;
    List<String>? subtitlePath;
    if (text != null) {
      subtitlePath = [
        'Videos',
        trailer.id,
        sourceId,
        'Subtitles',
        '${text.index}',
        '0',
        'Stream.vtt',
      ];
      final uri = server.endpoint(subtitlePath);
      subtitle = server.mediaUrl(uri.toString(), session.token).toString();
    }
    return (
      url: server.mediaUrl(stream.toString(), session.token).toString(),
      subtitleUrl: subtitle,
      subtitlePath: subtitlePath,
    );
  }
}
