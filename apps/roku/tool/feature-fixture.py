#!/usr/bin/env python3
"""Synthetic Jellyfin-shaped fixture for Roku looks/Calendar UI checks.

No real users, credentials, media, proxying or persistence. Never use for
reviewer access. Stop this temporary LAN server as soon as the checks finish.
"""
import argparse
import datetime as dt
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit, parse_qs

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--port', type=int, default=0)
p.add_argument('--state', required=True, type=Path, help='Local JSON with colors/accent/cardSize/enforced')
a = p.parse_args()
user = {'Id': 'fixture-viewer', 'Name': 'Fixture viewer', 'HasPassword': True,
        'Policy': {'IsAdministrator': False}, 'Configuration': {}}
movie = {'Id': 'fixture-movie', 'Name': 'Sample movie', 'Type': 'Movie', 'Overview': 'Synthetic UI fixture.',
         'BackdropImageTags': ['fixture'], 'ImageTags': {'Primary': 'fixture'}, 'UserData': {}}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        size = int(self.headers.get('Content-Length', '0'))
        self.rfile.read(size)  # Synthetic login values are intentionally ignored.
        self.do_GET()

    def do_GET(self):
        path = urlsplit(self.path).path.rstrip('/')
        query = parse_qs(urlsplit(self.path).query)
        status = 200
        if path == '/System/Info/Public':
            value = {'Id': 'roku-ui-fixture', 'ServerName': 'Roku UI fixture', 'Version': '12.2.0'}
        elif path == '/Users/Public': value = []
        elif path == '/QuickConnect/Enabled': value = False
        elif path == '/Users/AuthenticateByName': value = {'User': user, 'ServerId': 'roku-ui-fixture', 'AccessToken': 'synthetic-no-access'}
        elif path == '/Users/Me': value = user
        elif path == '/Zorofin/Capabilities': value = {'features': {}}
        elif path == '/Zorofin/Extras': value = {'calendar': True, 'catchUp': True}
        elif path == '/Zorofin/Web/ui/looks.json': value = {'version': 1, **json.loads(a.state.read_text())}
        elif path == '/Zorofin/Arr/Calendar':
            today = dt.date.fromisoformat(query['start'][0])
            value = {'items': [
                {'kind': 'episode', 'title': 'Sample show', 'subtitle': 'S1:E2', 'at': today.isoformat(), 'allDay': True},
                {'kind': 'movie', 'title': 'Last day movie', 'at': (today + dt.timedelta(days=27)).isoformat(), 'allDay': True},
                {'kind': 'movie', 'title': 'Outside window', 'at': (today + dt.timedelta(days=28)).isoformat(), 'allDay': True}]}
            print(json.dumps({'calendar_requested_days': query.get('days')}), flush=True)
        elif path == '/Items': value = {'Items': [movie] if query.get('includeItemTypes') != ['Series'] else []}
        elif path == '/Items/fixture-movie': value = movie
        elif path in ['/UserViews', '/UserItems/Resume', '/Shows/NextUp']: value = {'Items': []}
        elif path == '/Sessions/Logout': value = {}
        else: status, value = 404, {}
        body = json.dumps(value).encode()
        self.send_response(status);self.send_header('Content-Type', 'application/json');self.send_header('Content-Length', str(len(body)));self.end_headers();self.wfile.write(body)


server = ThreadingHTTPServer(('0.0.0.0', a.port), Handler)
print(json.dumps({'pid': os.getpid(), 'port': server.server_port}), flush=True)
try: server.serve_forever()
except KeyboardInterrupt: pass
finally: server.server_close()
