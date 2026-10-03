# Video Dehydrator
# Open "Video Dehydrator" in the parent folder. This file is the program window.

param(
    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'
$script:SmokeTest = [bool]$SmokeTest

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argList = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($SmokeTest) { $argList += '-SmokeTest' }
    if ($SmokeTest) {
        & $ps @argList
        exit $LASTEXITCODE
    }
    Start-Process -FilePath $ps -ArgumentList $argList | Out-Null
    exit 0
}

if (-not ('VideoDehydrator.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
namespace VideoDehydrator {
  public static class Native {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
  }

  public static class KeepAwake {
    public const uint ES_CONTINUOUS = 0x80000000;
    public const uint ES_SYSTEM_REQUIRED = 0x00000001;
    public const uint ES_AWAYMODE_REQUIRED = 0x00000040;
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);
    public static void Stay() {
      SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_AWAYMODE_REQUIRED);
    }
    public static void Allow() {
      SetThreadExecutionState(ES_CONTINUOUS);
    }
  }

  public static class LinePump {
    static readonly ConcurrentQueue<string> Lines = new ConcurrentQueue<string>();
    public static volatile bool Exited;
    public static int Generation;
    public static int ExitCode;
    static Process process;

    public static void Begin() {
      Generation++;
      string discard;
      while (Lines.TryDequeue(out discard)) {}
      ExitCode = 0;
      Exited = false;
    }

    public static void Accept(string line) {
      if (string.IsNullOrEmpty(line)) return;
      line = line.Trim().TrimEnd('\r');
      if (line.Length == 0) return;
      Lines.Enqueue(line);
    }

    static void ReadBrokenLines(StreamReader reader) {
      StringBuilder sb = new StringBuilder();
      while (true) {
        int value = reader.Read();
        if (value < 0) break;
        if (value == '\r' || value == '\n') {
          if (sb.Length > 0) {
            Accept(sb.ToString());
            sb.Length = 0;
          }
        } else {
          sb.Append((char)value);
        }
      }
      if (sb.Length > 0) Accept(sb.ToString());
    }

    public static void Start(string fileName, string arguments) {
      Stop();
      Begin();
      int generation = Generation;
      ProcessStartInfo psi = new ProcessStartInfo();
      psi.FileName = fileName;
      psi.Arguments = arguments;
      psi.UseShellExecute = false;
      psi.RedirectStandardOutput = true;
      psi.RedirectStandardError = true;
      psi.CreateNoWindow = true;
      Process started = new Process();
      started.StartInfo = psi;
      started.Start();
      process = started;
      Thread output = new Thread(() => { try { ReadBrokenLines(started.StandardOutput); } catch {} });
      Thread error = new Thread(() => { try { ReadBrokenLines(started.StandardError); } catch {} });
      output.IsBackground = true;
      error.IsBackground = true;
      output.Start();
      error.Start();
      Thread wait = new Thread(() => {
        try {
          output.Join();
          error.Join();
          started.WaitForExit();
          if (generation != Generation) return;
          ExitCode = started.ExitCode;
          Exited = true;
        } catch {
          if (generation != Generation) return;
          ExitCode = -1;
          Exited = true;
        }
      });
      wait.IsBackground = true;
      wait.Start();
    }

    public static void Kill() {
      try {
        if (process != null && !process.HasExited) process.Kill();
      } catch {}
    }

    public static void Stop() {
      Begin();
      try {
        if (process != null && !process.HasExited) process.Kill();
      } catch {}
      try {
        if (process != null) {
          process.Dispose();
          process = null;
        }
      } catch {}
    }

    public static string[] Drain() {
      List<string> batch = new List<string>();
      string line;
      while (Lines.TryDequeue(out line)) {
        if (!string.IsNullOrEmpty(line)) batch.Add(line);
      }
      return batch.ToArray();
    }
  }

  public sealed class FramePump : IDisposable {
    public readonly object Gate = new object();
    public byte[] Latest;
    public long FrameIndex;
    public volatile bool Running;
    public string Error;
    int width;
    int height;
    double fps;
    Process process;
    Thread reader;

    public void Start(string fileName, string arguments, int frameWidth, int frameHeight, double framesPerSecond) {
      Stop();
      width = frameWidth;
      height = frameHeight;
      fps = framesPerSecond;
      if (fps < 1) fps = 1;
      FrameIndex = 0;
      Latest = null;
      Error = null;
      Running = true;
      ProcessStartInfo psi = new ProcessStartInfo();
      psi.FileName = fileName;
      psi.Arguments = arguments;
      psi.UseShellExecute = false;
      psi.RedirectStandardOutput = true;
      psi.RedirectStandardError = true;
      psi.CreateNoWindow = true;
      process = new Process();
      process.StartInfo = psi;
      process.Start();
      Thread errors = new Thread(ReadErrors);
      errors.IsBackground = true;
      errors.Start();
      reader = new Thread(ReadFrames);
      reader.IsBackground = true;
      reader.Start();
    }

    void ReadErrors() {
      try {
        string text = process.StandardError.ReadToEnd();
        if (!string.IsNullOrEmpty(text)) Error = text;
      } catch (Exception ex) {
        if (string.IsNullOrEmpty(Error)) Error = ex.Message;
      }
    }

    void ReadFrames() {
      try {
        int size = width * height * 3;
        byte[] buffer = new byte[size];
        Stream stream = process.StandardOutput.BaseStream;
        Stopwatch clock = null;
        long index = 0;
        while (Running) {
          int got = 0;
          while (got < size) {
            int n = stream.Read(buffer, got, size - got);
            if (n <= 0) { Running = false; return; }
            got += n;
          }
          // Hold each frame until its turn. A full pipe makes ffmpeg wait,
          // so the picture stays at normal speed with the sound.
          if (clock == null) {
            clock = Stopwatch.StartNew();
          } else {
            double due = index * 1000.0 / fps;
            while (Running) {
              double wait = due - clock.Elapsed.TotalMilliseconds;
              if (wait <= 1) break;
              int slice = (int)wait;
              if (slice > 30) slice = 30;
              if (slice < 1) slice = 1;
              Thread.Sleep(slice);
            }
            if (!Running) return;
          }
          lock (Gate) {
            if (Latest == null || Latest.Length != size) Latest = new byte[size];
            Buffer.BlockCopy(buffer, 0, Latest, 0, size);
            FrameIndex++;
          }
          index++;
        }
      } catch (Exception ex) {
        Error = ex.Message;
        Running = false;
      }
    }

    public void Stop() {
      Running = false;
      try {
        if (process != null && !process.HasExited) process.Kill();
      } catch {}
      try {
        if (reader != null && reader.IsAlive) reader.Join(800);
      } catch {}
      try {
        if (process != null) {
          process.Dispose();
          process = null;
        }
      } catch {}
      reader = null;
    }

    public void Dispose() { Stop(); }
  }

  public static class QuietLog {
    const int EM_SETSEL = 0x00B1;
    const int EM_REPLACESEL = 0x00C2;
    const int WM_VSCROLL = 0x0115;
    const int SB_BOTTOM = 7;

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Auto, EntryPoint = "SendMessage")]
    static extern IntPtr SendMessageText(IntPtr hWnd, int msg, IntPtr wParam, string text);

    public static void SelectRange(IntPtr handle, int start, int end) {
      SendMessage(handle, EM_SETSEL, (IntPtr)start, (IntPtr)end);
    }

    public static void Insert(IntPtr handle, string text) {
      SendMessageText(handle, EM_REPLACESEL, IntPtr.Zero, text ?? "");
    }

    public static void ScrollToEnd(IntPtr handle) {
      SendMessage(handle, WM_VSCROLL, (IntPtr)SB_BOTTOM, IntPtr.Zero);
    }
  }
}
'@
}

function Hide-OwnConsole {
    try {
        $hwnd = [VideoDehydrator.Native]::GetConsoleWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return }
        $owner = [uint32]0
        [void][VideoDehydrator.Native]::GetWindowThreadProcessId($hwnd, [ref]$owner)
        if ($owner -eq [uint32]$PID) {
            [void][VideoDehydrator.Native]::ShowWindow($hwnd, 0)
        }
    } catch {
    }
}

if (-not $SmokeTest) { Hide-OwnConsole }

$script:AppDir = $PSScriptRoot
if (-not $script:AppDir) { $script:AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:Root = Split-Path -Parent $script:AppDir
$script:EnginePath = Join-Path $script:AppDir 'Engine.ps1'
if (-not (Test-Path -LiteralPath $script:EnginePath)) {
    throw "The engine is missing: $($script:EnginePath)"
}
. $script:EnginePath

$bundled = Get-BundledTools
$script:ToolsDir = $bundled.Tools
$script:Ffmpeg = $bundled.Ffmpeg
$script:Ffprobe = $bundled.Ffprobe
$script:Ffplay = $bundled.Ffplay
$script:HandBrake = $bundled.HandBrake
$script:SettingsPath = Join-Path $script:AppDir 'settings.json'
$script:PendingPath = Join-Path $script:AppDir 'pending.json'
$script:ConvertLogPath = Join-Path $script:AppDir 'convert-log.tsv'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$script:FontTitle = New-Object Drawing.Font('Segoe UI', 22, [Drawing.FontStyle]::Bold)
$script:FontSubtitle = New-Object Drawing.Font('Segoe UI', 10)
$script:FontSection = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold)
$script:FontUi = New-Object Drawing.Font('Segoe UI', 10)
$script:FontHint = New-Object Drawing.Font('Segoe UI', 9)
$script:FontButton = New-Object Drawing.Font('Segoe UI', 10)
$script:FontButtonBold = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
$script:FontLog = New-Object Drawing.Font('Consolas', 10)
$script:FontHelpHeading = New-Object Drawing.Font('Segoe UI', 13, [Drawing.FontStyle]::Bold)
$script:FontHelpBody = New-Object Drawing.Font('Segoe UI', 10)

$script:ColorPage = [Drawing.Color]::FromArgb(238, 241, 244)
$script:ColorInk = [Drawing.Color]::FromArgb(17, 24, 39)
$script:ColorBody = [Drawing.Color]::FromArgb(55, 65, 81)
$script:ColorMuted = [Drawing.Color]::FromArgb(75, 85, 99)
$script:ColorLine = [Drawing.Color]::FromArgb(214, 218, 225)
$script:ColorHeader = [Drawing.Color]::FromArgb(28, 36, 48)
$script:ColorHeaderMuted = [Drawing.Color]::FromArgb(209, 213, 219)
$script:ColorPrimary = [Drawing.Color]::FromArgb(29, 78, 216)
$script:ColorPrimaryHover = [Drawing.Color]::FromArgb(30, 64, 175)
$script:ColorDanger = [Drawing.Color]::FromArgb(185, 28, 28)
$script:ColorLogBg = [Drawing.Color]::FromArgb(28, 36, 48)
$script:ColorLogText = [Drawing.Color]::FromArgb(229, 231, 235)
$script:ColorLogOk = [Drawing.Color]::FromArgb(134, 239, 172)
$script:ColorLogWarn = [Drawing.Color]::FromArgb(252, 211, 77)
$script:ColorLogErr = [Drawing.Color]::FromArgb(252, 165, 165)
$script:ColorLogMuted = [Drawing.Color]::FromArgb(156, 163, 175)
$script:ColorOkText = [Drawing.Color]::FromArgb(22, 101, 52)
$script:ColorErrText = [Drawing.Color]::FromArgb(153, 27, 27)

$script:Work = 'idle'
$script:Cancel = $false
$script:ToolsOk = $false
$script:Loading = $false
$script:ProgressValue = 0
$script:InTick = $false
$script:Awake = $false
$script:LastAwake = [datetime]::MinValue
$script:Folder = ''
$script:BulkCheck = $false
$script:BloatFolderPaths = $null
$script:SavedBytes = [int64]0
$script:HbLines = New-Object System.Collections.Generic.List[string]
$script:Player = New-Object VideoDehydrator.FramePump
$script:Playing = $false
$script:Seeking = $false
$script:PlaySeconds = 0.0
$script:PlayDuration = 0.0
$script:PlayOrigin = 0.0
$script:LastFrame = [int64]-1

function Enable-DoubleBuffer($control) {
    $prop = $control.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic')
    if ($prop) { $prop.SetValue($control, $true, $null) }
}

function Get-AppIcon {
    try {
        if (-not ('VideoDehydrator.ShellIcon' -as [type])) {
            Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
namespace VideoDehydrator {
  public static class ShellIcon {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int ExtractIconEx(string file, int index, out IntPtr large, out IntPtr small, int count);
    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr hIcon);
    public static Icon Load(string file, int index) {
      IntPtr large, small;
      ExtractIconEx(file, index, out large, out small, 1);
      if (large == IntPtr.Zero) return null;
      Icon icon = (Icon)Icon.FromHandle(large).Clone();
      DestroyIcon(large);
      if (small != IntPtr.Zero) DestroyIcon(small);
      return icon;
    }
  }
}
'@
        }
        $dll = Join-Path $env:SystemRoot 'System32\imageres.dll'
        return [VideoDehydrator.ShellIcon]::Load($dll, 189)
    } catch {
        return $null
    }
}

function Update-ButtonFace($btn) {
    if ($null -eq $btn) { return }
    $role = [string]$btn.Tag
    $gray = [Drawing.Color]::FromArgb(229, 231, 235)
    $grayText = [Drawing.Color]::FromArgb(156, 163, 175)
    if (-not $btn.Enabled) {
        $btn.BackColor = $gray
        $btn.ForeColor = $grayText
        $btn.FlatAppearance.BorderColor = $gray
        $btn.FlatAppearance.MouseOverBackColor = $gray
        $btn.FlatAppearance.MouseDownBackColor = $gray
        return
    }
    if ($role -eq 'primary') {
        $btn.BackColor = $script:ColorPrimary
        $btn.ForeColor = [Drawing.Color]::White
        $btn.FlatAppearance.BorderColor = $script:ColorPrimary
        $btn.FlatAppearance.MouseOverBackColor = $script:ColorPrimaryHover
        $btn.FlatAppearance.MouseDownBackColor = $script:ColorPrimaryHover
    } elseif ($role -eq 'danger') {
        $btn.BackColor = [Drawing.Color]::White
        $btn.ForeColor = $script:ColorDanger
        $btn.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(252, 165, 165)
        $btn.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(254, 242, 242)
        $btn.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(254, 226, 226)
    } else {
        $btn.BackColor = [Drawing.Color]::White
        $btn.ForeColor = $script:ColorInk
        $btn.FlatAppearance.BorderColor = $script:ColorLine
        $btn.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(243, 244, 246)
        $btn.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(229, 231, 235)
    }
}

function New-Button([string]$text, [string]$role, [int]$width, [int]$height) {
    $btn = New-Object Windows.Forms.Button
    $btn.Text = $text
    $btn.Tag = $role
    $btn.Width = $width
    $btn.Height = $height
    $btn.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize = 1
    $btn.Cursor = [Windows.Forms.Cursors]::Hand
    $btn.UseVisualStyleBackColor = $false
    $btn.Margin = New-Object Windows.Forms.Padding(0, 4, 8, 0)
    if ($role -eq 'primary') { $btn.Font = $script:FontButtonBold } else { $btn.Font = $script:FontButton }
    $btn.Add_EnabledChanged({ Update-ButtonFace $this })
    Update-ButtonFace $btn
    return $btn
}

function New-Check([string]$text) {
    $chk = New-Object Windows.Forms.CheckBox
    $chk.Text = $text
    $chk.AutoSize = $true
    $chk.Font = $script:FontUi
    $chk.ForeColor = $script:ColorInk
    $chk.BackColor = [Drawing.Color]::White
    $chk.UseVisualStyleBackColor = $false
    return $chk
}

function Set-Tip($control, [string]$text) {
    $script:Tips.SetToolTip($control, $text)
}

function Set-Status([string]$text, [string]$kind) {
    if ($null -eq $script:StatusLabel) { return }
    if ($script:StatusLabel.Text -eq $text -and $script:StatusKind -eq $kind) { return }
    $script:StatusKind = $kind
    $script:StatusLabel.Text = $text
    if ($kind -eq 'ok') { $script:StatusLabel.ForeColor = $script:ColorOkText }
    elseif ($kind -eq 'err') { $script:StatusLabel.ForeColor = $script:ColorErrText }
    elseif ($kind -eq 'busy') { $script:StatusLabel.ForeColor = $script:ColorInk }
    else { $script:StatusLabel.ForeColor = $script:ColorMuted }
}

function Set-Progress([double]$percent) {
    if ($percent -lt 0) { $percent = 0 }
    if ($percent -gt 100) { $percent = 100 }
    $script:ProgressValue = $percent
    if ($null -eq $script:ProgressTrack) { return }
    $width = $script:ProgressTrack.ClientSize.Width
    $fill = [int][Math]::Round($width * ($percent / 100.0))
    if ($fill -lt 0) { $fill = 0 }
    if ($percent -gt 0 -and $fill -lt 6 -and $width -gt 0) { $fill = 6 }
    if ($fill -gt $width) { $fill = $width }
    $script:ProgressFill.Width = $fill
    $script:ProgressFill.Height = $script:ProgressTrack.ClientSize.Height
}

function Test-LogPinned {
    $box = $script:Log
    if ($null -eq $box -or $box.TextLength -le 1) { return $true }
    $last = $box.GetPositionFromCharIndex($box.TextLength - 1)
    return ($last.Y -le ($box.ClientSize.Height + 8))
}

function Write-Activity([string]$message, [string]$kind) {
    $box = $script:Log
    if ($null -eq $box -or $box.IsDisposed) { return }
    $color = $script:ColorLogText
    if ($kind -eq 'ok') { $color = $script:ColorLogOk }
    elseif ($kind -eq 'warn') { $color = $script:ColorLogWarn }
    elseif ($kind -eq 'err') { $color = $script:ColorLogErr }
    elseif ($kind -eq 'dim') { $color = $script:ColorLogMuted }
    $follow = Test-LogPinned
    if ($box.TextLength -gt 180000) {
        [VideoDehydrator.QuietLog]::SelectRange($box.Handle, 0, 60000)
        [VideoDehydrator.QuietLog]::Insert($box.Handle, '')
    }
    # SelectionStart and ScrollToCaret beep whenever this box is not the focused control.
    [VideoDehydrator.QuietLog]::SelectRange($box.Handle, $box.TextLength, $box.TextLength)
    $box.SelectionColor = $color
    [VideoDehydrator.QuietLog]::Insert($box.Handle, ($message + [Environment]::NewLine))
    if ($follow) { [VideoDehydrator.QuietLog]::ScrollToEnd($box.Handle) }
}

