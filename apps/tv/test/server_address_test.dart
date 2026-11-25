import 'package:flutter_test/flutter_test.dart';
import 'package:zorofin_tv/core/errors.dart';
import 'package:zorofin_tv/core/server_address.dart';

void main() {
  Matcher throwsKind(ClientErrorKind kind) =>
      throwsA(isA<ClientError>().having((e) => e.kind, 'kind', kind));

  test('bare hostnames default to HTTPS with a normalized base path', () {
    final server = ServerAddress.fromUserInput(
      '  Media.Example.com/jellyfin  ',
    );
    expect(server.url.toString(), 'https://media.example.com/jellyfin/');
  });

  test('rejects credentials, queries, fragments and traversal', () {
    for (final input in [
      'https://user:pw@example.com',
      'https://example.com/?x=1',
      'https://example.com/#frag',
      'https://example.com/a/../b',
      'https://example.com/%2e%2e/b',
      'ftp://example.com',
      '',
    ]) {
      expect(
        () => ServerAddress.fromUserInput(input),
        throwsA(isA<ClientError>()),
        reason: input,
      );
    }
  });

  test('HTTP is allowed only for opted-in private hosts', () {
    expect(
      () => ServerAddress.parse('http://example.com'),
      throwsKind(ClientErrorKind.insecureServer),
    );
    expect(
      () => ServerAddress.parse('http://192.168.1.20:8096'),
      throwsKind(ClientErrorKind.insecureServer),
    );
    expect(
      ServerAddress.parse(
        'http://192.168.1.20:8096',
        allowsLocalHttp: true,
      ).url.toString(),
      'http://192.168.1.20:8096/',
    );
    expect(
      () => ServerAddress.parse('http://8.8.8.8', allowsLocalHttp: true),
      throwsKind(ClientErrorKind.insecureServer),
    );
  });

  test('endpoint validates each path component', () {
    final server = ServerAddress.parse('https://example.com/jf');
    expect(
      server.endpoint(['Items', 'abc-1'], {'userId': 'u'}).toString(),
      'https://example.com/jf/Items/abc-1?userId=u',
    );
    expect(
      server.endpoint(['live-tv-logos', 'art', 'events.json']).path,
      '/jf/live-tv-logos/art/events.json',
    );
    for (final bad in ['..', '.', 'a..b', '%2e%2e', 'a/b', 'a\\b']) {
      expect(
        () => server.endpoint([bad]),
        throwsKind(ClientErrorKind.unsafeUrl),
      );
    }
    expect(
      () => server.endpoint(['Items', '../x']),
      throwsKind(ClientErrorKind.unsafeUrl),
    );
    expect(
      () => server.endpoint(['Items', 'a/b']),
      throwsKind(ClientErrorKind.unsafeUrl),
    );
  });

  test('media URLs stay on the server and carry only our token', () {
    final server = ServerAddress.parse('https://example.com/jf');
    final url = server.mediaUrl(
      '/jf/videos/1/master.m3u8?api_key=leak&x=1',
      'tok',
    );
    expect(url.queryParameters['ApiKey'], 'tok');
    expect(url.queryParameters.containsKey('api_key'), isFalse);
    expect(url.queryParameters['x'], '1');
    expect(
      () => server.mediaUrl('https://evil.example/x.m3u8', 'tok'),
      throwsKind(ClientErrorKind.unsafeUrl),
    );
    expect(
      () => server.mediaUrl('/other/x.m3u8', 'tok'),
      throwsKind(ClientErrorKind.unsafeUrl),
    );
  });

  test('round-trips through JSON', () {
    final server = ServerAddress.parse(
      'http://10.0.0.5:8096',
      allowsLocalHttp: true,
    );
    expect(ServerAddress.fromJson(server.toJson()), server);
  });

  test('IP addresses work as server addresses', () {
    expect(
      ServerAddress.fromUserInput('192.168.1.50:8096').url.toString(),
      'https://192.168.1.50:8096/',
    );
    expect(
      ServerAddress.fromUserInput(
        'http://192.168.1.50:8096',
        allowsLocalHttp: true,
      ).url.toString(),
      'http://192.168.1.50:8096/',
    );
    for (final host in [
      '100.101.1.2',
      '169.254.0.9',
      '[fd12:3456::1]',
      '[fe80::1]',
    ]) {
      expect(ServerAddress.isLocalHost(Uri.parse('http://$host').host), isTrue);
    }
    for (final host in ['8.8.8.8', '100.128.0.1', '172.32.0.1']) {
      expect(ServerAddress.isLocalHost(host), isFalse, reason: host);
    }
    expect(
      () => ServerAddress.fromUserInput(
        'http://8.8.8.8:8096',
        allowsLocalHttp: true,
      ),
      throwsKind(ClientErrorKind.insecureServer),
    );
  });
}
