import 'package:flutter_test/flutter_test.dart';
import 'package:zorofin_tv/core/playback_recovery.dart';

void main() {
  Future<void> noSleep(Duration _) async {}

  test('a server that answers is not a network problem', () async {
    var away = false;
    final wait = ServerWait(ping: () async {}, sleep: noSleep);
    expect(
      await wait.wait(onAway: () => away = true),
      ServerWaitResult.reachable,
    );
    expect(away, isFalse);
  });

  test('waits for the server to come back', () async {
    var pings = 0, away = 0;
    final wait = ServerWait(
      ping: () async {
        if (++pings < 4) throw Exception('offline');
      },
      sleep: noSleep,
    );
    expect(await wait.wait(onAway: () => away++), ServerWaitResult.returned);
    expect(pings, 4);
    expect(away, 1);
  });

  test('gives up after the limit', () async {
    var pings = 0;
    final wait = ServerWait(
      ping: () async {
        pings++;
        throw Exception('offline');
      },
      every: const Duration(seconds: 3),
      limit: const Duration(seconds: 9),
      sleep: noSleep,
    );
    expect(await wait.wait(), ServerWaitResult.gaveUp);
    expect(pings, 4);
  });

  test('cancel ends the wait', () async {
    late ServerWait wait;
    wait = ServerWait(
      ping: () async => throw Exception('offline'),
      sleep: (_) async => wait.cancel(),
    );
    expect(await wait.wait(), ServerWaitResult.cancelled);
  });
}