function Get-MissingTools {
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($script:HandBrake, $script:Ffmpeg, $script:Ffprobe, $script:Ffplay)) {
        if (-not (Test-Path -LiteralPath $path)) { $missing.Add($path) }
    }
    return $missing
}

function Update-Shortcut {
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $lnkPath = Join-Path $script:Root 'Video Dehydrator.lnk'
        $lnk = $wsh.CreateShortcut($lnkPath)
        $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
        $vbs = Join-Path $script:AppDir 'launch.vbs'
        $lnk.Arguments = "//nologo `"$vbs`""
        $lnk.WorkingDirectory = $script:Root
        $lnk.WindowStyle = 1
        $lnk.Description = 'Shrink videos that are too big for their picture size'
        $lnk.IconLocation = (Join-Path $env:SystemRoot 'System32\imageres.dll') + ',189'
        $lnk.Save()
    } catch {
    }
}

function Load-Settings {
    $defaults = @{
        Folder = ''
        IncludeSubfolders = $true
        AutoDelete = $false
        Detailed = $false
        Budgets = ''
        Shutdown = $false
    }
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) { return $defaults }
    try {
        $json = Get-Content -Raw -LiteralPath $script:SettingsPath -Encoding UTF8 | ConvertFrom-Json
        if ($json.folder) { $defaults.Folder = [string]$json.folder }
        if ($null -ne $json.includeSubfolders) { $defaults.IncludeSubfolders = [bool]$json.includeSubfolders }
        if ($null -ne $json.autoDelete) { $defaults.AutoDelete = [bool]$json.autoDelete }
        if ($null -ne $json.detailed) { $defaults.Detailed = [bool]$json.detailed }
        if ($json.budgets) { $defaults.Budgets = [string]$json.budgets }
        if ($null -ne $json.shutdown) { $defaults.Shutdown = [bool]$json.shutdown }
    } catch {
    }
    return $defaults
}

function Save-Settings {
    if ($script:SmokeTest) { return }
    if ($null -eq $script:SubfoldersCheck) { return }
    $folder = ''
    if ($script:FolderBox) { $folder = [string]$script:FolderBox.Text }
    $obj = [ordered]@{
        folder = $folder
        includeSubfolders = [bool]$script:SubfoldersCheck.Checked
        autoDelete = [bool]$script:AutoCheck.Checked
        detailed = [bool]$script:DetailedCheck.Checked
        budgets = (Get-SelectedBudgetPack)
        shutdown = [bool]$script:ShutdownCheck.Checked
    }
    $json = $obj | ConvertTo-Json
    $utf8 = New-Object System.Text.UTF8Encoding $true
    [IO.File]::WriteAllText($script:SettingsPath, $json, $utf8)
    $script:Folder = $folder.Trim()
}

function Expand-PendingRows {
    param($Value)
    $rows = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Generic.Stack[object]
    $seed = @($Value)
    for ($i = $seed.Count - 1; $i -ge 0; $i--) {
        if ($null -ne $seed[$i]) { $stack.Push($seed[$i]) }
    }
    while ($stack.Count -gt 0) {
        $item = $stack.Pop()
        if ($item -is [System.Array]) {
            for ($i = $item.Count - 1; $i -ge 0; $i--) {
                if ($null -ne $item[$i]) { $stack.Push($item[$i]) }
            }
            continue
        }
        [void]$rows.Add($item)
    }
    foreach ($row in $rows) { Write-Output $row }
}

function Format-PendingJson {
    param($Items)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($item in @(Expand-PendingRows $Items)) {
        if ($null -eq $item -or $item -is [System.Array]) { continue }
        [void]$parts.Add(($item | ConvertTo-Json -Depth 4 -Compress))
    }
    if ($parts.Count -eq 0) { return '' }
    return '[' + ($parts -join ',') + ']'
}

function Read-Pending {
    if (-not (Test-Path -LiteralPath $script:PendingPath)) { return @() }
    try {
        $raw = [IO.File]::ReadAllText($script:PendingPath)
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        return @(Expand-PendingRows ($raw | ConvertFrom-Json))
    } catch {
        return @()
    }
}

function Write-Pending {
    param($Items)
    $json = Format-PendingJson $Items
    $utf8 = New-Object System.Text.UTF8Encoding $true
    if (-not $json) {
        if (Test-Path -LiteralPath $script:PendingPath) { Remove-Item -LiteralPath $script:PendingPath -Force }
        return
    }
    [IO.File]::WriteAllText($script:PendingPath, $json, $utf8)
}

function Add-RunLog {
    param(
        [string]$Status, [string]$Reason, [string]$Source, [string]$NewPath, [string]$Kept,
        $OldBytes, $NewBytes, $OldRate, $NewRate, $Width, $Height, $Kbps
    )
    if (-not (Test-Path -LiteralPath $script:ConvertLogPath)) {
        $header = "Timestamp`tStatus`tReason`tSource`tNew`tKept`tOldGiB`tNewGiB`tOldGiBph`tNewGiBph`tWidth`tHeight`tKbps"
        Set-Content -LiteralPath $script:ConvertLogPath -Value $header -Encoding UTF8
    }
    $oldGiB = ''
    $newGiB = ''
    if ($OldBytes) { $oldGiB = '{0:0.000}' -f ($OldBytes / 1GB) }
    if ($NewBytes) { $newGiB = '{0:0.000}' -f ($NewBytes / 1GB) }
    $oldText = ''
    $newText = ''
    if ($null -ne $OldRate) { $oldText = '{0:0.000}' -f [double]$OldRate }
    if ($null -ne $NewRate) { $newText = '{0:0.000}' -f [double]$NewRate }
    $reasonText = ([string]$Reason) -replace '[\t\r\n]+', ' '
    $row = @(
        (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'),
        $Status, $reasonText, $Source, $NewPath, $Kept,
        $oldGiB, $newGiB, $oldText, $newText, $Width, $Height, $Kbps
    ) -join "`t"
    Add-Content -LiteralPath $script:ConvertLogPath -Value $row -Encoding UTF8
}

function Enable-KeepAwake {
    [VideoDehydrator.KeepAwake]::Stay()
    $script:Awake = $true
    $script:LastAwake = Get-Date
}

function Disable-KeepAwake {
    if (-not $script:Awake) { return }
    [VideoDehydrator.KeepAwake]::Allow()
    $script:Awake = $false
}

function Refresh-KeepAwake {
    if (-not $script:Awake) { return }
    if (((Get-Date) - $script:LastAwake).TotalSeconds -lt 45) { return }
    [VideoDehydrator.KeepAwake]::Stay()
    $script:LastAwake = Get-Date
}

