import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/device_playback.dart';
import '../core/errors.dart';
import '../core/jellyfin_client.dart';
import '../core/models.dart';
import '../core/playback.dart';
import '../core/saved_connections.dart';
import '../ui/theme.dart';
import 'phone_player.dart';
import 'phone_scope.dart';
import 'phone_theme.dart';
import 'phone_widgets.dart';

/// Download qualities (Apple `DownloadQuality`): the original file, or a
/// server conversion at a fixed bitrate.
enum DownloadQuality {
  original('Original', null),
  high('High', 20000000),
  standard('Standard', 8000000),
  saver('Data saver', 4000000);

  const DownloadQuality(this.label, this.bitrate);

  final String label;
  final int? bitrate;

  /// The choices offered for a title. A conversion at or near the file's
  /// own bitrate would only be bigger than the original, so it is left out.
  static List<DownloadQuality> choices({
    required bool original,
    int? originalSize,
    double runtimeSeconds = 0,
  }) {
    final sourceBitrate = originalSize != null && runtimeSeconds > 0
        ? originalSize * 8 / runtimeSeconds
        : null;
    final list = [
      for (final q in values)
        if (q == DownloadQuality.original
            ? original
            : sourceBitrate == null || q.bitrate! < sourceBitrate * 0.9)
          q,
    ];
    return list.isEmpty ? [DownloadQuality.saver] : list;
  }
}

enum DownloadState { queued, downloading, done, failed }

class DownloadRecord {
  DownloadRecord({
    required this.itemId,
    required this.account,
    required this.item,
    required this.quality,
    this.state = DownloadState.queued,
    this.received = 0,
    this.total,
    this.file,
    this.poster,
    this.resumeTicks = 0,
    this.played = false,
    this.pendingSync = false,
    this.error,
    this.audioIndex,
    this.subtitleIndex = PlaybackOptions.automatic,
    DateTime? added,
  }) : added = added ?? DateTime.now();

  factory DownloadRecord.fromJson(Map<String, dynamic> json) => DownloadRecord(
    itemId: json['itemId'] as String,
    account: json['account'] as String,
    item: (json['item'] as Map).cast<String, dynamic>(),
    quality: DownloadQuality.values.firstWhere(
      (q) => q.name == json['quality'],
      orElse: () => DownloadQuality.original,
    ),
    state: DownloadState.values.firstWhere(
      (s) => s.name == json['state'],
      orElse: () => DownloadState.failed,
    ),
    received: json['received'] as int? ?? 0,
    total: json['total'] as int?,
    file: json['file'] as String?,
    poster: json['poster'] as String?,
    resumeTicks: json['resumeTicks'] as int? ?? 0,
    played: json['played'] as bool? ?? false,
    pendingSync: json['pendingSync'] as bool? ?? false,
    error: json['error'] as String?,
    audioIndex: json['audioIndex'] as int?,
    subtitleIndex: json['subtitleIndex'] as int? ?? PlaybackOptions.automatic,
    added: DateTime.tryParse(json['added'] as String? ?? ''),
  );

  final String itemId;

  /// Server and viewer; other accounts never see this record.
  final String account;

  /// The title's metadata in Jellyfin's shape, readable offline.
  final Map<String, dynamic> item;
  final DownloadQuality quality;
  DownloadState state;
  int received;
  int? total;

  /// Paths relative to the downloads folder.
  String? file;
  String? poster;
  int resumeTicks;
  bool played;

  /// Offline progress not yet sent to the server.
  bool pendingSync;
  String? error;
  final int? audioIndex;
  final int subtitleIndex;
  final DateTime added;

  MediaItem get media => MediaItem.fromJson(item);

  double? get progress {
    final all = total;
    if (state == DownloadState.done) return 1;
    if (all == null || all <= 0) return null;
    return (received / all).clamp(0, 1);
  }

  Map<String, dynamic> toJson() => {
    'itemId': itemId,
    'account': account,
    'item': item,
    'quality': quality.name,
    'state': state.name,
    'received': received,
    'total': total,
    'file': file,
    'poster': poster,
    'resumeTicks': resumeTicks,
    'played': played,
    'pendingSync': pendingSync,
    'error': error,
    'audioIndex': audioIndex,
    'subtitleIndex': subtitleIndex,
    'added': added.toIso8601String(),
  };
}

