/// Recovery after the connection to the server drops mid-playback.
///
/// When a stream breaks, the player asks whether the server still answers.
/// If it does, the stream itself is at fault and the player's usual retry
/// applies. If it does not, the player keeps the viewer's place, shows
/// "Reconnecting…" and waits here for the server to answer again.
library;

import 'dart:async';

enum ServerWaitResult {
  /// The server answered at once: the network is not the problem.
  reachable,

  /// The server was away and came back within the limit.
  returned,

  /// The server did not come back in time.
  gaveUp,

  /// The player closed or moved on while waiting.
  cancelled,
}

class ServerWait {
  ServerWait({
    required Future<void> Function() ping,
    this.every = const Duration(seconds: 3),
    this.limit = const Duration(seconds: 90),
    this.pingTimeout = const Duration(seconds: 4),
    Future<void> Function(Duration)? sleep,
  }) : _ping = ping,
       _sleep = sleep ?? Future<void>.delayed;

  final Future<void> Function() _ping;
  final Future<void> Function(Duration) _sleep;
  final Duration every;
  final Duration limit;
  final Duration pingTimeout;

  int _run = 0;

  /// Stops any wait in progress; its future completes with `cancelled`.
  void cancel() => _run++;

  Future<bool> _answers() async {
    try {
      await _ping().timeout(pingTimeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// [onAway] runs once, when the first check finds the server unreachable.
  Future<ServerWaitResult> wait({void Function()? onAway}) async {
    final run = ++_run;
    if (await _answers()) {
      return run == _run
          ? ServerWaitResult.reachable
          : ServerWaitResult.cancelled;
    }
    if (run != _run) return ServerWaitResult.cancelled;
    onAway?.call();
    var waited = Duration.zero;
    while (waited < limit) {
      await _sleep(every);
      waited += every;
      if (run != _run) return ServerWaitResult.cancelled;
      if (await _answers()) {
        return run == _run
            ? ServerWaitResult.returned
            : ServerWaitResult.cancelled;
      }
      if (run != _run) return ServerWaitResult.cancelled;
    }
    return ServerWaitResult.gaveUp;
  }
}
