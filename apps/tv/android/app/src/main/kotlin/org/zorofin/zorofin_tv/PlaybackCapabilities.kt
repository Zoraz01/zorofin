package org.zorofin.zorofin_tv

import android.app.Activity
import android.content.res.Configuration
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.MediaCodecInfo.CodecProfileLevel
import android.media.MediaCodecList
import android.os.Build
import android.view.Display

/** Decoder evidence, not display resolution or a manufacturer-wide promise. */
object PlaybackCapabilities {
    /** HDR types the screen itself shows; the player doesn't tone-map. */
    private fun displayHdr(activity: Activity): List<String> {
        if (Build.VERSION.SDK_INT < 24) return emptyList()
        return try {
            @Suppress("DEPRECATION")
            val display: Display = (if (Build.VERSION.SDK_INT >= 30) activity.display else null)
                ?: activity.windowManager.defaultDisplay
            @Suppress("DEPRECATION")
            val types = if (Build.VERSION.SDK_INT >= 34) display.mode.supportedHdrTypes
                else display.hdrCapabilities?.supportedHdrTypes ?: intArrayOf()
            buildList {
                if (Display.HdrCapabilities.HDR_TYPE_HDR10 in types) add("hdr10")
                if (Display.HdrCapabilities.HDR_TYPE_HLG in types) add("hlg")
                if (Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION in types) add("dolbyVision")
            }
        } catch (_: Exception) { emptyList() }
    }

    // Before Android 13, a positive result can belong to an inactive HDMI
    // route. Restrict these passthrough-only MKV formats to the routed sink.
    private fun mkvPassthrough(activity: Activity): Map<String, Int> {
        if (Build.VERSION.SDK_INT < 33 || activity.resources.configuration.uiMode and
            Configuration.UI_MODE_TYPE_MASK != Configuration.UI_MODE_TYPE_TELEVISION) return emptyMap()
        val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build()
        val result = mutableMapOf<String, Int>()
        for ((codec, encoding) in mapOf("truehd" to AudioFormat.ENCODING_DOLBY_TRUEHD, "dts" to AudioFormat.ENCODING_DTS)) {
            for ((channels, mask) in listOf(8 to AudioFormat.CHANNEL_OUT_7POINT1_SURROUND, 6 to AudioFormat.CHANNEL_OUT_5POINT1)) {
                if (codec == "dts" && channels > 6) continue
                try {
                    val format = AudioFormat.Builder().setEncoding(encoding).setChannelMask(mask).setSampleRate(48000).build()
                    if (AudioManager.getDirectPlaybackSupport(format, attributes) and AudioManager.DIRECT_PLAYBACK_BITSTREAM_SUPPORTED != 0) {
                        result[codec] = channels
                        break
                    }
                } catch (_: IllegalArgumentException) { }
            }
        }
        return result
    }

    // DTS and TrueHD the bundled FFmpeg decoder can turn into PCM when the
    // device has no decoder or passthrough for them. Looked up by name: the
    // decoder ships inside the video player plugin, not this module.
    private fun ffmpegAudio(): List<String> = try {
        val library = Class.forName("androidx.media3.decoder.ffmpeg.FfmpegLibrary")
        val available = library.getMethod("isAvailable").invoke(null) == true
        val supports = library.getMethod("supportsFormat", String::class.java)
        if (!available) emptyList() else mapOf("dts" to "audio/vnd.dts", "truehd" to "audio/true-hd")
            .filterValues { supports.invoke(null, it) == true }.keys.toList()
    } catch (_: Throwable) { emptyList() }

