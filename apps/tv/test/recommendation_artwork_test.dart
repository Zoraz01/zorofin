import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zorofin_tv/core/errors.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/server_address.dart';

void main() {
  final server = ServerAddress.parse('https://example.com/base');
  JellyfinClient client(http.Client transport) => JellyfinClient(
    server: server,
    identity: const ClientIdentity(deviceId: 'fixture', deviceName: 'Test'),
    session: Session(
      server: server,
      viewer: Viewer(id: 'viewer', name: 'Fixture'),
      token: 'fictional-token',
      deviceId: 'fixture',
    ),
    httpClient: transport,
  );
  test(
    'recommendation artwork rejects foreign origins before sending auth',
    () async {
      var called = false;
      final c = client(
        MockClient((request) async {
          called = true;
          return http.Response('', 200);
        }),
      );
      await expectLater(
        c.recommendationArtwork(Uri.parse('https://foreign.example/image')),
        throwsA(const ClientError(ClientErrorKind.unsafeUrl)),
      );
      expect(called, false);
    },
  );
  test(
    'recommendation artwork does not follow redirects or return redirect bodies',
    () async {
      final c = client(
        MockClient((request) async {
          expect(request.followRedirects, false);
          expect(request.headers['Authorization'], contains('fictional-token'));
          return http.Response(
            'redirect',
            302,
            headers: {'location': 'https://foreign.example/image'},
          );
        }),
      );
      expect(await c.recommendationArtwork(c.image('item', width: 320)), null);
    },
  );
  test(
    'recommendation artwork bounds bytes even without content length',
    () async {
      final c = client(
        MockClient(
          (request) async =>
              http.Response.bytes(List.filled(2 * 1024 * 1024 + 1, 0), 200),
        ),
      );
      expect(await c.recommendationArtwork(c.image('item', width: 320)), null);
    },
  );
}
