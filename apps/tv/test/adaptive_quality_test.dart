import 'package:flutter_test/flutter_test.dart';
import 'package:zorofin_tv/core/adaptive_quality.dart';

void main() {
  test(
    'sustained buffering lowers below the actual source rate, then cools down',
    () {
      final policy = AdaptiveQuality(40000000);
      int? change;
      for (var t = 0; t < 20; t++) {
        change ??= policy.sample(
          now: t.toDouble(),
          position: 10,
          bitrate: 40000000,
          enabled: true,
          ready: true,
          paused: false,
          seeking: false,
          buffering: true,
          sourceBitrate: 17000000,
        );
      }
      expect(change, 12000000);
      expect(policy.reason, 'Reduced after buffering');
      for (var t = 20; t < 40; t++) {
        expect(
          policy.sample(
            now: t.toDouble(),
            position: 10,
            bitrate: 12000000,
            enabled: true,
            ready: true,
            paused: false,
            seeking: false,
            buffering: true,
          ),
          isNull,
        );
      }
    },
  );
  test(
    'manual quality, startup, pause, seek and disabled/background never adapt',
    () {
      for (var mode = 0; mode < 5; mode++) {
        final policy = AdaptiveQuality(40000000);
        for (var t = 0; t < 100; t++) {
          expect(
            policy.sample(
              now: t.toDouble(),
              position: 10,
              bitrate: 40000000,
              enabled: mode != 0 && mode != 4,
              ready: mode != 1,
              paused: mode == 2,
              seeking: mode == 3,
              buffering: true,
            ),
            isNull,
          );
        }
      }
    },
  );
  test(
    'smooth playback and a full buffer never raise the selected bitrate',
    () {
      final policy = AdaptiveQuality(40000000);
      for (var t = 0; t < 1800; t++) {
        expect(
          policy.sample(
            now: t.toDouble(),
            position: t.toDouble(),
            bitrate: 12000000,
            enabled: true,
            ready: true,
            paused: false,
            seeking: false,
            buffering: false,
            bufferedAhead: 120,
          ),
          isNull,
        );
      }
      final next = policy.sample(
        now: 1800,
        position: 1800,
        bitrate: 12000000,
        enabled: true,
        ready: true,
        paused: false,
        seeking: false,
        buffering: false,
        bufferedAhead: 30,
      );
      expect(next, isNull);
      expect(policy.reason, isNull);
    },
  );
  test(
    'Auto only descends, holds its floor, then stays stable with a full buffer',
    () {
      final policy = AdaptiveQuality(40000000);
      var bitrate = 40000000;
      for (var t = 0; t < 2000; t++) {
        final next = policy.sample(
          now: t.toDouble(),
          position: 10,
          bitrate: bitrate,
          enabled: true,
          ready: true,
          paused: false,
          seeking: false,
          buffering: t < 200,
          bufferedAhead: t < 200 ? 0 : 120,
          sourceBitrate: 17000000,
        );
        if (next != null) {
          expect(next, lessThan(bitrate));
          bitrate = next;
        }
      }
      expect(bitrate, 2000000);
      expect(policy.reason, 'Reduced after buffering');
    },
  );
}
