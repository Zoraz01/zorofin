import 'package:flutter/material.dart';

import '../core/public_info.dart';
import '../ui/theme.dart';
import 'phone_theme.dart';

/// Privacy Policy, App Support and credits, readable offline.
class PhoneInfoScreen extends StatelessWidget {
  const PhoneInfoScreen({super.key, required this.page});

  final PublicDocument page;

  @override
  Widget build(BuildContext context) {
    final body = Zoro.font(15, color: Zoro.muted).copyWith(height: 1.45);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Zoro.background,
        title: Text(page.title, style: Zoro.font(18, weight: FontWeight.w600)),
      ),
      body: SelectionArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            Phone.gutter + 4,
            8,
            Phone.gutter + 4,
            40,
          ),
          children: [
            Text(page.intro, style: body.copyWith(color: Zoro.text)),
            for (final (heading, paragraphs) in page.sections) ...[
              const SizedBox(height: 22),
              Text(heading, style: Zoro.font(17, weight: FontWeight.w600)),
              const SizedBox(height: 8),
              for (final p in paragraphs)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(p, style: body),
                ),
            ],
            const SizedBox(height: 16),
            Text('Contact: ${PublicDocument.contact}', style: body),
          ],
        ),
      ),
    );
  }
}

Future<void> openPublicDocument(BuildContext context, PublicDocument page) =>
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => PhoneInfoScreen(page: page)),
    );
