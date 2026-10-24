# Video Dehydrator

Version 1.0.9.3

A Windows program that finds videos that are too big for their picture size, encodes a smaller copy, and puts that copy where the original was.

Double-click **Video Dehydrator** in this folder. If that shortcut does nothing, open `app\launch.vbs` once. That starts the program and repairs the shortcut.

Choose a folder and click Scan. Checked rows are the ones Optimize will shrink. ~Savings is the current size minus New size, and the first click on that heading puts the largest estimates first. If the picture rate is missing, New size and ~Savings start with ~. Ratio shows how many times the budget a file uses. `1.00x` is on the line. Slight, Heavy, and Extreme can be checked as one group. Can shrink rows are under the line and the picture is still above the target rate. Showing all leaves every row on screen until a group box is checked. The original is kept in `.vd-originals` until you delete it. Compare plays the original on the left and the new file on the right. Undo puts the last conversion back.

## What's new in 1.0.9.3

The check at the end of a file keeps a good encode when the only notes are repeated equal timestamps and one short AC3 frame. That pair shows up on some VirtualDub Xvid files. A backwards timestamp, a picture error, or more than one broken AC3 frame still fails the file.

## What's new in 1.0.9.2

Parallel jobs can run up to six files at once. The choice sits just to the left of Find. Each file still uses about 8 cores. The tooltip says how many cores each level needs. On a smaller processor, extra files share the cores and the batch does not finish sooner.

Find can stop the scan after 5, 10, 25, 50, or 100 files that can be reduced. All keeps scanning the whole folder.

A file that is still on its first pass keeps its holding folder while another file in the same folder finishes. If the second pass cannot write the new file, the program tries that same two-pass encode again.

The bar along the bottom updates twice a second, so typing stays responsive while several files encode.

## What's new in 1.0.9.1

Parallel Jobs encodes two files at the same time. Each running file has its own bar and name. One encode uses about 8 cores, so the second file helps when the processor has about 16 cores.

## What's new in 1.0.8

The time line under the bar stays still while a file converts. It keeps a rolling average and changes about every 30 seconds, and when a file starts. The bar still shows the percent.

## What's new in 1.0.7.4

Drag the bar under the video list to make that list taller or shorter. The activity box shrinks first. If you keep dragging, Options gets shorter and scrolls. Drag the other way to give the space back to the activity box. Double-click the bar to put the list back. The size is remembered.

Manual converts a chosen file or folder even when it is under the budget. Test savings reads those files and estimates the savings, then asks you to proceed or cancel. Convert now skips that estimate. Include subfolders applies when the path is a folder. Dolby Vision is still left alone, and a result that is not smaller is still thrown away.

## What's new in 1.0.7.3

While a convert is running, a line under the status shows how long this file has left and the estimated time remaining for the rest of the batch. On the first pass of the first file, the batch stays on estimating. 10-bit files are timed apart from 8-bit files. Stop after current file leaves that estimate on the file that is still running.

When Delete originals automatically is on, the convert warning has a Stop asking box. Check it and click Convert, and that warning stays off. Cancel leaves the warning on.

## What's new in 1.0.7.2

Clear the drive recycle copy is a checkbox under Delete originals automatically. It starts off. With it on, after a delete, Auto, or undo, the program removes the matching copy in `#recycle` when that file sits inside `.vd-originals` and the size matches. With it off, the drive keeps that copy.

If the removal fails, a window still explains how to delete the copy by hand. Mute on that window hides it after this one time. Later failures stay in the activity list. The steps stay in How this works.

Tooltips are one or two short sentences. The guide still has the full explanation.

## What's new in 1.0.7.1

Some older AVI files end in the middle of an AC3 sound frame. Video Dehydrator copies that sound as it is. The check at the end of the file used to treat that cut-off frame as a broken encode, throw the new file away, and leave the original in place.

1.0.7.1 keeps the new file when that cut-off frame is the only problem and the original already ended the same way.

The picture still has to decode. The beginning of the file still has to decode. A second broken frame still fails. A broken frame the original did not already have still leaves the original in place. Sound that can be copied is still copied.

## What's new in 1.0.7

Ratio replaces the Over heading. The number uses two decimal places. `1.00x` is on the budget line. A file just over the line keeps the extra digits, such as `1.04x`, so it does not look like `1.00x`.

Can shrink lists a file that is under the budget line when its picture is still above the target rate and the New size is smaller. Those rows start checked and are not colored. Select slight, Select heavy, and Select extreme leave them alone. The scan lists every file it listed before, and these rows in addition.

~Savings is a new column. It is the current size minus New size. The first click puts the largest estimates first. After a convert, that cell clears and Space Saved shows the real result.

Showing all opens a checkbox for Can shrink, Bloated, Slight, Heavy, Extreme, Failed, Skipped, Ready to delete, and Finished. With none checked, every row stays. Check one group to show only those rows, then check more groups to add them. Hidden rows are unchecked, so Optimize leaves them out. Select shown checks the rows still on screen.

The convert button is labeled Optimize. Stop after current file lets the file already encoding finish, then stops the batch. Continue keeps the batch going. Every button has a tooltip, including a button that is grayed out.

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
