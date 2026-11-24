# Offline player preparation fixture

`player-preparation.mp4` is a generated, silent, three-second 160×90 H.264 test
pattern. It contains no library media, network addresses or credentials.

Recreate with FFmpeg:

```sh
ffmpeg -nostdin -hide_banner -loglevel error \
  -f lavfi -i testsrc2=size=160x90:rate=10 -t 3 -an \
  -c:v libx264 -threads 1 -pix_fmt yuv420p -g 10 -movflags +faststart \
  player-preparation.mp4
```

The macOS-only Core test uses the production preparation driver to seek to
1.25 seconds while paused, preroll without advancing, then resume and require
a decoded pixel buffer. It exercises AVFoundation locally; it is not HLS,
server compatibility, iPhone or Apple TV acceptance evidence.
