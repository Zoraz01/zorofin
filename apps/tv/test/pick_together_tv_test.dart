import 'package:flutter_test/flutter_test.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/pick_together.dart';
import 'package:zorofin_tv/core/trailer_previews.dart';

void main() {
  final session = {
    'schemaVersion': 1,
    'id': 'a' * 32,
    'code': 'abc def',
    'kind': 'movie',
    'status': 'lobby',
    'version': 3,
    'host': true,
    'seat': 'tv1',
    'members': [
      {'seat': 'tv1', 'name': 'Living Room', 'display': true, 'host': true},
      {'seat': 'p1', 'name': 'Alex', 'swiped': 4, 'total': 20},
      {'seat': 'p2', 'name': '', 'done': true},
      {'seat': 'bad seat!', 'name': 'Ignored'},
    ],
    'matches': [
      {
        'itemId': 'abc-123',
        'title': 'Fargo',
        'year': 1996,
        'likes': 2,
        'of': 2,
        'imageTag': 't',
      },
      {'itemId': 'not hex', 'title': 'Rejected'},
    ],
  };

  test(
    'a TV session reads voters, seats and matches, never counting the display',
    () {
      final view = PickTogetherSession.fromJson(session)!;
      expect(view.code, 'ABCDEF');
      expect(view.voters, 2);
      expect(view.canStart, isTrue);
      expect(view.members.map((m) => m.seat), ['tv1', 'p1', 'p2']);
      expect(view.members[2].name, 'Guest');
      expect(view.matches.single.tally, '2 of 2');
      expect(view.matches.single.itemJson['ImageTags'], {'Primary': 't'});
      final bridge = view.toBridge((c) => {'id': c.itemId});
      expect(
        (bridge['members'] as List).length,
        2,
        reason: 'the TV is not listed as a voter',
      );
    },
  );

  test('Start waits for two voters and only the host may start', () {
    final one = {
      ...session,
      'members': (session['members'] as List).take(2).toList(),
    };
    expect(PickTogetherSession.fromJson(one)!.canStart, isFalse);
    expect(
      PickTogetherSession.fromJson({...session, 'host': false})!.canStart,
      isFalse,
    );
  });

  test('malformed sessions and codes are rejected', () {
    expect(
      PickTogetherSession.fromJson({...session, 'schemaVersion': 2}),
      isNull,
    );
    expect(PickTogetherSession.fromJson({...session, 'id': 'short'}), isNull);
    expect(pickTogetherCode('ABC12I'), isNull);
    expect(pickTogetherCode(' xyz 234 '), 'XYZ234');
  });

  test('trailer previews only direct-play compatible files', () {
    MediaSource source(
      String container,
      String video,
      int height,
      String audio,
    ) => MediaSource.fromJson({
      'Container': container,
      'MediaStreams': [
        {'Index': 0, 'Type': 'Video', 'Codec': video, 'Height': height},
        {'Index': 1, 'Type': 'Audio', 'Codec': audio},
      ],
    });
    expect(
      trailerPreviewCompatible(source('mp4', 'h264', 1080, 'aac')),
      isTrue,
    );
    expect(
      trailerPreviewCompatible(source('mov,mp4,m4a', 'hevc', 720, 'eac3')),
      isTrue,
    );
    expect(
      trailerPreviewCompatible(
        source('mp4', 'hevc', 720, 'aac'),
        allowHevc: false,
      ),
      isFalse,
    );
    expect(
      trailerPreviewCompatible(source('mkv', 'h264', 1080, 'aac')),
      isFalse,
    );
    expect(
      trailerPreviewCompatible(source('mp4', 'h264', 2160, 'aac')),
      isFalse,
    );
    expect(
      trailerPreviewCompatible(source('mp4', 'h264', 1080, 'dts')),
      isFalse,
    );
  });
}
