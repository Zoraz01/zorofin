"""Endpoint safety tests; no Docker daemon or network needed."""
import unittest
import urllib.request
from unittest.mock import Mock

from demo import Demo, NoRedirects, SERVER, VERSION


class EndpointSafetyTests(unittest.TestCase):
    def demo(self):
        demo = Demo.__new__(Demo)
        demo.base = 'http://127.0.0.1:18097'
        demo.token = None
        demo.public_https = False
        demo.info = {'Id': 'isolated-demo', 'Version': VERSION,
                     'ServerName': SERVER, 'StartupWizardCompleted': True}
        demo.api = Mock(return_value=demo.info.copy())
        return demo

    def test_matching_server_is_verified_anonymously_before_login(self):
        demo = self.demo()
        demo.use_https('https://demo.example.com/')
        self.assertEqual(demo.base, 'https://demo.example.com')
        self.assertTrue(demo.public_https)
        demo.api.assert_called_once_with('/System/Info/Public', anonymous=True)
        self.assertIsNone(demo.token)

    def test_wrong_server_or_unconfigured_server_cannot_receive_credentials(self):
        for field, value in [('Id', 'another-server'), ('Version', '10.11.11'),
                             ('ServerName', 'Another server'), ('StartupWizardCompleted', False)]:
            with self.subTest(field=field):
                demo = self.demo()
                demo.api.return_value[field] = value
                with self.assertRaises(RuntimeError):
                    demo.use_https('https://demo.example.com')
                self.assertEqual(demo.base, 'http://127.0.0.1:18097')
                self.assertFalse(demo.public_https)

    def test_non_https_or_credential_bearing_origins_rejected_without_request(self):
        for url in ['http://demo.example.com', 'https://user:secret@demo.example.com',
                    'https://demo.example.com/?ApiKey=secret',
                    'https://demo.example.com/#secret', 'https://demo.example.com/web/',
                    'https:///missing-host']:
            with self.subTest(url=url):
                demo = self.demo()
                with self.assertRaises(RuntimeError):
                    demo.use_https(url)
                demo.api.assert_not_called()

    def test_authenticated_endpoint_cannot_be_repointed(self):
        demo = self.demo()
        demo.token = 'fixture-token'
        with self.assertRaises(RuntimeError):
            demo.use_https('https://demo.example.com')
        demo.api.assert_not_called()

    def test_connection_failure_restores_local_endpoint(self):
        demo = self.demo()
        demo.api.side_effect = RuntimeError('certificate check failed')
        with self.assertRaises(RuntimeError):
            demo.use_https('https://demo.example.com')
        self.assertEqual(demo.base, 'http://127.0.0.1:18097')
        self.assertFalse(demo.public_https)

    def test_redirects_do_not_reissue_authenticated_requests(self):
        request = urllib.request.Request('https://demo.example.com/stream?ApiKey=fixture',
                                         headers={'Authorization': 'MediaBrowser Token="fixture"'})
        for code in [301, 302, 303, 307, 308]:
            with self.subTest(code=code):
                self.assertIsNone(NoRedirects().redirect_request(
                    request, None, code, 'Redirect', {}, 'https://other.example.com/'))


if __name__ == '__main__':
    unittest.main()
