// Pick Together (schemaVersion 1) for TVs. Several people swipe the same short
// list of titles on their phones; a TV hosts with `display: true`, shows the
// code, progress and matches, and never votes or fetches a deck.
// Contract: docs/handoffs/PICK_TOGETHER_CLIENT_PLAN_1_4.md and the Apple
// client in apps/apple/Core/Sources/ZorofinCore/PickTogether.swift.

import 'package:qr/qr.dart';

import 'server_address.dart';
import 'errors.dart';
import 'jellyfin_client.dart';

const _root = ['Zorofin', 'Companion', 'pickTogether'];
const _codeAlphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

bool _validSession(String id) =>
    id.length == 32 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(id);
bool _validSeat(String id) =>
    id.isNotEmpty && id.length <= 64 && RegExp(r'^[A-Za-z0-9]+$').hasMatch(id);
bool _validItem(String id) =>
    id.isNotEmpty && id.length <= 64 && RegExp(r'^[0-9a-fA-F-]+$').hasMatch(id);

/// Six characters from the server's alphabet, or null.
String? pickTogetherCode(String text) {
  final code = text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  if (code.length != 6 ||
      code.split('').any((c) => !_codeAlphabet.contains(c))) {
    return null;
  }
  return code;
}

/// Encodes only the server's public join link. The manual code remains usable
/// for long proxy paths that would produce an unreadably dense TV image.
List<String>? pickInviteMatrix(ServerAddress server, String rawCode) {
  final code = pickTogetherCode(rawCode);
  if (code == null) return null;
  final url = server.url
      .resolve('web/')
      .replace(fragment: '/home?zorofin=catchup&pick=$code')
      .toString();
  if (url.length > 192) return null;
  final qr = QrImage(
    QrCode.fromData(data: url, errorCorrectLevel: QrErrorCorrectLevel.M),
  );
  return List.generate(
    qr.moduleCount,
    (y) => List.generate(
      qr.moduleCount,
      (x) => qr.isDark(y, x) ? '1' : '0',
    ).join(),
  );
}

class PickTogetherCard {
  const PickTogetherCard({
    required this.itemId,
    required this.type,
    required this.title,
    this.year,
    this.runtimeMinutes,
    this.officialRating,
    this.communityRating,
    this.seasons,
    this.imageTag,
    this.likes,
    this.of,
  });

  static PickTogetherCard? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['itemId'], title = json['title'];
    if (id is! String || !_validItem(id) || title is! String || title.isEmpty) {
      return null;
    }
    int? number(String key) => (json[key] as num?)?.toInt();
    String? text(String key) {
      final value = json[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    return PickTogetherCard(
      itemId: id,
      type: text('type') == 'Series' ? 'Series' : 'Movie',
      title: title.length > 300 ? title.substring(0, 300) : title,
      year: number('year'),
      runtimeMinutes: number('runtimeMinutes'),
      officialRating: text('officialRating'),
      communityRating: (json['communityRating'] as num?)?.toDouble(),
      seasons: number('seasons'),
      imageTag: text('imageTag'),
      likes: number('likes'),
      of: number('of'),
    );
  }

  final String itemId, type, title;
  final int? year, runtimeMinutes, seasons, likes, of;
  final String? officialRating, imageTag;
  final double? communityRating;

  /// "3 of 3".
  String? get tally => likes != null && of != null ? '$likes of $of' : null;

  /// Jellyfin item JSON for the ordinary catalog and player paths.
  Map<String, dynamic> get itemJson => {
    'Id': itemId,
    'Name': title,
    'Type': type,
    'ProductionYear': ?year,
    'OfficialRating': ?officialRating,
    'CommunityRating': ?communityRating,
    if (runtimeMinutes != null) 'RunTimeTicks': runtimeMinutes! * 600000000,
    if (imageTag != null) 'ImageTags': {'Primary': imageTag},
  };
}

class PickTogetherMember {
  const PickTogetherMember({
    required this.seat,
    required this.name,
    this.display = false,
    this.host = false,
    this.swiped = 0,
    this.total = 0,
    this.done = false,
    this.you = false,
  });
  final String seat, name;
  final bool display, host, done, you;
  final int swiped, total;
}

class PickTogetherSession {
  const PickTogetherSession({
    required this.id,
    required this.code,
    required this.kind,
    required this.status,
    required this.round,
    required this.version,
    required this.host,
    required this.seat,
    required this.members,
    required this.voters,
    required this.matches,
    required this.almost,
    this.display = false,
  });

