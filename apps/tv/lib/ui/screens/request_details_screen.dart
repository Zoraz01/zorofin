import 'dart:async';

import 'package:flutter/material.dart';
import '../widgets/request_progress.dart';

import '../../core/models.dart';
import '../../core/requests.dart';
import '../../extras_state.dart';
import '../theme.dart';
import '../widgets/focusable.dart';
import '../widgets/section_title.dart';
import 'requests_screen.dart';
import 'settings_screen.dart';

/// One title in Requests (Apple `RequestDetailsView` TV layout): status,
/// season groups and one confirmed request. Pops with true for View request
/// activity.
class RequestDetailsScreen extends StatefulWidget {
  const RequestDetailsScreen({
    super.key,
    required this.extras,
    required this.kind,
    required this.titleId,
    required this.onOpen,
  });

  final ExtrasState extras;
  final RequestKind kind;
  final int titleId;
  final ValueChanged<MediaItem> onOpen;

  @override
  State<RequestDetailsScreen> createState() => _RequestDetailsScreenState();
}

class _RequestDetailsScreenState extends State<RequestDetailsScreen> {
  RequestTitle? _title;
  RequestSeasonSettings? _settings;
  RequestQuota? _quota;
  Set<int> _seasons = {};
  List<RequestJournalEntry> _entries = [];
  RequestActivityItem? _activity;
  String? _download;
  double? _downloadProgress;
  bool _loading = true;
  bool _updating = false;
  bool _sending = false;
  String? _error;
  String? _outcome;
  int? _receiptStatus;
  bool _blocked = false;
  bool _unconfirmed = false;
  bool _initializedChoices = false;
  int _load = 0;
  Timer? _timer;

