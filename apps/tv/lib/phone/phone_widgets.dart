import 'package:flutter/material.dart';

import '../core/catalog.dart';
import '../core/home.dart';
import '../core/media_quality.dart';
import '../core/models.dart';
import '../core/preferences.dart';
import '../ui/player/player_panels.dart' show clockLabel;
import '../ui/widgets/live_score_view.dart';
import '../ui/screens/home_screen.dart' show LiveEventArtworkView;
import '../ui/theme.dart';
import '../ui/widgets/media_card.dart' show Artwork;
import 'phone_theme.dart';
import '../ui/widgets/home_game_card.dart';

/// Capsule button (Apple `ZoroButtonStyle` on iPhone): white for the banner
/// Play, green for detail Play, panel otherwise.
class PillButton extends StatelessWidget {
  const PillButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.primary = false,
    this.white = false,
    this.expand = false,
    this.busy = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool primary;
  final bool white;
  final bool expand;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final foreground = primary || white ? Zoro.background : Zoro.text;
    final background = white
        ? Zoro.text
        : primary
        ? Zoro.play
        : Zoro.panel;
    final content = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (busy)
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: foreground),
          )
        else if (icon != null)
          Icon(icon, size: 20, color: foreground),
        if (busy || icon != null) const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Zoro.font(16, weight: FontWeight.w600, color: foreground),
          ),
        ),
      ],
    );
    return Opacity(
      opacity: onPressed == null ? 0.5 : 1,
      child: Material(
        color: background,
        shape: StadiumBorder(
          side: BorderSide(
            color: primary || white ? Colors.transparent : Zoro.border,
          ),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: busy ? null : onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: Phone.target),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

/// Round icon button with a translucent fill (Apple `ArtworkButtonStyle`).
class RoundIconButton extends StatelessWidget {
  const RoundIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color = Zoro.text,
    this.fill = const Color(0x1FFFFFFF),
    this.size = Phone.target,
    this.badge,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color color;
  final Color fill;
  final double size;
  final String? badge;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    excludeSemantics: true,
    child: Tooltip(
      message: label,
      child: Material(
        color: fill,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: size,
            height: size,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Icon(icon, color: color, size: size * 0.46),
                if (badge != null)
                  Positioned(
                    top: 4,
                    right: 2,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: ShapeDecoration(
                        color: Zoro.jade,
                        shape: StadiumBorder(),
                      ),
                      child: Text(
                        badge!,
                        style: Zoro.font(
                          10,
                          weight: FontWeight.w700,
                          color: Zoro.background,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: Phone.gutter),
    child: Row(
      children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Zoro.font(21, weight: FontWeight.w700),
            ),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

/// Empty, loading and error states (Apple `StatusView`).
class PhoneStatus extends StatelessWidget {
  const PhoneStatus({
    super.key,
    required this.title,
    this.detail,
    this.icon,
    this.action,
  });

  final String title;
  final String? detail;
  final IconData? icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) Icon(icon, size: 36, color: Zoro.muted),
        if (icon != null) const SizedBox(height: 12),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Zoro.font(18, weight: FontWeight.w600),
        ),
        if (detail != null) ...[
          const SizedBox(height: 6),
          Text(
            detail!,
            textAlign: TextAlign.center,
            style: Zoro.font(15, color: Zoro.muted),
          ),
        ],
        if (action != null) ...[const SizedBox(height: 16), action!],
      ],
    ),
  );
}

class PhoneLoading extends StatelessWidget {
  const PhoneLoading({super.key, this.label});

  final String? label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(40),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          if (label != null) ...[
            const SizedBox(height: 14),
            Text(label!, style: Zoro.font(15, color: Zoro.muted)),
          ],
        ],
      ),
    ),
  );
}

/// Initial on the avatar green (Apple `Avatar`), or the viewer's photo.
class PhoneAvatar extends StatelessWidget {
  const PhoneAvatar({
    super.key,
    required this.name,
    this.size = 40,
    this.photo,
    this.headers = const {},
    this.rounded = false,
  });

  final String name;
  final double size;
  final Uri? photo;
  final Map<String, String> headers;
  final bool rounded;

