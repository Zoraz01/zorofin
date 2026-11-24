# Isolated Jellyfin demo server

A small, real Jellyfin server for Zorofin review preparation and ordinary-server
checks. It has its own accounts, database, cache and licensed sample media. No
production data, credentials, optional backend services or media mounts belong here.
The native apps still start with an empty user-supplied server address.

## Resource and access boundaries

- Official Jellyfin 12.4 image pinned by digest; the running API must report 12.4.0.
- One standalone Compose project and dedicated bridge network. No production
  Compose files are included. The network is not an outbound firewall.
- HTTP is published only to loopback. No public route, LAN listener, discovery port,
  router forwarding or App Store review submission is configured by this setup.
- 768 MiB hard memory limit, no additional swap allowance, 0.75 CPU, two logical
  .NET processors, and workstation garbage collection for this tiny workload.
- Non-root process, no added capabilities, no Docker socket, read-only sample
  media, bounded logs, and Watchtower auto-updates explicitly disabled.
- Persistent configuration/cache/media live in a separate operator-selected runtime
  directory outside Git. The host volume and existing Docker engine must stay up.
- `unless-stopped` restarts only this service with Docker. There is no host startup
  agent and no change to Docker Desktop's shared CPU or memory settings.
- Automatic media scanning, chapter/trickplay extraction, Internet metadata and
  plugin update schedules are disabled. Refresh this small library explicitly.
- The reviewer permits ten active sessions (owner-approved October 27, 2026),
  allowing review and sample devices to coexist without ending other sessions.
  This is an account-session limit, not a concurrent-stream guarantee.
- The reviewer has no administrative or deletion rights. Video transcoding is
  disabled to bound load; audio conversion and remuxing remain allowed. Low-quality
  video conversion, HDR conversion and subtitle burn-in are not covered by this
  server. Use compatible sample files and disclose this limitation in test notes.

