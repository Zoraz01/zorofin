import 'package:flutter/material.dart';

import '../../core/preferences.dart';
import '../theme.dart';

/// One text subtitle cue, styled with the viewer's appearance choices. Null
/// [appearance] is the standard look: white text on a translucent box.
class SubtitleText extends StatelessWidget {
  const SubtitleText(
    this.text, {
    super.key,
    this.appearance,
    this.baseSize = 44,
  });

  final String text;
  final SubtitleAppearance? appearance;

  /// Medium size on the 1920 × 1080 canvas.
  final double baseSize;

  @override
  Widget build(BuildContext context) {
    final style = appearance ?? const SubtitleAppearance();
    final color = style.yellow ? const Color(0xFFFFE34D) : Colors.white;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: style.backgroundOpacity),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style:
            Zoro.font(
              baseSize * style.size / 100,
              weight: style.bold ? FontWeight.w700 : FontWeight.w500,
              color: color,
            ).copyWith(
              height: 1.25,
              shadows: style.backgroundOpacity < 0.5
                  ? const [Shadow(blurRadius: 6, offset: Offset(0, 2))]
                  : null,
            ),
      ),
    );
  }
}
