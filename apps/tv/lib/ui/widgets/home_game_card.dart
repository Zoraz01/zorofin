import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../../core/catalog.dart';
import '../../core/home.dart';
import '../../core/models.dart';
import '../../core/preferences.dart';
import '../theme.dart';
import 'focusable.dart';
import 'media_card.dart';

/// Only constructed for a validated sports-row pair. Navigation and fallback
/// artwork still use the original channel.
class HomeGameCard extends StatefulWidget {
  const HomeGameCard({
    super.key,
    required this.card,
    required this.catalog,
    required this.width,
    required this.small,
    required this.caption,
    required this.status,
    required this.onPressed,
  });
  final HomeRowCard card;
  final Catalog catalog;
  final double width;
  final bool small;
  final String? caption;
  final String status;
  final VoidCallback onPressed;
  @override
  State<HomeGameCard> createState() => _HomeGameCardState();
}

class _HomeGameCardState extends State<HomeGameCard> {
  String? _pairKey;
  List<ImageProvider>? _images;

  static Future<Uint8List> _bytes(Uri uri) async {
    File? file;
    if (!kIsWeb) {
      try {
        final dir = await getTemporaryDirectory();
        file = File(
          '${dir.path}/home-crest-${sha256.convert(utf8.encode(uri.toString()))}',
        );
        if (await file.exists() &&
            DateTime.now().difference(await file.lastModified()) <
                const Duration(days: 7)) {
          return await file.readAsBytes();
        }
      } on Exception {
        file = null;
      }
    }
    final response = await http.get(uri).timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw StateError('Crest unavailable');
    }
    if (file != null) {
      try {
        await file.writeAsBytes(response.bodyBytes);
      } on Exception {
        /* Temporary cache unavailable. */
      }
    }
    return response.bodyBytes;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(HomeGameCard old) {
    super.didUpdateWidget(old);
    _resolve();
  }

  void _resolve() {
    final server = widget.catalog.client?.server;
    final paths = widget.card.game!.paths;
    final key = '${server?.url}|${paths.join('|')}';
    if (_pairKey == key) {
      return;
    }
    _pairKey = key;
    _images = null;
    if (server != null) {
      _load(key, [for (final p in paths) server.endpoint(p.split('/'))]);
    }
  }

  Future<void> _load(String key, List<Uri> urls) async {
    try {
      final data = await Future.wait(urls.map(_bytes));
      if (!mounted || key != _pairKey) {
        return;
      }
      final images = [for (final bytes in data) MemoryImage(bytes)];
      var failed = false;
      await Future.wait([
        for (final image in images)
          precacheImage(
            image,
            context,
            onError: (_, _) {
              failed = true;
            },
          ),
      ]);
      if (mounted && key == _pairKey && !failed) {
        setState(() => _images = images);
      }
    } on Exception {
      /* Keep channel art for the whole card. */
    } on StateError {
      /* Resource unavailable. */
    }
  }

  @override
  Widget build(BuildContext context) {
    final images = _images, item = widget.card.item;
    final title = images == null ? item.name : widget.card.game!.title;
    final status = widget.status;
    final small = widget.small;
    return Focusable(
      onPressed: widget.onPressed,
      semanticLabel: images == null
          ? '$title, ${widget.caption ?? status}'
          : '$title, ${item.name}, $status',
      builder: (context, focused) => SizedBox(
        width: widget.width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: focused ? Border.all(color: Zoro.jade, width: 3) : null,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: images == null
                      ? Artwork(
                          url: widget.catalog.artwork(
                            item,
                            landscape: true,
                            width: 720,
                          ),
                          headers: widget.catalog.imageHeaders,
                          title: item.name,
                          seed: item.id,
                        )
                      : DecoratedBox(
                          decoration: const BoxDecoration(
                            gradient: RadialGradient(
                              radius: .85,
                              colors: [Color(0xff2a3530), Color(0xff151b18)],
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              for (final (i, image) in images.indexed) ...[
                                if (i == 1)
                                  Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: widget.width * .035,
                                    ),
                                    child: Text(
                                      'VS',
                                      style: Zoro.font(
                                        small ? 12 : 18,
                                        weight: FontWeight.bold,
                                        color: Colors.white70,
                                      ).copyWith(letterSpacing: 2),
                                    ),
                                  ),
                                Image(
                                  image: image,
                                  width: widget.width * .28,
                                  height: widget.width * 9 / 16 * .56,
                                  fit: BoxFit.contain,
                                  excludeFromSemantics: true,
                                ),
                              ],
                            ],
                          ),
                        ),
                ),
              ),
            ),
            if (Preferences.valueOf(context).showTitles) ...[
              const SizedBox(height: 6),
              Text(
                title,
                maxLines: images == null ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                style: Zoro.font(small ? 15 : 22, weight: FontWeight.w600),
              ),
              Text(
                images == null
                    ? widget.caption ?? widget.card.subtitle
                    : item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Zoro.font(small ? 12 : 17, color: Zoro.muted),
              ),
              if (images != null)
                Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Zoro.font(small ? 12 : 17, color: Zoro.jade),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

String homeGameStatus(
  HomeRowCard card,
  DateTime now,
  String Function(DateTime) clock,
) {
  final start = jellyfinDate(card.startsAt);
  if (start == null) {
    return card.badges.contains('Starting soon') ? 'Starting soon' : 'On now';
  }
  return start.isAfter(now)
      ? 'Starting soon · Starts ${clock(start)}'
      : 'On now';
}
