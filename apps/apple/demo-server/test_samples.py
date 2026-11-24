"""Public download boundaries; no Docker or network access required."""
import unittest
from pathlib import Path
from unittest.mock import patch
from add_samples import fetch, source_allowed, playback_options, ARCHIVAL_SOURCES

class SampleSourceSafetyTests(unittest.TestCase):
    def test_only_exact_official_https_hosts(self):
        self.assertTrue(source_allowed('https://download.blender.org/ED/film.mov'))
        self.assertTrue(source_allowed('https://video.blender.org/object-storage/film.mp4'))
        for value in ['http://download.blender.org/film.mp4',
                      'https://download.blender.org.evil.example/film.mp4',
                      'https://video.blender.org@evil.example/film.mp4',
                      'https://user:password@video.blender.org/film.mp4',
                      'https://video.blender.org:443/film.mp4',
                      'https://video.blender.org/film.mp4?ApiKey=secret',
                      'https://video.blender.org/film.mp4#secret',
                      'https://video.blender.org:invalid/film.mp4']:
            with self.subTest(value=value):
                self.assertFalse(source_allowed(value))

    def test_rejected_source_does_not_start_network_or_open_a_file(self):
        with patch('urllib.request.build_opener') as opener:
            with self.assertRaises(RuntimeError):
                fetch('https://example.com/film.mp4', Path('/not-used.mp4'))
            opener.assert_not_called()

    def test_archival_downloads_are_exactly_allowlisted(self):
        for url in ARCHIVAL_SOURCES:
            self.assertTrue(source_allowed(url))
            self.assertFalse(source_allowed(url + '?redirect=1'))
        self.assertFalse(source_allowed('https://upload.wikimedia.org/wikipedia/commons/other.webm'))

    def test_silent_archive_never_keeps_added_music(self):
        options, copied, audio = playback_options({'streams': [
            {'codec_type': 'video', 'codec_name': 'vp9'},
            {'codec_type': 'audio', 'codec_name': 'opus'}]},
            {'source': next(iter(ARCHIVAL_SOURCES)), 'silent_original': True})
        self.assertIn('-an', options)
        self.assertNotIn('0:a:0', options)
        self.assertIn('libx264', options)
        self.assertFalse(copied)
        self.assertFalse(audio)

    def test_open_film_keeps_original_compatible_streams(self):
        options, video, audio = playback_options({'streams': [
            {'codec_type': 'video', 'codec_name': 'h264'},
            {'codec_type': 'audio', 'codec_name': 'aac', 'channels': 2}]}, {})
        self.assertTrue(video and audio)
        self.assertIn('0:a:0', options)
        self.assertNotIn('-an', options)

if __name__ == '__main__':
    unittest.main()
