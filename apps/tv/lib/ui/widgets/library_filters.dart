import 'package:flutter/material.dart';
import '../../core/library_browse.dart';
import '../theme.dart';

/// Shared touch/remote controls. Library queries carry the selected options.
class LibraryFilters extends StatelessWidget {
  const LibraryFilters({
    super.key,
    required this.options,
    required this.genres,
    required this.onChanged,
    this.genresFailed = false,
    this.onRetryGenres,
  });
  final LibraryBrowseOptions options;
  final List<String> genres;
  final bool genresFailed;
  final VoidCallback? onRetryGenres;
  final ValueChanged<LibraryBrowseOptions> onChanged;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 12,
    runSpacing: 8,
    children: [
      PopupMenuButton<LibrarySort>(
        tooltip: 'Sort library',
        initialValue: options.sort,
        onSelected: (v) => onChanged(
          LibraryBrowseOptions(
            sort: v,
            genre: options.genre,
            unwatched: options.unwatched,
          ),
        ),
        itemBuilder: (_) => [
          for (final v in LibrarySort.values)
            CheckedPopupMenuItem(
              value: v,
              checked: v == options.sort,
              child: Text(v.label),
            ),
        ],
        child: _label(Icons.sort_rounded, options.sort.label),
      ),
      PopupMenuButton<String>(
        tooltip: 'Filter by genre',
        initialValue: options.genre,
        onSelected: (v) => onChanged(
          LibraryBrowseOptions(
            sort: options.sort,
            genre: v,
            unwatched: options.unwatched,
          ),
        ),
        itemBuilder: (_) => [
          for (final v in ['', ...genres])
            CheckedPopupMenuItem(
              value: v,
              checked: v == options.genre,
              child: Text(v.isEmpty ? 'All genres' : v),
            ),
        ],
        child: _label(
          Icons.filter_list_rounded,
          options.genre.isEmpty ? 'All genres' : options.genre,
        ),
      ),
      FilterChip(
        label: const Text('Unwatched'),
        selected: options.unwatched,
        onSelected: (v) => onChanged(
          LibraryBrowseOptions(
            sort: options.sort,
            genre: options.genre,
            unwatched: v,
          ),
        ),
      ),
      if (options.hasFilters)
        ActionChip(
          label: const Text('Clear filters'),
          onPressed: () => onChanged(const LibraryBrowseOptions()),
        ),
      if (genresFailed)
        ActionChip(label: const Text('Retry genres'), onPressed: onRetryGenres),
    ],
  );
  Widget _label(IconData icon, String text) => Container(
    constraints: const BoxConstraints(minHeight: 48),
    padding: const EdgeInsets.symmetric(horizontal: 14),
    decoration: BoxDecoration(
      color: Zoro.panel,
      border: Border.all(color: Zoro.border),
      borderRadius: BorderRadius.circular(24),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 8),
        Flexible(child: Text(text)),
      ],
    ),
  );
}
