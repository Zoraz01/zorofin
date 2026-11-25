import 'package:flutter/widgets.dart';

import '../app_state.dart';
import '../core/catalog.dart';
import '../core/models.dart';
import '../core/playback.dart';
import '../extras_state.dart';
import '../watch_together.dart';

/// Phone and tablet sections (Apple `Destination`). The dock shows Home,
/// Search, Requests and Profile; Movies, TV Shows and Live TV open from
/// Home's shortcuts and keep Home selected.
enum PhoneDestination {
  home('Home'),
  movies('Movies'),
  shows('TV Shows'),
  live('Live TV'),
  search('Search'),
  requests('Requests'),
  profile('Profile');

  const PhoneDestination(this.title);

  final String title;

  PhoneDestination get dockItem => switch (this) {
    movies || shows || live => home,
    _ => this,
  };
}

/// What every phone screen reads: the account, its modules and the shell's
/// navigation actions.
class PhoneScope extends InheritedWidget {
  const PhoneScope({
    super.key,
    required this.state,
    required this.catalog,
    required this.extras,
    required this.together,
    required this.open,
    required this.play,
    required this.select,
    required this.push,
    required this.revision,
    required super.child,
  });

  final AppState state;
  final Catalog catalog;
  final ExtrasState extras;
  final WatchTogether together;

  /// Opens a title's details in the current section.
  final ValueChanged<MediaItem> open;
  final PlayItem play;
  final ValueChanged<PhoneDestination> select;

  /// Pushes a full page over the shell (settings, support, inbox…).
  final Future<void> Function(Widget page) push;

  /// Bumped when playback changes watch state, so rows reload.
  final int revision;

  static PhoneScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PhoneScope>()!;

  @override
  bool updateShouldNotify(PhoneScope old) =>
      old.revision != revision ||
      old.catalog != catalog ||
      old.extras != extras ||
      old.together != together;
}
