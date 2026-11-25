import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;

import '../../core/catalog.dart';
import '../../core/models.dart';
import '../../core/server_address.dart';
import '../../core/pick_together.dart';
import '../theme.dart';
import '../widgets/focusable.dart';
import '../widgets/media_card.dart' show Artwork;

/// Pick Together, matching the Apple apps. On a TV ([display]) the screen
/// hosts the group and shows the code, who joined, swipe progress and the
/// matches; it never votes. On a phone it joins by code or starts a group,
/// then swipes the round's titles. Polls about every two seconds only while
/// this screen is showing and the app is in front.
class PickTogetherScreen extends StatefulWidget {
  const PickTogetherScreen({
    super.key,
    required this.catalog,
    required this.display,
    required this.onOpen,
    required this.onPlay,
  });

  final JellyfinCatalog catalog;
  final bool display;
  final ValueChanged<MediaItem> onOpen;
  final ValueChanged<MediaItem> onPlay;

  /// One group per account and role, kept while the app runs so leaving the
  /// screen doesn't end the group on everyone's phones.
  static final _controllers = <String, PickTogetherController>{};

  static PickTogetherController controllerFor(
    JellyfinCatalog catalog, {
    required bool display,
  }) {
    final session = catalog.client.session;
    final key = '${session?.server.url}\n${session?.viewer.id}\n$display';
    final existing = _controllers[key];
    if (existing != null && existing.client == catalog.client) return existing;
    return _controllers[key] = PickTogetherController(
      catalog.client,
      display: display,
    );
  }

  @override
  State<PickTogetherScreen> createState() => _PickTogetherScreenState();
}

