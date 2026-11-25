import 'dart:async';

import 'errors.dart';
import 'jellyfin_client.dart';
import 'models.dart';

/// What a player tells the server went wrong (plugin capability
/// "playbackReports" version 1). The names are the server's contract.
enum PlaybackProblem {
  startFailed('start_failed'),
  stopped('stopped'),
  fallback('fallback'),
  stalled('stalled'),
  qualityLowered('quality_lowered'),
  recovered('recovered'),
  slowStart('slow_start'),
  appError('app_error');

  const PlaybackProblem(this.kind);
  final String kind;
}

/// Jellyfin's play method as the report's short word.
String playbackReportMethod(String? method, {bool live = false}) {
  if (live) return 'live';
  return switch (method) {
    'DirectPlay' => 'direct',
    'DirectStream' => 'remux',
    'Transcode' => 'transcode',
    _ => '',
  };
}

/// Sends playback problems to the viewer's own server, and only there.
///
/// Nothing is sent unless the server collects reports and the viewer left
/// reporting on. Sending never throws, never blocks playback, and stops for
/// the rest of the session once the server says it is not collecting.
class PlaybackReporter {
  PlaybackReporter({
    required this.client,
    required this.platform,
    required this.enabled,
  });

  final JellyfinClient client;

  /// "Android TV", "Samsung TV", "LG TV", "Android phone".
  final String platform;

  /// Read at send time: the server's switch and the viewer's own.
  final bool Function() enabled;

  /// A player in a failure loop must not flood the server.
  static const maxPerSession = 30;

  // Shared by every player in this run of the app.
  static int _sent = 0;
  static bool _refused = false;

  /// For tests.
  static void reset() {
    _sent = 0;
    _refused = false;
  }

  static Map<String, Object?> body({
    required PlaybackProblem problem,
    required String platform,
    required String appVersion,
    required String device,
    MediaItem? item,
    String? itemId,
    String? itemTitle,
    String method = '',
    String reason = '',
    Duration? startTook,
    Duration? position,
  }) {
    final title =
        itemTitle ??
        (item == null
        ? ''
        : item.isEpisode && item.seriesName != null
        ? '${item.seriesName}: ${item.name}'
        : item.name);
    return {
      'kind': problem.kind,
      'itemId': itemId ?? item?.id ?? '',
      'title': title,
      'platform': platform,
      'appVersion': appVersion,
      'device': device,
      'method': method,
      'reason': reason.length > 300 ? reason.substring(0, 300) : reason,
      'startMs': ?startTook?.inMilliseconds,
      'positionSeconds': ?position?.inSeconds,
    };
  }

  Future<void> send(
    PlaybackProblem problem, {
    MediaItem? item,

    /// For shells that hold the title as plain values (the LG web app).
    String? itemId,
    String? itemTitle,
    String method = '',
    String reason = '',
    Duration? startTook,
    Duration? position,
  }) async {
    if (_refused || _sent >= maxPerSession || client.session == null) return;
    try {
      if (!enabled()) return;
      _sent++;
      await client.requestText(
        ['Zorofin', 'PlaybackReports'],
        method: 'POST',
        extensionToken: true,
        body: body(
          problem: problem,
          platform: platform,
          appVersion: client.identity.version,
          device: client.identity.deviceName,
          item: item,
          itemId: itemId,
          itemTitle: itemTitle,
          method: method,
          reason: reason,
          startTook: startTook,
          position: position,
        ),
      );
    } on ClientError catch (e) {
      // 404: the owner switched collection off since sign-in. 429: enough.
      if (e.status == 404 || e.status == 429) _refused = true;
    } catch (_) {
      // A report is never worth interrupting the viewer for.
    }
  }
}

/// One player's view of [PlaybackReporter]: times the start and watches for
/// long buffering, so the two players report the same things the same way.
class PlayerProblems {
  PlayerProblems(this.reporter, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final PlaybackReporter reporter;

  /// A start slower than this is worth the owner knowing about.
  static const slowStart = Duration(seconds: 10);

  /// Buffering this long while playing is a stall, not a seek.
  static const stall = Duration(seconds: 10);

  final DateTime Function() _now;
  DateTime? _opened;
  Timer? _stall;

  /// A stream is being opened.
  void opening() {
    _stall?.cancel();
    _opened = _now();
  }

  /// The stream opened and is showing.
  void started(MediaItem item, String method) {
    final opened = _opened;
    if (opened == null) return;
    _opened = null;
    final took = _now().difference(opened);
    if (took >= slowStart) {
      unawaited(
        reporter.send(
          PlaybackProblem.slowStart,
          item: item,
          method: method,
          startTook: took,
        ),
      );
    }
  }

  /// The player started or stopped buffering mid-title.
  void buffering(
    bool on,
    MediaItem item,
    String method,
    Duration? Function() position,
  ) {
    _stall?.cancel();
    if (!on) return;
    _stall = Timer(stall, () {
      unawaited(
        reporter.send(
          PlaybackProblem.stalled,
          item: item,
          method: method,
          reason: 'Buffering for ${stall.inSeconds} s',
          position: position(),
        ),
      );
    });
  }

  void report(
    PlaybackProblem problem,
    MediaItem item,
    String method, {
    String reason = '',
    Duration? position,
  }) {
    final opened = _opened;
    final took = opened == null ? null : _now().difference(opened);
    if (problem == PlaybackProblem.startFailed) _opened = null;
    unawaited(
      reporter.send(
        problem,
        item: item,
        method: method,
        reason: reason,
        startTook: problem == PlaybackProblem.startFailed ? took : null,
        position: position,
      ),
    );
  }

  void dispose() => _stall?.cancel();
}