  @override
  Widget build(BuildContext context) {
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    final letter = Center(
      child: Text(
        initial,
        style: Zoro.font(
          size * 0.5,
          weight: FontWeight.w600,
          color: const Color(0xFFE6FFEF),
        ),
      ),
    );
    final shape = rounded
        ? RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(size * .22),
          )
        : const CircleBorder();
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: ShapeDecoration(
        color: Zoro.avatar,
        shape: shape.copyWith(
          side: BorderSide(color: Zoro.jade.withValues(alpha: .35)),
        ),
      ),
      child: photo == null
          ? letter
          : Image.network(
              photo.toString(),
              headers: headers,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => letter,
            ),
    );
  }
}

/// Year, length and age rating (Apple `MetadataLine`).
class PhoneMetadataLine extends StatelessWidget {
  const PhoneMetadataLine(this.item, {super.key, this.size = 14});

  final MediaItem item;
  final double size;

  @override
  Widget build(BuildContext context) {
    final style = Zoro.font(size, weight: FontWeight.w500, color: Zoro.muted);
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (item.productionYear != null)
          Text('${item.productionYear}', style: style),
        if (item.durationLabel.isNotEmpty)
          Text(item.durationLabel, style: style),
        if (item.officialRating case final rating?)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white12,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(rating, style: style),
          ),
      ],
    );
  }
}

/// Artwork card (Apple `MediaCard` on iPhone): rating, quality line and
/// progress over 2:3 or 16:9 artwork, with the title and year below.
class PhoneCard extends StatelessWidget {
  const PhoneCard({
    super.key,
    required this.item,
    required this.catalog,
    required this.onPressed,
    this.landscape = false,
    this.width,
    this.formats,
    this.caption,
    this.onLongPress,
  });

  final MediaItem item;
  final Catalog catalog;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;
  final bool landscape;

  /// Null fills the available width (grids).
  final double? width;
  final List<String>? formats;
  final String? caption;

  static double defaultWidth(
    BuildContext context, {
    required bool landscape,
    DevicePreferences? prefs,
  }) {
    final window = PhoneWindow.of(context);
    final scale = (prefs ?? Preferences.valueOf(context)).posterScale;
    return (landscape ? window.landscapeWidth : window.posterWidth) * scale;
  }

  /// Height of a card including captions, for horizontal rows.
  static double heightFor(
    BuildContext context,
    double width, {
    required bool landscape,
    bool titles = true,
  }) =>
      width / (landscape ? 16 / 9 : 2 / 3) +
      (titles ? captionHeight(context) : 0);

  /// The gap and two caption lines under the artwork, at the reader's text
  /// size. Lines have fixed heights so rows never clip them.
  static double captionHeight(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(12) / 12;
    return 9 + (_titleLine + _captionLine) * scale + 1;
  }

  static const _titleLine = 20.0;
  static const _captionLine = 17.0;

  String get _caption {
    if (caption != null) return caption!;
    if (item.isEpisode) return item.episodeLabel;
    if (item.productionYear != null) return '${item.productionYear}';
    return item.isLive ? 'Live TV' : '';
  }

  @override
  Widget build(BuildContext context) {
    final prefs = Preferences.valueOf(context);
    final rating = item.communityRating;
    final quality = prefs.showQualityBadges
        ? (item.quality().thumbnailBadges.isNotEmpty
              ? item.quality().thumbnailBadges
              : [
                  for (final f in formats ?? const <String>[])
                    f == 'Dolby Vision' ? 'DV' : f,
                ])
        : const <String>[];
    final progress = prefs.showProgress && item.resumeTicks > 0
        ? item.progress
        : 0.0;
    final card = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        AspectRatio(
          aspectRatio: landscape ? 16 / 9 : 2 / 3,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Phone.radius),
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
                if (prefs.showRatings && rating != null && rating > 0)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: _Capsule(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.star_rounded,
                            size: 13,
                            color: Color(0xFFFFD60A),
                          ),
                          const SizedBox(width: 2),
                          Text(
                            rating.toStringAsFixed(1),
                            style: Zoro.font(
                              12,
                              weight: FontWeight.w700,
                              color: const Color(0xFFFFD60A),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (quality.isNotEmpty)
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: progress > 0 ? 16 : 8,
                    child: Align(
                      alignment: Alignment.bottomLeft,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xD1000000),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          quality.join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Zoro.font(10, weight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ),
                if (progress > 0)
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 6,
                    child: LayoutBuilder(
                      builder: (context, size) => Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          height: 4,
                          width: size.maxWidth * progress.clamp(0, 1),
                          color: Zoro.jade,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (prefs.showTitles) ...[
          const SizedBox(height: 9),
          Text(
            item.displayTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Zoro.font(
              15,
              weight: FontWeight.w600,
            ).copyWith(height: _titleLine / 15),
          ),
          Text(
            _caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Zoro.font(
              12,
              color: Zoro.muted,
            ).copyWith(height: _captionLine / 12),
          ),
        ],
      ],
    );
    return Semantics(
      button: true,
      label: item.isEpisode
          ? '${item.displayTitle}, ${item.episodeLabel}'
          : item.name,
      excludeSemantics: true,
      child: SizedBox(
        width: width,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          onLongPress: onLongPress,
          child: card,
        ),
      ),
    );
  }
}