  static PickTogetherSession? fromJson(Object? json) {
    if (json is! Map || json['schemaVersion'] != 1) return null;
    final id = json['id'], kind = json['kind'], version = json['version'];
    final code = json['code'] is String ? pickTogetherCode(json['code']) : null;
    if (id is! String ||
        !_validSession(id) ||
        code == null ||
        (kind != 'movie' && kind != 'series') ||
        version is! int) {
      return null;
    }
    final members = <PickTogetherMember>[
      for (final m in (json['members'] as List? ?? const []).take(12))
        if (m is Map && m['seat'] is String && _validSeat(m['seat']))
          PickTogetherMember(
            seat: m['seat'],
            name: (m['name'] is String && (m['name'] as String).isNotEmpty)
                ? (m['name'] as String).length > 40
                      ? (m['name'] as String).substring(0, 40)
                      : m['name']
                : 'Guest',
            display: m['display'] == true,
            host: m['host'] == true,
            swiped: ((m['swiped'] as num?)?.toInt() ?? 0).clamp(0, 1000),
            total: ((m['total'] as num?)?.toInt() ?? 0).clamp(0, 1000),
            done: m['done'] == true,
            you: m['you'] == true,
          ),
    ];
    const statuses = {
      'lobby',
      'preparing',
      'swiping',
      'empty',
      'ended',
      'failed',
    };
    final seat = json['seat'];
    return PickTogetherSession(
      id: id,
      code: code,
      kind: kind as String,
      status: statuses.contains(json['status']) ? json['status'] : 'unknown',
      round: ((json['round'] as num?)?.toInt() ?? 0).clamp(0, 1000),
      version: version,
      host: json['host'] == true,
      display: json['display'] == true,
      seat: seat is String && _validSeat(seat) ? seat : null,
      members: members,
      voters:
          (json['voters'] as num?)?.toInt() ??
          members.where((m) => !m.display).length,
      matches: [
        for (final c in json['matches'] as List? ?? const [])
          ?PickTogetherCard.fromJson(c),
      ],
      almost: [
        for (final c in json['almost'] as List? ?? const [])
          ?PickTogetherCard.fromJson(c),
      ],
    );
  }

  final String id, code, kind, status;
  final int round, version, voters;
  final bool host, display;
  final String? seat;

  /// Voting members only; a TV display is not a voter.
  List<PickTogetherMember> get voterMembers =>
      members.where((m) => !m.display).toList();

  /// This device's member row, when it is a voter.
  PickTogetherMember? get me =>
      members.where((m) => m.seat == seat).firstOrNull;
  final List<PickTogetherMember> members;
  final List<PickTogetherCard> matches, almost;

  /// Same session, keeping this device's seat when another seat of the same
  /// account refreshed it.
  PickTogetherSession withSeat(String? keep) => keep == null || keep == seat
      ? this
      : PickTogetherSession(
          id: id,
          code: code,
          kind: kind,
          status: status,
          round: round,
          version: version,
          host: host,
          seat: keep,
          members: members,
          voters: voters,
          matches: matches,
          almost: almost,
          display: display,
        );

  /// The server only makes a match with two or more voters.
  bool get canStart => host && status == 'lobby' && voters >= 2;

  Map<String, Object?> toBridge(
    Map<String, Object?> Function(PickTogetherCard) card,
  ) => {
    'id': id,
    'code': code,
    'kind': kind,
    'status': status,
    'round': round,
    'version': version,
    'host': host,
    'seat': seat,
    'voters': voters,
    'canStart': canStart,
    'members': [
      for (final m in members)
        if (!m.display)
          {
            'seat': m.seat,
            'name': m.name,
            'host': m.host,
            'swiped': m.swiped,
            'total': m.total,
            'done': m.done,
          },
    ],
    'matches': [for (final c in matches) card(c)],
    'almost': [for (final c in almost) card(c)],
  };
}

/// Short, actionable messages for TV hosts, from the response status.
String pickTogetherMessage(Object error) {
  if (error is ClientError) {
    switch (error.status) {
      case 404:
        return 'This session has ended.';
      case 429:
        return 'The server is busy. Try again in a moment.';
    }
    if (error.kind == ClientErrorKind.forbidden) {
      return 'You’re no longer in this session.';
    }
    if (error.kind == ClientErrorKind.network) {
      return 'Couldn’t reach Pick Together. Check the connection and try again.';
    }
  }
  return 'Couldn’t reach Pick Together. Try again.';
}

/// True when the session is gone for this seat: stop polling.
bool pickTogetherEnded(Object error) =>
    error is ClientError &&
    (error.status == 404 || error.kind == ClientErrorKind.forbidden);

extension PickTogetherClient on JellyfinClient {
  Future<PickTogetherSession> _pickSession(
    List<String> path, {
    Map<String, String> query = const {},
    String method = 'GET',
    Object? body,
  }) async {
    final json = await requestJson(
      [..._root, ...path],
      query: query,
      method: method,
      body: body,
      extensionToken: true,
    );
    final view = PickTogetherSession.fromJson(json);
    if (view == null) throw const ClientError(ClientErrorKind.invalidResponse);
    return view;
  }

