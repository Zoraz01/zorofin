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
  missingSession,
}

class ClientError implements Exception {
  const ClientError(this.kind, [this.status]);

  final ClientErrorKind kind;
  final int? status;

  String get message => switch (kind) {
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
    ClientErrorKind.unsupportedPlayback =>
      "This title needs a compatible stream. Check the server's transcoding settings.",
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
