#!/usr/bin/env python3
"""Add licensed full films only to the verified isolated demo; never restart it.

Downloads and conversions stage outside the read-only mounted library. Retain
full film credits, use no independent soundtrack assets, and record adaptations.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

from demo import Demo, NoRedirects, require
from urllib.parse import urlsplit

TOOLS = Path('/Applications/Jellyfin.app/Contents/MacOS')
ARCHIVAL_SOURCES = {
    'https://upload.wikimedia.org/wikipedia/commons/1/1d/The_Great_Train_Robbery_1903.webm',
}

def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()

def source_allowed(url):
    try:
        p = urlsplit(url)
        return (p.scheme == 'https' and (p.hostname in {'download.blender.org', 'video.blender.org'}
                                       or url in ARCHIVAL_SOURCES)
                and p.port is None and p.username is None and p.password is None
                and not p.query and not p.fragment)
    except ValueError:
        return False


def fetch(url, target, cap=1500 * 1024 * 1024):
    require(source_allowed(url), 'Only official catalog sources are allowed')
    partial = target.with_suffix(target.suffix + '.partial')
    if target.exists():
        return
    ctx = ssl.create_default_context(cafile='/etc/ssl/cert.pem')
    opener = urllib.request.build_opener(NoRedirects(), urllib.request.HTTPSHandler(context=ctx))
    request = urllib.request.Request(url, headers={'User-Agent': 'ZorofinSampleLibrary/1.0 (+https://zorofin.app)'})
    with opener.open(request, timeout=45) as response, partial.open('wb') as f:
        require(source_allowed(response.url), 'Unexpected source redirect')
        length = int(response.headers.get('Content-Length', 0))
        require(length <= cap, 'Source exceeds size budget')
        size = 0
        while block := response.read(1024 * 1024):
            size += len(block)
            require(size <= cap, 'Source exceeds size budget')
            f.write(block)
        require(size > 1024 * 1024 and (not length or size == length), 'Incomplete film download')
    partial.rename(target)

def probe(path):
    return json.loads(subprocess.check_output([str(TOOLS / 'ffprobe'), '-v', 'error', '-show_format',
                                               '-show_streams', '-of', 'json', str(path)]))

def ffmpeg(*args):
    subprocess.run([str(TOOLS / 'ffmpeg.real'), '-nostdin', '-hide_banner', '-loglevel', 'error',
                    '-threads', '2', '-filter_threads', '1', *map(str, args)], check=True)

def playback_options(before, film):
    video = next((s for s in before['streams'] if s.get('codec_type') == 'video'), {})
    require(video.get('codec_name') in {'h264', 'vp8', 'vp9'}, 'Unsupported sample video')
    copy_video = video['codec_name'] == 'h264'
    video_options = ['-c:v', 'copy'] if copy_video else [
        '-c:v', 'libx264', '-preset', 'fast', '-crf', '20', '-pix_fmt', 'yuv420p', '-threads', '2']
    audio = next((s for s in before['streams'] if s.get('codec_type') == 'audio'), {})
    if film.get('silent_original'):
        require(film['source'] in ARCHIVAL_SOURCES, 'Silent conversion requires an audited archival source')
        return ['-map', '0:v:0', *video_options, '-an'], copy_video, False
    require(audio, 'Expected original film audio')
    copy_audio = audio.get('codec_name') == 'aac' and audio.get('channels', 99) <= 2
    audio_options = ['-c:a', 'copy'] if copy_audio else ['-c:a', 'aac', '-ac', '2', '-b:a', '192k']
    return ['-map', '0:v:0', '-map', '0:a:0', *video_options, *audio_options], copy_video, copy_audio

def add(demo, film):
    name = f"{film['title']} ({film['year']})"
    destination = demo.root / 'media/movies' / name
    require(not destination.exists(), 'This sample already exists; preserve it and inspect before changing it')
    stage = demo.root / 'sources' / name
    stage.mkdir(exist_ok=True)
    suffix = Path(urlsplit(film['source']).path).suffix.lower()
    require(suffix in {'.zip', '.mov', '.mp4', '.webm'}, 'Unsupported catalog format')
    source = stage / ('source' + suffix)
    print('Downloading:', film['title'], flush=True)
    fetch(film['source'], source)
    original = source
    if source.suffix == '.zip':
        original = stage / 'original.mkv'
        if not original.exists():
            with zipfile.ZipFile(source) as archive:
                entries = [i for i in archive.infolist() if i.filename.lower().endswith('.mkv')]
                require(len(entries) == 1 and entries[0].file_size < 1800 * 1024 * 1024, 'Unexpected film archive')
                with archive.open(entries[0]) as src, original.open('wb') as dst:
                    shutil.copyfileobj(src, dst, length=1024 * 1024)
    before = probe(original)
    minimum_duration = film.get('minimum_duration', 600)
    require(isinstance(minimum_duration, int) and minimum_duration >= 120, 'Invalid film duration constraint')
    require(float(before['format']['duration']) >= minimum_duration, 'Expected the complete catalog film')
    options, copy_video, copy_audio = playback_options(before, film)
    ready = stage / 'ready'
    ready.mkdir(exist_ok=True)
    movie = ready / (name + '.mp4')
    if not movie.exists():
        print('Preparing compatible full film:', film['title'], flush=True)
        ffmpeg('-i', original, *options, '-movflags', '+faststart', movie)
    after = probe(movie)
    require(abs(float(after['format']['duration']) - float(before['format']['duration'])) < 1,
            'Film duration changed; preserve the complete credits')
    # MP4 chapters can be represented by an additional bin_data stream.
    media_streams = [s for s in after['streams'] if s.get('codec_type') in ('video', 'audio')]
    expected = [('video', 'h264')] + ([] if film.get('silent_original') else [('audio', 'aac')])
    require(sorted((s.get('codec_type'), s.get('codec_name')) for s in media_streams) == sorted(expected),
            'Unexpected playback codec')
    focus = film.get('poster_horizontal_focus', 0.5)
    require(isinstance(focus, (int, float)) and 0 <= focus <= 1, 'Invalid poster crop focus')
    for output, shape in [('poster.jpg', f'scale=480:720:force_original_aspect_ratio=increase,crop=480:720:x=(iw-ow)*{focus}:y=(ih-oh)/2'),
                          ('fanart.jpg', 'scale=1280:720:force_original_aspect_ratio=increase,crop=1280:720')]:
        path = ready / output
        if not path.exists():
            ffmpeg('-ss', film['still_seconds'], '-i', movie, '-frames:v', '1', '-vf', shape, '-q:v', '3', path)
    credit = film['attribution'] + '\n' + film['license'] + '\n' + film['license_evidence']
    changes = 'Full film and credit scroll retained. ' + ('Video stream copied; ' if copy_video else 'Video converted to H.264; ')
    changes += ('silent original presented without the upload soundtrack.' if film.get('silent_original') else
                ('stereo AAC audio copied.' if copy_audio else 'audio converted to AAC stereo.'))
    changes += ' Artwork consists of cropped/scaled film frames. No endorsement implied.'
    (ready / 'ATTRIBUTION.txt').write_text(credit + '\n' + changes + '\n')
    nfo = ET.Element('movie')
    for key, value in [('title', film['title']), ('year', str(film['year'])), ('genre', film['genre']),
                       ('plot', film['plot'] + '\n\n' + credit + '\n' + changes), ('lockdata', 'true')]:
        ET.SubElement(nfo, key).text = value
    ET.ElementTree(nfo).write(ready / 'movie.nfo', encoding='utf-8', xml_declaration=True)
    manifest = dict(film, source_sha256=sha(source), output_sha256=sha(movie),
                    duration=after['format']['duration'], adaptations=changes)
    (stage / 'provenance.json').write_text(json.dumps(manifest, indent=2) + '\n')
    # Publish the complete directory atomically on this one volume; no partial library items.
    ready.rename(destination)
    print('Added:', film['title'], flush=True)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--env', required=True)
    args = parser.parse_args()
    demo = Demo(args.env)  # Proves container label, exact mounts, version and server identity.
    require(demo.credentials is not None)
    require(shutil.disk_usage(demo.root).free > 4 * 1024**3, 'Need 4 GiB free on the demo volume')
    catalog = json.loads(Path(__file__).with_name('sample-catalog.json').read_text())
    for film in catalog:
        destination = demo.root / 'media/movies' / f"{film['title']} ({film['year']})"
        if destination.exists():
            print('Already present; preserving:', film['title'], flush=True)
        else:
            add(demo, film)
    demo.login(demo.credentials['admin'])
    try:
        demo.api('/Library/Refresh', 'POST')
    finally:
        demo.logout()
    print('Requested a demo-only library scan. No service restarted.', flush=True)

if __name__ == '__main__':
    main()
