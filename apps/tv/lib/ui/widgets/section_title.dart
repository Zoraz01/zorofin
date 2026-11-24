import 'package:flutter/material.dart';

import '../theme.dart';

/// Row heading with the jade marker (Apple `SectionTitle`).
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 30,
          decoration: BoxDecoration(
            color: Zoro.jade,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 10),
        Text(title, style: Zoro.font(30, weight: FontWeight.w700)),
      ],
    );
  }
}

/// Empty, error and retry states (Apple `StatusView`).
class StatusMessage extends StatelessWidget {
  const StatusMessage({
    super.key,
    required this.title,
    required this.detail,
    this.icon = Icons.movie_outlined,
    this.action,
  });

  final String title;
  final String detail;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 720),
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Zoro.jade),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Zoro.font(32, weight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: Zoro.font(22, color: Zoro.muted),
            ),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}
