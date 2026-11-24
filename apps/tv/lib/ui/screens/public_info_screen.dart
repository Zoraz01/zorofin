import 'package:flutter/material.dart';

import '../../core/public_info.dart';
import '../theme.dart';
import '../widgets/focusable.dart';

/// Privacy Policy, App Support or Sample Media Credits (Apple
/// `PublicInformationView`). Paragraphs take focus so the remote can scroll
/// through long text.
class PublicInfoScreen extends StatelessWidget {
  const PublicInfoScreen({super.key, required this.page});

  final PublicDocument page;

  @override
  Widget build(BuildContext context) {
    final body = Zoro.font(24).copyWith(height: 1.4);
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Zoro.gutter, 24, Zoro.gutter, 8),
            child: Row(
              children: [
                const Spacer(),
                ZoroButton(
                  label: 'Done',
                  autofocus: true,
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                Zoro.gutter,
                0,
                Zoro.gutter,
                48,
              ),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 920),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          page.title,
                          style: Zoro.font(40, weight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Updated ${PublicDocument.updated}',
                          style: Zoro.font(18, color: Zoro.muted),
                        ),
                        const SizedBox(height: 24),
                        _Paragraph(page.intro, style: body),
                        for (final (title, paragraphs) in page.sections) ...[
                          const SizedBox(height: 24),
                          Text(
                            title,
                            style: Zoro.font(26, weight: FontWeight.w700),
                          ),
                          const SizedBox(height: 12),
                          for (final p in paragraphs)
                            _Paragraph(p, style: body),
                        ],
                        const SizedBox(height: 24),
                        if (page == PublicDocument.support) ...[
                          ZoroButton(
                            label: 'Sample media credits',
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const PublicInfoScreen(
                                  page: PublicDocument.credits,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),
                        ],
                        Text(
                          PublicDocument.contact,
                          style: body.copyWith(color: Zoro.jade),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Paragraph extends StatelessWidget {
  const _Paragraph(this.text, {required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Focusable(
      onPressed: () {},
      semanticLabel: text,
      builder: (context, focused) => AnimatedContainer(
        duration: Zoro.focusDuration,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: focused ? Zoro.panel : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(text, style: style),
      ),
    ),
  );
}