class _PickTogetherScreenState extends State<PickTogetherScreen>
    with WidgetsBindingObserver {
  late PickTogetherController _pick = PickTogetherScreen.controllerFor(
    widget.catalog,
    display: widget.display,
  );
  Timer? _timer;
  bool _polling = false;
  String? _selected;
  final _code = TextEditingController();

  bool get _tv => widget.display;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pick.absorbMatches();
    _schedule(immediately: true);
  }

  @override
  void didUpdateWidget(PickTogetherScreen old) {
    super.didUpdateWidget(old);
    if (old.catalog != widget.catalog || old.display != widget.display) {
      _pick = PickTogetherScreen.controllerFor(
        widget.catalog,
        display: widget.display,
      );
      _schedule(immediately: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _code.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _schedule(immediately: true);
    } else {
      _timer?.cancel();
    }
  }

  void _schedule({bool immediately = false}) {
    _timer?.cancel();
    final s = _pick.session;
    if (!mounted || s == null || s.status == 'ended' || s.status == 'failed') {
      return;
    }
    _timer = Timer(
      immediately ? Duration.zero : const Duration(seconds: 2),
      _poll,
    );
  }

  Future<void> _poll() async {
    if (!mounted || _polling) return;
    _polling = true;
    final before = _pick.session?.matches.map((c) => c.itemId).toSet() ?? {};
    await _pick.refresh();
    _polling = false;
    if (!mounted) return;
    // A match that arrived while this phone waited: one moment per title.
    if (!_tv) {
      for (final card in _pick.session?.matches ?? const <PickTogetherCard>[]) {
        if (!before.contains(card.itemId)) _celebrate(_pick.celebrate(card));
      }
    }
    setState(() {});
    _schedule();
  }

  Future<void> _act(Future<void> Function() action) async {
    setState(() {});
    await action();
    if (!mounted) return;
    _pick.absorbMatches();
    setState(() {});
    _schedule(immediately: true);
  }

  void _celebrate(PickTogetherCard? card) {
    if (card == null || !mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        duration: const Duration(milliseconds: 2500),
        content: Text('It’s a match: ${card.title}'),
      ),
    );
  }

  MediaItem _item(PickTogetherCard card) => MediaItem.fromJson(card.itemJson);

  Future<void> _play(PickTogetherCard card) async {
    final item = _item(card);
    if (card.type == 'Series') return widget.onOpen(item);
    try {
      widget.onPlay(await widget.catalog.item(card.itemId));
    } catch (_) {
      widget.onPlay(item);
    }
  }

  String _kindLabel(String kind) => kind == 'series' ? 'Shows' : 'Movies';
  String _spaced(String code) =>
      code.length == 6 ? '${code.substring(0, 3)} ${code.substring(3)}' : code;

  String _title(PickTogetherSession s) {
    final voters = s.voterMembers;
    switch (s.status) {
      case 'swiping':
        return voters.isNotEmpty && voters.every((m) => m.done)
            ? 'Everyone’s done'
            : 'Swiping…';
      case 'empty':
        return 'Out of titles';
      case 'ended':
        return 'Session ended';
      case 'failed':
        return 'Couldn’t find titles';
      default:
        return 'Getting ready…';
    }
  }

  // ── Shared pieces ───────────────────────────────────────────────────────

  Widget _button(
    String label,
    VoidCallback? onPressed, {
    bool primary = false,
    bool autofocus = false,
    IconData? icon,
  }) {
    final enabled = onPressed != null && !_pick.busy;
    if (_tv) {
      return Opacity(
        opacity: enabled ? 1 : .45,
        child: ZoroButton(
          label: label,
          icon: icon,
          primary: primary,
          autofocus: autofocus,
          onPressed: enabled ? onPressed : () {},
        ),
      );
    }
    final style = primary
        ? FilledButton.styleFrom(
            backgroundColor: Zoro.play,
            foregroundColor: Zoro.background,
            minimumSize: const Size(0, 48),
          )
        : OutlinedButton.styleFrom(
            foregroundColor: Zoro.text,
            side: const BorderSide(color: Zoro.border),
            minimumSize: const Size(0, 48),
          );
    final child = icon == null
        ? Text(label)
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 8),
              Text(label),
            ],
          );
    return primary
        ? FilledButton(
            onPressed: enabled ? onPressed : null,
            style: style,
            child: child,
          )
        : OutlinedButton(
            onPressed: enabled ? onPressed : null,
            style: style,
            child: child,
          );
  }

  Widget _poster(PickTogetherCard card, double width) => ClipRRect(
    borderRadius: BorderRadius.circular(_tv ? 14 : 12),
    child: SizedBox(
      width: width,
      child: AspectRatio(
        aspectRatio: 2 / 3,
        child: Artwork(
          url: widget.catalog.artwork(
            _item(card),
            landscape: false,
            width: 420,
          ),
          headers: widget.catalog.imageHeaders,
          title: card.title,
          seed: card.itemId,
        ),
      ),
    ),
  );

  String _meta(PickTogetherCard c) => [
    if (c.year != null) '${c.year}',
    if (c.officialRating != null) c.officialRating!,
    if (c.type == 'Series' && (c.seasons ?? 0) > 0)
      c.seasons == 1 ? '1 season' : '${c.seasons} seasons'
    else if ((c.runtimeMinutes ?? 0) > 0)
      c.runtimeMinutes! >= 60
          ? '${c.runtimeMinutes! ~/ 60}h ${c.runtimeMinutes! % 60}m'
          : '${c.runtimeMinutes}m',
  ].join(' · ');

  Widget _error() => _pick.error == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            _pick.error!,
            style: Zoro.font(_tv ? 22 : 15, color: Zoro.muted),
          ),
        );

  // ── Screens ─────────────────────────────────────────────────────────────

  Widget _start() {
    final kinds = [
      for (final kind in const ['movie', 'series'])
        _tv
            ? Focusable(
                autofocus: kind == 'movie',
                semanticLabel:
                    'Pick ${_kindLabel(kind).toLowerCase()} together',
                onPressed: () => _act(() => _pick.create(kind)),
                builder: (context, focused) => AnimatedContainer(
                  duration: Zoro.focusDuration,
                  width: 340,
                  height: 230,
                  decoration: BoxDecoration(
                    color: Zoro.panel,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: focused ? Colors.white : Zoro.border,
                      width: focused ? 3 : 1,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        kind == 'movie'
                            ? Icons.movie_rounded
                            : Icons.tv_rounded,
                        size: 64,
                        color: Zoro.jade,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _kindLabel(kind),
                        style: Zoro.font(34, weight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              )
            : Expanded(
                child: _button(
                  _kindLabel(kind),
                  () => _act(() => _pick.create(kind)),
                  icon: kind == 'movie'
                      ? Icons.movie_rounded
                      : Icons.tv_rounded,
                ),
              ),
    ];
    if (_tv) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Pick Together',
            style: Zoro.font(26, weight: FontWeight.w600, color: Zoro.jade),
          ),
          const SizedBox(height: 12),
          Text(
            'What are we watching?',
            style: Zoro.font(64, weight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: 1100,
            child: Text(
              'Everyone swipes on their own phone. Matches show up here, and Play starts the pick on this TV.',
              textAlign: TextAlign.center,
              style: Zoro.font(28, color: Zoro.muted),
            ),
          ),
          const SizedBox(height: 40),
          FocusTraversalGroup(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [kinds[0], const SizedBox(width: 48), kinds[1]],
            ),
          ),
          if (_pick.busy)
            const Padding(
              padding: EdgeInsets.only(top: 24),
              child: CircularProgressIndicator(),
            ),
          _error(),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Pick together', style: Zoro.font(28, weight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(
          'Swipe the same short list with friends and see what everyone likes.',
          style: Zoro.font(15, color: Zoro.muted),
        ),
        const SizedBox(height: 24),
        Text('Join a group', style: Zoro.font(17, weight: FontWeight.w600)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('pick-code'),
                controller: _code,
                textCapitalization: TextCapitalization.characters,
                autocorrect: false,
                maxLength: 7,
                style: Zoro.font(20, weight: FontWeight.w700),
                decoration: const InputDecoration(
                  hintText: 'Six-character code',
                  counterText: '',
                ),
                onSubmitted: (v) => _act(() => _pick.join(v)),
              ),
            ),
            const SizedBox(width: 12),
            _button(
              'Join',
              () => _act(() => _pick.join(_code.text)),
              primary: true,
            ),
          ],
        ),
        const SizedBox(height: 28),
        Text('Or start one', style: Zoro.font(17, weight: FontWeight.w600)),
        const SizedBox(height: 8),
        Row(children: [kinds[0], const SizedBox(width: 12), kinds[1]]),
        if (_pick.busy)
          const Padding(
            padding: EdgeInsets.only(top: 20),
            child: Center(child: CircularProgressIndicator()),
          ),
        _error(),
      ],
    );
  }

  Widget _members(PickTogetherSession s, {bool progress = false}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Joined · ${s.voters}',
        style: Zoro.font(_tv ? 24 : 15, color: Zoro.muted),
      ),
      const SizedBox(height: 10),
      if (s.voterMembers.isEmpty)
        Text(
          'Waiting for the first phone…',
          style: Zoro.font(_tv ? 26 : 16, color: Zoro.muted),
        ),
      for (final m in s.voterMembers)
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: EdgeInsets.symmetric(
            horizontal: _tv ? 20 : 14,
            vertical: _tv ? 18 : 12,
          ),
          decoration: BoxDecoration(
            color: Zoro.panel,
            borderRadius: BorderRadius.circular(_tv ? 16 : 12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      m.you ? '${m.name} (you)' : m.name,
                      overflow: TextOverflow.ellipsis,
                      style: Zoro.font(_tv ? 28 : 17, weight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    progress
                        ? '${m.swiped}/${m.total}${m.done ? ' · done' : ''}'
                        : (m.host ? 'Host' : 'Ready'),
                    style: Zoro.font(
                      _tv ? 22 : 14,
                      color: m.host && !progress ? Zoro.jade : Zoro.muted,
                    ),
                  ),
                ],
              ),
              if (progress) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: m.total > 0
                        ? (m.swiped / m.total).clamp(0.0, 1.0)
                        : 0,
                    minHeight: 6,
                    color: Zoro.jade,
                    backgroundColor: Zoro.border,
                  ),
                ),
              ],
            ],
          ),
        ),
    ],
  );

  Widget _lobby(PickTogetherSession s) {
    final canStart = s.canStart && s.status == 'lobby';
    final actions = [
      if (s.host)
        _button(
          'Start swiping',
          canStart ? () => _act(() => _pick.host('start')) : null,
          primary: true,
          autofocus: _tv,
        ),
      _button(s.host ? 'Cancel' : 'Leave', () async {
        await _pick.leave();
        if (mounted) setState(() {});
        if (_tv && mounted) Navigator.of(context).maybePop();
      }),
    ];
    final hint = s.voters < 2
        ? 'Start unlocks when two people have joined.${_tv ? ' The TV never swipes.' : ''}'
        : s.host
        ? 'Start when everyone’s in.'
        : 'Waiting for the host to start.';
    final code = Text(
      _spaced(s.code),
      semanticsLabel: 'Code ${s.code.split('').join(' ')}',
      style: Zoro.font(
        _tv ? 88 : 44,
        weight: FontWeight.w800,
      ).copyWith(letterSpacing: _tv ? 8 : 4),
    );
    if (_tv) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 860,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Pick Together · ${_kindLabel(s.kind)}',
                  style: Zoro.font(24, color: Zoro.muted),
                ),
                const SizedBox(height: 12),
                Text(
                  'Grab your phones.',
                  style: Zoro.font(64, weight: FontWeight.w700),
                ),
                const SizedBox(height: 16),
                Text(
                  'Open Zorofin on your phone, go to Pick together and type the code. Everyone swipes on their own phone, and matches show up here.',
                  style: Zoro.font(28, color: Zoro.muted),
                ),
                const SizedBox(height: 32),
                Text('Group code', style: Zoro.font(24, color: Zoro.muted)),
                Row(
                  children: [
                    _JoinQr(server: widget.catalog.client.server, code: s.code),
                    Flexible(child: code),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 80),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _members(s),
                if (s.status == 'preparing')
                  Text(
                    'Finding titles for everyone…',
                    style: Zoro.font(24, color: Zoro.muted),
                  ),
                const SizedBox(height: 20),
                FocusTraversalGroup(
                  child: Row(
                    children: [
                      for (final a in actions)
                        Padding(
                          padding: const EdgeInsets.only(right: 20),
                          child: a,
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(hint, style: Zoro.font(20, color: Zoro.muted)),
                _error(),
              ],
            ),
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Pick Together · ${_kindLabel(s.kind)}',
          style: Zoro.font(15, color: Zoro.muted),
        ),
        const SizedBox(height: 8),
        Text('Group code', style: Zoro.font(15, color: Zoro.muted)),
        code,
        const SizedBox(height: 6),
        Text(
          'Friends join from Pick together with this code.',
          style: Zoro.font(15, color: Zoro.muted),
        ),
        const SizedBox(height: 20),
        _members(s),
        if (s.status == 'preparing')
          Text(
            'Finding titles for everyone…',
            style: Zoro.font(15, color: Zoro.muted),
          ),
        const SizedBox(height: 16),
        Wrap(spacing: 12, runSpacing: 12, children: actions),
        const SizedBox(height: 10),
        Text(hint, style: Zoro.font(14, color: Zoro.muted)),
        _error(),
      ],
    );
  }

  Widget _matches(PickTogetherSession s) {
    final cards = [
      for (final c in s.matches)
        Padding(
          padding: EdgeInsets.only(right: _tv ? 32 : 14),
          child: _tv
              ? Focusable(
                  autofocus: c.itemId == (_selected ?? s.matches.first.itemId),
                  semanticLabel: '${c.title}, ${c.tally ?? ''} liked',
                  onFocus: () => setState(() => _selected = c.itemId),
                  onPressed: () => _play(c),
                  builder: (context, focused) => AnimatedScale(
                    scale: Zoro.lift(context, focused, 1.05),
                    duration: Zoro.focusDuration,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: focused
                                  ? Colors.white
                                  : Colors.transparent,
                              width: 3,
                            ),
                          ),
                          child: _poster(c, 230),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: 230,
                          child: Text(
                            c.title,
                            overflow: TextOverflow.ellipsis,
                            style: Zoro.font(22, weight: FontWeight.w600),
                          ),
                        ),
                        Text(
                          [c.tally, _meta(c)]
                              .whereType<String>()
                              .where((t) => t.isNotEmpty)
                              .join(' · '),
                          style: Zoro.font(18, color: Zoro.muted),
                        ),
                      ],
                    ),
                  ),
                )
              : InkWell(
                  onTap: () => widget.onOpen(_item(c)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _poster(c, 130),
                      const SizedBox(height: 6),
                      SizedBox(
                        width: 130,
                        child: Text(
                          c.title,
                          overflow: TextOverflow.ellipsis,
                          style: Zoro.font(14, weight: FontWeight.w600),
                        ),
                      ),
                      Text(
                        c.tally ?? '',
                        style: Zoro.font(12, color: Zoro.muted),
                      ),
                    ],
                  ),
                ),
        ),
      for (final c in s.almost)
        Container(
          width: _tv ? 230 : 130,
          height: _tv ? 345 : 195,
          margin: EdgeInsets.only(right: _tv ? 32 : 14),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Zoro.border, width: 2),
          ),
          alignment: Alignment.center,
          child: Text(
            'Almost: ${c.title}\n${c.tally ?? ''}',
            textAlign: TextAlign.center,
            style: Zoro.font(_tv ? 20 : 13, color: Zoro.muted),
          ),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          s.matches.isEmpty
              ? 'Matches show up here when everyone likes the same title'
              : 'Matches · everyone liked',
          style: Zoro.font(
            _tv ? 24 : 15,
            weight: FontWeight.w600,
            color: Zoro.jade,
          ),
        ),
        SizedBox(height: _tv ? 16 : 10),
        if (cards.isNotEmpty)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            child: FocusTraversalGroup(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: cards,
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _resultActions(PickTogetherSession s) {
    final chosen =
        s.matches.where((c) => c.itemId == _selected).firstOrNull ??
        s.matches.firstOrNull;
    final over = s.status == 'ended' || s.status == 'failed';
    return [
      if (chosen != null && _tv)
        _button('Play ${chosen.title}', () => _play(chosen), primary: true),
      if (s.host)
        _button(
          'Another round',
          (s.status == 'swiping' || s.status == 'empty')
              ? () => _act(() => _pick.host('next-round'))
              : null,
        ),
      _button(over ? 'Done' : (s.host ? 'End' : 'Leave'), () async {
        if (!over) await _pick.leave();
        _pick.reset();
        if (mounted) setState(() {});
      }),
    ];
  }

  Widget _tvLive(PickTogetherSession s) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Pick Together · ${_kindLabel(s.kind)} · code ${_spaced(s.code)}',
        style: Zoro.font(22, color: Zoro.muted),
      ),
      Text(_title(s), style: Zoro.font(54, weight: FontWeight.w700)),
      const SizedBox(height: 16),
      Wrap(
        spacing: 28,
        runSpacing: 12,
        children: [
          for (final m in s.voterMembers)
            SizedBox(
              width: 220,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${m.name} · ${m.swiped}/${m.total}${m.done ? ' · done' : ''}',
                    overflow: TextOverflow.ellipsis,
                    style: Zoro.font(20),
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: m.total > 0
                          ? (m.swiped / m.total).clamp(0.0, 1.0)
                          : 0,
                      minHeight: 7,
                      color: Zoro.jade,
                      backgroundColor: Zoro.border,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      const SizedBox(height: 28),
      _matches(s),
      const SizedBox(height: 28),
      FocusTraversalGroup(
        child: Row(
          children: [
            for (final a in _resultActions(s))
              Padding(padding: const EdgeInsets.only(right: 20), child: a),
          ],
        ),
      ),
      _error(),
    ],
  );

  Widget _phoneLive(PickTogetherSession s) {
    final card = _pick.deck.firstOrNull;
    final me = s.me;
    final swiping = s.status == 'swiping' && card != null;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Pick Together · ${_kindLabel(s.kind)} · ${_spaced(s.code)}',
          style: Zoro.font(14, color: Zoro.muted),
        ),
        const SizedBox(height: 4),
        Text(
          swiping ? 'Swipe right to like, left to skip' : _title(s),
          style: Zoro.font(22, weight: FontWeight.w700),
        ),
        if (me != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${me.swiped} of ${me.total} swiped',
              style: Zoro.font(14, color: Zoro.muted),
            ),
          ),
        const SizedBox(height: 16),
        if (swiping) ...[
          Dismissible(
            key: ValueKey('pick-card-${s.round}-${card.itemId}'),
            direction: _pick.busy
                ? DismissDirection.none
                : DismissDirection.horizontal,
            onDismissed: (direction) =>
                _swipe(card, like: direction == DismissDirection.startToEnd),
            background: _swipeHint('LIKE', Alignment.centerLeft, Zoro.jade),
            secondaryBackground: _swipeHint(
              'SKIP',
              Alignment.centerRight,
              Zoro.text,
            ),
            child: Column(
              children: [
                Center(child: _poster(card, 260)),
                const SizedBox(height: 12),
                Text(
                  card.title,
                  textAlign: TextAlign.center,
                  style: Zoro.font(22, weight: FontWeight.w700),
                ),
                Text(
                  _meta(card),
                  textAlign: TextAlign.center,
                  style: Zoro.font(14, color: Zoro.muted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _button(
                'Skip',
                () => _swipe(card, like: false),
                icon: Icons.close_rounded,
              ),
              const SizedBox(width: 24),
              _button(
                'Like',
                () => _swipe(card, like: true),
                primary: true,
                icon: Icons.favorite_rounded,
              ),
            ],
          ),
        ] else if (s.status == 'swiping')
          Text(
            'You’re done. Waiting for everyone else…',
            style: Zoro.font(16, color: Zoro.muted),
          ),
        const SizedBox(height: 24),
        _matches(s),
        const SizedBox(height: 20),
        Wrap(spacing: 12, runSpacing: 12, children: _resultActions(s)),
        _error(),
      ],
    );
  }

  Widget _swipeHint(String text, Alignment alignment, Color color) => Container(
    alignment: alignment,
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: Text(
      text,
      style: Zoro.font(26, weight: FontWeight.w800, color: color),
    ),
  );

  Future<void> _swipe(PickTogetherCard card, {required bool like}) async {
    setState(() {});
    final match = await _pick.swipe(card, like: like);
    if (!mounted) return;
    _celebrate(match);
    setState(() {});
    if (_pick.deck.isEmpty) _schedule(immediately: true);
  }

  @override
  Widget build(BuildContext context) {
    final s = _pick.session;
    final body = s == null
        ? _start()
        : (s.status == 'lobby' || s.status == 'preparing')
        ? _lobby(s)
        : _tv
        ? _tvLive(s)
        : _phoneLive(s);
    if (_tv) {
      return Scaffold(
        backgroundColor: Zoro.background,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(96, 60, 96, 40),
          child: FocusTraversalGroup(child: body),
        ),
      );
    }
    return body;
  }
}

class _JoinQr extends StatelessWidget {
  const _JoinQr({required this.server, required this.code});
  final ServerAddress server;
  final String code;

  @override
  Widget build(BuildContext context) {
    final matrix = pickInviteMatrix(server, code);
    if (matrix == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 24),
      child: Semantics(
        label: 'Scan to join Pick Together',
        image: true,
        child: CustomPaint(
          size: const Size.square(196),
          painter: _QrPainter(matrix),
        ),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  const _QrPainter(this.matrix);
  final List<String> matrix;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final unit = size.shortestSide / (matrix.length + 8);
    final ink = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    for (var row = 0; row < matrix.length; row++) {
      for (var col = 0; col < matrix.length; col++) {
        if (matrix[row][col] == '1') {
          canvas.drawRect(
            Rect.fromLTWH((col + 4) * unit, (row + 4) * unit, unit, unit),
            ink,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => !listEquals(old.matrix, matrix);
}