function Get-DisplayPath {
    param([string]$Path)
    if (-not $Path) { return '' }
    $folder = [string]$script:Folder
    if (-not $folder) { return $Path }
    try {
        $root = [IO.Path]::GetFullPath($folder).TrimEnd('\')
        $full = [IO.Path]::GetFullPath($Path)
        if ($full.Length -gt $root.Length -and $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            $mark = $full[$root.Length]
            if ($mark -eq '\' -or $mark -eq '/') { return $full.Substring($root.Length).TrimStart('\', '/') }
        }
        return $full
    } catch {
        return $Path
    }
}

function Get-RowText($tag, [int]$index) {
    switch ($index) {
        0 { return (Get-DisplayPath ([string]$tag.Path)) }
        1 {
            if ($tag.Width -and $tag.Height) { return "$($tag.Width)x$($tag.Height)" }
            return ''
        }
        2 {
            if ($tag.DurationSec) { return (Format-Clock ([double]$tag.DurationSec)) }
            return ''
        }
        3 {
            if ($tag.OldBytes -and $tag.SizeBytes -and [int64]$tag.OldBytes -ne [int64]$tag.SizeBytes) {
                return ((Format-ByteSize ([int64]$tag.SizeBytes)) + ' from ' + (Format-ByteSize ([int64]$tag.OldBytes)))
            }
            if ($tag.SizeBytes) { return (Format-ByteSize ([int64]$tag.SizeBytes)) }
            return ''
        }
        4 { return (Format-Rate $tag.GiBph) }
        5 { return (Format-Rate $tag.BudgetGiBph) }
        6 {
            if ($tag.TargetKbps) { return "$($tag.TargetKbps) kbps" }
            return ''
        }
        7 {
            if ($tag.EstimateBytes) { return (Format-ByteSize ([int64]$tag.EstimateBytes)) }
            return ''
        }
        default { return [string]$tag.Status }
    }
}

function Update-ResultRow($item) {
    if ($null -eq $item) { return }
    $tag = $item.Tag
    $item.Text = Get-RowText $tag 0
    for ($i = 1; $i -le 8; $i++) { $item.SubItems[$i].Text = Get-RowText $tag $i }
    $tip = [string]$tag.Path
    if ($tag.Reason) { $tip = $tip + "`r`n" + [string]$tag.Reason }
    $item.ToolTipText = $tip
}

function Add-ResultRow($tag) {
    $item = New-Object Windows.Forms.ListViewItem (Get-RowText $tag 0)
    for ($i = 1; $i -le 8; $i++) { [void]$item.SubItems.Add((Get-RowText $tag $i)) }
    $item.Tag = $tag
    $item.Checked = ($tag.Status -eq 'Bloated' -or $tag.Status -eq 'Failed' -or $tag.Status -eq 'Ready to delete')
    [void]$script:Files.Items.Add($item)
    Update-ResultRow $item
    return $item
}

function Test-KnownNewPath {
    param([string]$Path)
    foreach ($item in @($script:Files.Items)) {
        $known = [string]$item.Tag.New
        if ($known -and [string]::Equals($known, $Path, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Add-PendingRows {
    foreach ($row in @(Read-Pending)) {
        $kept = [string]$row.kept
        $newPath = [string]$row.new
        if (-not $kept -or -not (Test-Path -LiteralPath $kept)) { continue }
        $status = 'Ready to delete'
        $reason = 'Original is in .vd-originals. Compare, then delete it when the new file looks right.'
        if ($newPath -and -not (Test-Path -LiteralPath $newPath)) {
            $status = 'New file missing'
            $reason = 'The new file is missing, so the original stays.'
        }
        $tag = @{
            Status = $status
            Path = $(if ($newPath) { $newPath } else { $kept })
            Kept = $kept
            New = $newPath
            Source = [string]$row.source
            Width = $row.width
            Height = $row.height
            DurationSec = 0
            SizeBytes = $row.newBytes
            OldBytes = $row.oldBytes
            GiBph = $null
            BudgetGiBph = $null
            TargetKbps = $row.targetKbps
            EstimateBytes = $null
            Codec = ''
            PendingId = [string]$row.id
            Reason = $reason
        }
        Add-ResultRow $tag | Out-Null
    }
}

function Clear-ScanRows {
    $keep = @()
    foreach ($item in @($script:Files.Items)) {
        if ($item.Tag.PendingId) { $keep += $item.Tag }
    }
    $script:Files.Items.Clear()
    foreach ($tag in $keep) { Add-ResultRow $tag | Out-Null }
    Update-BloatFolders
}

function Get-CheckedItems {
    param([string[]]$Statuses)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($script:Files.Items)) {
        if (-not $item.Checked) { continue }
        if ($Statuses -contains [string]$item.Tag.Status) { $list.Add($item) }
    }
    return $list
}

function Get-ScanRootPath {
    $folder = [string]$script:Folder
    if (-not $folder -and $script:FolderBox) { $folder = [string]$script:FolderBox.Text }
    if (-not $folder) { return '' }
    try { return [IO.Path]::GetFullPath($folder).TrimEnd('\') } catch { return $folder.TrimEnd('\') }
}

function Get-FullDirectory([string]$Path) {
    if (-not $Path) { return '' }
    $dir = [IO.Path]::GetDirectoryName($Path)
    if (-not $dir) { return '' }
    try { return [IO.Path]::GetFullPath($dir).TrimEnd('\') } catch { return $dir.TrimEnd('\') }
}

function Get-BloatFolderEntries {
    $root = Get-ScanRootPath
    $counts = @{}
    $total = 0
    $rootHasFile = $false
    foreach ($item in @($script:Files.Items)) {
        $status = [string]$item.Tag.Status
        if ($status -ne 'Bloated' -and $status -ne 'Failed') { continue }
        $total++
        $dir = Get-FullDirectory ([string]$item.Tag.Path)
        if (-not $dir) { continue }
        if ($root -and [string]::Equals($dir, $root, [StringComparison]::OrdinalIgnoreCase)) { $rootHasFile = $true }
        $current = $dir
        while ($current) {
            $key = $current.ToLowerInvariant()
            if (-not $counts.ContainsKey($key)) {
                $counts[$key] = [pscustomobject]@{ Path = $current; FileCount = 0 }
            }
            $rowNow = $counts[$key]
            $rowNow.FileCount = [int]$rowNow.FileCount + 1
            if ($root -and [string]::Equals($current, $root, [StringComparison]::OrdinalIgnoreCase)) { break }
            $parent = [IO.Path]::GetDirectoryName($current)
            if (-not $parent) { break }
            try { $parent = [IO.Path]::GetFullPath($parent).TrimEnd('\') } catch { $parent = $parent.TrimEnd('\') }
            if ([string]::Equals($parent, $current, [StringComparison]::OrdinalIgnoreCase)) { break }
            $current = $parent
        }
    }
    $entries = @()
    foreach ($key in @($counts.Keys)) {
        $row = $counts[$key]
        $isRoot = $root -and [string]::Equals([string]$row.Path, $root, [StringComparison]::OrdinalIgnoreCase)
        if ($isRoot -and -not $rootHasFile -and [int]$row.FileCount -eq $total -and $counts.Count -gt 1) { continue }
        $label = [string]$row.Path
        if ($root -and $label.Length -gt $root.Length -and $label.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            $mark = $label[$root.Length]
            if ($mark -eq '\' -or $mark -eq '/') { $label = $label.Substring($root.Length).TrimStart('\', '/') }
        }
        elseif ($isRoot -or -not $root) {
            $leaf = [IO.Path]::GetFileName($label)
            if ($leaf) { $label = $leaf }
        }
        $word = if ([int]$row.FileCount -eq 1) { 'file' } else { 'files' }
        $entries += [pscustomobject]@{
            Path  = [string]$row.Path
            Count = [int]$row.FileCount
            Label = ($label + '  (' + $row.FileCount + ' ' + $word + ')')
        }
    }
    return @($entries | Sort-Object Label)
}

function Update-BloatFolders {
    if (-not $script:FolderPick) { return }
    $keep = ''
    if ($script:BloatFolderPaths -and $script:FolderPick.SelectedIndex -ge 0 -and $script:FolderPick.SelectedIndex -lt $script:BloatFolderPaths.Count) {
        $keep = [string]$script:BloatFolderPaths[$script:FolderPick.SelectedIndex]
    }
    $entries = @(Get-BloatFolderEntries)
    $script:FolderPick.BeginUpdate()
    $script:FolderPick.Items.Clear()
    $paths = New-Object System.Collections.Generic.List[string]
    $match = -1
    $index = 0
    foreach ($entry in $entries) {
        if (-not $entry -or -not $entry.Path) { continue }
        [void]$script:FolderPick.Items.Add([string]$entry.Label)
        if ($keep -and [string]::Equals($keep, [string]$entry.Path, [StringComparison]::OrdinalIgnoreCase)) { $match = $index }
        [void]$paths.Add([string]$entry.Path)
        $index++
    }
    $script:BloatFolderPaths = $paths
    if ($match -ge 0) { $script:FolderPick.SelectedIndex = $match }
    elseif ($script:FolderPick.Items.Count -gt 0) { $script:FolderPick.SelectedIndex = 0 }
    $script:FolderPick.EndUpdate()
    Update-Buttons
}

function Set-AllChecks([bool]$Checked) {
    if ($script:Work -ne 'idle') { return }
    $script:BulkCheck = $true
    try {
        $script:Files.BeginUpdate()
        foreach ($item in @($script:Files.Items)) { $item.Checked = $Checked }
    }
    finally {
        $script:Files.EndUpdate()
        $script:BulkCheck = $false
    }
    Update-Buttons
}

function Select-FilesInFolder([string]$Folder) {
    if ($script:Work -ne 'idle') { return }
    if (-not $Folder) { return }
    $folderFull = $Folder.TrimEnd('\')
    try { $folderFull = [IO.Path]::GetFullPath($Folder).TrimEnd('\') } catch {}
    $prefix = $folderFull + '\'
    $checked = 0
    $script:BulkCheck = $true
    try {
        $script:Files.BeginUpdate()
        foreach ($item in @($script:Files.Items)) {
            $status = [string]$item.Tag.Status
            $inside = $false
            if ($status -eq 'Bloated' -or $status -eq 'Failed') {
                $dir = Get-FullDirectory ([string]$item.Tag.Path)
                if ($dir -and ([string]::Equals($dir, $folderFull, [StringComparison]::OrdinalIgnoreCase) -or $dir.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))) {
                    $inside = $true
                }
            }
            $item.Checked = $inside
            if ($inside) { $checked++ }
        }
    }
    finally {
        $script:Files.EndUpdate()
        $script:BulkCheck = $false
    }
    Update-Buttons
    $shown = $folderFull
    $root = Get-ScanRootPath
    if ($root -and $shown.Length -gt $root.Length -and $shown.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        $mark = $shown[$root.Length]
        if ($mark -eq '\' -or $mark -eq '/') { $shown = $shown.Substring($root.Length).TrimStart('\', '/') }
    }
    $word = if ($checked -eq 1) { 'file' } else { 'files' }
    Write-Activity "Checked $checked $word in $shown." 'text'
}

function Select-ChosenFolder {
    if (-not $script:FolderPick -or $script:FolderPick.SelectedIndex -lt 0) { return }
    if (-not $script:BloatFolderPaths) { return }
    if ($script:FolderPick.SelectedIndex -ge $script:BloatFolderPaths.Count) { return }
    Select-FilesInFolder ([string]$script:BloatFolderPaths[$script:FolderPick.SelectedIndex])
}

function Select-FolderOfSelectedFile {
    if ($script:Files.SelectedItems.Count -ne 1) { return }
    $dir = Get-FullDirectory ([string]$script:Files.SelectedItems[0].Tag.Path)
    if (-not $dir) { return }
    if ($script:BloatFolderPaths -and $script:FolderPick) {
        for ($i = 0; $i -lt $script:BloatFolderPaths.Count; $i++) {
            if ([string]::Equals([string]$script:BloatFolderPaths[$i], $dir, [StringComparison]::OrdinalIgnoreCase)) {
                $script:FolderPick.SelectedIndex = $i
                break
            }
        }
    }
    Select-FilesInFolder $dir
}

function Update-Buttons {
    $busy = ($script:Work -ne 'idle')
    $folderOk = $false
    if ($script:FolderBox -and -not [string]::IsNullOrWhiteSpace($script:FolderBox.Text)) { $folderOk = $true }
    $convertible = @(Get-CheckedItems @('Bloated', 'Failed'))
    $deletable = @(Get-CheckedItems @('Ready to delete'))
    $compareOk = $false
    if ($script:Files -and $script:Files.SelectedItems.Count -eq 1) {
        $selected = $script:Files.SelectedItems[0].Tag
        if ([string]$selected.Status -eq 'Ready to delete' -and $selected.Kept -and $selected.New) { $compareOk = $true }
    }
    if ($script:ScanButton) { $script:ScanButton.Enabled = ((-not $busy) -and $script:ToolsOk -and $folderOk) }
    if ($script:ConvertButton) { $script:ConvertButton.Enabled = ((-not $busy) -and $script:ToolsOk -and $convertible.Count -gt 0) }
    if ($script:CancelButton) { $script:CancelButton.Enabled = $busy }
    if ($script:CompareButton) { $script:CompareButton.Enabled = ((-not $busy) -and $compareOk) }
    if ($script:DeleteButton) { $script:DeleteButton.Enabled = ((-not $busy) -and $deletable.Count -gt 0) }
    $undoReady = (-not $busy) -and (@(Get-UndoBatch).Count -gt 0)
    if ($script:UndoButton) { $script:UndoButton.Enabled = $undoReady }
    if ($script:BrowseButton) { $script:BrowseButton.Enabled = -not $busy }
    if ($script:SelectAllButton) { $script:SelectAllButton.Enabled = -not $busy }
    if ($script:SelectNoneButton) { $script:SelectNoneButton.Enabled = -not $busy }
    $pickReady = (-not $busy) -and $script:FolderPick -and $script:FolderPick.Items.Count -gt 0
    if ($script:FolderPick) { $script:FolderPick.Enabled = [bool]$pickReady }
    if ($script:SelectFolderButton) {
        $script:SelectFolderButton.Enabled = [bool]($pickReady -and $script:FolderPick.SelectedIndex -ge 0)
    }
    foreach ($chk in @($script:SubfoldersCheck, $script:AutoCheck, $script:DetailedCheck, $script:ShutdownCheck)) {
        if ($chk) { $chk.Enabled = -not $busy }
    }
    foreach ($box in @($script:BudgetBoxes)) {
        if ($box) { $box.Enabled = -not $busy }
    }
    Update-Savings
}

function Update-Savings {
    if (-not $script:SavingsLabel) { return }
    $saved = [int64]0
    $missing = 0
    $files = 0
    foreach ($item in @($script:Files.Items)) {
        if (-not $item.Checked) { continue }
        $status = [string]$item.Tag.Status
        if ($status -ne 'Bloated' -and $status -ne 'Failed') { continue }
        $files++
        $size = [int64]0
        if ($item.Tag.SizeBytes) { $size = [int64]$item.Tag.SizeBytes }
        $estimate = [int64]0
        $hasEstimate = $false
        if ($null -ne $item.Tag.EstimateBytes -and [string]$item.Tag.EstimateBytes -ne '') {
            $estimate = [int64]$item.Tag.EstimateBytes
            if ($estimate -gt 0) { $hasEstimate = $true }
        }
        if (-not $hasEstimate -or $size -le 0) {
            $missing++
            continue
        }
        $delta = $size - $estimate
        if ($delta -gt 0) { $saved += $delta }
    }
    if ($files -eq 0) {
        $script:SavingsLabel.Text = 'Estimated savings: 0 B'
    }
    else {
        $text = 'Estimated savings: ' + (Format-ByteSize $saved)
        if ($missing -eq 1) { $text += ', 1 file not included' }
        elseif ($missing -gt 1) { $text += ", $missing files not included" }
        $script:SavingsLabel.Text = $text
    }
    Layout-Hint
}

function Set-FolderText {
    param([string]$Path)
    $script:Folder = $Path.Trim()
    if ($script:FolderBox) { $script:FolderBox.Text = $script:Folder }
    if (-not $script:Loading) { Save-Settings }
    Update-Buttons
}

function Choose-Folder {
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose the folder to scan'
    $dlg.ShowNewFolderButton = $false
    if ($script:Folder -and (Test-Path -LiteralPath $script:Folder -PathType Container)) {
        $dlg.SelectedPath = $script:Folder
    }
    if ($dlg.ShowDialog($script:Form) -ne [Windows.Forms.DialogResult]::OK) { return }
    Set-FolderText $dlg.SelectedPath
}

function Add-DroppedFolder($data) {
    if ($script:Work -ne 'idle') { return }
    if (-not $data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { return }
    $paths = @($data.GetData([Windows.Forms.DataFormats]::FileDrop))
    if ($paths.Count -eq 0) { return }
    $first = [string]$paths[0]
    if (Test-Path -LiteralPath $first -PathType Container) {
        Set-FolderText $first
        return
    }
    if (Test-Path -LiteralPath $first -PathType Leaf) {
        Set-FolderText (Split-Path -Parent $first)
    }
}

function Stop-ChildTools {
    foreach ($name in @('ffprobe.exe', 'ffmpeg.exe', 'ffplay.exe', 'HandBrakeCLI.exe')) {
        try {
            $procs = @(Get-CimInstance Win32_Process -Filter "Name = '$name'" -ErrorAction SilentlyContinue)
            foreach ($proc in $procs) {
                if ([int]$proc.ParentProcessId -eq $PID) {
                    Stop-Process -Id ([int]$proc.ProcessId) -Force -ErrorAction SilentlyContinue
                }
            }
        } catch {
        }
    }
}

function Stop-Playback {
    $script:Playing = $false
    if ($script:PlayTimer) { $script:PlayTimer.Stop() }
    if ($script:Player) { $script:Player.Stop() }
    if ($script:AudioProc) {
        try {
            if (-not $script:AudioProc.HasExited) { $script:AudioProc.Kill() }
        } catch {
        }
        try { $script:AudioProc.Dispose() } catch {}
        $script:AudioProc = $null
    }
    if ($script:PlayClock) { $script:PlayClock.Stop() }
    $script:PlayClock = $null
    if ($script:PlayButton) { $script:PlayButton.Text = 'Play' }
}

function Start-CompareAudio {
    if (-not $script:Playing -or $script:PlayClock) { return }
    if (-not $script:Player -or $script:Player.FrameIndex -lt 1) { return }
    $start = '{0:0.###}' -f $script:PlayOrigin
    if ($script:PlayOrigin -le 0) { $start = '0' }
    $audioArgs = ConvertTo-ArgumentLine @(
        '-hide_banner', '-loglevel', 'error', '-nodisp', '-vn', '-autoexit',
        '-ss', $start, '-i', $script:PlayRight
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:Ffplay
    $psi.Arguments = $audioArgs
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $audio = New-Object System.Diagnostics.Process
    $audio.StartInfo = $psi
    $script:PlayClock = [Diagnostics.Stopwatch]::StartNew()
    try { [void]$audio.Start() } catch { $audio = $null }
    $script:AudioProc = $audio
}

function Update-PlayFrame {
    if (-not $script:Player -or -not $script:PlayPicture) { return }
    $info = Get-CompareFrameInfo
    $copied = $false
    [Threading.Monitor]::Enter($script:Player.Gate)
    try {
        if ($script:Player.FrameIndex -le 0 -or $null -eq $script:Player.Latest) { return }
        if ($script:Player.FrameIndex -eq $script:LastFrame) { return }
        if (-not $script:PlayBitmap -or $script:PlayBitmap.Width -ne $info.Width -or $script:PlayBitmap.Height -ne $info.Height) {
            if ($script:PlayBitmap) { $script:PlayBitmap.Dispose() }
            $script:PlayBitmap = New-Object Drawing.Bitmap $info.Width, $info.Height, ([Drawing.Imaging.PixelFormat]::Format24bppRgb)
            $script:PlayPicture.Image = $script:PlayBitmap
        }
        $rect = New-Object Drawing.Rectangle 0, 0, $info.Width, $info.Height
        $data = $script:PlayBitmap.LockBits($rect, [Drawing.Imaging.ImageLockMode]::WriteOnly, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
        try {
            $row = $info.Width * 3
            if ($data.Stride -eq $row) {
                [Runtime.InteropServices.Marshal]::Copy($script:Player.Latest, 0, $data.Scan0, $script:Player.Latest.Length)
            } else {
                for ($y = 0; $y -lt $info.Height; $y++) {
                    $dest = [IntPtr]($data.Scan0.ToInt64() + ($y * $data.Stride))
                    [Runtime.InteropServices.Marshal]::Copy($script:Player.Latest, ($y * $row), $dest, $row)
                }
            }
        }
        finally {
            $script:PlayBitmap.UnlockBits($data)
        }
        $script:LastFrame = $script:Player.FrameIndex
        $copied = $true
    }
    finally {
        [Threading.Monitor]::Exit($script:Player.Gate)
    }
    if ($copied) { $script:PlayPicture.Invalidate() }
}

function Get-PlayPosition {
    $pos = $script:PlaySeconds
    if ($script:Playing -and $script:PlayClock) {
        $pos = $script:PlayOrigin + $script:PlayClock.Elapsed.TotalSeconds
    }
    if ($pos -lt 0) { $pos = 0 }
    if ($script:PlayDuration -gt 0 -and $pos -gt $script:PlayDuration) { $pos = $script:PlayDuration }
    return $pos
}

function Update-PlayChrome {
    $pos = Get-PlayPosition
    if ($script:PlayTime) {
        $total = Format-Clock $script:PlayDuration
        if ($script:PlayDuration -le 0) { $total = '' }
        $script:PlayTime.Text = ((Format-Clock $pos) + ' / ' + $total).Trim()
    }
    if ($script:PlaySlider -and -not $script:Seeking -and $script:PlayDuration -gt 0) {
        $value = [int][math]::Round($pos * 10)
        if ($value -lt $script:PlaySlider.Minimum) { $value = $script:PlaySlider.Minimum }
        if ($value -gt $script:PlaySlider.Maximum) { $value = $script:PlaySlider.Maximum }
        $script:PlaySlider.Value = $value
    }
    if ($script:Playing -and $script:PlayDuration -gt 0 -and $pos -ge ($script:PlayDuration - 0.15)) {
        $script:PlaySeconds = $script:PlayDuration
        Stop-Playback
    }
}

function Start-Playback {
    param([double]$Seconds)
    Stop-Playback
    if (-not $script:PlayLeft -or -not $script:PlayRight) { return }
    if ($Seconds -lt 0) { $Seconds = 0 }
    if ($script:PlayDuration -gt 1 -and $Seconds -gt ($script:PlayDuration - 0.25)) { $Seconds = 0 }
    $script:PlayOrigin = $Seconds
    $script:PlaySeconds = $Seconds
    $script:LastFrame = [int64]-1
    $info = Get-CompareFrameInfo
    $arguments = Get-CompareArguments -Left $script:PlayLeft -Right $script:PlayRight -StartSec $Seconds
    $script:Player.Start($script:Ffmpeg, (ConvertTo-ArgumentLine $arguments), $info.Width, $info.Height, $info.Fps)
    $script:Playing = $true
    if ($script:PlayButton) { $script:PlayButton.Text = 'Pause' }
    if ($script:PlayTimer) { $script:PlayTimer.Start() }
}

function Show-Compare {
    if ($script:Files.SelectedItems.Count -ne 1) { return }
    $tag = $script:Files.SelectedItems[0].Tag
    if ([string]$tag.Status -ne 'Ready to delete') { return }
    if (-not (Test-Path -LiteralPath ([string]$tag.Kept)) -or -not (Test-Path -LiteralPath ([string]$tag.New))) {
        [Windows.Forms.MessageBox]::Show($script:Form, 'The original and the new file both need to be on disk to compare them.', 'Video Dehydrator', 'OK', 'Information') | Out-Null
        return
    }
    if ($tag.DurationSec -le 0) {
        try {
            $probe = Get-MediaProbe -Ffprobe $script:Ffprobe -File ([string]$tag.New)
            $tag.DurationSec = $probe.DurationSec
            Update-ResultRow $script:Files.SelectedItems[0]
        } catch {
            $tag.DurationSec = 0
        }
    }
    $script:PlayLeft = [string]$tag.Kept
    $script:PlayRight = [string]$tag.New
    $script:PlayDuration = [double]$tag.DurationSec
    $script:PlaySeconds = 0
    Ensure-CompareForm
    $script:CompareTitle.Text = [IO.Path]::GetFileName([string]$tag.New)
    $max = 1
    if ($script:PlayDuration -gt 0) { $max = [int][math]::Max(1, [math]::Ceiling($script:PlayDuration * 10)) }
    $script:PlaySlider.Maximum = $max
    $script:PlaySlider.Value = 0
    $script:PlaySlider.Enabled = ($script:PlayDuration -gt 0)
    if (-not $script:CompareForm.Visible) { $script:CompareForm.Show($script:Form) }
    else { $script:CompareForm.Activate() }
    Start-Playback 0
}

function Ensure-CompareForm {
    if ($script:CompareForm -and -not $script:CompareForm.IsDisposed) { return }
    $form = New-Object Windows.Forms.Form
    $form.Text = 'Compare'
    $form.StartPosition = 'CenterParent'
    $form.Font = $script:FontUi
    $form.BackColor = [Drawing.Color]::Black
    $form.ClientSize = New-Object Drawing.Size(1100, 680)
    $form.MinimumSize = New-Object Drawing.Size(760, 480)
    $icon = Get-AppIcon
    if ($icon) { $form.Icon = $icon }
    Enable-DoubleBuffer $form

    $top = New-Object Windows.Forms.Panel
    $top.Dock = 'Top'
    $top.Height = 64
    $top.BackColor = $script:ColorHeader
    $script:CompareTitle = New-Object Windows.Forms.Label
    $script:CompareTitle.ForeColor = [Drawing.Color]::White
    $script:CompareTitle.BackColor = $script:ColorHeader
    $script:CompareTitle.Font = $script:FontSection
    $script:CompareTitle.AutoEllipsis = $true
    $sides = New-Object Windows.Forms.Label
    $sides.Text = 'Original on the left. New file on the right. Sound is the new file.'
    $sides.ForeColor = $script:ColorHeaderMuted
    $sides.BackColor = $script:ColorHeader
    $sides.Font = $script:FontHint
    $top.Controls.Add($script:CompareTitle)
    $top.Controls.Add($sides)
    $top.Add_Resize({
        $script:CompareTitle.SetBounds(20, 8, ($this.ClientSize.Width - 40), 26)
        $this.Controls[1].SetBounds(20, 34, ($this.ClientSize.Width - 40), 22)
    })

    $bottom = New-Object Windows.Forms.Panel
    $bottom.Dock = 'Bottom'
    $bottom.Height = 64
    $bottom.BackColor = $script:ColorPage
    $script:PlayButton = New-Button 'Pause' 'primary' 96 34
    $script:PlaySlider = New-Object Windows.Forms.TrackBar
    $script:PlaySlider.Minimum = 0
    $script:PlaySlider.Maximum = 1
    $script:PlaySlider.TickStyle = 'None'
    $script:PlaySlider.AutoSize = $false
    $script:PlaySlider.Height = 32
    $script:PlaySlider.BackColor = $script:ColorPage
    $script:PlayTime = New-Object Windows.Forms.Label
    $script:PlayTime.ForeColor = $script:ColorInk
    $script:PlayTime.BackColor = $script:ColorPage
    $script:PlayTime.Font = $script:FontUi
    $script:PlayTime.TextAlign = 'MiddleRight'
    $bottom.Controls.Add($script:PlayButton)
    $bottom.Controls.Add($script:PlaySlider)
    $bottom.Controls.Add($script:PlayTime)
    $bottom.Add_Resize({
        $script:PlayButton.Location = New-Object Drawing.Point(16, 14)
        $script:PlayTime.SetBounds(($this.ClientSize.Width - 140), 16, 120, 28)
        $left = $script:PlayButton.Right + 12
        $width = $script:PlayTime.Left - 12 - $left
        if ($width -lt 40) { $width = 40 }
        $script:PlaySlider.SetBounds($left, 12, $width, 36)
    })
    $script:PlayButton.Add_Click({
        if ($script:Playing) {
            $script:PlaySeconds = Get-PlayPosition
            Stop-Playback
        } else {
            Start-Playback $script:PlaySeconds
        }
    })
    $script:PlaySlider.Add_MouseDown({ $script:Seeking = $true })
    $script:PlaySlider.Add_MouseUp({
        $script:Seeking = $false
        $seconds = $script:PlaySlider.Value / 10.0
        $was = $script:Playing
        $script:PlaySeconds = $seconds
        if ($was) { Start-Playback $seconds }
        else { Update-PlayChrome }
    })

    $script:PlayPicture = New-Object Windows.Forms.PictureBox
    $script:PlayPicture.Dock = 'Fill'
    $script:PlayPicture.BackColor = [Drawing.Color]::Black
    $script:PlayPicture.SizeMode = 'Zoom'

    $form.Controls.Add($script:PlayPicture)
    $form.Controls.Add($bottom)
    $form.Controls.Add($top)
    $form.Add_FormClosing({
        Stop-Playback
        if ($script:PlayBitmap) {
            $script:PlayPicture.Image = $null
            $script:PlayBitmap.Dispose()
            $script:PlayBitmap = $null
        }
    })
    $form.Add_KeyDown({
        if ($_.KeyCode -eq [Windows.Forms.Keys]::Escape) {
            $form.Close()
            $_.SuppressKeyPress = $true
        } elseif ($_.KeyCode -eq [Windows.Forms.Keys]::Space) {
            $script:PlayButton.PerformClick()
            $_.SuppressKeyPress = $true
        }
    })
    $form.KeyPreview = $true
    $script:CompareForm = $form
    Set-Tip $script:PlayButton 'Play or pause the side by side preview. Space does this too.'
    Set-Tip $script:PlaySlider 'Move through both copies together.'
}

function Remove-TempQuiet {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
    if ($Path) { Remove-EmptyDirectory (Split-Path -Parent $Path) }
}

function Complete-ScanRuntime {
    if ($script:ScanPower) {
        try { $script:ScanPower.EndInvoke($script:ScanHandle) | Out-Null } catch {
            Write-Activity ("Scan stopped early. " + $_.Exception.Message) 'warn'
        }
        try { $script:ScanPower.Dispose() } catch {}
        $script:ScanPower = $null
    }
    if ($script:ScanRunspace) {
        try { $script:ScanRunspace.Close(); $script:ScanRunspace.Dispose() } catch {}
        $script:ScanRunspace = $null
    }
    $script:Work = 'idle'
    $script:Cancel = $false
    Disable-KeepAwake
    Set-Progress 0
    Update-Buttons
}

function Start-Scan {
    if ($script:Work -ne 'idle') { return }
    $folder = [string]$script:FolderBox.Text
    $folder = $folder.Trim()
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        [Windows.Forms.MessageBox]::Show($script:Form, 'Choose a folder that is on this computer.', 'Video Dehydrator', 'OK', 'Information') | Out-Null
        return
    }
    Save-Settings
    $script:Cancel = $false
    $script:ScanCancel = @{ Stop = $false }
    $script:ScanQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    Clear-ScanRows
    $script:Work = 'scan'
    Update-Buttons
    Enable-KeepAwake
    Set-Status 'Listing videos...' 'busy'
    Set-Progress 0
    Write-Activity ("Scanning " + $folder) 'text'
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $script:ScanRunspace = $rs
    $script:ScanPower = $ps
    $null = $ps.AddScript({
        param($EnginePath, $Root, $Recurse, $Ffprobe, $Queue, $Cancel, $Budgets)
        . $EnginePath
        Set-BudgetPicks $Budgets
        Invoke-ScanFolder -Root $Root -Recurse $Recurse -Ffprobe $Ffprobe -Queue $Queue -Cancel $Cancel
    }).AddArgument($script:EnginePath).AddArgument($folder).AddArgument([bool]$script:SubfoldersCheck.Checked).AddArgument($script:Ffprobe).AddArgument($script:ScanQueue).AddArgument($script:ScanCancel).AddArgument((Get-SelectedBudgetPack))
    $script:ScanHandle = $ps.BeginInvoke()
}

function Read-ScanQueue {
    if (-not $script:ScanQueue) { return }
    $line = $null
    while ($script:ScanQueue.TryDequeue([ref]$line)) {
        if (-not $line) { continue }
        $msg = $null
        try { $msg = $line | ConvertFrom-Json } catch { continue }
        if ($msg.Kind -eq 'progress') {
            Set-Status ("Scanned $($msg.Seen), $($msg.Hits) bloated - $($msg.Name)") 'busy'
        }
        elseif ($msg.Kind -eq 'hit') {
            if (Test-KnownNewPath ([string]$msg.Path)) { continue }
            $estimate = $null
            if ($null -ne $msg.EstimateBytes -and [string]$msg.EstimateBytes -ne '') { $estimate = [int64]$msg.EstimateBytes }
            $videoBits = [int64]0
            if ($null -ne $msg.VideoBitrate -and [string]$msg.VideoBitrate -ne '') {
                [void][int64]::TryParse([string]$msg.VideoBitrate, [ref]$videoBits)
            }
            $tag = @{
                Status = 'Bloated'
                Path = [string]$msg.Path
                Kept = ''
                New = ''
                Source = [string]$msg.Path
                Width = [int]$msg.Width
                Height = [int]$msg.Height
                DurationSec = [double]$msg.DurationSec
                SizeBytes = [int64]$msg.SizeBytes
                OldBytes = $null
                GiBph = [double]$msg.GiBph
                BudgetGiBph = [double]$msg.BudgetGiBph
                TargetKbps = [int]$msg.TargetKbps
                EstimateBytes = $estimate
                VideoBitrate = $videoBits
                Codec = [string]$msg.Codec
                PendingId = ''
                Reason = [string]$msg.Reason
            }
            Add-ResultRow $tag | Out-Null
        }
        elseif ($msg.Kind -eq 'done') {
            $script:ScanSummary = $msg
        }
    }
}

function Finish-Scan {
    $summary = $script:ScanSummary
    Complete-ScanRuntime
    Update-BloatFolders
    if ($summary -and [bool]$summary.Cancelled) {
        Set-Status 'Scan stopped' 'idle'
        Write-Activity 'Scan stopped. Files already listed stay in the box.' 'warn'
        return
    }
    $hits = 0
    $seen = 0
    $lean = 0
    $within = 0
    $dv = 0
    $nodur = 0
    $errors = 0
    if ($summary) {
        $hits = [int]$summary.Hits
        $seen = [int]$summary.Seen
        $lean = [int]$summary.Lean
        $within = [int]$summary.Within
        $dv = [int]$summary.Dv
        $nodur = [int]$summary.NoDur
        $errors = [int]$summary.Errors
    }
    $bytes = [int64]0
    foreach ($item in @($script:Files.Items)) {
        if ([string]$item.Tag.Status -eq 'Bloated' -and $item.Tag.SizeBytes) { $bytes += [int64]$item.Tag.SizeBytes }
    }
    $line = "Scanned $seen videos. $hits bloated"
    if ($bytes -gt 0) { $line += " (" + (Format-ByteSize $bytes) + ")" }
    $line += "."
    Set-Status $line 'ok'
    Write-Activity $line 'ok'
    $extra = @()
    if ($lean -gt 0) { $extra += "$lean already under the budget" }
    if ($within -gt 0) { $extra += "$within already at the picture rate" }
    if ($dv -gt 0) { $extra += "$dv Dolby Vision left alone" }
    if ($nodur -gt 0) { $extra += "$nodur could not be measured" }
    if ($errors -gt 0) { $extra += "$errors could not be read" }
    if ($extra.Count -gt 0) { Write-Activity ($extra -join '. ') 'dim' }
    if ($summary -and $summary.Samples) { Write-Activity ([string]$summary.Samples) 'warn' }
    if ($hits -eq 0 -and $seen -gt 0) { Write-Activity 'Nothing in this folder is over the budget for its picture size.' 'text' }
    Update-Buttons
}

function Start-EncodeProcess {
    param($Item, $Plan, $Probe, $Decision)
    $tag = $Item.Tag
    $tag.Status = 'Converting'
    $tag.Reason = ''
    Update-ResultRow $Item
    $encoder = Get-EncoderName -Probe $Probe
    $arguments = Get-HandBrakeArguments -Source $Plan.Source -Temp $Plan.Temp -Probe $Probe -VideoKbps $Decision.TargetKbps -Encoder $encoder
    $script:HbLines = New-Object System.Collections.Generic.List[string]
    $script:ActiveItem = $Item
    $script:ActivePlan = $Plan
    $script:ActiveProbe = $Probe
    $script:ActiveDecision = $Decision
    $script:ActiveEncoder = $encoder
    if ($script:DetailedCheck.Checked) {
        Write-Activity (ConvertTo-ArgumentLine (@($script:HandBrake) + $arguments)) 'dim'
    }
    [VideoDehydrator.LinePump]::Start($script:HandBrake, (ConvertTo-ArgumentLine $arguments))
}

function Start-NextEncode {
    while ($script:EncodeIndex -lt $script:EncodeItems.Count) {
        if ($script:Cancel) { Finish-Batch 'stopped'; return }
        $item = $script:EncodeItems[$script:EncodeIndex]
        $script:EncodeIndex++
        $number = $script:EncodeIndex
        $total = $script:EncodeItems.Count
        $source = [string]$item.Tag.Source
        if (-not $source) { $source = [string]$item.Tag.Path }
        Set-Status ("File $number of $total - " + [IO.Path]::GetFileName($source)) 'busy'
        Set-Progress 0
        if (-not (Test-Path -LiteralPath $source)) {
            $item.Tag.Status = 'Failed'
            $item.Tag.Reason = 'The file is no longer there.'
            Update-ResultRow $item
            Write-Activity ("Missing  " + $source) 'err'
            continue
        }
        $plan = $null
        $probe = $null
        try {
            $plan = Get-ReplacePlan -Source $source
            if ($plan.Blocked) { throw "A file already has the new name: $($plan.Final)" }
            $probe = Get-MediaProbe -Ffprobe $script:Ffprobe -File $source
            $decision = Get-BloatDecision -Probe $probe
        }
        catch {
            $item.Tag.Status = 'Failed'
            $item.Tag.Reason = $_.Exception.Message
            Update-ResultRow $item
            Write-Activity ("Could not read  " + [IO.Path]::GetFileName($source) + "  " + $_.Exception.Message) 'err'
            continue
        }
        if ($decision.Decision -ne 'bloated') {
            $item.Tag.Status = 'Already small enough'
            $item.Tag.Reason = $decision.Reason
            $item.Checked = $false
            Update-ResultRow $item
            Write-Activity ("Left alone  " + [IO.Path]::GetFileName($source) + "  " + $decision.Reason) 'dim'
            continue
        }
        try {
            New-Item -ItemType Directory -Force -Path $plan.HoldDir | Out-Null
            Add-PlexIgnore -Directory (Split-Path -Parent $source)
            if (Test-Path -LiteralPath $plan.Temp) { Remove-Item -LiteralPath $plan.Temp -Force }
        }
        catch {
            $item.Tag.Status = 'Failed'
            $item.Tag.Reason = $_.Exception.Message
            Update-ResultRow $item
            Write-Activity ("Could not prepare  " + [IO.Path]::GetFileName($source) + "  " + $_.Exception.Message) 'err'
            continue
        }
        $item.Tag.TargetKbps = $decision.TargetKbps
        $item.Tag.Width = $probe.Width
        $item.Tag.Height = $probe.Height
        Write-Activity ("Converting  " + [IO.Path]::GetFileName($source) + "  at $($decision.TargetKbps) kbps") 'text'
        Start-EncodeProcess -Item $item -Plan $plan -Probe $probe -Decision $decision
        return
    }
    Finish-Batch 'done'
}

function Fail-Active {
    param([string]$Reason)
    $item = $script:ActiveItem
    $plan = $script:ActivePlan
    if ($plan) { Remove-TempQuiet $plan.Temp }
    if ($item) {
        $item.Tag.Status = 'Failed'
        $item.Tag.Reason = $Reason
        $item.Checked = $true
        Update-ResultRow $item
    }
    $name = ''
    if ($plan) { $name = [IO.Path]::GetFileName($plan.Source) }
    Write-Activity ("Failed  $name  $Reason") 'err'
    Add-RunLog -Status 'FAIL' -Reason $Reason -Source $(if ($plan) { $plan.Source } else { '' }) -NewPath '' -Kept '' -Width $(if ($script:ActiveProbe) { $script:ActiveProbe.Width } else { '' }) -Height $(if ($script:ActiveProbe) { $script:ActiveProbe.Height } else { '' }) -Kbps $(if ($script:ActiveDecision) { $script:ActiveDecision.TargetKbps } else { '' })
    $script:ActiveItem = $null
}

function Complete-ActiveEncode {
    Read-EncodeLines
    $exitCode = [int][VideoDehydrator.LinePump]::ExitCode
    $plan = $script:ActivePlan
    $item = $script:ActiveItem
    if ($script:Cancel) {
        if ($plan) { Remove-TempQuiet $plan.Temp }
        if ($item -and [string]$item.Tag.Status -eq 'Converting') {
            $item.Tag.Status = 'Stopped'
            $item.Tag.Reason = 'Cancelled before the new file was checked.'
            Update-ResultRow $item
        }
        Finish-Batch 'stopped'
        return
    }
    $log = ($script:HbLines -join "`n")
    if ($exitCode -ne 0 -or -not $plan -or -not (Test-Path -LiteralPath $plan.Temp)) {
        $tail = @($script:HbLines | Select-Object -Last 6) -join ' | '
        Fail-Active "HandBrake stopped ($exitCode). $tail"
        Start-NextEncode
        return
    }
    if ($item) {
        $item.Tag.Status = 'Checking'
        Update-ResultRow $item
    }
    Set-Status 'Checking the new file' 'busy'
    $script:Form.Refresh()
    $verify = Test-EncodedFile -Ffmpeg $script:Ffmpeg -Ffprobe $script:Ffprobe -Temp $plan.Temp -SourceProbe $script:ActiveProbe -HandBrakeLog $log
    if (-not $verify.Ok) {
        Fail-Active $verify.Reason
        Start-NextEncode
        return
    }
    try {
        $swap = Invoke-ReplaceWithEncode -Source $plan.Source -TempFile $plan.Temp -DeleteOriginal:([bool]$script:AutoCheck.Checked)
    }
    catch {
        Fail-Active $_.Exception.Message
        Start-NextEncode
        return
    }
    $saved = [int64]$swap.OldBytes - [int64]$swap.NewBytes
    if ($saved -gt 0) { $script:SavedBytes += $saved }
    $item.Tag.SizeBytes = $swap.NewBytes
    $item.Tag.OldBytes = $swap.OldBytes
    $item.Tag.GiBph = $verify.NewGiBph
    $item.Tag.New = $swap.NewPath
    $item.Tag.Path = $swap.NewPath
    $item.Tag.Kept = $swap.KeptPath
    $name = [IO.Path]::GetFileName($swap.NewPath)
    if ($swap.Deleted) {
        $item.Tag.Status = 'Replaced'
        $item.Tag.Reason = 'Original deleted after the check.'
        $item.Checked = $false
        Write-Activity ("Replaced  $name  saved " + (Format-ByteSize $saved)) 'ok'
    }
    else {
        $item.Tag.Status = 'Ready to delete'
        $item.Tag.Reason = 'Original is in .vd-originals. Compare, then delete it when the new file looks right.'
        $item.Checked = $true
        $pending = Read-Pending
        $entry = [pscustomobject]@{
            id = [guid]::NewGuid().ToString('n')
            source = $plan.Source
            kept = $swap.KeptPath
            new = $swap.NewPath
            when = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
            oldBytes = $swap.OldBytes
            newBytes = $swap.NewBytes
            width = $script:ActiveProbe.Width
            height = $script:ActiveProbe.Height
            targetKbps = $script:ActiveDecision.TargetKbps
            batch = [string]$script:ConvertBatchId
        }
        $item.Tag.PendingId = $entry.id
        Write-Pending (@($pending) + @($entry))
        Write-Activity ("Ready  $name  saved " + (Format-ByteSize $saved) + ". Original kept for review.") 'ok'
    }
    Update-ResultRow $item
    Add-RunLog -Status $(if ($swap.Deleted) { 'REPLACED' } else { 'KEPT' }) -Reason 'ok' -Source $plan.Source -NewPath $swap.NewPath -Kept $swap.KeptPath -OldBytes $swap.OldBytes -NewBytes $swap.NewBytes -OldRate $verify.OldGiBph -NewRate $verify.NewGiBph -Width $script:ActiveProbe.Width -Height $script:ActiveProbe.Height -Kbps $script:ActiveDecision.TargetKbps
    $script:ActiveItem = $null
    Start-NextEncode
}

function Read-EncodeLines {
    $batch = @([VideoDehydrator.LinePump]::Drain())
    foreach ($line in $batch) {
        if (-not $line) { continue }
        $script:HbLines.Add($line)
        if ($script:HbLines.Count -gt 500) { $script:HbLines.RemoveAt(0) }
        $fraction = Get-HandBrakeFraction $line
        if ($null -ne $fraction) {
            Set-Progress $fraction
            $name = ''
            if ($script:ActivePlan) { $name = [IO.Path]::GetFileName($script:ActivePlan.Source) }
            $number = $script:EncodeIndex
            $total = $script:EncodeItems.Count
            Set-Status ("File $number of $total - $name - " + ('{0:0}%' -f $fraction)) 'busy'
            if ($script:DetailedCheck.Checked) { Write-Activity $line 'dim' }
        }
        elseif ($script:DetailedCheck.Checked) {
            Write-Activity $line 'dim'
        }
    }
}

function Finish-Batch {
    param([string]$How)
    $script:Work = 'idle'
    $script:Cancel = $false
    Disable-KeepAwake
    Set-Progress 0
    $saved = Format-ByteSize $script:SavedBytes
    if ($How -eq 'stopped') {
        Set-Status 'Convert stopped' 'idle'
        Write-Activity 'Convert stopped. Finished files stay in place.' 'warn'
    }
    else {
        Set-Status ("Finished. Saved $saved.") 'ok'
        Write-Activity ("Finished. Saved $saved.") 'ok'
        if (-not $script:AutoCheck.Checked) {
            Write-Activity 'Compare a file, then click Delete originals when it looks right.' 'text'
        }
    }
    Update-BloatFolders
    if ($How -eq 'stopped') {
        if ($script:ShutdownCheck -and $script:ShutdownCheck.Checked) {
            Write-Activity 'Convert was stopped, so the computer will stay on.' 'text'
        }
    }
    else {
        Offer-Shutdown
    }
}

function Invoke-ShutdownExe {
    param([string[]]$Arguments)
    if ($script:SmokeTest) { throw 'Smoke test must not shut down the computer.' }
    $exe = Join-Path $env:SystemRoot 'System32\shutdown.exe'
    $process = Start-Process -FilePath $exe -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
    return [int]$process.ExitCode
}

function New-ShutdownForm {
    $form = New-Object Windows.Forms.Form
    $form.Text = 'Video Dehydrator'
    $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
    $form.StartPosition = 'CenterScreen'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $false
    $form.TopMost = $true
    $form.KeyPreview = $true
    $form.ClientSize = New-Object Drawing.Size(480, 176)
    $form.Font = $script:FontUi
    $form.BackColor = [Drawing.Color]::White
    $icon = Get-AppIcon
    if ($icon) { $form.Icon = $icon }
    $script:ShutdownSeconds = 60
    $label = New-Object Windows.Forms.Label
    $label.Font = $script:FontUi
    $label.ForeColor = $script:ColorInk
    $label.BackColor = [Drawing.Color]::White
    $label.SetBounds(24, 20, 432, 78)
    $script:ShutdownLabel = $label
    $label.Text = "Convert finished. This computer will shut down in 60 seconds.`r`n`r`nCancel if you want to keep working. Open programs will close."
    $now = New-Button 'Shut down now' 'danger' 140 34
    $cancel = New-Button 'Cancel' 'secondary' 110 34
    $now.SetBounds(196, 118, 140, 34)
    $cancel.SetBounds(346, 118, 110, 34)
    $form.Controls.Add($label)
    $form.Controls.Add($now)
    $form.Controls.Add($cancel)
    $script:ShutdownChoice = 'cancel'
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        $script:ShutdownSeconds--
        if ($script:ShutdownSeconds -le 0) {
            $timer.Stop()
            $script:ShutdownChoice = 'now'
            $form.Close()
            return
        }
        $label.Text = "Convert finished. This computer will shut down in $($script:ShutdownSeconds) seconds.`r`n`r`nCancel if you want to keep working. Open programs will close."
    }.GetNewClosure())
    $form.Tag = $timer
    $now.Add_Click({
        $timer.Stop()
        $script:ShutdownChoice = 'now'
        $form.Close()
    }.GetNewClosure())
    $cancel.Add_Click({
        $timer.Stop()
        $script:ShutdownChoice = 'cancel'
        $form.Close()
    }.GetNewClosure())
    $form.Add_KeyDown({
        if ($_.KeyCode -eq [Windows.Forms.Keys]::Escape) {
            $timer.Stop()
            $script:ShutdownChoice = 'cancel'
            $form.Close()
            $_.SuppressKeyPress = $true
        }
    }.GetNewClosure())
    $form.Add_Shown({ $timer.Start() }.GetNewClosure())
    return $form
}

function Offer-Shutdown {
    if ($script:SmokeTest) { return }
    if (-not $script:ShutdownCheck -or -not $script:ShutdownCheck.Checked) { return }
    Write-Activity 'Convert finished. Shutting down in 60 seconds unless you cancel.' 'text'
    $scheduled = $false
    $code = Invoke-ShutdownExe @('/s', '/t', '60', '/c', 'Video Dehydrator finished converting.')
    if ($code -eq 0) { $scheduled = $true }
    else {
        Write-Activity 'Windows did not accept the shutdown request. The computer will stay on.' 'err'
        return
    }
    $dialog = New-ShutdownForm
    $choice = 'cancel'
    try {
        [void]$dialog.ShowDialog()
        $choice = [string]$script:ShutdownChoice
    }
    catch {
        $choice = 'cancel'
        Write-Activity ("Could not show the shutdown countdown. " + $_.Exception.Message) 'err'
    }
    finally {
        $timer = $dialog.Tag
        if ($timer) { $timer.Stop(); $timer.Dispose() }
        $dialog.Dispose()
    }
    if ($choice -eq 'now') {
        Write-Activity 'Shutting down the computer.' 'text'
        Set-Status 'Shutting down...' 'busy'
        if ($script:ShutdownSeconds -gt 0) {
            if ($scheduled) { Invoke-ShutdownExe @('/a') | Out-Null }
            $again = Invoke-ShutdownExe @('/s', '/t', '5', '/c', 'Video Dehydrator finished converting.')
            if ($again -ne 0) {
                Write-Activity 'Windows did not start the shutdown. The computer will stay on.' 'err'
                $script:ShutdownRequested = $false
                return
            }
        }
        $script:ShutdownRequested = $true
        return
    }
    if ($scheduled) { Invoke-ShutdownExe @('/a') | Out-Null }
    $script:ShutdownRequested = $false
    Write-Activity 'Shutdown cancelled. The computer stays on.' 'text'
    Set-Status 'Finished. Shutdown cancelled.' 'ok'
}

function Start-Convert {
    if ($script:Work -ne 'idle') { return }
    $items = @(Get-CheckedItems @('Bloated', 'Failed'))
    if ($items.Count -eq 0) { return }
    if ($script:AutoCheck.Checked) {
        $answer = [Windows.Forms.MessageBox]::Show($script:Form, "Auto is on.`r`n`r`nAfter each file checks out, its original is deleted. The new file stays in the original's place. There will be nothing left to compare.", 'Video Dehydrator', 'OKCancel', 'Warning')
        if ($answer -ne [Windows.Forms.DialogResult]::OK) { return }
    }
    Stop-Playback
    Save-Settings
    $script:ConvertBatchId = [guid]::NewGuid().ToString('n')
    $script:Cancel = $false
    $script:SavedBytes = [int64]0
    $script:EncodeItems = $items
    $script:EncodeIndex = 0
    $script:Work = 'encode'
    Update-Buttons
    Enable-KeepAwake
    $word = if ($items.Count -eq 1) { 'file' } else { 'files' }
    Write-Activity ("Converting $($items.Count) $word.") 'text'
    if ($script:ShutdownCheck.Checked) {
        Write-Activity 'The computer will shut down when this convert finishes.' 'text'
    }
    Start-NextEncode
}

function Request-Cancel {
    if ($script:Work -eq 'idle') { return }
    $script:Cancel = $true
    Set-Status 'Stopping...' 'busy'
    if ($script:Work -eq 'scan' -and $script:ScanCancel) { $script:ScanCancel.Stop = $true }
    if ($script:Work -eq 'encode') { [VideoDehydrator.LinePump]::Kill() }
    Stop-ChildTools
}

function Remove-CheckedOriginals {
    $items = @(Get-CheckedItems @('Ready to delete'))
    if ($items.Count -eq 0) { return }
    $word = if ($items.Count -eq 1) { 'original' } else { 'originals' }
    $answer = [Windows.Forms.MessageBox]::Show($script:Form, "Delete $($items.Count) $word?`r`n`r`nThe new smaller files stay where the originals were.", 'Video Dehydrator', 'OKCancel', 'Warning')
    if ($answer -ne [Windows.Forms.DialogResult]::OK) { return }
    Stop-Playback
    $pending = @(Read-Pending)
    $removed = 0
    foreach ($item in $items) {
        $tag = $item.Tag
        try {
            if ($script:PlayRight -and [string]::Equals([string]$script:PlayRight, [string]$tag.New, [StringComparison]::OrdinalIgnoreCase)) {
                Stop-Playback
            }
            [void](Remove-KeptOriginal -KeptPath ([string]$tag.Kept) -NewPath ([string]$tag.New))
            $pending = @($pending | Where-Object { [string]$_.id -ne [string]$tag.PendingId })
            $tag.Status = 'Original deleted'
            $tag.Kept = ''
            $tag.PendingId = ''
            $tag.Reason = 'The held original was deleted.'
            $item.Checked = $false
            Update-ResultRow $item
            $removed++
            Write-Activity ("Deleted original of " + [IO.Path]::GetFileName([string]$tag.New)) 'ok'
        }
        catch {
            Write-Activity ("Could not delete " + [IO.Path]::GetFileName([string]$tag.Kept) + "  " + $_.Exception.Message) 'err'
        }
    }
    Write-Pending $pending
    Set-Status "Deleted $removed originals." 'ok'
    Update-Buttons
}

function Get-UndoBatch {
    $ready = @()
    foreach ($row in @(Read-Pending)) {
        if (-not $row -or $row -is [System.Array]) { continue }
        if (-not ($row.PSObject.Properties.Name -contains 'source')) { continue }
        if (-not $row.source -or -not $row.kept -or -not $row.new) { continue }
        if (-not (Test-Path -LiteralPath ([string]$row.kept))) { continue }
        $ready += $row
    }
    if ($ready.Count -eq 0) { return @() }
    $latest = $ready[0]
    foreach ($row in $ready) {
        if ([string]$row.when -gt [string]$latest.when) { $latest = $row }
    }
    $batch = [string]$latest.batch
    if ($batch) {
        return @($ready | Where-Object { [string]$_.batch -eq $batch })
    }
    $day = [string]$latest.when
    if ($day.Length -ge 10) { $day = $day.Substring(0, 10) } else { return @($latest) }
    return @($ready | Where-Object { -not [string]$_.batch -and ([string]$_.when).StartsWith($day) })
}

function Start-UndoLast {
    if ($script:Work -ne 'idle') { return }
    $batch = @(Get-UndoBatch)
    if ($batch.Count -eq 0) { return }
    $names = @($batch | ForEach-Object { [IO.Path]::GetFileName([string]$_.source) })
    $shown = @($names | Select-Object -First 8)
    $preview = $shown -join "`r`n"
    if ($names.Count -gt $shown.Count) {
        $preview += "`r`n" + ('and ' + ($names.Count - $shown.Count) + ' more.')
    }
    $word = if ($batch.Count -eq 1) { 'file' } else { 'files' }
    $answer = [Windows.Forms.MessageBox]::Show($script:Form, "Undo the last conversion?`r`n`r`n$($batch.Count) $word will be put back, and the new files will be deleted.`r`n`r`n$preview", 'Video Dehydrator', 'OKCancel', 'Warning')
    if ($answer -ne [Windows.Forms.DialogResult]::OK) { return }
    Stop-Playback
    if ($script:CompareForm -and -not $script:CompareForm.IsDisposed) { $script:CompareForm.Close() }
    $pending = @(Read-Pending)
    $restored = 0
    foreach ($row in $batch) {
        $sourceName = [IO.Path]::GetFileName([string]$row.source)
        try {
            [void](Undo-ReplacedFile -Source ([string]$row.source) -KeptPath ([string]$row.kept) -NewPath ([string]$row.new))
            $pending = @($pending | Where-Object { [string]$_.id -ne [string]$row.id })
            foreach ($item in @($script:Files.Items)) {
                $sameId = [string]$item.Tag.PendingId -and [string]$item.Tag.PendingId -eq [string]$row.id
                $sameNew = [string]$item.Tag.New -and [string]::Equals([string]$item.Tag.New, [string]$row.new, [StringComparison]::OrdinalIgnoreCase)
                if (-not $sameId -and -not $sameNew) { continue }
                $item.Tag.Status = 'Restored'
                $item.Tag.Path = [string]$row.source
                $item.Tag.Source = [string]$row.source
                $item.Tag.New = ''
                $item.Tag.Kept = ''
                $item.Tag.PendingId = ''
                if ($row.oldBytes) { $item.Tag.SizeBytes = [int64]$row.oldBytes }
                $item.Tag.Reason = 'The original was put back and the new file was deleted.'
                $item.Checked = $false
                Update-ResultRow $item
            }
            Add-RunLog -Status 'UNDONE' -Reason 'ok' -Source ([string]$row.source) -NewPath ([string]$row.new) -Kept ([string]$row.kept) -OldBytes $row.oldBytes -NewBytes $row.newBytes -OldRate $null -NewRate $null -Width $row.width -Height $row.height -Kbps $row.targetKbps
            $restored++
            Write-Activity ("Restored  $sourceName") 'ok'
        }
        catch {
            Write-Activity ("Could not restore $sourceName  " + $_.Exception.Message) 'err'
        }
    }
    Write-Pending $pending
    $doneWord = if ($restored -eq 1) { 'file' } else { 'files' }
    Set-Status "Restored $restored $doneWord." 'ok'
    Update-BloatFolders
    Update-Buttons
}

function Invoke-UiTick {
    if ($script:InTick) { return }
    $script:InTick = $true
    try {
        Refresh-KeepAwake
        if ($script:Work -eq 'scan') {
            Read-ScanQueue
            if ($script:ScanHandle -and $script:ScanHandle.IsCompleted) {
                Read-ScanQueue
                Finish-Scan
            }
        }
        elseif ($script:Work -eq 'encode') {
            Read-EncodeLines
            if ([VideoDehydrator.LinePump]::Exited) {
                Complete-ActiveEncode
            }
        }
        if ($script:Playing) {
            Update-PlayFrame
            Start-CompareAudio
            Update-PlayChrome
            if ($script:Player -and -not $script:Player.Running -and $script:Player.FrameIndex -gt 0) {
                $script:PlaySeconds = Get-PlayPosition
                Stop-Playback
            }
        }
    }
    catch {
        Write-Activity ("Something went wrong. " + $_.Exception.Message) 'err'
        if ($script:Work -ne 'idle') {
            try { [VideoDehydrator.LinePump]::Stop() } catch {}
            Stop-ChildTools
            $script:Work = 'idle'
            $script:Cancel = $false
            Disable-KeepAwake
            Update-Buttons
        }
    }
    finally {
        $script:InTick = $false
    }
}

function Layout-Actions {
    $panel = $script:ActionPanel
    if ($null -eq $panel -or $panel.ClientSize.Width -lt 20) { return }
    $y = [Math]::Max(0, [int](($panel.ClientSize.Height - $script:ScanButton.Height) / 2))
    $script:ScanButton.Location = New-Object Drawing.Point(0, $y)
    $script:ConvertButton.Location = New-Object Drawing.Point(($script:ScanButton.Right + 8), $y)
    $script:CancelButton.Location = New-Object Drawing.Point(($script:ConvertButton.Right + 8), ($y + 2))
    $script:HelpButton.Location = New-Object Drawing.Point(($panel.ClientSize.Width - $script:HelpButton.Width), ($y + 2))
    $script:DeleteButton.Location = New-Object Drawing.Point(($script:HelpButton.Left - 8 - $script:DeleteButton.Width), ($y + 2))
    $undoWidth = 0
    if ($script:UndoButton) { $undoWidth = $script:UndoButton.Width + 8 }
    if ($script:UndoButton) {
        $script:UndoButton.Location = New-Object Drawing.Point(($script:DeleteButton.Left - 8 - $script:UndoButton.Width), ($y + 2))
    }
    $script:CompareButton.Location = New-Object Drawing.Point(($script:DeleteButton.Left - 8 - $undoWidth - $script:CompareButton.Width), ($y + 2))
}

function Get-BudgetBox([string]$Id) {
    foreach ($box in @($script:BudgetBoxes)) {
        if ($box -and [string]$box.Tag -eq $Id) { return $box }
    }
    return $null
}

function Get-SelectedBudgetPack {
    if (-not $script:BudgetBoxes) { return (Get-BudgetPickPack) }
    $parts = New-Object System.Collections.Generic.List[string]
    $table = @(Get-BudgetFactorTable)
    foreach ($box in @($script:BudgetBoxes)) {
        if (-not $box) { continue }
        $pick = 'recommended'
        if ($box.SelectedIndex -ge 0 -and $box.SelectedIndex -lt $table.Count) {
            $pick = [string]$table[$box.SelectedIndex].Id
        }
        $parts.Add(([string]$box.Tag) + '=' + $pick)
    }
    return ($parts -join ';')
}

function Update-BudgetTips {
    $table = @(Get-BudgetFactorTable)
    foreach ($anchor in (Get-BudgetAnchors)) {
        $box = Get-BudgetBox ([string]$anchor.Id)
        if (-not $box) { continue }
        $pick = 'recommended'
        if ($box.SelectedIndex -ge 0 -and $box.SelectedIndex -lt $table.Count) {
            $pick = [string]$table[$box.SelectedIndex].Id
        }
        $numbers = Get-AnchorBudget -Anchor $anchor -PickId $pick
        $hevc = Format-BudgetGiB $numbers.HevcGiBph
        $text = "$($anchor.Name) budget, $($box.Text). The new file is encoded at $($numbers.Kbps) kbps. HEVC and AV1 are left alone under $hevc. A nearby picture size follows this choice. The choice is remembered."
        Set-Tip $box $text
    }
}

function Update-RowsForBudgets {
    $removed = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($script:Files.Items)) {
        if (-not $item -or -not $item.Tag) { continue }
        $status = [string]$item.Tag.Status
        if ($status -ne 'Bloated' -and $status -ne 'Failed') { continue }
        $width = 0
        $height = 0
        [void][int]::TryParse([string]$item.Tag.Width, [ref]$width)
        [void][int]::TryParse([string]$item.Tag.Height, [ref]$height)
        if ($width -le 0 -or $height -le 0) { continue }
        $bits = [int64]0
        if ($item.Tag.VideoBitrate) { $bits = [int64]$item.Tag.VideoBitrate }
        $codec = [string]$item.Tag.Codec
        $probe = [pscustomobject]@{
            Width            = $width
            Height           = $height
            SizeBytes        = [int64]$item.Tag.SizeBytes
            DurationSec      = [double]$item.Tag.DurationSec
            VideoBitrate     = $bits
            AlreadyEfficient = ($codec -in @('hevc', 'h265', 'av1'))
            IsDolbyVision    = $false
        }
        $decision = Get-BloatDecision -Probe $probe
        if ($decision.Decision -eq 'lean' -or $decision.Decision -eq 'within') {
            $removed.Add($item)
            continue
        }
        if ($decision.Decision -ne 'bloated') { continue }
        $item.Tag.BudgetGiBph = $decision.BudgetGiBph
        $item.Tag.TargetKbps = $decision.TargetKbps
        $item.Tag.GiBph = $decision.GiBph
        if ($null -ne $decision.EstimateBytes) { $item.Tag.EstimateBytes = $decision.EstimateBytes }
        if ($status -eq 'Bloated') { $item.Tag.Reason = $decision.Reason }
        Update-ResultRow $item
    }
    if ($removed.Count -gt 0) {
        $script:Files.BeginUpdate()
        try {
            foreach ($item in $removed) { $script:Files.Items.Remove($item) }
        }
        finally { $script:Files.EndUpdate() }
    }
    return $removed.Count
}

function Test-BudgetTighter([string]$Before, [string]$After) {
    $old = @{}
    $new = @{}
    foreach ($part in ($Before -split ';')) {
        if ($part -match '^(\d+)=(.+)$') { $old[$Matches[1]] = $Matches[2] }
    }
    foreach ($part in ($After -split ';')) {
        if ($part -match '^(\d+)=(.+)$') { $new[$Matches[1]] = $Matches[2] }
    }
    $factors = @{}
    foreach ($row in (Get-BudgetFactorTable)) { $factors[[string]$row.Id] = [double]$row.Factor }
    foreach ($id in @($new.Keys)) {
        $was = 1.0
        $now = 1.0
        if ($old.ContainsKey($id) -and $factors.ContainsKey([string]$old[$id])) { $was = [double]$factors[[string]$old[$id]] }
        if ($factors.ContainsKey([string]$new[$id])) { $now = [double]$factors[[string]$new[$id]] }
        if ($now -lt $was) { return $true }
    }
    return $false
}

function Update-BudgetChoice {
    if ($script:Loading) { return }
    $previous = Get-BudgetPickPack
    $pack = Get-SelectedBudgetPack
    if ($pack -eq $previous) { return }
    $tighter = Test-BudgetTighter $previous $pack
    Set-BudgetPicks $pack
    Save-Settings
    $removed = Update-RowsForBudgets
    Update-BloatFolders
    Update-BudgetTips
    $table = @(Get-BudgetFactorTable)
    $notes = New-Object System.Collections.Generic.List[string]
    foreach ($anchor in (Get-BudgetAnchors)) {
        $box = Get-BudgetBox ([string]$anchor.Id)
        if (-not $box) { continue }
        $pick = 'recommended'
        if ($box.SelectedIndex -ge 0 -and $box.SelectedIndex -lt $table.Count) {
            $pick = [string]$table[$box.SelectedIndex].Id
        }
        $was = 'recommended'
        foreach ($part in ($previous -split ';')) {
            if ($part -like ([string]$anchor.Id + '=*')) { $was = $part.Substring($anchor.Id.Length + 1) }
        }
        if ($was -eq $pick) { continue }
        $numbers = Get-AnchorBudget -Anchor $anchor -PickId $pick
        $notes.Add("$($anchor.Name) is $($box.Text), encoding at $($numbers.Kbps) kbps")
    }
    if ($removed -eq 1) { $notes.Add('1 file fell under the new budget and left the list') }
    elseif ($removed -gt 1) { $notes.Add("$removed files fell under the new budget and left the list") }
    if ($tighter) { $notes.Add('Scan again to include files that were under the old budget') }
    if ($notes.Count -gt 0) { Write-Activity (($notes -join '. ') + '.') 'text' }
}

function Layout-Options {
    $card = $script:OptionsCard
    if ($null -eq $card -or $card.ClientSize.Width -lt 20) { return }
    $script:OptionsTitle.SetBounds(16, 8, 200, 22)
    $y = 36
    foreach ($chk in @($script:SubfoldersCheck, $script:AutoCheck, $script:DetailedCheck, $script:ShutdownCheck)) {
        if (-not $chk) { continue }
        $chk.Location = New-Object Drawing.Point(16, $y)
        $y += 28
    }
    if (-not $script:BudgetTitle) { return }
    $split = 360
    $script:BudgetTitle.SetBounds($split, 8, 180, 22)
    $width = $card.ClientSize.Width - 16 - $split
    if ($width -lt 280) { $width = 280 }
    $col = [int]($width / 2)
    for ($i = 0; $i -lt @($script:BudgetBoxes).Count; $i++) {
        $label = $script:BudgetLabels[$i]
        $box = $script:BudgetBoxes[$i]
        if (-not $label -or -not $box) { continue }
        $colIndex = $i % 2
        $rowIndex = [int][math]::Floor($i / 2)
        $x = $split + ($colIndex * $col)
        $rowY = 36 + ($rowIndex * 36)
        $label.SetBounds($x, ($rowY + 4), 52, 22)
        $boxW = $col - 52 - 14
        if ($boxW -lt 140) { $boxW = 140 }
        $box.SetBounds(($x + 52), $rowY, $boxW, 28)
    }
}

function Layout-Hint {
    $panel = $script:HintPanel
    if ($null -eq $panel -or $panel.ClientSize.Width -lt 20) { return }
    if (-not $script:SavingsLabel -or -not $script:HintLabel) { return }
    $y = [Math]::Max(0, [int](($panel.ClientSize.Height - $script:SavingsLabel.Height) / 2))
    $script:SavingsLabel.Location = New-Object Drawing.Point(($panel.ClientSize.Width - $script:SavingsLabel.Width), $y)
    $width = $script:SavingsLabel.Left - 16
    if ($width -lt 40) { $width = 40 }
    $script:HintLabel.SetBounds(0, 0, $width, $panel.ClientSize.Height)
}

function Layout-Folder {
    $card = $script:FolderCard
    if ($null -eq $card -or $card.ClientSize.Width -lt 20) { return }
    $script:BrowseButton.Location = New-Object Drawing.Point(($card.ClientSize.Width - 16 - $script:BrowseButton.Width), 8)
    $script:FolderLabel.Location = New-Object Drawing.Point(16, 12)
    $left = $script:FolderLabel.Right + 8
    $width = $script:BrowseButton.Left - 8 - $left
    if ($width -lt 40) { $width = 40 }
    $script:FolderBox.SetBounds($left, 10, $width, 26)
}

function Layout-ListHeader {
    $panel = $script:ListHeader
    if ($null -eq $panel -or $panel.ClientSize.Width -lt 20) { return }
    $script:ListLabel.Location = New-Object Drawing.Point(0, 6)
    $script:SelectNoneButton.Location = New-Object Drawing.Point(($panel.ClientSize.Width - $script:SelectNoneButton.Width), 2)
    $script:SelectAllButton.Location = New-Object Drawing.Point(($script:SelectNoneButton.Left - 8 - $script:SelectAllButton.Width), 2)
    $script:SelectFolderButton.Location = New-Object Drawing.Point(($script:SelectAllButton.Left - 8 - $script:SelectFolderButton.Width), 2)
    $left = $script:ListLabel.Right + 12
    $width = $script:SelectFolderButton.Left - 8 - $left
    if ($width -lt 120) { $width = 120 }
    $script:FolderPick.SetBounds($left, 3, $width, 26)
}

function Layout-FileColumns {
    $list = $script:Files
    if ($null -eq $list -or $list.Columns.Count -lt 2) { return }
    $fixed = 0
    for ($i = 1; $i -lt $list.Columns.Count; $i++) { $fixed += $list.Columns[$i].Width }
    $fileWidth = $list.ClientSize.Width - $fixed - 8
    if ($fileWidth -lt 160) { $fileWidth = 160 }
    if ($list.Columns[0].Width -ne $fileWidth) { $list.Columns[0].Width = $fileWidth }
}

function Update-ChromeLayout {
    $header = $script:Header
    if ($header -and $header.ClientSize.Width -gt 0) {
        $script:TitleLabel.SetBounds(28, 16, ($header.ClientSize.Width - 56), 36)
        $script:SubtitleLabel.SetBounds(28, 54, ($header.ClientSize.Width - 56), 48)
    }
    $status = $script:StatusPanel
    if ($status -and $status.ClientSize.Width -gt 0) {
        $script:StatusLabel.SetBounds(24, 8, ($status.ClientSize.Width - 48), 22)
        $script:ProgressTrack.SetBounds(24, 36, ([Math]::Max(0, $status.ClientSize.Width - 48)), 8)
        Set-Progress $script:ProgressValue
    }
    Layout-Folder
    Layout-Hint
    Layout-ListHeader
    Layout-FileColumns
    Layout-Options
    Layout-Actions
}

function Get-HelpSections {
    $license = Join-Path $script:ToolsDir 'FFmpeg-LICENSE.txt'
    return @(
        @{
            Title = 'Opening the program'
            Body = "Double-click Video Dehydrator in this folder. The window that opens is the whole program.`r`n`r`nIf you move this folder and that shortcut stops opening, open app\launch.vbs. That starts the program and repairs the shortcut."
        },
        @{
            Title = 'What it does'
            Body = "Point it at a folder. Scan finds videos that are too big for their picture size. Convert makes a smaller copy with the same picture size, the same audio, and the same subtitles.`r`n`r`nThe new file takes the original's place. The original is kept in a folder named .vd-originals next to it, until you delete it. Turn on Delete originals automatically to remove each original as soon as its new file checks out."
        },
        @{
            Title = 'The size rule'
            Body = "A 1920x1080 video is too big when the whole file is 2 GiB per hour or more. HEVC and AV1 are left alone under 3 GiB per hour. The target for that 1080p picture is 3000 kbps of video. This is the same rule the media library uses.`r`n`r`nOther picture sizes multiply those numbers by how many pixels they have compared with 1920x1080. 3840x2160 has four times the pixels, so 4K is allowed 8 GiB per hour and is encoded at 12000 kbps. 1280x720 is encoded at 1333 kbps. 720x480 is encoded at 500 kbps. A very small picture stays at 200 kbps.`r`n`r`nThe Budgets row has a choice for 2160p, 1080p, 720p, and 480p. Each one starts on Recommended, which is the line above. Half, 1.5 times, and Double lower or raise that line, and the encode rate moves with it. A picture of some other size uses the closest of those four, then scales by its number of pixels. HEVC and AV1 stay at one and a half times the budget you picked. The choices are remembered.`r`n`r`nScan again after a change. A higher budget takes files that are no longer over the line off the list. A lower budget finds new files on the next scan.`r`n`r`nThe encode is software x265, two passes, medium speed. The frame rate stays as it was. The picture is not cropped or scaled. Audio is copied. Subtitles are copied and are not burned into the picture.`r`n`r`nA file whose picture is already at that target rate is left alone, even when the file is large because of the audio. Dolby Vision is left alone."
        },
        @{
            Title = 'Scanning'
            Body = "Browse, or drop a folder onto the path, then click Scan. Include subfolders looks inside every folder within the one you chose. The list shows the bloated files, checked and ready to convert.`r`n`r`nSelect all checks every row. Deselect all clears every check. The folder list names each folder that has bloated files, and a show is listed along with the season folders inside it. Select folder checks only the bloated files in the folder you picked and clears the other checks, so Convert is that smaller job. Right-click a row for the same choices.`r`n`r`nGiB/h is the size of the whole file per hour of runtime. Budget is the line for that picture size. Target is the video rate the new file will use. About is a rough guess of the new size when the current video rate can be read. Estimated savings is the current size minus About, added up for the checked files. It changes as those checks change. A file with no About figure is left out of the total."
        },
        @{
            Title = 'Converting'
            Body = "Convert shrinks every checked file whose status is Bloated or Failed. One file is encoded at a time. The bar is that file. Cancel stops the file that is running. Files that already finished stay finished.`r`n`r`nThe new file is written inside .vd-originals first, then checked: it has to be smaller, the same length, the same picture size, with the same audio and at least as many subtitles, and the start and end have to play. When the check passes, the original moves into .vd-originals and the new .mkv takes its place. When the check fails, the original stays where it was.`r`n`r`nThe folder needs free space for the new file while the original is still there. Show detailed activity adds the encoder's own messages.`r`n`r`nShutdown computer upon completion turns the computer off after the convert finishes. A one-minute countdown gives you a chance to cancel. If you stop the convert, the computer stays on. A scan does not turn the computer off."
        },
        @{
            Title = 'Checking the picture'
            Body = "Select a file marked Ready to delete and click Compare. The window plays both copies side by side at normal speed: original on the left, new file on the right. Sound is the new file, which carries the original audio. The slider moves through both together.`r`n`r`nThis preview is for review. It is a smaller picture than the files themselves, so you can see them next to each other."
        },
        @{
            Title = 'Originals and deleting'
            Body = "Delete originals removes the checked files that are still in .vd-originals. The new files stay. The button refuses to delete anything outside that holding folder. If the new file is missing, the original is kept.`r`n`r`nUndo puts back the last conversion. The originals return to where they were, and the new files are deleted. The program lists the files and asks before it does this. One use covers every file from that convert. It can only undo a conversion whose original is still in .vd-originals. If those originals were already deleted, there is nothing to put back.`r`n`r`nA .plexignore file in the video's folder tells Plex to skip .vd-originals. Held originals are remembered in app\pending.json, so they are still listed the next time you open the program.`r`n`r`nEach result is also written to app\convert-log.tsv."
        },
        @{
            Title = 'Auto'
            Body = "Delete originals automatically does the deletion as soon as a file checks out. The program asks once before a convert with Auto turned on. With Auto off, every original stays until you press Delete originals."
        },
        @{
            Title = 'What is in this folder'
            Body = "Video Dehydrator: double-click this to open the program.`r`napp: the program, your settings, the list of originals still waiting, and the convert log.`r`ntools: HandBrake, which encodes, and FFmpeg, which reads the files and plays the comparison. FFmpeg is free software. Its license is $license. HandBrake is free software under the GPL."
        }
    )
}

function Add-HelpHeading($box, [string]$text) {
    if ($box.TextLength -gt 0) {
        $box.SelectionStart = $box.TextLength
        $box.SelectionLength = 0
        $box.SelectionFont = $script:FontHelpBody
        $box.SelectionColor = $script:ColorBody
        $box.AppendText([Environment]::NewLine)
    }
    $box.SelectionStart = $box.TextLength
    $box.SelectionLength = 0
    $box.SelectionFont = $script:FontHelpHeading
    $box.SelectionColor = $script:ColorInk
    $box.AppendText($text + [Environment]::NewLine)
}

function Add-HelpBody($box, [string]$text) {
    $box.SelectionStart = $box.TextLength
    $box.SelectionLength = 0
    $box.SelectionFont = $script:FontHelpBody
    $box.SelectionColor = $script:ColorBody
    $box.AppendText($text.Trim() + [Environment]::NewLine)
}

function New-HelpForm {
    $help = New-Object Windows.Forms.Form
    $help.Text = 'How this works'
    $help.StartPosition = 'CenterParent'
    $help.Font = $script:FontUi
    $help.BackColor = [Drawing.Color]::White
    $help.AutoScaleMode = [Windows.Forms.AutoScaleMode]::None
    $help.MinimizeBox = $false
    $help.MaximizeBox = $true
    $help.ShowInTaskbar = $false
    $help.KeyPreview = $true
    $area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $help.ClientSize = New-Object Drawing.Size([Math]::Min(760, $area.Width - 40), [Math]::Min(820, $area.Height - 40))
    $help.MinimumSize = New-Object Drawing.Size([Math]::Min(640, $area.Width), [Math]::Min(480, $area.Height))
    $icon = Get-AppIcon
    if ($icon) { $help.Icon = $icon }
    Enable-DoubleBuffer $help

    $header = New-Object Windows.Forms.Panel
    $header.Dock = 'Top'
    $header.Height = 92
    $header.BackColor = $script:ColorHeader
    $title = New-Object Windows.Forms.Label
    $title.Text = 'How this works'
    $title.Font = $script:FontTitle
    $title.ForeColor = [Drawing.Color]::White
    $title.BackColor = $script:ColorHeader
    $sub = New-Object Windows.Forms.Label
    $sub.Text = 'Folders, the size rule, comparing, and deleting originals.'
    $sub.Font = $script:FontSubtitle
    $sub.ForeColor = $script:ColorHeaderMuted
    $sub.BackColor = $script:ColorHeader
    $header.Controls.Add($title)
    $header.Controls.Add($sub)
    $header.Add_Resize({
        $this.Controls[0].SetBounds(28, 16, ($this.ClientSize.Width - 56), 36)
        $this.Controls[1].SetBounds(28, 54, ($this.ClientSize.Width - 56), 24)
    })

    $footer = New-Object Windows.Forms.Panel
    $footer.Dock = 'Bottom'
    $footer.Height = 64
    $footer.BackColor = $script:ColorPage
    $close = New-Button 'Close' 'secondary' 110 34
    $footer.Controls.Add($close)
    $footer.Add_Resize({ $this.Controls[0].Location = New-Object Drawing.Point(($this.ClientSize.Width - $this.Controls[0].Width - 24), 14) })
    $footer.Add_Paint({
        $pen = New-Object Drawing.Pen $script:ColorLine
        $_.Graphics.DrawLine($pen, 0, 0, $this.Width, 0)
        $pen.Dispose()
    })
    $close.Add_Click({ $script:HelpForm.Close() })

    $bodyHost = New-Object Windows.Forms.Panel
    $bodyHost.Dock = 'Fill'
    $bodyHost.BackColor = [Drawing.Color]::White
    $bodyHost.Padding = New-Object Windows.Forms.Padding(24, 12, 12, 8)
    $box = New-Object Windows.Forms.RichTextBox
    $box.Dock = 'Fill'
    $box.BorderStyle = 'None'
    $box.ReadOnly = $true
    $box.BackColor = [Drawing.Color]::White
    $box.Font = $script:FontHelpBody
    $box.DetectUrls = $false
    $box.ScrollBars = 'Vertical'
    $box.ShortcutsEnabled = $true
    $bodyHost.Controls.Add($box)
    foreach ($section in (Get-HelpSections)) {
        Add-HelpHeading $box $section.Title
        Add-HelpBody $box $section.Body
    }
    $box.SelectionStart = 0
    $box.SelectionLength = 0
    $script:HelpBox = $box
    $help.Controls.Add($bodyHost)
    $help.Controls.Add($footer)
    $help.Controls.Add($header)
    $help.Add_KeyDown({
        if ($_.KeyCode -eq [Windows.Forms.Keys]::Escape) {
            $script:HelpForm.Close()
            $_.SuppressKeyPress = $true
        }
    })
    $help.Add_FormClosed({ $script:HelpForm = $null })
    return $help
}

function Show-Help {
    if ($script:HelpForm -and -not $script:HelpForm.IsDisposed) {
        $script:HelpForm.Activate()
        return
    }
    $script:HelpForm = New-HelpForm
    [void]$script:HelpForm.Show($script:Form)
}

function Write-Welcome {
    Write-Activity 'Ready. Choose a folder, then click Scan.' 'text'
    Write-Activity 'Scan lists videos that are too big for their picture size. The Budgets row starts on Recommended.' 'text'
    Write-Activity 'Convert puts the smaller file where the original was and keeps the original until you delete it.' 'text'
}

function Warn-MissingTools {
    $missing = @(Get-MissingTools)
    if ($missing.Count -eq 0) {
        $script:ToolsOk = $true
        return
    }
    $script:ToolsOk = $false
    $text = "These tools need to be in the tools folder:`r`n" + ($missing -join "`r`n")
    Write-Activity $text 'err'
    if (-not $script:SmokeTest) {
        [Windows.Forms.MessageBox]::Show($text, 'Video Dehydrator', 'OK', 'Error') | Out-Null
    }
}

# Window
$script:TipMap = @{}
$script:Tips = New-Object Windows.Forms.ToolTip
$script:Tips.InitialDelay = 400
$script:Tips.ReshowDelay = 200
$script:Tips.AutoPopDelay = 20000
$script:Tips.ShowAlways = $true

$settings = Load-Settings
Set-BudgetPicks ([string]$settings.Budgets)
$script:Loading = $true

$script:Form = New-Object Windows.Forms.Form
$script:Form.Text = 'Video Dehydrator'
$script:Form.Font = $script:FontUi
$script:Form.BackColor = $script:ColorPage
$script:Form.StartPosition = 'CenterScreen'
$script:Form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::None
$script:Form.KeyPreview = $true
$script:Form.AllowDrop = $true
$area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$wantW = 1120
$wantH = 920
if ($wantW -gt ($area.Width - 24)) { $wantW = [Math]::Max(860, $area.Width - 24) }
if ($wantH -gt ($area.Height - 24)) { $wantH = [Math]::Max(680, $area.Height - 24) }
$script:Form.ClientSize = New-Object Drawing.Size($wantW, $wantH)
$script:Form.MinimumSize = New-Object Drawing.Size([Math]::Min(960, $area.Width), [Math]::Min(760, $area.Height))
$appIcon = Get-AppIcon
if ($appIcon) { $script:Form.Icon = $appIcon }
Enable-DoubleBuffer $script:Form

$script:Header = New-Object Windows.Forms.Panel
$script:Header.Dock = 'Top'
$script:Header.Height = 112
$script:Header.BackColor = $script:ColorHeader
$script:TitleLabel = New-Object Windows.Forms.Label
$script:TitleLabel.Text = 'Video Dehydrator'
$script:TitleLabel.Font = $script:FontTitle
$script:TitleLabel.ForeColor = [Drawing.Color]::White
$script:TitleLabel.BackColor = $script:ColorHeader
$script:SubtitleLabel = New-Object Windows.Forms.Label
$script:SubtitleLabel.Text = "Shrink videos that are too big for their picture size. The smaller file takes the original's place."
$script:SubtitleLabel.Font = $script:FontSubtitle
$script:SubtitleLabel.ForeColor = $script:ColorHeaderMuted
$script:SubtitleLabel.BackColor = $script:ColorHeader
$script:Header.Controls.Add($script:TitleLabel)
$script:Header.Controls.Add($script:SubtitleLabel)

$script:StatusPanel = New-Object Windows.Forms.Panel
$script:StatusPanel.Dock = 'Bottom'
$script:StatusPanel.Height = 58
$script:StatusPanel.BackColor = [Drawing.Color]::White
$script:StatusLabel = New-Object Windows.Forms.Label
$script:StatusLabel.Text = 'Ready'
$script:StatusLabel.Font = $script:FontUi
$script:StatusLabel.ForeColor = $script:ColorMuted
$script:StatusLabel.AutoEllipsis = $true
$script:StatusLabel.BackColor = [Drawing.Color]::White
$script:ProgressTrack = New-Object Windows.Forms.Panel
$script:ProgressTrack.BackColor = [Drawing.Color]::FromArgb(229, 231, 235)
$script:ProgressTrack.Height = 8
$script:ProgressFill = New-Object Windows.Forms.Panel
$script:ProgressFill.BackColor = $script:ColorPrimary
$script:ProgressFill.Height = 8
$script:ProgressFill.Width = 0
$script:ProgressTrack.Controls.Add($script:ProgressFill)
$script:StatusPanel.Controls.Add($script:StatusLabel)
$script:StatusPanel.Controls.Add($script:ProgressTrack)
$script:StatusPanel.Add_Paint({
    $pen = New-Object Drawing.Pen $script:ColorLine
    $_.Graphics.DrawLine($pen, 0, 0, $script:StatusPanel.Width, 0)
    $pen.Dispose()
})

$table = New-Object Windows.Forms.TableLayoutPanel
$table.Dock = 'Fill'
$table.BackColor = $script:ColorPage
$table.ColumnCount = 1
$table.RowCount = 9
$table.Padding = New-Object Windows.Forms.Padding(24, 16, 24, 8)
$table.Margin = New-Object Windows.Forms.Padding(0)
$table.GrowStyle = 'FixedSize'
[void]$table.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 26)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 48)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 40)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 36)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 58)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 196)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 56)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 26)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 42)))

$folderCaption = New-Object Windows.Forms.Label
$folderCaption.Text = 'Folder'
$folderCaption.Font = $script:FontSection
$folderCaption.ForeColor = $script:ColorInk
$folderCaption.BackColor = $script:ColorPage
$folderCaption.Dock = 'Fill'
$folderCaption.TextAlign = 'BottomLeft'

$script:FolderCard = New-Object Windows.Forms.Panel
$script:FolderCard.Dock = 'Fill'
$script:FolderCard.BackColor = [Drawing.Color]::White
$script:FolderCard.Margin = New-Object Windows.Forms.Padding(0, 4, 0, 0)
$script:FolderLabel = New-Object Windows.Forms.Label
$script:FolderLabel.Text = 'Look in'
$script:FolderLabel.AutoSize = $true
$script:FolderLabel.Font = $script:FontUi
$script:FolderLabel.ForeColor = $script:ColorInk
$script:FolderLabel.BackColor = [Drawing.Color]::White
$script:FolderBox = New-Object Windows.Forms.TextBox
$script:FolderBox.ReadOnly = $true
$script:FolderBox.Font = $script:FontUi
$script:FolderBox.BackColor = [Drawing.Color]::White
$script:FolderBox.ForeColor = $script:ColorInk
$script:FolderBox.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
$script:FolderBox.AllowDrop = $true
$script:BrowseButton = New-Button 'Browse' 'secondary' 96 28
$script:BrowseButton.Margin = New-Object Windows.Forms.Padding(0)
$script:FolderCard.Controls.Add($script:FolderLabel)
$script:FolderCard.Controls.Add($script:FolderBox)
$script:FolderCard.Controls.Add($script:BrowseButton)
$script:FolderCard.Add_Paint({
    $pen = New-Object Drawing.Pen $script:ColorLine
    $_.Graphics.DrawRectangle($pen, 0, 0, ($script:FolderCard.Width - 1), ($script:FolderCard.Height - 1))
    $pen.Dispose()
})
$script:FolderCard.AllowDrop = $true
$script:FolderCard.Add_DragEnter({
    if ($script:Work -ne 'idle') { $_.Effect = 'None'; return }
    if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = 'Copy' } else { $_.Effect = 'None' }
})
$script:FolderCard.Add_DragDrop({ Add-DroppedFolder $_.Data })
$script:FolderBox.Add_DragEnter({
    if ($script:Work -ne 'idle') { $_.Effect = 'None'; return }
    if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = 'Copy' } else { $_.Effect = 'None' }
})
$script:FolderBox.Add_DragDrop({ Add-DroppedFolder $_.Data })
$script:BrowseButton.Add_Click({ Choose-Folder })

$script:HintPanel = New-Object Windows.Forms.Panel
$script:HintPanel.Dock = 'Fill'
$script:HintPanel.BackColor = $script:ColorPage
$script:HintPanel.Margin = New-Object Windows.Forms.Padding(0)
$script:HintLabel = New-Object Windows.Forms.Label
$script:HintLabel.Text = 'Include subfolders looks inside every folder within this one. Checked rows are the ones Convert will shrink.'
$script:HintLabel.Font = $script:FontHint
$script:HintLabel.ForeColor = $script:ColorMuted
$script:HintLabel.BackColor = $script:ColorPage
$script:HintLabel.AutoEllipsis = $true
$script:HintLabel.TextAlign = 'MiddleLeft'
$script:SavingsLabel = New-Object Windows.Forms.Label
$script:SavingsLabel.Text = 'Estimated savings: 0 B'
$script:SavingsLabel.Font = $script:FontButtonBold
$script:SavingsLabel.ForeColor = $script:ColorOkText
$script:SavingsLabel.BackColor = $script:ColorPage
$script:SavingsLabel.AutoSize = $true
$script:HintPanel.Controls.Add($script:HintLabel)
$script:HintPanel.Controls.Add($script:SavingsLabel)
$script:HintPanel.Add_Resize({ Layout-Hint })

$script:ListHeader = New-Object Windows.Forms.Panel
$script:ListHeader.Dock = 'Fill'
$script:ListHeader.BackColor = $script:ColorPage
$script:ListHeader.Margin = New-Object Windows.Forms.Padding(0)
$script:ListLabel = New-Object Windows.Forms.Label
$script:ListLabel.Text = 'Videos'
$script:ListLabel.Font = $script:FontSection
$script:ListLabel.ForeColor = $script:ColorInk
$script:ListLabel.BackColor = $script:ColorPage
$script:ListLabel.AutoSize = $true
$script:FolderPick = New-Object Windows.Forms.ComboBox
$script:FolderPick.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
$script:FolderPick.Font = $script:FontUi
$script:FolderPick.IntegralHeight = $false
$script:FolderPick.DropDownHeight = 320
$script:FolderPick.DropDownWidth = 520
$script:SelectFolderButton = New-Button 'Select folder' 'secondary' 124 28
$script:SelectAllButton = New-Button 'Select all' 'secondary' 104 28
$script:SelectNoneButton = New-Button 'Deselect all' 'secondary' 120 28
$script:SelectFolderButton.Margin = New-Object Windows.Forms.Padding(0)
$script:SelectAllButton.Margin = New-Object Windows.Forms.Padding(0)
$script:SelectNoneButton.Margin = New-Object Windows.Forms.Padding(0)
$script:ListHeader.Controls.Add($script:ListLabel)
$script:ListHeader.Controls.Add($script:FolderPick)
$script:ListHeader.Controls.Add($script:SelectFolderButton)
$script:ListHeader.Controls.Add($script:SelectAllButton)
$script:ListHeader.Controls.Add($script:SelectNoneButton)
$script:SelectFolderButton.Add_Click({ Select-ChosenFolder })
$script:SelectAllButton.Add_Click({ Set-AllChecks $true })
$script:SelectNoneButton.Add_Click({ Set-AllChecks $false })

$script:Files = New-Object Windows.Forms.ListView
$script:Files.Dock = 'Fill'
$script:Files.View = 'Details'
$script:Files.FullRowSelect = $true
$script:Files.CheckBoxes = $true
$script:Files.GridLines = $false
$script:Files.HideSelection = $false
$script:Files.MultiSelect = $false
$script:Files.Font = $script:FontUi
$script:Files.BackColor = [Drawing.Color]::White
$script:Files.ForeColor = $script:ColorInk
$script:Files.BorderStyle = 'FixedSingle'
$script:Files.ShowItemToolTips = $true
$script:Files.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 4)
[void]$script:Files.Columns.Add('File', 280)
[void]$script:Files.Columns.Add('Picture', 110)
[void]$script:Files.Columns.Add('Length', 80)
[void]$script:Files.Columns.Add('Size', 170)
[void]$script:Files.Columns.Add('GiB/h', 70)
[void]$script:Files.Columns.Add('Budget', 70)
[void]$script:Files.Columns.Add('Target', 100)
[void]$script:Files.Columns.Add('About', 90)
[void]$script:Files.Columns.Add('Status', 150)
$script:Files.Add_ItemChecked({ if (-not $script:BulkCheck) { Update-Buttons } })
$script:Files.Add_SelectedIndexChanged({ Update-Buttons })
$script:FileMenu = New-Object Windows.Forms.ContextMenuStrip
$script:FileMenu.Font = $script:FontUi
[void]$script:FileMenu.Items.Add('Select all')
[void]$script:FileMenu.Items.Add('Deselect all')
[void]$script:FileMenu.Items.Add('Select files in this folder')
$script:FileMenu.Items[0].Add_Click({ Set-AllChecks $true })
$script:FileMenu.Items[1].Add_Click({ Set-AllChecks $false })
$script:FileMenu.Items[2].Add_Click({ Select-FolderOfSelectedFile })
$script:FileMenu.Add_Opening({
    $busy = ($script:Work -ne 'idle')
    $hasRow = ($script:Files.SelectedItems.Count -eq 1)
    $script:FileMenu.Items[0].Enabled = -not $busy
    $script:FileMenu.Items[1].Enabled = -not $busy
    $script:FileMenu.Items[2].Enabled = ((-not $busy) -and $hasRow)
})
$script:Files.ContextMenuStrip = $script:FileMenu
$script:Files.Add_MouseDown({
    if ($_.Button -ne [Windows.Forms.MouseButtons]::Right) { return }
    $hit = $script:Files.HitTest($_.X, $_.Y)
    if ($hit.Item) { $hit.Item.Selected = $true }
})
$script:Files.Add_DoubleClick({
    if ($script:CompareButton.Enabled) { Show-Compare }
})
Enable-DoubleBuffer $script:Files

