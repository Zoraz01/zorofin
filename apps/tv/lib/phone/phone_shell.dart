import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/catalog.dart';
import '../core/models.dart';
import '../core/server_extras.dart';
import '../extras_state.dart';
import '../ui/theme.dart';
import '../ui/widgets/live_tv_notice.dart' show showLiveTvConflict;
import '../watch_together.dart';
import 'phone_detail.dart';
import '../ui/screens/collections_screen.dart';
import 'phone_downloads.dart';
import 'phone_live.dart';
import 'phone_home.dart';
import 'phone_library.dart';
import 'phone_player.dart';
import 'phone_profile.dart';
import 'phone_requests.dart';
import 'phone_scope.dart';
import 'phone_search.dart';
import 'phone_theme.dart';
import 'phone_widgets.dart';

/// Signed-in phone and tablet shell (Apple `ZorofinShell` on iPhone/iPad):
/// the current section with any opened titles, and the floating dock
/// (a full-width bar on tablets) with Home, Search, Requests and Profile.
class PhoneShell extends StatefulWidget {
  const PhoneShell({super.key, required this.state, required this.catalog});

  final AppState state;
  final Catalog catalog;

  @override
  State<PhoneShell> createState() => _PhoneShellState();
}

class _PhoneShellState extends State<PhoneShell> {
  PhoneDestination _destination = PhoneDestination.home;
  final _content = GlobalKey<NavigatorState>();
  int _revision = 0;
  bool _checkingLive = false;
  bool _playerOpen = false;

  late final ExtrasState _extras = ExtrasState(
    catalog: widget.catalog,
    storage: widget.state.storage,
  );
  final _together = WatchTogether();

  @override
  void initState() {
    super.initState();
    _extras.start();
    _extras.addListener(_extrasChanged);
    final client = widget.catalog.client;
    if (!widget.catalog.isPreview && client != null) {
      _together.configure(client);
      unawaited(_together.refresh());
    }
    _together.addListener(_togetherChanged);
    PhoneDownloads.instance.addListener(_downloadsChanged);
  }

  @override
  void dispose() {
    PhoneDownloads.instance.removeListener(_downloadsChanged);
    _together.removeListener(_togetherChanged);
    _together.dispose();
    _extras.removeListener(_extrasChanged);
    _extras.dispose();
    super.dispose();
  }

  void _downloadsChanged() {
    if (mounted) setState(() {});
  }

  bool get _showsRequests => _extras.requestsEnabled || _extras.isPreview;

  void _extrasChanged() {
    if (!mounted) return;
    setState(() {});
    if (_destination == PhoneDestination.requests && !_showsRequests) {
      _select(PhoneDestination.home);
    }
  }

  /// The group asked to browse, or started a title while no player is open.
  void _togetherChanged() {
    if (!mounted) return;
    setState(() {});
    if (_playerOpen) return;
    if (_together.browseRequested) {
      _together.takePlaybackRequest();
      _select(PhoneDestination.home);
      return;
    }
    final request = _together.playbackRequest;
    final catalog = widget.catalog;
    if (request == null || catalog is! JellyfinCatalog) return;
    _together.takePlaybackRequest();
    unawaited(
      _openPlayer(catalog, request.item, startTicks: request.startTicks),
    );
  }

  void _select(PhoneDestination value) {
    // Retapping a tab returns to its root.
    _content.currentState?.popUntil((route) => route.isFirst);
    if (_destination == value) return;
    setState(() => _destination = value);
  }

