import '../../phone/phone_live.dart' show LiveBrowseScreen;
import 'guide_screen.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/catalog.dart';
import '../../core/models.dart';
import '../../core/playback.dart';
import '../../core/server_extras.dart';
import '../../extras_state.dart';
import '../../watch_together.dart';
import '../theme.dart';
import '../player/in_app_player.dart';
import '../widgets/focusable.dart';
import '../widgets/live_tv_notice.dart';
import '../../core/errors.dart';
import '../../core/session_store.dart';
import 'account_popover.dart';
import 'pick_together_screen.dart';
import 'calendar_screen.dart';
import 'catch_up_screen.dart';
import 'accounts_screen.dart';
import 'alert_settings.dart';
import 'detail_screen.dart';
import 'home_screen.dart';
import 'collections_screen.dart';
import 'library_screen.dart';
import 'notifications_panel.dart';
import 'player_screen.dart';
import 'profile_screen.dart';
import 'requests_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'support_screen.dart';
import 'teams_screen.dart';
import 'watch_together_screen.dart';

enum Destination { home, movies, shows, live, requests, search, profile }

/// Signed-in TV shell (Apple `ZorofinShell` TV layout): a persistent header
/// with the mark, Home / Movies / TV Shows / Live TV, profile and search, over
/// a stack of the current destination and any opened titles.
class TvShell extends StatefulWidget {
  const TvShell({super.key, required this.state, required this.catalog});

  final AppState state;
  final Catalog catalog;

  @override
  State<TvShell> createState() => _TvShellState();
}

class _TvShellState extends State<TvShell> {
  Destination _destination = Destination.home;
  final List<MediaItem?> _path = [];

  /// Focus to restore when each opened title is closed, like returning to
  /// the card that opened it on Apple TV.
  final List<FocusNode?> _returnFocus = [];

  /// Bumped when an opened title changes watch state so Home reloads.
  int _revision = 0;

  late final ExtrasState _extras = ExtrasState(
    catalog: widget.catalog,
    storage: widget.state.storage,
  );
  bool _showNotifications = false;
  bool _checkingLive = false;
  final _bell = FocusNode(debugLabel: 'notifications-bell');
  final _header = FocusNode(
    debugLabel: 'header',
    canRequestFocus: false,
    skipTraversal: true,
  );

  /// Watch together for this account; the server owns the group.
  final _together = WatchTogether();
  final _playerHost = GlobalKey<InAppPlayerHostState>();
  bool get _playerOpen => _playerHost.currentState?.hasPlayer ?? false;

