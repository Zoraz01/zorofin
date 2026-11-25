import 'package:flutter_test/flutter_test.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/player_extras.dart';
import 'package:zorofin_tv/core/preferences.dart';
import 'package:zorofin_tv/core/server_address.dart';

MediaStream _stream(
  int index,
  String type,
  String? language, {
  bool forced = false,
}) =>
    MediaStream(index: index, type: type, language: language, isForced: forced);

void main() {
  test('chapters are sorted, named and need at least two', () {
    final chapters = Chapter.fromItem({
      'Chapters': [
        {
          'StartPositionTicks': 6000000000,
          'Name': 'The heist',
          'ImageTag': 'b',
        },
        {'StartPositionTicks': 0, 'Name': ''},
      ],
    });
    expect(chapters.map((c) => c.name), ['Chapter 1', 'The heist']);
    expect(chapters[1].start, const Duration(minutes: 10));
    expect(Chapter.indexAt(chapters, const Duration(minutes: 9)), 0);
    expect(Chapter.indexAt(chapters, const Duration(minutes: 10)), 1);
    expect(
      Chapter.fromItem({
        'Chapters': [
          {'StartPositionTicks': 0, 'Name': 'Only'},
        ],
      }),
      isEmpty,
    );
  });

  test('trickplay picks a width and finds the frame in its sheet', () {
    final info = Trickplay.fromItem({
      'Id': 'item',
      'Trickplay': {
        'source': {
          '160': {
            'Width': 160,
            'Height': 90,
            'TileWidth': 10,
            'TileHeight': 10,
            'ThumbnailCount': 500,
            'Interval': 10000,
          },
          '320': {
            'Width': 320,
            'Height': 180,
            'TileWidth': 10,
            'TileHeight': 10,
            'ThumbnailCount': 500,
            'Interval': 10000,
          },
        },
      },
    }, mediaSourceId: 'source')!;
    expect(info.width, 320);
    final frame = info.frameAt(const Duration(seconds: 1234));
    // Frame 123: sheet 1, 23rd on it: row 2, column 3.
    expect((frame.sheet, frame.row, frame.column), (1, 2, 3));
    expect(info.frameAt(const Duration(hours: 9)).sheet, 4);
    final url = info.sheetUrl(
      ServerAddress.parse('https://media.example/jf'),
      'item',
      1,
      mediaSourceId: 'source',
    );
    expect(url.path, '/jf/Videos/item/Trickplay/320/1.jpg');
    expect(url.query.contains('api_key'), isFalse);
    expect(Trickplay.fromItem({'Trickplay': {}}), isNull);
  });

  test('track memory follows the language, forced flag and off', () {
    final streams = [
      _stream(1, 'Audio', 'eng'),
      _stream(2, 'Audio', 'jpn'),
      _stream(3, 'Subtitle', 'eng', forced: true),
      _stream(4, 'Subtitle', 'eng'),
    ];
    var memory = const TrackMemory().choosing(
      audio: streams[1],
      subtitle: streams[3],
    );
    expect(memory.pick(streams), (audio: 2, subtitle: 4));
    memory = TrackMemory.fromJson(memory.toJson());
    expect(memory.pick(streams), (audio: 2, subtitle: 4));
    memory = memory.choosing(off: true);
    expect(memory.pick(streams), (audio: 2, subtitle: -1));
    // Languages this episode lacks leave the default alone.
    expect(memory.pick([_stream(7, 'Audio', 'fra')]), (
      audio: null,
      subtitle: -1,
    ));
  });

  test('timing is clamped, kept and labelled', () {
    final memory = const TrackMemory().withOffsets(
      subtitle: const Duration(seconds: 30),
    );
    expect(memory.subtitleOffset, TrackMemory.maxOffset);
    expect(
      TrackMemory.fromJson(memory.toJson()).subtitleOffset,
      TrackMemory.maxOffset,
    );
    expect(timingLabel(Duration.zero), 'In sync');
    expect(timingLabel(const Duration(milliseconds: -300)), '−0.3 s');
    expect(const TrackMemory().toJson(), isEmpty);
  });

  test('chapters are off until the viewer turns them on', () {
    expect(const DevicePreferences().showChapters, false);
    expect(DevicePreferences.fromJson(const {}).showChapters, false);
    final on = const DevicePreferences().copyWith(showChapters: true);
    expect(DevicePreferences.fromJson(on.toJson()).showChapters, true);
    const trickplay = Trickplay(
      width: 320,
      height: 180,
      tileWidth: 10,
      tileHeight: 10,
      count: 100,
      interval: Duration(seconds: 10),
    );
    const extras = PlayerExtras(
      chapters: [Chapter(start: Duration.zero, name: 'Opening', imageIndex: 0)],
      trickplay: trickplay,
    );
    final hidden = extras.withoutChapters();
    expect(hidden.chapters, isEmpty);
    expect(hidden.trickplay, same(trickplay));
  });
}
