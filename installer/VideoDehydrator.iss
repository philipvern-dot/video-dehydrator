; Builds video_dehydrator.exe, the setup program attached to a GitHub Release.
; The tool programs are not in git. This script reads them from the working copy.
; Compile with Inno Setup 6:
;   "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" VideoDehydrator.iss

#define AppVersion "1.0.2"
#define Repo ".."
#define ToolExe "E:\Programming\video_dehydrator\tools"

[Setup]
AppId={{F3AB4A8A-00B8-46B4-84CE-4622A6CF467A}
AppName=Video Dehydrator
AppVersion={#AppVersion}
AppPublisher=Video Dehydrator
AppCopyright=Copyright (c) 2026 Philip Miller
DefaultDirName={localappdata}\Programs\Video Dehydrator
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#Repo}
OutputBaseFilename=video_dehydrator
Compression=lzma2
SolidCompression=yes
LZMAUseSeparateProcess=yes
WizardStyle=modern
Uninstallable=yes
UninstallDisplayName=Video Dehydrator
UninstallDisplayIcon={sys}\imageres.dll
VersionInfoVersion=1.0.2.0
VersionInfoProductName=Video Dehydrator
VersionInfoCompany=Video Dehydrator
VersionInfoDescription=Installs Video Dehydrator and the tools it needs
CloseApplications=yes

[Files]
Source: "{#Repo}\app\VideoDehydrator.ps1"; DestDir: "{app}\app"
Source: "{#Repo}\app\Engine.ps1"; DestDir: "{app}\app"
Source: "{#Repo}\app\launch.vbs"; DestDir: "{app}\app"
Source: "{#Repo}\app\version.txt"; DestDir: "{app}\app"
Source: "{#Repo}\LICENSE"; DestDir: "{app}"
Source: "{#Repo}\tools\FFmpeg-LICENSE.txt"; DestDir: "{app}\tools"
Source: "{#Repo}\tools\HandBrake-LICENSE.txt"; DestDir: "{app}\tools"
Source: "{#Repo}\tools\SOURCES.txt"; DestDir: "{app}\tools"
Source: "{#ToolExe}\ffmpeg.exe"; DestDir: "{app}\tools"
Source: "{#ToolExe}\ffprobe.exe"; DestDir: "{app}\tools"
Source: "{#ToolExe}\ffplay.exe"; DestDir: "{app}\tools"
Source: "{#ToolExe}\HandBrakeCLI.exe"; DestDir: "{app}\tools"

[Icons]
Name: "{autoprograms}\Video Dehydrator"; Filename: "{sys}\wscript.exe"; Parameters: "//nologo ""{app}\app\launch.vbs"""; WorkingDir: "{app}"; IconFilename: "{sys}\imageres.dll"; IconIndex: 189; Comment: "Shrink videos that are too big for their picture size"

[Run]
Filename: "{sys}\wscript.exe"; Parameters: "//nologo ""{app}\app\launch.vbs"""; WorkingDir: "{app}"; Description: "Open Video Dehydrator"; Flags: postinstall nowait skipifsilent

[UninstallDelete]
Type: files; Name: "{app}\Video Dehydrator.lnk"
