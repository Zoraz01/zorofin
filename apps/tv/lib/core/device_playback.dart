import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'media_quality.dart';
import 'models.dart';
import 'viewer_settings.dart';
import 'playback.dart';
import 'playback_capabilities.dart';

/// Platform adapters return capability flags. The player stores no device IDs
/// or model names and reads the current output before playback.
class DevicePlayback {
  static const isSamsungTv = bool.fromEnvironment('ZOROFIN_TIZEN_TV');
  static const _q80bTarget = bool.fromEnvironment('ZOROFIN_TIZEN_Q80B');
  static const _knownUhdTarget = bool.fromEnvironment('ZOROFIN_TIZEN_UHD');

  static bool get supportsLocalAudioSelection =>
      !kIsWeb &&
      !isSamsungTv &&
      defaultTargetPlatform == TargetPlatform.android;

  /// Media3 group IDs are opaque. A unique language on both sides identifies
  /// a track even when the container and Android use different language codes.
  static VideoAudioTrack? matchAudioTrack(
    List<MediaStream> streams,
    int index,
    List<VideoAudioTrack> tracks,
  ) {
    final audio = streams.where((s) => s.type == 'Audio' && !s.isExternal);
    final wanted = audio.where((s) => s.index == index).firstOrNull;
    if (wanted == null) return null;
    if (audio.length == 1 && tracks.length == 1) return tracks.single;
    final language = wanted.language;
    if (language == null || language.isEmpty || language == 'und') return null;
    if (audio
            .where((s) => ViewerSettings.sameLanguage(s.language, language))
            .length !=
        1) {
      return null;
    }
    return tracks
        .where((t) => ViewerSettings.sameLanguage(t.language, language))
        .singleOrNull;
  }

  static Future<void> selectDirectAudio(
    VideoPlayerController video,
    PlaybackPlan plan,
    PlaybackOptions options,
  ) async {
    final index = options.audioIndex;
    if (!options.selectAudioOnDevice ||
        plan.method != 'DirectPlay' ||
        index == null) {
      return;
    }
    final track = matchAudioTrack(
      plan.streams,
      index,
      await video.getAudioTracks(),
    );
    if (track == null) {
      throw StateError('Cannot identify requested audio track');
    }
    if (track.isSelected) return;
    await video.selectAudioTrack(track.id);
    // Media3 applies overrides asynchronously. Verify before starting sound.
    for (var attempt = 0; attempt < 12; attempt++) {
      final tracks = await video.getAudioTracks();
      if (tracks.any((t) => t.id == track.id && t.isSelected)) return;
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    throw StateError('Requested audio track was not selected');
  }

  /// Render negotiated HDR on an Android SurfaceView so the display pipeline
  /// receives the video surface directly. Keep the existing texture for SDR.
  static VideoViewType viewType(PlaybackPlan plan) {
    if (isSamsungTv ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      return VideoViewType.textureView;
    }
    final video = MediaQuality.of(plan.source, plan.streams).video;
    final range = video?.videoRangeType;
    final decoder =
        plan.options.capabilities.videos[video?.codec?.toLowerCase()];
    if (range != null &&
        range != 'SDR' &&
        decoder?.rangeTypes.split('|').contains(range) == true) {
      return VideoViewType.platformView;
    }
    return VideoViewType.textureView;
  }

  // The active display can change between playback sessions.
  static Future<PlaybackCapabilities> detect() async {
    if (isSamsungTv) {
      bool q80b = false;
      try {
        q80b =
            await const MethodChannel('org.zorofin.tv/display')
                .invokeMethod<bool>('isQ80B')
                .timeout(const Duration(seconds: 2)) ==
            true;
      } catch (_) {
        // Some runners do not expose a product model.
      }
      return PlaybackCapabilities.samsungTv(
        uhd: q80b || _q80bTarget || _knownUhdTarget,
        q80bHdr: q80b || _q80bTarget,
      );
    }
    try {
      final data = await const MethodChannel('org.zorofin.tv/platform')
          .invokeMapMethod<String, dynamic>('playbackCapabilities')
          .timeout(const Duration(seconds: 3));
      return PlaybackCapabilities.fromJson(data ?? {});
    } catch (_) {
      return const PlaybackCapabilities();
    }
  }
}
