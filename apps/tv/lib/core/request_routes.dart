import 'jellyfin_client.dart';
import 'requests.dart';

/// Where Requests lives on a server (Apple `RequestRoutes`). `requests`
/// version 1 in the capability manifest is the older Jellyfin Enhanced proxy;
/// version 2 is the Zorofin plugin's own routes. Both return the same shapes,
/// so only the paths differ.
enum RequestRoutes {
  enhanced,
  zorofin;

  static RequestRoutes? fromVersion(Object? version) => switch (version) {
    1 => enhanced,
    2 => zorofin,
    _ => null,
  };

  /// The routes an enabled `requests` manifest entry points to, if any.
  static RequestRoutes? fromManifest(Map features) {
    final feature = features['requests'];
    if (feature is! Map || feature['enabled'] != true) return null;
    return fromVersion(feature['version']);
  }

  List<String> get userStatus => _path(['user-status']);
  List<String> get quota => _path(['quota']);
  List<String> get seasonSettings => _path(['settings', 'partial-requests']);
  List<String> get submit => _path(['request']);
  List<String> get search => _path(['search']);
  List<String> discover(List<String> rest) => _path(['discover', ...rest]);
  List<String> title(RequestKind kind, int id) => _path([kind.name, '$id']);
  List<String> get activity => switch (this) {
    enhanced => ['JellyfinEnhanced', 'arr', 'requests'],
    zorofin => ['Zorofin', 'Requests', 'activity'],
  };
  List<String> get queue => switch (this) {
    enhanced => ['JellyfinEnhanced', 'arr', 'queue'],
    zorofin => ['Zorofin', 'Requests', 'queue'],
  };

  List<String> _path(List<String> rest) => switch (this) {
    enhanced => ['JellyfinEnhanced', 'jellyseerr', ...rest],
    zorofin => ['Zorofin', 'Requests', ...rest],
  };

  static final _known = <String, RequestRoutes>{};

  static String _key(JellyfinClient client) =>
      '${client.server.url}\n${client.session?.viewer.id ?? ''}';

  /// Routes found by the last feature discovery for this server and viewer.
  /// Before discovery, or on a server without the plugin, Requests keeps
  /// using the Jellyfin Enhanced paths.
  static RequestRoutes of(JellyfinClient client) =>
      _known[_key(client)] ?? enhanced;

  static void remember(JellyfinClient client, RequestRoutes? routes) {
    if (routes == null) {
      _known.remove(_key(client));
    } else {
      _known[_key(client)] = routes;
    }
  }
}
