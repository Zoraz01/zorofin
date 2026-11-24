"""Progress preparation boundaries and recovery; no Docker or network."""
import copy
from pathlib import Path
import tempfile
import unittest
from urllib.parse import urlsplit

from demo import SERVER, VERSION
from prepare_screenshots import prepare, SAMPLES


class SampleDemo:
    def __init__(self, root):
        self.root = Path(root)
        self.public_https = False
        self.credentials = {'server_id': 'sample-server', 'viewer': {'username': 'Reviewer'}}
        self.info = {'Id': 'sample-server', 'ServerName': SERVER, 'Version': VERSION}
        self.user = {'Id': 'viewer', 'Name': 'Reviewer', 'Policy': {'IsAdministrator': False}}
        self.items = [{'Id': str(n), 'Name': name, 'Type': 'Movie', 'ProductionYear': year,
                       'RunTimeTicks': 800 * 10_000_000} for n, (name, year, _) in enumerate(SAMPLES)]
        self.data = {i['Id']: {'PlaybackPositionTicks': 0, 'Played': False, 'PlayCount': 0,
                              'IsFavorite': True} for i in self.items}
        self.data['0']['PlaybackPositionTicks'] = 200 * 10_000_000
        self.posts = []
        self.hide_prepared = False

    def login(self, account):
        return self.user

    def api(self, path, method='GET', data=None):
        route = urlsplit(path).path
        if route == '/Items':
            return {'Items': copy.deepcopy(self.items)}
        if route == '/UserItems/Resume':
            return {'Items': [copy.deepcopy(i) for i in self.items if
                             self.data[i['Id']]['PlaybackPositionTicks'] > 0
                             and not self.data[i['Id']]['Played']
                             and (not self.hide_prepared or i['Id'] == '0')]}
        key = route.split('/')[2]
        if method == 'POST':
            self.posts.append((key, copy.deepcopy(data)))
            self.data[key] = copy.deepcopy(data)
        return copy.deepcopy(self.data[key])


class ScreenshotProgressTests(unittest.TestCase):
    def test_existing_progress_favorites_and_other_accounts_are_preserved(self):
        with tempfile.TemporaryDirectory() as root:
            demo = SampleDemo(root)
            before = copy.deepcopy(demo.data['0'])
            result = prepare(demo)
            self.assertEqual(demo.data['0'], before)
            self.assertEqual(result['resumeCountAfter'], 3)
            self.assertEqual({key for key, _ in demo.posts}, {'1', '2'})
            self.assertTrue(all(value['IsFavorite'] for value in demo.data.values()))
            self.assertTrue(all(path.stat().st_mode & 0o777 == 0o600
                                for path in (Path(root) / 'private').glob('*.json')))

    def test_repeated_preparation_does_not_reset_viewing_progress(self):
        with tempfile.TemporaryDirectory() as root:
            demo = SampleDemo(root)
            prepare(demo)
            demo.posts.clear()
            result = prepare(demo)
            self.assertEqual(demo.posts, [])
            self.assertEqual(result['preparedTitles'], [])

    def test_completed_sample_is_not_reset(self):
        with tempfile.TemporaryDirectory() as root:
            demo = SampleDemo(root)
            demo.data['1']['Played'] = True
            result = prepare(demo)
            self.assertTrue(demo.data['1']['Played'])
            self.assertEqual(result['resumeCountAfter'], 2)
            self.assertEqual({key for key, _ in demo.posts}, {'2'})

    def test_wrong_server_public_endpoint_or_admin_is_rejected_before_writes(self):
        for issue in ['server', 'https', 'admin']:
            with self.subTest(issue=issue), tempfile.TemporaryDirectory() as root:
                demo = SampleDemo(root)
                if issue == 'server': demo.info['Id'] = 'different-server'
                if issue == 'https': demo.public_https = True
                if issue == 'admin': demo.user['Policy']['IsAdministrator'] = True
                with self.assertRaises(RuntimeError): prepare(demo)
                self.assertEqual(demo.posts, [])

    def test_failed_resume_readback_restores_attempted_changes(self):
        with tempfile.TemporaryDirectory() as root:
            demo = SampleDemo(root)
            before = copy.deepcopy(demo.data)
            demo.hide_prepared = True
            with self.assertRaises(RuntimeError): prepare(demo)
            self.assertEqual(demo.data, before)

    def test_missing_or_ambiguous_sample_fails_preflight_without_writes(self):
        for duplicate in [True, False]:
            with self.subTest(duplicate=duplicate), tempfile.TemporaryDirectory() as root:
                demo = SampleDemo(root)
                if duplicate: demo.items.append(demo.items[1].copy())
                else: demo.items.pop()
                with self.assertRaises(RuntimeError): prepare(demo)
                self.assertEqual(demo.posts, [])


if __name__ == '__main__':
    unittest.main()
