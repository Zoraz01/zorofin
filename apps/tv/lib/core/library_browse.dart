enum LibrarySort {
  recentlyAdded('Recently added', 'DateCreated,SortName', 'Descending'),
  title('Title A–Z', 'SortName', 'Ascending'),
  year('Release year', 'ProductionYear,SortName', 'Descending');

  const LibrarySort(this.label, this.field, this.order);
  final String label, field, order;
}

class LibraryBrowseOptions {
  const LibraryBrowseOptions({
    this.sort = LibrarySort.recentlyAdded,
    this.genre = '',
    this.unwatched = false,
  });
  final LibrarySort sort;
  final String genre;
  final bool unwatched;
  bool get hasFilters =>
      genre.isNotEmpty || unwatched || sort != LibrarySort.recentlyAdded;
}