$script:OptionsCard = New-Object Windows.Forms.Panel
$script:OptionsCard.Dock = 'Fill'
$script:OptionsCard.BackColor = [Drawing.Color]::White
$script:OptionsCard.Margin = New-Object Windows.Forms.Padding(0, 6, 0, 6)
$script:OptionsTitle = New-Object Windows.Forms.Label
$script:OptionsTitle.Text = 'Options'
$script:OptionsTitle.Font = $script:FontSection
$script:OptionsTitle.ForeColor = $script:ColorInk
$script:OptionsTitle.BackColor = [Drawing.Color]::White
$script:SubfoldersCheck = New-Check 'Include subfolders'
$script:AutoCheck = New-Check 'Delete originals automatically'
$script:DetailedCheck = New-Check 'Show detailed activity'
$script:ShutdownCheck = New-Check 'Shutdown computer upon completion'
$script:SubfoldersCheck.Checked = [bool]$settings.IncludeSubfolders
$script:AutoCheck.Checked = [bool]$settings.AutoDelete
$script:DetailedCheck.Checked = [bool]$settings.Detailed
$script:ShutdownCheck.Checked = [bool]$settings.Shutdown
$script:OptionsCard.Controls.Add($script:OptionsTitle)
$script:OptionsCard.Controls.Add($script:SubfoldersCheck)
$script:OptionsCard.Controls.Add($script:AutoCheck)
$script:OptionsCard.Controls.Add($script:DetailedCheck)
$script:OptionsCard.Controls.Add($script:ShutdownCheck)
$script:BudgetTitle = New-Object Windows.Forms.Label
$script:BudgetTitle.Text = 'Budgets'
$script:BudgetTitle.Font = $script:FontSection
$script:BudgetTitle.ForeColor = $script:ColorInk
$script:BudgetTitle.BackColor = [Drawing.Color]::White
$script:BudgetLabels = @()
$script:BudgetBoxes = @()
foreach ($anchor in (Get-BudgetAnchors)) {
    $name = New-Object Windows.Forms.Label
    $name.Text = [string]$anchor.Name
    $name.Font = $script:FontUi
    $name.ForeColor = $script:ColorInk
    $name.BackColor = [Drawing.Color]::White
    $name.AutoEllipsis = $true
    $box = New-Object Windows.Forms.ComboBox
    $box.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    $box.Font = $script:FontUi
    $box.Tag = [string]$anchor.Id
    $box.DropDownWidth = 280
    $pick = 'recommended'
    if ($script:BudgetPicks.ContainsKey([string]$anchor.Id)) { $pick = [string]$script:BudgetPicks[[string]$anchor.Id] }
    $selected = 0
    $index = 0
    foreach ($row in (Get-BudgetFactorTable)) {
        [void]$box.Items.Add((Get-BudgetChoiceLabel -Anchor $anchor -PickId ([string]$row.Id)))
        if ($row.Id -eq $pick) { $selected = $index }
        $index++
    }
    $box.SelectedIndex = $selected
    $box.Add_SelectedIndexChanged({ Update-BudgetChoice })
    $script:OptionsCard.Controls.Add($name)
    $script:OptionsCard.Controls.Add($box)
    $script:BudgetLabels += $name
    $script:BudgetBoxes += $box
}
$script:BudgetLabels = @($script:BudgetLabels)
$script:BudgetBoxes = @($script:BudgetBoxes)
$script:OptionsCard.Controls.Add($script:BudgetTitle)
$script:OptionsCard.Add_Paint({
    $pen = New-Object Drawing.Pen $script:ColorLine
    $_.Graphics.DrawRectangle($pen, 0, 0, ($script:OptionsCard.Width - 1), ($script:OptionsCard.Height - 1))
    $pen.Dispose()
})
foreach ($chk in @($script:SubfoldersCheck, $script:AutoCheck, $script:DetailedCheck, $script:ShutdownCheck)) {
    $chk.Add_CheckedChanged({ if (-not $script:Loading) { Save-Settings } })
}