/// Saves movies and episodes for offline playback (Apple `DownloadManager`),
/// per server and viewer. Original files are saved when the device can play
/// them; anything else is saved from a server conversion to H.264/AAC MP4.
/// At most two downloads run at once, and one conversion.
class PhoneDownloads extends ChangeNotifier {
  PhoneDownloads._();

  static final instance = PhoneDownloads._();

  Directory? _root;
  final List<DownloadRecord> _all = [];
  JellyfinClient? _client;
  String? _account;
  bool online = true;

  /// The server's answer for this viewer: null while unknown or offline.
  /// Display only; every new download and retry asks the server again.
  bool? permission;
  int _permissionRequest = 0;
  Timer? _probe;
  final Map<String, StreamSubscription<List<int>>> _active = {};
  final Map<String, http.Client> _http = {};
  bool _ready = false;

  static String accountKey(JellyfinClient client) {
    final session = client.session!;
    return '${session.server.storageKey}\n${session.viewer.id}';
  }

  Future<void> _ensureReady() async {
    if (_ready) return;
    _ready = true;
    try {
      final support = await getApplicationSupportDirectory();
      final root = Directory('${support.path}/Zorofin Downloads');
      await root.create(recursive: true);
      _root = root;
      final index = File('${root.path}/catalog.json');
      if (await index.exists()) {
        final data = jsonDecode(await index.readAsString());
        for (final entry in data as List) {
          final record = DownloadRecord.fromJson(
            (entry as Map).cast<String, dynamic>(),
          );
          // Interrupted downloads resume as failed; the viewer retries them.
          if (record.state != DownloadState.done) {
            record.state = DownloadState.failed;
            record.error = 'Interrupted. Tap retry to download again.';
          }
          _all.add(record);
        }
      }
    } catch (_) {
      // Downloads stay unavailable; streaming is unaffected.
    }
    notifyListeners();
  }

  Future<void> _saving = Future.value();

  /// Saves run one at a time: overlapping saves shared the temporary file,
  /// so one rename could find it already moved and that save was lost.
  Future<void> _save() => _saving = _saving.then((_) async {
    final root = _root;
    if (root == null) return;
    try {
      final index = File('${root.path}/catalog.json');
      final temp = File('${index.path}.tmp');
      await temp.writeAsString(jsonEncode([for (final r in _all) r.toJson()]));
      await temp.rename(index.path);
    } on FileSystemException {
      // The next save writes the whole list again.
    }
  });

  /// The signed-in account; null in the preview.
  Future<void> use(JellyfinClient? client) async {
    await _ensureReady();
    _client = client;
    _account = client?.session == null ? null : accountKey(client!);
    _probe?.cancel();
    online = true;
    permission = null;
    _permissionRequest++;
    _permissionChecked = null;
    if (client != null) {
      unawaited(refreshPermission());
      unawaited(_check());
      _probe = Timer.periodic(const Duration(seconds: 30), (_) => _check());
    }
    notifyListeners();
  }

  /// Server reachability: the offline banner and progress sync follow it.
  Future<void> _check() async {
    final client = _client;
    if (client == null) return;
    bool reachable;
    try {
      await client.systemInfo().timeout(const Duration(seconds: 8));
      reachable = true;
    } on ClientError catch (e) {
      reachable = e.kind != ClientErrorKind.network;
    } on TimeoutException {
      reachable = false;
    } catch (_) {
      reachable = true;
    }
    if (reachable != online) {
      online = reachable;
      if (reachable) {
        unawaited(refreshPermission());
      } else {
        permission = null;
        _permissionRequest++;
      }
      notifyListeners();
    }
    if (reachable) {
      unawaited(refreshPermission());
      unawaited(_syncProgress());
    }
  }

  /// Whether Download shows on title pages.
  bool get canDownload => online && permission == true;

  DateTime? _permissionChecked;