  @override
  void initState() {
    super.initState();
    _extras.start();
    widget.state.recommendations.addListener(_recommendationsChanged);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _recommendationsChanged(),
    );
    _extras.addListener(_extrasChanged);
    final client = widget.catalog.client;
    if (!widget.catalog.isPreview && client != null) {
      _together.configure(client);
      unawaited(_together.refresh());
    }
    _together.addListener(_togetherChanged);
  }

  @override
  void dispose() {
    widget.state.recommendations.removeListener(_recommendationsChanged);
    _together.removeListener(_togetherChanged);
    _together.dispose();
    _extras.removeListener(_extrasChanged);
    _extras.dispose();
    _bell.dispose();
    _header.dispose();
    super.dispose();
  }

  void _recommendationsChanged() {
    if (!mounted) return;
    final item = widget.state.recommendations.takeOpening();
    if (item != null) unawaited(_openRecommendation(item));
  }

  Future<void> _openRecommendation(MediaItem item) async {
    final generation = widget.state.generation;
    await _playerHost.currentState?.closePlayer();
    if (!mounted || generation != widget.state.generation) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    _select(Destination.home);
    _open(item);
  }

  /// The inbox closes if the server stops offering notifications.
  void _extrasChanged() {
    if (_showNotifications && !_extras.hasNotifications) _closeNotifications();
    if (_destination == Destination.requests && !_showsRequests) {
      _select(Destination.home);
    }
  }

  /// The group asked to browse, or opened a title while no player is up.
  void _togetherChanged() {
    if (!mounted) return;
    setState(() {});
    if (_playerOpen) return;
    if (_together.browseRequested) {
      _together.takePlaybackRequest();
      Navigator.of(context).popUntil((r) => r.isFirst);
      _select(Destination.home);
      return;
    }
    final request = _together.playbackRequest;
    final catalog = widget.catalog;
    if (request == null || catalog is! JellyfinCatalog) return;
    _together.takePlaybackRequest();
    Navigator.of(context).popUntil((r) => r.isFirst);
    unawaited(
      _openPlayer(catalog, request.item, startTicks: request.startTicks),
    );
  }

  bool get _showsRequests => _extras.requestsEnabled || _extras.isPreview;

  final _requests = GlobalKey<RequestsScreenState>();

  void _openNotifications() => setState(() => _showNotifications = true);

  void _closeNotifications() {
    setState(() => _showNotifications = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_bell.context != null) _bell.requestFocus();
    });
  }

  Future<void> _push(Widget page) async {
    await _playerHost.currentState?.closePlayer();
    if (mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ExtrasScope(extras: _extras, child: page),
        ),
      );
    }
  }

  void _openSupport() => _push(
    SupportScreen(extras: _extras, viewerName: widget.catalog.viewerName),
  );

  void _openNotificationSettings() {
    final client = widget.catalog.client;
    _push(
      SettingsScreen(
        page: SettingsPage.notifications,
        preferences: widget.state.preferences,
        catalog: widget.catalog,
        grouped: true,
        extraFields:
            _extras.features.notificationSettings &&
                !_extras.isPreview &&
                client != null
            ? AlertSettingsFields(client: client)
            : null,
      ),
    );
  }

  void _select(Destination value) {
    if (value == Destination.profile) {
      unawaited(_playerHost.currentState?.closePlayer());
    }
    setState(() {
      _path.clear();
      _returnFocus.clear();
      _destination = value;
    });
  }

  /// A title chosen on Calendar or Catch Up opens over Home, like a
  /// recommendation.
  void _openFromPage(MediaItem item) {
    if (!mounted) return;
    _select(Destination.home);
    _open(item);
  }

  void _open(MediaItem item) {
    _returnFocus.add(FocusManager.instance.primaryFocus);
    setState(() => _path.add(item));
  }

  void _openCollections() {
    _returnFocus.add(FocusManager.instance.primaryFocus);
    setState(() => _path.add(null));
  }

  /// Back from a destination's content returns to its tab first, as on
  /// Apple TV; Back on the tab bar leaves the app.
  bool get _contentFocused => !_header.hasFocus;

  /// Search and Profile have no tab of their own, so Back returns Home.
  bool get _offTab =>
      _destination == Destination.search || _destination == Destination.profile;

  void _goHome() {
    _select(Destination.home);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusTab();
    });
  }

  void _focusTab() {
    // Scroll the content back to the top on the way, as Apple TV does.
    var scrollable = Scrollable.maybeOf(
      FocusManager.instance.primaryFocus?.context ?? context,
    );
    while (scrollable != null) {
      if (scrollable.axisDirection == AxisDirection.down &&
          scrollable.position.pixels > 0) {
        scrollable.position.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      }
      scrollable = Scrollable.maybeOf(scrollable.context);
    }
    final tab = _header.descendants.where((node) {
      final button = node.context?.findAncestorWidgetOfExactType<NavButton>();
      return node.canRequestFocus && (button?.selected ?? false);
    }).firstOrNull;
    (tab ?? _header.descendants.where((n) => n.canRequestFocus).firstOrNull)
        ?.requestFocus();
  }

  void _back() {
    final target = _returnFocus.removeLast();
    setState(() => _path.removeLast());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (target != null && target.context != null) target.requestFocus();
    });
  }

  /// The destination and every opened title stay built so Back returns to
  /// the same scroll position and focus; only the top layer is shown.
  Widget _layer(int index, Widget child) {
    final top = index == _path.length;
    return Offstage(
      offstage: !top,
      child: TickerMode(
        enabled: top,
        child: ExcludeFocus(excluding: !top, child: child),
      ),
    );
  }

  final _avatar = GlobalKey(debugLabel: 'account-menu');

  Future<void> _accountMenu() async {
    final box = _avatar.currentContext?.findRenderObject() as RenderBox?;
    // Measure in the dialog's own space. The app is drawn on a scaled
    // 1920x1080 canvas, so screen coordinates would put the menu in the wrong
    // place on any TV whose logical size isn't 1920x1080.
    final overlay =
        Navigator.of(
              context,
              rootNavigator: true,
            ).overlay?.context.findRenderObject()
            as RenderBox?;
    final anchor = box == null
        ? Rect.fromLTWH(MediaQuery.sizeOf(context).width - 200, 30, 64, 64)
        // The 48pt avatar sits centered in its padded button; align to it.
        : Rect.fromCenter(
            center:
                (box.localToGlobal(Offset.zero, ancestor: overlay) & box.size)
                    .center,
            width: 48,
            height: 48,
          );
    final choice = await showAccountPopover(
      context,
      state: widget.state,
      anchor: anchor,
      serverName: widget.catalog.serverName,
      watchTogether: widget.catalog.isPreview || _together.canJoin,
      pickTogether:
          widget.catalog is JellyfinCatalog && _extras.features.pickTogether,
      extras: _extras.pluginExtras,
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case SwitchAccount(:final account):
        await _switchTo(account);
      case AccountMenuPage.calendar:
        _push(CalendarScreen(catalog: widget.catalog, onOpen: _openFromPage));
      case AccountMenuPage.catchUp:
        final skips = _extras.catchUpSkips;
        if (skips != null) {
          _push(CatchUpScreen(catalog: widget.catalog, skips: skips));
        }
      case AccountMenuPage.settings:
        _select(Destination.profile);
      case AccountMenuPage.servers:
        await _openAccounts();
      case AccountMenuPage.quickConnect:
        _push(QuickConnectScreen(state: widget.state));
      case AccountMenuPage.pickTogether:
        final catalog = widget.catalog;
        if (catalog is JellyfinCatalog) {
          _push(
            PickTogetherScreen(
              catalog: catalog,
              display: true,
              onOpen: (item) {
                Navigator.of(context).maybePop();
                _openFromPage(item);
              },
              onPlay: (item) => _play(item),
            ),
          );
        }
      case AccountMenuPage.watchTogether:
        _push(
          WatchTogetherScreen(
            group: _together,
            preview: widget.catalog.isPreview,
          ),
        );
    }
  }

  Future<void> _openAccounts() => _push(AccountsScreen(state: widget.state));

  /// Switches straight from the menu; an expired account signs in again on
  /// Who's watching, as on Apple TV.
  Future<void> _switchTo(SavedAccount account) async {
    if (account.session == null) return _openAccounts();
    try {
      await widget.state.switchAccount(account.id);
    } on ClientError catch (e) {
      if (!mounted) return;
      if (e.kind == ClientErrorKind.unauthorized) return _openAccounts();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${account.serverName}: ${e.message}')),
      );
    }
  }

  Future<void> _play(
    MediaItem item, {
    int? startTicks,
    int? audioIndex,
    int? subtitleIndex,
    bool? burnSubtitles,
  }) async {
    final catalog = widget.catalog;
    if (catalog is! JellyfinCatalog) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This preview contains fictional titles. Connect your server to watch your library.',
          ),
        ),
      );
      return;
    }
    if (item.isSeries || item.type == 'Season') {
      // Series and seasons have no media of their own (the server answers
      // 400); Home hero Play starts the next episode, like Apple TV.
      final MediaItem? next;
      try {
        next = await catalog.nextEpisode(item);
      } on Object {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Couldn’t find an episode of ${item.name} to play.',
              ),
            ),
          );
        }
        return;
      }
      if (!mounted) return;
      if (next == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No episodes of ${item.name} are available.')),
        );
        return;
      }
      item = next;
      startTicks = next.resumeTicks;
    }
    if (_together.isJoined) {
      if (item.isLive) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Leave your group from Profile to watch Live TV.'),
          ),
        );
      } else {
        // The server queues it for everyone, then opens the player here.
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
    await _playerHost.currentState!.open(
      (presentation) => PlayerScreen(
        presentation: presentation,
        catalog: catalog,
        item: item,
        startTicks: startTicks,
        audioIndex: audioIndex,
        subtitleIndex: subtitleIndex ?? PlaybackOptions.automatic,
        burnSubtitles: burnSubtitles ?? false,
        liveCapacityCheck: _extras.features.liveTVAvailability,
        liveStreamsCheck: _extras.features.liveTvStreams,
        group: _together.isJoined ? _together : null,
      ),
    );
    if (mounted) {
      setState(() => _revision++);
      unawaited(widget.state.recommendations.refresh());
    }
  }

  Widget _root() => switch (_destination) {
    Destination.home => HomeScreen(
      key: const ValueKey('home'),
      catalog: widget.catalog,
      onOpen: _open,
      onPlay: _play,
      onAllChannels: () => _select(Destination.live),
      onBrowseCollections: _openCollections,
      extras: _extras,
      revision: _revision,
    ),
    Destination.movies => LibraryScreen(
      key: const ValueKey('movies'),
      catalog: widget.catalog,
      kind: LibraryKind.movies,
      onOpen: _open,
    ),
    Destination.shows => LibraryScreen(
      key: const ValueKey('shows'),
      catalog: widget.catalog,
      kind: LibraryKind.shows,
      onOpen: _open,
    ),
    Destination.live => LiveBrowseScreen(
      key: const ValueKey('live'),
      catalog: widget.catalog,
      extras: _extras,
      onOpen: (channel) => _play(channel),
      onPlay: (channel) => _play(channel),
      tvGuideBuilder: (active) => GuideScreen(
        catalog: widget.catalog,
        onPlay: _play,
        active: active,
        embedded: true,
      ),
    ),
    Destination.requests => RequestsScreen(
      key: _requests,
      extras: _extras,
      onOpen: _open,
    ),
    Destination.search => SearchScreen(
      key: const ValueKey('search'),
      catalog: widget.catalog,
      onOpen: _open,
      onOpenRequests: _showsRequests
          ? () => _select(Destination.requests)
          : null,
    ),
    Destination.profile => ProfileScreen(
      key: const ValueKey('profile'),
      state: widget.state,
      catalog: widget.catalog,
      onTeams: () =>
          _push(TeamsScreen(catalog: widget.catalog, extras: _extras)),
      onNotifications: _openNotificationSettings,
      onSupport: _extras.features.support ? _openSupport : null,
      accountApprovals: _extras.features.accountApprovals,
    ),
  };

  @override
  Widget build(BuildContext context) {
    // The player the host shows sits beside the shell's content, so the
    // scope has to wrap the host for the player to see the server's features.
    return ExtrasScope(extras: _extras, child: _host(context));
  }

  Widget _host(BuildContext context) {
    return InAppPlayerHost(
      key: _playerHost,
      child: Actions(
        actions: {
          BackIntent: ConditionalBackAction(
            canHandle: () =>
                _showNotifications ||
                _path.isNotEmpty ||
                _offTab ||
                _contentFocused,
            onBack: _showNotifications
                ? _closeNotifications
                : _path.isNotEmpty
                ? _back
                : _offTab
                ? _goHome
                : _focusTab,
          ),
        },
        child: ExtrasScope(
          extras: _extras,
          child: ListenableBuilder(
            listenable: _extras,
            builder: (context, _) => Scaffold(
              body: Stack(
                children: [
                  ExcludeFocus(
                    excluding: _showNotifications,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (widget.catalog.isPreview)
                          Container(
                            color: Zoro.panel,
                            padding: const EdgeInsets.symmetric(vertical: 5),
                            alignment: Alignment.center,
                            child: Text(
                              'APP PREVIEW · FICTIONAL LIBRARY',
                              style: Zoro.font(
                                14,
                                weight: FontWeight.w600,
                                color: Zoro.jade,
                              ).copyWith(letterSpacing: 1.3),
                            ),
                          ),
                        Focus(
                          focusNode: _header,
                          child: _Header(
                            destination: _destination,
                            viewerName: widget.catalog.viewerName,
                            photo: widget.catalog.viewerPhoto(width: 96),
                            headers: widget.catalog.imageHeaders,
                            onSelect: _select,
                            onAccountMenu: _accountMenu,
                            avatarKey: _avatar,
                            showRequests: _showsRequests,
                            onSupport: _extras.features.support
                                ? _openSupport
                                : null,
                            onNotifications: _extras.hasNotifications
                                ? _openNotifications
                                : null,
                            unread:
                                widget.state.preferences.value.showUnreadBadge
                                ? _extras.unreadCount
                                : 0,
                            bell: _bell,
                          ),
                        ),
                        Expanded(
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              _layer(
                                0,
                                KeyedSubtree(
                                  key: ValueKey(_destination),
                                  child: _root(),
                                ),
                              ),
                              for (final (i, item) in _path.indexed)
                                _layer(
                                  i + 1,
                                  _FadeIn(
                                    key: ValueKey(
                                      'detail-$i-${item?.id ?? 'collections'}',
                                    ),
                                    child: item == null || item.type == 'BoxSet'
                                        ? CollectionsScreen(
                                            catalog: widget.catalog,
                                            collection: item,
                                            onOpen: _open,
                                            onBack: _back,
                                          )
                                        : DetailScreen(
                                            revision: _revision,
                                            catalog: widget.catalog,
                                            item: item,
                                            onOpen: _open,
                                            onPlay: _play,
                                          ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_checkingLive)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: Zoro.gutter,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            color: Zoro.panel,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 28,
                                height: 28,
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                  color: Zoro.jade,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Text(
                                'Checking Live TV availability…',
                                style: Zoro.font(22),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (_showNotifications) ...[
                    Positioned.fill(
                      child: GestureDetector(
                        onTap: _closeNotifications,
                        child: const ColoredBox(color: Color(0x2E000000)),
                      ),
                    ),
                    Positioned(
                      top: (widget.catalog.isPreview ? 28 : 0) + 106,
                      right: Zoro.gutter,
                      width: 560,
                      height: 650,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: NotificationInbox(
                          extras: _extras,
                          onClose: _closeNotifications,
                          onOpen: (item) {
                            _closeNotifications();
                            _open(item);
                          },
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Apple-style push: the opened title fades and rises in slightly.
class _FadeIn extends StatefulWidget {
  const _FadeIn({super.key, required this.child});

  final Widget child;

  @override
  State<_FadeIn> createState() => _FadeInState();
}

class _FadeInState extends State<_FadeIn> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
    final curve = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    return FadeTransition(
      opacity: curve,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.012),
          end: Offset.zero,
        ).animate(curve),
        child: widget.child,
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.destination,
    required this.viewerName,
    required this.onSelect,
    required this.onAccountMenu,
    this.photo,
    this.headers = const {},
    this.showRequests = false,
    this.onSupport,
    this.onNotifications,
    this.unread = 0,
    this.bell,
    this.avatarKey,
  });

  final Key? avatarKey;
  final Destination destination;
  final String viewerName;
  final ValueChanged<Destination> onSelect;
  final VoidCallback onAccountMenu;
  final Uri? photo;
  final Map<String, String> headers;

  final bool showRequests;

  /// Null when the server has no support or notifications module.
  final VoidCallback? onSupport;
  final VoidCallback? onNotifications;
  final int unread;
  final FocusNode? bell;

  static const _tabs = {
    Destination.home: 'Home',
    Destination.movies: 'Movies',
    Destination.shows: 'TV Shows',
    Destination.live: 'Live TV',
  };

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Zoro.gutter,
          vertical: 16,
        ),
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 30),
              child: Image.asset(
                'assets/images/mark-512.png',
                width: 48,
                height: 48,
                semanticLabel: 'Zorofin',
              ),
            ),
            for (final entry in {
              ..._tabs,
              if (showRequests) Destination.requests: 'Requests',
            }.entries) ...[
              NavButton(
                selected: destination == entry.key,
                label: entry.value,
                onPressed: () => onSelect(entry.key),
                child: (_) => Container(
                  constraints: const BoxConstraints(minHeight: 60),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  alignment: Alignment.center,
                  child: Text(
                    entry.value,
                    style: Zoro.font(
                      22,
                      weight: FontWeight.w600,
                      color: destination == entry.key
                          ? Zoro.background
                          : Zoro.muted,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
            const Spacer(),
            NavButton(
              key: avatarKey,
              label: 'Account menu',
              selected: false,
              onPressed: onAccountMenu,
              child: (_) => SizedBox(
                width: 64,
                height: 64,
                child: Center(
                  child: ProfileAvatar(
                    name: viewerName,
                    size: 48,
                    photo: photo,
                    headers: headers,
                  ),
                ),
              ),
            ),
            if (onSupport != null) ...[
              const SizedBox(width: 6),
              NavButton(
                label: 'Support',
                selected: false,
                onPressed: onSupport!,
                child: (_) => const SizedBox(
                  width: 60,
                  height: 60,
                  child: Icon(
                    Icons.support_agent_rounded,
                    size: 28,
                    color: Zoro.text,
                  ),
                ),
              ),
            ],
            if (onNotifications != null) ...[
              const SizedBox(width: 6),
              NavButton(
                label: 'Notifications, $unread unread updates',
                selected: false,
                focusNode: bell,
                onPressed: onNotifications!,
                child: (_) => SizedBox(
                  width: 60,
                  height: 60,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      const Center(
                        child: Icon(
                          Icons.notifications_none_rounded,
                          size: 30,
                          color: Zoro.text,
                        ),
                      ),
                      if (unread > 0)
                        Positioned(
                          top: 2,
                          right: 0,
                          child: ExcludeSemantics(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Zoro.jade,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                unread > 99 ? '99+' : '$unread',
                                style: Zoro.font(
                                  14,
                                  weight: FontWeight.w700,
                                  color: Zoro.background,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(width: 6),
            NavButton(
              label: 'Search',
              selected: false,
              onPressed: () => onSelect(Destination.search),
              child: (_) => const SizedBox(
                width: 60,
                height: 60,
                child: Icon(Icons.search_rounded, size: 30, color: Zoro.text),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Rounded-square avatar with the viewer's photo, or their initial
/// (Apple `ProfileAvatar`).
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({
    super.key,
    required this.name,
    required this.size,
    this.photo,
    this.headers = const {},
  });

  final String name;
  final double size;
  final Uri? photo;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    final initial = Text(
      name.isEmpty ? '?' : name[0].toUpperCase(),
      style: Zoro.font(size / 2, weight: FontWeight.w700),
    );
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Zoro.avatar,
        borderRadius: BorderRadius.circular(size / 4),
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
