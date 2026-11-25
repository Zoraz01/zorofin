import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/catalog.dart';
import '../../core/media_quality.dart';
import '../../core/models.dart';
import '../../core/preferences.dart';
import '../theme.dart';
import 'focusable.dart';
import 'trailer_preview_card.dart';
import 'home_rail_focus.dart';
import 'section_title.dart';

/// Artwork card matching the Apple TV `MediaCard`: 360-wide 16:9 or 212-wide
/// 2:3 artwork with 12-point corners, a white focus ring and 1.045 lift, and a
/// title and caption below.
class MediaCard extends StatelessWidget {
  const MediaCard({
    super.key,
    required this.item,
    required this.catalog,
    required this.onPressed,
    this.landscape = false,
    this.width,
    this.autofocus = false,
    this.onFocus,
    this.focusNode,
    this.formats,
    this.caption,
    this.preview,
    this.widenOnFocus = false,
  });

  static const posterWidth = 212.0;
  static const landscapeWidth = 360.0;

  /// Default width at the viewer's poster size.
  static double widthFor({
    required bool landscape,
    DevicePreferences prefs = const DevicePreferences(),
  }) => (landscape ? landscapeWidth : posterWidth) * prefs.posterScale;

  /// Card height including captions, for sizing horizontal rows.
  static double heightFor({
    required bool landscape,
    double? width,
    DevicePreferences prefs = const DevicePreferences(),
  }) {
    final w = width ?? widthFor(landscape: landscape, prefs: prefs);
    return w / (landscape ? 16 / 9 : 2 / 3) +
        (prefs.showTitles ? 9 + 34 + 26 : 0);
  }

  final MediaItem item;
  final Catalog catalog;
  final VoidCallback onPressed;
  final bool landscape;
  final double? width;
  final bool autofocus;
  final VoidCallback? onFocus;
  final FocusNode? focusNode;

  /// Server-provided format badges, used in place of the item's own.
  final List<String>? formats;

  /// One context line in place of the year ("85 min", "#1").
  final String? caption;

  final bool widenOnFocus;

  /// Preview video fades over the focused backdrop.
  final Widget? preview;

  String get _caption {
    if (caption != null) return caption!;
    if (item.isEpisode) return item.episodeLabel;
    if (item.productionYear != null) return '${item.productionYear}';
    return item.isLive ? 'Live TV' : '';
  }

