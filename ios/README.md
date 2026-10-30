# N5PREcaster for iPhone (first native build)

A SwiftUI app (iOS 17 or later) that reads the web app's list from Dropbox and plays episodes.

What this first build does:
- Signs in with Dropbox and reads `sync.json` (shows, subjects, favorites, speed and skip amounts). It asks Dropbox for read-only access, so it can never change that file.
- Episode lists straight from each show's RSS feed, kept on the phone between launches.
- Playback with background audio, lock screen and Control Center controls, speed, skip back and forward.
- Podcasting 2.0 chapters: a list to tap, chapter back and forward buttons, and each chapter's picture and title on screen and on the lock screen.
- Listening spots and played marks stay on the phone for now. A spot saved by the web app is used when the phone has none.

Not in this build yet: search, transcripts, skip and highlight words, pause trimming, writing back to Dropbox.

## Running it on an iPhone with a free Apple ID

1. Download this repository (Code, then Download ZIP) and unzip it.
2. Open `ios/N5PREcaster.xcodeproj` in Xcode.
3. Xcode, Settings, Accounts: add your Apple ID if it isn't there.
4. Click the blue N5PREcaster project at the top of the left column, then the N5PREcaster target, then Signing & Capabilities. Set Team to your Personal Team. If Xcode says the bundle identifier isn't available, change it to something of your own, such as `com.yourname.N5PREcaster`.
5. Plug in the iPhone, unlock it and tap Trust. On the iPhone, turn on Settings, Privacy & Security, Developer Mode, and let it restart.
6. Pick the iPhone at the top of the Xcode window and press Run.
7. If the iPhone says Untrusted Developer: Settings, General, VPN & Device Management, tap your Apple ID, Trust. Then Run again.

An app signed with a free Apple ID stops opening after 7 days. Plug in and press Run again to renew it.

## Dropbox

Uses the same Dropbox app as the web app (App key `9yk2nzxp65t5krk`, PKCE, no secret). Sign-in returns to the app through `db-9yk2nzxp65t5krk://2/token`. If Dropbox refuses that, Settings has Sign in with a code instead, which needs no redirect address.