    fun read(activity: Activity): Map<String, Any> {
        val available = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { !it.isEncoder }
        val decoders = available.filter {
            if (Build.VERSION.SDK_INT >= 29) it.isHardwareAccelerated
            else !it.name.startsWith("OMX.google.") && !it.name.startsWith("c2.android.")
        }
        val videos = mutableMapOf<String, Map<String, Any>>()
        for ((codec, mime) in listOf("h264" to "video/avc", "hevc" to "video/hevc")) {
            val candidates = decoders.mapNotNull { decoder ->
                try {
                    val caps = decoder.getCapabilitiesForType(mime)
                    val video = caps.videoCapabilities ?: return@mapNotNull null
                    val levels = caps.profileLevels.filter { p ->
                        if (codec == "hevc") p.profile == CodecProfileLevel.HEVCProfileMain || p.profile == CodecProfileLevel.HEVCProfileMain10
                        else p.profile in listOf(CodecProfileLevel.AVCProfileBaseline, CodecProfileLevel.AVCProfileMain, CodecProfileLevel.AVCProfileHigh)
                    }
                    val enough4kLevel = levels.any { it.level >= if (codec == "hevc") CodecProfileLevel.HEVCMainTierLevel51 else CodecProfileLevel.AVCLevel51 }
                    val uhd = enough4kLevel && video.areSizeAndRateSupported(3840, 2160, 30.0)
                    val width = if (uhd) 3840 else 1920
                    val height = if (uhd) 2160 else 1080
                    val fps = if (video.areSizeAndRateSupported(width, height, 60.0)) 60 else 30
                    if (!video.areSizeAndRateSupported(width, height, fps.toDouble())) return@mapNotNull null
                    val requiredLevel = if (codec == "hevc") {
                        if (uhd) CodecProfileLevel.HEVCMainTierLevel51 else CodecProfileLevel.HEVCMainTierLevel41
                    } else if (uhd) {
                        if (fps == 60) CodecProfileLevel.AVCLevel52 else CodecProfileLevel.AVCLevel51
                    } else if (fps == 60) CodecProfileLevel.AVCLevel42 else CodecProfileLevel.AVCLevel41
                    if (levels.none { it.level >= requiredLevel }) return@mapNotNull null
                    mapOf("maxBitrate" to video.bitrateRange.upper.coerceAtMost(120000000), "width" to width, "height" to height, "fps" to fps,
                        "level" to if (codec == "hevc") { if (uhd) 153 else 123 }
                            else if (uhd) { if (fps == 60) 52 else 51 } else if (fps == 60) 42 else 41,
                        "main10" to levels.any { it.profile == CodecProfileLevel.HEVCProfileMain10 && it.level >= requiredLevel })
                } catch (_: Exception) { null }
            }
            candidates.maxByOrNull { (it["width"] as Int) * (it["height"] as Int) * (it["fps"] as Int) }?.let { videos[codec] = it }
        }
        val audio = mutableMapOf<String, Int>("aac" to 2)
        for ((codec, mime) in listOf("aac" to "audio/mp4a-latm", "ac3" to "audio/ac3", "eac3" to "audio/eac3")) {
            // Audio software decoders are fine; do not infer passthrough from HDMI.
            available.forEach {
                try { val channels = it.getCapabilitiesForType(mime).audioCapabilities?.maxInputChannelCount?.coerceAtMost(if (codec == "ac3") 6 else 8) ?: 0
                    if (channels >= 2) audio[codec] = maxOf(audio[codec] ?: 0, channels)
                } catch (_: Exception) { }
            }
        }
        val hdr = displayHdr(activity)
        val hevc = videos["hevc"]
        val dvProfile5 = hevc != null && hevc["main10"] == true && "dolbyVision" in hdr && decoders.any { decoder ->
            try {
                val caps = decoder.getCapabilitiesForType("video/dolby-vision")
                val width = hevc["width"] as Int
                val height = hevc["height"] as Int
                val fps = hevc["fps"] as Int
                val level = if (height > 1080) {
                    if (fps > 30) CodecProfileLevel.DolbyVisionLevelUhd60 else CodecProfileLevel.DolbyVisionLevelUhd30
                } else if (fps > 30) CodecProfileLevel.DolbyVisionLevelFhd60 else CodecProfileLevel.DolbyVisionLevelFhd30
                caps.profileLevels.any { it.profile == CodecProfileLevel.DolbyVisionProfileDvheStn && it.level >= level } &&
                    caps.videoCapabilities?.areSizeAndRateSupported(width, height, fps.toDouble()) == true
            } catch (_: Exception) { false }
        }
        return mapOf("platform" to "android", "videos" to videos, "audio" to audio,
            "hdr" to hdr, "dvProfile5" to dvProfile5, "mkvPassthrough" to mkvPassthrough(activity),
            "ffmpegAudio" to ffmpegAudio())
    }
}
