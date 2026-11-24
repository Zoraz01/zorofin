# Player rotation HLS fixture

`rotation-hls/` is a generated, 60-second, 320×180 H.264/AAC test pattern with
a synthetic tone. It contains no library media, account data or server URLs.
Only the hosted `Zorofin-PlayerTests` target copies it; shipping targets do not.

Regenerate from the repository root with FFmpeg (libx264 and AAC enabled):

```sh
ffmpeg -nostdin -y -v error \
  -f lavfi -i 'testsrc2=size=320x180:rate=12' \
  -f lavfi -i 'sine=frequency=440:sample_rate=44100' \
  -t 60 -c:v libx264 -preset veryfast -crf 36 -pix_fmt yuv420p \
  -g 48 -sc_threshold 0 -c:a aac -b:a 32k \
  -f hls -hls_time 4 -hls_playlist_type vod \
  -hls_segment_filename 'apps/apple/Tests/Fixtures/rotation-hls/segment-%02d.ts' \
  apps/apple/Tests/Fixtures/rotation-hls/stream.m3u8
```

The test owns an ephemeral loopback listener and cancels every connection in
`defer`. A stub transport delays Jellyfin playback negotiation for one minute;
the production player then fetches and decodes this HLS over HTTP. This covers
the startup/phase/control-hide layout lifecycle without a real account or shared
server. It does not reproduce the reported remote stream's network or codec
conditions, or establish physical-device acceptance.

The harness explicitly supplies an active SwiftUI scene phase. An independent
UIKit test window does not inherit the app's WindowGroup environment. Without
that value, production background-pause handling left a ready, decoded HLS item
paused, so waiting for playing timed out. Numeric diagnostics showed no media
errors. This was a harness setup failure, not reproduction of the device report.
