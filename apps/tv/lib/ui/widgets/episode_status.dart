import 'package:flutter/material.dart';
import '../theme.dart';

/// Retains the season controls and a stable content area while a page loads.
class EpisodeStatus extends StatelessWidget {
  const EpisodeStatus({
    super.key,
    required this.title,
    this.detail,
    this.loading = false,
    this.onRetry,
    this.onChooseSeason,
  });
  final String title;
  final String? detail;
  final bool loading;
  final VoidCallback? onRetry, onChooseSeason;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Zoro.panel,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Zoro.font(18, weight: FontWeight.w600)),
          if (detail != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(detail!, style: Zoro.font(15, color: Zoro.muted)),
            ),
          if (loading) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(minHeight: 2),
            ExcludeSemantics(
              child: Column(
                children: [
                  for (var i = 0; i < 3; i++)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Row(
                        children: [
                          Container(width: 96, height: 54, color: Zoro.border),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(height: 12, color: Zoro.border),
                                const SizedBox(height: 10),
                                Container(
                                  width: 96,
                                  height: 10,
                                  color: Zoro.border,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (onRetry != null || onChooseSeason != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  if (onRetry != null)
                    OutlinedButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Try again'),
                    ),
                  if (onChooseSeason != null)
                    OutlinedButton(
                      onPressed: onChooseSeason,
                      child: const Text('Choose another season'),
                    ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
