# Video Dehydrator

Version 1.0.3

A Windows program that finds videos that are too big for their picture size, encodes a smaller copy, and puts that copy where the original was.

Double-click **Video Dehydrator** in this folder. If that shortcut does nothing, open `app\launch.vbs` once. That starts the program and repairs the shortcut.

Choose a folder and click Scan. Checked rows are the ones Convert will shrink. Over shows how many times the budget a file uses. Slight, Heavy, and Extreme can be checked as one group. The original is kept in `.vd-originals` until you delete it. Compare plays the new file. Undo puts the last conversion back.

The bottom right corner shows this copy's version. Check for updates looks for a newer version on GitHub. Update downloads that version and opens the setup program. The setup replaces the installed copy and keeps your settings.

## Tools

The program looks for these files in `tools\`:

- `HandBrakeCLI.exe`
- `ffmpeg.exe`
- `ffprobe.exe`
- `ffplay.exe`

They are not in this repository. Each one is larger than GitHub allows. Copy them into `tools\` yourself, or run the Windows setup program `video_dehydrator.exe`. That installs this program and those tools for the current user, adds a Start menu entry, and registers an uninstall entry in Windows Settings.

FFmpeg's license is `tools\FFmpeg-LICENSE.txt`. HandBrake's license is `tools\HandBrake-LICENSE.txt`.

## License

This program is released under the MIT License. See [LICENSE](LICENSE).

HandBrake and FFmpeg are separate programs and keep their own licenses. HandBrake is GPL-2.0. FFmpeg is GPL-3.0.
