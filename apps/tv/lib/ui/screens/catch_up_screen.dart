import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show GestureBinding, VelocityTracker;
import '../../core/catalog.dart';
import '../../core/models.dart';
import '../../core/plugin_extras.dart';
import '../theme.dart';
import '../widgets/focusable.dart';
import '../widgets/media_card.dart' show Artwork;
import 'settings_screen.dart';

/// Web-parity Like/Skip preferences. No played/favorite/watchlist mutation.
class CatchUpScreen extends StatefulWidget {
  const CatchUpScreen({super.key, required this.catalog, required this.skips});
  final Catalog catalog;
  final CatchUpSkips skips;
  @override
  State<CatchUpScreen> createState() => _CatchUpScreenState();
}

class _CatchUpScreenState extends State<CatchUpScreen> {
  CatchUpKind _kind = CatchUpKind.all;
  CatchUpQueue? _queue;
  bool _failed = false, _busy = false, _dragging = false;
  double _drag = 0;
  Offset _touchStart = Offset.zero;
  VelocityTracker? _velocity;
  final _contacts = <int>{};
  int? _dragPointer;
  int _load = 0;
  String? _error;
  (String, int)? _lastSkip;
  final _skip = FocusNode(debugLabel: 'catch-up-skip');
  @override
  void initState() {
    super.initState();
    GestureBinding.instance.pointerRouter.addGlobalRoute(_trackContacts);
    _reload();
  }

  @override
  void didUpdateWidget(CatchUpScreen old) {
    super.didUpdateWidget(old);
    if (old.catalog != widget.catalog || old.skips.key != widget.skips.key) {
      _reload();
    }
  }

  void _trackContacts(PointerEvent event) {
    if (event is PointerDownEvent) {
      _contacts.add(event.pointer);
      if (_contacts.length > 1 && _velocity != null) {
        _velocity = null;
        _dragPointer = null;
        _resetDrag();
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _contacts.remove(event.pointer);
    }
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_trackContacts);
    _load++;
    _skip.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final load = ++_load, catalog = widget.catalog, skips = widget.skips;
    setState(() {
      _queue = null;
      _failed = false;
      _busy = false;
      _dragging = false;
      _drag = 0;
      _contacts.clear();
      _velocity = null;
      _dragPointer = null;
      _error = null;
      _lastSkip = null;
    });
    try {
      final titles =
          await catalog.client?.catchUpTitles(_kind) ?? <MediaItem>[];
      if (!mounted || load != _load) return;
      setState(() => _queue = CatchUpQueue(titles, skips));
      _focusSkip();
    } catch (_) {
      if (mounted && load == _load) setState(() => _failed = true);
    }
  }

