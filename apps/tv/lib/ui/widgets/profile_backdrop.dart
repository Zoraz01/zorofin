import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/profile_spotlight.dart';
import '../../core/profile_spotlight_store.dart';
import '../../core/saved_connections.dart';
import '../theme.dart';

/// Per-profile "was watching" data for Who's watching (Apple
/// `ProfileSpotlights`). Cached spotlights show at once; each profile then
/// refreshes with its own saved session, one at a time.
class ProfileSpotlights extends ChangeNotifier {
  ProfileSpotlights(this.state);

  final AppState state;
  final Map<String, ProfileSpotlight> _spotlights = {};
  String _loadedFor = '';
  int _generation = 0;
  bool _disposed = false;

  ProfileSpotlight? operator [](String accountId) => _spotlights[accountId];

  /// Loads once per set of saved accounts; call again after accounts change.
  Future<void> load() async {
    final accounts = List.of(state.connections.accounts);
    final ids = accounts.map((a) => a.id).join(',');
    if (ids == _loadedFor) return;
    _loadedFor = ids;
    final generation = ++_generation;
    final store = ProfileSpotlightStore(state.storage);
    await store.prune(accounts.map((a) => a.id).toSet());
    for (final account in accounts) {
      final cached = store.load(account.id);
      if (cached != null) _spotlights[account.id] = cached;
    }
    _notify();
    for (final account in accounts) {
      final session = account.session;
      if (session == null) continue;
      try {
        final fresh = await state
            .clientFor(account.server)
            .withSession(session)
            .profileSpotlight();
        if (_disposed || generation != _generation) return;
        await store.save(account.id, fresh);
        if (fresh == null) {
          _spotlights.remove(account.id);
        } else {
          _spotlights[account.id] = fresh;
        }
        _notify();
      } catch (_) {
        // Offline or signed out: the cached spotlight stays.
      }
    }
  }

  /// Artwork URL and headers for [image] on [account]'s own server.
  (Uri, Map<String, String>)? imageFor(
    SavedAccount account,
    SpotlightImage? image, {
    required int width,
  }) {
    final session = account.session;
    if (image == null || session == null) return null;
    final client = state.clientFor(account.server).withSession(session);
    return (
      client.image(image.itemId, kind: image.kind, tag: image.tag, width: width),
      client.authHeaders,
    );
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Full-bleed art of what the shown profile was watching, dimmed toward the
/// text. Without history, a soft wash of that profile's scene avatar.
class ProfileBackdrop extends StatelessWidget {
  const ProfileBackdrop({
    super.key,
    required this.artKey,
    required this.tv,
    this.image,
    this.fallbackAsset,
  });

  final String artKey;
  final bool tv;
  final (Uri, Map<String, String>)? image;
  final String? fallbackAsset;

  @override
  Widget build(BuildContext context) {
    final fallback = fallbackAsset == null
        ? const SizedBox.expand()
        : Opacity(
            opacity: 0.35,
            child: Image.asset(
              fallbackAsset!,
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              filterQuality: FilterQuality.low,
              excludeFromSemantics: true,
            ),
          );
    final art = image == null
        ? fallback
        : Image.network(
            image!.$1.toString(),
            headers: image!.$2,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            excludeFromSemantics: true,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => fallback,
          );
    const bg = Zoro.background;
    return ExcludeSemantics(
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: bg),
          Align(
            alignment: Alignment.topCenter,
            child: FractionallySizedBox(
              heightFactor: tv ? 1 : 0.72,
              widthFactor: 1,
              child: AnimatedSwitcher(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 450),
                child: KeyedSubtree(key: ValueKey(artKey), child: art),
              ),
            ),
          ),
          if (tv) ...[
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    bg.withValues(alpha: 0.94),
                    bg.withValues(alpha: 0.72),
                    bg.withValues(alpha: 0.12),
                    bg.withValues(alpha: 0),
                  ],
                  stops: const [0, 0.38, 0.7, 1],
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    bg.withValues(alpha: 0.97),
                    bg.withValues(alpha: 0.55),
                    bg.withValues(alpha: 0),
                  ],
                  stops: const [0, 0.34, 0.6],
                ),
              ),
            ),
          ] else
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    bg,
                    bg,
                    bg.withValues(alpha: 0.55),
                    bg.withValues(alpha: 0.1),
                    bg.withValues(alpha: 0.5),
                  ],
                  stops: const [0, 0.4, 0.62, 0.85, 1],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// "Maya was watching" with a 16:9 thumbnail and resume progress.
class ProfileSpotlightCard extends StatelessWidget {
  const ProfileSpotlightCard({
    super.key,
    required this.name,
    required this.spotlight,
    required this.tv,
    this.thumbnail,
  });

  final String name;
  final ProfileSpotlight spotlight;
  final bool tv;
  final (Uri, Map<String, String>)? thumbnail;

