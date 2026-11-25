import 'dart:convert';
import 'models.dart';

/// Only the initial library shelves are cached. Live channels, URLs, tokens,
/// playback sources and optional plugin feeds are always resolved afresh.
class LibraryShelf {
  const LibraryShelf(this.id, this.title, this.items, {this.landscape = false});
  final int id;
  final String title;
  final List<MediaItem> items;
  final bool landscape;

  static const titles = {
    0: 'Continue Watching',
    2: 'Recently Added Movies',
    3: 'Recently Added Shows',
  };
  factory LibraryShelf.forItems(int id, List<MediaItem> items) =>
      LibraryShelf(id, titles[id]!, items, landscape: id == 0);
}

class HomeShelfSnapshot {
  HomeShelfSnapshot(
    this.accountId, {
    required this.readValue,
    required this.writeValue,
    required this.removeValue,
  });
  final String? Function(String) readValue;
  final Future<bool> Function(String, String) writeValue;
  final Future<bool> Function(String) removeValue;
  final String accountId;
  bool _revoked = false;
  String get _key => 'home.shelves.v1.$accountId';

  List<LibraryShelf> read() {
    try {
      if (_revoked) return [];
      final raw = readValue(_key);
      if (raw == null || raw.length > 256000) return [];
      final data = jsonDecode(raw) as Map;
      final age = DateTime.now().millisecondsSinceEpoch - (data['at'] as int);
      if (age < 0 || age > const Duration(hours: 12).inMilliseconds) return [];
      final rows = data['rows'] as Map;
      return [
        for (final id in LibraryShelf.titles.keys)
          if (rows['$id'] case final List items)
            LibraryShelf.forItems(
              id,
              items
                  .take(16)
                  .map((e) => MediaItem.fromJson(e as Map<String, dynamic>))
                  .toList(),
            ),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> save(Iterable<LibraryShelf> shelves) async {
    try {
      if (_revoked) return;
      final rows = {
        for (final row in shelves)
          if (LibraryShelf.titles.containsKey(row.id))
            '${row.id}': [
              for (final item in row.items.take(16))
                {
                  'Id': item.id,
                  'Type': item.type,
                  'Name': item.name,
                  'ProductionYear': ?item.productionYear,
                  'CommunityRating': ?item.communityRating,
                  'SeriesId': ?item.seriesId,
                  'SeriesName': ?item.seriesName,
                  'SeasonId': ?item.seasonId,
                  'IndexNumber': ?item.indexNumber,
                  'ParentIndexNumber': ?item.parentIndexNumber,
                  'ImageTags': item.imageTags,
                  'BackdropImageTags': item.backdropImageTags,
                  'ParentBackdropItemId': ?item.parentBackdropItemId,
                  'ParentBackdropImageTags': item.parentBackdropImageTags,
                  'RunTimeTicks': ?item.runTimeTicks,
                  'UserData': {
                    'PlaybackPositionTicks':
                        ?item.userData?.playbackPositionTicks,
                    'PlayedPercentage': ?item.userData?.playedPercentage,
                    'Played': ?item.userData?.played,
                    'IsFavorite': ?item.userData?.isFavorite,
                  },
                },
            ],
      };
      final raw = jsonEncode({
        'at': DateTime.now().millisecondsSinceEpoch,
        'rows': rows,
      });
      if (raw.length <= 256000) await writeValue(_key, raw);
    } catch (_) {
      // Cache storage is optional.
    }
  }

  Future<void> clear({bool revoke = false}) async {
    if (revoke) _revoked = true;
    try {
      await removeValue(_key);
    } catch (_) {
      // A storage failure must never prevent sign-out.
    }
  }
}
