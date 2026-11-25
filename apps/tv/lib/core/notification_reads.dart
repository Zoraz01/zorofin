import 'jellyfin_client.dart';
import 'server_extras.dart';
import 'errors.dart';

class NotificationReadState {
  const NotificationReadState({
    this.initialized = false,
    this.requests = const {},
    this.replies = const {},
  });
  final bool initialized;
  final Set<int> requests;
  final Set<String> replies;
  factory NotificationReadState.fromJson(Object? value) {
    if (value is! Map ||
        value['initialized'] is! bool ||
        value['requests'] is! List ||
        value['replies'] is! List) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    final requests = value['requests'] as List,
        replies = value['replies'] as List;
    if (requests.length > 2000 ||
        replies.length > 500 ||
        requests.any((v) => v is! int || v <= 0) ||
        replies.any((v) => v is! String || !v.contains('|'))) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    return NotificationReadState(
      initialized: value['initialized'] == true,
      requests: requests.cast<int>().toSet(),
      replies: replies.cast<String>().toSet(),
    );
  }
  NotificationReadState merging(NotificationReadState other) =>
      NotificationReadState(
        initialized: initialized || other.initialized,
        requests: {...requests, ...other.requests},
        replies: {...replies, ...other.replies},
      );
  Map<String, dynamic> toJson() => {
    'initialized': initialized,
    'requests': requests.toList(),
    'replies': replies.toList(),
  };
}

extension AccountReadReply on SupportReply {
  String get accountReadKey => '$id|$updatedAt';
}

extension NotificationReadsClient on JellyfinClient {
  Future<NotificationReadState> notificationReads() async =>
      NotificationReadState.fromJson(
        await requestJson(
          ['Zorofin', 'Notifications', 'Read'],
          extensionToken: true,
          expectedStatus: 200,
        ),
      );
  Future<NotificationReadState> markNotificationReads({
    List<int> requests = const [],
    List<SupportReply> replies = const [],
    bool initialize = false,
  }) async {
    final ids = requests.toSet().toList()..sort();
    if (ids.any((id) => id <= 0)) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    final messages = replies
        .where((r) => !r.isAnnouncement)
        .map((r) => {'id': r.id, 'updatedAt': r.updatedAt})
        .toList();
    final batches = <Map<String, dynamic>>[];
    for (var offset = 0; offset < ids.length; offset += 500) {
      batches.add({
        'requests': ids.skip(offset).take(500).toList(),
        'replies': <Object>[],
      });
    }
    for (var offset = 0; offset < messages.length; offset += 500) {
      batches.add({
        'requests': <int>[],
        'replies': messages.skip(offset).take(500).toList(),
      });
    }
    if (batches.isEmpty) {
      batches.add({'requests': <int>[], 'replies': <Object>[]});
    }
    var state = const NotificationReadState();
    for (final (index, batch) in batches.indexed) {
      final result = await requestJson(
        ['Zorofin', 'Notifications', 'Read'],
        method: 'POST',
        body: {
          ...batch,
          'initialize': initialize && index == batches.length - 1,
        },
        extensionToken: true,
        expectedStatus: 200,
      );
      state = state.merging(NotificationReadState.fromJson(result));
    }
    return state;
  }
}
