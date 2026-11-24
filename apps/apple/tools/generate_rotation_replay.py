#!/usr/bin/env python3
"""Generate synthetic HLS for delayed-startup tests; never reads library media."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--profile", type=Path, help="Private numeric replay profile; no account data needed")
    parser.add_argument("--ffmpeg", default=os.environ.get("FFMPEG_BIN", "ffmpeg"))
    args = parser.parse_args()
    profile = dict(durationSeconds=1800.0, resumeSeconds=1380.0, width=1920,
                   height=1080, frameRateNumerator=24000, frameRateDenominator=1001,
                   audioSampleRate=48000, audioChannels=2, audioStreamIndex=3,
                   subtitleStreamIndex=-1)
    if args.profile:
        supplied = json.loads(args.profile.read_text())
        if set(supplied) - set(profile):
            parser.error("Profile accepts numeric replay settings only")
        profile.update(supplied)
    if not all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in profile.values()):
        parser.error("Every profile value must be numeric")
    integer_keys = set(profile) - {"durationSeconds", "resumeSeconds"}
    if any(not isinstance(profile[key], int) for key in integer_keys):
        parser.error("Dimensions, rates and stream indexes must be integers")
    if not (120 <= profile["durationSeconds"] <= 3600 and
            60 <= profile["resumeSeconds"] < profile["durationSeconds"] - 60 and
            profile["width"] == 1920 and profile["height"] == 1080 and
            profile["frameRateNumerator"] == 24000 and profile["frameRateDenominator"] == 1001 and
            profile["audioSampleRate"] == 48000 and profile["audioChannels"] == 2 and
            0 <= profile["audioStreamIndex"] <= 16 and profile["subtitleStreamIndex"] == -1):
        parser.error("Unsupported replay profile")
    ffmpeg = shutil.which(args.ffmpeg)
    if not ffmpeg:
        parser.error("FFmpeg with libx264/AAC is required; pass --ffmpeg or FFMPEG_BIN")
    output = args.output.resolve()
    marker = output / ".zorofin-synthetic-hls"
    if output.exists() and any(output.iterdir()) and not marker.exists():
        parser.error("Output must be empty or a previously generated synthetic fixture")
    output.mkdir(parents=True, exist_ok=True)
    complete = output / "profile.json"
    if complete.exists() and json.loads(complete.read_text()) == profile and (output / "master.m3u8").exists():
        print("Reusing completed synthetic HLS fixture", flush=True)
        return
    marker.write_text("Generated SMPTE bars and tone only. No library media.\n")
    rate = f'{profile["frameRateNumerator"]}/{profile["frameRateDenominator"]}'
    command = [ffmpeg, "-nostdin", "-y", "-v", "error", "-threads", "2",
               "-f", "lavfi", "-i", f'smptebars=size=1920x1080:rate={rate}',
               "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
               "-t", str(profile["durationSeconds"]), "-c:v", "libx264", "-threads:v", "2",
               "-preset", "veryfast", "-crf", "36", "-profile:v", "high", "-level:v", "4.1",
               "-pix_fmt", "yuv420p", "-g", "96", "-keyint_min", "96", "-sc_threshold", "0",
               "-c:a", "aac", "-b:a", "64k", "-ar", "48000", "-ac", "2",
               "-f", "hls", "-hls_time", "4", "-hls_playlist_type", "vod",
               "-hls_flags", "independent_segments", "-hls_segment_filename",
               str(output / "segment-%05d.ts"), str(output / "stream.m3u8")]
    print("Generating 1080p synthetic VOD timeline; this can take a few minutes", flush=True)
    subprocess.run(command, check=True)
    (output / "master.m3u8").write_text(
        '#EXTM3U\n#EXT-X-VERSION:3\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=22000000,RESOLUTION=1920x1080,'
        'FRAME-RATE=23.976,CODECS="avc1.640029,mp4a.40.2"\nstream.m3u8\n')
    complete.write_text(json.dumps(profile, indent=2) + "\n")
    print("Synthetic HLS fixture ready", flush=True)


if __name__ == "__main__":
    main()