  /// Asks again at most every few seconds: title pages call this as they
  /// open, and the reachability probe every 30 seconds.
  Future<void> refreshPermission() async {
    final now = DateTime.now();
    final last = _permissionChecked;
    if (last != null && now.difference(last) < const Duration(seconds: 5)) {
      return;
    }
    _permissionChecked = now;
    try {
      await _allowed();
    } catch (_) {}
  }

  /// Asks the server; any failure or account change counts as not allowed.
  Future<bool> _allowed() async {
    final client = _client;
    if (client == null || client.session == null) {
      throw const ClientError(ClientErrorKind.missingSession);
    }
    final request = ++_permissionRequest;
    try {
      final allowed = await client.contentDownloadPermission();
      if (request != _permissionRequest || client != _client) return false;
      if (permission != allowed) {
        permission = allowed;
        notifyListeners();
      }
      return allowed;
    } catch (_) {
      if (request == _permissionRequest && permission != null) {
        permission = null;
        notifyListeners();
      }
      rethrow;
    }
  }

  List<DownloadRecord> get records => [
    for (final r in _all)
      if (r.account == _account) r,
  ]..sort((a, b) => b.added.compareTo(a.added));

  DownloadRecord? record(String itemId) => _all
      .where((r) => r.account == _account && r.itemId == itemId)
      .firstOrNull;

  DownloadRecord? playable(String itemId) {
    final r = record(itemId);
    return r?.state == DownloadState.done && r?.file != null ? r : null;
  }

  File? fileOf(DownloadRecord record) => _root == null || record.file == null
      ? null
      : File('${_root!.path}/${record.file}');

  File? posterOf(DownloadRecord record) =>
      _root == null || record.poster == null
      ? null
      : File('${_root!.path}/${record.poster}');

  int get usedBytes => records
      .where((r) => r.state == DownloadState.done)
      .fold(0, (sum, r) => sum + (r.total ?? r.received));

  /// Bitrates the server can convert to, and whether the original plays here.
  Future<({bool original, int? originalSize})> options(MediaItem item) async {
    final client = _client;
    if (client == null) return (original: false, originalSize: null);
    final plan = await client.preparePlayback(
      item,
      PlaybackOptions(
        bitrate: 120000000,
        subtitleIndex: -1,
        capabilities: await DevicePlayback.detect(),
      ),
    );
    return (
      original: plan.method == 'DirectPlay',
      originalSize: plan.source?.size,
    );
  }

  Future<void> start(
    MediaItem item,
    DownloadQuality quality, {
    int? audioIndex,
    int subtitleIndex = PlaybackOptions.automatic,
  }) async {
    await _ensureReady();
    final client = _client;
    final account = _account;
    if (client == null || account == null || _root == null) return;
    if (!await _allowed()) {
      throw const ClientError(ClientErrorKind.forbidden);
    }
    if (client != _client || account != _account) return;
    _all.removeWhere((r) => r.account == account && r.itemId == item.id);
    _all.add(
      DownloadRecord(
        itemId: item.id,
        account: account,
        item: _metadata(item),
        quality: quality,
        audioIndex: audioIndex,
        subtitleIndex: subtitleIndex,
        resumeTicks: item.resumeTicks,
        played: item.userData?.played ?? false,
      ),
    );
    notifyListeners();
    await _save();
    _pump();
  }

  Future<void> retry(DownloadRecord record) => start(
    record.media,
    record.quality,
    audioIndex: record.audioIndex,
    subtitleIndex: record.subtitleIndex,
  );

  Map<String, dynamic> _metadata(MediaItem item) => {
    'Id': item.id,
    'Name': item.name,
    'Type': item.type,
    'Overview': ?item.overview,
    'ProductionYear': ?item.productionYear,
    'OfficialRating': ?item.officialRating,
    'CommunityRating': ?item.communityRating,
    'RunTimeTicks': ?item.runTimeTicks,
    'ImageTags': item.imageTags,
    'BackdropImageTags': item.backdropImageTags,
    'SeriesId': ?item.seriesId,
    'SeriesName': ?item.seriesName,
    'SeasonId': ?item.seasonId,
    'IndexNumber': ?item.indexNumber,
    'ParentIndexNumber': ?item.parentIndexNumber,
    'Genres': item.genres,
  };