$script:ActionPanel = New-Object Windows.Forms.Panel
$script:ActionPanel.Dock = 'Fill'
$script:ActionPanel.BackColor = $script:ColorPage
$script:ActionPanel.Margin = New-Object Windows.Forms.Padding(0, 4, 0, 0)
$script:ScanButton = New-Button 'Scan' 'primary' 110 38
$script:ConvertButton = New-Button 'Convert' 'primary' 120 38
$script:CancelButton = New-Button 'Cancel' 'danger' 100 34
$script:CompareButton = New-Button 'Compare' 'secondary' 110 34
$script:UndoButton = New-Button 'Undo' 'secondary' 90 34
$script:DeleteButton = New-Button 'Delete originals' 'secondary' 150 34
$script:HelpButton = New-Button 'How this works' 'secondary' 148 34
$script:CancelButton.Enabled = $false
$script:ActionPanel.Controls.Add($script:ScanButton)
$script:ActionPanel.Controls.Add($script:ConvertButton)
$script:ActionPanel.Controls.Add($script:CancelButton)
$script:ActionPanel.Controls.Add($script:CompareButton)
$script:ActionPanel.Controls.Add($script:UndoButton)
$script:ActionPanel.Controls.Add($script:DeleteButton)
$script:ActionPanel.Controls.Add($script:HelpButton)
$script:ScanButton.Add_Click({ Start-Scan })
$script:ConvertButton.Add_Click({ Start-Convert })
$script:CancelButton.Add_Click({ Request-Cancel })
$script:CompareButton.Add_Click({ Show-Compare })
$script:UndoButton.Add_Click({ Start-UndoLast })
$script:DeleteButton.Add_Click({ Remove-CheckedOriginals })
$script:HelpButton.Add_Click({ Show-Help })