  @override
  Widget build(BuildContext context) {
    final w = tv ? 208.0 : 96.0, h = tv ? 117.0 : 54.0;
    final progress = spotlight.progress;
    return Semantics(
      label: '$name was watching ${spotlight.line}',
      excludeSemantics: true,
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(tv ? 12 : 8),
            child: SizedBox(
              width: w,
              height: h,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: Zoro.panel),
                  if (thumbnail != null)
                    Image.network(
                      thumbnail!.$1.toString(),
                      headers: thumbnail!.$2,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  if (progress != null)
                    Align(
                      alignment: Alignment.bottomLeft,
                      child: SizedBox(
                        height: tv ? 5 : 3,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            const ColoredBox(color: Color(0x40FFFFFF)),
                            FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: progress,
                              child: ColoredBox(color: Zoro.jade),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          SizedBox(width: tv ? 22 : 12),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$name was watching',
                  style: Zoro.font(tv ? 22 : 13, color: Zoro.muted),
                ),
                SizedBox(height: tv ? 4 : 2),
                Text(
                  spotlight.line,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Zoro.font(tv ? 30 : 16, weight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Rounded-square profile avatar: the Jellyfin photo, else the initial.
class ProfileSquare extends StatelessWidget {
  const ProfileSquare({
    super.key,
    required this.name,
    required this.viewerId,
    required this.size,
    this.photo,
    this.headers = const {},
  });

  final String name;
  final String viewerId;
  final double size;
  final Uri? photo;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    final initial = Center(
      child: Text(
        name.isEmpty ? '?' : name[0].toUpperCase(),
        style: Zoro.font(size / 2, weight: FontWeight.w700),
      ),
    );
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Zoro.avatar,
        borderRadius: BorderRadius.circular(size * 0.22),
      ),
      child: photo == null
          ? initial
          : Image.network(
              photo.toString(),
              headers: headers,
              width: size,
              height: size,
              fit: BoxFit.cover,
              excludeFromSemantics: true,
              errorBuilder: (_, _, _) => initial,
            ),
    );
  }
}

/// Avatar with the focus/current ring and name, shared by TV and phone.
class ProfileTile extends StatelessWidget {
  const ProfileTile({
    super.key,
    required this.account,
    required this.size,
    required this.ringed,
    required this.tv,
    this.busy = false,
    this.current = false,
    this.photo,
    this.headers = const {},
  });

  final SavedAccount account;
  final double size;
  final bool ringed;
  final bool tv;
  final bool busy;
  final bool current;
  final Uri? photo;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    final gap = tv ? 11.0 : 5.5;
    return SizedBox(
      width: size + gap * 2,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedScale(
            scale: tv ? Zoro.lift(context, ringed, 1.08) : 1,
            duration: Zoro.focusDuration,
            child: AnimatedOpacity(
              opacity: tv && !ringed ? 0.82 : 1,
              duration: Zoro.focusDuration,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    padding: EdgeInsets.all(gap),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(size * 0.22 + gap),
                      border: Border.all(
                        color: ringed ? Zoro.text : Colors.transparent,
                        width: tv ? 5 : 2.5,
                      ),
                    ),
                    child: ProfileSquare(
                      name: account.viewer.name,
                      viewerId: account.viewer.id,
                      size: size,
                      photo: photo,
                      headers: headers,
                    ),
                  ),
                  if (busy)
                    const Positioned.fill(
                      child: Center(
                        child: CircularProgressIndicator(color: Zoro.text),
                      ),
                    ),
                  if (!busy && current && tv)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: Zoro.jade,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.check_rounded,
                          size: 22,
                          color: Zoro.background,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          SizedBox(height: tv ? (ringed ? 18 : 10) : 6),
          Text(
            account.viewer.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Zoro.font(
              tv ? 26 : 15,
              weight: ringed ? FontWeight.w600 : FontWeight.w500,
              color: ringed ? Zoro.text : Zoro.muted,
            ),
          ),
          if (account.session == null)
            Text(
              'Sign in again',
              style: Zoro.font(tv ? 18 : 12, color: Zoro.jade),
            ),
        ],
      ),
    );
  }
}

/// The "+" tile beside the profiles.
class AddProfileTile extends StatelessWidget {
  const AddProfileTile({
    super.key,
    required this.size,
    required this.tv,
    required this.ringed,
  });

  final double size;
  final bool tv;
  final bool ringed;

  @override
  Widget build(BuildContext context) {
    final gap = tv ? 11.0 : 5.5;
    return SizedBox(
      width: size + gap * 2,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: EdgeInsets.all(gap),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(size * 0.22 + gap),
              border: Border.all(
                color: ringed ? Zoro.text : Colors.transparent,
                width: tv ? 5 : 2.5,
              ),
            ),
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: const Color(0x17FFFFFF),
                borderRadius: BorderRadius.circular(size * 0.22),
              ),
              child: Icon(
                Icons.add_rounded,
                size: tv ? 56 : 34,
                color: Zoro.muted,
              ),
            ),
          ),
          SizedBox(height: tv ? 10 : 6),
          Text(
            'Add',
            style: Zoro.font(
              tv ? 26 : 15,
              weight: FontWeight.w500,
              color: ringed ? Zoro.text : Zoro.muted,
            ),
          ),
        ],
      ),
    );
  }
}