  void _open(MediaItem item) {
    final navigator = _content.currentState;
    if (navigator == null) return;
    // A title opened from a page over the shell (inbox, profile…) opens in
    // the current section once that page closes.
    Navigator.of(context).popUntil((route) => route.isFirst);
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => item.type == 'BoxSet'
              ? CollectionsScreen(
                  catalog: widget.catalog,
                  collection: item,
                  mobile: true,
                  onOpen: _open,
                  onBack: () => navigator.pop(),
                )
              : PhoneDetailScreen(item: item),
        ),
      ),
    );
  }

  /// Full pages open over the dock but keep the shell's scope.
  Future<void> _push(Widget page) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => _scoped(page)));

  Widget _scoped(Widget child) => PhoneScope(
    state: widget.state,
    catalog: widget.catalog,
    extras: _extras,
    together: _together,
    open: _open,
    play: _play,
    select: _select,
    push: _push,
    revision: _revision,
    child: ExtrasScope(extras: _extras, child: child),
  );

  void _message(String text) => showPhoneMessage(context, text);

  Future<void> _play(
    MediaItem item, {
    int? startTicks,
    int? audioIndex,
    int? subtitleIndex,
    bool? burnSubtitles,
  }) async {
    final catalog = widget.catalog;
    // A downloaded copy always plays from the device, online or not.
    final offline = PhoneDownloads.instance.playable(item.id);
    if (offline != null && !_together.isJoined) {
      await openOfflinePlayer(context, offline);
      if (mounted) setState(() => _revision++);
      return;
    }
    if (catalog is! JellyfinCatalog) {
      _message(
        'This preview contains fictional titles. Connect your server to watch your library.',
      );
      return;
    }
    if (item.isSeries || item.type == 'Season') {
      // Series and seasons have no media of their own; Play starts the next
      // episode, as on iPhone.
      final MediaItem? next;
      try {
        next = await catalog.nextEpisode(item);
      } on Object {
        if (mounted) {
          _message('Couldn’t find an episode of ${item.name} to play.');
        }
        return;
      }
      if (!mounted) return;
      if (next == null) {
        _message('No episodes of ${item.name} are available.');
        return;
      }
      item = next;
      startTicks = next.resumeTicks;
    }
    if (_together.isJoined) {
      if (item.isLive) {
        _message('Leave your group from Profile to watch Live TV.');
      } else {
        await _together.selectForPlayback(item, startTicks ?? item.resumeTicks);
      }
      return;
    }
    if (item.isLive) {
      setState(() => _checkingLive = true);
      try {
        if (!_extras.featuresChecked) await _extras.checkFeatures();
        await catalog.client.checkLiveTvCapacity(
          item.id,
          enabled: _extras.features.liveTVAvailability,
          streams: _extras.features.liveTvStreams,
        );
      } on LiveTvConflict catch (conflict) {
        if (mounted) {
          setState(() => _checkingLive = false);
          final join = await showLiveTvConflict(context, conflict);
          if (join != null && mounted) await _play(join);
        }
        return;
      } catch (_) {
        // The check is advisory; the server still enforces its limit.
      }
      if (!mounted) return;
      setState(() => _checkingLive = false);
    }
    await _openPlayer(
      catalog,
      item,
      startTicks: startTicks,
      audioIndex: audioIndex,
      subtitleIndex: subtitleIndex,
      burnSubtitles: burnSubtitles,
    );
  }

  Future<void> _openPlayer(
    JellyfinCatalog catalog,
    MediaItem item, {
    int? startTicks,
    int? audioIndex,
    int? subtitleIndex,
    bool? burnSubtitles,
  }) async {
    _playerOpen = true;
    await Navigator.of(context).push(
      PhonePlayerRoute(
        builder: (_) => ExtrasScope(
          extras: _extras,
          child: PhonePlayerScreen(
            catalog: catalog,
            item: item,
            startTicks: startTicks,
            audioIndex: audioIndex,
            subtitleIndex: subtitleIndex,
            burnSubtitles: burnSubtitles ?? false,
            liveCapacityCheck: _extras.features.liveTVAvailability,
            liveStreamsCheck: _extras.features.liveTvStreams,
            group: _together.isJoined ? _together : null,
          ),
        ),
      ),
    );
    _playerOpen = false;
    if (mounted) setState(() => _revision++);
  }

  Widget _root(PhoneDestination destination) => switch (destination) {
    PhoneDestination.home => const PhoneHomeScreen(),
    PhoneDestination.movies => const PhoneLibraryScreen(
      kind: LibraryKind.movies,
    ),
    PhoneDestination.shows => const PhoneLibraryScreen(kind: LibraryKind.shows),
    PhoneDestination.live => const PhoneLiveScreen(),
    PhoneDestination.search => const PhoneSearchScreen(),
    PhoneDestination.requests => const PhoneRequestsScreen(),
    PhoneDestination.profile => const PhoneProfileScreen(),
  };

  List<PhoneDestination> get _dockItems => [
    PhoneDestination.home,
    PhoneDestination.search,
    if (_showsRequests) PhoneDestination.requests,
    PhoneDestination.profile,
  ];

  @override
  Widget build(BuildContext context) {
    final window = PhoneWindow.of(context);
    final media = MediaQuery.of(context);
    final dockSpace = window.tablet ? 64.0 : 74.0;
    final offline =
        !PhoneDownloads.instance.online && !widget.catalog.isPreview;
    // While the keyboard is up the dock is behind it, so pages only make
    // room for the keyboard (their own Scaffolds do that).
    final keyboard = media.viewInsets.bottom > 0;
    final content = MediaQuery(
      data: media.copyWith(
        padding: media.padding.copyWith(
          // The preview label sits under the status bar, above every page.
          top: media.padding.top + (widget.catalog.isPreview ? 18 : 0),
          bottom: keyboard
              ? media.padding.bottom
              : media.padding.bottom + dockSpace + (offline ? 46 : 0),
        ),
      ),
      child: NavigatorPopHandler(
        onPopWithResult: (_) => _content.currentState?.maybePop(),
        child: Navigator(
          key: _content,
          onGenerateRoute: (settings) => PageRouteBuilder<void>(
            settings: settings,
            pageBuilder: (_, _, _) => KeyedSubtree(
              key: ValueKey(_destination),
              child: _root(_destination),
            ),
            transitionDuration: Duration.zero,
          ),
        ),
      ),
    );
    return _scoped(
      PopScope(
        // Back at a section root returns Home before leaving the app.
        canPop: _destination == PhoneDestination.home,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _select(PhoneDestination.home);
        },
        child: Scaffold(
          backgroundColor: Zoro.background,
          // Each page resizes for the keyboard; resizing here too would
          // count it twice.
          resizeToAvoidBottomInset: false,
          // Landscape keeps content clear of side navigation bars and
          // cutouts; the top and bottom are handled per page.
          body: SafeArea(
            top: false,
            bottom: false,
            child: Stack(
              children: [
                // A new section starts a new stack, like iPhone tabs.
                KeyedSubtree(key: ValueKey(_destination), child: content),
                if (widget.catalog.isPreview)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Container(
                        color: Zoro.panel,
                        padding: EdgeInsets.only(top: media.padding.top),
                        alignment: Alignment.center,
                        height: media.padding.top + 18,
                        child: Text(
                          'APP PREVIEW · FICTIONAL LIBRARY',
                          style: Zoro.font(
                            10,
                            weight: FontWeight.w600,
                            color: Zoro.jade,
                          ).copyWith(letterSpacing: 1.3),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (offline)
                        _OfflineBanner(
                          onPressed: () => _push(const PhoneDownloadsScreen()),
                        ),
                      _Dock(
                        items: _dockItems,
                        selected: _destination.dockItem,
                        tablet: window.tablet,
                        viewerName: widget.catalog.viewerName,
                        photo: widget.catalog.viewerPhoto(width: 96),
                        headers: widget.catalog.imageHeaders,
                        onSelect: _select,
                      ),
                    ],
                  ),
                ),
                if (_checkingLive)
                  const Center(
                    child: Card(
                      color: Zoro.panel,
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        child: PhoneLoading(
                          label: 'Checking Live TV availability…',
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Dock extends StatelessWidget {
  const _Dock({
    required this.items,
    required this.selected,
    required this.tablet,
    required this.viewerName,
    required this.photo,
    required this.headers,
    required this.onSelect,
  });

  final List<PhoneDestination> items;
  final PhoneDestination selected;
  final bool tablet;
  final String viewerName;
  final Uri? photo;
  final Map<String, String> headers;
  final ValueChanged<PhoneDestination> onSelect;

  IconData _icon(PhoneDestination d) => switch (d) {
    PhoneDestination.home => Icons.home_rounded,
    PhoneDestination.search => Icons.search_rounded,
    PhoneDestination.requests => Icons.add_to_queue_rounded,
    _ => Icons.person_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final motion = !MediaQuery.disableAnimationsOf(context);
    final row = Row(
      children: [
        for (final item in items)
          Expanded(
            child: Semantics(
              selected: item == selected,
              button: true,
              label: item.title,
              excludeSemantics: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onSelect(item),
                child: AnimatedContainer(
                  duration: motion
                      ? const Duration(milliseconds: 220)
                      : Duration.zero,
                  curve: Curves.easeOutCubic,
                  constraints: const BoxConstraints(minHeight: 52),
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  decoration: ShapeDecoration(
                    color: item == selected
                        ? Colors.white.withValues(alpha: .11)
                        : Colors.transparent,
                    shape: const StadiumBorder(),
                  ),
                  child: Flex(
                    direction: tablet ? Axis.horizontal : Axis.vertical,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AnimatedScale(
                        scale: motion && item == selected ? 1.1 : 1,
                        duration: const Duration(milliseconds: 200),
                        child: item == PhoneDestination.profile
                            ? PhoneAvatar(
                                name: viewerName,
                                size: 22,
                                photo: photo,
                                headers: headers,
                              )
                            : Icon(
                                _icon(item),
                                size: 22,
                                color: item == selected
                                    ? Zoro.text
                                    : Zoro.muted,
                              ),
                      ),
                      SizedBox(width: tablet ? 10 : 0, height: tablet ? 0 : 3),
                      Text(
                        item.title,
                        style: Zoro.font(
                          tablet ? 14 : 10,
                          weight: FontWeight.w500,
                          color: item == selected ? Zoro.text : Zoro.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
    if (tablet) {
      final width = MediaQuery.sizeOf(context).width;
      return Container(
        decoration: BoxDecoration(
          color: Zoro.background.withValues(alpha: .97),
          border: Border(
            top: BorderSide(color: Zoro.border.withValues(alpha: .4)),
          ),
        ),
        padding: EdgeInsets.fromLTRB(
          (width * 0.16).clamp(24, 400).toDouble(),
          6,
          (width * 0.16).clamp(24, 400).toDouble(),
          6 + bottom,
        ),
        child: row,
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(28, 0, 28, 8 + bottom),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Container(
            padding: const EdgeInsets.all(5),
            decoration: ShapeDecoration(
              color: const Color(0xF21B211E),
              shape: StadiumBorder(
                side: BorderSide(color: Zoro.muted.withValues(alpha: .2)),
              ),
              shadows: const [
                BoxShadow(color: Color(0x66000000), blurRadius: 18),
              ],
            ),
            child: row,
          ),
        ),
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Material(
      color: const Color(0xF21B211E),
      shape: StadiumBorder(
        side: BorderSide(color: Zoro.jade.withValues(alpha: .5)),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off_rounded, size: 18),
              const SizedBox(width: 8),
              Text(
                'You’re offline. Watch your downloads',
                style: Zoro.font(14, weight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