class _Capsule extends StatelessWidget {
  const _Capsule({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
    decoration: const ShapeDecoration(
      color: Color(0xD1000000),
      shape: StadiumBorder(),
    ),
    child: child,
  );
}

/// A titled horizontal row of cards (Apple `MediaShelf`).
class PhoneShelf extends StatelessWidget {
  const PhoneShelf({
    super.key,
    required this.title,
    required this.items,
    required this.catalog,
    required this.onOpen,
    this.landscape = false,
    this.trailing,
  });

  final String title;
  final List<MediaItem> items;
  final Catalog catalog;
  final ValueChanged<MediaItem> onOpen;
  final bool landscape;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final prefs = Preferences.valueOf(context);
    final width = PhoneCard.defaultWidth(
      context,
      landscape: landscape,
      prefs: prefs,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title, trailing: trailing),
        const SizedBox(height: 12),
        SizedBox(
          height:
              PhoneCard.heightFor(
                context,
                width,
                landscape: landscape,
                titles: prefs.showTitles,
              ) +
              6,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
              horizontal: Phone.gutter,
              vertical: 3,
            ),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (context, i) => PhoneCard(
              item: items[i],
              catalog: catalog,
              landscape: landscape,
              width: width,
              onPressed: () => onOpen(items[i]),
            ),
          ),
        ),
      ],
    );
  }
}

/// A personal Home row (Apple `CustomHomeShelf`): episodes and sports use
/// stills, and each card shows its context, length or start time.
class PhoneHomeRowShelf extends StatelessWidget {
  const PhoneHomeRowShelf({
    super.key,
    required this.row,
    required this.catalog,
    required this.now,
    required this.onOpen,
    this.title,
  });

  final HomeFeedRow row;
  final String? title;
  final Catalog catalog;
  final DateTime now;
  final ValueChanged<MediaItem> onOpen;