  List<String> _sessionPath(String id, [String? action]) {
    if (!_validSession(id)) {
      throw const ClientError(ClientErrorKind.unavailable, 404);
    }
    return ['sessions', id, ?action];
  }

  /// A TV creates with `display: true` and never votes; a phone host votes.
  Future<PickTogetherSession> createPickTogether(
    String kind, {
    bool display = true,
  }) {
    if (kind != 'movie' && kind != 'series') {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    return _pickSession(
      ['sessions'],
      method: 'POST',
      body: {'kind': kind, 'display': display},
    );
  }

  /// Joins as a voter with the six-character code.
  Future<PickTogetherSession> joinPickTogether(String code) {
    final normalized = pickTogetherCode(code);
    if (normalized == null) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    return _pickSession(['join'], method: 'POST', body: {'code': normalized});
  }

  /// This seat's cards for the current round. Never called by a display.
  Future<({String status, int round, List<PickTogetherCard> cards})>
  pickTogetherDeck(String id, {String? seat}) async {
    final json = await requestJson(
      [..._root, ..._sessionPath(id, 'deck')],
      query: {if (seat != null && _validSeat(seat)) 'seat': seat},
      extensionToken: true,
    );
    if (json is! Map || json['version'] is! int) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    return (
      status: json['status'] is String ? json['status'] as String : 'unknown',
      round: (json['round'] as num?)?.toInt() ?? 0,
      cards: [
        for (final c in (json['cards'] as List? ?? const []).take(40))
          ?PickTogetherCard.fromJson(c),
      ],
    );
  }

  /// Session swipes only: never taste, played state, favorites or watchlist.
  /// Returns the match this swipe completed, if any.
  Future<PickTogetherCard?> pickTogetherSwipe(
    String id, {
    String? seat,
    required String itemId,
    required bool like,
  }) async {
    final json = await requestJson(
      [..._root, ..._sessionPath(id, 'swipes')],
      method: 'POST',
      body: {
        'itemId': itemId,
        'choice': like ? 'like' : 'skip',
        if (seat != null && _validSeat(seat)) 'seat': seat,
      },
      extensionToken: true,
    );
    if (json is! Map || json['version'] is! int) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    return PickTogetherCard.fromJson(json['match']);
  }

  /// Null means `{unchanged: true}` for [since].
  Future<PickTogetherSession?> pickTogetherState(
    String id, {
    String? seat,
    int? since,
  }) async {
    final json = await requestJson(
      [..._root, ..._sessionPath(id)],
      query: {
        if (seat != null && _validSeat(seat)) 'seat': seat,
        if (since != null) 'since': '$since',
      },
      extensionToken: true,
    );
    if (json is Map && json['unchanged'] == true) return null;
    final view = PickTogetherSession.fromJson(json);
    if (view == null) throw const ClientError(ClientErrorKind.invalidResponse);
    return view;
  }

  /// Host actions: `start`, `next-round`, `end`.
  Future<PickTogetherSession> pickTogetherHost(
    String id,
    String action, {
    String? seat,
  }) {
    if (!const {'start', 'next-round', 'end'}.contains(action)) {
      throw const ClientError(ClientErrorKind.invalidResponse);
    }
    return _pickSession(
      _sessionPath(id, action),
      method: 'POST',
      body: {if (seat != null && _validSeat(seat)) 'seat': seat},
    );
  }

  Future<void> pickTogetherLeave(String id, {String? seat}) async {
    await requestJson(
      [..._root, ..._sessionPath(id, 'leave')],
      method: 'POST',
      body: {if (seat != null && _validSeat(seat)) 'seat': seat},
      extensionToken: true,
    );
  }
}

/// One device's view of its Pick Together group: polling every two seconds
/// while a screen is showing it, version ordering, decks for voters and match
/// moments that fire once. TVs host as displays; phones vote.
class PickTogetherController {
  PickTogetherController(this.client, {required this.display});

