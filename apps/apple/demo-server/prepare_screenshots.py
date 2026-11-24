#!/usr/bin/env python3
"""Prepare saved resume state only for the isolated demo's existing viewer.

This is sample-account staging, not evidence of watched or decoded playback.
Existing watch progress, completed titles, favorites and other accounts survive.
"""
import argparse
from datetime import datetime, timezone
import json
import re
import sys
import urllib.parse

from demo import Demo, SERVER, VERSION, require, save_private

SAMPLES = [("Big Buck Bunny", 2008, 0.35), ("Sintel", 2010, 0.40), ("Tears of Steel", 2012, 0.55)]


def prepare(demo):
    require(not demo.public_https, 'Progress preparation stays on the verified local demo')
    require(demo.credentials and demo.info.get('Id') == demo.credentials['server_id']
            and demo.info.get('ServerName') == SERVER and demo.info.get('Version') == VERSION)
    user = demo.login(demo.credentials['viewer'])
    require(user.get('Name') == demo.credentials['viewer']['username']
            and (user.get('Policy') or {}).get('IsAdministrator') is False,
            'Use only the existing restricted demo viewer')
    query = urllib.parse.urlencode({'userId': user['Id']})
    resume_path = '/UserItems/Resume?' + query + '&limit=20&mediaTypes=Video'
    before = demo.api(resume_path)['Items']
    items = demo.api('/Items?' + query + '&recursive=true&includeItemTypes=Movie&limit=30')['Items']
    changes = []
    preserved = []
    # Complete the preflight before writing any user data.
    for title, year, fraction in SAMPLES:
        matches = [i for i in items if i.get('Name') == title and i.get('ProductionYear') == year
                   and i.get('Type') == 'Movie']
        require(len(matches) == 1, 'Expected one complete, licensed demo title: ' + title)
        item = matches[0]
        require(re.fullmatch(r'[A-Za-z0-9_-]{1,128}', item['Id']) is not None)
        duration = item.get('RunTimeTicks', 0)
        require(isinstance(duration, int) and duration >= 300 * 10_000_000,
                'Resume samples must be at least five minutes long')
        path = '/UserItems/' + item['Id'] + '/UserData?' + query
        current = demo.api(path)
        if current.get('Played') or (current.get('PlaybackPositionTicks') or 0) > 0:
            preserved.append(title)
            continue
        updated = dict(current, PlaybackPositionTicks=int(duration * fraction), Played=False,
                       PlayCount=max(1, current.get('PlayCount') or 0),
                       LastPlayedDate=datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'))
        changes.append({'title': title, 'id': item['Id'], 'path': path, 'before': current, 'after': updated})
    if changes:
        stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
        save_private(demo.root / 'private' / ('screenshot-progress-before-' + stamp + '.json'),
                     {'serverId': demo.info['Id'], 'viewerId': user['Id'], 'items': changes})
    attempted = []
    try:
        for change in changes:
            attempted.append(change)  # Restore uncertain delivery as well as acknowledged writes.
            demo.api(change['path'], 'POST', change['after'])
        after = demo.api(resume_path)['Items']
        ids = {item['Id'] for item in after}
        require(all(change['id'] in ids for change in changes), 'A prepared title is missing from Resume')
        require(len(after) >= 2, 'Need at least two real resume entries for the screenshot row')
        for change in changes:
            saved = demo.api(change['path'])
            require(saved.get('PlaybackPositionTicks') == change['after']['PlaybackPositionTicks']
                    and saved.get('Played') is False, 'Resume state readback did not match')
    except Exception:
        failed = False
        for change in reversed(attempted):
            try:
                demo.api(change['path'], 'POST', change['before'])
            except Exception:
                failed = True
        require(not failed, 'Demo progress restoration failed; inspect the private checkpoint before retrying')
        raise
    evidence = {'serverVersion': demo.info['Version'], 'scope': 'existing restricted isolated-demo viewer',
                'resumeCountBefore': len(before), 'resumeCountAfter': len(after),
                'preparedTitles': [c['title'] for c in changes], 'preservedTitles': preserved,
                'resumeTitles': [i['Name'] for i in after],
                'physicalDeviceValidation': 'not performed', 'playbackDecoded': 'not tested'}
    save_private(demo.root / 'evidence' / 'screenshot-progress.json', evidence)
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--env', required=True)
    args = parser.parse_args()
    demo = Demo(args.env)  # Existing container, mounts, version and server-ID guards.
    try:
        print(json.dumps(prepare(demo), indent=2))
    finally:
        demo.logout()


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, ValueError) as error:
        print('Demo screenshot preparation failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
