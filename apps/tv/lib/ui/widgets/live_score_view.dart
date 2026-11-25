import 'package:flutter/material.dart';

import '../../core/home.dart';
import '../../core/live_scores.dart';
import '../theme.dart';

/// The scores over a scored game's matchup art, like the Zorofin site's
/// "Live now" row and the web card (owner approved Nov 9): both teams and
/// their scores at the bottom over a dark fade. [tinted] is the background
/// when there is no matchup art. `scale` 1 is the TV card.
class LiveScoreArt extends StatelessWidget {
  const LiveScoreArt({super.key, required this.score, this.scale = 1});

  final LiveScore score;
  final double scale;

  /// The team-tinted 135° card, only for games without matchup art.
  static Widget tinted(LiveScore score, {Widget? child}) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0xFF000000 | liveScoreTint(score)),
          const Color(0xFF102421),
          Colors.black,
        ],
        stops: const [0, 0.6, 1],
      ),
    ),
    child: child,
  );

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Stack(
      fit: StackFit.expand,
      children: [
        // Bottom-to-top fade so the scores read over any art (same as web).
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Color(0xEB000000), Color(0xA6000000), Color(0x00000000)],
              stops: [0, 0.36, 0.68],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            18 * scale,
            10 * scale,
            18 * scale,
            14 * scale,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _team(
                _name(score.awayName, score.away),
                score.awayScore,
                trailing: score.isFinal && score.homeLeads,
              ),
              SizedBox(height: 2 * scale),
              _team(
                _name(score.homeName, score.home),
                score.homeScore,
                trailing: score.isFinal && score.awayLeads,
              ),
            ],
          ),
        ),
      ],
    ),
  );

  static String _name(String name, String code) => name.isEmpty ? code : name;

  /// [trailing]: the losing side of a final reads muted (same as web).
  Widget _team(String name, String points, {bool trailing = false}) {
    final style = Zoro.font(
      24 * scale,
      weight: FontWeight.w700,
      color: trailing ? Zoro.muted : Zoro.text,
    ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    return Row(
      children: [
        Expanded(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        SizedBox(width: 10 * scale),
        Text(points, style: style),
      ],
    );
  }
}

/// The LIVE tag on a scored card's top-left corner, while the game is on:
/// the same dark pill with a red dot as every other live card.
class LiveScoreBadge extends StatelessWidget {
  const LiveScoreBadge({super.key, this.scale = 1});

  final double scale;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(horizontal: 9 * scale, vertical: 6 * scale),
    decoration: const ShapeDecoration(
      color: Color(0xBF000000),
      shape: StadiumBorder(),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 10 * scale, color: const Color(0xFFFF453A)),
        SizedBox(width: 5 * scale),
        Text(
          'LIVE',
          style: Zoro.font(
            14 * scale,
            weight: FontWeight.w700,
          ).copyWith(letterSpacing: 0.6 * scale),
        ),
      ],
    ),
  );
}

/// Under a scored card: "NBA · Q4 4:12" (or Final), then the channel, with
/// "Your teams" first for the server's favorite teams.
class LiveScoreCaption extends StatelessWidget {
  const LiveScoreCaption({
    super.key,
    required this.event,
    required this.score,
    this.scale = 1,
  });

  final LiveEvent event;
  final LiveScore score;
  final double scale;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          event.scoreStatus ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Zoro.font(21 * scale, weight: FontWeight.w600),
        ),
        Text(
          event.channelLine,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Zoro.font(18 * scale, color: Zoro.muted),
        ),
      ],
    ),
  );
}

/// The star on a card whose game has one of the server's favorite teams.
class FavoriteTeamBadge extends StatelessWidget {
  const FavoriteTeamBadge({super.key, this.scale = 1});

  final double scale;

  @override
  Widget build(BuildContext context) => Container(
    constraints: BoxConstraints(minWidth: 32 * scale, minHeight: 30 * scale),
    padding: EdgeInsets.symmetric(horizontal: 7 * scale),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: const Color(0xBF000000),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Icon(
      Icons.star_rounded,
      size: 20 * scale,
      color: const Color(0xFFFFD60A),
      semanticLabel: 'Favorite team',
    ),
  );
}
