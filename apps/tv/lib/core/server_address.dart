import 'errors.dart';

/// A validated Jellyfin server base URL. Port of the Apple client's
/// `ServerAddress`: HTTPS only unless local HTTP is explicitly allowed, no
/// credentials, query or fragment, and a normalized trailing-slash base path.
class ServerAddress {
  ServerAddress._(this.url, this.allowsLocalHttp);

  final Uri url;
  final bool allowsLocalHttp;

  /// Bare hostnames default to HTTPS, matching the Apple client.
  factory ServerAddress.fromUserInput(
    String input, {
    bool allowsLocalHttp = false,
  }) {
    final text = input.trim();
    if (text.isEmpty) throw const ClientError(ClientErrorKind.invalidServer);
    return ServerAddress.parse(
      text.contains('://') ? text : 'https://$text',
      allowsLocalHttp: allowsLocalHttp,
    );
  }

  factory ServerAddress.parse(String input, {bool allowsLocalHttp = false}) {
    final Uri parts;
    try {
      parts = Uri.parse(input.trim());
    } on FormatException {
      throw const ClientError(ClientErrorKind.invalidServer);
    }
    final scheme = parts.scheme.toLowerCase();
    final rawPath = _rawPath(input.trim());
    if (parts.host.isEmpty ||
        !(scheme == 'https' || scheme == 'http') ||
        parts.userInfo.isNotEmpty ||
        parts.hasQuery ||
        parts.hasFragment ||
        rawPath == null ||
        !isSafePath(rawPath) ||
        (parts.hasPort && (parts.port < 1 || parts.port > 65535))) {
      throw const ClientError(ClientErrorKind.invalidServer);
    }
    if (scheme != 'https' && !(allowsLocalHttp && isLocalHost(parts.host))) {
      throw const ClientError(ClientErrorKind.insecureServer);
    }
    final trimmed = parts.path.replaceAll(RegExp(r'^/+|/+$'), '');
    final path = trimmed.isEmpty ? '/' : '/$trimmed/';
    final url = Uri(
      scheme: scheme,
      host: parts.host.toLowerCase(),
      port: parts.hasPort ? parts.port : null,
      path: path,
    );
    return ServerAddress._(url, allowsLocalHttp);
  }

  static ServerAddress fromJson(Map<String, dynamic> json) =>
      ServerAddress.parse(
        json['url'] as String,
        allowsLocalHttp: json['allowsLocalHttp'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
    'url': url.toString(),
    'allowsLocalHttp': allowsLocalHttp,
  };

  static final _component = RegExp(r'^[A-Za-z0-9_-]+$');

  /// Builds an API URL from strictly validated path components.
  Uri endpoint(List<String> path, [Map<String, String> query = const {}]) {
    for (final component in path) {
      if (!_component.hasMatch(component)) {
        throw const ClientError(ClientErrorKind.unsafeUrl);
      }
    }
    return url.replace(
      path: url.path + path.join('/'),
      queryParameters: query.isEmpty ? null : query,
    );
  }

  /// Scopes credential-bearing requests to this server.
  bool contains(Uri candidate) {
    int port(Uri u) => u.hasPort ? u.port : (u.scheme == 'https' ? 443 : 80);
    return candidate.scheme.toLowerCase() == url.scheme &&
        candidate.host.toLowerCase() == url.host &&
        port(candidate) == port(url) &&
        candidate.userInfo.isEmpty &&
        !candidate.hasFragment &&
        isSafePath(candidate.path) &&
        candidate.path.startsWith(url.path);
  }

  /// Resolves a server-provided media reference and attaches the token,
  /// removing any token the server tried to embed.
  Uri mediaUrl(String reference, String token) {
    if (reference.contains(r'\')) {
      throw const ClientError(ClientErrorKind.unsafeUrl);
    }
    final target = url.resolve(reference);
    if (!contains(target)) throw const ClientError(ClientErrorKind.unsafeUrl);
    const forbidden = {
      'apikey',
      'api_key',
      'x-emby-token',
      'token',
      'access_token',
    };
    final query = <String, List<String>>{
      for (final entry in target.queryParametersAll.entries)
        if (!forbidden.contains(entry.key.toLowerCase()))
          entry.key: entry.value,
      'ApiKey': [token],
    };
    return target.replace(queryParameters: query);
  }

  /// Extracts the still-encoded path so encoded traversal can be rejected.
  static String? _rawPath(String input) {
    final match = RegExp(
      r'^[A-Za-z][A-Za-z0-9+.-]*://[^/?#]*([^?#]*)',
    ).firstMatch(input);
    return match?.group(1);
  }

  static bool isSafePath(String path) {
    var decoded = path;
    for (var i = 0; i < 3; i++) {
      if (decoded.contains(r'\') ||
          decoded.codeUnits.any((c) => c < 32) ||
          decoded.split('/').any((s) => s == '.' || s == '..')) {
        return false;
      }
      String next;
      try {
        next = Uri.decodeComponent(decoded);
      } on ArgumentError {
        return false;
      }
      if (next == decoded) return true;
      decoded = next;
    }
    return !decoded.contains('%');
  }

  static bool isLocalHost(String value) {
    final host = value.toLowerCase();
    if (host == 'localhost' ||
        host == '::1' ||
        host == '[::1]' ||
        host.endsWith('.local')) {
      return true;
    }
    // IPv6 unique-local (fc00::/7) and link-local (fe80::/10) addresses.
    final v6 = host.replaceAll(RegExp(r'^\[|\]$'), '');
    if (v6.contains(':')) {
      return RegExp(r'^f[cd][0-9a-f]{0,2}:').hasMatch(v6) ||
          RegExp(r'^fe[89ab][0-9a-f]?:').hasMatch(v6);
    }
    final parts = host.split('.');
    if (parts.length != 4 ||
        parts.any((p) => p.isEmpty || !RegExp(r'^\d+$').hasMatch(p))) {
      return false;
    }
    final o = parts.map(int.parse).toList();
    if (o.any((v) => v > 255)) return false;
    return o[0] == 10 ||
        o[0] == 127 ||
        (o[0] == 192 && o[1] == 168) ||
        (o[0] == 172 && o[1] >= 16 && o[1] <= 31) ||
        (o[0] == 169 && o[1] == 254) ||
        // Carrier-grade NAT range, used by Tailscale and similar VPNs.
        (o[0] == 100 && o[1] >= 64 && o[1] <= 127);
  }

  @override
  bool operator ==(Object other) =>
      other is ServerAddress &&
      other.url == url &&
      other.allowsLocalHttp == allowsLocalHttp;

  @override
  int get hashCode => Object.hash(url, allowsLocalHttp);

  @override
  String toString() => url.toString();
}