  final JellyfinClient client;
  final bool display;
  PickTogetherSession? session;
  List<PickTogetherCard> deck = [];
  String? error;
  bool busy = false;
  String? _deckKey;
  final _celebrated = <String>{};

  /// Applies a full view; older versions of the same session are ignored.
  void apply(PickTogetherSession view) {
    final current = session;
    if (current != null && current.id == view.id) {
      if (view.version < current.version) return;
      session = view.withSeat(current.seat);
    } else {
      session = view;
      deck = [];
      _deckKey = null;
      _celebrated.clear();
    }
    error = null;
  }

  void reset() {
    session = null;
    deck = [];
    _deckKey = null;
    error = null;
    _celebrated.clear();
  }

  bool get needsDeck {
    final s = session;
    if (s == null ||
        display ||
        (s.status != 'swiping' && s.status != 'empty')) {
      return false;
    }
    return _deckKey != '${s.round}-${s.status}';
  }

  /// A match moment for [card], once per title per round.
  PickTogetherCard? celebrate(PickTogetherCard? card) {
    final s = session;
    if (card == null || s == null) return null;
    return _celebrated.add('${s.round}-${card.itemId}') ? card : null;
  }

  /// Marks every match already on screen as seen, so polling never replays.
  void absorbMatches() {
    final s = session;
    if (s == null) return;
    for (final c in s.matches) {
      _celebrated.add('${s.round}-${c.itemId}');
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    busy = true;
    try {
      await action();
    } on ClientError catch (e) {
      if (pickTogetherEnded(e)) reset();
      error = pickTogetherMessage(e);
      if (e.kind == ClientErrorKind.missingSession) rethrow;
    } finally {
      busy = false;
    }
  }

  Future<void> create(String kind) => _run(() async {
    apply(await client.createPickTogether(kind, display: display));
  });

  Future<void> join(String code) => _run(() async {
    if (pickTogetherCode(code) == null) {
      error = 'Enter the six-character code.';
      return;
    }
    apply(await client.joinPickTogether(code));
  });

  Future<void> host(String action) => _run(() async {
    final s = session;
    if (s == null) return;
    apply(await client.pickTogetherHost(s.id, action, seat: s.seat));
  });

  Future<void> leave() async {
    final s = session;
    reset();
    if (s == null) return;
    try {
      if (s.host) {
        await client.pickTogetherHost(s.id, 'end', seat: s.seat);
      } else {
        await client.pickTogetherLeave(s.id, seat: s.seat);
      }
    } catch (_) {
      // The group may already be gone; leaving locally is enough.
    }
  }

  /// One poll: the latest state, then this seat's deck when it changed.
  Future<void> refresh() async {
    final s = session;
    if (s == null || busy) return;
    try {
      final view = await client.pickTogetherState(
        s.id,
        seat: s.seat,
        since: s.version,
      );
      if (session?.id != s.id) return;
      if (view != null) apply(view);
      if (needsDeck) {
        final current = session!;
        final next = await client.pickTogetherDeck(
          current.id,
          seat: current.seat,
        );
        if (session?.id != current.id) return;
        deck = next.cards;
        _deckKey = '${next.round}-${next.status}';
      }
    } on ClientError catch (e) {
      if (pickTogetherEnded(e)) reset();
      error = pickTogetherMessage(e);
    }
  }

  /// Like or skip the top card. Returns a new match to celebrate, if any.
  Future<PickTogetherCard?> swipe(
    PickTogetherCard card, {
    required bool like,
  }) async {
    final s = session;
    if (s == null || busy) return null;
    PickTogetherCard? match;
    await _run(() async {
      match = await client.pickTogetherSwipe(
        s.id,
        seat: s.seat,
        itemId: card.itemId,
        like: like,
      );
      deck = [
        for (final c in deck)
          if (c.itemId != card.itemId) c,
      ];
    });
    return celebrate(match);
  }
}