  /// Starts queued downloads: two at once, one of them a conversion.
  void _pump() {
    final queued = _all.where(
      (r) => r.account == _account && r.state == DownloadState.queued,
    );
    for (final record in queued.toList()) {
      final running = _all.where((r) => r.state == DownloadState.downloading);
      if (running.length >= 2) return;
      final converting = running.any(
        (r) => r.quality != DownloadQuality.original,
      );
      if (record.quality != DownloadQuality.original && converting) continue;
      unawaited(_run(record));
    }
  }

  Future<void> _run(DownloadRecord record) async {
    final client = _client;
    final root = _root;
    final session = client?.session;
    if (client == null || root == null || session == null) return;
    record
      ..state = DownloadState.downloading
      ..received = 0
      ..error = null;
    notifyListeners();
    final folder = Directory(
      '${root.path}/${record.account.hashCode.toUnsigned(32).toRadixString(16)}',
    );
    final transfer = http.Client();
    _http[record.itemId] = transfer;
    try {
      if (!await _allowed()) {
        throw const ClientError(ClientErrorKind.forbidden);
      }
      await folder.create(recursive: true);
      final item = record.media;
      final playback = await client.preparePlayback(
        item,
        PlaybackOptions(
          bitrate: record.quality.bitrate ?? 120000000,
          audioIndex: record.audioIndex,
          subtitleIndex: -1,
          capabilities: await DevicePlayback.detect(),
        ),
      );
      final original =
          record.quality == DownloadQuality.original &&
          playback.method == 'DirectPlay';
      final Uri url;
      final String extension;
      if (original) {
        url = playback.url;
        extension = (playback.source?.container ?? 'mp4')
            .split(',')
            .first
            .toLowerCase();
      } else {
        final bitrate = record.quality.bitrate ?? 20000000;
        final subtitle = record.subtitleIndex >= 0
            ? record.subtitleIndex
            : null;
        final reference = client.server.endpoint(
          ['Videos', item.id, 'stream.ts'],
          {
            'static': 'false',
            'MediaSourceId': playback.sourceId,
            'DeviceId': client.identity.deviceId,
            'PlaySessionId': playback.sessionId,
            'VideoCodec': 'h264',
            'AudioCodec': 'aac',
            'VideoBitrate': '${bitrate - 192000}',
            'AudioBitrate': '192000',
            'MaxAudioChannels': '2',
            'AudioStreamIndex': ?record.audioIndex?.toString(),
            if (subtitle != null) ...{
              'SubtitleStreamIndex': '$subtitle',
              'SubtitleMethod': 'Encode',
            },
          },
        );
        url = client.server.mediaUrl(reference.toString(), session.token);
        // MPEG-TS rather than MP4: a streamed MP4 conversion is fragmented
        // with no index, so the saved file has no duration and can't seek.
        // Android reads a TS file's length from its timestamps.
        extension = 'ts';
      }
      final name = '${item.id}.$extension';
      final file = File('${folder.path}/$name');
      final response = await transfer.send(
        http.Request('GET', url)..headers.addAll(client.authHeaders),
      );
      if (response.statusCode != 200) {
        throw ClientError(ClientErrorKind.unavailable, response.statusCode);
      }
      record.total =
          response.contentLength ?? (original ? playback.source?.size : null);
      final sink = file.openWrite();
      final done = Completer<void>();
      _active[record.itemId] = response.stream.listen(
        (chunk) {
          sink.add(chunk);
          record.received += chunk.length;
          notifyListeners();
        },
        onError: (Object e) {
          if (!done.isCompleted) done.completeError(e);
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );
      try {
        await done.future;
      } finally {
        await sink.close();
      }
      record.total = record.received;
      record.file =
          '${folder.uri.pathSegments.where((s) => s.isNotEmpty).last}/$name';
      await _savePoster(client, record, folder);
      record.state = DownloadState.done;
      if (!original) {
        // The server stops its conversion once the copy is saved.
        await client.stopEncoding(playback);
      }
    } catch (e) {
      if (record.state == DownloadState.downloading) {
        record.state = DownloadState.failed;
        record.error = e is ClientError && e.kind == ClientErrorKind.forbidden
            ? downloadRefusal(e)
            : e is ClientError
            ? e.message
            : 'The download stopped. Check your connection and try again.';
      }
    } finally {
      _active.remove(record.itemId);
      _http.remove(record.itemId)?.close();
      notifyListeners();
      await _save();
      _pump();
    }
  }

  Future<void> _savePoster(
    JellyfinClient client,
    DownloadRecord record,
    Directory folder,
  ) async {
    final item = record.media;
    final tag = item.imageTags['Primary'];
    final id = tag != null ? item.id : item.seriesId;
    if (id == null) return;
    try {
      final response = await http.get(
        client.image(id, tag: tag, width: 420),
        headers: client.authHeaders,
      );
      if (response.statusCode != 200) return;
      final name = '${item.id}.jpg';
      await File('${folder.path}/$name').writeAsBytes(response.bodyBytes);
      record.poster =
          '${folder.uri.pathSegments.where((s) => s.isNotEmpty).last}/$name';
    } catch (_) {}
  }

  Future<void> cancel(String itemId) async {
    final record = this.record(itemId);
    if (record == null) return;
    record.state = DownloadState.failed;
    await _active.remove(itemId)?.cancel();
    _http.remove(itemId)?.close();
    await remove(itemId);
  }

  Future<void> remove(String itemId) async {
    final record = this.record(itemId);
    if (record == null) return;
    if (record.state == DownloadState.downloading) return cancel(itemId);
    for (final f in [fileOf(record), posterOf(record)]) {
      try {
        if (f != null && await f.exists()) await f.delete();
      } catch (_) {}
    }
    _all.remove(record);
    notifyListeners();
    await _save();
  }

  Future<void> removeAll() async {
    for (final r in records) {
      await remove(r.itemId);
    }
  }

  /// Deletes downloads of accounts no longer saved on this device.
  Future<void> prune(Set<String> accounts) async {
    await _ensureReady();
    final gone = _all.where((r) => !accounts.contains(r.account)).toList();
    for (final r in gone) {
      for (final f in [fileOf(r), posterOf(r)]) {
        try {
          if (f != null && await f.exists()) await f.delete();
        } catch (_) {}
      }
      _all.remove(r);
    }
    if (gone.isNotEmpty) {
      notifyListeners();
      await _save();
    }
  }

  /// Offline progress with Jellyfin's resume rules: under 5% starts over,
  /// 90% or more is watched.
  Future<void> saveProgress(DownloadRecord record, Duration position) async {
    final total = record.media.runTimeTicks ?? 0;
    final ticks = MediaTime.ticks(position);
    final share = total > 0 ? ticks / total : 0;
    record
      ..played = record.played || share >= 0.9
      ..resumeTicks = share < 0.05 || share >= 0.9 ? 0 : ticks
      ..pendingSync = true;
    notifyListeners();
    await _save();
    if (online) unawaited(_syncProgress());
  }

  Future<void> _syncProgress() async {
    final client = _client;
    if (client == null) return;
    for (final r in records.where((r) => r.pendingSync)) {
      try {
        await client.requestText(
          ['UserItems', r.itemId, 'UserData'],
          method: 'POST',
          body: {'PlaybackPositionTicks': r.resumeTicks, 'Played': r.played},
        );
        r.pendingSync = false;
      } catch (_) {
        return;
      }
    }
    await _save();
  }
}

/// Download control on movie and episode pages (Apple `DownloadButton`):
/// choose a quality, watch progress, cancel or remove.
class PhoneDownloadButton extends StatefulWidget {
  const PhoneDownloadButton({
    super.key,
    required this.item,
    this.audioIndex,
    this.subtitleIndex = PlaybackOptions.automatic,
    this.refreshPermission = true,
  });

