# Zorofin: PlaybackCapabilities.kt looks these up by name to learn which
# audio (DTS, TrueHD) the bundled FFmpeg decoder plays. Without the rule a
# release build renames the methods, the probe finds nothing, and the app
# asks the server to convert audio it could have played itself.
-keep class androidx.media3.decoder.ffmpeg.FfmpegLibrary {
    public static boolean isAvailable();
    public static boolean supportsFormat(java.lang.String);
}
