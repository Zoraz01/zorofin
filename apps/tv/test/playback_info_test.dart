import 'package:flutter_test/flutter_test.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/ui/player/player_panels.dart';

void main() {
  test('source summary uses the default audio track', () {
    final streams = [
      MediaStream(index: 0, type: 'Video', codec: 'hevc', height: 2160),
      MediaStream(index: 1, type: 'Audio', codec: 'aac', channels: 2),
      MediaStream(
        index: 2,
        type: 'Audio',
        codec: 'eac3',
        channels: 6,
        isDefault: true,
      ),
    ];
    expect(playbackSourceSummary(streams), '2160p · HEVC · EAC3 6 ch');
    expect(playbackSourceSummary(const []), '');
  });
}