Jellyfin documents Docker on macOS as unsupported, particularly hardware
acceleration and scanning. This deployment uses explicit scans and preprepared
media; its local HTTP checks do not establish physical-device or review acceptance.
[Container documentation](https://jellyfin.org/docs/general/installation/container/).

## Operate

Create a private environment file outside Git with these values:

```dotenv
DEMO_DATA_DIR=/absolute/path/to/dedicated-demo-runtime
DEMO_PORT=CHOOSE_AN_UNUSED_NON_PRODUCTION_PORT
DEMO_UID=YOUR_NUMERIC_UID
DEMO_GID=YOUR_NUMERIC_GID
```

Use `id -u` and `id -g` for the host user. Give the private file mode 600. Create
`config`, `cache`, `media/movies`, `private` and `evidence` inside the dedicated
runtime directory; make its top directory accessible only to the operator. Never
point any of these at a production directory. Supply local metadata/artwork and
lawful sample files before running configuration.

Run from this directory, substituting the private environment file:

```sh
docker compose --env-file /private/path/demo.env -f compose.yaml config --quiet
docker compose --env-file /private/path/demo.env -f compose.yaml up -d jellyfin
python3 demo.py --env /private/path/demo.env configure
python3 demo.py --env /private/path/demo.env check
docker stats zorofin-demo-jellyfin --no-stream
```

Wait for the health check/startup wizard before configuration; scan completion is
also asynchronous. Configuration checks the dedicated container label, loopback
port, exact mount set, read-only media, expected version and saved server identity
before making API writes. It generates strong independent administrator/reviewer
passwords in `private/accounts.json`, mode 600. Tokens stay in memory and setup
sessions are logged out. Never copy this file into source, logs or screenshots.
A completed setup can be configured again without replacing users or passwords.
If interrupted during first-time setup, retain the saved credentials and inspect
the wizard state before retrying; do not wipe the runtime to resolve an error.

`check` signs in as the reviewer, verifies protected API-key administration is
forbidden, negotiates H.264/AAC direct playback, checks image delivery, and confirms
HTTP 206 media delivery with both Authorization headers and URL-only `ApiKey`.
Its sanitized results are saved under `evidence/`. It does not run an Apple device,
modify viewing progress, or prove AVPlayer/HLS behavior.

## Prepare Continue Watching for screenshots

The demo viewer needs saved resume state for a Continue Watching shelf. A fresh
viewer with no unfinished films correctly has no row; do not add fictional cards
to ordinary clients to fill it. Prepare sample-account progress explicitly:

```sh
python3 prepare_screenshots.py --env /private/path/demo.env
python3 -m unittest discover -s . -p 'test_*.py' -v
```

This command reuses `Demo`'s isolated-container, mount, version and server-ID
checks, signs in only as the existing non-admin reviewer and stays on the local
verified origin. It prepares partial positions only for unstarted Big Buck Bunny,
Sintel and Tears of Steel. Existing progress, completed titles, favorites and
other accounts are preserved. Repeating the command does not reset viewing state.
Private pre-write checkpoints permit recovery; failed/uncertain writes are
restored, and sanitized readback evidence is saved under `evidence/`.

On October 26, 2026, the actual Jellyfin **12.2.0** demo initially returned one
resume title, Big Buck Bunny at 446 seconds. Preparation added Sintel at 355
seconds and Tears of Steel at 403 seconds, preserving Big Buck Bunny. A repeat
made no writes. The native Swift `continueWatching()` implementation then read
all three through the verified public HTTPS endpoint without a custom backend.
These are staged demo-viewer positions, not decoded-playback evidence. The
on-device screen remains to be checked. Activity reads can retain their prior
response for up to 60 seconds; revisit Home after that interval when checking.

Stop or start only this project:

```sh
docker compose --env-file /private/path/demo.env -f compose.yaml stop jellyfin
docker compose --env-file /private/path/demo.env -f compose.yaml start jellyfin
```

Do not use production Compose files, restart Docker Desktop, or prune containers
or volumes to manage this server. Keep its persistent files when stopping it.

Before changing the pinned version, check the demo's active sessions and pull the
new digest. Stop only the demo and make a private copy of its complete config
directory before starting the new version. Verify the existing server identity
and reviewer with `demo.py check` on both loopback and the configured HTTPS route.
For rollback, stop the new container, restore the previous pin and the cold config
copy, and then start the prior version. Keep the failed config copy separately.

## Initial content and rights

The initial local library contains the full **Big Buck Bunny** film, including
its credit scroll, from the official Blender download. Video is unchanged; stereo
and surround audio were converted to AAC and the MP4 index moved to the front for
Apple playback. Local poster/backdrop images are cropped/scaled film frames.
The library description and `media/ATTRIBUTION.txt` identify those adaptations,
credit Blender Foundation and link the CC BY 3.0 license. The source archive,
original film and SHA-256 provenance manifest remain outside the repository.
No Blender logos or DVD-cover artwork were repurposed as app branding.

### Additional screenshot samples (October 23)

The isolated library also contains full **Sintel (2010)** and **Tears of Steel
(2012)**, bringing that first screenshot expansion to three movies. Both use the film's CC BY 3.0
license, retain complete credits, copy H.264 video and convert the original mixed
audio to AAC stereo. No separately licensed soundtrack album is redistributed.
Posters/backdrops are cropped/scaled frames. Each movie has local NFO metadata and
an attribution file; source hashes, output hashes and adaptation notes remain in
the private runtime `sources/<title>/provenance.json`.

`sample-catalog.json` records official sources and license evidence. After
checking volume space, add them to the verified dedicated instance with:

```sh
python3 add_samples.py --env /private/path/demo.env
```

The helper verifies container ownership/mounts/version through `Demo`, stages
downloads outside the library, publishes complete folders atomically, preserves
existing titles and requests only a demo library scan. It never restarts a
service or changes the production server/proxy. The separate source films and
archives intentionally remain available for provenance; they consume disk, not
idle server RAM. Additional titles need their own verified license entry.

Public-safe attribution suitable for release materials is prepared in
`../release-site/credits.html`. Keep required credits with exported screenshots.

- [Sintel sharing terms](https://durian.blender.org/sharing/)
- [Tears of Steel film license](https://mango.blender.org/about/)

### Fuller screenshot library

The latest isolated library has **six complete films**: the three above plus
**Elephants Dream (2006)**, **Caminandes 2: Gran Dillama (2013)** and **Caminandes 3:
Llamigos (2016)**. The official video host supplies the small 1080p Caminandes
files. Already compatible stereo AAC is copied; other audio is converted as
needed. There are no duplicate clips presented as different movies, invented
ratings, or fake 4K/HDR labels. Poster framing is checked separately from the
landscape images used in the hero.

Elephants Dream uses CC BY 2.5. Gran Dillama's retained closing license card
explicitly says CC BY 3.0. The official Blender publisher labels Llamigos
“Attribution” (`licence.id=1`); its metadata does not state a license version,
which is recorded without inventing one. All credits and the original film mix
remain in the complete videos. Do not redistribute the separately licensed
soundtrack albums. The catalog and generated public/native media-credit pages
record these source-specific permissions.

The helper accepts only exact official Blender HTTPS source hosts, rejects
credentials/query strings/unexpected redirects, bounds download/extraction sizes,
and requires the full duration appropriate to each title. Source-boundary tests
join the existing demo endpoint-safety tests.

- [Elephants Dream permission](https://orange.blender.org/press/)
- [Gran Dillama full film and closing license](https://video.blender.org/videos/watch/fb70d459-48d2-4db5-adba-813c84f9200a)
- [Llamigos publisher license metadata](https://video.blender.org/api/v1/videos/23f3ef79-15dc-44c5-aa45-cf92e78a4509)

- [Official film](https://video.blender.org/videos/watch/bf1f3fb5-b119-4f9f-9930-8e20e892b898)
- [Official download directory](https://download.blender.org/demo/movies/BBB/)
- [Creative Commons attribution license](https://creativecommons.org/licenses/by/3.0/)

## HTTPS verification

Keep the origin port on loopback and route a dedicated HTTPS hostname through the
operator's reverse proxy. Use a DNS-only record to the streaming-capable origin or
relay. Do not attach the demo to production accounts, media or optional backends.
Prepare and validate the new route before applying it; preserve active viewers and
follow the host's proxy deployment procedure. A prepared route is not a live URL.

Once DNS and a publicly trusted certificate work, run:

```sh
python3 demo.py --env /private/path/demo.env --url https://demo.example.com check
python3 -m unittest discover -s . -p test_demo.py -v
```

The external check first compares the anonymous public server ID, version, name
and setup state with the owned local instance. Only then does it send the demo
reviewer credentials. Plain HTTP, embedded URL credentials, paths, query strings
and fragments are rejected. Redirects are never followed, including authenticated
media requests. Certificate verification remains enabled; use your Python
installation's trusted CA bundle (`SSL_CERT_FILE`) if it lacks the host trust store.
Do not disable verification to make a check pass.

External results go to `evidence/https-checks.json`; local results remain separate
in `evidence/http-checks.json`. Both verify that anonymous library browsing and
reviewer API-key administration are denied. The pinned runtime serves a known
movie's direct stream without authentication; the checker records that status
explicitly. A 206 media response alone therefore does not prove authentication.
This demo contains only licensed public sample media. Native AVPlayer, HLS segment
handling and physical-device acceptance still require their own checks.

## Before reviewer use

Set a dedicated HTTPS address and controlled route to this instance, then validate
external login and actual iPhone/tvOS playback. Do not route to production or put
its address or credentials in review materials. A loopback URL is not reachable
from Apple reviewers, an iPhone or an Apple TV. Keep reviewer credentials private
and separate from the administrator, and provide them only in the review channel.

Expand the small library with licensed episodes/subtitle tracks for the intended
feature walkthrough, preserving attribution. Requests, support and notifications
need separate demo services if they are to be demonstrated; none are connected.
The friend's independent-server test and the Release physical-device matrix remain
separate open gates. See beta readiness.