$activityLabel = New-Object Windows.Forms.Label
$activityLabel.Text = 'Activity'
$activityLabel.Font = $script:FontSection
$activityLabel.ForeColor = $script:ColorInk
$activityLabel.BackColor = $script:ColorPage
$activityLabel.Dock = 'Fill'
$activityLabel.TextAlign = 'BottomLeft'

$logHost = New-Object Windows.Forms.Panel
$logHost.Dock = 'Fill'
$logHost.BackColor = $script:ColorLogBg
$logHost.Padding = New-Object Windows.Forms.Padding(10, 8, 10, 8)
$logHost.Margin = New-Object Windows.Forms.Padding(0, 4, 0, 0)
$script:Log = New-Object Windows.Forms.RichTextBox
$script:Log.Dock = 'Fill'
$script:Log.BorderStyle = 'None'
$script:Log.ReadOnly = $true
$script:Log.BackColor = $script:ColorLogBg
$script:Log.ForeColor = $script:ColorLogText
$script:Log.Font = $script:FontLog
$script:Log.DetectUrls = $false
$script:Log.ScrollBars = 'Vertical'
$script:Log.WordWrap = $true
$script:Log.ShortcutsEnabled = $true
$logHost.Controls.Add($script:Log)
$logHost.Add_Paint({
    $pen = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(55, 65, 81))
    $_.Graphics.DrawRectangle($pen, 0, 0, ($this.Width - 1), ($this.Height - 1))
    $pen.Dispose()
})

