import 'dart:convert';
import 'package:video_player/video_player.dart';
import 'package:zorofin_tv/core/device_playback.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zorofin_tv/core/playback.dart';
import 'package:zorofin_tv/core/playback_capabilities.dart';
import 'package:zorofin_tv/core/models.dart';
import 'package:zorofin_tv/core/jellyfin_client.dart';
import 'package:zorofin_tv/core/server_address.dart';

void main() {
  test('explicit audio can stay direct only on a player that selects it', () {
    final requested = PlaybackOptions(audioIndex: 1);
    expect(PlaybackProfile.request('u', requested)['EnableDirectPlay'], false);
    final local = requested.copyWith(selectAudioOnDevice: true);
    expect(PlaybackProfile.request('u', local)['EnableDirectPlay'], true);
    expect(PlaybackProfile.request('u', local)['AudioStreamIndex'], 1);
    expect(
      local.copyWith(subtitleIndex: 4, burnSubtitles: true).needsTranscode,
      true,
    );
    expect(
      PlaybackProfile.request(
        'u',
        local.copyWith(allowDirectPlay: false),
      )['EnableDirectPlay'],
      false,
    );
  });

  test(
    'map explicit tracks by unique language, never by native list order',
    () {
      final ja = MediaStream(
        index: 1,
        type: 'Audio',
        language: 'jpn',
        codec: 'dts',
      );
      final en = MediaStream(
        index: 2,
        type: 'Audio',
        language: 'eng',
        codec: 'ac3',
      );
      const japanese = VideoAudioTrack(
        id: '2_0',
        isSelected: true,
        language: 'ja',
      );
      const english = VideoAudioTrack(
        id: '1_0',
        isSelected: false,
        language: 'en',
      );
      const tracks = [english, japanese];
      expect(DevicePlayback.matchAudioTrack([ja, en], 1, tracks), japanese);
      expect(DevicePlayback.matchAudioTrack([ja, en], 2, tracks), english);
      final commentary = MediaStream(index: 3, type: 'Audio', language: 'jpn');
      expect(
        DevicePlayback.matchAudioTrack([ja, en, commentary], 1, tracks),
        isNull,
      );
      expect(DevicePlayback.matchAudioTrack([ja, en], 1, [english]), isNull);
      expect(
        DevicePlayback.matchAudioTrack([ja, en], 1, [...tracks, japanese]),
        isNull,
      );
      expect(DevicePlayback.matchAudioTrack([ja, en], 3, tracks), isNull);
    },
  );
  PlaybackCapabilities lg({bool uhd = true}) => PlaybackCapabilities.fromJson({
    'platform': 'lg',
    'packaged': true,
    'sdkVersion': '10.0.0',
    'uhd': uhd,
    'hdr10': true,
  });
  test(
    'players that draw PGS get it External; LG web only with its renderer',
    () {
      List<String> subtitles(PlaybackCapabilities c) => [
        for (final p
            in PlaybackProfile.forDevice(
                  PlaybackOptions(capabilities: c),
                )['SubtitleProfiles']
                as List)
          '${p['Format']}:${p['Method']}',
      ];
      final withRenderer = PlaybackCapabilities.fromJson({
        'platform': 'lg',
        'packaged': true,
        'sdkVersion': '10.0.0',
        'pgs': true,
      });
      expect(withRenderer.pgsSubtitles, isTrue);
      expect(subtitles(withRenderer), contains('pgssub:External'));
      expect(subtitles(withRenderer), contains('dvdsub:Encode'));
      expect(lg().pgsSubtitles, isFalse);
      expect(subtitles(withRenderer), isNot(contains('ass:External')));
      expect(
        MediaStream.fromJson({
          'Index': 4,
          'Type': 'Subtitle',
          'Codec': 'ASS',
        }).isStyled,
        isTrue,
      );
      expect(subtitles(lg()), contains('pgssub:Encode'));
      expect(
        subtitles(PlaybackCapabilities.samsungTv()),
        containsAll(['pgssub:External', 'ass:External', 'dvdsub:Encode']),
      );
      final pgs = MediaStream.fromJson({
        'Index': 3,
        'Type': 'Subtitle',
        'Codec': 'PGSSUB',
      });
      final srt = MediaStream.fromJson({
        'Index': 4,
        'Type': 'Subtitle',
        'Codec': 'subrip',
      });
      final episode = MediaItem.fromJson({
        'Id': 'episode',
        'Type': 'Episode',
        'MediaStreams': [
          {'Index': 3, 'Type': 'Subtitle', 'Codec': 'PGSSUB'},
        ],
      });
      final selected = PlaybackOptions(subtitleIndex: 3, burnSubtitles: true);
      expect(
        selected.withDeviceCapabilities(withRenderer, episode).needsTranscode,
        isFalse,
      );
      expect(
        selected.withDeviceCapabilities(lg(), episode).burnSubtitles,
        isTrue,
      );
      expect(pgs.isPgs, isTrue);
      expect(srt.isPgs, isFalse);
    },
  );
  test('Samsung TV prefers compatible MKV and HEVC without assuming UHD', () {
    final samsung = PlaybackCapabilities.samsungTv();
    final body = PlaybackProfile.request(
      'viewer',
      PlaybackOptions(capabilities: samsung),
    );
    final profile = body['DeviceProfile'] as Map;
    final direct = (profile['DirectPlayProfiles'] as List).single as Map;
    expect(direct['Container'], contains('mkv'));
    expect(direct['VideoCodec'], 'h264,hevc');
    expect(direct['AudioCodec'], 'aac,ac3,eac3');
    expect(samsung.videos['hevc']!.height, 1080);
    expect(samsung.videos['hevc']!.rangeTypes, 'SDR');
    expect(
      PlaybackCapabilities.samsungTv(uhd: true).videos['hevc']!.height,
      2160,
    );
    expect(body['EnableDirectPlay'], true);
  });
  test('Samsung compatibility retry disables direct play and allows remux', () {
    final options = PlaybackOptions(
      startTicks: 12000000,
      audioIndex: 1,
      subtitleIndex: -1,
    ).copyWith(allowDirectPlay: false);
    final request = PlaybackProfile.request('viewer', options);
    expect(request['StartTimeTicks'], 12000000);
    expect(request['AudioStreamIndex'], 1);
    expect(request['EnableDirectPlay'], false);
    expect(request['EnableDirectStream'], true);
    expect(request['AllowVideoStreamCopy'], true);
    final profile = request['DeviceProfile'] as Map;
    expect(
      (profile['TranscodingProfiles'] as List).single['VideoCodec'],
      'h264',
    );
  });
  test(
    'LG UHD uses 4K HEVC Main10 and multichannel EAC3, not UI resolution',
    () {
      final body = PlaybackProfile.request(
        'u',
        PlaybackOptions(capabilities: lg(), bitrate: 60000000),
      );
      final profile = body['DeviceProfile'] as Map;
      final direct = (profile['DirectPlayProfiles'] as List).first as Map;
      expect(direct['Container'], isNot(contains('mkv')));
      expect(direct['VideoCodec'], contains('hevc'));
      expect(direct['AudioCodec'], contains('eac3'));
      expect(body['MaxAudioChannels'], 6);
      expect(body['EnableDirectStream'], true);
      final codecs = profile['CodecProfiles'] as List;
      final hevc = codecs.firstWhere((c) => c['Codec'] == 'hevc');
      expect(hevc['Conditions'], contains(containsPair('Value', '2160')));
      expect(hevc['Conditions'], contains(containsPair('Value', '10')));
      expect(jsonEncode(profile), isNot(contains('DOVI')));
      expect(lg(uhd: false).videos['hevc']!.height, 1080);
    },
  );
  test('LG accepts HD sports at 60fps while retaining the 4K H264 limit', () {
    final profiles =
        PlaybackProfile.forDevice(
              PlaybackOptions(capabilities: lg()),
            )['CodecProfiles']
            as List;
    bool accepts(String codec, int width, int height, int fps) {
      final values = {'Width': width, 'Height': height, 'VideoFramerate': fps};
      bool passes(dynamic c) {
        final actual = values[c['Property']];
        if (actual == null) return true;
        final limit = int.parse(c['Value'] as String);
        return c['Condition'] == 'GreaterThanEqual'
            ? actual >= limit
            : actual <= limit;
      }

      return profiles
          .where(
            (p) =>
                p['Codec'] == codec &&
                ((p['ApplyConditions'] as List?) ?? []).every(passes),
          )
          .every((p) => (p['Conditions'] as List).every(passes));
    }

    expect(accepts('h264', 1920, 1080, 60), true);
    expect(accepts('h264', 3840, 2160, 30), true);
    expect(accepts('h264', 3840, 2160, 60), false);
    expect(accepts('h264', 2560, 1080, 60), false);
    expect(accepts('h264', 1920, 1200, 60), false);
    expect(accepts('hevc', 3840, 2160, 60), true);
  });

  test('unknown and ordinary browser players cannot claim LG UHD', () {
    for (final data in <Map<String, dynamic>>[
      {},
      {'platform': 'lg', 'uhd': true},
      {
        'platform': 'lg',
        'packaged': true,
        'sdkVersion': 'unknown',
        'uhd': true,
      },
    ]) {
      final caps = PlaybackCapabilities.fromJson(data);
      expect(caps.detected, false);
      final profile = PlaybackProfile.forDevice(
        PlaybackOptions(capabilities: caps),
      );
      expect(jsonEncode(profile), isNot(contains('hevc')));
    }
  });
  test('Android requires decoder evidence and preserves 1080p devices', () {
    final caps = PlaybackCapabilities.fromJson({
      'platform': 'android',
      'videos': {
        'h264': {'width': 1920, 'height': 1080, 'fps': 60, 'level': 42},
        'hevc': {
          'width': 3840,
          'height': 2160,
          'fps': 60,
          'level': 153,
          'main10': true,
        },
      },
      'audio': {'eac3': 6},
    });
    expect(caps.videos['h264']!.width, 1920);
    expect(caps.videos['hevc']!.bitDepth, 10);
    expect(caps.audio.containsKey('truehd'), false);
    final streams =
        PlaybackProfile.forDevice(
              PlaybackOptions(capabilities: caps),
            )['TranscodingProfiles']
            as List;
    expect(streams, hasLength(1));
    expect(streams.single['Container'], 'ts');
    expect(streams.single['Protocol'], 'hls');
    expect(streams.single['VideoCodec'], 'h264,hevc');
    expect(streams.single['AudioCodec'], 'aac,eac3');
    expect(streams.single['MaxAudioChannels'], '6');
    expect(PlaybackOptions(bitrate: 120000000).bitrate, 120000000);
    expect(PlaybackOptions(bitrate: 999000000).bitrate, 120000000);
  });
  test(
    'Android quality and track changes keep TS HLS and decoder evidence',
    () {
      final caps = PlaybackCapabilities.fromJson({
        'platform': 'android',
        'videos': {
          'h264': {'width': 1920, 'height': 1080, 'fps': 60, 'level': 42},
          'hevc': {
            'width': 3840,
            'height': 2160,
            'fps': 60,
            'level': 153,
            'main10': true,
            'hdr10': true,
          },
        },
        'audio': {'aac': 6, 'eac3': 6},
      });
      final automatic = PlaybackOptions(capabilities: caps);
      final reduced = automatic.copyWith(
        bitrate: 2000000,
        startTicks: 30000000,
      );
      final tracks = reduced.copyWith(
        audioIndex: () => 1,
        subtitleIndex: 2,
        burnSubtitles: true,
      );
      for (final options in [automatic, reduced, tracks]) {
        final body = PlaybackProfile.request('viewer', options);
        final profile = body['DeviceProfile'] as Map;
        final transcodes = profile['TranscodingProfiles'] as List;
        expect(transcodes, hasLength(1));
        expect(transcodes.single['Container'], 'ts');
        expect(transcodes.single['Protocol'], 'hls');
        expect(transcodes.single['VideoCodec'], contains('hevc'));
        expect(transcodes.single['AudioCodec'], 'aac,eac3');
        final direct = (profile['DirectPlayProfiles'] as List).single;
        expect(direct['Container'], contains('mkv'));
        expect(direct['VideoCodec'], contains('hevc'));
        expect(direct['AudioCodec'], contains('eac3'));
        final hevc = (profile['CodecProfiles'] as List).firstWhere(
          (codec) => codec['Codec'] == 'hevc',
        );
        expect(hevc['Conditions'], contains(containsPair('Value', '2160')));
        expect(hevc['Conditions'], contains(containsPair('Value', '10')));
        expect(body['MaxStreamingBitrate'], options.bitrate);
        expect(body['StartTimeTicks'], options.startTicks);
        expect(body['EnableDirectStream'], true);
        expect(body['EnableTranscoding'], true);
        expect(body['AllowVideoStreamCopy'], true);
        expect(body['AllowAudioStreamCopy'], true);
        expect(body['EnableDirectPlay'], !options.needsTranscode);
      }
      final selected = PlaybackProfile.request('viewer', tracks);
      expect(selected['AudioStreamIndex'], 1);
      expect(selected['SubtitleStreamIndex'], 2);
    },
  );

  test('Android advertises HDR only when the screen shows it', () {
    String ranges(Map<String, Object?> extra, {bool main10 = true}) {
      final caps = PlaybackCapabilities.fromJson({
        'platform': 'android',
        'videos': {
          'h264': {'width': 1920, 'height': 1080, 'fps': 60, 'level': 42},
          'hevc': {
            'width': 3840,
            'height': 2160,
            'fps': 60,
            'level': 153,
            'main10': main10,
          },
        },
        ...extra,
      });
      final codecs =
          PlaybackProfile.forDevice(
                PlaybackOptions(capabilities: caps),
              )['CodecProfiles']
              as List;
      final hevc = codecs.firstWhere((c) => c['Codec'] == 'hevc') as Map;
      return (hevc['Conditions'] as List).firstWhere(
            (c) => c['Property'] == 'VideoRangeType',
          )['Value']
          as String;
    }

    expect(ranges({}), 'SDR');
    expect(ranges({'hdr': <String>[]}), 'SDR');
    expect(
      ranges({
        'hdr': ['hdr10'],
      }),
      'SDR|HDR10|DOVIWithHDR10',
    );
    expect(
      ranges({
        'hdr': ['hdr10', 'hlg'],
      }),
      'SDR|HDR10|DOVIWithHDR10|HLG',
    );
    // An 8-bit decoder can't show HDR even on an HDR screen.
    expect(
      ranges({
        'hdr': ['hdr10'],
      }, main10: false),
      'SDR',
    );
    expect(ranges({'hdr': 'hdr10'}), 'SDR');
    expect(
      ranges({
        'hdr': ['dolbyVision'],
      }),
      'SDR',
    );
    expect(ranges({'dvProfile5': true}), 'SDR');
    expect(
      ranges({
        'hdr': ['dolbyVision'],
        'dvProfile5': true,
      }),
      'SDR|DOVI',
    );
    expect(
      ranges({
        'hdr': ['dolbyVision'],
        'dvProfile5': true,
      }, main10: false),
      'SDR',
    );
  });
  test(
    'HDR target and receiver capabilities constrain the actual device profile',
    () {
      final samsung = PlaybackCapabilities.samsungTv(uhd: true, q80bHdr: true);
      final ranges = samsung.videos['hevc']!.rangeTypes.split('|');
      expect(
        ranges,
        containsAll(['HDR10', 'HDR10Plus', 'HLG', 'DOVIWithHDR10']),
      );
      expect(ranges, isNot(contains('DOVI')));
      expect(samsung.videos['h264']!.rangeTypes, 'SDR');
      final lgDv = PlaybackCapabilities.fromJson({
        'platform': 'lg',
        'packaged': true,
        'sdkVersion': '8.0',
        'dolbyVision': true,
        'mkvAudioByVideo': {
          'hevc': ['eac3', 'unknown'],
        },
      });
      expect(lgDv.videos['hevc']!.rangeTypes, 'SDR|DOVI');
      final hybrid = PlaybackCapabilities.fromJson({
        'platform': 'lg',
        'packaged': true,
        'sdkVersion': '8.0',
        'hdr10': true,
        'dolbyVisionHdr10': true,
      });
      expect(hybrid.videos['hevc']!.rangeTypes, 'SDR|HDR10|DOVIWithHDR10');
      final lgProfile = PlaybackProfile.forDevice(
        PlaybackOptions(capabilities: lgDv),
      );
      final mkv = (lgProfile['DirectPlayProfiles'] as List).last;
      expect(mkv['Container'], 'mkv');
      expect(mkv['VideoCodec'], 'hevc');
      expect(mkv['AudioCodec'], 'eac3');
      final mkvRules = (lgProfile['CodecProfiles'] as List).firstWhere(
        (r) => r['Container'] == 'mkv',
      );
      expect(mkvRules['Conditions'], contains(containsPair('Value', 'SDR')));
      final android = PlaybackCapabilities.fromJson({
        'platform': 'android',
        'videos': {
          'h264': {'width': 1920, 'height': 1080, 'fps': 60, 'level': 42},
        },
        'audio': {'ac3': 8, 'eac3': 8},
        'mkvPassthrough': {'truehd': 8, 'dts': 6, 'unknown': 8},
      });
      expect(android.audio, {'aac': 2, 'ac3': 6, 'eac3': 8});
      final profile = PlaybackProfile.forDevice(
        PlaybackOptions(capabilities: android),
      );
      final files = profile['DirectPlayProfiles'] as List;
      expect(files.last['Container'], 'mkv');
      expect(files.last['AudioCodec'], 'truehd,dts');
      expect(files.first['AudioCodec'], 'aac,ac3,eac3');
      final rules = profile['CodecProfiles'] as List;
      expect(
        rules.firstWhere((r) => r['Codec'] == 'dts')['Conditions'],
        contains(containsPair('Value', 'DTS')),
      );
      expect(
        rules.firstWhere((r) => r['Codec'] == 'truehd')['Conditions'],
        contains(containsPair('Value', '48000')),
      );
      final hls = (profile['TranscodingProfiles'] as List).first;
      expect(hls['AudioCodec'], 'aac,ac3,eac3');
      // Converted audio stops at 5.1 even when the AAC decoder lists 8.
      expect(hls['MaxAudioChannels'], '6');
    },
  );
  test('Android direct plays DTS and TrueHD MKV the app decodes itself', () {
    final android = PlaybackCapabilities.fromJson({
      'platform': 'android',
      'videos': {
        'h264': {'width': 1920, 'height': 1080, 'fps': 60, 'level': 42},
      },
      'audio': {'ac3': 6},
      'mkvPassthrough': {'dts': 6},
      'ffmpegAudio': ['dts', 'truehd', 'flac'],
    });
    expect(android.decodedAudio, {'dts': 8, 'truehd': 8});
    final profile = PlaybackProfile.forDevice(
      PlaybackOptions(capabilities: android),
    );
    final mkv = (profile['DirectPlayProfiles'] as List).last;
    expect(mkv['Container'], 'mkv');
    expect(mkv['AudioCodec'], 'dts,truehd');
    // DTS no longer needs to fit the receiver: the app decodes what it can't
    // pass through.
    expect(
      (profile['CodecProfiles'] as List).where(
        (r) => r['Type'] == 'VideoAudio' && r['Codec'] == 'dts',
      ),
      isEmpty,
    );
    final plain = PlaybackCapabilities.fromJson({
      'platform': 'android',
      'videos': {
        'h264': {'width': 1920, 'height': 1080, 'fps': 60, 'level': 42},
      },
    });
    expect(plain.decodedAudio, isEmpty);
  });

  test('LG retains fMP4 and TS live fallback independently of Android', () {
    final transcodes =
        PlaybackProfile.forDevice(
              PlaybackOptions(capabilities: lg()),
            )['TranscodingProfiles']
            as List;
    expect(transcodes, hasLength(2));
    expect(transcodes.first['Container'], 'mp4');
    expect(transcodes.first['VideoCodec'], contains('hevc'));
    expect(transcodes.last['Container'], 'ts');
    expect(transcodes.last['VideoCodec'], 'h264');
    expect(transcodes.last['AudioCodec'], 'aac');
  });

  test(
    'own-session diagnostics ignore other accounts, devices, titles and sources',
    () async {
      final server = ServerAddress.parse('https://example.test');
      final current = {
        'UserId': 'viewer',
        'DeviceId': 'device',
        'NowPlayingItem': {'Id': 'item'},
        'PlayState': {'MediaSourceId': 'source'},
        'TranscodingInfo': {
          'Bitrate': 8000000,
          'IsVideoDirect': true,
          'IsAudioDirect': false,
          'TranscodeReasons': ['AudioCodecNotSupported'],
        },
      };
      late Uri requestUrl;
      final client = JellyfinClient(
        server: server,
        identity: const ClientIdentity(deviceId: 'device', deviceName: 'TV'),
        session: Session(
          server: server,
          viewer: Viewer(id: 'viewer', name: 'Fixture'),
          token: 'fixture-token',
          deviceId: 'device',
        ),
        httpClient: MockClient((req) async {
          requestUrl = req.url;
          return http.Response(
            jsonEncode([
              {
                ...current,
                'UserId': 'other',
                'TranscodingInfo': {'Bitrate': 99000000},
              },
              {
                ...current,
                'DeviceId': 'other',
                'TranscodingInfo': {'Bitrate': 98000000},
              },
              {
                ...current,
                'NowPlayingItem': {'Id': 'other'},
                'TranscodingInfo': {'Bitrate': 97000000},
              },
              {
                ...current,
                'PlayState': {'MediaSourceId': 'other'},
                'TranscodingInfo': {'Bitrate': 96000000},
              },
              current,
            ]),
            200,
          );
        }),
      );
      final plan = PlaybackPlan.make(
        PlaybackInfo(
          playSessionId: 'play',
          mediaSources: [
            MediaSource(
              id: 'source',
              bitrate: 17000000,
              supportsTranscoding: true,
              transcodingUrl:
                  '/stream.m3u8?TranscodeReasons=ContainerNotSupported',
              transcodingSubProtocol: 'hls',
            ),
          ],
        ),
        itemId: 'item',
        client: client,
        options: PlaybackOptions(),
      );
      final info = await client.playbackDiagnostics(plan);
      expect(requestUrl.queryParameters['deviceId'], 'device');
      expect(info.outputBitrate, 8000000);
      expect(info.sourceBitrate, 17000000);
      expect(info.method, 'Audio conversion (video copied)');
      expect(info.reasons, ['Audio codec is not supported']);
      expect(jsonEncode(info.toJson()), isNot(contains('fixture-token')));
    },
  );
  test(
    'restricted diagnostics retain negotiated reasons without blocking playback',
    () async {
      final server = ServerAddress.parse('https://example.test');
      final client = JellyfinClient(
        server: server,
        identity: const ClientIdentity(deviceId: 'd', deviceName: 'TV'),
        session: Session(
          server: server,
          viewer: Viewer(id: 'u', name: 'Test'),
          token: 'fixture',
          deviceId: 'd',
        ),
        httpClient: MockClient((_) async => http.Response('forbidden', 403)),
      );
      final plan = PlaybackPlan.make(
        PlaybackInfo(
          playSessionId: 'p',
          mediaSources: [
            MediaSource(
              id: 's',
              bitrate: 17000000,
              supportsTranscoding: true,
              transcodingUrl:
                  '/stream.m3u8?TranscodeReasons=ContainerBitrateExceedsLimit',
              transcodingSubProtocol: 'hls',
            ),
          ],
        ),
        itemId: 'i',
        client: client,
        options: PlaybackOptions(bitrate: 8000000),
      );
      final info = await client.playbackDiagnostics(plan);
      expect(info.outputBitrate, isNull);
      expect(info.limit, 8000000);
      expect(info.reasons, ['Source bitrate exceeds the quality limit']);
    },
  );
}
