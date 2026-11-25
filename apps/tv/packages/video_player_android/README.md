> **Zorofin fork of video_player_android 2.9.5.** The only changes: ExoPlayer
> is built with `DefaultRenderersFactory` in `EXTENSION_RENDERER_MODE_ON`, and
> Jellyfin's prebuilt Media3 FFmpeg decoder (GPL-3.0) is added, so DTS and
> TrueHD play on devices without those decoders. Android tests and the example
> were removed. To update, copy the new upstream release and reapply the two
> `ExoPlayer.Builder` edits and the Gradle dependency (search for "Zorofin").

# video\_player\_android

The Android implementation of [`video_player`][1].

## Usage

This package is [endorsed][2], which means you can simply use `video_player`
normally. This package will be automatically included in your app when you do,
so you do not need to add it to your `pubspec.yaml`.

However, if you `import` this package to use any of its APIs directly, you
should add it to your `pubspec.yaml` as usual.

## Known issues

Using `VideoViewType.platformView` is not currently recommended on Android due to a known [issue][3] affecting platform views on Android.

[1]: https://pub.dev/packages/video_player
[2]: https://flutter.dev/to/endorsed-federated-plugin
[3]: https://github.com/flutter/flutter/issues/164899
