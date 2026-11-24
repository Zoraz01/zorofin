# Screenshot film selection

The owner requested real sample films, recognizable classics and deliberately
chosen scenes rather than fictional preview titles or private library content.
Use actual LG app captures; do not composite a film into a fake player.

## November 5, 2026 expansion

`sample-catalog.json` is the executable source/attribution manifest. Run
`python3 add_samples.py --env /private/path/demo.env` from this directory. It
checks the isolated demo identity, stages complete films, preserves existing
items and requests only a demo-library scan. It never restarts shared services.
The live deployment currently requires the existing 12.4 version guard in
`demo.py`; do not relax identity/version checks to make an old checkout run.

| Film | Selected frame | Intended use |
| --- | --- | --- |
| Spring (2019) | 05:25, girl with glowing staff | Colorful fantasy poster/detail candidate |
| Cosmos Laundromat – First Cycle (2015) | 09:00, vivid pink forest | Colorful science-fiction/fantasy row |
| The Great Train Robbery (1903) | 05:00, train scene | Classic Western row |
| Sintel (2010), existing | Reassess a dragon scene before final capture | Fantasy hero candidate |
| Tears of Steel (2012), existing | Existing city/science-fiction imagery | Live-action detail/player candidate |

Spring's project About page grants CC BY 4.0; its video mirror has a differing,
unversioned share-alike label. The manifest records both rather than silently
inventing a version. Cosmos uses the project's CC BY 3.0 grant. Keep attribution
and adaptation notices with exported artwork, and retain original film credits.

The Great Train Robbery source copy is identified as the original 1903 film,
preserved by the Library of Congress. The added upload soundtrack is excluded;
the sample is silent H.264, preserving all video frames and duration. Archival
downloads use an exact URL allowlist and an identified downloader. No blanket
permission is inferred for other files on Wikimedia or modern restorations.

## Requested classics still under consideration

- The user likely means Akira Kurosawa: Seven Samurai, Rashomon and Yojimbo.
  These are visual references, not cleared sample films or approved promotional
  imagery. Check the actual edition, territories, soundtrack and stills rights.
- Night of the Living Dead (1968): the US Copyright Office confirms the original
  film entered the US public domain. This is not worldwide clearance for every
  restoration, score or poster.
- A Page of Madness (1926): candidate for Japanese cinema, but the located
  Commons copy explicitly flags an unresolved soundtrack. Not imported.
- The familiar Wizard of Oz is the 1939 Judy Garland film, not the 1925 silent
  version. Do not substitute the earlier film while implying the famous one.
- Steamboat Willie (1928) is public domain in the US but remains protected in
  some countries. Keep it out of worldwide listing artwork pending a suitable
  territorial decision.

Sources:

- https://studio.blender.org/projects/spring/pages/about/
- https://gooseberry.blender.org/sharing/
- https://www.loc.gov/item/00694220/
- https://commons.wikimedia.org/wiki/File:The_Great_Train_Robbery_1903.webm
- https://blogs.loc.gov/copyright/2020/10/copyright-horror-stories/
- https://commons.wikimedia.org/wiki/File:A_Page_of_Madness_(1926)_by_Teinosuke_Kinugasa.webm
- https://loc.gov/exhibits/oz/ozsect2.html
- https://cspd.law.duke.edu/mickey/
- https://player.bfi.org.uk/subscription/collection/akira-kurosawa

Keep server addresses, accounts, raw browser captures and runtime manifests
outside Git. Final screenshot selection and physical playback acceptance are
separate checks from successful import or HTTP delivery.
