import 'package:flutter/material.dart';
import '../../core/catalog.dart';
import '../../core/models.dart';
import '../theme.dart';
import 'focusable.dart';
import 'media_card.dart';

class SearchTypeFilters extends StatelessWidget {
  const SearchTypeFilters({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final String value;
  final ValueChanged<String> onChanged;
  static const types = {
    'Movie,Series': 'All',
    'Movie': 'Movies',
    'Series': 'TV shows',
  };
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 10,
    children: [
      for (final entry in types.entries)
        ChoiceChip(
          label: Text(entry.value),
          selected: value == entry.key,
          onSelected: (_) => onChanged(entry.key),
        ),
    ],
  );
}

class SearchResultRow extends StatelessWidget {
  const SearchResultRow({
    super.key,
    required this.item,
    required this.catalog,
    required this.onOpen,
  });
  final MediaItem item;
  final Catalog catalog;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 700;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Focusable(
        semanticLabel:
            '${item.name}, ${item.type == 'Series' ? 'TV show' : 'Movie'}',
        onPressed: onOpen,
        builder: (context, focused) => Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Zoro.panel,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: focused ? Colors.white : Zoro.border,
              width: focused ? 3 : 1,
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: compact ? 112 : 200,
                height: compact ? 63 : 112.5,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Artwork(
                    url: catalog.artwork(item, landscape: true, width: 400),
                    headers: catalog.imageHeaders,
                    title: item.name,
                    seed: item.id,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Zoro.font(
                        compact ? 16 : 24,
                        weight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      [
                        item.type == 'Series' ? 'TV show' : 'Movie',
                        if (item.productionYear != null)
                          '${item.productionYear}',
                      ].join(' · '),
                      style: Zoro.font(compact ? 14 : 18, color: Zoro.muted),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}