  void _focusSkip() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && !CompactSettings.of(context) && _skip.canRequestFocus) {
      _skip.requestFocus();
    }
  });
  Future<void> _act(CatchUpAction action, String id) async {
    final queue = _queue,
        catalog = widget.catalog,
        skips = widget.skips,
        load = _load;
    if (_busy ||
        queue?.current?.id != id ||
        (action != CatchUpAction.skip && action != CatchUpAction.like)) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _dragging = false;
    });
    final moving =
        CompactSettings.of(context) &&
        !MediaQuery.of(context).disableAnimations;
    if (moving) {
      setState(
        () => _drag =
            (action == CatchUpAction.skip ? -1 : 1) *
            MediaQuery.sizeOf(context).width *
            1.3,
      );
    }
    final settled = moving
        ? Future<void>.delayed(const Duration(milliseconds: 190))
        : Future<void>.value();
    try {
      if (action == CatchUpAction.skip) {
        skips.add(id);
      } else {
        final client = catalog.client;
        if (client == null) throw StateError('No signed-in server');
        await client.likeForRecommendations(id);
      }
      await settled;
      if (!mounted ||
          load != _load ||
          !identical(catalog, widget.catalog) ||
          queue?.current?.id != id) {
        return;
      }
      setState(() {
        _lastSkip = action == CatchUpAction.skip ? (id, queue!.index) : null;
        queue!.next();
        _drag = 0;
      });
      final client = catalog.client;
      if (client != null && action == CatchUpAction.skip) {
        unawaited(client.logCatchUp(id, action));
      }
    } catch (_) {
      if (mounted && load == _load) {
        setState(() {
          _error = action == CatchUpAction.skip
              ? 'Couldn’t skip. Try again.'
              : 'Couldn’t save your like. Try again.';
        });
      }
    } finally {
      if (mounted && load == _load) {
        setState(() {
          _busy = false;
          _drag = 0;
          _dragging = false;
        });
        _focusSkip();
      }
    }
  }

  void _undoSkip() {
    final previous = _lastSkip;
    if (_busy || previous == null) return;
    widget.skips.remove(previous.$1);
    setState(() {
      _queue?.restore(previous.$2);
      _lastSkip = null;
      _error = null;
      _drag = 0;
    });
    _focusSkip();
  }

  @override
  Widget build(BuildContext context) {
    final compact = CompactSettings.of(context),
        queue = _queue,
        item = queue?.current;
    final kinds = [
      for (final kind in CatchUpKind.values)
        Padding(
          padding: const EdgeInsets.only(right: 10),
          child: ZoroButton(
            label: kind.label,
            primary: kind == _kind,
            onPressed: () {
              if (!_busy && kind != _kind) {
                _kind = kind;
                _reload();
              }
            },
          ),
        ),
    ];
    return SettingsScaffold(
      title: 'Catch Up',
      actions: compact ? const [] : kinds,
      children: [
        if (compact)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: kinds),
          ),
        if (_failed)
          _message(
            context,
            'Couldn’t load titles',
            ZoroButton(label: 'Try again', onPressed: _reload, autofocus: true),
          )
        else if (queue == null)
          Padding(
            padding: const EdgeInsets.all(40),
            child: Center(child: CircularProgressIndicator(color: Zoro.jade)),
          )
        else if (item == null)
          _message(
            context,
            'You’re all caught up',
            ZoroButton(
              label: 'Show skipped again',
              autofocus: true,
              onPressed: () {
                if (!_busy) {
                  widget.skips.clear();
                  _reload();
                }
              },
            ),
          )
        else ...[
          const SizedBox(height: 16),
          _decisionCard(context, item, compact),
          const SizedBox(height: 12),
          Text(
            queue.position,
            style: settingsFont(context, 18, color: Zoro.muted),
          ),
        ],
        if (_busy && !compact)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator(color: Zoro.jade)),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                style: settingsFont(context, 20, color: Zoro.muted),
              ),
            ),
          ),
        if (_lastSkip != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: ZoroButton(label: 'Undo skip', onPressed: _undoSkip),
          ),
      ],
    );
  }

  void _resetDrag() {
    if (!mounted || _busy) return;
    setState(() {
      _drag = 0;
      _dragging = false;
    });
  }

  Widget _decisionCard(BuildContext context, MediaItem item, bool compact) {
    if (!compact) return _card(context, item, false);
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= 700;
    final reduced = MediaQuery.of(context).disableAnimations;
    final accessible = MediaQuery.textScalerOf(context).scale(16) > 24;
    final queue = _queue!;
    final next = queue.index + 1 < queue.items.length
        ? queue.items[queue.index + 1]
        : null;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: wide ? 680 : 460),
        child: Column(
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                if (!width.isFinite || width <= 0) {
                  return const SizedBox.shrink();
                }
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    if (next != null)
                      ExcludeSemantics(
                        child: IgnorePointer(
                          child: Transform.translate(
                            offset: const Offset(0, 8),
                            child: Transform.scale(
                              scale: .98,
                              child: _mobileArtwork(next, wide),
                            ),
                          ),
                        ),
                      ),
                    Listener(
                      key: ValueKey('catch-up-card-${item.id}'),
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (event) {
                        if (_busy ||
                            accessible ||
                            _contacts.any((id) => id != event.pointer)) {
                          return;
                        }
                        _dragPointer = event.pointer;
                        _touchStart = event.position;
                        _velocity = VelocityTracker.withKind(event.kind)
                          ..addPosition(event.timeStamp, event.position);
                      },
                      onPointerMove: (event) {
                        final tracker = _velocity;
                        if (_busy ||
                            tracker == null ||
                            _dragPointer != event.pointer) {
                          return;
                        }
                        tracker.addPosition(event.timeStamp, event.position);
                        final delta = event.position - _touchStart;
                        final horizontal = delta.dx.abs() > delta.dy.abs() * .8;
                        if (horizontal || _dragging) {
                          setState(() {
                            _dragging = horizontal;
                            _drag = horizontal ? delta.dx : 0;
                          });
                        }
                      },
                      onPointerCancel: (event) {
                        if (_dragPointer != event.pointer) return;
                        _velocity = null;
                        _dragPointer = null;
                        _resetDrag();
                      },
                      onPointerUp: (event) {
                        if (_dragPointer != event.pointer) return;
                        _dragPointer = null;
                        final tracker = _velocity;
                        _velocity = null;
                        if (_busy || tracker == null) return;
                        final delta = event.position - _touchStart;
                        final dx = delta.dx;
                        final speed = tracker.getVelocity().pixelsPerSecond.dx;
                        final flick =
                            dx.abs() >= 32 &&
                            speed.abs() > 450 &&
                            speed * dx > 0;
                        if (dx.abs() > delta.dy.abs() * .8 &&
                            (dx.abs() >= (width * .2).clamp(0.0, 72.0) ||
                                flick)) {
                          _act(
                            dx < 0 ? CatchUpAction.skip : CatchUpAction.like,
                            item.id,
                          );
                        } else {
                          _resetDrag();
                        }
                      },
                      child: AnimatedSlide(
                        offset: Offset(_drag / width, 0),
                        duration: reduced || _dragging
                            ? Duration.zero
                            : const Duration(milliseconds: 190),
                        child: AnimatedRotation(
                          turns: reduced ? 0 : _drag / width * .025,
                          duration: reduced || _dragging
                              ? Duration.zero
                              : const Duration(milliseconds: 190),
                          child: Stack(
                            children: [
                              _mobileCard(item, wide),
                              if (_drag.abs() > 5)
                                Positioned(
                                  top: 20,
                                  right: _drag > 0 ? 20 : null,
                                  left: _drag < 0 ? 20 : null,
                                  child: ExcludeSemantics(
                                    child: Opacity(
                                      opacity: (_drag.abs() / 60).clamp(
                                        0.0,
                                        1.0,
                                      ),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 14,
                                          vertical: 10,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Zoro.background.withValues(
                                            alpha: .9,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                          border: Border.all(
                                            color: _drag > 0
                                                ? Zoro.jade
                                                : Zoro.text,
                                            width: 3,
                                          ),
                                        ),
                                        child: Text(
                                          _drag > 0 ? 'LIKE' : 'SKIP',
                                          style: Zoro.font(
                                            24,
                                            weight: FontWeight.w800,
                                            color: _drag > 0
                                                ? Zoro.jade
                                                : Zoro.text,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _phoneDecision(
                  'Skip',
                  Icons.close_rounded,
                  CatchUpAction.skip,
                  item,
                ),
                const SizedBox(width: 32),
                _phoneDecision(
                  'Like',
                  Icons.favorite_rounded,
                  CatchUpAction.like,
                  item,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Semantics(
              liveRegion: _busy,
              child: Text(
                _busy ? 'Saving…' : 'Swipe left to skip · Swipe right to like',
                textAlign: TextAlign.center,
                style: Zoro.font(15, color: Zoro.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mobileArtwork(MediaItem item, bool wide) {
    final uri = widget.catalog.artwork(
      item,
      landscape: wide,
      width: wide ? 1280 : 780,
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: AspectRatio(
        aspectRatio: wide ? 16 / 9 : 4 / 5,
        child: Artwork(
          url: uri,
          headers: widget.catalog.imageHeaders,
          title: item.name,
          seed: item.id,
        ),
      ),
    );
  }

  Widget _mobileInfo(MediaItem item) {
    final meta = [
      if (item.productionYear != null) '${item.productionYear}',
      if (item.officialRating?.isNotEmpty == true) item.officialRating!,
      if (item.communityRating case final rating?
          when rating.isFinite && rating > 0)
        '★ ${rating.toStringAsFixed(1)}',
    ];
    final accessible = MediaQuery.textScalerOf(context).scale(16) > 24;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          item.name,
          maxLines: accessible ? null : 2,
          overflow: TextOverflow.ellipsis,
          style: Zoro.font(28, weight: FontWeight.w800),
        ),
        if (meta.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              meta.join(' · '),
              style: Zoro.font(15, color: Zoro.muted),
            ),
          ),
        if (item.plainOverview?.isNotEmpty == true)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              item.plainOverview!,
              maxLines: accessible ? null : 2,
              overflow: accessible
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
              style: Zoro.font(16),
            ),
          ),
      ],
    );
  }

  Widget _mobileCard(MediaItem item, bool wide) {
    final accessible = MediaQuery.textScalerOf(context).scale(16) > 24;
    if (accessible) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: Zoro.panel,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          children: [
            _mobileArtwork(item, wide),
            Padding(
              padding: const EdgeInsets.all(18),
              child: _mobileInfo(item),
            ),
          ],
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Stack(
        children: [
          _mobileArtwork(item, wide),
          Positioned.fill(
            child: const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Color(0xF20D110F)],
                  stops: [.25, 1],
                ),
              ),
            ),
          ),
          Positioned(left: 18, right: 18, bottom: 18, child: _mobileInfo(item)),
        ],
      ),
    );
  }

  Widget _phoneDecision(
    String title,
    IconData icon,
    CatchUpAction action,
    MediaItem item,
  ) {
    final like = action == CatchUpAction.like;
    return TextButton(
      key: ValueKey('catch-up-${action.wire}'),
      onPressed: _busy ? null : () => _act(action, item.id),
      style: TextButton.styleFrom(
        padding: EdgeInsets.zero,
        minimumSize: const Size(80, 96),
        foregroundColor: Zoro.text,
      ),
      child: Opacity(
        opacity: _busy ? .5 : 1,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: like ? Zoro.jade.withValues(alpha: .12) : Zoro.panel,
                  border: Border.all(
                    color: like ? Zoro.jade.withValues(alpha: .4) : Zoro.border,
                  ),
                ),
                child: Icon(
                  icon,
                  size: 30,
                  color: like ? Zoro.jade : Zoro.text,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(title, style: Zoro.font(15, weight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _card(BuildContext context, MediaItem item, bool compact) {
    final size = MediaQuery.sizeOf(context);
    final wide = !compact || size.width >= 700 || size.width > size.height;
    final uri = widget.catalog.artwork(
      item,
      landscape: wide,
      width: wide ? 1280 : 640,
    );
    final image = ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: AspectRatio(
        aspectRatio: wide ? 16 / 9 : 2 / 3,
        child: uri == null
            ? const ColoredBox(color: Color(0xFF151C18))
            : Image.network(
                uri.toString(),
                headers: widget.catalog.imageHeaders,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    const ColoredBox(color: Color(0xFF151C18)),
              ),
      ),
    );
    final art = !wide
        ? Center(
            child: SizedBox(
              height: (MediaQuery.sizeOf(context).height * .4)
                  .clamp(180.0, 340.0)
                  .toDouble(),
              child: image,
            ),
          )
        : image;
    final meta = [
      if (item.productionYear != null) '${item.productionYear}',
      if (item.officialRating?.isNotEmpty == true) item.officialRating!,
    ];
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.name,
          style: settingsFont(context, 36, weight: FontWeight.w700),
        ),
        if (meta.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              meta.join(' · '),
              style: settingsFont(context, 20, color: Zoro.muted),
            ),
          ),
        if (item.overview?.isNotEmpty == true)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              item.overview!,
              maxLines: compact ? 3 : 4,
              overflow: TextOverflow.ellipsis,
              style: settingsFont(context, 22),
            ),
          ),
        const SizedBox(height: 18),
        Semantics(
          enabled: !_busy,
          child: IgnorePointer(
            ignoring: _busy,
            child: Opacity(
              opacity: _busy ? .5 : 1,
              child: FocusTraversalGroup(
                child: Wrap(
                  spacing: 14,
                  runSpacing: 12,
                  children: [
                    ZoroButton(
                      key: const ValueKey('catch-up-skip'),
                      label: 'Skip',
                      icon: compact
                          ? Icons.arrow_back_rounded
                          : Icons.close_rounded,
                      focusNode: _skip,
                      onPressed: () => _act(CatchUpAction.skip, item.id),
                    ),
                    ZoroButton(
                      key: const ValueKey('catch-up-like'),
                      label: 'Like',
                      icon: Icons.favorite_rounded,
                      primary: true,
                      onPressed: () => _act(CatchUpAction.like, item.id),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
    return !wide
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [art, const SizedBox(height: 14), info],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 5, child: art),
              const SizedBox(width: 32),
              Expanded(flex: 5, child: info),
            ],
          );
  }

  Widget _message(BuildContext context, String title, Widget action) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 40),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: settingsFont(context, 30, weight: FontWeight.w700)),
        const SizedBox(height: 16),
        action,
      ],
    ),
  );
}
