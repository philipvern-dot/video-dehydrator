# Video Dehydrator

Version 1.0.6.1

A Windows program that finds videos that are too big for their picture size, encodes a smaller copy, and puts that copy where the original was.

Double-click **Video Dehydrator** in this folder. If that shortcut does nothing, open `app\launch.vbs` once. That starts the program and repairs the shortcut.

Choose a folder and click Scan. Checked rows are the ones Convert will shrink. Estimated savings uses the New size column. If the picture rate is missing, New size starts with ~ and uses the target rate times the length. Over shows how many times the budget a file uses. Slight, Heavy, and Extreme can be checked as one group. The original is kept in `.vd-originals` until you delete it. Compare plays the new file. Undo puts the last conversion back.

The bottom right corner shows this copy's version. The program checks for updates when it opens. Check for updates looks again. When a newer version is found, a window tells you once. After you close it, it stays closed until a later version is published. The status line keeps saying that version is available. Update downloads that version and opens the setup program. The setup replaces the installed copy and keeps your settings. Donate opens a tip page. The program stays free. Report a bug opens a GitHub page with this version and the Windows version filled in. Include latest activity is optional. Leave it unchecked and nothing else is added.

## What's new in 1.0.6.1

Space Saved shows the original file size minus the converted file. It fills in when a convert finishes.

Drag a heading sideways to move that column. The rows move with it. The order is remembered. An update can put the columns back. A click still sorts, and the edge of a heading still changes its width.

## What's new in 1.0.6

Delete originals, and automatic delete, also remove the matching copy from a drive's `#recycle` folder when the path and the size match. The `.plexignore` from that convert is removed when it only hides the holding folder. Empty folders left by that delete are removed when nothing else is in them. The recycle folder itself stays. If that cleanup cannot finish, a window lists the problem and opens the manual steps in How this works.

Delete originals asks before it deletes. Don't show this in the future hides that question until the next version.

## What's new in 1.0.5.1

The window, taskbar, Start menu shortcut, desktop shortcut, setup program, and uninstall entry use the Video Dehydrator icon.

## What's new in 1.0.5

This is the first published update since 1.0.4.

- Donate and Report a bug are in the header. Donate opens a tip page. The program stays free. A tip of $5 or more can include a feature suggestion. Report a bug opens a GitHub page with this version and the Windows version filled in. Include latest activity is a choice. Leave it unchecked and nothing else is added. Those lines can include folder paths. The program does not send the report. You submit it on the GitHub page.
- Re-encode audio that cannot be copied is a new option. Some audio, such as Windows Media Audio, cannot be copied into the new file. With the option on, that audio is re-encoded to AAC and the convert can finish. With it off, the convert stops and the original stays. Audio that can be copied is still copied either way.
- When the new file is not smaller, the row says Skipped and the activity box says why. The larger file is discarded. Later scans leave that file off the list while it stays the same size and the budget is the same or higher. A smaller budget lists it again. Clear skips forgets those marks.
- Picture is now Dimensions, and About is now New size. A New size that starts with ~ had no picture rate, so that guess uses the target rate times the length. Each budget has a color, and Dimensions uses that same color.
- Clear removes the scanned files from the list. Files still waiting in .vd-originals stay.
- The activity box lists each step, and a moving Working mark shows that a job is still running. The running percent stays on the bar.
- Compare says the sound will not stay in sync with the picture. Open the file on disk to confirm the audio.
- The program checks for updates when it opens. A window opens the first time a newer version is found. Closing it keeps it from opening again until a later version is published. The status line keeps saying that version is available.
- The first time Delete originals automatically is turned on, the program explains what you give up. You can choose not to see that warning again.
- A convert can finish when the only check note is a harmless timing message. Any other problem still leaves the original in place.
- Setup asks separately for a Start menu shortcut and a desktop shortcut.

## Tools

The program looks for these files in `tools\`:

- `HandBrakeCLI.exe`
- `ffmpeg.exe`
- `ffprobe.exe`
- `ffplay.exe`

They are not in this repository. Each one is larger than GitHub allows. Copy them into `tools\` yourself, or run the Windows setup program `video_dehydrator.exe`. That installs this program and those tools for the current user. During setup you can choose a Start menu shortcut and a desktop shortcut separately. Setup also registers an uninstall entry in Windows Settings.

FFmpeg's license is `tools\FFmpeg-LICENSE.txt`. HandBrake's license is `tools\HandBrake-LICENSE.txt`.

## Support

Video Dehydrator is free and always will be.

[![Support on Ko-fi](https://img.shields.io/badge/Ko--fi-Support-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/philipvern)

- **Tips:** welcome at [ko-fi.com/philipvern](https://ko-fi.com/philipvern). Pick $1, $2, $5, or a custom amount. A tip of $5 or more can include a feature suggestion.
- **Bugs:** Report a bug in the program opens a GitHub page with this version and the Windows version filled in. Include latest activity is optional.
- **Commissions:** I'm open to them. Reach out through Ko-fi.

## License

This program is released under the MIT License. See [LICENSE](LICENSE).

HandBrake and FFmpeg are separate programs and keep their own licenses. HandBrake is GPL-2.0. FFmpeg is GPL-3.0.
