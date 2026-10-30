# Podcast Player

A podcast player web app for iPhone and iPad that installs to the Home Screen from Safari.

- Plays audio and video podcasts, with Picture in Picture for video
- Favorites in the order you set (drag or arrows), plus subjects you name yourself; a show can sit under several subjects, and a subject lists only shows with something left to hear
- Each show has a Recent tab (every episode, marked New, time left or Played) and a New to me tab (not finished yet), sorted newest or oldest first
- Each episode row shows the start of its description; tap the title to open its details (date, length, where you are, chapters, and the full show notes with working links)
- Skip and highlight words in Settings: episodes whose title or description mentions a skip word count as played (shown as Skipped, and Hear again brings one back); ones that mention a highlight word stand out with the word under the title. A highlight always beats a skip. Transcripts the app makes are checked too: one mention highlights, a skip word needs 3 mentions, and the episode says when the match came from its transcript
- Search: Podcast Index first (with your own free key, kept in your Dropbox when you sync), Apple Podcasts second
- Skip back and forward amounts you choose, per-show skip at start and end, and skipping of ads a show marks in its chapters
- Transcripts when a show publishes them (Podcasting 2.0), following along as it plays
- Make transcripts (optional, off by default, set per device): when an episode has none, the app can make one with Whisper speech recognition running on the device (transformers.js, model downloaded once, about 41 MB). MP3 episodes from hosts that allow the app to read the audio. Finished transcripts are kept on the device and in Dropbox (Apps/<app>/transcripts), so each episode is made once. Make them ahead (set per device) can make them in advance for your starred favorites or one subject while the app is open, newest unplayed episodes first
- Speed, sleep timer, resume where you left off, lock screen controls
- Shows that haven't put out an episode in over a year are flagged as candidates to unfollow; you choose Unfollow or Keep for each
- OPML import from any podcast app (Overcast, Pocket Casts and others), and backup and restore between devices
- Sync between devices through each person's own Dropbox (Sign in with Dropbox in Settings)
- Settings > Sync shows what this device holds (shows, subjects, favorites) and which device saved Dropbox's copy last, so lists are easy to compare. An app left open checks Dropbox every two minutes and whenever its window comes to the front. Use this device's list everywhere (two taps) makes every other device take this one's shows, subjects, favorites order and settings the next time it syncs; listening spots and played marks still keep whichever is newer, and Earlier copies can undo it

Everything you set is stored in your browser on each device. If you sign in with Dropbox, your shows, subjects, favorites order, listening spots and playback settings are also kept in one file in the app's own folder in your Dropbox, so your devices stay in step. Your Podcast Index key and secret travel the same way, so you enter them once; the one saved most recently wins, an empty key never replaces a saved one, and only Remove key (two taps) takes it off every device. Nothing else is sent anywhere except the podcast directories and the shows' own servers.

## Dropbox setup (for whoever hosts this copy)

Register a Dropbox app (Scoped access, App folder), add this site's address as an OAuth 2 redirect URI, allow public clients (PKCE), turn on files.content.read and files.content.write, and put the App key in `DBX_APP_KEY` in index.html. The App key is public; no app secret is used.
