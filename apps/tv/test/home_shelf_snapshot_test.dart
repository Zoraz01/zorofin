import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zorofin_tv/core/home_shelf_snapshot.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/playback.dart';

void main() {
  test('Home snapshots are bounded and isolated to a saved account', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    HomeShelfSnapshot snapshot(String id) => HomeShelfSnapshot(
      id,
      readValue: prefs.getString,
      writeValue: prefs.setString,
      removeValue: prefs.remove,
    );
    final a = snapshot('account-a');
    final b = snapshot('account-b');
    final rows = [
      LibraryShelf.forItems(
        0,
        List.generate(
          18,
          (i) => MediaItem(
            id: 'id-$i',
            name: 'Episode',
            type: 'Episode',
            userData: UserData(playbackPositionTicks: 900),
          ),
        ),
      ),
    ];
    await a.save(rows);
    expect(a.read().single.items.length, 16);
    expect(a.read().single.items.first.resumeTicks, 900);
    expect(b.read(), isEmpty);
    await b.save(rows);
    await a.clear(revoke: true);
    await a.save(rows);
    expect(snapshot('account-a').read(), isEmpty);
    expect(b.read(), isNotEmpty);
    final key = prefs.getKeys().single;
    final saved = jsonDecode(prefs.getString(key)!) as Map;
    saved['at'] = DateTime.now()
        .subtract(const Duration(days: 1))
        .millisecondsSinceEpoch;
    await prefs.setString(key, jsonEncode(saved));
    expect(b.read(), isEmpty);
    await prefs.setString(key, 'corrupt');
    expect(b.read(), isEmpty);
  });

  test(
    'Skip intro is available within the marked range in a known duration',
    () {
      const start = Duration(seconds: 10),
          end = Duration(seconds: 22),
          duration = Duration(minutes: 40);
      const markers = [(start: start, end: end)];
      expect(introEndAt(markers, Duration.zero, duration), isNull);
      expect(introEndAt(markers, start, duration), end);
      expect(introEndAt(markers, end, duration), isNull);
      expect(introEndAt(markers, start, end), isNull);
      expect(introEndAt(markers, start, null), isNull);
    },
  );
}
