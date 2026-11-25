/// Errors shown to viewers. Messages match the Apple client's wording so the
/// product reads the same on every platform.
enum ClientErrorKind {
  invalidServer,
  insecureServer,
  unsafeUrl,
  invalidResponse,
  unauthorized,
  forbidden,
  unavailable,
  network,
  unsupportedPlayback,
  playbackFailed,
  playbackSync,
  missingSession,
  storage,
}

class ClientError implements Exception {
  const ClientError(this.kind, [this.status]);

  final ClientErrorKind kind;
  final int? status;

  String get message => switch (kind) {
    ClientErrorKind.storage => 'Saved sign-ins are unavailable. Try again.',
    ClientErrorKind.invalidServer =>
      'Enter the server address, including https:// and any base path.',
    ClientErrorKind.insecureServer =>
      'Use HTTPS, or explicitly allow HTTP for a local server.',
    ClientErrorKind.unsafeUrl =>
      'The server returned a resource outside its configured address.',
    ClientErrorKind.invalidResponse =>
      'The server returned an unexpected response.',
    ClientErrorKind.unauthorized =>
      'Your session expired. Please sign in again.',
    ClientErrorKind.forbidden =>
      'Your account does not have permission for this action.',
    ClientErrorKind.unavailable =>
      'The server is unavailable (HTTP $status). Try again.',
    ClientErrorKind.network =>
      'Could not reach the server. Check your connection and try again.',
    ClientErrorKind.playbackSync =>
      'Playback progress is waiting to save. Retry saving before playing another title.',
    ClientErrorKind.playbackFailed =>
      "Could not play this stream. Try again or choose another title or channel.",
    ClientErrorKind.unsupportedPlayback =>
      "The server could not provide a compatible stream for this device. Try another quality.",
    ClientErrorKind.missingSession => 'Sign in to your server to continue.',
  };

  @override
  bool operator ==(Object other) =>
      other is ClientError && other.kind == kind && other.status == status;

  @override
  int get hashCode => Object.hash(kind, status);

  @override
  String toString() => 'ClientError($kind${status == null ? '' : ', $status'})';
}