  ExtrasState get _extras => widget.extras;
  bool get _tv => widget.kind == RequestKind.tv;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!_sending && !_extras.isPreview) unawaited(_reload(quiet: true));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  RequestIntent get _intent => RequestIntent(
    kind: widget.kind,
    id: widget.titleId,
    seasons: _seasons,
    tvdbId: _title?.tvdbId,
  );

  bool get _canSend {
    final title = _title;
    if (_loading ||
        _sending ||
        _blocked ||
        _extras.isPreview ||
        title == null ||
        !_extras.requestsEnabled) {
      return false;
    }
    if (!_tv &&
        (title.mediaInfo?.status4k == 5 ||
            (title.mediaInfo?.requests ?? []).any(
              (r) => const [1, 2].contains(r.status ?? 0),
            ))) {
      return false;
    }
    try {
      _intent.validate(title, settings: _settings, quota: _quota);
      return true;
    } catch (_) {
      return false;
    }
  }

  bool get _movieCanBeRequested {
    final title = _title;
    if (title == null ||
        _tv ||
        _entries.isNotEmpty ||
        _receiptStatus != null ||
        title.mediaInfo?.status4k == 5) {
      return false;
    }
    try {
      RequestIntent(
        kind: RequestKind.movie,
        id: widget.titleId,
      ).validate(title);
      return true;
    } catch (_) {
      return false;
    }
  }

  List<RequestSeason> get _visibleSeasons {
    final minimum = _settings?.enableSpecialEpisodes == true ? 0 : 1;
    return [
      for (final s in _title?.seasons ?? const <RequestSeason>[])
        if (s.seasonNumber >= minimum && (s.episodeCount ?? 0) > 0) s,
    ]..sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));
  }

  RequestSeasonState _state(RequestSeason season) {
    final title = _title;
    if (title == null) return RequestSeasonState.unknown;
    final server = title.requestSeasonState(season.seasonNumber);
    if (server.requestable &&
        _entries.any(
          (e) => (e.intent.seasons ?? []).contains(season.seasonNumber),
        )) {
      return _receiptStatus == 1
          ? RequestSeasonState.pendingApproval
          : RequestSeasonState.requested;
    }
    return server;
  }

  List<RequestSeason> get _missing =>
      _visibleSeasons.where((s) => _state(s).requestable).toList();

  String get _statusLabel {
    final title = _title;
    if (_unconfirmed) return 'Confirmation pending';
    if (_activity?.statusLabel == 'Available') return 'Ready to watch';
    if (_download != null) return _download!;
    if (_activity != null) return _activity!.statusLabel;
    if (_receiptStatus == 1) return 'Awaiting approval';
    if (title != null &&
        (title.mediaInfo?.status == 5 || title.mediaInfo?.status4k == 5)) {
      return 'Ready to watch';
    }
    if (_outcome != null) return _outcome!;
    return title?.status() ?? 'Status unavailable';
  }

  bool get _showsStatus =>
      _unconfirmed ||
      _outcome != null ||
      _activity != null ||
      (_title != null && _title!.status() != 'Not requested') ||
      _title?.mediaInfo?.status4k == 5;

  void _updateSelection() {
    final eligible = _missing.map((s) => s.seasonNumber).toSet();
    if (!_initializedChoices || _settings?.partialRequestsEnabled != true) {
      _seasons = eligible;
    } else {
      _seasons = _seasons.intersection(eligible);
    }
    _initializedChoices = true;
  }

  Future<void> _reload({bool quiet = false}) async {
    if (_updating || _sending) return;
    if (_extras.isPreview) {
      setState(() {
        _title = requestPreviewTitles
            .where((t) => t.id == widget.titleId)
            .firstOrNull;
        _settings = const RequestSeasonSettings(partialRequestsEnabled: true);
        _loading = false;
      });
      return;
    }
    final client = _extras.catalog.client;
    final service = _extras.requestService;
    if (client == null || service == null || !_extras.requestsEnabled) {
      setState(() {
        _loading = false;
        _error = RequestFailure.unavailable.message;
      });
      return;
    }
    final load = ++_load;
    setState(() {
      _updating = true;
      _loading = !quiet && _title == null;
    });
    try {
      final results = await Future.wait([
        client.requestTitle(widget.kind, widget.titleId),
        client.requestQuota(),
      ]);
      final fresh = results[0] as RequestTitle;
      final quota = results[1] as RequestQuota;
      final settings = _tv ? await client.requestSeasonSettings() : null;
      await service.journal.reconcile(fresh);
      final saved = service.journal
          .entries()
          .where(
            (e) =>
                e.intent.id == widget.titleId && e.intent.kind == widget.kind,
          )
          .toList();
      RequestActivityItem? personal;
      String? queueLabel;
      double? queueProgress;
      try {
        final page = await client.requestActivity();
        personal = page.requests
            .where((r) => r.tmdbId == widget.titleId && r.kind == widget.kind)
            .firstOrNull;
        if (personal != null) {
          final download = (await client.requestQueue()).download(personal);
          queueLabel = download?.label;
          queueProgress = download?.progress;
        }
      } catch (_) {}
      if (!mounted || load != _load) return;
      setState(() {
        _title = fresh;
        _quota = quota;
        _settings = settings;
        _entries = saved;
        _activity = personal;
        _download = queueLabel;
        _downloadProgress = queueProgress;
        _error = null;
        _blocked = saved.any((e) => e.receiptId == null);
        _unconfirmed = _blocked;
        if (_blocked) {
          _outcome = null;
        } else if (saved.isNotEmpty) {
          _outcome = 'Request received';
        } else {
          _outcome = null;
          _receiptStatus = null;
        }
        _updateSelection();
      });
    } catch (e) {
      if (mounted && load == _load) {
        setState(() {
          _error = requestErrorMessage(e);
          _blocked = true;
        });
      }
    } finally {
      if (mounted && load == _load) {
        setState(() {
          _updating = false;
          _loading = false;
        });
      }
    }
  }

  Future<void> _confirmSend() async {
    final title = _title;
    if (title == null || !_canSend) return;
    final seasons = (_seasons.toList()..sort())
        .map((n) => n == 0 ? 'Specials' : 'Season $n')
        .join(', ');
    final ok = await confirmDialog(
      context,
      'Request ${title.displayTitle}?',
      'Send request',
      detail: _tv ? seasons : 'Your server manages quality and approval.',
    );
    if (ok) await _send();
  }

  Future<void> _send() async {
    final service = _extras.requestService;
    if (!_canSend || service == null) return;
    _load++;
    setState(() {
      _updating = false;
      _sending = true;
      _error = null;
    });
    try {
      final receipt = await service.submit(_intent);
      if (!mounted) return;
      setState(() {
        _blocked = true;
        _receiptStatus = receipt.status;
        _outcome = 'Request received';
        _sending = false;
      });
      _extras.requestSent();
      await _reload(quiet: true);
    } catch (e) {
      if (!mounted) return;
      final unconfirmed = e == RequestFailure.unconfirmed;
      setState(() {
        _blocked = true;
        _unconfirmed = unconfirmed;
        _sending = false;
      });
      await _reload(quiet: true);
      if (mounted && !unconfirmed) {
        setState(() => _error = requestErrorMessage(e));
      }
    }
  }

  Future<void> _allowRetry() async {
    final service = _extras.requestService;
    if (service == null || _sending) return;
    final ok = await confirmDialog(
      context,
      'Check Activity before trying again',
      'I checked · Allow another attempt',
      detail:
          'The first request may have reached the server. Continue only after checking Activity or confirming with your server owner. Nothing is resent automatically.',
    );
    if (!ok || !mounted) return;
    setState(() => _sending = true);
    try {
      await service.allowAnotherAttempt(widget.kind, widget.titleId);
      if (!mounted) return;
      setState(() {
        _unconfirmed = false;
        _blocked = false;
        _outcome = null;
        _sending = false;
      });
      await _reload();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = requestErrorMessage(e);
          _sending = false;
        });
      }
    }
  }

  Future<void> _openLibrary(String id, {int? season}) async {
    final client = _extras.catalog.client;
    if (client == null) return;
    try {
      var item = await client.item(id);
      if (season != null && item.isSeries) {
        final seasons = await _extras.catalog.seasons(id);
        item =
            seasons.where((s) => s.indexNumber == season).firstOrNull ?? item;
      }
      if (mounted) widget.onOpen(item);
    } catch (e) {
      if (mounted) setState(() => _error = requestErrorMessage(e));
    }
  }

  String? _libraryId(RequestSeason season) {
    final title = _title;
    if (title == null) return null;
    return title.seasonState(season.seasonNumber) ==
            RequestSeasonState.available
        ? title.mediaInfo?.jellyfinMediaId
        : title.mediaInfo?.jellyfinMediaId4k;
  }

  @override
  Widget build(BuildContext context) {
    final title = _title;
    final children = <Widget>[];
    if (_loading) {
      children.add(
        Row(
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
            Text('Loading title…', style: Zoro.font(22)),
          ],
        ),
      );
    }
    if (title != null) {
      children.addAll(_titleContent(title));
    } else if (_error != null && !_loading) {
      children.add(
        StatusMessage(
          title: 'Title unavailable',
          detail: _error!,
          icon: Icons.error_outline_rounded,
          action: ZoroButton(label: 'Try again', onPressed: _reload),
        ),
      );
    }
    return SettingsScaffold(
      title: 'Requests',
      actions: [
        ZoroButton(
          label: 'Done',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ],
      children: children,
    );
  }

  List<Widget> _titleContent(RequestTitle title) {
    final libraryId =
        title.mediaInfo?.jellyfinMediaId ?? title.mediaInfo?.jellyfinMediaId4k;
    final limit = _quota?.limit(widget.kind);
    final remaining = limit?.remaining;
    return [
      Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 200,
              height: 300,
              child: RequestPoster(
                url: RequestArtwork.path(title.posterPath),
                title: title.displayTitle,
              ),
            ),
          ),
          const SizedBox(width: 32),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title.displayTitle,
                  style: Zoro.font(40, weight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                Text(
                  [
                    title.year,
                    _tv ? 'TV show' : 'Movie',
                  ].where((s) => s.isNotEmpty).join(' · '),
                  style: Zoro.font(22, color: Zoro.muted),
                ),
                if (_movieCanBeRequested) ...[
                  const SizedBox(height: 16),
                  _requestButton(autofocus: true),
                ],
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 30),
      if (_showsStatus) ...[_status(), const SizedBox(height: 24)],
      if (_error != null) ...[
        Text(_error!, style: Zoro.font(20, color: Zoro.muted)),
        if (!_unconfirmed)
          Align(
            alignment: Alignment.centerLeft,
            child: ZoroButton(label: 'Try again', onPressed: _reload),
          ),
        const SizedBox(height: 24),
      ],
      if (_tv) ..._seasonGroups(),
      if (_tv && _missing.isNotEmpty) ...[
        Align(
          alignment: Alignment.centerLeft,
          child: _requestButton(autofocus: !_showsStatus),
        ),
        const SizedBox(height: 20),
      ],
      if (_unconfirmed)
        Align(
          alignment: Alignment.centerLeft,
          child: ZoroButton(
            label: 'Review another attempt',
            onPressed: _sending || _updating ? () {} : _allowRetry,
          ),
        ),
      if (remaining != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            '$remaining ${_tv ? 'seasons' : 'movies'} remaining in your ${limit?.days ?? 7}-day request limit.',
            style: Zoro.font(18, color: Zoro.muted),
          ),
        ),
      if (libraryId != null &&
          (!_tv ||
              !_visibleSeasons.any(
                (s) => _state(s) == RequestSeasonState.available,
              )))
        Padding(
          padding: const EdgeInsets.only(top: 20),
          child: Align(
            alignment: Alignment.centerLeft,
            child: ZoroButton(
              label: 'Open in library',
              icon: Icons.play_arrow_rounded,
              autofocus: !_movieCanBeRequested && !_showsStatus,
              onPressed: () => _openLibrary(libraryId),
            ),
          ),
        ),
      if (title.overview case final overview? when overview.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 28),
          child: Text(overview, style: Zoro.font(23).copyWith(height: 1.4)),
        ),
    ];
  }

  Widget _requestButton({bool autofocus = false}) {
    final count = _seasons.length;
    final label = _sending
        ? 'Sending…'
        : _tv
        ? 'Request $count ${count == 1 ? 'season' : 'seasons'}'
        : 'Request movie';
    return Opacity(
      opacity: _canSend ? 1 : 0.45,
      child: ZoroButton(
        label: label,
        icon: Icons.add_rounded,
        primary: true,
        autofocus: autofocus,
        onPressed: _confirmSend,
      ),
    );
  }

  Widget _status() {
    final ready = _statusLabel == 'Ready to watch';
    return FocusTraversalGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Zoro.panel,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _unconfirmed
                      ? Icons.error_outline_rounded
                      : ready
                      ? Icons.check_circle_outline_rounded
                      : Icons.schedule_rounded,
                  color: _unconfirmed ? const Color(0xFFFFD54F) : Zoro.jade,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _statusLabel,
                        style: Zoro.font(26, weight: FontWeight.w600),
                      ),
                      if (_statusLabel.startsWith('Downloading')) ...[
                        const SizedBox(height: 12),
                        LinearProgressIndicator(
                          value: _downloadProgress?.isFinite == true
                              ? (_downloadProgress! / 100).clamp(0, 1)
                              : null,
                        ),
                      ],
                      if (_unconfirmed)
                        Text(
                          'The server may have received your request. We’ll keep checking; nothing is resent automatically.',
                          style: Zoro.font(20, color: Zoro.muted),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (!_unconfirmed) RequestProgress(status: _statusLabel),
          const SizedBox(height: 14),
          ZoroButton(
            label: 'View request activity',
            icon: Icons.arrow_forward_rounded,
            autofocus: !_movieCanBeRequested,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
  }

  List<Widget> _seasonGroups() {
    final seasons = _visibleSeasons;
    final available = seasons
        .where((s) => _state(s) == RequestSeasonState.available)
        .toList();
    final progress = seasons
        .where(
          (s) => const [
            RequestSeasonState.pendingApproval,
            RequestSeasonState.requested,
          ].contains(_state(s)),
        )
        .toList();
    final unknown = seasons
        .where((s) => _state(s) == RequestSeasonState.unknown)
        .toList();
    final missing = _missing;
    final partial = _settings?.partialRequestsEnabled == true;
    return [
      if (available.isNotEmpty) ...[
        _heading('Available to watch', available.length),
        FocusTraversalGroup(
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              for (final season in available)
                if (_libraryId(season) case final id?)
                  ZoroButton(
                    label: season.displayName,
                    icon: Icons.play_arrow_rounded,
                    onPressed: () =>
                        _openLibrary(id, season: season.seasonNumber),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(
                      '✓ ${season.displayName}',
                      style: Zoro.font(22),
                    ),
                  ),
            ],
          ),
        ),
        const SizedBox(height: 28),
      ],
      if (progress.isNotEmpty) ...[
        _heading('Already requested', progress.length),
        for (final season in progress)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Text(season.displayName, style: Zoro.font(22)),
                const Spacer(),
                Text(
                  _unconfirmed ? 'Confirmation pending' : _state(season).label,
                  style: Zoro.font(22, color: Zoro.muted),
                ),
              ],
            ),
          ),
        const SizedBox(height: 28),
      ],
      if (missing.isNotEmpty) ...[
        _heading('Missing seasons', missing.length),
        if (!partial)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Your server requests all missing seasons together.',
              style: Zoro.font(20, color: Zoro.muted),
            ),
          ),
        FocusTraversalGroup(
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final season in missing)
                _SeasonChoice(
                  season: season,
                  selected: _seasons.contains(season.seasonNumber),
                  partlyAvailable:
                      _state(season) == RequestSeasonState.partlyAvailable,
                  label: '${season.displayName}, ${_state(season).label}',
                  enabled: partial && !_sending && !_loading,
                  onPressed: () => setState(() {
                    if (!_seasons.remove(season.seasonNumber)) {
                      _seasons.add(season.seasonNumber);
                    }
                  }),
                ),
            ],
          ),
        ),
        const SizedBox(height: 24),
      ],
      if (unknown.isNotEmpty) ...[
        Text(
          'Availability not confirmed',
          style: Zoro.font(23, weight: FontWeight.w600),
        ),
        Text(
          unknown.map((s) => s.displayName).join(', '),
          style: Zoro.font(22, color: Zoro.muted),
        ),
        const SizedBox(height: 24),
      ],
    ];
  }

  Widget _heading(String text, int count) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: [
        Text(text, style: Zoro.font(26, weight: FontWeight.w600)),
        const Spacer(),
        Text('$count', style: Zoro.font(20, color: Zoro.muted)),
      ],
    ),
  );
}

class _SeasonChoice extends StatelessWidget {
  const _SeasonChoice({
    required this.season,
    required this.selected,
    required this.partlyAvailable,
    required this.label,
    required this.enabled,
    required this.onPressed,
  });

  final RequestSeason season;
  final bool selected;
  final bool partlyAvailable;
  final String label;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Focusable(
    onPressed: enabled ? onPressed : () {},
    semanticLabel: '$label${selected ? ', selected' : ''}',
    builder: (context, focused) => AnimatedContainer(
      duration: Zoro.focusDuration,
      width: 300,
      constraints: const BoxConstraints(minHeight: 72),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: selected ? Zoro.avatar.withValues(alpha: 0.6) : Zoro.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: focused
              ? Zoro.text
              : selected
              ? Zoro.jade
              : Zoro.border,
          width: focused ? 3 : 1,
        ),
      ),
      child: Opacity(
        opacity: enabled ? 1 : 0.7,
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              color: Zoro.jade,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(season.displayName, style: Zoro.font(22)),
                  if (partlyAvailable)
                    Text(
                      'Missing episodes',
                      style: Zoro.font(18, color: Zoro.muted),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