[void]$table.Controls.Add($folderCaption, 0, 0)
[void]$table.Controls.Add($script:FolderCard, 0, 1)
[void]$table.Controls.Add($script:HintPanel, 0, 2)
[void]$table.Controls.Add($script:ListHeader, 0, 3)
[void]$table.Controls.Add($script:Files, 0, 4)
[void]$table.Controls.Add($script:OptionsCard, 0, 5)
[void]$table.Controls.Add($script:ActionPanel, 0, 6)
[void]$table.Controls.Add($activityLabel, 0, 7)
[void]$table.Controls.Add($logHost, 0, 8)

$script:Form.Controls.Add($table)
$script:Form.Controls.Add($script:StatusPanel)
$script:Form.Controls.Add($script:Header)

Set-Tip $script:FolderBox 'The folder Scan will look through. Drop a folder here, or click Browse. The choice is remembered.'
Set-Tip $script:SavingsLabel 'Current size minus the About column, for the checked files Convert will shrink. It changes as you check and uncheck rows.'
Set-Tip $script:BrowseButton 'Choose the folder to scan.'
Set-Tip $script:SubfoldersCheck 'Look inside folders within the chosen folder. Turn this off to scan only the files sitting directly in that folder.'
Set-Tip $script:AutoCheck 'After a new file checks out, delete the original. Leave this off to compare first and delete with the Delete originals button.'
Set-Tip $script:DetailedCheck "Show the encoder's own technical messages in the activity box."
Set-Tip $script:ShutdownCheck 'After Convert finishes, turn the computer off. A one-minute countdown lets you cancel. The computer stays on if you stop the convert. A scan does not turn it off.'
Set-Tip $script:BudgetTitle 'The size line for each picture. Recommended is where the program starts. Scan again after you change one.'
Update-BudgetTips
Set-Tip $script:ScanButton 'Read the videos in the folder and list the ones that are too big for their picture size.'
Set-Tip $script:ConvertButton 'Shrink every checked video that is bloated or failed earlier. The new file takes the original place.'
Set-Tip $script:CancelButton 'Stop the scan or the file that is converting. Esc does this too.'
Set-Tip $script:CompareButton 'Play the original and the new file side by side.'
Set-Tip $script:UndoButton 'Put the originals from the last conversion back, and delete the new files. The program asks first.'
Set-Tip $script:DeleteButton 'Delete the checked originals that are waiting in .vd-originals. The new files stay.'
Set-Tip $script:HelpButton 'Open a short guide to the size rule, comparing, and what each part of this folder is for.'
Set-Tip $script:FolderPick 'Folders that have bloated files. A show is listed with the folders inside it. Pick one to make a smaller convert job.'
Set-Tip $script:SelectFolderButton 'Check the bloated files in the folder shown here, and clear the other checks.'
Set-Tip $script:SelectAllButton 'Check every row.'
Set-Tip $script:SelectNoneButton 'Clear every check.'
Set-Tip $script:Files 'Bloated videos are checked. Right-click a row to select that folder. Double-click a file that is ready to delete to compare it.'
Set-Tip $script:Log 'Saved space, skipped videos, and problems are listed here.'
Set-Tip $script:ProgressTrack 'How far the current file has been encoded.'
Set-Tip $script:StatusLabel 'What the program is doing right now.'

