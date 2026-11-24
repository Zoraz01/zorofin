# Offline downloads (iPhone and iPad)

Zorofin can save movies and episodes on iPhone and iPad and play them without a
connection. Apple TV does not download (tvOS has no lasting storage for media).

## What the viewer sees

- **Download button** on movie and episode pages (next to Favorite and Watched).
  It offers four qualities with a size estimate: Original, High (20 Mbps),
  Standard (8 Mbps) and Data saver (4 Mbps). The audio and subtitle choices on
  the page are used for the saved copy; subtitles are burned in when chosen.
  While downloading the button shows a progress ring; tap it to cancel. When
  finished it turns green and offers **Remove download**.
- **Downloads** row in Profile (with the other settings rows; its subtitle shows
  the title count and space used). Shows active downloads with
  progress, finished titles (episodes grouped under their show), size and
  quality, watch progress, storage used and free space, per-title remove/retry,
  and **Remove all downloads**.
- **Offline banner** above the dock when the device has no connection; it opens
  Downloads.
- **Playback**: a downloaded title always plays from the device, from Downloads
  or from its page, using the system player (AirPlay and scrubbing included).
  Watch together still streams, so downloaded copies are not used in a group.

## How it works

- `ZorofinCore/OfflineDownloads.swift` (tested in `OfflineDownloadsTests`):
  `DownloadPlan` reuses the same `PlaybackInfo` negotiation and device profile as
  streaming. A source the device can play directly is saved as the original file
  (`/Videos/{id}/stream?static=true`). Anything else is saved from the server's
  HLS transcode at the chosen bitrate, so every copy is something AVPlayer
  already plays. When PR #55's 4K/HEVC profile lands, downloads use it too.
- `App/DownloadManager.swift`: original files use a background `URLSession`
  (`org.zorofin.app.downloads.files`); transcodes use
  `AVAssetDownloadURLSession` (`org.zorofin.app.downloads.streams`). Both keep
  running while the app is suspended and are recreated at launch
  (`ZorofinAppDelegate`) so finished work is delivered. At most two downloads run
  at once and only one transcode, to keep server load low. After a transcode
  download finishes or is cancelled, the app ends the server encoding with
  `DELETE /Videos/ActiveEncodings`.
- Storage: `Library/Application Support/Zorofin Downloads/<account>/` (excluded
  from iCloud backup) plus the system's own location for HLS packages. The index
  is `catalog.json` in the same folder. Paths are stored relative to the app
  home so they survive container moves.
- Accounts: every record belongs to one server + viewer
  (`DownloadAccount.key`). Other accounts never see them. Removing a saved
  account deletes its downloads. Signing out keeps them for the next sign-in.
- Offline progress: the player saves the position every 10 seconds and on close
  using Jellyfin's resume rules (under 5% starts over, 90% or more is watched).
  When the device is online again it is sent with
  `POST /UserItems/{id}/UserData`.

## Testing checklist (physical device)

HLS (`AVAssetDownloadURLSession`) downloads do not run in the Simulator, so use
an iPhone or iPad.

1. Download an MP4/H.264 movie at Original; confirm it is saved as a file and
   plays in airplane mode.
2. Download an MKV/HEVC title at Standard; confirm progress moves, it finishes
   while the app is in the background, and plays in airplane mode.
3. Watch part of a download offline, reconnect, and confirm the resume point
   appears on the server and other devices.
4. Remove a download; confirm storage numbers update.
5. Switch to another account; confirm its Downloads tab is empty.