  final bool refreshPermission;
  final MediaItem item;
  final int? audioIndex;
  final int subtitleIndex;

  @override
  State<PhoneDownloadButton> createState() => _PhoneDownloadButtonState();
}

class _PhoneDownloadButtonState extends State<PhoneDownloadButton> {
  @override
  void initState() {
    super.initState();
    // Opening a title page picks up a permission change on the server.
    if (widget.refreshPermission) {
      unawaited(PhoneDownloads.instance.refreshPermission());
    }
  }

  @override
  Widget build(BuildContext context) => _DownloadControl(
    item: widget.item,
    audioIndex: widget.audioIndex,
    subtitleIndex: widget.subtitleIndex,
  );
}

class _DownloadControl extends StatelessWidget {
  const _DownloadControl({
    required this.item,
    required this.audioIndex,
    required this.subtitleIndex,
  });

  final MediaItem item;
  final int? audioIndex;
  final int subtitleIndex;

  Future<void> _choose(BuildContext context) async {
    final downloads = PhoneDownloads.instance;
    final scope = PhoneScope.of(context);
    if (scope.catalog.isPreview) {
      showPhoneMessage(context, 'Connect your server to download titles.');
      return;
    }
    ({bool original, int? originalSize})? options;
    try {
      options = await downloads.options(item);
    } catch (_) {
      if (context.mounted) {
        showPhoneMessage(context, 'Download options couldn’t load. Try again.');
      }
      return;
    }
    if (!context.mounted) return;
    final runtime = (item.runTimeTicks ?? 0) / 10000000;
    final originalSize = options.originalSize;
    final qualities = DownloadQuality.choices(
      original: options.original,
      originalSize: originalSize,
      runtimeSeconds: runtime,
    );
    String size(DownloadQuality q) {
      final bytes = q == DownloadQuality.original
          ? originalSize
          : runtime > 0
          ? (q.bitrate! * runtime / 8).round()
          : null;
      return bytes == null ? '' : ' · about ${formatBytes(bytes)}';
    }

    final choice = await showModalBottomSheet<DownloadQuality>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(top: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  'Download quality',
                  style: Zoro.font(18, weight: FontWeight.w700),
                ),
              ),
              for (final q in qualities)
                ListTile(
                  title: Text(q.label),
                  subtitle: Text(
                    (q.bitrate == null
                            ? 'Same file as the server'
                            : '${q.bitrate! ~/ 1000000} Mbps') +
                        size(q),
                  ),
                  onTap: () => Navigator.of(context).pop(q),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Text(
                  'Keep Zorofin open until the download finishes.',
                  style: Zoro.font(13, color: Zoro.muted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null) return;
    try {
      await downloads.start(
        item,
        choice,
        audioIndex: audioIndex,
        subtitleIndex: subtitleIndex,
      );
    } catch (e) {
      if (context.mounted) showPhoneMessage(context, downloadRefusal(e));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: PhoneDownloads.instance,
    builder: (context, _) {
      final downloads = PhoneDownloads.instance;
      final record = downloads.record(item.id);
      switch (record?.state) {
        case DownloadState.queued || DownloadState.downloading:
          return Semantics(
            button: true,
            label: 'Cancel download',
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => downloads.cancel(item.id),
              child: SizedBox(
                width: Phone.target,
                height: Phone.target,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 30,
                      height: 30,
                      child: CircularProgressIndicator(
                        value: record!.progress,
                        strokeWidth: 3,
                      ),
                    ),
                    const Icon(Icons.stop_rounded, size: 16),
                  ],
                ),
              ),
            ),
          );
        case DownloadState.done:
          return RoundIconButton(
            icon: Icons.download_done_rounded,
            label: 'Downloaded. Remove download',
            color: Zoro.jade,
            onPressed: () async {
              final remove = await showModalBottomSheet<bool>(
                context: context,
                useRootNavigator: true,
                builder: (context) => SafeArea(
                  child: ListTile(
                    leading: const Icon(
                      Icons.delete_outline_rounded,
                      color: Color(0xFFFF8A80),
                    ),
                    title: const Text('Remove download'),
                    onTap: () => Navigator.of(context).pop(true),
                  ),
                ),
              );
              if (remove == true) await downloads.remove(item.id);
            },
          );
        default:
          // Downloads follow the account's permission on the server.
          if (!downloads.canDownload && !scopeIsPreview(context)) {
            return const SizedBox.shrink();
          }
          return RoundIconButton(
            icon: record?.state == DownloadState.failed
                ? Icons.error_outline_rounded
                : Icons.download_rounded,
            label: record?.state == DownloadState.failed
                ? 'Download failed. Try again'
                : 'Download',
            onPressed: () => _choose(context),
          );
      }
    },
  );
}

