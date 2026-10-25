# Podcast Player

A podcast player web app for iPhone and iPad that installs to the Home Screen from Safari.

- Plays audio and video podcasts, with Picture in Picture for video
- Favorites in the order you set (drag or arrows), plus subjects you name yourself; a show can sit under several subjects, and a subject lists only shows with something left to hear
- Each show has a Recent tab (every episode, marked New, time left or Played) and a New to me tab (not finished yet), sorted newest or oldest first
- Search: Podcast Index first (with your own free key, saved on your device), Apple Podcasts second
- Skip back and forward amounts you choose, per-show skip at start and end, and skipping of ads a show marks in its chapters
- Transcripts when a show publishes them (Podcasting 2.0), following along as it plays
- Speed, sleep timer, resume where you left off, lock screen controls
- Shows that haven't put out an episode in over a year are flagged as candidates to unfollow; you choose Unfollow or Keep for each
- Overcast OPML import, and backup and restore between devices
- Sync between devices through each person's own Dropbox (Sign in with Dropbox in Settings)

Everything you set is stored in your browser on each device. If you sign in with Dropbox, your shows, subjects, favorites order, listening spots and playback settings are also kept in one file in the app's own folder in your Dropbox, so your devices stay in step. Your Podcast Index key is never synced. Nothing else is sent anywhere except the podcast directories and the shows' own servers.

## Dropbox setup (for whoever hosts this copy)

Register a Dropbox app (Scoped access, App folder), add this site's address as an OAuth 2 redirect URI, allow public clients (PKCE), turn on files.content.read and files.content.write, and put the App key in `DBX_APP_KEY` in index.html. The App key is public; no app secret is used.
