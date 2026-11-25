import 'package:flutter/material.dart';
import '../theme.dart';

/// Only the current server state is highlighted. No historical timestamps or
/// completed approval steps are inferred from a successful submission.
class RequestProgress extends StatelessWidget {
  const RequestProgress({super.key, required this.status});
  final String status;
  @override
  Widget build(BuildContext context) {
    final current = status == 'Ready to watch'
        ? 'Ready to watch'
        : const ['Pending approval', 'Awaiting approval'].contains(status)
        ? 'Pending approval'
        : status.startsWith('Download') || status == 'Adding to library'
        ? 'Downloading'
        : const ['Processing', 'Requested'].contains(status)
        ? 'Processing'
        : status == 'Request received'
        ? 'Request received'
        : null;
    if (current == null) return const SizedBox.shrink();
    final steps = [
      'Request received',
      if (current == 'Pending approval') 'Pending approval',
      'Processing',
      'Downloading',
      'Ready to watch',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final step in steps)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Semantics(
                label: '$step${step == current ? ', current status' : ''}',
                excludeSemantics: true,
                child: Row(
                  children: [
                    Icon(
                      step == current
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 20,
                      color: step == current ? Zoro.jade : Zoro.muted,
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        step,
                        style: Zoro.font(
                          16,
                          color: step == current ? Zoro.text : Zoro.muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