bool scopeIsPreview(BuildContext context) =>
    PhoneScope.of(context).catalog.isPreview;

/// Why a download didn't start, in the viewer's words.
String downloadRefusal(Object error) =>
    error is ClientError && error.kind == ClientErrorKind.forbidden
    ? 'Downloads are turned off for your account on this server.'
    : 'Couldn’t check whether you can download. Try again.';

String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 10 || unit == 0 ? 0 : 1)} ${units[unit]}';
}

/// Downloads (Apple `DownloadsView`): active and finished downloads, episodes
/// grouped under their show, with remove and retry.
class PhoneDownloadsScreen extends StatefulWidget {
  const PhoneDownloadsScreen({super.key});
  @override
  State<PhoneDownloadsScreen> createState() => _PhoneDownloadsScreenState();
}

class _PhoneDownloadsScreenState extends State<PhoneDownloadsScreen> {
  bool _editing = false;
  final _selected = <String>{};
  String _key(DownloadRecord record) => '${record.account}|${record.itemId}';
  Future<void> _removeSelected() async {
    final downloads = PhoneDownloads.instance;
    final selected = downloads.records
        .where((r) => _selected.contains(_key(r)))
        .toList();
    if (selected.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Remove ${selected.length} downloaded ${selected.length == 1 ? 'title' : 'titles'}?',
        ),
        content: const Text(
          'Selected copies will be removed from this device. Active downloads will be canceled.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    for (final record in selected) {
      if (downloads.records.any((v) => identical(v, record))) {
        await downloads.remove(record.itemId);
      }
    }
    if (mounted) {
      setState(() {
        _selected.clear();
        _editing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      backgroundColor: Zoro.background,
      title: Text('Downloads', style: Zoro.font(18, weight: FontWeight.w600)),
      actions: [
        TextButton(
          onPressed: () => setState(() {
            _editing = !_editing;
            _selected.clear();
          }),
          child: Text(_editing ? 'Done' : 'Edit'),
        ),
      ],
    ),
    body: ListenableBuilder(
      listenable: PhoneDownloads.instance,
      builder: (context, _) {
        final downloads = PhoneDownloads.instance;
        final records = downloads.records;
        if (records.isEmpty) {
          final scope = context
              .dependOnInheritedWidgetOfExactType<PhoneScope>();
          return PhoneStatus(
            action: scope == null
                ? null
                : PillButton(
                    label: 'Browse movies',
                    onPressed: () {
                      Navigator.of(context).maybePop();
                      scope.select(PhoneDestination.movies);
                    },
                  ),
            title: 'No downloads',
            detail:
                'Use the download button on a movie or episode to watch it without a connection.',
            icon: Icons.download_rounded,
          );
        }
        final groups = <String, List<DownloadRecord>>{};
        for (final r in records) {
          final media = r.media;
          groups
              .putIfAbsent(
                media.isEpisode ? (media.seriesName ?? media.name) : '',
                () => [],
              )
              .add(r);
        }
        return ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                '${records.length} ${records.length == 1 ? 'title' : 'titles'} · ${formatBytes(downloads.usedBytes)} used',
                style: Zoro.font(14, color: Zoro.muted),
              ),
            ),
            for (final MapEntry(key: show, value: items) in groups.entries) ...[
              if (show.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                  child: Text(
                    show,
                    style: Zoro.font(17, weight: FontWeight.w700),
                  ),
                ),
              for (final r in items)
                _editing
                    ? CheckboxListTile(
                        title: Text(r.media.name),
                        subtitle: Text(
                          r.media.isEpisode
                              ? r.media.episodeLabel
                              : r.quality.label,
                        ),
                        value: _selected.contains(_key(r)),
                        onChanged: (value) => setState(() {
                          value == true
                              ? _selected.add(_key(r))
                              : _selected.remove(_key(r));
                        }),
                      )
                    : _DownloadRow(record: r),
            ],
            if (_editing)
              Center(
                child: TextButton.icon(
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: Text(
                    'Remove selected (${_selected.intersection(records.map(_key).toSet()).length})',
                  ),
                  onPressed:
                      _selected.intersection(records.map(_key).toSet()).isEmpty
                      ? null
                      : _removeSelected,
                ),
              ),
            const SizedBox(height: 20),
            Center(
              child: TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFFFF8A80),
                ),
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Remove all downloads?'),
                      content: const Text(
                        'Downloaded copies for this account are deleted from this device. Your server library is unchanged.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('Remove all'),
                        ),
                      ],
                    ),
                  );
                  if (ok == true) await downloads.removeAll();
                },
                child: const Text('Remove all downloads'),
              ),
            ),
          ],
        );
      },
    ),
  );
}