if ($settings.Folder) { Set-FolderText $settings.Folder }
$script:Loading = $false

$script:Form.Add_KeyDown({
    if ($_.KeyCode -eq [Windows.Forms.Keys]::Escape -and $script:Work -ne 'idle') {
        $_.SuppressKeyPress = $true
        Request-Cancel
    }
})
$script:Form.Add_FormClosing({
    if ($script:SmokeTest) { return }
    if ($script:Work -ne 'idle') {
        $answer = [Windows.Forms.MessageBox]::Show($script:Form, 'Work is still running. Stop it and close?', 'Video Dehydrator', 'YesNo', 'Question')
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
            $_.Cancel = $true
            return
        }
        Request-Cancel
        $deadline = [DateTime]::UtcNow.AddSeconds(4)
        while ($script:Work -ne 'idle' -and [DateTime]::UtcNow -lt $deadline) {
            Invoke-UiTick
            [Threading.Thread]::Sleep(100)
        }
    }
    Stop-Playback
    Save-Settings
    Disable-KeepAwake
})
$script:Form.Add_FormClosed({
    Stop-Playback
    try { [VideoDehydrator.LinePump]::Stop() } catch {}
    if ($script:Timer) { $script:Timer.Stop(); $script:Timer.Dispose() }
    if ($script:PlayTimer) { $script:PlayTimer.Stop(); $script:PlayTimer.Dispose() }
    if ($script:HelpForm -and -not $script:HelpForm.IsDisposed) { $script:HelpForm.Close() }
    if ($script:CompareForm -and -not $script:CompareForm.IsDisposed) { $script:CompareForm.Close() }
    if ($script:Player) { $script:Player.Dispose() }
})
$script:Header.Add_Resize({ Update-ChromeLayout })
$script:StatusPanel.Add_Resize({ Update-ChromeLayout })
$script:ActionPanel.Add_Resize({ Layout-Actions })
$script:OptionsCard.Add_Resize({ Layout-Options })
$script:FolderCard.Add_Resize({ Layout-Folder })
$script:ListHeader.Add_Resize({ Layout-ListHeader })
$script:Files.Add_Resize({ Layout-FileColumns })
$script:Form.Add_Shown({
    Update-ChromeLayout
    if (-not $script:SmokeTest) {
        try {
            $script:Form.WindowState = [Windows.Forms.FormWindowState]::Normal
            $script:Form.Visible = $true
            [void][VideoDehydrator.Native]::ShowWindow($script:Form.Handle, 9)
            [void][VideoDehydrator.Native]::SetForegroundWindow($script:Form.Handle)
        } catch {
        }
    }
})
$script:Form.Add_DragEnter({
    if ($script:Work -ne 'idle') { $_.Effect = 'None'; return }
    if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = 'Copy' } else { $_.Effect = 'None' }
})
$script:Form.Add_DragDrop({ Add-DroppedFolder $_.Data })

$script:Timer = New-Object Windows.Forms.Timer
$script:Timer.Interval = 150
$script:Timer.Add_Tick({ Invoke-UiTick })
$script:Timer.Start()

$script:PlayTimer = New-Object Windows.Forms.Timer
$script:PlayTimer.Interval = 40
$script:PlayTimer.Add_Tick({
    if (-not $script:Playing) { return }
    Update-PlayFrame
    Start-CompareAudio
    Update-PlayChrome
})

Add-PendingRows
Write-Welcome
$waiting = @($script:Files.Items | Where-Object { [string]$_.Tag.Status -eq 'Ready to delete' })
if ($waiting.Count -gt 0) {
    $word = if ($waiting.Count -eq 1) { 'original is' } else { 'originals are' }
    Write-Activity "$($waiting.Count) $word still waiting to be deleted." 'text'
}
Warn-MissingTools
Update-Buttons
Set-Status 'Ready' 'idle'
Update-Shortcut
Update-ChromeLayout

function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}

function Save-FormImage($targetForm, [string]$path) {
    $bmp = New-Object Drawing.Bitmap $targetForm.Width, $targetForm.Height
    $targetForm.DrawToBitmap($bmp, (New-Object Drawing.Rectangle 0, 0, $targetForm.Width, $targetForm.Height))
    $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

function Invoke-PlayerCheck {
    $dir = Join-Path $env:TEMP ('vdh-player-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    try {
        $clip = Join-Path $dir 'clip.mp4'
        $made = Invoke-CapturedProcess -File $script:Ffmpeg -Arguments @(
            '-y', '-hide_banner', '-loglevel', 'error',
            '-f', 'lavfi', '-i', 'testsrc=size=320x180:rate=12:duration=1',
            '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-an', $clip
        )
        if ($made.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $clip)) { throw "Player sample failed. $($made.StdErr)" }
        $info = Get-CompareFrameInfo
        $arguments = Get-CompareArguments -Left $clip -Right $clip -StartSec 0
        $script:Player.Start($script:Ffmpeg, (ConvertTo-ArgumentLine $arguments), $info.Width, $info.Height, $info.Fps)
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while ($script:Player.FrameIndex -lt 1 -and [DateTime]::UtcNow -lt $deadline) {
            [Threading.Thread]::Sleep(20)
        }
        $frames = $script:Player.FrameIndex
        $errorText = $script:Player.Error
        if ($frames -lt 1) { throw "The player produced no frames. $errorText" }
        [Threading.Thread]::Sleep(500)
        $mid = $script:Player.FrameIndex
        $script:Player.Stop()
        if ($mid -lt 4 -or $mid -gt 9) { throw "Playback ran at the wrong speed. Frame $mid after 500 ms (12 fps)." }
    }
    finally {
        $script:Player.Stop()
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Add-SmokeFile([string]$Path) {
    $tag = @{
        Status = 'Bloated'
        Path = $Path
        Kept = ''
        New = ''
        Source = $Path
        Width = 1920
        Height = 1080
        DurationSec = 60
        SizeBytes = 100000000
        OldBytes = $null
        GiBph = 4
        BudgetGiBph = 2
        TargetKbps = 3000
        EstimateBytes = 20000000
        Codec = 'h264'
        PendingId = ''
        Reason = 'smoke'
    }
    Add-ResultRow $tag | Out-Null
}

function Invoke-FolderSelectCheck {
    $savedFolder = [string]$script:FolderBox.Text
    $script:Folder = 'C:\Library'
    $script:FolderBox.Text = 'C:\Library'
    Add-SmokeFile 'C:\Library\Show\Season 1\a.mkv'
    Add-SmokeFile 'C:\Library\Show\Season 1\b.mkv'
    Add-SmokeFile 'C:\Library\Show\Season 2\c.mkv'
    Add-SmokeFile 'C:\Library\Other\d.mkv'
    Update-BloatFolders
    $labels = @($script:FolderPick.Items | ForEach-Object { [string]$_ })
    Assert-True ($labels -contains 'Show  (3 files)') 'Show folder missing from the list'
    Assert-True ($labels -contains 'Show\Season 1  (2 files)') 'Season folder missing from the list'
    Assert-True ($labels -contains 'Other  (1 file)') 'Other folder missing from the list'
    Assert-True (($labels -notcontains 'Library  (4 files)') -and ($labels -notcontains 'C:\Library  (4 files)')) 'The scan folder itself was listed'
    $season = -1
    for ($i = 0; $i -lt $script:BloatFolderPaths.Count; $i++) {
        if ([string]$script:BloatFolderPaths[$i] -match 'Season 1$') { $season = $i }
    }
    Assert-True ($season -ge 0) 'Season 1 path was missing'
    $script:FolderPick.SelectedIndex = $season
    Select-ChosenFolder
    $checked = @($script:Files.Items | Where-Object { $_.Checked })
    Assert-True ($checked.Count -eq 2) ("Select folder checked $($checked.Count), expected 2")
    Assert-True ($script:SavingsLabel.Text -eq 'Estimated savings: 152.6 MiB') ("Savings after one folder was $($script:SavingsLabel.Text)")
    Set-AllChecks $false
    $checked = @($script:Files.Items | Where-Object { $_.Checked })
    Assert-True ($checked.Count -eq 0) 'Deselect all left a row checked'
    Assert-True ($script:SavingsLabel.Text -eq 'Estimated savings: 0 B') ("Savings after deselect was $($script:SavingsLabel.Text)")
    Set-AllChecks $true
    Assert-True ($script:Files.CheckedItems.Count -eq 4) 'Select all missed a row'
    Assert-True ($script:SavingsLabel.Text -eq 'Estimated savings: 305.2 MiB') ("Savings after select all was $($script:SavingsLabel.Text)")
    $script:Files.Items[0].Checked = $false
    Assert-True ($script:SavingsLabel.Text -eq 'Estimated savings: 228.9 MiB') ("Savings after one uncheck was $($script:SavingsLabel.Text)")
    $script:Files.Items[0].Checked = $true
    Update-ChromeLayout
    [Windows.Forms.Application]::DoEvents()
    Save-FormImage $script:Form (Join-Path $env:TEMP 'vdh-folders.png')
    $script:Files.Items.Clear()
    $script:Folder = $savedFolder
    $script:FolderBox.Text = $savedFolder
    Update-BloatFolders
}

function Set-BudgetBoxPick([string]$Id, [string]$PickId) {
    $box = Get-BudgetBox $Id
    if (-not $box) { throw "Missing budget list $Id" }
    $table = @(Get-BudgetFactorTable)
    for ($i = 0; $i -lt $table.Count; $i++) {
        if ($table[$i].Id -eq $PickId) {
            $box.SelectedIndex = $i
            return
        }
    }
    throw "Missing budget choice $PickId"
}

function Invoke-BudgetCheck {
    Assert-True (@($script:BudgetBoxes).Count -eq 4) 'Budget dropdowns missing'
    $expected = @{
        '2160' = 'Recommended, 8 GiB/h'
        '1080' = 'Recommended, 2 GiB/h'
        '720' = 'Recommended, 0.89 GiB/h'
        '480' = 'Recommended, 0.33 GiB/h'
    }
    foreach ($box in @($script:BudgetBoxes)) {
        $want = [string]$expected[[string]$box.Tag]
        Assert-True ($box.Text -eq $want) ("Budget for $($box.Tag) was $($box.Text)")
    }
    $tag = @{
        Status = 'Bloated'
        Path = 'C:\Library\clip.mkv'
        Kept = ''
        New = ''
        Source = 'C:\Library\clip.mkv'
        Width = 1920
        Height = 1080
        DurationSec = 3600
        SizeBytes = [int64]3GB
        OldBytes = $null
        GiBph = 3
        BudgetGiBph = 2
        TargetKbps = 3000
        EstimateBytes = $null
        Codec = 'h264'
        VideoBitrate = [int64]15000000
        PendingId = ''
        Reason = 'smoke budget'
    }
    $item = Add-ResultRow $tag
    Set-BudgetBoxPick '1080' 'half'
    Assert-True ([int]$item.Tag.TargetKbps -eq 1500) ("Half target was $($item.Tag.TargetKbps)")
    Assert-True ([math]::Abs([double]$item.Tag.BudgetGiBph - 1) -lt 0.001) ("Half budget was $($item.Tag.BudgetGiBph)")
    Set-BudgetBoxPick '1080' 'double'
    $still = @($script:Files.Items | Where-Object { [string]$_.Tag.Path -eq 'C:\Library\clip.mkv' })
    Assert-True ($still.Count -eq 0) 'Double budget kept a 3 GiB/h file'
    Set-BudgetBoxPick '1080' 'recommended'
    $script:Files.Items.Clear()
    Update-BloatFolders
}

function Invoke-SmokeTest {
    $missing = @(Get-MissingTools)
    Assert-True ($missing.Count -eq 0) ("Missing tools: " + ($missing -join ', '))
    Assert-True ($script:Log.Text -match 'Choose a folder') 'Startup text was missing'
    $fraction = Get-HandBrakeFraction 'Encoding: task 1 of 2, 50 %'
    Assert-True ([math]::Abs($fraction - 25) -lt 0.01) 'Progress parser'
    $script:Form.Show()
    Update-ChromeLayout
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 200
    [Windows.Forms.Application]::DoEvents()
    Invoke-FolderSelectCheck
    Invoke-BudgetCheck
    Save-FormImage $script:Form (Join-Path $env:TEMP 'vdh-main.png')
    Show-Help
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 200
    Save-FormImage $script:HelpForm (Join-Path $env:TEMP 'vdh-help.png')
    Assert-True ($script:HelpBox.Text -match '12000 kbps') 'The guide was missing the 4K rate'
    Assert-True ($script:HelpBox.Text -match '\.vd-originals') 'The guide was missing the holding folder'
    Assert-True ($script:HelpBox.Text -match 'Select folder') 'The guide was missing folder selection'
    Assert-True ($script:HelpBox.Text -match 'Estimated savings') 'The guide was missing the savings total'
    Assert-True ($script:HelpBox.Text -match 'starts on Recommended') 'The guide was missing the budget choices'
    Assert-True ($script:HelpBox.Text -match 'one-minute countdown') 'The guide was missing shutdown'
    Assert-True ($script:HelpBox.Text -match 'Undo puts back the last conversion') 'The guide was missing undo'
    Assert-True ($script:UndoButton.Text -eq 'Undo') 'Undo button was missing'
    $nestedPending = ,@(
        [pscustomobject]@{ id = 'a'; source = 's1'; kept = 'k1'; new = 'n1' },
        [pscustomobject]@{ id = 'b'; source = 's2'; kept = 'k2'; new = 'n2' }
    )
    $flatPending = @(Expand-PendingRows $nestedPending)
    Assert-True ($flatPending.Count -eq 2) 'Nested pending rows were not split'
    Assert-True ($flatPending[0].source -eq 's1' -and $flatPending[1].source -eq 's2') 'Nested pending rows changed order'
    $packedPending = Format-PendingJson $nestedPending
    Assert-True ($packedPending.StartsWith('[{')) 'Pending save wrapped the list twice'
    $readBack = @(Expand-PendingRows ($packedPending | ConvertFrom-Json))
    Assert-True ($readBack.Count -eq 2 -and $readBack[1].id -eq 'b') 'Saved pending did not read back as two rows'
    Update-Buttons
    Assert-True ($script:UndoButton.Enabled -eq (@(Get-UndoBatch).Count -gt 0)) 'Undo button did not follow the held originals'
    Assert-True (-not $script:ShutdownCheck.Checked) 'Shutdown started checked'
    Assert-True ($script:ShutdownCheck.Text -eq 'Shutdown computer upon completion') 'Shutdown label'
    $script:ShutdownRequested = $false
    $script:ShutdownCheck.Checked = $true
    Offer-Shutdown
    Assert-True (-not $script:ShutdownRequested) 'Smoke test scheduled a shutdown'
    $script:ShutdownCheck.Checked = $false
    if ($script:HelpForm) { $script:HelpForm.Close() }
    Invoke-PlayerCheck
    $script:Form.Close()
    Write-Output 'SMOKE OK'
}

try {
    if ($script:SmokeTest) {
        Invoke-SmokeTest
        exit 0
    }
    [void][System.Windows.Forms.Application]::Run($script:Form)
}
catch {
    $msg = $_.Exception.ToString()
    if ($script:SmokeTest) {
        Write-Output ("SMOKE FAIL: " + $msg)
        Write-Output $_.ScriptStackTrace
        exit 1
    }
    try {
        [Windows.Forms.MessageBox]::Show($msg, 'Video Dehydrator', 'OK', 'Error') | Out-Null
    } catch {
    }
    exit 1
}