  @override
  Widget build(BuildContext context) {
    final cards = row.cards.where((c) => !c.isExpired(now)).toList();
    if (cards.isEmpty) return const SizedBox.shrink();
    final prefs = Preferences.valueOf(context);
    final landscape =
        row.id == 'sports' ||
        cards.any((c) => c.item.isEpisode || c.item.isLive);
    final width = PhoneCard.defaultWidth(
      context,
      landscape: landscape,
      prefs: prefs,
    );
    final height = PhoneCard.heightFor(
      context,
      width,
      landscape: landscape,
      titles: prefs.showTitles,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title ?? row.title),
        const SizedBox(height: 12),
        SizedBox(
          height:
              height +
              10 +
              (row.id == 'sports' &&
                      prefs.showTitles &&
                      cards.any((c) => c.game != null)
                  ? MediaQuery.textScalerOf(context).scale(52)
                  : 0),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
              horizontal: Phone.gutter,
              vertical: 3,
            ),
            itemCount: cards.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (context, i) {
              final card = cards[i];
              final start = jellyfinDate(card.startsAt);
              final when = start == null
                  ? null
                  : start.isAfter(now)
                  ? 'Starts ${clockLabel(start)}'
                  : 'On now';
              if (row.id == 'sports' && card.game != null) {
                return HomeGameCard(
                  key: ValueKey(card.id),
                  card: card,
                  catalog: catalog,
                  width: width,
                  small: true,
                  caption: [
                    if (card.subtitle.isNotEmpty) card.subtitle,
                    ?when,
                  ].join(' · '),
                  status: homeGameStatus(card, now, clockLabel),
                  onPressed: () => onOpen(card.item),
                );
              }
              return PhoneCard(
                item: card.item,
                catalog: catalog,
                width: width,
                landscape: landscape,
                caption: when == null
                    ? homeCardLabel(card, row.id)
                    : [
                        if (card.subtitle.isNotEmpty) card.subtitle,
                        when,
                      ].join(' · '),
                formats: card.qualityBadges,
                onPressed: () => onOpen(card.item),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Sports & live events (Apple `LiveEventsShelf` on iPhone).
class PhoneLiveEventsShelf extends StatelessWidget {
  const PhoneLiveEventsShelf({
    super.key,
    required this.events,
    required this.catalog,
    required this.now,
    required this.onOpen,
    required this.onAllChannels,
    this.title = 'Sports & live events',
  });

  final String title;
  final List<LiveEvent> events;
  final Catalog catalog;
  final DateTime now;
  final ValueChanged<LiveEvent> onOpen;
  final VoidCallback onAllChannels;

  static const width = 270.0;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SectionHeader(
        title,
        trailing: TextButton(
          onPressed: onAllChannels,
          style: TextButton.styleFrom(foregroundColor: Zoro.jade),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'All channels',
                style: Zoro.font(15, weight: FontWeight.w600, color: Zoro.jade),
              ),
              const Icon(Icons.chevron_right_rounded, size: 20),
            ],
          ),
        ),
      ),
      const SizedBox(height: 8),
      SizedBox(
        height: width * 9 / 16 + 96,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: Phone.gutter),
          itemCount: events.length,
          separatorBuilder: (_, _) => const SizedBox(width: 14),
          itemBuilder: (context, i) {
            final event = events[i];
            final channel = event.channel;
            return Semantics(
              button: true,
              label:
                  '${event.title}${event.score == null ? '' : ', ${event.score!.text}'}${event.favoriteTeam ? ', favorite team' : ''}, live on ${channel.name}, ${clockLabel(event.start)} to ${clockLabel(event.end)}. Open channel.',
              excludeSemantics: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onOpen(event),
                child: SizedBox(
                  width: width,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: width,
                        height: width * 9 / 16,
                        clipBehavior: Clip.antiAlias,
                        foregroundDecoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(Phone.radius),
                          border: Border.all(color: Zoro.border),
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF151C18),
                          borderRadius: BorderRadius.circular(Phone.radius),
                        ),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (event.score case final score?) ...[
                              LiveEventArtworkView(
                                event: event,
                                catalog: catalog,
                                width: width,
                              ),
                              LiveScoreArt(score: score, scale: 0.64),
                              if (!score.isFinal)
                                const Positioned(
                                  top: 8,
                                  left: 8,
                                  child: LiveScoreBadge(scale: 0.67),
                                ),
                            ] else ...[
                              LiveEventArtworkView(
                                event: event,
                                catalog: catalog,
                                width: width,
                              ),
                              const Positioned(
                                top: 8,
                                left: 8,
                                child: LiveBadge(),
                              ),
                            ],
                            if (event.favoriteTeam)
                              const Positioned(
                                top: 8,
                                right: 8,
                                child: FavoriteTeamBadge(scale: 0.8),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (event.score case final score?)
                        LiveScoreCaption(
                          event: event,
                          score: score,
                          scale: 0.67,
                        )
                      else ...[
                        Text(
                          event.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Zoro.font(15, weight: FontWeight.w600),
                        ),
                        Text(
                          channel.name +
                              (channel.channelNumber == null
                                  ? ''
                                  : ' · Ch ${channel.channelNumber}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Zoro.font(12, color: Zoro.muted),
                        ),
                        Text(
                          '${clockLabel(event.start)} – ${clockLabel(event.end)}',
                          style: Zoro.font(12, color: Zoro.muted),
                        ),
                      ],
                      const SizedBox(height: 5),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: event.progress(now),
                          minHeight: 3,
                          color: Zoro.jade,
                          backgroundColor: Zoro.border,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ],
  );
}

class LiveBadge extends StatelessWidget {
  const LiveBadge({super.key, this.label = 'LIVE'});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: const ShapeDecoration(
      color: Color(0xBF000000),
      shape: StadiumBorder(),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.circle, size: 8, color: Color(0xFFFF453A)),
        const SizedBox(width: 4),
        Text(label, style: Zoro.font(11, weight: FontWeight.w700)),
      ],
    ),
  );
}

/// The quality badges a detail page shows for its source.
List<String> qualityBadgesFor(MediaItem item) => item.quality().badges;

void showPhoneMessage(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
