#!/usr/bin/env python3
"""Configure and check only the dedicated local Zorofin demo container.

Credentials stay in the private runtime directory; no tokens are persisted or printed.
"""
import argparse
import json
import os
from pathlib import Path
import secrets
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

NAME = 'zorofin-demo-jellyfin'
SERVER = 'Zorofin Demo'
VERSION = '12.4.0'


class NoRedirects(urllib.request.HTTPRedirectHandler):
    # Never forward a password, Authorization header or ApiKey to another origin.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def require(condition, message='Demo ownership or validation check failed'):
    if not condition:
        raise RuntimeError(message)


def save_private(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump(value, f, indent=2)
    path.chmod(0o600)


class Demo:
    def __init__(self, env):
        values = dict(line.split('=', 1) for line in Path(env).read_text().splitlines()
                      if line and not line.startswith('#'))
        self.root = Path(values['DEMO_DATA_DIR']).resolve()
        port = int(values['DEMO_PORT'])
        if port == 8096 or not 1024 <= port <= 65535:
            raise ValueError('Use a dedicated non-production port')
        container = json.loads(subprocess.check_output(['docker', 'inspect', NAME]))[0]
        require(container['Config']['Labels'].get('org.zorofin.purpose') == 'isolated-review-demo')
        bindings = container['HostConfig']['PortBindings']['8096/tcp']
        require(bindings == [{'HostIp': '127.0.0.1', 'HostPort': str(port)}])
        mounts = {v['Destination']: v for v in container['Mounts'] if v['Type'] == 'bind'}
        require(set(mounts) == {'/config', '/cache', '/media'})
        for key in mounts:
            require(Path(mounts[key]['Source']).resolve() == self.root / key[1:])
        require(mounts['/media']['RW'] is False)
        self.base = f'http://127.0.0.1:{port}'
        self.token = None
        self.public_https = False
        self.opener = urllib.request.build_opener(
            NoRedirects(), urllib.request.HTTPSHandler(context=ssl.create_default_context()))
        self.credentials_path = self.root / 'private' / 'accounts.json'
        self.credentials = json.loads(self.credentials_path.read_text()) if self.credentials_path.exists() else None
        self.info = self.api('/System/Info/Public')
        require(self.info['Version'] == VERSION, 'Revalidate before changing the pinned server version')
        if self.credentials:
            require(self.credentials['server_id'] == self.info['Id'])
        if self.info['StartupWizardCompleted']:
            require(self.credentials is not None)
            require(self.info['ServerName'] == SERVER)

    def use_https(self, url):
        parsed = urllib.parse.urlsplit(url)
        require(parsed.scheme == 'https' and parsed.hostname and not parsed.username
                and not parsed.password and not parsed.query and not parsed.fragment
                and parsed.path in ('', '/'), 'Use a plain HTTPS server origin')
        require(self.token is None, 'Select the endpoint before signing in')
        local_base = self.base
        self.base = url.rstrip('/')
        try:
            public = self.api('/System/Info/Public', anonymous=True)
            require(public.get('Id') == self.info['Id']
                    and public.get('Version') == self.info['Version']
                    and public.get('ServerName') == SERVER
                    and public.get('StartupWizardCompleted') is True,
                    'Public endpoint does not identify this configured demo server')
        except Exception:
            self.base = local_base
            raise
        self.public_https = True

    def api(self, path, method='GET', data=None, headers=None, raw=False, anonymous=False):
        auth = 'MediaBrowser Client="Zorofin Demo Setup", Device="Local setup", DeviceId="zorofin-demo-setup", Version="1"'
        if self.token:
            auth += ', Token="' + self.token + '"'
        h = {'Authorization': auth, 'Content-Type': 'application/json'}
        if anonymous:
            h.pop('Authorization')
        h.update(headers or {})
        req = urllib.request.Request(self.base + path, method=method, headers=h,
                                     data=json.dumps(data).encode() if data is not None else None)
        try:
            with self.opener.open(req, timeout=30) as r:
                body = r.read()
                if raw:
                    return r.status, body
                return json.loads(body) if body else None
        except urllib.error.HTTPError as e:
            raise RuntimeError(f'{method} {path.split("?")[0]}: HTTP {e.code}') from None
        except urllib.error.URLError:
            # Do not render exceptions that might include an authenticated URL.
            raise RuntimeError(f'{method} {path.split("?")[0]}: connection or certificate check failed') from None

    def login(self, account):
        auth = self.api('/Users/AuthenticateByName', 'POST', {
            'Username': account['username'], 'Pw': account['password']})
        self.token = auth['AccessToken']
        return auth['User']

    def logout(self):
        if self.token:
            self.api('/Sessions/Logout', 'POST')
            self.token = None

    def configure(self):
        if self.credentials is None:
            self.credentials = {'server_id': self.info['Id'], 'admin': {
                'username': 'DemoAdmin', 'password': secrets.token_urlsafe(24)}, 'viewer': {
                'username': 'Reviewer', 'password': secrets.token_urlsafe(18)}}
            save_private(self.credentials_path, self.credentials)
        if not self.info['StartupWizardCompleted']:
            self.api('/Startup/User')
            self.api('/Startup/User', 'POST', {
                'Name': self.credentials['admin']['username'],
                'Password': self.credentials['admin']['password']})
            self.login(self.credentials['admin'])
            self.api('/Startup/Configuration', 'POST', {'ServerName': SERVER,
                'UICulture': 'en-US', 'MetadataCountryCode': 'US', 'PreferredMetadataLanguage': 'en'})
            self.api('/Startup/RemoteAccess', 'POST', {'EnableRemoteAccess': True})
            self.api('/Startup/Complete', 'POST')
        else:
            self.login(self.credentials['admin'])
        config = self.api('/System/Configuration')
        config.update({'ServerName': SERVER, 'QuickConnectAvailable': True,
                       'EnableMetrics': False, 'EnableLegacyAuthorization': False,
                       'LogFileRetentionDays': 3, 'ParallelImageEncodingLimit': 1, 'LibraryScanFanoutConcurrency': 1,
                       'LibraryMetadataRefreshConcurrency': 1, 'PluginRepositories': []})
        self.api('/System/Configuration', 'POST', config)
        users = self.api('/Users')
        viewer = next((u for u in users if u['Name'] == self.credentials['viewer']['username']), None)
        if not viewer:
            viewer = self.api('/Users/New', 'POST', {'Name': self.credentials['viewer']['username'],
                                                   'Password': self.credentials['viewer']['password']})
        policy = viewer['Policy']
        policy.update({'IsAdministrator': False, 'IsHidden': True, 'EnableAllFolders': True,
            'EnableMediaPlayback': True, 'EnableRemoteAccess': True, 'EnableUserPreferenceAccess': True,
            'EnableContentDeletion': False, 'EnableContentDeletionFromFolders': [],
            'EnableContentDownloading': False, 'EnableMediaConversion': False,
            'EnableVideoPlaybackTranscoding': False, 'EnableAudioPlaybackTranscoding': True,
            'EnablePlaybackRemuxing': True, 'EnableSyncTranscoding': False,
            'EnableRemoteControlOfOtherUsers': False, 'EnableSharedDeviceControl': False,
            'EnableLiveTvManagement': False, 'EnableLiveTvAccess': False,
            'EnableCollectionManagement': False, 'EnableSubtitleManagement': False,
            'EnableLyricManagement': False, 'EnablePublicSharing': False, 'MaxActiveSessions': 10})
        self.api('/Users/' + viewer['Id'] + '/Policy', 'POST', policy)
        admin = next(u for u in users if u['Name'] == self.credentials['admin']['username'])
        admin['Policy']['IsHidden'] = True
        self.api('/Users/' + admin['Id'] + '/Policy', 'POST', admin['Policy'])
        libraries = self.api('/Library/VirtualFolders')
        if not any(x['Name'] == 'Demo Movies' for x in libraries):
            self.api('/Library/VirtualFolders?' + urllib.parse.urlencode({
                'name': 'Demo Movies', 'collectionType': 'movies', 'refreshLibrary': 'false'}),
                'POST', {'LibraryOptions': {'Enabled': True, 'PathInfos': [{'Path': '/media/movies'}],
                    'EnableRealtimeMonitor': False, 'EnableInternetProviders': False,
                    'EnableLUFSScan': False, 'EnableChapterImageExtraction': False,
                    'ExtractChapterImagesDuringLibraryScan': False,
                    'EnableTrickplayImageExtraction': False, 'ExtractTrickplayImagesDuringLibraryScan': False,
                    'SaveLocalMetadata': False, 'AutomaticRefreshIntervalDays': 0,
                    'SubtitleDownloadLanguages': [], 'TypeOptions': [{'Type': 'Movie',
                        'MetadataFetchers': [], 'ImageFetchers': []}]}})
        for task in self.api('/ScheduledTasks'):
            if task['Key'] in ('RefreshLibrary', 'ExtractChapterImages', 'ExtractKeyFrames',
                               'ExtractTrickplayImages', 'UpdatePlugins'):
                self.api('/ScheduledTasks/' + task['Id'] + '/Triggers', 'POST', [])
        self.api('/Library/Refresh', 'POST')
        self.logout()
        print('Demo configuration completed; viewer credentials saved privately.')

    def check(self):
        user = self.login(self.credentials['viewer'])
        require(not user['Policy']['IsAdministrator'])
        require(not user['Policy']['EnableContentDeletion'])
        require(not user['Policy']['EnableVideoPlaybackTranscoding'])
        items = self.api('/Items?' + urllib.parse.urlencode({'UserId': user['Id'],
            'Recursive': 'true', 'IncludeItemTypes': 'Movie', 'Fields': 'MediaSources,MediaStreams,Overview'}))['Items']
        require(items, 'Library scan has not produced any movies yet')
        try:
            self.api('/Auth/Keys')
        except RuntimeError as error:
            require('HTTP 403' in str(error), 'Unexpected administration response')
        else:
            raise RuntimeError('Reviewer unexpectedly has administrative access')
        try:
            self.api('/Items?Recursive=true', anonymous=True)
        except RuntimeError as error:
            require('HTTP 401' in str(error), 'Unexpected anonymous library response')
        else:
            raise RuntimeError('Library unexpectedly accessible without authentication')
        results = []
        for item in items:
            result = {'name': item['Name'], 'media_sources': len(item.get('MediaSources', []))}
            try:
                status, _ = self.api('/Videos/' + item['Id'] + '/stream?Static=true',
                                     headers={'Range': 'bytes=0-1'}, raw=True, anonymous=True)
                result['anonymous_stream_status'] = status
            except RuntimeError as error:
                require('HTTP 401' in str(error), 'Unexpected anonymous media response')
                result['anonymous_stream_status'] = 401
            # Jellyfin exposes some stream routes without auth when the item ID is
            # known. Record the runtime behavior; a successful stream alone does
            # not prove authentication. Only licensed public samples belong here.
            playback = self.api('/Items/' + item['Id'] + '/PlaybackInfo', 'POST', {
                'UserId': user['Id'], 'MaxStreamingBitrate': 40000000,
                'EnableDirectPlay': True, 'EnableDirectStream': True, 'EnableTranscoding': False,
                'DeviceProfile': {'Name': 'Demo H264 AAC check', 'MaxStreamingBitrate': 40000000,
                    'MaxStaticBitrate': 40000000, 'DirectPlayProfiles': [{'Container': 'mp4,m4v',
                        'Type': 'Video', 'VideoCodec': 'h264', 'AudioCodec': 'aac'}]}})
            require(any(s.get('SupportsDirectPlay') for s in playback.get('MediaSources', [])))
            result['direct_play_negotiation'] = True
            status, data = self.api('/Videos/' + item['Id'] + '/stream?Static=true',
                                    headers={'Range': 'bytes=0-65535'}, raw=True)
            require(status == 206 and len(data) == 65536)
            status, data = self.api('/Videos/' + item['Id'] + '/stream?' +
                urllib.parse.urlencode({'Static': 'true', 'ApiKey': self.token}),
                headers={'Range': 'bytes=0-65535'}, raw=True, anonymous=True)
            require(status == 206 and len(data) == 65536)
            result['query_auth_stream'] = status
            result['ranged_stream'] = status
            status, data = self.api('/Items/' + item['Id'] + '/Images/Primary?maxWidth=200', raw=True)
            require(status == 200 and len(data) > 1000)
            result['artwork'] = status
            results.append(result)
        self.logout()
        evidence = {'anonymous_library_denied': True, 'administration_denied': True, 'server_version': self.info['Version'], 'non_admin_viewer': True,
                    'video_transcoding_disabled': True, 'items': results,
                    'physical_device_validation': 'not performed', 'public_https': 'verified' if self.public_https else 'not tested'}
        save_private(self.root / 'evidence' /
                     ('https-checks.json' if self.public_https else 'http-checks.json'), evidence)
        print(json.dumps(evidence, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--env', required=True)
    parser.add_argument('--url', help='Verify this HTTPS origin against the local demo identity before checking')
    parser.add_argument('action', choices=['configure', 'check'])
    args = parser.parse_args()
    if args.url and args.action != 'check':
        parser.error('--url is only valid with check; configuration stays local')
    try:
        demo = Demo(args.env)
        if args.url:
            demo.use_https(args.url)
        try:
            getattr(demo, args.action)()
        finally:
            demo.logout()
    except (AssertionError, RuntimeError, ValueError, urllib.error.URLError) as error:
        print(f'Demo operation failed: {error}', file=sys.stderr)
        sys.exit(1)