class _DownloadRow extends StatelessWidget {
  const _DownloadRow({required this.record});

  final DownloadRecord record;

  @override
  Widget build(BuildContext context) {
    final downloads = PhoneDownloads.instance;
    final media = record.media;
    final poster = downloads.posterOf(record);
    final total = media.runTimeTicks ?? 0;
    final watched = total > 0 ? record.resumeTicks / total : 0.0;
    final subtitle = switch (record.state) {
      DownloadState.done =>
        '${record.quality.label} · ${formatBytes(record.total ?? record.received)}${record.played ? ' · Watched' : ''}',
      DownloadState.downloading =>
        record.total == null
            ? 'Downloading · ${formatBytes(record.received)}'
            : 'Downloading · ${((record.progress ?? 0) * 100).round()}%',
      DownloadState.queued => 'Waiting to download',
      DownloadState.failed => record.error ?? 'Download failed',
    };
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 44,
          height: 66,
          child: poster != null && poster.existsSync()
              ? Image.file(poster, fit: BoxFit.cover)
              : const ColoredBox(
                  color: Zoro.panel,
                  child: Icon(Icons.movie_outlined, color: Zoro.muted),
                ),
        ),
      ),
      title: Text(
        media.isEpisode ? '${media.episodeLabel} · ${media.name}' : media.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Zoro.font(15, weight: FontWeight.w600),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(subtitle, style: Zoro.font(13, color: Zoro.muted)),
          if (record.state == DownloadState.downloading)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: LinearProgressIndicator(value: record.progress),
            )
          else if (record.state == DownloadState.done && watched > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: LinearProgressIndicator(
                value: watched.clamp(0, 1).toDouble(),
                backgroundColor: Zoro.border,
              ),
            ),
        ],
      ),
      trailing: switch (record.state) {
        DownloadState.failed => IconButton(
          tooltip: 'Retry download',
          icon: const Icon(Icons.refresh_rounded),
          onPressed: () async {
            try {
              await downloads.retry(record);
            } catch (e) {
              if (context.mounted) {
                showPhoneMessage(context, downloadRefusal(e));
              }
            }
          },
        ),
        DownloadState.downloading || DownloadState.queued => IconButton(
          tooltip: 'Cancel download',
          icon: const Icon(Icons.close_rounded),
          onPressed: () => downloads.cancel(record.itemId),
        ),
        DownloadState.done => IconButton(
          tooltip: 'Remove download',
          icon: const Icon(Icons.delete_outline_rounded),
          onPressed: () => downloads.remove(record.itemId),
        ),
      },
      onTap: record.state == DownloadState.done
          ? () => openOfflinePlayer(context, record)
          : null,
    );
  }
}

/// Plays a downloaded copy from the device.
Future<void> openOfflinePlayer(BuildContext context, DownloadRecord record) =>
    Navigator.of(context, rootNavigator: true).push(
      PhonePlayerRoute(
        builder: (_) => PhoneOfflinePlayerScreen(record: record),
      ),
    );