  @override
  Widget build(BuildContext context) {
    final prefs = Preferences.valueOf(context);
    final base = width ?? widthFor(landscape: landscape, prefs: prefs);
    final artHeight = base / (landscape ? 16 / 9 : 2 / 3);
    final rating = item.communityRating;
    final badges = prefs.showQualityBadges
        ? (formats?.isNotEmpty ?? false
              ? formats!
              : item.quality().thumbnailBadges)
        : const <String>[];
    return Focusable(
      autofocus: autofocus,
      focusNode: focusNode,
      onPressed: onPressed,
      onFocus: onFocus,
      semanticLabel: item.isEpisode
          ? '${item.displayTitle}, ${item.episodeLabel}'
          : item.name,
      builder: (context, focused) {
        final expanded = widenOnFocus && focused && !landscape;
        final backdrop = expanded
            ? catalog.artwork(item, landscape: true, width: 1280)
            : null;
        return AnimatedContainer(
          duration: prefs.reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 260),
          curve: Curves.easeOut,
          width: expanded ? artHeight * 16 / 9 : base,
          onEnd: () {
            if (!expanded || focusNode?.hasFocus != true || !context.mounted) {
              return;
            }
            final target = context.findRenderObject();
            if (target != null && target.attached) {
              Scrollable.maybeOf(
                context,
                axis: Axis.horizontal,
              )?.position.ensureVisible(
                target,
                alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
                duration: prefs.reduceMotion
                    ? Duration.zero
                    : Zoro.focusDuration,
              );
            }
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedScale(
                scale: Zoro.lift(context, focused, 1.045),
                duration: Zoro.focusDuration,
                child: Container(
                  foregroundDecoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: focused ? Colors.white : Colors.transparent,
                      width: 4,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      height: widenOnFocus ? artHeight : null,
                      width: double.infinity,
                      child: AspectRatio(
                        aspectRatio: landscape ? 16 / 9 : 2 / 3,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Artwork(
                              url: catalog.artwork(
                                item,
                                landscape: landscape,
                                width: landscape ? 720 : 420,
                              ),
                              headers: catalog.imageHeaders,
                              title: item.displayTitle,
                              seed: item.id,
                              showTitle: catalog.isPreview,
                            ),
                            if (backdrop != null)
                              Image.network(
                                backdrop.toString(),
                                headers: catalog.imageHeaders,
                                fit: BoxFit.cover,
                                // Keep the poster underneath until the backdrop decodes.
                                frameBuilder: (_, child, frame, sync) =>
                                    sync || frame != null
                                    ? child
                                    : const SizedBox.shrink(),
                                errorBuilder: (_, _, _) =>
                                    const SizedBox.shrink(),
                              ),
                            ?preview,
                            if (preview == null &&
                                prefs.showRatings &&
                                rating != null &&
                                rating > 0)
                              Positioned(
                                top: 8,
                                right: 8,
                                child: RatingBadge(rating: rating),
                              ),
                            if (preview == null && badges.isNotEmpty)
                              Positioned(
                                left: 8,
                                bottom: 16,
                                child: QualityBadges(badges),
                              ),
                            if (prefs.showProgress && item.progress > 0)
                              Positioned(
                                left: 8,
                                right: 8,
                                bottom: 6,
                                height: 4,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: FractionallySizedBox(
                                    widthFactor: item.progress,
                                    child: ColoredBox(color: Zoro.jade),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (prefs.showTitles) ...[
                const SizedBox(height: 9),
                Text(
                  item.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Zoro.font(22, weight: FontWeight.w600),
                ),
                Text(
                  _caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Zoro.font(17, color: Zoro.muted),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Yellow score and star on a dark capsule (Apple poster rating badge).
class RatingBadge extends StatelessWidget {
  const RatingBadge({super.key, required this.rating});

  final double rating;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Rating ${rating.toStringAsFixed(1)}',
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xD9000000),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, size: 16, color: Color(0xFFFFD60A)),
          const SizedBox(width: 3),
          Text(
            rating.toStringAsFixed(1),
            style: Zoro.font(
              15,
              weight: FontWeight.w700,
              color: const Color(0xFFFFD60A),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Compact source resolution and dynamic-range labels.
class QualityBadges extends StatelessWidget {
  const QualityBadges(this.badges, {super.key, this.size = 13});

  final List<String> badges;
  final double size;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 5,
    runSpacing: 5,
    children: [
      for (final badge in badges)
        Container(
          padding: EdgeInsets.symmetric(horizontal: size / 2, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0xD9000000),
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: const Color(0x66FFFFFF)),
          ),
          child: Text(badge, style: Zoro.font(size, weight: FontWeight.w700)),
        ),
    ],
  );
}

/// Network artwork sent with the viewer's server credentials, falling back to
/// generated preview art (Apple `PreviewArtwork`).
class Artwork extends StatelessWidget {
  const Artwork({
    super.key,
    required this.url,
    required this.headers,
    required this.title,
    required this.seed,
    this.showTitle = false,
    this.fit = BoxFit.cover,
  });

  final Uri? url;
  final Map<String, String> headers;
  final String title;
  final String seed;
  final bool showTitle;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final placeholder = PreviewArtwork(
      title: title,
      seed: seed,
      showTitle: showTitle,
    );
    final source = url;
    if (source == null) return placeholder;
    return Image.network(
      source.toString(),
      headers: headers,
      fit: fit,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => placeholder,
      frameBuilder: (_, child, frame, sync) =>
          sync || frame != null ? child : const ColoredBox(color: Zoro.panel),
    );
  }
}

class PreviewArtwork extends StatelessWidget {
  const PreviewArtwork({
    super.key,
    required this.title,
    required this.seed,
    this.showTitle = true,
  });

  final String title;
  final String seed;
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final hue =
        (utf8.encode(seed).fold<int>(0, (a, b) => a + b) % 90) / 100 + 0.1;
    Color hsb(double h, double s, double b) =>
        HSVColor.fromAHSV(1, (h % 1) * 360, s, b).toColor();
    return LayoutBuilder(
      builder: (context, size) {
        final w = size.maxWidth, h = size.maxHeight;
        return ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      hsb(hue, 0.35, 0.45),
                      const Color(0xFF102421),
                      Colors.black,
                    ],
                  ),
                ),
              ),
              Positioned(
                left: w / 2 - w * 0.23 + w * 0.2,
                top: h / 2 - w * 0.23 - h * 0.16,
                width: w * 0.46,
                height: w * 0.46,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: hsb(hue + 0.08, 0.25, 0.9).withValues(alpha: 0.7),
                  ),
                ),
              ),
              CustomPaint(painter: _Ridge()),
              if (showTitle)
                Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, h * 0.18),
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: w - 32),
                        child: Builder(
                          builder: (context) {
                            final text = title.toUpperCase();
                            final style = _fitWords(
                              context,
                              text,
                              Zoro.font(
                                (w * 0.11).clamp(8, 34),
                                weight: FontWeight.w700,
                                color: const Color(0xE6FFFFFF),
                              ).copyWith(letterSpacing: 2),
                              w - 32,
                            );
                            return Text(
                              text,
                              textAlign: TextAlign.center,
                              style: style,
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Ridge extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final path = Path()
      ..moveTo(0, h * 0.78)
      ..lineTo(w * 0.4, h * 0.35)
      ..lineTo(w, h * 0.88)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0x66000000));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Year, runtime and rating badge (Apple `MetadataLine`).
class MetadataLine extends StatelessWidget {
  const MetadataLine(this.item, {super.key});

  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final style = Zoro.font(22, weight: FontWeight.w500, color: Zoro.muted);
    return Wrap(
      spacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (item.productionYear != null)
          Text('${item.productionYear}', style: style),
        if (item.durationLabel.isNotEmpty)
          Text(item.durationLabel, style: style),
        if (item.officialRating != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0x1FFFFFFF),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(item.officialRating!, style: style),
          ),
      ],
    );
  }
}

/// Horizontally scrolling row with a jade section heading (Apple `MediaShelf`).
class MediaShelf extends StatelessWidget {
  const MediaShelf({
    super.key,
    required this.title,
    required this.items,
    required this.catalog,
    required this.onOpen,
    this.landscape = false,
    this.trailing,
    this.onFocus,
    this.autofocusFirst = false,
    this.previews = false,
  });

  /// Movie and show posters play their trailer when focused (TV Home).
  final bool previews;

  final String title;
  final List<MediaItem> items;
  final Catalog catalog;
  final ValueChanged<MediaItem> onOpen;
  final bool landscape;
  final Widget? trailing;
  final ValueChanged<MediaItem>? onFocus;
  final bool autofocusFirst;

  @override
  Widget build(BuildContext context) {
    return HomeRailFocus(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Zoro.gutter),
            child: SectionTitle(title),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height:
                MediaCard.heightFor(
                  landscape: landscape,
                  prefs: Preferences.valueOf(context),
                ) +
                36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              padding: const EdgeInsets.symmetric(
                horizontal: Zoro.gutter,
                vertical: 18,
              ),
              itemCount: items.length + (trailing == null ? 0 : 1),
              findChildIndexCallback: (key) {
                if (key == const ValueKey('shelf-browse-all')) {
                  return items.length * 2;
                }
                final index = items.indexWhere(
                  (item) => ValueKey(item.id) == key,
                );
                return index < 0 ? null : index * 2;
              },
              separatorBuilder: (_, _) => const SizedBox(width: 28),
              itemBuilder: (context, i) => i == items.length
                  ? SizedBox(
                      key: const ValueKey('shelf-browse-all'),
                      width: MediaCard.widthFor(
                        landscape: landscape,
                        prefs: Preferences.valueOf(context),
                      ),
                      child: Center(child: trailing),
                    )
                  : previews && !landscape
                  ? TrailerPreviewCard(
                      key: ValueKey(items[i].id),
                      item: items[i],
                      catalog: catalog,
                      autofocus: autofocusFirst && i == 0,
                      onFocus: onFocus == null
                          ? null
                          : () => onFocus!(items[i]),
                      onPressed: () => onOpen(items[i]),
                    )
                  : MediaCard(
                      key: ValueKey(items[i].id),
                      item: items[i],
                      catalog: catalog,
                      landscape: landscape,
                      autofocus: autofocusFirst && i == 0,
                      onFocus: onFocus == null
                          ? null
                          : () => onFocus!(items[i]),
                      onPressed: () => onOpen(items[i]),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shrinks [style] so the longest word in [text] fits on one line within
/// [width], so a long title never breaks mid-word.
TextStyle _fitWords(
  BuildContext context,
  String text,
  TextStyle style,
  double width,
) {
  if (width <= 0) return style;
  var widest = 0.0;
  for (final word in text.split(RegExp(r'\s+'))) {
    if (word.isEmpty) continue;
    final painter = TextPainter(
      text: TextSpan(text: word, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    if (painter.width > widest) widest = painter.width;
    painter.dispose();
  }
  if (widest <= width) return style;
  final scale = width / widest * 0.98;
  return style.copyWith(
    fontSize: (style.fontSize ?? 14) * scale,
    letterSpacing: (style.letterSpacing ?? 0) * scale,
  );
}
