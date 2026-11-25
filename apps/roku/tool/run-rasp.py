#!/usr/bin/env python3
"""Run Zorofin's small RASP subset over Roku ECP without logging inputs.

Private scripts/credential files remain outside Git. This is a device smoke
runner, not a replacement for Roku's official cloud analysis or Remote Tool.
"""
import argparse
import json
import pathlib
import re
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET


class DeviceTestFailure(Exception):
    """A fixed, safe-to-print validation message."""


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--roku', required=True, help='Device hostname/IP, without a port')
    p.add_argument('--script', required=True, type=pathlib.Path)
    p.add_argument('--credentials', type=pathlib.Path, help='Private JSON: username/password or nested viewer')
    p.add_argument('--channel', help='Explicit launch-ID override; otherwise use the script mapping')
    p.add_argument('--validate-only', action='store_true', help='Check commands and installed launch targets without sending keys')
    p.add_argument('--skip-launch', action='store_true', help='Use a prepared Connect screen; preserve other saved accounts')
    p.add_argument('--expect', choices=['home', 'signed-out'])
    a = p.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9.:-]+', a.roku):
        p.error('Invalid device hostname/IP')
    base = 'http://' + a.roku + ':8060/'
    text = a.script.read_text()
    delay = float(re.search(r'^\s*default_keypress_wait:\s*([\d.]+)', text, re.M).group(1))
    channels = dict(re.findall(r'^ {8}([^:]+):\s*(\S+)\s*$', text, re.M))
    steps = re.findall(r'^\s*-\s+(\w+):\s*(.*)$', text, re.M)
    allowed = {'launch', 'pause', 'press', 'text', 'wait_for_player_state'}
    if any(kind not in allowed for kind, _ in steps):
        raise DeviceTestFailure('Unsupported RASP command')
    targets = {a.channel or channels.get(value.strip()) for kind, value in steps if kind == 'launch'}
    if None in targets:
        raise DeviceTestFailure('Launch alias is missing from script channels')
    installed = {n.get('id') for n in ET.fromstring(urllib.request.urlopen(base + 'query/apps', timeout=12).read())}
    if not targets.issubset(installed):
        raise DeviceTestFailure('Script launch target is not installed; sideloaded channels use dev')
    if a.validate_only:
        print(json.dumps({'valid': True, 'steps': len(steps), 'installed_launch_targets': sorted(targets)}))
        return
    creds = json.loads(a.credentials.read_text()) if a.credentials else {}
    creds = creds.get('viewer', creds)

    def request(route, post=False):
        return urllib.request.urlopen(base + route, data=b'' if post else None, timeout=12).read()

    def snapshot(step):
        ui = ET.fromstring(request('query/app-ui'))
        types = {n.tag for n in ui.iter()}
        player = ET.fromstring(request('query/media-player')).get('state')
        result = {'step': step, 'home': 'HomeScreen' in types, 'connect': 'ConnectScreen' in types,
                  'accounts': 'AccountsScreen' in types, 'keyboard': 'TextEntry' in types, 'player': player}
        print(json.dumps(result), flush=True)
        return result

    keys = {'ok': 'Select', 'play': 'Play', 'backspace': 'Backspace', 'back': 'Back',
            'up': 'Up', 'down': 'Down', 'left': 'Left', 'right': 'Right', 'options': 'Info'}
    step = 0
    for line in text.splitlines():
        match = re.match(r'\s*-\s+(\w+):\s*(.*)', line)
        if not match:
            continue
        kind, value = match.groups()
        step += 1
        if kind == 'launch':
            if not a.skip_launch:
                target = a.channel or channels[value.strip()]
                request('launch/' + urllib.parse.quote(target, safe=''), True)
                time.sleep(delay)
        elif kind == 'pause':
            time.sleep(float(value))
        elif kind == 'press':
            request('keypress/' + keys[value], True)
            time.sleep(delay)
        elif kind == 'text':
            value = {'script-login': creds.get('username'), 'script-password': creds.get('password')}.get(value, value)
            if value is None or value == 'DEMO_SERVER_URL':
                raise DeviceTestFailure('Private server or credential input is missing')
            previous = None
            for char in value:
                if char == previous:
                    time.sleep(.2)
                request('keypress/Lit_' + urllib.parse.quote(char, safe=''), True)
                time.sleep(.22)
                previous = char
            time.sleep(delay)
        elif kind == 'wait_for_player_state':
            deadline = time.monotonic() + 45
            while ET.fromstring(request('query/media-player')).get('state') != value:
                if time.monotonic() >= deadline:
                    raise DeviceTestFailure('Playback postcondition was not reached')
                time.sleep(.5)
        else:
            raise DeviceTestFailure('Unsupported RASP command at step ' + str(step))
        if kind in ('pause', 'wait_for_player_state'):
            snapshot(step)
    result = snapshot('complete')
    if a.expect == 'home' and not result['home']:
        raise DeviceTestFailure('Home was not reached')
    if a.expect == 'signed-out' and not (result['connect'] or result['accounts']):
        raise DeviceTestFailure('Signed-out screen was not reached')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Print only fixed validation messages; other errors may contain private URLs.
        detail = str(error) if isinstance(error, DeviceTestFailure) else type(error).__name__
        print('Device test failed: ' + detail, file=sys.stderr)
        sys.exit(1)
