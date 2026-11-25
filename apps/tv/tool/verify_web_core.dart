import 'dart:convert';
import 'package:zorofin_tv/core/adaptive_quality.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/playback.dart';

// Run the same fixture on the VM and compiled JavaScript. Native-only tests
// cannot detect Dart-to-JS integer/bitwise differences in the LG bridge.
void main() {
  for (final ticks in [-1, 0, 18000000000, 864000000000]) {
    final item = MediaItem.fromJson({
      'Id': 'fixture',
      'Name': 'Fixture',
      'Type': 'Episode',
      'RunTimeTicks': 30000000000,
      'UserData': {'PlaybackPositionTicks': ticks},
    });
    final expected = ticks < 0 ? 0 : ticks;
    if (item.resumeTicks != expected) {
      throw StateError(
        'Saved playback position was corrupted: ${item.resumeTicks} != $expected',
      );
    }
    if (MediaTime.ticks(MediaTime.duration(expected)) != expected) {
      throw StateError('Playback tick roundtrip was corrupted');
    }
    if ((jsonDecode(jsonEncode({'PositionTicks': item.resumeTicks}))
            as Map)['PositionTicks'] !=
        expected) {
      throw StateError('Serialized playback position was corrupted');
    }
    if (ticks == 18000000000 && (item.progress - .6).abs() > .00001) {
      throw StateError('Continue Watching progress was corrupted');
    }
  }
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
      if (next >= bitrate) throw StateError('Auto raised quality');
      bitrate = next;
    }
  }
  if (bitrate != 2000000) {
    throw StateError('Auto did not hold its stable floor');
  }
  // ignore: avoid_print -- command-line verification receipt.
  print('Web core resume, timeline and downward-only quality fixtures passed');
}
