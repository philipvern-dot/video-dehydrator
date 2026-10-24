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
      try { started.PriorityClass = ProcessPriorityClass.BelowNormal; } catch {}
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

  public sealed class JobPump {
    readonly ConcurrentQueue<string> lines = new ConcurrentQueue<string>();
    public volatile bool Exited;
    public int Generation;
    public int ExitCode;
    Process process;

    public void Begin() {
      Generation++;
      string discard;
      while (lines.TryDequeue(out discard)) {}
      ExitCode = 0;
      Exited = false;
    }

    public void Accept(string line) {
      if (string.IsNullOrEmpty(line)) return;
      line = line.Trim().TrimEnd('\r');
      if (line.Length == 0) return;
      lines.Enqueue(line);
    }

    void ReadBrokenLines(StreamReader reader) {
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

    public void Start(string fileName, string arguments) {
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
      try { started.PriorityClass = ProcessPriorityClass.BelowNormal; } catch {}
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

    public void Kill() {
      try {
        if (process != null && !process.HasExited) process.Kill();
      } catch {}
    }

    public void Stop() {
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

    public string[] Drain() {
      List<string> batch = new List<string>();
      string line;
      while (lines.TryDequeue(out line)) {
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
$script:SkipPath = Join-Path $script:AppDir 'skipped.json'
$script:SkipRows = @()
$script:ConvertLogPath = Join-Path $script:AppDir 'convert-log.tsv'
$script:ConversionLogPath = Join-Path $script:AppDir 'conversion-log.md'
$script:UpdateRepo = 'video-dehydrator'
$script:UpdateAsset = 'video_dehydrator.exe'
$script:UpdateProduct = 'Video Dehydrator'
$script:UpdateFallback = '1.0.9.4'
$script:UpdateOffer = $null
$script:UpdatePrompt = ''
$script:UpdateClosing = $false

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('VideoDehydrator.HeaderDrag' -as [type])) {
    $formsRef = ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'System.Windows.Forms' } | Select-Object -First 1).Location
    $drawRef = ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'System.Drawing' } | Select-Object -First 1).Location
    Add-Type -ReferencedAssemblies @($formsRef, $drawRef) -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
namespace VideoDehydrator {
  public class HeaderDrag : NativeWindow {
    const int WM_LBUTTONDOWN = 0x0201;
    const int WM_MOUSEMOVE = 0x0200;
    const int WM_LBUTTONUP = 0x0202;
    const int LVM_GETHEADER = 0x101F;
    const int LVM_GETSUBITEMRECT = 0x1038;
    const int HDM_HITTEST = 0x1206;
    const int HDM_GETITEMRECT = 0x1207;
    const uint HHT_ONDIVIDER = 0x0004;
    const uint HHT_ONDIVOPEN = 0x0008;
    readonly ListView list;
    bool armed;
    bool dragged;
    int startX;
    int columnIndex;
    public event EventHandler Reordered;

    [StructLayout(LayoutKind.Sequential)]
    struct HDHITTESTINFO {
      public int x;
      public int y;
      public uint flags;
      public int iItem;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct RECT {
      public int left;
      public int top;
      public int right;
      public int bottom;
    }

    [DllImport("user32.dll")]
    static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool GetUpdateRect(IntPtr hWnd, IntPtr lpRect, bool bErase);

    public HeaderDrag(ListView list) { this.list = list; }

    public void Attach() {
      IntPtr header = SendMessage(list.Handle, LVM_GETHEADER, IntPtr.Zero, IntPtr.Zero);
      if (header == IntPtr.Zero || Handle == header) return;
      if (Handle != IntPtr.Zero) ReleaseHandle();
      AssignHandle(header);
    }

    public void InjectMouse(int msg, int x, int y) {
      long packed = ((long)y << 16) | (uint)(x & 0xFFFF);
      SendMessage(Handle, msg, (IntPtr)1, (IntPtr)packed);
    }

    public bool RowsNeedPaint() {
      return GetUpdateRect(list.Handle, IntPtr.Zero, false);
    }

    public int HeaderLeft(int index) {
      return ReadRectLeft(Handle, HDM_GETITEMRECT, (IntPtr)index, 0, 0);
    }

    public int CellLeft(int index) {
      // This Windows build reads left as LVIR_* and top as the subitem.
      int portion = index == 0 ? 2 : 0;
      return ReadRectLeft(list.Handle, LVM_GETSUBITEMRECT, IntPtr.Zero, portion, index);
    }

    int ReadRectLeft(IntPtr hwnd, int msg, IntPtr wParam, int left, int top) {
      RECT rect = new RECT();
      rect.left = left;
      rect.top = top;
      IntPtr ptr = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(RECT)));
      try {
        Marshal.StructureToPtr(rect, ptr, false);
        SendMessage(hwnd, msg, wParam, ptr);
        rect = (RECT)Marshal.PtrToStructure(ptr, typeof(RECT));
      } finally {
        Marshal.FreeHGlobal(ptr);
      }
      return rect.left;
    }

    static int XOf(IntPtr lParam) { return (short)(lParam.ToInt64() & 0xFFFF); }
    static int YOf(IntPtr lParam) { return (short)((lParam.ToInt64() >> 16) & 0xFFFF); }

    int Hit(int x, int y, out bool divider) {
      HDHITTESTINFO info = new HDHITTESTINFO();
      info.x = x;
      info.y = y;
      IntPtr ptr = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(HDHITTESTINFO)));
      try {
        Marshal.StructureToPtr(info, ptr, false);
        SendMessage(Handle, HDM_HITTEST, IntPtr.Zero, ptr);
        info = (HDHITTESTINFO)Marshal.PtrToStructure(ptr, typeof(HDHITTESTINFO));
      } finally {
        Marshal.FreeHGlobal(ptr);
      }
      divider = (info.flags & (HHT_ONDIVIDER | HHT_ONDIVOPEN)) != 0;
      return info.iItem;
    }

    protected override void WndProc(ref Message m) {
      if (m.Msg == WM_LBUTTONDOWN) {
        int x = XOf(m.LParam);
        bool divider;
        int index = Hit(x, YOf(m.LParam), out divider);
        armed = !divider && index >= 0 && index < list.Columns.Count;
        dragged = false;
        startX = x;
        columnIndex = index;
      } else if (m.Msg == WM_MOUSEMOVE && armed) {
        if (Math.Abs(XOf(m.LParam) - startX) >= 6) dragged = true;
      } else if (m.Msg == WM_LBUTTONUP && armed) {
        int x = XOf(m.LParam);
        bool move = dragged || Math.Abs(x - startX) >= 6;
        int from = columnIndex;
        armed = false;
        if (move) {
          bool divider;
          int target = Hit(x, YOf(m.LParam), out divider);
          if (!divider && target >= 0 && target < list.Columns.Count && target != from) {
            list.Columns[from].DisplayIndex = list.Columns[target].DisplayIndex;
            list.Invalidate();
            EventHandler handler = Reordered;
            if (handler != null) handler(this, EventArgs.Empty);
          }
        }
      }
      base.WndProc(ref m);
    }
  }
}
'@
}
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
$script:ColorOverSlightBack = [Drawing.Color]::FromArgb(220, 252, 231)
$script:ColorOverHeavyBack = [Drawing.Color]::FromArgb(254, 249, 195)
$script:ColorOverHeavyFore = [Drawing.Color]::FromArgb(133, 77, 14)
$script:ColorOverExtremeBack = [Drawing.Color]::FromArgb(254, 226, 226)
$script:BudgetMark = @{
    '2160' = @{ Mark = [Drawing.Color]::FromArgb(29, 78, 216); Back = [Drawing.Color]::FromArgb(219, 234, 254); Fore = [Drawing.Color]::FromArgb(30, 58, 138) }
    '1080' = @{ Mark = [Drawing.Color]::FromArgb(15, 118, 110); Back = [Drawing.Color]::FromArgb(204, 251, 241); Fore = [Drawing.Color]::FromArgb(17, 94, 89) }
    '720' = @{ Mark = [Drawing.Color]::FromArgb(109, 40, 217); Back = [Drawing.Color]::FromArgb(237, 233, 254); Fore = [Drawing.Color]::FromArgb(91, 33, 182) }
    '480' = @{ Mark = [Drawing.Color]::FromArgb(194, 65, 12); Back = [Drawing.Color]::FromArgb(255, 237, 213); Fore = [Drawing.Color]::FromArgb(154, 52, 18) }
}

$script:Work = 'idle'
$script:ForceEncode = $false
$script:PulseMarks = @('|', '/', '-', '\')
$script:PulseIndex = 0
$script:PulseWanted = $false
$script:PulseOn = $false
$script:PulseSlot = -1
$script:PulseStamp = [datetime]::MinValue
$script:Cancel = $false
$script:StopAfterFile = $false
$script:ToolsOk = $false
$script:Loading = $false
$script:ProgressValue = 0
$script:EtaRates8 = New-Object System.Collections.Generic.List[double]
$script:EtaRates10 = New-Object System.Collections.Generic.List[double]
$script:EtaLive8 = New-Object System.Collections.Generic.List[double]
$script:EtaLive10 = New-Object System.Collections.Generic.List[double]
$script:EtaRatios = New-Object System.Collections.Generic.List[double]
$script:EtaFileSamples = New-Object System.Collections.Generic.List[double]
$script:EtaBatchSamples = New-Object System.Collections.Generic.List[double]
$script:EtaShownAt = $null
$script:EtaShownKey = ''
$script:EtaPassStart = $null
$script:EtaPass1Sec = 0
$script:EtaTask = 0
$script:EtaProgress = $null
$script:EtaChecking = $false
$script:EtaRemembered = $false
$script:EtaTenBit = $false
$script:EtaPixels = 0
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

function Get-AppIconPath {
    $path = Join-Path $script:Root 'vd-icon.ico'
    if (Test-Path -LiteralPath $path) { return $path }
    return $null
}

function Get-AppIcon {
    try {
        $path = Get-AppIconPath
        if (-not $path) { return $null }
        return New-Object Drawing.Icon $path
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
    if (-not $script:Tips -or -not $control) { return }
    $script:Tips.SetToolTip($control, $text)
}

function Install-DisabledButtonTips($panel) {
    if (-not $panel) { return }
    $panel.Add_MouseMove({
        if (-not $script:Tips) { return }
        $pt = $this.PointToClient([Windows.Forms.Cursor]::Position)
        $hit = $null
        foreach ($child in @($this.Controls)) {
            if ($child -isnot [Windows.Forms.Button]) { continue }
            if ($child.Enabled) { continue }
            if (-not $child.Bounds.Contains($pt)) { continue }
            $hit = $child
            break
        }
        if ($hit) {
            $tip = [string]$script:Tips.GetToolTip($hit)
            if (-not $tip) { return }
            if ($script:DisabledTipButton -ne $hit) {
                if ($script:DisabledTipButton) { $script:Tips.Hide($script:DisabledTipButton) }
                $script:DisabledTipButton = $hit
                $script:Tips.Show($tip, $hit, 0, ($hit.Height + 2))
            }
            return
        }
        if ($script:DisabledTipButton) {
            $script:Tips.Hide($script:DisabledTipButton)
            $script:DisabledTipButton = $null
        }
    })
    $panel.Add_MouseLeave({
        if ($script:DisabledTipButton -and $script:Tips) {
            $script:Tips.Hide($script:DisabledTipButton)
            $script:DisabledTipButton = $null
        }
    })
}

function Get-UpdateNotice {
    if ($script:UpdateOffer -and $script:UpdateOffer.Newer -and $script:UpdateOffer.Message) {
        return [string]$script:UpdateOffer.Message
    }
    $prompt = [string]$script:UpdatePrompt
    if ([string]::IsNullOrWhiteSpace($prompt)) { return '' }
    $cmp = Compare-AppVersion $prompt (Get-AppVersion)
    if ($null -eq $cmp -or $cmp -le 0) { return '' }
    return ('Version ' + $prompt + ' is available.')
}

function Set-Status([string]$text, [string]$kind) {
    if ($null -eq $script:StatusLabel) { return }
    if ($kind -ne 'busy') {
        $notice = Get-UpdateNotice
        if ($notice) {
            if ($text -eq 'Ready' -or $text -eq $notice) {
                $text = $notice
                if ($kind -eq 'idle') { $kind = 'ok' }
            }
            elseif ($text -notmatch [regex]::Escape($notice)) {
                $trimmed = $text.Trim()
                if ($trimmed.EndsWith('.')) { $text = $trimmed + ' ' + $notice }
                else { $text = $trimmed + '. ' + $notice }
            }
        }
    }
    if ($script:StatusLabel.Text -eq $text -and $script:StatusKind -eq $kind) { return }
    $script:StatusKind = $kind
    $script:StatusLabel.Text = $text
    if ($kind -eq 'ok') { $script:StatusLabel.ForeColor = $script:ColorOkText }
    elseif ($kind -eq 'err') { $script:StatusLabel.ForeColor = $script:ColorErrText }
    elseif ($kind -eq 'busy') { $script:StatusLabel.ForeColor = $script:ColorInk }
    else { $script:StatusLabel.ForeColor = $script:ColorMuted }
}

function Set-BarFill($Track, $Fill, [double]$percent) {
    if ($null -eq $Track -or $null -eq $Fill) { return }
    if ($percent -lt 0) { $percent = 0 }
    if ($percent -gt 100) { $percent = 100 }
    $width = $Track.ClientSize.Width
    $span = [int][Math]::Round($width * ($percent / 100.0))
    if ($span -lt 0) { $span = 0 }
    if ($percent -gt 0 -and $span -lt 6 -and $width -gt 0) { $span = 6 }
    if ($span -gt $width) { $span = $width }
    if ($Fill.Width -eq $span -and $Fill.Height -eq $Track.ClientSize.Height) { return }
    $Fill.Width = $span
    $Fill.Height = $Track.ClientSize.Height
}

function Set-Progress([double]$percent) {
    if ($percent -lt 0) { $percent = 0 }
    if ($percent -gt 100) { $percent = 100 }
    $script:ProgressValue = $percent
    Set-BarFill $script:ProgressTrack $script:ProgressFill $percent
}

function Get-FindLimit {
    if (-not $script:FindBox -or $script:FindBox.SelectedIndex -lt 0) { return [int]$script:FindLimit }
    $text = [string]$script:FindBox.SelectedItem
    if ($text -eq 'All') { return 0 }
    $number = 0
    if (-not [int]::TryParse($text, [ref]$number)) { return 0 }
    if ($number -lt 0) { return 0 }
    return $number
}

function Get-JobTip {
    return "How many files encode at the same time. Each file uses about 8 cores.`r`n`r`n1 is right for most computers.`r`n2 needs about 16 cores, in two groups of 8.`r`n3 needs about 24 cores.`r`n4 needs about 32 cores.`r`n5 needs about 40 cores.`r`n6 needs about 48 cores.`r`n`r`nOn fewer cores the files share the processor and the batch does not finish sooner. On a laptop, leave this at 1 unless it is plugged in."
}

function Get-JobCount {
    $count = 1
    if ($script:JobBox -and $script:JobBox.SelectedIndex -ge 0) {
        $parsed = 0
        if ([int]::TryParse([string]$script:JobBox.SelectedItem, [ref]$parsed)) { $count = $parsed }
    }
    elseif ($null -ne $script:JobCount) { $count = [int]$script:JobCount }
    if ($count -lt 1) { $count = 1 }
    if ($count -gt 6) { $count = 6 }
    return $count
}

function Get-OpenLane {
    if (-not $script:Lanes) { return $null }
    $limit = Get-JobCount
    $lanes = @($script:Lanes)
    for ($i = 0; $i -lt $limit -and $i -lt $lanes.Count; $i++) {
        if (-not $lanes[$i].Item) { return $lanes[$i] }
    }
    return $null
}

function Test-ProgressPaintDue {
    if ($null -eq $script:ProgressPaintAt) { return $true }
    return (([datetime]::UtcNow - $script:ProgressPaintAt).TotalMilliseconds -ge 500)
}

function Set-JobBar($Row, [string]$Name, [double]$Percent, [string]$PassName) {
    if ($null -eq $Row) { return }
    $label = [string]$Name
    if ([string]::IsNullOrWhiteSpace($label)) { $label = 'File' }
    $pct = [int][Math]::Round($Percent)
    if ($pct -lt 0) { $pct = 0 }
    if ($pct -gt 100) { $pct = 100 }
    $text = $label + '   ' + $pct + '%'
    if ($PassName) { $text = $text + '   ' + $PassName }
    $Row.Label.Text = $text
    Set-BarFill $Row.Track $Row.Fill $Percent
}

function Test-LogPinned {
    $box = $script:Log
    if ($null -eq $box -or $box.TextLength -le 1) { return $true }
    $last = $box.GetPositionFromCharIndex($box.TextLength - 1)
    return ($last.Y -le ($box.ClientSize.Height + 8))
}

function Remove-ActivityPulse {
    if (-not $script:PulseOn) { return }
    $box = $script:Log
    if ($box -and -not $box.IsDisposed -and $script:PulseSlot -ge 0 -and $script:PulseSlot -le $box.TextLength) {
        [VideoDehydrator.QuietLog]::SelectRange($box.Handle, $script:PulseSlot, $box.TextLength)
        [VideoDehydrator.QuietLog]::Insert($box.Handle, '')
    }
    $script:PulseOn = $false
    $script:PulseSlot = -1
}

function Add-ActivityPulse {
    if (-not $script:PulseWanted) { return }
    $box = $script:Log
    if ($null -eq $box -or $box.IsDisposed) { return }
    $mark = $script:PulseMarks[$script:PulseIndex]
    $line = 'Working  ' + $mark + [Environment]::NewLine
    $follow = Test-LogPinned
    if ($script:PulseOn -and $script:PulseSlot -ge 0 -and $script:PulseSlot -le $box.TextLength) {
        [VideoDehydrator.QuietLog]::SelectRange($box.Handle, $script:PulseSlot, $box.TextLength)
    }
    else {
        $script:PulseSlot = $box.TextLength
        [VideoDehydrator.QuietLog]::SelectRange($box.Handle, $box.TextLength, $box.TextLength)
        $script:PulseOn = $true
    }
    $box.SelectionColor = $script:ColorLogMuted
    [VideoDehydrator.QuietLog]::Insert($box.Handle, $line)
    if ($follow) { [VideoDehydrator.QuietLog]::ScrollToEnd($box.Handle) }
}

function Start-ActivityPulse {
    Stop-ActivityPulse
    $script:PulseWanted = $true
    $script:PulseIndex = 0
    $script:PulseStamp = [datetime]::UtcNow
    Add-ActivityPulse
}

function Stop-ActivityPulse {
    $script:PulseWanted = $false
    Remove-ActivityPulse
}

function Update-ActivityPulse {
    if (-not $script:PulseWanted) { return }
    $now = [datetime]::UtcNow
    if ($script:PulseOn -and ($now - $script:PulseStamp).TotalMilliseconds -lt 320) { return }
    $script:PulseStamp = $now
    if ($script:PulseOn) { $script:PulseIndex = ($script:PulseIndex + 1) % 4 }
    Add-ActivityPulse
}

function Write-Activity([string]$message, [string]$kind) {
    $box = $script:Log
    if ($null -eq $box -or $box.IsDisposed) { return }
    $restorePulse = [bool]$script:PulseWanted
    Remove-ActivityPulse
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
    if ($restorePulse) {
        $script:PulseWanted = $true
        Add-ActivityPulse
    }
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
        $iconPath = Get-AppIconPath
        if ($iconPath) { $lnk.IconLocation = $iconPath + ',0' }
        $lnk.Save()
    } catch {
    }
}

function Load-Settings {
    $defaults = @{
        Folder = ''
        IncludeSubfolders = $true
        AutoDelete = $false
        AutoWarnAccepted = $false
        AutoAsk = $true
        ReencodeAudio = $false
        Detailed = $false
        Budgets = ''
        Shutdown = $false
        PurgeRecycle = $false
        RecycleAlertMuted = $false
        UpdatePrompt = ''
        DeleteConfirmVersion = ''
        ColumnOrder = @()
        ListExtra = 0
        LogExtra = 0
        ParallelJobs = $false
        JobCount = 1
        FindLimit = 0
    }
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) { return $defaults }
    try {
        $json = Get-Content -Raw -LiteralPath $script:SettingsPath -Encoding UTF8 | ConvertFrom-Json
        if ($json.folder) { $defaults.Folder = [string]$json.folder }
        if ($null -ne $json.includeSubfolders) { $defaults.IncludeSubfolders = [bool]$json.includeSubfolders }
        if ($null -ne $json.autoDelete) { $defaults.AutoDelete = [bool]$json.autoDelete }
        if ($null -ne $json.autoWarnAccepted) { $defaults.AutoWarnAccepted = [bool]$json.autoWarnAccepted }
        if ($null -ne $json.autoAsk) { $defaults.AutoAsk = [bool]$json.autoAsk }
        if ($null -ne $json.reencodeAudio) { $defaults.ReencodeAudio = [bool]$json.reencodeAudio }
        if ($null -ne $json.detailed) { $defaults.Detailed = [bool]$json.detailed }
        if ($json.budgets) { $defaults.Budgets = [string]$json.budgets }
        if ($null -ne $json.shutdown) { $defaults.Shutdown = [bool]$json.shutdown }
        if ($null -ne $json.purgeRecycle) { $defaults.PurgeRecycle = [bool]$json.purgeRecycle }
        if ($null -ne $json.recycleAlertMuted) { $defaults.RecycleAlertMuted = [bool]$json.recycleAlertMuted }
        if ($json.updatePrompt) { $defaults.UpdatePrompt = [string]$json.updatePrompt }
        if ($json.deleteConfirmVersion) { $defaults.DeleteConfirmVersion = [string]$json.deleteConfirmVersion }
        if ($json.columnOrder) {
            $names = @($json.columnOrder | ForEach-Object {
                $name = [string]$_
                if ($name -eq 'Over') { 'Ratio' } else { $name }
            })
            if ($names -notcontains '~Savings') {
                $inserted = @()
                $placed = $false
                foreach ($name in $names) {
                    if ($name -eq 'Space Saved' -and -not $placed) {
                        $inserted += '~Savings'
                        $placed = $true
                    }
                    $inserted += $name
                }
                if (-not $placed) { $inserted += '~Savings' }
                $names = $inserted
            }
            $defaults.ColumnOrder = $names
        }
        if ($null -ne $json.parallelJobs) { $defaults.ParallelJobs = [bool]$json.parallelJobs }
        if ($null -ne $json.jobCount) {
            $rawJobs = [string]$json.jobCount
            if ($rawJobs -match '^\d+$') {
                $jobCount = [int]$rawJobs
                if ($jobCount -ge 1 -and $jobCount -le 6) { $defaults.JobCount = $jobCount }
            }
        }
        elseif ($defaults.ParallelJobs) { $defaults.JobCount = 2 }
        if ($null -ne $json.findLimit) {
            $rawFind = [string]$json.findLimit
            if ($rawFind -match '^\d+$') {
                $findLimit = [int]$rawFind
                if (@(0, 5, 10, 25, 50, 100) -contains $findLimit) { $defaults.FindLimit = $findLimit }
            }
        }
        if ($null -ne $json.logExtra) {
            $rawLog = [string]$json.logExtra
            if ($rawLog -match '^-?\d+$') {
                $logExtra = [int]$rawLog
                if ($logExtra -gt 800) { $logExtra = 800 }
                if ($logExtra -lt -400) { $logExtra = -400 }
                $defaults.LogExtra = $logExtra
            }
        }
        if ($null -ne $json.listExtra) {
            $rawExtra = [string]$json.listExtra
            if ($rawExtra -match '^-?\d+$') {
                $extra = [int]$rawExtra
                if ($extra -gt 800) { $extra = 800 }
                if ($extra -lt -400) { $extra = -400 }
                $defaults.ListExtra = $extra
            }
        }
    } catch {
    }
    return $defaults
}

function Sync-RecyclePurge {
    $on = $false
    if ($script:RecycleCheck) { $on = [bool]$script:RecycleCheck.Checked }
    $script:RecyclePurgeEnabled = $on
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
        autoWarnAccepted = [bool]$script:AutoWarnAccepted
        autoAsk = [bool]$script:AutoAsk
        reencodeAudio = [bool]$script:ReencodeCheck.Checked
        detailed = [bool]$script:DetailedCheck.Checked
        budgets = (Get-SelectedBudgetPack)
        shutdown = [bool]$script:ShutdownCheck.Checked
        purgeRecycle = $(if ($script:RecycleCheck) { [bool]$script:RecycleCheck.Checked } else { [bool]$script:RecyclePurgeEnabled })
        recycleAlertMuted = [bool]$script:RecycleAlertMuted
        updatePrompt = [string]$script:UpdatePrompt
        deleteConfirmVersion = [string]$script:DeleteConfirmVersion
        columnOrder = @($script:ColumnOrder)
        listExtra = [int]$script:ListExtra
        logExtra = [int]$script:LogExtra
        jobCount = (Get-JobCount)
        parallelJobs = ((Get-JobCount) -gt 1)
        findLimit = (Get-FindLimit)
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

function Read-SkipFile {
    if (-not (Test-Path -LiteralPath $script:SkipPath)) { return @() }
    try { return @(Convert-SkipRows ([IO.File]::ReadAllText($script:SkipPath))) } catch { return @() }
}

function Write-SkipFile {
    $json = Format-SkipJson $script:SkipRows
    if (-not $json) {
        if (Test-Path -LiteralPath $script:SkipPath) { Remove-Item -LiteralPath $script:SkipPath -Force }
        return
    }
    $utf8 = New-Object System.Text.UTF8Encoding $true
    [IO.File]::WriteAllText($script:SkipPath, $json, $utf8)
}

function Remember-SizeSkip {
    param(
        [string]$Path,
        [int64]$SizeBytes,
        [int]$TargetKbps
    )
    if (-not $Path -or $SizeBytes -le 0 -or $TargetKbps -le 0) { return }
    $script:SkipRows = @(Merge-SkipRow -Rows $script:SkipRows -Path $Path -SizeBytes $SizeBytes -TargetKbps $TargetKbps)
    Write-SkipFile
    Update-Buttons
}

function Forget-SizeSkipPath([string]$Path) {
    if (-not $Path) { return }
    $before = Format-SkipJson $script:SkipRows
    $script:SkipRows = @(Remove-SkipRow -Rows $script:SkipRows -Path $Path)
    if ((Format-SkipJson $script:SkipRows) -ne $before) { Write-SkipFile }
}

function Clear-RememberedSkips {
    if ($script:Work -ne 'idle') { return }
    $count = @($script:SkipRows | Where-Object { $_ }).Count
    if ($count -lt 1) { return }
    $word = if ($count -eq 1) { 'file' } else { 'files' }
    $answer = [Windows.Forms.MessageBox]::Show($script:Form, "Forget $count $word that were skipped because the new copy was larger?`r`n`r`nThe next scan can list them again.", 'Video Dehydrator', 'OKCancel', 'Question')
    if ($answer -ne [Windows.Forms.DialogResult]::OK) { return }
    $script:SkipRows = @()
    Write-SkipFile
    $word = if ($count -eq 1) { 'file' } else { 'files' }
    Write-Activity "Forgot $count skipped $word. Scan again to list them." 'text'
    Update-Buttons
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
    try { Write-ConversionLog } catch { }
}

function Escape-LogCell([string]$Text) {
    $value = ([string]$Text) -replace '[\r\n]+', ' '
    $value = $value -replace '\|', '\|'
    return $value.Trim()
}

function Get-LogResultText([string]$Status, [string]$Reason) {
    $name = switch ($Status) {
        'REPLACED' { 'Replaced the original' }
        'KEPT' { 'Kept the original' }
        'UNDONE' { 'Undone' }
        'FAIL' { 'Failed' }
        'SKIP' { 'Skipped' }
        default { $Status }
    }
    $note = ([string]$Reason).Trim()
    if ($note -and $note -ne 'ok') {
        if ($note.Length -gt 120) { $note = $note.Substring(0, 117) + '...' }
        return "$name. $note"
    }
    return $name
}

function Format-ConversionLogMarkdown($Rows) {
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine('# Video Dehydrator conversions')
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine('Each conversion is listed under the day and time it finished. Updating the program keeps this file.')
    [void]$builder.AppendLine('')
    # @() around a generic List throws "Argument types do not match" in Windows PowerShell 5.1.
    $items = New-Object System.Collections.ArrayList
    if ($null -eq $Rows) { }
    elseif (($Rows -is [System.Collections.IEnumerable]) -and -not ($Rows -is [string])) {
        foreach ($row in $Rows) { if ($null -ne $row) { [void]$items.Add($row) } }
    }
    else { [void]$items.Add($Rows) }
    if ($items.Count -eq 0) {
        [void]$builder.AppendLine('No conversions are recorded yet.')
        [void]$builder.AppendLine('')
        return $builder.ToString()
    }
    $ordered = foreach ($row in $items) {
        $when = [datetime]::MinValue
        $text = [string]$row.Timestamp
        if (-not [datetime]::TryParse($text, [ref]$when)) { $when = [datetime]::MinValue }
        [pscustomobject]@{ When = $when; Row = $row }
    }
    $ordered = @($ordered | Sort-Object When, { $_.Row.Source })
    $day = ''
    $minute = ''
    foreach ($item in $ordered) {
        $nextDay = $item.When.ToString('MMMM d, yyyy')
        $nextMinute = $item.When.ToString('h:mm tt')
        if ($nextDay -ne $day) {
            if ($day) { [void]$builder.AppendLine('') }
            [void]$builder.AppendLine("## $nextDay")
            [void]$builder.AppendLine('')
            $day = $nextDay
            $minute = ''
        }
        if ($nextMinute -ne $minute) {
            [void]$builder.AppendLine("### $nextMinute")
            [void]$builder.AppendLine('')
            [void]$builder.AppendLine('| File | Result | Size | Picture | Rate |')
            [void]$builder.AppendLine('| --- | --- | --- | --- | --- |')
            $minute = $nextMinute
        }
        $row = $item.Row
        $file = Escape-LogCell ([string]$row.Source)
        if (-not $file) { $file = 'Unknown file' }
        $result = Escape-LogCell (Get-LogResultText $row.Status $row.Reason)
        $size = ''
        if ($row.OldGiB -and $row.NewGiB) { $size = "$($row.OldGiB) GiB to $($row.NewGiB) GiB" }
        elseif ($row.OldGiB) { $size = "$($row.OldGiB) GiB" }
        $picture = ''
        if ($row.Width -and $row.Height) { $picture = "$($row.Width) x $($row.Height)" }
        $rate = ''
        if ($row.Kbps) { $rate = "$($row.Kbps) kbps" }
        elseif ($row.OldGiBph -and $row.NewGiBph) { $rate = "$($row.OldGiBph) to $($row.NewGiBph) GiB/h" }
        [void]$builder.AppendLine("| ``$file`` | $result | $(Escape-LogCell $size) | $(Escape-LogCell $picture) | $(Escape-LogCell $rate) |")
    }
    [void]$builder.AppendLine('')
    return $builder.ToString()
}

function Read-ConvertLogRows {
    if (-not (Test-Path -LiteralPath $script:ConvertLogPath)) { return @() }
    $lines = @(Get-Content -LiteralPath $script:ConvertLogPath -Encoding UTF8)
    if ($lines.Count -lt 2) { return @() }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($line in ($lines | Select-Object -Skip 1)) {
        if (-not $line) { continue }
        $part = $line -split "`t", -1
        while ($part.Count -lt 13) { $part += '' }
        $rows.Add([pscustomobject]@{
            Timestamp = $part[0]; Status = $part[1]; Reason = $part[2]; Source = $part[3]
            New = $part[4]; Kept = $part[5]; OldGiB = $part[6]; NewGiB = $part[7]
            OldGiBph = $part[8]; NewGiBph = $part[9]; Width = $part[10]; Height = $part[11]; Kbps = $part[12]
        })
    }
    return $rows.ToArray()
}

function Write-ConversionLog {
    $text = Format-ConversionLogMarkdown (Read-ConvertLogRows)
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($script:ConversionLogPath, $text, $utf8)
}

function Open-ConversionLog {
    try { Write-ConversionLog } catch { }
    $path = $script:ConversionLogPath
    if (-not (Test-Path -LiteralPath $path)) {
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($path, "# Video Dehydrator conversions`r`n`r`nNo conversions are recorded yet.`r`n", $utf8)
    }
    try {
        Start-Process -FilePath $path
    } catch {
        Start-Process -FilePath notepad.exe -ArgumentList $path
    }
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
        6 { return (Format-OverRatio (Get-OverRatio $tag.GiBph $tag.BudgetGiBph)) }
        7 {
            if ($tag.TargetKbps) { return "$($tag.TargetKbps) kbps" }
            return ''
        }
        8 {
            if ($tag.EstimateBytes) {
                $text = Format-ByteSize ([int64]$tag.EstimateBytes)
                if ($tag.EstimateRough) { return ('~' + $text) }
                return $text
            }
            return ''
        }
        9 { return [string]$tag.Status }
        10 {
            $saved = Get-SpaceSavedBytes $tag
            if ($null -eq $saved) { return '' }
            return (Format-ByteSize ([int64]$saved))
        }
        11 {
            $guess = Get-EstimatedSavingsBytes $tag
            if ($null -eq $guess) { return '' }
            $text = Format-ByteSize ([int64]$guess)
            if ($tag.EstimateRough) { return ('~' + $text) }
            return $text
        }
        default { return [string]$tag.Status }
    }
}

function Get-EstimatedSavingsBytes($tag) {
    if ($null -eq $tag) { return $null }
    if ($null -ne $tag.OldBytes -and [string]$tag.OldBytes -ne '') { return $null }
    if ($null -eq $tag.SizeBytes -or [string]$tag.SizeBytes -eq '') { return $null }
    if ($null -eq $tag.EstimateBytes -or [string]$tag.EstimateBytes -eq '') { return $null }
    $size = [int64]$tag.SizeBytes
    $estimate = [int64]$tag.EstimateBytes
    if ($size -le 0 -or $estimate -le 0 -or $estimate -ge $size) { return $null }
    return ($size - $estimate)
}

function Get-SpaceSavedBytes($tag) {
    if ($null -eq $tag) { return $null }
    if ($null -eq $tag.OldBytes -or [string]$tag.OldBytes -eq '') { return $null }
    if ($null -eq $tag.SizeBytes -or [string]$tag.SizeBytes -eq '') { return $null }
    $old = [int64]$tag.OldBytes
    $new = [int64]$tag.SizeBytes
    if ($old -le 0 -or $new -le 0 -or $old -le $new) { return $null }
    return ($old - $new)
}

function Get-OverBands {
    return @(
        @{ Id = 'slight'; Label = 'Slight'; Phrase = 'slightly over budget' },
        @{ Id = 'heavy'; Label = 'Heavy'; Phrase = 'heavily over budget' },
        @{ Id = 'extreme'; Label = 'Extreme'; Phrase = 'extremely over budget' }
    )
}

function Get-OverBand($id) {
    foreach ($band in @(Get-OverBands)) {
        if ($band.Id -eq [string]$id) { return $band }
    }
    return $null
}

function Get-RowOverBand($tag) {
    if ($null -eq $tag) { return '' }
    $status = [string]$tag.Status
    if ($status -ne 'Bloated' -and $status -ne 'Failed') { return '' }
    return (Get-OverBandId (Get-OverRatio $tag.GiBph $tag.BudgetGiBph))
}

function Get-ShowCriteria($tag) {
    $found = New-Object System.Collections.Generic.List[string]
    if ($null -eq $tag) { return @() }
    $status = [string]$tag.Status
    $band = ''
    if ($status -eq 'Bloated' -or $status -eq 'Failed') {
        $band = [string](Get-OverBandId (Get-OverRatio $tag.GiBph $tag.BudgetGiBph))
    }
    if ($status -eq 'Can shrink') { [void]$found.Add('shrink') }
    if ($status -eq 'Bloated') { [void]$found.Add('bloated') }
    if ($band -eq 'slight') { [void]$found.Add('slight') }
    if ($band -eq 'heavy') { [void]$found.Add('heavy') }
    if ($band -eq 'extreme') { [void]$found.Add('extreme') }
    if ($status -eq 'Failed') { [void]$found.Add('failed') }
    if ($status -eq 'Skipped') { [void]$found.Add('skipped') }
    if ($status -eq 'Ready to delete') { [void]$found.Add('ready') }
    if ($found.Count -eq 0) { [void]$found.Add('finished') }
    return @($found)
}

function Test-ShowFilterActive {
    if (-not $script:ShowFilters) { return $false }
    foreach ($id in @($script:ShowFilters.Keys)) {
        if ($script:ShowFilters[$id]) { return $true }
    }
    return $false
}

function Test-RowShown($tag) {
    if ($tag -and [string]$tag.Status -eq 'Forced') { return $true }
    if (-not (Test-ShowFilterActive)) { return $true }
    foreach ($id in @(Get-ShowCriteria $tag)) {
        if ($script:ShowFilters.ContainsKey($id) -and $script:ShowFilters[$id]) { return $true }
    }
    return $false
}

function Get-EveryFileItem {
    $all = New-Object System.Collections.ArrayList
    if ($script:Files) {
        foreach ($item in @($script:Files.Items)) { [void]$all.Add($item) }
    }
    if ($script:HiddenItems) {
        foreach ($item in @($script:HiddenItems.ToArray())) { [void]$all.Add($item) }
    }
    if ($all.Count -eq 0) { return @() }
    return @($all.ToArray())
}

function Get-ShowFilterNames {
    $names = New-Object System.Collections.Generic.List[string]
    if (-not $script:ShowOrder -or -not $script:ShowBoxes) { return @() }
    foreach ($id in @($script:ShowOrder)) {
        $box = $script:ShowBoxes[$id]
        if ($box -and $box.Checked) { [void]$names.Add([string]$box.Text) }
    }
    return @($names)
}

function Update-ShowButton {
    if (-not $script:ShowButton) { return }
    $names = @(Get-ShowFilterNames)
    if ($names.Count -eq 0) { $script:ShowButton.Text = 'Showing all' }
    else { $script:ShowButton.Text = 'Showing ' + ($names -join ', ') }
}

function Apply-ShowFilter {
    if ($script:FilterBusy -or -not $script:Files) { return }
    $script:FilterDepth = [int]$script:FilterDepth + 1
    if ($script:FilterDepth -gt 8) { throw 'Show filter reentered.' }
    $script:FilterBusy = $true
    $all = @(Get-EveryFileItem)
    $script:Files.BeginUpdate()
    try {
        $script:BulkCheck = $true
        $script:Files.Items.Clear()
        $script:HiddenItems = New-Object System.Collections.ArrayList
        foreach ($item in $all) {
            if (Test-RowShown $item.Tag) {
                [void]$script:Files.Items.Add($item)
            }
            else {
                $item.Checked = $false
                [void]$script:HiddenItems.Add($item)
            }
        }
        $script:BulkCheck = $false
    }
    finally {
        $script:Files.EndUpdate()
        $script:FilterBusy = $false
        $script:FilterDepth = [int]$script:FilterDepth - 1
    }
    Update-ShowButton
    if ($script:Work -eq 'idle') {
        Update-BloatFolders
        Update-Buttons
    }
}

function Select-ShownFiles {
    if ($script:Work -ne 'idle') { return }
    $checked = 0
    $script:BulkCheck = $true
    try {
        $script:Files.BeginUpdate()
        foreach ($item in @(Get-EveryFileItem)) {
            $status = [string]$item.Tag.Status
            $convertible = ($status -eq 'Bloated' -or $status -eq 'Can shrink' -or $status -eq 'Failed' -or $status -eq 'Skipped')
            $show = (Test-RowShown $item.Tag)
            $item.Checked = ($convertible -and $show)
            if ($item.Checked) { $checked++ }
        }
    }
    finally {
        $script:Files.EndUpdate()
        $script:BulkCheck = $false
    }
    Update-Buttons
    $word = if ($checked -eq 1) { 'file' } else { 'files' }
    Write-Activity "Checked $checked shown $word. Hidden files stay unchecked." 'text'
}

function Get-BudgetMark([string]$Id) {
    if (-not $Id -or -not $script:BudgetMark -or -not $script:BudgetMark.ContainsKey($Id)) { return $null }
    return $script:BudgetMark[$Id]
}

function Get-RowBudgetAnchor($tag) {
    if ($null -eq $tag) { return $null }
    $width = 0
    $height = 0
    [void][int]::TryParse([string]$tag.Width, [ref]$width)
    [void][int]::TryParse([string]$tag.Height, [ref]$height)
    if ($width -le 0 -or $height -le 0) { return $null }
    return (Get-NearestBudgetAnchor -Width $width -Height $height)
}

function Update-BudgetCell($item) {
    if ($null -eq $item -or $item.SubItems.Count -le 1) { return }
    $cell = $item.SubItems[1]
    $mark = $null
    $anchor = Get-RowBudgetAnchor $item.Tag
    if ($anchor) { $mark = Get-BudgetMark ([string]$anchor.Id) }
    if ($mark) {
        $cell.BackColor = $mark.Back
        $cell.ForeColor = $mark.Fore
    } else {
        $cell.ForeColor = $script:ColorInk
        $cell.BackColor = [Drawing.Color]::White
    }
}

function Update-OverCell($item) {
    if ($null -eq $item -or $item.SubItems.Count -le 6) { return }
    $cell = $item.SubItems[6]
    $bandId = Get-RowOverBand $item.Tag
    if ($bandId -eq 'slight') {
        $cell.ForeColor = $script:ColorOkText
        $cell.BackColor = $script:ColorOverSlightBack
    } elseif ($bandId -eq 'heavy') {
        $cell.ForeColor = $script:ColorOverHeavyFore
        $cell.BackColor = $script:ColorOverHeavyBack
    } elseif ($bandId -eq 'extreme') {
        $cell.ForeColor = $script:ColorDanger
        $cell.BackColor = $script:ColorOverExtremeBack
    } else {
        $cell.ForeColor = $script:ColorInk
        $cell.BackColor = [Drawing.Color]::White
    }
}

function Update-ResultRow($item) {
    if ($null -eq $item) { return }
    $tag = $item.Tag
    $item.Text = Get-RowText $tag 0
    for ($i = 1; $i -le 11; $i++) { $item.SubItems[$i].Text = Get-RowText $tag $i }
    Update-OverCell $item
    Update-BudgetCell $item
    $tip = [string]$tag.Path
    if ($tag.Reason) { $tip = $tip + "`r`n" + [string]$tag.Reason }
    $bandId = Get-RowOverBand $tag
    if ($bandId) {
        $band = Get-OverBand $bandId
        $tip = $tip + "`r`n" + (Get-RowText $tag 6) + ' the budget (' + $band.Label + ').'
    }
    $anchor = Get-RowBudgetAnchor $tag
    if ($anchor) { $tip = $tip + "`r`n" + 'Follows the ' + $anchor.Name + ' budget.' }
    if ($tag.EstimateRough) { $tip = $tip + "`r`n" + 'New size is a guess.' }
    if ($null -ne (Get-EstimatedSavingsBytes $tag)) { $tip = $tip + "`r`n" + '~Savings is current size minus New size.' }
    if ($null -ne (Get-SpaceSavedBytes $tag)) { $tip = $tip + "`r`n" + 'Space saved is the original minus the new file.' }
    $item.ToolTipText = $tip
}

function Add-ResultRow($tag) {
    $item = New-Object Windows.Forms.ListViewItem (Get-RowText $tag 0)
    $item.UseItemStyleForSubItems = $false
    for ($i = 1; $i -le 11; $i++) { [void]$item.SubItems.Add((Get-RowText $tag $i)) }
    $item.Tag = $tag
    $item.Checked = ($tag.Status -eq 'Bloated' -or $tag.Status -eq 'Can shrink' -or $tag.Status -eq 'Failed' -or $tag.Status -eq 'Ready to delete' -or $tag.Status -eq 'Forced')
    if (-not (Test-RowShown $tag)) {
        $item.Checked = $false
        if (-not $script:HiddenItems) { $script:HiddenItems = New-Object System.Collections.ArrayList }
        [void]$script:HiddenItems.Add($item)
    }
    else {
        [void]$script:Files.Items.Add($item)
    }
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

function Test-ScanRows {
    if (-not $script:Files) { return $false }
    foreach ($item in @(Get-EveryFileItem)) {
        if ($item.Tag -and -not $item.Tag.PendingId) { return $true }
    }
    return $false
}

function Clear-ListedFiles {
    if ($script:Work -ne 'idle') { return }
    if (-not (Test-ScanRows)) { return }
    Clear-ScanRows
    Update-Buttons
    Write-Activity 'Cleared the scanned files. Files still waiting in .vd-originals stay.' 'text'
}

function Clear-ScanRows {
    $keep = @()
    foreach ($item in @(Get-EveryFileItem)) {
        if ($item.Tag.PendingId) { $keep += $item.Tag }
    }
    $script:Files.Items.Clear()
    if ($script:HiddenItems) { $script:HiddenItems.Clear() }
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
        if ($status -ne 'Bloated' -and $status -ne 'Can shrink' -and $status -ne 'Failed') { continue }
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
    Update-OverChoices
    Update-Buttons
}

function Get-SelectedOverId {
    if (-not $script:OverPick -or $script:OverPick.SelectedIndex -lt 0 -or -not $script:OverBandIds) { return 'slight' }
    if ($script:OverPick.SelectedIndex -ge $script:OverBandIds.Count) { return 'slight' }
    return [string]$script:OverBandIds[$script:OverPick.SelectedIndex]
}

function Update-OverButton {
    if (-not $script:SelectOverButton) { return }
    $band = Get-OverBand (Get-SelectedOverId)
    if ($band) { $script:SelectOverButton.Text = ('Select ' + ([string]$band.Label).ToLowerInvariant()) }
}

function Update-OverChoices {
    if (-not $script:OverPick) { return }
    $keep = Get-SelectedOverId
    $script:LoadingOver = $true
    $script:OverPick.BeginUpdate()
    try {
        $script:OverPick.Items.Clear()
        $ids = New-Object System.Collections.Generic.List[string]
        $counts = @{}
        $match = 0
        $index = 0
        foreach ($band in @(Get-OverBands)) {
            $count = 0
            $listed = @()
            if ($script:Files) { $listed = @($script:Files.Items) }
            foreach ($item in $listed) {
                if ((Get-RowOverBand $item.Tag) -eq $band.Id) { $count++ }
            }
            $word = if ($count -eq 1) { 'file' } else { 'files' }
            [void]$script:OverPick.Items.Add(([string]$band.Label) + '  (' + $count + ' ' + $word + ')')
            [void]$ids.Add([string]$band.Id)
            $counts[[string]$band.Id] = $count
            if ($band.Id -eq $keep) { $match = $index }
            $index++
        }
        $script:OverBandIds = $ids
        $script:OverBandCounts = $counts
        if ($script:OverPick.Items.Count -gt 0) { $script:OverPick.SelectedIndex = $match }
    }
    finally {
        $script:OverPick.EndUpdate()
        $script:LoadingOver = $false
    }
    Update-OverButton
}

function Select-OverBand([string]$BandId) {
    if ($script:Work -ne 'idle') { return }
    if (-not $BandId) { $BandId = Get-SelectedOverId }
    $band = Get-OverBand $BandId
    if (-not $band) { return }
    if ($script:OverPick -and $script:OverBandIds) {
        for ($i = 0; $i -lt $script:OverBandIds.Count; $i++) {
            if ($script:OverBandIds[$i] -eq $BandId) {
                if ($script:OverPick.SelectedIndex -ne $i) { $script:OverPick.SelectedIndex = $i }
                break
            }
        }
    }
    $checked = 0
    $script:BulkCheck = $true
    try {
        $script:Files.BeginUpdate()
        foreach ($item in @($script:Files.Items)) {
            $inside = ((Get-RowOverBand $item.Tag) -eq $BandId)
            $item.Checked = $inside
            if ($inside) { $checked++ }
        }
    }
    finally {
        $script:Files.EndUpdate()
        $script:BulkCheck = $false
    }
    Update-Buttons
    $word = if ($checked -eq 1) { 'file' } else { 'files' }
    Write-Activity ("Checked $checked $word " + $band.Phrase + '.') 'text'
}

function Get-RowSortKey($tag, [int]$Column) {
    if ($null -eq $tag) { return $null }
    switch ($Column) {
        0 { return [string]$tag.Path }
        1 {
            $w = 0
            $h = 0
            [void][int]::TryParse([string]$tag.Width, [ref]$w)
            [void][int]::TryParse([string]$tag.Height, [ref]$h)
            if ($w -le 0 -or $h -le 0) { return $null }
            return [double](($w * 100000) + $h)
        }
        2 {
            if ($null -eq $tag.DurationSec -or [string]$tag.DurationSec -eq '') { return $null }
            return [double]$tag.DurationSec
        }
        3 {
            if ($null -eq $tag.SizeBytes -or [string]$tag.SizeBytes -eq '') { return $null }
            return [double]$tag.SizeBytes
        }
        4 {
            if ($null -eq $tag.GiBph -or [string]$tag.GiBph -eq '') { return $null }
            return [double]$tag.GiBph
        }
        5 {
            if ($null -eq $tag.BudgetGiBph -or [string]$tag.BudgetGiBph -eq '') { return $null }
            return [double]$tag.BudgetGiBph
        }
        6 { return (Get-OverRatio $tag.GiBph $tag.BudgetGiBph) }
        7 {
            if ($null -eq $tag.TargetKbps -or [string]$tag.TargetKbps -eq '') { return $null }
            return [double]$tag.TargetKbps
        }
        8 {
            if ($null -eq $tag.EstimateBytes -or [string]$tag.EstimateBytes -eq '') { return $null }
            return [double]$tag.EstimateBytes
        }
        10 {
            $saved = Get-SpaceSavedBytes $tag
            if ($null -eq $saved) { return $null }
            return [double]$saved
        }
        11 { return (Get-EstimatedSavingsBytes $tag) }
        default {
            if (-not $tag.Status) { return $null }
            return [string]$tag.Status
        }
    }
}

function Get-ColumnOrderNames {
    if (-not $script:Files -or -not $script:ColumnTitles) { return @() }
    if ($script:Files.Columns.Count -ne $script:ColumnTitles.Count) { return @() }
    $order = New-Object string[] $script:Files.Columns.Count
    for ($i = 0; $i -lt $script:Files.Columns.Count; $i++) {
        $display = $script:Files.Columns[$i].DisplayIndex
        if ($display -lt 0 -or $display -ge $order.Length) { return @() }
        if ($order[$display]) { return @() }
        $order[$display] = [string]$script:ColumnTitles[$i]
    }
    return @($order)
}

function Restore-ColumnOrder {
    param([string[]]$Order)
    if (-not $script:Files -or -not $script:ColumnTitles) { return $false }
    $titles = @($script:ColumnTitles)
    $wanted = @($Order | ForEach-Object { [string]$_ })
    if ($wanted.Count -ne $titles.Count) { return $false }
    $seen = @{}
    foreach ($name in $wanted) {
        if (-not $name -or $seen.ContainsKey($name)) { return $false }
        $seen[$name] = $true
    }
    foreach ($title in $titles) {
        if (-not $seen.ContainsKey([string]$title)) { return $false }
    }
    $changed = $false
    for ($display = 0; $display -lt $wanted.Count; $display++) {
        for ($i = 0; $i -lt $titles.Count; $i++) {
            if ([string]$titles[$i] -eq [string]$wanted[$display]) {
                if ($script:Files.Columns[$i].DisplayIndex -ne $display) {
                    $script:Files.Columns[$i].DisplayIndex = $display
                    $changed = $true
                }
                break
            }
        }
    }
    $script:ColumnOrder = @(Get-ColumnOrderNames)
    if ($changed -and $script:Files) { $script:Files.Invalidate() }
    return ($script:ColumnOrder.Count -eq $titles.Count)
}

function Get-ColumnHeaderCenter([int]$Index) {
    $display = $script:Files.Columns[$Index].DisplayIndex
    $x = 0
    for ($d = 0; $d -lt $display; $d++) {
        for ($i = 0; $i -lt $script:Files.Columns.Count; $i++) {
            if ($script:Files.Columns[$i].DisplayIndex -eq $d) {
                $x += $script:Files.Columns[$i].Width
                break
            }
        }
    }
    return ($x + [int]($script:Files.Columns[$Index].Width / 2))
}

function Install-ColumnDrag {
    if ($script:HeaderDrag) { return }
    $script:HeaderDrag = New-Object VideoDehydrator.HeaderDrag($script:Files)
    $script:HeaderDrag.Add_Reordered({
        $script:SkipNextColumnClick = $true
        $script:ColumnOrder = @(Get-ColumnOrderNames)
        Save-Settings
    })
    $script:HeaderDrag.Attach()
}

function Update-SortHeaders {
    if (-not $script:Files -or -not $script:ColumnTitles) { return }
    for ($i = 0; $i -lt $script:ColumnTitles.Count -and $i -lt $script:Files.Columns.Count; $i++) {
        $title = [string]$script:ColumnTitles[$i]
        if ($i -eq $script:SortColumn) {
            if ($script:SortAscending) { $title += ' ^' } else { $title += ' v' }
        }
        if ($script:Files.Columns[$i].Text -ne $title) { $script:Files.Columns[$i].Text = $title }
    }
}

function Sort-FileList([int]$Column) {
    if ($script:Work -ne 'idle') { return }
    if ($script:SortColumn -eq $Column) {
        $script:SortAscending = -not $script:SortAscending
    } else {
        $script:SortColumn = $Column
        $script:SortAscending = ($Column -ne 6 -and $Column -ne 10 -and $Column -ne 11)
    }
    $rows = @()
    foreach ($item in @($script:Files.Items)) {
        $key = Get-RowSortKey $item.Tag $Column
        $missing = 0
        $number = 0.0
        $text = [string]$item.Tag.Path
        $numeric = $true
        if ($null -eq $key) { $missing = 1 }
        elseif ($key -is [string]) { $text = [string]$key; $numeric = $false }
        else { $number = [double]$key }
        $rows += [pscustomobject]@{ Item = $item; Missing = $missing; Number = $number; Text = $text; Numeric = $numeric; Path = [string]$item.Tag.Path }
    }
    $present = @($rows | Where-Object { $_.Missing -eq 0 })
    $absent = @($rows | Where-Object { $_.Missing -eq 1 })
    if ($present.Count -gt 0) {
        if ([bool]$present[0].Numeric) {
            if ($script:SortAscending) { $present = @($present | Sort-Object Number, Path) }
            else { $present = @($present | Sort-Object @{ Expression = 'Number'; Descending = $true }, @{ Expression = 'Path'; Ascending = $true }) }
        } else {
            $present = @($present | Sort-Object @{ Expression = 'Text'; Descending = (-not $script:SortAscending) }, @{ Expression = 'Path'; Ascending = $true })
        }
    }
    $script:BulkCheck = $true
    try {
        $script:Files.BeginUpdate()
        $script:Files.Items.Clear()
        foreach ($row in @($present + $absent)) { [void]$script:Files.Items.Add($row.Item) }
    }
    finally {
        $script:Files.EndUpdate()
        $script:BulkCheck = $false
    }
    Update-SortHeaders
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
            if ($status -eq 'Bloated' -or $status -eq 'Can shrink' -or $status -eq 'Failed') {
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
    $convertible = @(Get-CheckedItems @('Bloated', 'Can shrink', 'Failed', 'Skipped'))
    $deletable = @(Get-CheckedItems @('Ready to delete'))
    $compareOk = $false
    if ($script:Files -and $script:Files.SelectedItems.Count -eq 1) {
        $selected = $script:Files.SelectedItems[0].Tag
        if ([string]$selected.Status -eq 'Ready to delete' -and $selected.Kept -and $selected.New) { $compareOk = $true }
    }
    if ($script:ScanButton) { $script:ScanButton.Enabled = ((-not $busy) -and $script:ToolsOk -and $folderOk) }
    if ($script:ConvertButton) { $script:ConvertButton.Enabled = ((-not $busy) -and $script:ToolsOk -and $convertible.Count -gt 0) }
    if ($script:ForceButton) { $script:ForceButton.Enabled = ((-not $busy) -and $script:ToolsOk) }
    if ($script:CancelButton) { $script:CancelButton.Enabled = $busy }
    $pausing = ($script:Work -eq 'encode')
    if ($script:StopAfterButton) { $script:StopAfterButton.Enabled = ($pausing -and -not $script:StopAfterFile) }
    if ($script:ContinueButton) { $script:ContinueButton.Enabled = ($pausing -and [bool]$script:StopAfterFile) }
    if ($script:CompareButton) { $script:CompareButton.Enabled = ((-not $busy) -and $compareOk) }
    if ($script:DeleteButton) { $script:DeleteButton.Enabled = ((-not $busy) -and $deletable.Count -gt 0) }
    $undoReady = (-not $busy) -and (@(Get-UndoBatch).Count -gt 0)
    if ($script:UndoButton) { $script:UndoButton.Enabled = $undoReady }
    if ($script:BrowseButton) { $script:BrowseButton.Enabled = -not $busy }
    if ($script:SelectAllButton) { $script:SelectAllButton.Enabled = -not $busy }
    if ($script:SelectNoneButton) { $script:SelectNoneButton.Enabled = -not $busy }
    if ($script:ClearButton) { $script:ClearButton.Enabled = ((-not $busy) -and (Test-ScanRows)) }
    if ($script:ShowButton) { $script:ShowButton.Enabled = -not $busy }
    if ($script:SelectShownButton) { $script:SelectShownButton.Enabled = -not $busy }
    $pickReady = (-not $busy) -and $script:FolderPick -and $script:FolderPick.Items.Count -gt 0
    if ($script:FolderPick) { $script:FolderPick.Enabled = [bool]$pickReady }
    if ($script:SelectFolderButton) {
        $script:SelectFolderButton.Enabled = [bool]($pickReady -and $script:FolderPick.SelectedIndex -ge 0)
    }
    $overCount = 0
    $overId = Get-SelectedOverId
    if ($script:OverBandCounts -and $script:OverBandCounts.ContainsKey($overId)) { $overCount = [int]$script:OverBandCounts[$overId] }
    if ($script:OverPick) { $script:OverPick.Enabled = -not $busy }
    if ($script:SelectOverButton) { $script:SelectOverButton.Enabled = ((-not $busy) -and $overCount -gt 0) }
    foreach ($chk in @($script:SubfoldersCheck, $script:AutoCheck, $script:RecycleCheck, $script:ReencodeCheck, $script:DetailedCheck, $script:ShutdownCheck)) {
        if ($chk) { $chk.Enabled = -not $busy }
    }
    if ($script:JobBox) { $script:JobBox.Enabled = -not $busy }
    if ($script:FindBox) { $script:FindBox.Enabled = -not $busy }
    foreach ($box in @($script:BudgetBoxes)) {
        if ($box) { $box.Enabled = -not $busy }
    }
    if ($script:ClearSkipsButton) {
        $skipCount = @($script:SkipRows | Where-Object { $_ }).Count
        $script:ClearSkipsButton.Enabled = ((-not $busy) -and $skipCount -gt 0)
    }
    Update-UpdateButtons
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
        if ($status -ne 'Bloated' -and $status -ne 'Can shrink' -and $status -ne 'Failed' -and $status -ne 'Skipped' -and $status -ne 'Forced') { continue }
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
    $top.Height = 86
    $top.BackColor = $script:ColorHeader
    $script:CompareTitle = New-Object Windows.Forms.Label
    $script:CompareTitle.ForeColor = [Drawing.Color]::White
    $script:CompareTitle.BackColor = $script:ColorHeader
    $script:CompareTitle.Font = $script:FontSection
    $script:CompareTitle.AutoEllipsis = $true
    $sides = New-Object Windows.Forms.Label
    $sides.Text = 'Original on the left. New file on the right. Sound is the new file, and it will not stay in sync with the picture. Go to the file on disk to confirm the audio.'
    $sides.AutoEllipsis = $true
    $sides.ForeColor = $script:ColorHeaderMuted
    $sides.BackColor = $script:ColorHeader
    $sides.Font = $script:FontHint
    $top.Controls.Add($script:CompareTitle)
    $top.Controls.Add($sides)
    $top.Add_Resize({
        $script:CompareTitle.SetBounds(20, 8, ($this.ClientSize.Width - 40), 26)
        $this.Controls[1].SetBounds(20, 36, ($this.ClientSize.Width - 40), 42)
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

function Remove-HeldFileQuiet {
    param([string]$Path)
    if (-not $Path) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $length = [int64]0
    try { $length = [int64](Get-Item -LiteralPath $Path -Force).Length } catch { return }
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Path) { return }
    if ($length -le 0) { return }
    try { [void](Remove-RecycleCopy -Path $Path -Length $length) } catch { }
}

function Remove-TempQuiet {
    param([string]$Path)
    Remove-HeldFileQuiet $Path
    if ($Path) { Remove-EmptyDirectory (Split-Path -Parent $Path) }
}

function Release-EncodeHold {
    param($Plan)
    if (-not $Plan) { return }
    Remove-HoldBusyMarker -Plan $Plan
    if ($Plan.Temp) { Remove-TempQuiet $Plan.Temp }
}

function Complete-ScanRuntime {
    param([string]$Label = 'Scan')
    if ($script:ScanPower) {
        try { $script:ScanPower.EndInvoke($script:ScanHandle) | Out-Null } catch {
            Write-Activity ("$Label stopped early. " + $_.Exception.Message) 'warn'
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
        param($EnginePath, $Root, $Recurse, $Ffprobe, $Queue, $Cancel, $Budgets, $SkipJson, $Limit)
        . $EnginePath
        Set-BudgetPicks $Budgets
        Invoke-ScanFolder -Root $Root -Recurse $Recurse -Ffprobe $Ffprobe -Queue $Queue -Cancel $Cancel -Skips @(Convert-SkipRows $SkipJson) -Limit $Limit
    }).AddArgument($script:EnginePath).AddArgument($folder).AddArgument([bool]$script:SubfoldersCheck.Checked).AddArgument($script:Ffprobe).AddArgument($script:ScanQueue).AddArgument($script:ScanCancel).AddArgument((Get-SelectedBudgetPack)).AddArgument((Format-SkipJson $script:SkipRows)).AddArgument((Get-FindLimit))
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
            $scanStatus = "Scanned $($msg.Seen), $($msg.Hits) bloated"
            $shrinkNow = 0
            if ($msg.PSObject.Properties.Name -contains 'Shrink') { $shrinkNow = [int]$msg.Shrink }
            if ($shrinkNow -gt 0) { $scanStatus += ", $shrinkNow can shrink" }
            Set-Status ($scanStatus + " - $($msg.Name)") 'busy'
        }
        elseif ($msg.Kind -eq 'hit') {
            if (Test-KnownNewPath ([string]$msg.Path)) { continue }
            $estimate = $null
            if ($null -ne $msg.EstimateBytes -and [string]$msg.EstimateBytes -ne '') { $estimate = [int64]$msg.EstimateBytes }
            $videoBits = [int64]0
            if ($null -ne $msg.VideoBitrate -and [string]$msg.VideoBitrate -ne '') {
                [void][int64]::TryParse([string]$msg.VideoBitrate, [ref]$videoBits)
            }
            $listed = 'Bloated'
            if ([string]$msg.Decision -eq 'shrink') { $listed = 'Can shrink' }
            $tag = @{
                Status = $listed
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
                EstimateRough = [bool]$msg.EstimateRough
                VideoBitrate = $videoBits
                Codec = [string]$msg.Codec
                PendingId = ''
                Reason = [string]$msg.Reason
            }
            if ($msg.PSObject.Properties.Name -contains 'TenBit') { $tag.TenBit = [bool]$msg.TenBit }
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
    $ignored = 0
    if ($summary) {
        $hits = [int]$summary.Hits
        $seen = [int]$summary.Seen
        $lean = [int]$summary.Lean
        $within = [int]$summary.Within
        $dv = [int]$summary.Dv
        $nodur = [int]$summary.NoDur
        $errors = [int]$summary.Errors
        $ignored = [int]$summary.Ignored
    }
    $shrink = 0
    if ($summary -and $summary.PSObject.Properties.Name -contains 'Shrink') { $shrink = [int]$summary.Shrink }
    $bytes = [int64]0
    $shrinkBytes = [int64]0
    foreach ($item in @($script:Files.Items)) {
        $rowStatus = [string]$item.Tag.Status
        if ($rowStatus -eq 'Bloated' -and $item.Tag.SizeBytes) { $bytes += [int64]$item.Tag.SizeBytes }
        if ($rowStatus -eq 'Can shrink' -and $item.Tag.SizeBytes) { $shrinkBytes += [int64]$item.Tag.SizeBytes }
    }
    $line = "Scanned $seen videos. $hits bloated"
    if ($bytes -gt 0) { $line += " (" + (Format-ByteSize $bytes) + ")" }
    if ($shrink -gt 0) {
        $line += ". $shrink can shrink"
        if ($shrinkBytes -gt 0) { $line += " (" + (Format-ByteSize $shrinkBytes) + ")" }
    }
    $line += "."
    Set-Status $line 'ok'
    Write-Activity $line 'ok'
    $extra = @()
    if ($lean -gt 0) { $extra += "$lean already under the budget" }
    if ($within -gt 0) { $extra += "$within already at the picture rate" }
    if ($dv -gt 0) { $extra += "$dv Dolby Vision left alone" }
    if ($nodur -gt 0) { $extra += "$nodur could not be measured" }
    if ($errors -gt 0) { $extra += "$errors could not be read" }
    if ($ignored -eq 1) { $extra += '1 file left off the list because an earlier convert was not smaller. A smaller budget lists it again. Clear skips forgets that mark' }
    elseif ($ignored -gt 1) { $extra += "$ignored files left off the list because an earlier convert was not smaller. A smaller budget lists them again. Clear skips forgets those marks" }
    if ($extra.Count -gt 0) { Write-Activity ($extra -join '. ') 'dim' }
    if ($summary -and $summary.Samples) { Write-Activity ([string]$summary.Samples) 'warn' }
    if ($summary -and [bool]$summary.Limited) {
        $found = $hits + $shrink
        $word = if ($found -eq 1) { 'file' } else { 'files' }
        Write-Activity "Stopped scanning after $found $word that can be reduced." 'text'
    }
    elseif ($hits -eq 0 -and $shrink -eq 0 -and $seen -gt 0 -and $ignored -eq 0) { Write-Activity 'Nothing in this folder is over the budget for its picture size.' 'text' }
    Update-Buttons
}

function Test-PassTwoDidNotStart($Lines) {
    $text = (@($Lines) -join "`n")
    if ($text -match 'encoded 0 frames' -and $text -match 'task 2 of 2') { return $true }
    if ($text -match 'x265_encoder_open failed|Failure to initialise thread|can''t open stats file') { return $true }
    return $false
}

function Test-OutputPathMissing($Lines) {
    $text = (@($Lines) -join "`n")
    return ($text -match 'avio_open2 failed' -and $text -match 'errno -2')
}

function Get-EncodeFailureText($Lines) {
    $picked = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($Lines)) {
        if (-not $line) { continue }
        if ($line -match 'error|Error|fail|Fail|result =') {
            [void]$picked.Add(($line -replace '\s+', ' ').Trim())
        }
    }
    if ($picked.Count -eq 0) { $picked = @($Lines | Select-Object -Last 6) }
    $keep = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($picked)) {
        if ($line -match 'avio_open2 failed') { [void]$keep.Add($line) }
    }
    foreach ($line in @($picked | Select-Object -Last 4)) {
        if (-not $line) { continue }
        $seen = $false
        foreach ($have in $keep) {
            if ($have -eq $line) { $seen = $true; break }
        }
        if (-not $seen) { [void]$keep.Add($line) }
    }
    $tail = @($keep) -join ' | '
    if ($tail.Length -gt 500) {
        if ($tail -match 'avio_open2 failed') { $tail = $tail.Substring(0, 500) }
        else { $tail = $tail.Substring($tail.Length - 500) }
    }
    return $tail
}

function Start-EncodeProcess {
    param($Item, $Plan, $Probe, $Decision, $Lane, [switch]$SinglePass, [switch]$KeepTwoPass)
    if (-not $Lane) { return }
    $tag = $Item.Tag
    $tag.Status = 'Converting'
    $tag.Reason = ''
    Update-ResultRow $Item
    # The analysis pass does not create the output file. The marker keeps
    # .vd-originals in place until this encode exits.
    Add-HoldBusyMarker -Plan $Plan
    if (-not $KeepTwoPass) { $Lane.OutputRetries = 0 }
    $encoder = Get-EncoderName -Probe $Probe
    $reencode = $false
    if ($script:ReencodeCheck) { $reencode = [bool]$script:ReencodeCheck.Checked }
    $pool = 0
    if ((Get-JobCount) -gt 1) { $pool = 8 }
    $arguments = Get-HandBrakeArguments -Source $Plan.Source -Temp $Plan.Temp -Probe $Probe -VideoKbps $Decision.TargetKbps -Encoder $encoder -ReencodeAudio:$reencode -ThreadPool $pool -SinglePass:$SinglePass
    $Lane.ReencodeAudio = $reencode
    $Lane.Lines = New-Object System.Collections.Generic.List[string]
    $Lane.Item = $Item
    $Lane.Plan = $Plan
    $Lane.Probe = $Probe
    $Lane.Decision = $Decision
    $Lane.Encoder = $encoder
    $Lane.Percent = 0
    $Lane.Pass = ''
    $Lane.SinglePass = [bool]$SinglePass
    if ($script:DetailedCheck.Checked) {
        $shown = [IO.Path]::GetFileName($Plan.Source) + '  ' + (ConvertTo-ArgumentLine (@($script:HandBrake) + $arguments))
        if ((Get-JobCount) -le 1) { $shown = ConvertTo-ArgumentLine (@($script:HandBrake) + $arguments) }
        Write-Activity $shown 'dim'
    }
    if ($null -eq $Lane.Pump) { $Lane.Pump = New-Object VideoDehydrator.JobPump }
    $Lane.Pump.Start($script:HandBrake, (ConvertTo-ArgumentLine $arguments))
    if ([int]$Lane.Index -eq 0) {
        Reset-EncodeEtaClock
        $script:EtaTenBit = ($encoder -eq 'x265_10bit')
        $script:EtaPixels = Get-PixelSeconds ([int]$Probe.Width) ([int]$Probe.Height) ([double]$Probe.DurationSec)
        Update-EtaLine
    }
    Paint-EncodeProgress
    if (-not $script:PulseWanted) { Start-ActivityPulse }
}

function Test-EncodeBusy {
    if (-not $script:Lanes) { return $false }
    foreach ($lane in @($script:Lanes)) {
        if ($lane.Item) { return $true }
    }
    return $false
}

function Start-NextEncode {
    while ($script:EncodeIndex -lt $script:EncodeItems.Count) {
        if ($script:Cancel) {
            if (-not (Test-EncodeBusy)) { Finish-Batch 'stopped' }
            return
        }
        if ($script:StopAfterFile) {
            if (-not (Test-EncodeBusy)) { Finish-Batch 'after' }
            return
        }
        $lane = Get-OpenLane
        if (-not $lane) { return }
        $item = $script:EncodeItems[$script:EncodeIndex]
        $script:EncodeIndex++
        $number = $script:EncodeIndex
        $total = $script:EncodeItems.Count
        $script:EtaProgress = $null
        $script:EtaChecking = $false
        Update-EtaLine
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
        $convertible = ($decision.Decision -eq 'bloated' -or $decision.Decision -eq 'shrink')
        if ($script:ForceEncode) { $convertible = (Test-ForceConvertible $decision) }
        if (-not $convertible) {
            $item.Tag.Status = 'Already small enough'
            if ($script:ForceEncode) { $item.Tag.Status = 'Left alone' }
            $item.Tag.Reason = $decision.Reason
            $item.Checked = $false
            Update-ResultRow $item
            Write-Activity ("Left alone  " + [IO.Path]::GetFileName($source) + "  " + $decision.Reason) 'dim'
            continue
        }
        try {
            New-Item -ItemType Directory -Force -Path $plan.HoldDir | Out-Null
            Add-PlexIgnore -Directory (Split-Path -Parent $source)
            if (Test-Path -LiteralPath $plan.Temp) { Remove-HeldFileQuiet $plan.Temp }
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
        Start-EncodeProcess -Item $item -Plan $plan -Probe $probe -Decision $decision -Lane $lane
        if ((Get-JobCount) -gt 1 -and (Get-OpenLane) -and -not $script:StopAfterFile -and -not $script:Cancel) { continue }
        return
    }
    if (-not (Test-EncodeBusy)) { Finish-Batch 'done' }
}

function Fail-Active {
    param(
        [string]$Reason,
        $Verify,
        $Lane
    )
    $item = $null
    $plan = $null
    $laneProbe = $null
    $laneDecision = $null
    if ($Lane) {
        $item = $Lane.Item
        $plan = $Lane.Plan
        $laneProbe = $Lane.Probe
        $laneDecision = $Lane.Decision
    }
    $newBytes = [int64]0
    $sourceBytes = [int64]0
    $targetKbps = 0
    $sourceCodecs = @()
    $outputCodecs = @()
    if ($Verify -and $null -ne $Verify.NewBytes) { $newBytes = [int64]$Verify.NewBytes }
    elseif ($plan -and $plan.Temp -and (Test-Path -LiteralPath $plan.Temp)) {
        $newBytes = [int64](Get-Item -LiteralPath $plan.Temp).Length
    }
    if ($laneProbe) {
        $sourceBytes = [int64]$laneProbe.SizeBytes
        if ($null -ne $laneProbe.AudioCodecs) { $sourceCodecs = @($laneProbe.AudioCodecs) }
    }
    if ($Verify -and $Verify.OutProbe -and $null -ne $Verify.OutProbe.AudioCodecs) {
        $outputCodecs = @($Verify.OutProbe.AudioCodecs)
    }
    if ($laneDecision -and $laneDecision.TargetKbps) { $targetKbps = [int]$laneDecision.TargetKbps }
    $note = Get-LargerFileNote -Reason $Reason -SourceBytes $sourceBytes -NewBytes $newBytes -TargetKbps $targetKbps -SourceCodecs $sourceCodecs -OutputCodecs $outputCodecs
    $sizeSkip = (Test-SizeSkipReason $Reason) -and [bool]$note
    if ($sizeSkip) {
        $note = $note + ' Later scans leave this file off the list. A smaller budget lists it again. Clear skips forgets that mark.'
        $skipPath = ''
        if ($plan) { $skipPath = [string]$plan.Source }
        if ($skipPath -and $sourceBytes -gt 0 -and $targetKbps -gt 0) {
            Remember-SizeSkip -Path $skipPath -SizeBytes $sourceBytes -TargetKbps $targetKbps
        }
    }
    Release-EncodeHold $plan
    Write-NewRecycleActivity
    if ($item) {
        if ($sizeSkip) {
            $item.Tag.Status = 'Skipped'
            $item.Tag.Reason = $note
            $item.Checked = $false
        }
        else {
            $item.Tag.Status = 'Failed'
            $item.Tag.Reason = $Reason
            $item.Checked = $true
        }
        Update-ResultRow $item
    }
    $name = ''
    if ($plan) { $name = [IO.Path]::GetFileName($plan.Source) }
    if ($sizeSkip) {
        Write-Activity ("Skipped  $name  $note") 'warn'
        Add-RunLog -Status 'SKIP' -Reason $note -Source $(if ($plan) { $plan.Source } else { '' }) -NewPath '' -Kept '' -Width $(if ($laneProbe) { $laneProbe.Width } else { '' }) -Height $(if ($laneProbe) { $laneProbe.Height } else { '' }) -Kbps $(if ($laneDecision) { $laneDecision.TargetKbps } else { '' })
    }
    else {
        Write-Activity ("Failed  $name  $Reason") 'err'
        if ($note) { Write-Activity $note 'warn' }
        Add-RunLog -Status 'FAIL' -Reason $Reason -Source $(if ($plan) { $plan.Source } else { '' }) -NewPath '' -Kept '' -Width $(if ($laneProbe) { $laneProbe.Width } else { '' }) -Height $(if ($laneProbe) { $laneProbe.Height } else { '' }) -Kbps $(if ($laneDecision) { $laneDecision.TargetKbps } else { '' })
    }
    if ($Lane) {
        $Lane.Item = $null
        $Lane.Plan = $null
    }
    if (Test-EncodeBusy) { Paint-EncodeProgress } else { Stop-ActivityPulse }
    Update-JobBars
}

function Read-LaneLines($Lane) {
    if (-not $Lane -or -not $Lane.Item -or -not $Lane.Pump) { return }
    if ($null -eq $Lane.Lines) { $Lane.Lines = New-Object System.Collections.Generic.List[string] }
    $batch = @($Lane.Pump.Drain())
    $latest = $null
    foreach ($line in $batch) {
        if (-not $line) { continue }
        $Lane.Lines.Add($line)
        if ($Lane.Lines.Count -gt 500) { $Lane.Lines.RemoveAt(0) }
        $progress = Get-HandBrakeProgress $line
        if ($null -ne $progress) {
            $latest = $progress
            continue
        }
        if ((Test-EncodeProgressLine $line)) { continue }
        if ($script:DetailedCheck.Checked) {
            $prefix = ''
            if ((Get-JobCount) -gt 1 -and $Lane.Plan) { $prefix = [IO.Path]::GetFileName($Lane.Plan.Source) + '  ' }
            Write-Activity ($prefix + $line) 'dim'
        }
    }
    if ($null -eq $latest) { return }
    $Lane.Percent = [double]$latest.Overall
    $pass = 'first pass'
    if ([int]$latest.Task -ge 2) { $pass = 'pass ' + [int]$latest.Task }
    $passChanged = ($pass -ne [string]$Lane.Pass)
    $Lane.Pass = $pass
    if ([int]$Lane.Index -eq 0) { Sync-EncodePass $latest }
    if ($passChanged -or (Test-ProgressPaintDue)) { Paint-EncodeProgress }
}

function Paint-EncodeProgress {
    $script:ProgressPaintAt = [datetime]::UtcNow
    $statusLane = $null
    if ($script:Lanes) {
        foreach ($lane in @($script:Lanes)) {
            if ($lane.Item) { $statusLane = $lane; break }
        }
    }
    if ($statusLane) {
        Set-Progress ([double]$statusLane.Percent)
        $name = ''
        if ($statusLane.Plan) { $name = [IO.Path]::GetFileName($statusLane.Plan.Source) }
        $number = $script:EncodeIndex
        $total = 0
        if ($script:EncodeItems) { $total = $script:EncodeItems.Count }
        $fileStatus = "File $number of $total - $name - " + ('{0:0}%' -f [double]$statusLane.Percent)
        if ((Get-JobCount) -gt 1) {
            $running = 0
            foreach ($lane in @($script:Lanes)) { if ($lane.Item) { $running++ } }
            $fileStatus = "$running files at once - $name - " + ('{0:0}%' -f [double]$statusLane.Percent)
        }
        if ($script:StopAfterFile) { $fileStatus += ' - stopping after the current file' }
        Set-Status $fileStatus 'busy'
    }
    Update-JobBars
    Update-EtaLine
}

function Update-JobBars {
    $running = 0
    if ($script:Lanes) {
        foreach ($lane in @($script:Lanes)) { if ($lane.Item) { $running++ } }
    }
    $show = ((Get-JobCount) -gt 1) -and ($running -gt 0)
    if ($script:JobHost) { $script:JobHost.Visible = $show }
    if ($script:ProgressTrack) { $script:ProgressTrack.Visible = -not $show }
    if (-not $show) {
        if ($script:JobHost) { $script:JobHost.Height = 0 }
    } else {
    $rows = @($script:JobRows)
    $limit = Get-JobCount
    $count = 0
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $lane = $null
        if ($script:Lanes -and $i -lt @($script:Lanes).Count) { $lane = @($script:Lanes)[$i] }
        $visible = ($i -lt $limit -and $lane -and $lane.Item)
        $rows[$i].Panel.Visible = [bool]$visible
        if (-not $visible) { continue }
        $count++
        $laneName = ''
        if ($lane.Plan) { $laneName = [IO.Path]::GetFileName($lane.Plan.Source) }
        Set-JobBar $rows[$i] $laneName ([double]$lane.Percent) ([string]$lane.Pass)
    }
    if ($count -lt 1) { $count = 1 }
    if ($script:JobHost) { $script:JobHost.Height = 8 + ($count * 36) }
    }
    if ($script:StatusPanel) {
        $want = 58
        if ($script:EtaLabel -and -not [string]::IsNullOrWhiteSpace([string]$script:EtaLabel.Text)) { $want = 78 }
        if ($show -and $script:JobHost) { $want += [int]$script:JobHost.Height }
        if ($script:StatusPanel.Height -ne $want) {
            $script:StatusPanel.Height = $want
            Update-ChromeLayout
        }
    }
}

function Complete-ActiveEncode {
    param($Lane)
    if (-not $Lane -or -not $Lane.Item) { return }
    Read-LaneLines $Lane
    $exitCode = 0
    if ($Lane.Pump) { $exitCode = [int]$Lane.Pump.ExitCode }
    $plan = $Lane.Plan
    $item = $Lane.Item
    $laneLines = $Lane.Lines
    $laneProbe = $Lane.Probe
    $laneDecision = $Lane.Decision
    $laneReencode = [bool]$Lane.ReencodeAudio
    if ($script:Cancel) {
        Release-EncodeHold $plan
        Write-NewRecycleActivity
        if ($item -and [string]$item.Tag.Status -eq 'Converting') {
            $item.Tag.Status = 'Stopped'
            $item.Tag.Reason = 'Cancelled before the new file was checked.'
            Update-ResultRow $item
        }
        Finish-Batch 'stopped'
        return
    }
    $log = ($(if ($laneLines) { $laneLines } else { @() }) -join "`n")
    if ($exitCode -ne 0 -or -not $plan -or -not (Test-Path -LiteralPath $plan.Temp)) {
        $outputRetries = [int]$Lane.OutputRetries
        $outputMissing = Test-OutputPathMissing $laneLines
        if (-not $script:Cancel -and $plan -and $exitCode -ne 0 -and $outputMissing -and $outputRetries -lt 2) {
            $retryName = ''
            if ($plan.Source) { $retryName = [IO.Path]::GetFileName($plan.Source) }
            Write-Activity ("The output folder was missing for  $retryName. Trying the two-pass encode again.") 'warn'
            $Lane.OutputRetries = $outputRetries + 1
            if ($plan.Temp) { Remove-TempQuiet $plan.Temp }
            Start-EncodeProcess -Item $item -Plan $plan -Probe $laneProbe -Decision $laneDecision -Lane $Lane -KeepTwoPass
            return
        }
        $alreadySingle = [bool]$Lane.SinglePass
        if (-not $script:Cancel -and -not $outputMissing -and -not $alreadySingle -and $exitCode -ne 0 -and (Test-PassTwoDidNotStart $laneLines)) {
            $retryName = ''
            if ($plan) { $retryName = [IO.Path]::GetFileName($plan.Source) }
            Write-Activity ("The two-pass encode did not start for  $retryName. Trying one pass.") 'warn'
            if ($plan -and $plan.Temp) { Remove-TempQuiet $plan.Temp }
            Start-EncodeProcess -Item $item -Plan $plan -Probe $laneProbe -Decision $laneDecision -Lane $Lane -SinglePass
            return
        }
        $tail = Get-EncodeFailureText $laneLines
        Fail-Active "HandBrake stopped ($exitCode). $tail" -Lane $Lane
        Start-NextEncode
        return
    }
    if ([int]$Lane.Index -eq 0) { Remember-FinishedEncode }
    $script:EtaChecking = $true
    Update-EtaLine
    if ($item) {
        $item.Tag.Status = 'Checking'
        Update-ResultRow $item
    }
    Set-Status 'Checking the new file' 'busy'
    $script:Form.Refresh()
    $verify = Test-EncodedFile -Ffmpeg $script:Ffmpeg -Ffprobe $script:Ffprobe -Temp $plan.Temp -SourceProbe $laneProbe -HandBrakeLog $log -AllowAudioReencode:$laneReencode
    if (-not $verify.Ok) {
        Fail-Active -Reason $verify.Reason -Verify $verify -Lane $Lane
        Start-NextEncode
        return
    }
    try {
        Remove-HoldBusyMarker -Plan $plan
        $swap = Invoke-ReplaceWithEncode -Source $plan.Source -TempFile $plan.Temp -DeleteOriginal:([bool]$script:AutoCheck.Checked)
    }
    catch {
        Fail-Active $_.Exception.Message -Lane $Lane
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
        Write-NewRecycleActivity
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
            width = $(if ($laneProbe) { $laneProbe.Width } else { 0 })
            height = $(if ($laneProbe) { $laneProbe.Height } else { 0 })
            targetKbps = $(if ($laneDecision) { $laneDecision.TargetKbps } else { 0 })
            batch = [string]$script:ConvertBatchId
        }
        $item.Tag.PendingId = $entry.id
        Write-Pending (@($pending) + @($entry))
        Write-Activity ("Ready  $name  saved " + (Format-ByteSize $saved) + ". Original kept for review.") 'ok'
    }
    Update-ResultRow $item
    if ($plan.Source) { Forget-SizeSkipPath ([string]$plan.Source) }
    Add-RunLog -Status $(if ($swap.Deleted) { 'REPLACED' } else { 'KEPT' }) -Reason 'ok' -Source $plan.Source -NewPath $swap.NewPath -Kept $swap.KeptPath -OldBytes $swap.OldBytes -NewBytes $swap.NewBytes -OldRate $verify.OldGiBph -NewRate $verify.NewGiBph -Width $(if ($laneProbe) { $laneProbe.Width } else { '' }) -Height $(if ($laneProbe) { $laneProbe.Height } else { '' }) -Kbps $(if ($laneDecision) { $laneDecision.TargetKbps } else { '' })
    $Lane.Item = $null
    $Lane.Plan = $null
    if (-not (Test-EncodeBusy)) { Stop-ActivityPulse }
    Update-JobBars
    Start-NextEncode
}

function Get-CurrentPassElapsed {
    if ($null -eq $script:EtaPassStart) { return 0 }
    $elapsed = ([datetime]::UtcNow - $script:EtaPassStart).TotalSeconds
    if ($elapsed -lt 0 -or [double]::IsNaN($elapsed)) { return 0 }
    return [double]$elapsed
}

function Reset-EncodeEtaClock {
    $script:EtaPassStart = [datetime]::UtcNow
    $script:EtaPass1Sec = 0
    $script:EtaTask = 0
    $script:EtaProgress = $null
    $script:EtaChecking = $false
    $script:EtaRemembered = $false
    if ($script:EtaLive8) { $script:EtaLive8.Clear() }
    if ($script:EtaLive10) { $script:EtaLive10.Clear() }
    Clear-EtaWindow
}

function Add-EtaSample($List, [double]$Value) {
    if ($null -eq $List) { return }
    if ($Value -le 0 -or [double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { return }
    [void]$List.Add($Value)
    while ($List.Count -gt 8) { $List.RemoveAt(0) }
}

function Remember-FinishedEncode {
    if ($script:EtaRemembered) { return }
    if ([int]$script:EtaTask -lt 2) { return }
    if ([double]$script:EtaPass1Sec -lt 1) { return }
    $pass2 = Get-CurrentPassElapsed
    if ($pass2 -lt 1) { return }
    $pixels = [double]$script:EtaPixels
    if ($pixels -le 0) { return }
    $rate = ([double]$script:EtaPass1Sec + $pass2) / $pixels
    $ratio = $pass2 / [double]$script:EtaPass1Sec
    if ([bool]$script:EtaTenBit) { Add-EtaSample $script:EtaRates10 $rate }
    else { Add-EtaSample $script:EtaRates8 $rate }
    Add-EtaSample $script:EtaRatios $ratio
    $script:EtaRemembered = $true
}

function Sync-EncodePass($Progress) {
    if ($null -eq $Progress) { return }
    $task = [int]$Progress.Task
    if ([int]$script:EtaTask -ge 1 -and $task -gt [int]$script:EtaTask) {
        if ([int]$script:EtaTask -eq 1 -and $task -ge 2) {
            $script:EtaPass1Sec = Get-CurrentPassElapsed
        }
        $script:EtaPassStart = [datetime]::UtcNow
    }
    if ($task -gt [int]$script:EtaTask) {
        if ($script:EtaLive8) { $script:EtaLive8.Clear() }
        if ($script:EtaLive10) { $script:EtaLive10.Clear() }
        $script:EtaTask = $task
    }
    $script:EtaProgress = $Progress
}

function Get-ChosenEncodeRate([string]$Class) {
    $finished = @()
    if ($Class -eq '10') { $finished = @($script:EtaRates10) }
    elseif ($Class -eq '8') { $finished = @($script:EtaRates8) }
    else { return 0 }
    $live = 0.0
    $progress = $script:EtaProgress
    $onLastPass = ($null -ne $progress -and [int]$progress.Task -ge [int]$progress.Tasks -and [int]$script:EtaTask -ge 2)
    $same = (($Class -eq '10') -eq [bool]$script:EtaTenBit)
    $part = 0.0
    if ($onLastPass -and $same -and -not $script:EtaChecking) {
        if ([double]$progress.Part -gt 0) { $part = [double]$progress.Part / 100.0 }
        $live = Get-LiveEncodeRate -Pass1Sec ([double]$script:EtaPass1Sec) -PassElapsedSec (Get-CurrentPassElapsed) -PassFraction $part -PixelSeconds ([double]$script:EtaPixels)
        if ($live -gt 0) {
            $bucket = $script:EtaLive8
            if ($Class -eq '10') { $bucket = $script:EtaLive10 }
            Add-EtaSample $bucket $live
            $live = Get-MedianSample @($bucket)
        }
    }
    return (Get-EncodeRate -LiveRate $live -FinishedRates $finished -PassFraction $part)
}

function Get-WaitingEncodeRows {
    if ($script:StopAfterFile -or -not $script:EncodeItems) { return @() }
    $list = New-Object System.Collections.Generic.List[object]
    for ($i = [int]$script:EncodeIndex; $i -lt $script:EncodeItems.Count; $i++) {
        $item = $script:EncodeItems[$i]
        $tag = $null
        if ($item) { $tag = $item.Tag }
        $known = $false
        $ten = $false
        $pixels = 0.0
        if ($tag -and ($tag -is [System.Collections.IDictionary]) -and $tag.Contains('TenBit')) {
            $width = 0
            $height = 0
            [void][int]::TryParse([string]$tag['Width'], [ref]$width)
            [void][int]::TryParse([string]$tag['Height'], [ref]$height)
            $duration = 0.0
            [void][double]::TryParse([string]$tag['DurationSec'], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$duration)
            $pixels = Get-PixelSeconds $width $height $duration
            $ten = [bool]$tag['TenBit']
            $known = ($pixels -gt 0)
        }
        [void]$list.Add([pscustomobject]@{ PixelSeconds = $pixels; TenBit = $ten; Known = $known })
    }
    return @($list.ToArray())
}

function Set-EtaText([string]$text) {
    if ($null -eq $script:EtaLabel -or $null -eq $script:StatusPanel) { return }
    if ($null -eq $text) { $text = '' }
    $show = -not [string]::IsNullOrWhiteSpace($text)
    $want = 58
    if ($show) { $want = 78 }
    if ($script:JobHost -and $script:JobHost.Visible) { $want += [int]$script:JobHost.Height }
    $textSame = ([string]$script:EtaLabel.Text -eq $text)
    $heightSame = ($script:StatusPanel.Height -eq $want)
    if ($textSame -and $heightSame) { return }
    $script:EtaLabel.Text = $text
    if ($script:Tips) {
        $tip = 'This file is the encode in progress. Estimated time remaining is the rest of the batch.'
        if ($show) { $tip = $text }
        $script:Tips.SetToolTip($script:EtaLabel, $tip)
    }
    if (-not $heightSame) {
        $script:StatusPanel.Height = $want
        Update-ChromeLayout
    }
}

function Add-EtaWindow($List, [double]$Value) {
    if ($null -eq $List) { return }
    if ($Value -le 0 -or [double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { return }
    [void]$List.Add($Value)
    while ($List.Count -gt 160) { $List.RemoveAt(0) }
}

function Clear-EtaWindow {
    if ($script:EtaFileSamples) { $script:EtaFileSamples.Clear() }
    if ($script:EtaBatchSamples) { $script:EtaBatchSamples.Clear() }
    $script:EtaShownAt = $null
    $script:EtaShownKey = ''
}

function Get-EtaPublishKey([string]$Phase, $Estimate) {
    $task = 0
    if ($script:EtaProgress) { $task = [int]$script:EtaProgress.Task }
    $stop = 'run'
    if ($script:StopAfterFile) { $stop = 'stop' }
    $batch = 'wait'
    if ($Estimate -and [bool]$Estimate.HaveBatch) { $batch = 'ready' }
    $kind = 'none'
    if ($Estimate) { $kind = [string]$Estimate.FileKind }
    return ($Phase + '|' + $kind + '|' + $batch + '|' + $stop + '|' + $task)
}

function Update-EtaLine {
    if ($script:Work -ne 'encode') {
        Clear-EtaWindow
        Set-EtaText ''
        return
    }
    $phase = 'encode'
    if ($script:EtaChecking) { $phase = 'check' }
    $estimate = Get-RemainingEstimate -Progress $script:EtaProgress -PassElapsedSec (Get-CurrentPassElapsed) -Pass1Sec ([double]$script:EtaPass1Sec) -PassRatio (Get-MeanSample @($script:EtaRatios)) -Rate8 (Get-ChosenEncodeRate '8') -Rate10 (Get-ChosenEncodeRate '10') -Waiting (Get-WaitingEncodeRows) -Phase $phase
    $key = Get-EtaPublishKey $phase $estimate
    $keyChanged = ($key -ne [string]$script:EtaShownKey)
    if ($keyChanged) {
        if ($script:EtaFileSamples) { $script:EtaFileSamples.Clear() }
        if ($script:EtaBatchSamples) { $script:EtaBatchSamples.Clear() }
    }
    if ([double]$estimate.FileSeconds -gt 0) { Add-EtaWindow $script:EtaFileSamples ([double]$estimate.FileSeconds) }
    if ($estimate.HaveBatch -and [double]$estimate.BatchSeconds -gt 0) { Add-EtaWindow $script:EtaBatchSamples ([double]$estimate.BatchSeconds) }
    $fileSeconds = Get-MedianSample @($script:EtaFileSamples)
    if ($fileSeconds -le 0) { $fileSeconds = [double]$estimate.FileSeconds }
    $batchSeconds = [double]$estimate.BatchSeconds
    if ($estimate.HaveBatch) {
        $medianBatch = Get-MedianSample @($script:EtaBatchSamples)
        if ($medianBatch -gt 0) { $batchSeconds = $medianBatch }
    }
    $text = Format-EtaText -Progress $script:EtaProgress -FileKind ([string]$estimate.FileKind) -FileSeconds $fileSeconds -BatchSeconds $batchSeconds -HaveBatch ([bool]$estimate.HaveBatch)
    $sinceShown = 999.0
    if ($null -ne $script:EtaShownAt) { $sinceShown = ([datetime]::UtcNow - $script:EtaShownAt).TotalSeconds }
    if ($keyChanged -or $sinceShown -ge 30) {
        Set-EtaText $text
        $script:EtaShownAt = [datetime]::UtcNow
        $script:EtaShownKey = $key
        if (-not $keyChanged) {
            if ($script:EtaFileSamples) { $script:EtaFileSamples.Clear() }
            if ($script:EtaBatchSamples) { $script:EtaBatchSamples.Clear() }
            if ($fileSeconds -gt 0) { Add-EtaWindow $script:EtaFileSamples $fileSeconds }
            if ($estimate.HaveBatch -and $batchSeconds -gt 0) { Add-EtaWindow $script:EtaBatchSamples $batchSeconds }
        }
    }
}

function Clear-EtaLine {
    $script:EtaProgress = $null
    $script:EtaChecking = $false
    Clear-EtaWindow
    Set-EtaText ''
}

function Test-EncodeProgressLine([string]$Line) {
    if ([string]::IsNullOrWhiteSpace($Line)) { return $false }
    if ($null -ne (Get-HandBrakeFraction $Line)) { return $true }
    return ($Line -match '(?i)^(Encoding|Muxing):.*\d+(?:\.\d+)?\s*%')
}

function Read-EncodeLines {
    if (-not $script:Lanes) { return }
    foreach ($lane in @($script:Lanes)) { Read-LaneLines $lane }
}

function Finish-Batch {
    param([string]$How)
    Stop-ActivityPulse
    if ($script:Lanes) {
        foreach ($lane in @($script:Lanes)) {
            try { if ($lane.Pump) { $lane.Pump.Stop() } } catch {}
            if ($lane.Item) { Release-EncodeHold $lane.Plan }
            $lane.Item = $null
            $lane.Plan = $null
        }
    }
    try { [VideoDehydrator.LinePump]::Stop() } catch {}
    Update-JobBars
    $script:Work = 'idle'
    $script:ForceEncode = $false
    Clear-EtaLine
    $script:Cancel = $false
    $script:StopAfterFile = $false
    Disable-KeepAwake
    Set-Progress 0
    $saved = Format-ByteSize $script:SavedBytes
    if ($How -eq 'stopped') {
        Set-Status 'Convert stopped' 'idle'
        Write-Activity 'Convert stopped. Finished files stay in place.' 'warn'
    }
    elseif ($How -eq 'after') {
        Set-Status 'Stopped after the current file' 'idle'
        Write-Activity 'This file finished. The rest of the batch was left for later.' 'warn'
    }
    else {
        Set-Status ("Finished. Saved $saved.") 'ok'
        Write-Activity ("Finished. Saved $saved.") 'ok'
        if (-not $script:AutoCheck.Checked) {
            Write-Activity 'Compare a file, then click Delete originals when it looks right.' 'text'
        }
    }
    Show-PendingRecycleProblems
    Update-BloatFolders
    if ($How -eq 'stopped' -or $How -eq 'after') {
        if ($script:ShutdownCheck -and $script:ShutdownCheck.Checked) {
            Write-Activity 'Convert was stopped, so the computer will stay on.' 'text'
        }
    }
    elseif ($script:HoldShutdownForRecycle) {
        $script:HoldShutdownForRecycle = $false
        if ($script:ShutdownCheck -and $script:ShutdownCheck.Checked) {
            Write-Activity 'The computer will stay on so the drive recycle bin can be cleared.' 'warn'
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
    Set-Tip $now 'Shut the computer down now.'
    Set-Tip $cancel 'Leave the computer on.'
    $form.Controls.Add($label)
    $form.Controls.Add($now)
    $form.Controls.Add($cancel)
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 1000
    $state = [pscustomobject]@{ Timer = $timer; Choice = 'cancel'; Seconds = 60 }
    $form.Tag = $state
    $timer.Add_Tick({
        $state.Seconds--
        if ($state.Seconds -le 0) {
            $timer.Stop()
            $state.Choice = 'now'
            $form.Close()
            return
        }
        $label.Text = "Convert finished. This computer will shut down in $($state.Seconds) seconds.`r`n`r`nCancel if you want to keep working. Open programs will close."
    }.GetNewClosure())
    $now.Add_Click({
        $timer.Stop()
        $state.Choice = 'now'
        $form.Close()
    }.GetNewClosure())
    $cancel.Add_Click({
        $timer.Stop()
        $state.Choice = 'cancel'
        $form.Close()
    }.GetNewClosure())
    $form.Add_KeyDown({
        if ($_.KeyCode -eq [Windows.Forms.Keys]::Escape) {
            $timer.Stop()
            $state.Choice = 'cancel'
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
    $secondsLeft = 0
    try {
        [void]$dialog.ShowDialog()
        $choice = [string]$dialog.Tag.Choice
        $secondsLeft = [int]$dialog.Tag.Seconds
    }
    catch {
        $choice = 'cancel'
        Write-Activity ("Could not show the shutdown countdown. " + $_.Exception.Message) 'err'
    }
    finally {
        $timer = $dialog.Tag.Timer
        if ($timer) { $timer.Stop(); $timer.Dispose() }
        $dialog.Dispose()
    }
    if ($choice -eq 'now') {
        Write-Activity 'Shutting down the computer.' 'text'
        Set-Status 'Shutting down...' 'busy'
        if ($secondsLeft -gt 0) {
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

function Test-AutoWarnPending {
    if ($script:AutoWarnAccepted) { return $false }
    if ($script:AutoWarnShown) { return $false }
    return $true
}

function Test-AutoWarnNeeded {
    if ($script:SmokeTest) { return $false }
    return (Test-AutoWarnPending)
}

function Apply-AutoWarnChoice([string]$Choice, [bool]$Hide) {
    if ($Choice -ne 'on') { return $false }
    $script:AutoWarnShown = $true
    if ($Hide) { $script:AutoWarnAccepted = $true }
    return $true
}

function New-AutoWarnForm {
    $form = New-Object Windows.Forms.Form
    $form.Text = 'Video Dehydrator'
    $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
    $form.StartPosition = 'CenterParent'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $false
    $form.KeyPreview = $true
    $form.ClientSize = New-Object Drawing.Size(520, 292)
    $form.Font = $script:FontUi
    $form.BackColor = [Drawing.Color]::White
    $icon = Get-AppIcon
    if ($icon) { $form.Icon = $icon }
    $label = New-Object Windows.Forms.Label
    $label.Font = $script:FontUi
    $label.ForeColor = $script:ColorInk
    $label.BackColor = [Drawing.Color]::White
    $label.SetBounds(24, 16, 472, 168)
    $label.Text = "Delete originals automatically removes each original as soon as its new file checks out.`r`n`r`nThe check looks at size, length, picture size, audio, subtitles, and whether the start and end play. It does not judge how the picture looks.`r`n`r`nAfter the original is deleted, Compare and Undo cannot bring it back."
    $hide = New-Check "Don't show this again"
    $hide.SetBounds(24, 196, 280, 24)
    $on = New-Button 'Turn auto on' 'primary' 140 34
    $off = New-Button 'Leave it off' 'secondary' 130 34
    $on.SetBounds(214, 236, 140, 34)
    $off.SetBounds(364, 236, 130, 34)
    Set-Tip $on 'Turn on Delete originals automatically.'
    Set-Tip $off 'Leave Delete originals automatically off.'
    $form.Controls.Add($label)
    $form.Controls.Add($hide)
    $form.Controls.Add($on)
    $form.Controls.Add($off)
    $state = [pscustomobject]@{ Choice = 'off'; Hide = $false }
    $form.Tag = $state
    $on.DialogResult = [Windows.Forms.DialogResult]::OK
    $off.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $form.AcceptButton = $on
    $form.CancelButton = $off
    $on.Add_Click({
        $state.Choice = 'on'
        $state.Hide = [bool]$hide.Checked
    }.GetNewClosure())
    $off.Add_Click({
        $state.Choice = 'off'
        $state.Hide = $false
    }.GetNewClosure())
    return $form
}

function Show-AutoWarn {
    if ($script:SmokeTest) { return 'on' }
    $form = New-AutoWarnForm
    $state = $form.Tag
    try { [void]$form.ShowDialog($script:Form) }
    finally { $form.Dispose() }
    $hide = $false
    if ($state.Choice -eq 'on') { $hide = [bool]$state.Hide }
    if (Apply-AutoWarnChoice ([string]$state.Choice) $hide) { return 'on' }
    return 'off'
}

function Set-AutoOff {
    $script:AutoWarnBusy = $true
    try { $script:AutoCheck.Checked = $false }
    finally { $script:AutoWarnBusy = $false }
}

function Update-AutoChoice {
    if ($script:Loading -or $script:AutoWarnBusy) { return }
    if ($script:AutoCheck.Checked -and (Test-AutoWarnNeeded)) {
        if ((Show-AutoWarn) -ne 'on') { Set-AutoOff }
    }
    Save-Settings
}

function Begin-ConvertBatch {
    param($Items, [bool]$Force)
    if ($script:Work -ne 'idle') { return }
    $items = @($Items)
    if ($items.Count -eq 0) { return }
    if ($script:AutoCheck.Checked -and (Test-AutoWarnNeeded)) {
        if ((Show-AutoWarn) -ne 'on') {
            Set-AutoOff
            Save-Settings
            return
        }
        Save-Settings
    }
    if ($script:AutoCheck.Checked) {
        if (-not (Show-AutoAsk)) { return }
    }
    Stop-Playback
    Save-Settings
    $script:ForceEncode = $Force
    $script:ConvertBatchId = [guid]::NewGuid().ToString('n')
    Clear-RecycleResults
    $script:HoldShutdownForRecycle = $false
    $script:Cancel = $false
    $script:StopAfterFile = $false
    $script:SavedBytes = [int64]0
    $script:EncodeItems = $items
    $script:EncodeIndex = 0
    $script:Work = 'encode'
    Update-Buttons
    Enable-KeepAwake
    $word = if ($items.Count -eq 1) { 'file' } else { 'files' }
    $verb = 'Converting'
    if ($Force) { $verb = 'Forcing' }
    Write-Activity ("$verb $($items.Count) $word.") 'text'
    $jobCount = Get-JobCount
    if ($jobCount -gt 1 -and $items.Count -gt 1) {
        $running = $jobCount
        if ($running -gt $items.Count) { $running = $items.Count }
        Write-Activity ("Parallel jobs is $jobCount. Up to $running files encode at the same time.") 'text'
    }
    if ($Force) { Write-Activity 'The scanned list was replaced. Files still waiting in .vd-originals stay.' 'text' }
    if ($script:ReencodeCheck.Checked) {
        Write-Activity 'Audio that cannot be copied will be re-encoded to AAC. Other audio is still copied.' 'text'
    }
    if ($script:ShutdownCheck.Checked) {
        Write-Activity 'The computer will shut down when this convert finishes.' 'text'
    }
    Start-NextEncode
}

function Start-Convert {
    if ($script:Work -ne 'idle') { return }
    $items = @(Get-CheckedItems @('Bloated', 'Can shrink', 'Failed', 'Skipped'))
    if ($items.Count -eq 0) { return }
    Begin-ConvertBatch $items $false
}

function Get-ForceStartPath {
    if ($script:Files -and $script:Files.SelectedItems.Count -eq 1) {
        $tag = $script:Files.SelectedItems[0].Tag
        $path = ''
        if ($tag) { $path = [string]$tag.Source }
        if (-not $path -and $tag) { $path = [string]$tag.Path }
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $path }
    }
    if ($script:FolderBox) { return ([string]$script:FolderBox.Text).Trim() }
    return ''
}

function New-ForcePickForm {
    $form = New-Object Windows.Forms.Form
    $form.Text = 'Video Dehydrator'
    $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
    $form.StartPosition = 'CenterParent'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $false
    $form.KeyPreview = $true
    $form.ClientSize = New-Object Drawing.Size(560, 268)
    $form.Font = $script:FontUi
    $form.BackColor = [Drawing.Color]::White
    $icon = Get-AppIcon
    if ($icon) { $form.Icon = $icon }
    $label = New-Object Windows.Forms.Label
    $label.Font = $script:FontUi
    $label.ForeColor = $script:ColorInk
    $label.BackColor = [Drawing.Color]::White
    $label.SetBounds(20, 16, 520, 88)
    $label.Text = "Manual converts a file or a folder even when Scan would leave it alone. Test savings reads the files and estimates the new size. It does not encode. Convert now starts immediately. A result that is not smaller is thrown away."
    $path = New-Object Windows.Forms.TextBox
    $path.Font = $script:FontUi
    $path.SetBounds(20, 112, 400, 26)
    $path.Text = Get-ForceStartPath
    $fileBtn = New-Button 'Browse file' 'secondary' 120 30
    $folderBtn = New-Button 'Browse folder' 'secondary' 120 30
    $fileBtn.SetBounds(428, 110, 112, 30)
    $folderBtn.SetBounds(428, 146, 112, 30)
    $subs = New-Check 'Include subfolders'
    $subs.SetBounds(20, 150, 220, 24)
    $subs.Checked = $false
    if ($path.Text -and (Test-Path -LiteralPath $path.Text -PathType Container)) {
        $subs.Checked = [bool]$script:SubfoldersCheck.Checked
    }
    $test = New-Button 'Test savings' 'primary' 140 34
    $now = New-Button 'Convert now' 'secondary' 140 34
    $cancel = New-Button 'Cancel' 'secondary' 110 34
    $test.SetBounds(20, 210, 140, 34)
    $now.SetBounds(168, 210, 140, 34)
    $cancel.SetBounds(316, 210, 110, 34)
    Set-Tip $test 'Read the files and show the estimated savings. Nothing is encoded yet.'
    Set-Tip $now 'Convert without the savings estimate.'
    Set-Tip $cancel 'Leave the files alone.'
    Set-Tip $subs 'Also convert videos in folders inside this folder.'
    $form.Controls.AddRange(@($label, $path, $fileBtn, $folderBtn, $subs, $test, $now, $cancel))
    $state = [pscustomobject]@{ Choice = 'cancel'; Path = ''; Recurse = $false }
    $form.Tag = $state
    $form.CancelButton = $cancel
    $fileBtn.Add_Click({
        $dlg = New-Object Windows.Forms.OpenFileDialog
        $dlg.Title = 'Choose a video to force'
        $dlg.Filter = 'Video files|*.mkv;*.mp4;*.avi;*.m4v;*.mov;*.wmv;*.mpg;*.mpeg;*.ts;*.m2ts;*.vob;*.webm;*.flv;*.divx|All files|*.*'
        if ($path.Text -and (Test-Path -LiteralPath $path.Text -PathType Leaf)) { $dlg.FileName = $path.Text }
        if ($dlg.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) { $path.Text = $dlg.FileName }
    }.GetNewClosure())
    $folderBtn.Add_Click({
        $dlg = New-Object Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Choose a folder to force'
        $dlg.ShowNewFolderButton = $false
        if ($path.Text -and (Test-Path -LiteralPath $path.Text -PathType Container)) { $dlg.SelectedPath = $path.Text }
        if ($dlg.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) { $path.Text = $dlg.SelectedPath }
    }.GetNewClosure())
    $test.Add_Click({
        $state.Choice = 'test'
        $state.Path = [string]$path.Text
        $state.Recurse = [bool]$subs.Checked
        $form.Close()
    }.GetNewClosure())
    $now.Add_Click({
        $state.Choice = 'convert'
        $state.Path = [string]$path.Text
        $state.Recurse = [bool]$subs.Checked
        $form.Close()
    }.GetNewClosure())
    $cancel.Add_Click({
        $state.Choice = 'cancel'
        $form.Close()
    }.GetNewClosure())
    return $form
}

function New-ForceReportForm {
    param([string]$Report, [bool]$CanProceed)
    $form = New-Object Windows.Forms.Form
    $form.Text = 'Video Dehydrator'
    $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
    $form.StartPosition = 'CenterParent'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $false
    $form.KeyPreview = $true
    $form.ClientSize = New-Object Drawing.Size(560, 400)
    $form.Font = $script:FontUi
    $form.BackColor = [Drawing.Color]::White
    $icon = Get-AppIcon
    if ($icon) { $form.Icon = $icon }
    $box = New-Object Windows.Forms.TextBox
    $box.Multiline = $true
    $box.ReadOnly = $true
    $box.ScrollBars = 'Vertical'
    $box.Font = $script:FontUi
    $box.SetBounds(20, 16, 520, 300)
    $box.Text = $Report
    $proceed = New-Button 'Proceed' 'primary' 120 34
    $cancel = New-Button 'Cancel' 'secondary' 110 34
    $proceed.SetBounds(300, 340, 120, 34)
    $cancel.SetBounds(428, 340, 110, 34)
    $proceed.Enabled = $CanProceed
    Set-Tip $proceed 'Convert these files.'
    Set-Tip $cancel 'Do not convert.'
    $form.Controls.AddRange(@($box, $proceed, $cancel))
    $state = [pscustomobject]@{ Proceed = $false }
    $form.Tag = $state
    $form.CancelButton = $cancel
    $proceed.Add_Click({
        $state.Proceed = $true
        $form.Close()
    }.GetNewClosure())
    $cancel.Add_Click({
        $state.Proceed = $false
        $form.Close()
    }.GetNewClosure())
    return $form
}

function Show-ForceReport {
    param([string]$Report, [bool]$CanProceed)
    if ($script:SmokeTest) { return $false }
    $form = New-ForceReportForm $Report $CanProceed
    $state = $form.Tag
    try { [void]$form.ShowDialog($script:Form) }
    finally { if (-not $form.IsDisposed) { $form.Dispose() } }
    return [bool]$state.Proceed
}

function Add-ForceRows {
    param($Files, [bool]$OnlyConvertible)
    Clear-ScanRows
    $added = New-Object System.Collections.Generic.List[object]
    $pending = New-Object System.Collections.ArrayList
    if ($null -eq $Files) { }
    elseif (($Files -is [System.Collections.IEnumerable]) -and -not ($Files -is [string])) {
        foreach ($row in $Files) { if ($null -ne $row) { [void]$pending.Add($row) } }
    }
    else { [void]$pending.Add($Files) }
    foreach ($file in $pending) {
        if ($null -eq $file) { continue }
        if ($OnlyConvertible -and -not [bool]$file.CanConvert) { continue }
        $path = [string]$file.Path
        if (-not $path) { continue }
        $estimate = $null
        if ($null -ne $file.EstimateBytes -and [string]$file.EstimateBytes -ne '') { $estimate = [int64]$file.EstimateBytes }
        $videoBits = [int64]0
        if ($null -ne $file.VideoBitrate -and [string]$file.VideoBitrate -ne '') { $videoBits = [int64]$file.VideoBitrate }
        $gib = $null
        if ($null -ne $file.GiBph -and [string]$file.GiBph -ne '') { $gib = [double]$file.GiBph }
        $budget = $null
        if ($null -ne $file.BudgetGiBph -and [string]$file.BudgetGiBph -ne '') { $budget = [double]$file.BudgetGiBph }
        $tag = @{
            Status = 'Forced'
            Path = $path
            Kept = ''
            New = ''
            Source = $path
            Width = [int]$file.Width
            Height = [int]$file.Height
            DurationSec = [double]$file.DurationSec
            SizeBytes = [int64]$file.SizeBytes
            OldBytes = $null
            GiBph = $gib
            BudgetGiBph = $budget
            TargetKbps = [int]$file.TargetKbps
            EstimateBytes = $estimate
            EstimateRough = [bool]$file.EstimateRough
            VideoBitrate = $videoBits
            Codec = [string]$file.Codec
            PendingId = ''
            Reason = ''
        }
        if ($file.PSObject.Properties.Name -contains 'TenBit') { $tag.TenBit = [bool]$file.TenBit }
        $item = Add-ResultRow $tag
        if ($item) { [void]$added.Add($item) }
    }
    return @($added.ToArray())
}

function Read-ForceQueue {
    if (-not $script:ScanQueue) { return }
    $line = $null
    while ($script:ScanQueue.TryDequeue([ref]$line)) {
        if (-not $line) { continue }
        $msg = $null
        try { $msg = $line | ConvertFrom-Json } catch { continue }
        if ($msg.Kind -eq 'progress') {
            Set-Status ("Reading $($msg.Seen) - $($msg.Name)") 'busy'
        }
        elseif ($msg.Kind -eq 'file') {
            [void]$script:ForceFiles.Add($msg)
        }
        elseif ($msg.Kind -eq 'done') {
            $script:ForceSummary = $msg
        }
    }
}

function Finish-ForceWalk {
    $mode = [string]$script:ForceMode
    $files = @()
    if ($script:ForceFiles) { $files = $script:ForceFiles.ToArray() }
    $summary = $script:ForceSummary
    Complete-ScanRuntime -Label 'Force'
    if ($summary -and [bool]$summary.Cancelled) {
        Set-Status 'Force cancelled' 'idle'
        Write-Activity 'Force was cancelled before converting.' 'warn'
        return
    }
    if ($summary -and $summary.Samples) { Write-Activity ([string]$summary.Samples) 'warn' }
    $ready = @($files | Where-Object { $_ -and [bool]$_.CanConvert })
    if ($mode -eq 'test') {
        $report = Format-ForceReport $files
        if (-not (Show-ForceReport $report ($ready.Count -gt 0))) {
            Set-Status 'Ready' 'idle'
            Write-Activity 'Force was cancelled after the savings estimate.' 'text'
            return
        }
        $items = @(Add-ForceRows $files $true)
        Begin-ConvertBatch $items $true
        return
    }
    if ($ready.Count -eq 0) {
        Set-Status 'Nothing to force' 'idle'
        Write-Activity 'Nothing in that path can be converted.' 'warn'
        return
    }
    $items = @(Add-ForceRows $files $false)
    Begin-ConvertBatch $items $true
}

function Start-ForceWalk {
    param([string]$Path, [bool]$Recurse, [string]$Mode)
    if ($script:Work -ne 'idle') { return }
    $picked = $Path.Trim()
    if (-not $picked -or -not (Test-Path -LiteralPath $picked)) {
        [Windows.Forms.MessageBox]::Show($script:Form, 'Choose a file or folder that is on this computer.', 'Video Dehydrator', 'OK', 'Information') | Out-Null
        return
    }
    $script:Cancel = $false
    $script:ScanCancel = @{ Stop = $false }
    $script:ScanQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $script:ForceFiles = New-Object System.Collections.Generic.List[object]
    $script:ForceSummary = $null
    $script:ForceMode = $Mode
    $script:Work = 'force'
    Update-Buttons
    Enable-KeepAwake
    Set-Status 'Reading videos...' 'busy'
    Set-Progress 0
    $verb = 'Estimating savings in'
    if ($Mode -eq 'convert') { $verb = 'Listing' }
    Write-Activity ($verb + ' ' + $picked) 'text'
    $probe = ($Mode -eq 'test')
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $script:ScanRunspace = $rs
    $script:ScanPower = $ps
    $null = $ps.AddScript({
        param($EnginePath, $Root, $WalkRecurse, $WalkProbe, $Ffprobe, $Queue, $Cancel, $Budgets)
        . $EnginePath
        Set-BudgetPicks $Budgets
        Invoke-ForceWalk -Path $Root -Recurse $WalkRecurse -ProbeFiles $WalkProbe -Ffprobe $Ffprobe -Queue $Queue -Cancel $Cancel
    }).AddArgument($script:EnginePath).AddArgument($picked).AddArgument([bool]$Recurse).AddArgument([bool]$probe).AddArgument($script:Ffprobe).AddArgument($script:ScanQueue).AddArgument($script:ScanCancel).AddArgument((Get-SelectedBudgetPack))
    $script:ScanHandle = $ps.BeginInvoke()
}

function Start-Force {
    if ($script:Work -ne 'idle') { return }
    $form = New-ForcePickForm
    $state = $form.Tag
    try { [void]$form.ShowDialog($script:Form) }
    finally { if (-not $form.IsDisposed) { $form.Dispose() } }
    if ($state.Choice -eq 'cancel') { return }
    Start-ForceWalk -Path ([string]$state.Path) -Recurse ([bool]$state.Recurse) -Mode ([string]$state.Choice)
}

function Request-Cancel {
    if ($script:Work -eq 'idle') { return }
    $script:Cancel = $true
    $script:StopAfterFile = $false
    Set-Status 'Stopping...' 'busy'
    if (($script:Work -eq 'scan' -or $script:Work -eq 'force') -and $script:ScanCancel) { $script:ScanCancel.Stop = $true }
    if ($script:Work -eq 'encode') {
        [VideoDehydrator.LinePump]::Kill()
        if ($script:Lanes) {
            foreach ($lane in @($script:Lanes)) {
                try { if ($lane.Pump) { $lane.Pump.Kill() } } catch {}
            }
        }
    }
    Stop-ChildTools
    Update-Buttons
}

function Request-StopAfterFile {
    if ($script:Work -ne 'encode' -or $script:StopAfterFile -or $script:Cancel) { return }
    $script:StopAfterFile = $true
    Write-Activity 'The files already encoding will finish. The batch will stop after that.' 'warn'
    Set-Status 'Stopping after the current file' 'busy'
    Update-EtaLine
    Update-Buttons
}

function Request-ContinueBatch {
    if ($script:Work -ne 'encode' -or -not $script:StopAfterFile) { return }
    $script:StopAfterFile = $false
    Write-Activity 'The batch will keep going.' 'text'
    Set-Status 'Converting' 'busy'
    Update-EtaLine
    Update-Buttons
}

function Write-NewRecycleActivity {
    if (-not $script:RecycleResults) { return }
    if (-not $script:RecycleLogOnce) { $script:RecycleLogOnce = @{} }
    foreach ($row in @($script:RecycleResults.ToArray())) {
        if (-not $row -or $row.Reported) { continue }
        $row.Reported = $true
        if ($row.Status -eq 'skipped') { continue }
        $key = [string]$row.Status + '|' + [string]$row.Message
        if ($row.Status -eq 'absent') {
            if ($script:RecycleLogOnce.Contains($key)) { continue }
            $script:RecycleLogOnce[$key] = $true
            Write-Activity ([string]$row.Message) 'text'
            continue
        }
        $kind = 'warn'
        if ($row.Status -eq 'purged') { $kind = 'ok' }
        elseif ($row.Status -eq 'denied' -or $row.Status -eq 'failed' -or $row.Status -eq 'remained') { $kind = 'err' }
        Write-Activity ([string]$row.Message) $kind
    }
}

function Get-UnshownRecycleProblems {
    if (-not $script:RecycleResults) { return @() }
    $bad = @('missing', 'denied', 'mismatch', 'failed', 'remained')
    return @($script:RecycleResults.ToArray() | Where-Object { $_ -and -not $_.Shown -and ($bad -contains [string]$_.Status) })
}

function Format-RecycleProblemText($Problems) {
    $lines = New-Object System.Collections.Generic.List[string]
    $shown = @($Problems | Select-Object -First 8)
    foreach ($row in $shown) {
        [void]$lines.Add([string]$row.Name)
        [void]$lines.Add([string]$row.Message)
        if ($row.RecycleFile) { [void]$lines.Add([string]$row.RecycleFile) }
        [void]$lines.Add('')
    }
    $extra = @($Problems).Count - @($shown).Count
    if ($extra -gt 0) { [void]$lines.Add('and ' + $extra + ' more.') }
    return ($lines.ToArray() -join "`r`n").Trim()
}

function New-RecycleProblemForm($Problems) {
    $form = New-Object Windows.Forms.Form
    $form.Text = 'Video Dehydrator'
    $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
    $form.StartPosition = 'CenterParent'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $false
    $form.KeyPreview = $true
    $form.ClientSize = New-Object Drawing.Size(560, 500)
    $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::None
    $form.Font = $script:FontUi
    $form.BackColor = [Drawing.Color]::White
    $icon = Get-AppIcon
    if ($icon) { $form.Icon = $icon }
    $intro = New-Object Windows.Forms.Label
    $intro.Font = $script:FontUi
    $intro.ForeColor = $script:ColorInk
    $intro.BackColor = [Drawing.Color]::White
    $intro.SetBounds(24, 16, 512, 210)
    $intro.Text = "The original is already deleted from the library. The drive recycle bin may still have a copy, and the program could not remove it.`r`n`r`nThe link below opens the manual steps. Those steps remove only .vd-originals folders inside #recycle. A share that does not keep a recycle bin can show this same window, and then there is nothing to remove.`r`n`r`nMute hides this window after this one time. The activity list still records a later failure, and the steps stay in How this works."
    $detail = New-Object Windows.Forms.TextBox
    $detail.Multiline = $true
    $detail.ReadOnly = $true
    $detail.ScrollBars = 'Vertical'
    $detail.Font = $script:FontUi
    $detail.SetBounds(24, 234, 512, 128)
    $detail.Text = Format-RecycleProblemText $Problems
    $link = New-Object Windows.Forms.LinkLabel
    $link.Text = 'Show the manual deletion steps'
    $link.Font = $script:FontUi
    $link.LinkColor = [Drawing.Color]::FromArgb(37, 99, 235)
    $link.ActiveLinkColor = [Drawing.Color]::FromArgb(29, 78, 216)
    $link.AutoSize = $true
    $link.Location = New-Object Drawing.Point(24, 374)
    $mute = New-Button 'Mute' 'secondary' 110 34
    $mute.SetBounds(308, 446, 110, 34)
    $close = New-Button 'Close' 'secondary' 110 34
    $close.SetBounds(426, 446, 110, 34)
    Set-Tip $mute 'Hide this window after this one time.'
    Set-Tip $close 'Close this list. It opens again next time.'
    $form.Controls.Add($intro)
    $form.Controls.Add($detail)
    $form.Controls.Add($link)
    $form.Controls.Add($mute)
    $form.Controls.Add($close)
    $state = [pscustomobject]@{ OpenHelp = $false; Mute = $false }
    $form.Tag = $state
    $close.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $form.CancelButton = $close
    $link.Add_LinkClicked({
        $state.OpenHelp = $true
        $form.Close()
    }.GetNewClosure())
    $mute.Add_Click({
        $state.Mute = $true
        $form.Close()
    }.GetNewClosure())
    return $form
}

function Complete-RecycleMute([bool]$Mute) {
    if (-not $Mute) { return }
    $script:RecycleAlertMuted = $true
    Save-Settings
}

function Show-PendingRecycleProblems {
    Write-NewRecycleActivity
    if ($script:SmokeTest) { return }
    $script:HoldShutdownForRecycle = $false
    $problems = @(Get-UnshownRecycleProblems)
    if ($problems.Count -eq 0) { return }
    foreach ($row in $problems) { $row.Shown = $true }
    if ($script:RecycleAlertMuted) { return }
    $form = New-RecycleProblemForm $problems
    $state = $form.Tag
    try { [void]$form.ShowDialog($script:Form) }
    finally { if (-not $form.IsDisposed) { $form.Dispose() } }
    if ($state.Mute) { Complete-RecycleMute $true }
    if ($state.OpenHelp) {
        $script:HoldShutdownForRecycle = $true
        Show-Help -Section 'Drive recycle bin'
    }
}

function Test-AutoAskHidden {
    return (-not [bool]$script:AutoAsk)
}

function Complete-AutoAsk([bool]$Convert, [bool]$Hide) {
    if (-not $Convert) { return $false }
    if ($Hide) {
        $script:AutoAsk = $false
        Save-Settings
    }
    return $true
}

function New-AutoAskForm {
    $form = New-Object Windows.Forms.Form
    $form.Text = 'Video Dehydrator'
    $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
    $form.StartPosition = 'CenterParent'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $false
    $form.KeyPreview = $true
    $form.ClientSize = New-Object Drawing.Size(540, 326)
    $form.Font = $script:FontUi
    $form.BackColor = [Drawing.Color]::White
    $icon = Get-AppIcon
    if ($icon) { $form.Icon = $icon }
    $label = New-Object Windows.Forms.Label
    $label.Font = $script:FontUi
    $label.ForeColor = $script:ColorInk
    $label.BackColor = [Drawing.Color]::White
    $label.SetBounds(24, 16, 492, 176)
    $label.Text = "Auto is on.`r`n`r`nAfter each file checks out, its original is deleted. The new file stays in the original's place. There will be nothing left to compare. When Clear the drive recycle copy is on, the matching copy in #recycle is removed when the path and the size match. The .plexignore from that convert is removed when it only hides the holding folder."
    $hide = New-Check 'Stop asking'
    $hide.SetBounds(24, 204, 492, 24)
    $convert = New-Button 'Convert' 'primary' 140 34
    $cancel = New-Button 'Cancel' 'secondary' 110 34
    $convert.SetBounds(258, 268, 140, 34)
    $cancel.SetBounds(406, 268, 110, 34)
    Set-Tip $convert 'Convert, and delete each original after it checks out.'
    Set-Tip $cancel 'Leave the files alone.'
    Set-Tip $hide 'Stop opening this warning. Cancel leaves it on.'
    $form.Controls.Add($label)
    $form.Controls.Add($hide)
    $form.Controls.Add($convert)
    $form.Controls.Add($cancel)
    $state = [pscustomobject]@{ Convert = $false; Hide = $false }
    $form.Tag = $state
    $convert.DialogResult = [Windows.Forms.DialogResult]::OK
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $form.AcceptButton = $convert
    $form.CancelButton = $cancel
    $convert.Add_Click({
        $state.Convert = $true
        $state.Hide = [bool]$hide.Checked
    }.GetNewClosure())
    $cancel.Add_Click({
        $state.Convert = $false
        $state.Hide = $false
    }.GetNewClosure())
    return $form
}

function Show-AutoAsk {
    if (Test-AutoAskHidden) { return $true }
    $form = New-AutoAskForm
    $state = $form.Tag
    try { [void]$form.ShowDialog($script:Form) }
    finally { if (-not $form.IsDisposed) { $form.Dispose() } }
    return (Complete-AutoAsk ([bool]$state.Convert) ([bool]$state.Hide))
}

function Test-DeleteConfirmHidden {
    $saved = [string]$script:DeleteConfirmVersion
    if ([string]::IsNullOrWhiteSpace($saved)) { return $false }
    $cmp = Compare-AppVersion $saved (Get-AppVersion)
    if ($null -eq $cmp) { return $false }
    return ($cmp -eq 0)
}

function Complete-DeleteConfirm([bool]$Delete, [bool]$Hide) {
    if (-not $Delete) { return $false }
    if ($Hide) {
        $script:DeleteConfirmVersion = Get-AppVersion
        Save-Settings
    }
    return $true
}

function New-DeleteConfirmForm([int]$Count) {
    $word = if ($Count -eq 1) { 'original' } else { 'originals' }
    $form = New-Object Windows.Forms.Form
    $form.Text = 'Video Dehydrator'
    $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
    $form.StartPosition = 'CenterParent'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $false
    $form.KeyPreview = $true
    $form.ClientSize = New-Object Drawing.Size(540, 320)
    $form.Font = $script:FontUi
    $form.BackColor = [Drawing.Color]::White
    $icon = Get-AppIcon
    if ($icon) { $form.Icon = $icon }
    $label = New-Object Windows.Forms.Label
    $label.Font = $script:FontUi
    $label.ForeColor = $script:ColorInk
    $label.BackColor = [Drawing.Color]::White
    $label.SetBounds(24, 16, 492, 168)
    $label.Text = "Delete $Count $word?`r`n`r`nThe new smaller files stay where the originals were. When Clear the drive recycle copy is on, the matching copy in #recycle is removed when the path and the size match. The .plexignore from that convert is removed when it only hides the holding folder."
    $hide = New-Check "Don't show this in the future"
    $hide.SetBounds(24, 196, 492, 24)
    $hint = New-Object Windows.Forms.Label
    $hint.Font = $script:FontHint
    $hint.ForeColor = $script:ColorMuted
    $hint.BackColor = [Drawing.Color]::White
    $hint.SetBounds(24, 224, 492, 28)
    $hint.Text = 'This question comes back when a new version of the program is installed.'
    $delete = New-Button 'Delete' 'primary' 140 34
    $cancel = New-Button 'Cancel' 'secondary' 110 34
    $delete.SetBounds(258, 264, 140, 34)
    $cancel.SetBounds(406, 264, 110, 34)
    Set-Tip $delete 'Delete the checked originals that are waiting in .vd-originals.'
    Set-Tip $cancel 'Keep the originals.'
    $form.Controls.Add($label)
    $form.Controls.Add($hide)
    $form.Controls.Add($hint)
    $form.Controls.Add($delete)
    $form.Controls.Add($cancel)
    $state = [pscustomobject]@{ Delete = $false; Hide = $false }
    $form.Tag = $state
    $delete.DialogResult = [Windows.Forms.DialogResult]::OK
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $form.AcceptButton = $delete
    $form.CancelButton = $cancel
    $delete.Add_Click({
        $state.Delete = $true
        $state.Hide = [bool]$hide.Checked
    }.GetNewClosure())
    $cancel.Add_Click({
        $state.Delete = $false
        $state.Hide = $false
    }.GetNewClosure())
    return $form
}

function Show-DeleteConfirm([int]$Count) {
    if (Test-DeleteConfirmHidden) { return $true }
    $form = New-DeleteConfirmForm $Count
    $state = $form.Tag
    try { [void]$form.ShowDialog($script:Form) }
    finally { if (-not $form.IsDisposed) { $form.Dispose() } }
    return (Complete-DeleteConfirm ([bool]$state.Delete) ([bool]$state.Hide))
}

function Remove-CheckedOriginals {
    $items = @(Get-CheckedItems @('Ready to delete'))
    if ($items.Count -eq 0) { return }
    if (-not (Show-DeleteConfirm $items.Count)) { return }
    Clear-RecycleResults
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
            Write-NewRecycleActivity
        }
        catch {
            Write-Activity ("Could not delete " + [IO.Path]::GetFileName([string]$tag.Kept) + "  " + $_.Exception.Message) 'err'
        }
    }
    Write-Pending $pending
    Set-Status "Deleted $removed originals." 'ok'
    Update-Buttons
    Show-PendingRecycleProblems
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
    Clear-RecycleResults
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
                $item.Tag.OldBytes = $null
                $item.Tag.Reason = 'The original was put back and the new file was deleted.'
                $item.Checked = $false
                Update-ResultRow $item
            }
            Add-RunLog -Status 'UNDONE' -Reason 'ok' -Source ([string]$row.source) -NewPath ([string]$row.new) -Kept ([string]$row.kept) -OldBytes $row.oldBytes -NewBytes $row.newBytes -OldRate $null -NewRate $null -Width $row.width -Height $row.height -Kbps $row.targetKbps
            $restored++
            Write-Activity ("Restored  $sourceName") 'ok'
            Write-NewRecycleActivity
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
    Show-PendingRecycleProblems
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
        elseif ($script:Work -eq 'force') {
            Read-ForceQueue
            if ($script:ScanHandle -and $script:ScanHandle.IsCompleted) {
                Read-ForceQueue
                Finish-ForceWalk
            }
        }
        elseif ($script:Work -eq 'encode') {
            Read-EncodeLines
            Update-ActivityPulse
            if ($script:Lanes) {
                $finished = @()
                foreach ($lane in @($script:Lanes)) {
                    if ($lane.Item -and $lane.Pump -and $lane.Pump.Exited) { $finished += $lane }
                }
                foreach ($lane in $finished) {
                    if ($lane.Item -and $lane.Pump -and $lane.Pump.Exited) { Complete-ActiveEncode $lane }
                }
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
            if ($script:Lanes) {
                foreach ($lane in @($script:Lanes)) {
                    try { if ($lane.Pump) { $lane.Pump.Stop() } } catch {}
                    Release-EncodeHold $lane.Plan
                    $lane.Item = $null
                    $lane.Plan = $null
                }
            }
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

function Test-UpdateBusy {
    return ($script:Work -ne 'idle')
}

function Remove-VersionPrefix([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    $clean = $text.Trim()
    if (($clean.StartsWith('v') -or $clean.StartsWith('V')) -and $clean.Length -gt 1) {
        $rest = $clean.Substring(1)
        if ($rest -match '^\d+\.\d+\.\d+(\.\d+)?$') { return $rest }
    }
    return $clean
}

function ConvertTo-VersionNumbers([string]$text) {
    $clean = ''
    if ($null -ne $text) { $clean = $text.Trim() }
    if ($clean -match '^(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?$') {
        $numbers = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
        $fourth = [string]$Matches[4]
        if ($fourth -match '^\d+$') { $numbers += [int]$fourth }
        return ,$numbers
    }
    return $null
}

function Compare-AppVersion([string]$left, [string]$right) {
    $a = ConvertTo-VersionNumbers (Remove-VersionPrefix $left)
    $b = ConvertTo-VersionNumbers (Remove-VersionPrefix $right)
    if ($null -eq $a -or $null -eq $b) { return $null }
    $count = [Math]::Max($a.Count, $b.Count)
    for ($i = 0; $i -lt $count; $i++) {
        $leftNumber = 0
        $rightNumber = 0
        if ($i -lt $a.Count) { $leftNumber = $a[$i] }
        if ($i -lt $b.Count) { $rightNumber = $b[$i] }
        if ($leftNumber -gt $rightNumber) { return 1 }
        if ($leftNumber -lt $rightNumber) { return -1 }
    }
    return 0
}

function Get-WindowsLabel {
    $build = 0
    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        [void][int]::TryParse([string]$cv.CurrentBuild, [ref]$build)
    } catch { }
    $name = 'Windows'
    if ($build -ge 22000) { $name = 'Windows 11' }
    elseif ($build -ge 10240) { $name = 'Windows 10' }
    if ($build -gt 0) { return "$name (build $build)" }
    return $name
}

function Get-LatestActivityText {
    param([int]$MaxEncoded = 4500)
    if ($null -eq $script:Log) { return '' }
    $raw = [string]$script:Log.Text
    if ([string]::IsNullOrWhiteSpace($raw)) { return '' }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($raw -split '\r?\n')) {
        if ($line -ne '') { [void]$lines.Add($line) }
    }
    if ($lines.Count -eq 0) { return '' }
    $last = [string]$lines[$lines.Count - 1]
    if ($last -match '^Working  [|/\-\\]$') { $lines.RemoveAt($lines.Count - 1) }
    if ($lines.Count -eq 0) { return '' }
    $kept = New-Object System.Collections.Generic.List[string]
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $candidate = New-Object System.Collections.Generic.List[string]
        [void]$candidate.Add([string]$lines[$i])
        foreach ($older in $kept) { [void]$candidate.Add([string]$older) }
        $text = [string]::Join("`n", $candidate.ToArray())
        if (([uri]::EscapeDataString($text)).Length -le $MaxEncoded) {
            $kept.Insert(0, [string]$lines[$i])
            continue
        }
        if ($kept.Count -eq 0) {
            $line = [string]$lines[$i]
            $low = 0
            $high = $line.Length
            while ($low -lt $high) {
                $mid = [int](($low + $high + 1) / 2)
                $slice = $line.Substring($line.Length - $mid)
                if (([uri]::EscapeDataString($slice)).Length -le $MaxEncoded) { $low = $mid } else { $high = $mid - 1 }
            }
            if ($low -gt 0) { return $line.Substring($line.Length - $low) }
        }
        break
    }
    if ($kept.Count -eq 0) { return '' }
    return [string]::Join("`n", $kept.ToArray())
}

function Get-BugReportUrl {
    param([string]$Activity = '')
    $version = [uri]::EscapeDataString((Get-AppVersion))
    $windows = [uri]::EscapeDataString((Get-WindowsLabel))
    $url = "https://github.com/philipvern-dot/video-dehydrator/issues/new?template=bug_report.yml&version=$version&windows=$windows"
    if (-not [string]::IsNullOrWhiteSpace($Activity)) {
        $url = $url + '&activity=' + [uri]::EscapeDataString($Activity)
    }
    return $url
}

function New-BugReportForm {
    $form = New-Object Windows.Forms.Form
    $form.Text = 'Video Dehydrator'
    $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
    $form.StartPosition = 'CenterParent'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $false
    $form.KeyPreview = $true
    $form.ClientSize = New-Object Drawing.Size(520, 262)
    $form.Font = $script:FontUi
    $form.BackColor = [Drawing.Color]::White
    $icon = Get-AppIcon
    if ($icon) { $form.Icon = $icon }
    $label = New-Object Windows.Forms.Label
    $label.Font = $script:FontUi
    $label.ForeColor = $script:ColorInk
    $label.BackColor = [Drawing.Color]::White
    $label.SetBounds(24, 16, 472, 128)
    $label.Text = "Report a bug opens a GitHub page. This version and the Windows version are filled in. Nothing else is added unless you check the box.`r`n`r`nInclude latest activity adds the latest lines from the activity box to that page. Those lines can include folder paths. This program does not send the report. You submit it on the GitHub page."
    $include = New-Check 'Include latest activity'
    $include.Checked = $false
    $include.Enabled = -not [string]::IsNullOrWhiteSpace((Get-LatestActivityText))
    $include.SetBounds(24, 156, 280, 24)
    $open = New-Button 'Open report' 'primary' 140 34
    $cancel = New-Button 'Cancel' 'secondary' 110 34
    $open.SetBounds(238, 204, 140, 34)
    $cancel.SetBounds(386, 204, 110, 34)
    Set-Tip $open 'Open the GitHub page with this version filled in.'
    Set-Tip $cancel 'Close this window without opening GitHub.'
    $form.Controls.Add($label)
    $form.Controls.Add($include)
    $form.Controls.Add($open)
    $form.Controls.Add($cancel)
    $state = [pscustomobject]@{ Open = $false; Include = $false }
    $form.Tag = $state
    $open.DialogResult = [Windows.Forms.DialogResult]::OK
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $form.AcceptButton = $open
    $form.CancelButton = $cancel
    $open.Add_Click({
        $state.Open = $true
        $state.Include = [bool]$include.Checked
    }.GetNewClosure())
    $cancel.Add_Click({
        $state.Open = $false
        $state.Include = $false
    }.GetNewClosure())
    return $form
}

function Show-BugReport {
    $form = New-BugReportForm
    $state = $form.Tag
    try { [void]$form.ShowDialog($script:Form) }
    finally { $form.Dispose() }
    if (-not $state.Open) { return }
    $activity = ''
    if ($state.Include) { $activity = Get-LatestActivityText }
    Open-HttpLink (Get-BugReportUrl $activity)
}

function Open-HttpLink([string]$Url) {
    $allowed = $false
    if ($Url -eq 'https://ko-fi.com/philipvern') { $allowed = $true }
    elseif ($Url.StartsWith('https://github.com/philipvern-dot/video-dehydrator/issues/new?')) { $allowed = $true }
    if (-not $allowed) { return }
    Start-Process $Url
}

function Get-AppVersion {
    $path = Join-Path $script:AppDir 'version.txt'
    if (Test-Path -LiteralPath $path) {
        $text = ''
        try { $text = [IO.File]::ReadAllText($path).Trim() } catch { $text = '' }
        if ($text -match '^\d+\.\d+\.\d+(\.\d+)?$') { return $text }
    }
    return [string]$script:UpdateFallback
}

function Test-InstalledCopy {
    $programs = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs'))
    if (-not $programs.EndsWith('\')) { $programs = $programs + '\' }
    $root = [IO.Path]::GetFullPath($script:Root)
    if (-not $root.EndsWith('\')) { $root = $root + '\' }
    return $root.StartsWith($programs, [StringComparison]::OrdinalIgnoreCase)
}

function Update-UpdateButtons {
    $busy = Test-UpdateBusy
    if ($script:CheckUpdateButton) { $script:CheckUpdateButton.Enabled = -not $busy }
    if ($script:UpdateButton) {
        $ready = (-not $busy) -and ($null -ne $script:UpdateOffer) -and [bool]$script:UpdateOffer.Newer
        $script:UpdateButton.Enabled = $ready
    }
}

function Get-UpdateOffer($release) {
    $remote = Remove-VersionPrefix ([string]$release.tag_name)
    $cmp = Compare-AppVersion $remote (Get-AppVersion)
    $asset = $null
    foreach ($item in @($release.assets)) {
        if ($null -eq $item) { continue }
        if ([string]$item.name -eq $script:UpdateAsset) { $asset = $item }
    }
    $result = [pscustomobject]@{
        Newer = $false
        Version = $remote
        Url = ''
        Size = [int64]0
        Message = ''
        Kind = 'idle'
    }
    if ($null -eq $cmp) {
        $result.Message = 'The latest release has no version number.'
        $result.Kind = 'err'
        return $result
    }
    $url = ''
    $size = [int64]0
    if ($null -ne $asset) {
        $url = [string]$asset.browser_download_url
        try { $size = [int64]$asset.size } catch { $size = 0 }
    }
    if ([string]::IsNullOrWhiteSpace($url) -or $size -le 0 -or $url -notmatch '^https://github\.com/philipvern-dot/') {
        $result.Message = 'The latest release does not include the setup program.'
        $result.Kind = 'err'
        return $result
    }
    if ($cmp -le 0) {
        $result.Message = 'You have the latest version (' + (Get-AppVersion) + ').'
        $result.Kind = 'ok'
        return $result
    }
    $result.Newer = $true
    $result.Url = $url
    $result.Size = $size
    $result.Message = 'Version ' + $remote + ' is available.'
    $result.Kind = 'ok'
    return $result
}

function Apply-UpdateOffer($offer) {
    if ($offer.Newer) { $script:UpdateOffer = $offer } else { $script:UpdateOffer = $null }
    Update-UpdateButtons
    Set-Status $offer.Message $offer.Kind
    $kind = 'dim'
    if ($offer.Kind -eq 'err') { $kind = 'err' }
    elseif ($offer.Newer) { $kind = 'ok' }
    Write-Activity $offer.Message $kind
}

function Test-UpdatePromptDue($offer) {
    if ($null -eq $offer -or -not $offer.Newer) { return $false }
    $seen = [string]$script:UpdatePrompt
    if ([string]::IsNullOrWhiteSpace($seen)) { return $true }
    $cmp = Compare-AppVersion ([string]$offer.Version) $seen
    if ($null -eq $cmp) { return $true }
    return ($cmp -gt 0)
}

function Remember-UpdatePrompt([string]$Version) {
    if ([string]::IsNullOrWhiteSpace($Version)) { return }
    if ([string]$script:UpdatePrompt -eq $Version) { return }
    $script:UpdatePrompt = $Version
    Save-Settings
}

function Show-UpdateReady($offer) {
    if ($script:SmokeTest) { return }
    if (-not (Test-UpdatePromptDue $offer)) { return }
    $text = 'Version ' + $offer.Version + ' is available. Click Update to install it.'
    [Windows.Forms.MessageBox]::Show($script:Form, $text, $script:UpdateProduct, 'OK', 'Information') | Out-Null
    Remember-UpdatePrompt ([string]$offer.Version)
}

function Start-UpdateCheck {
    if (Test-UpdateBusy) {
        [Windows.Forms.MessageBox]::Show($script:Form, 'Finish or cancel the current job before checking for updates.', $script:UpdateProduct, 'OK', 'Information') | Out-Null
        return
    }
    $previous = $script:UpdateOffer
    $script:UpdateOffer = $null
    Update-UpdateButtons
    Set-Status 'Checking for updates...' 'busy'
    $script:Form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $url = 'https://api.github.com/repos/philipvern-dot/' + $script:UpdateRepo + '/releases/latest'
        $headers = @{ 'User-Agent' = $script:UpdateProduct; 'Accept' = 'application/vnd.github+json' }
        $release = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
        Apply-UpdateOffer (Get-UpdateOffer $release)
        Show-UpdateReady $script:UpdateOffer
    } catch {
        $status = 0
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        if ($status -eq 404) { $message = 'No published update was found.' }
        else { $message = 'Could not reach GitHub to check for updates.' }
        Write-Activity $message 'err'
        if ($previous -and $previous.Newer) {
            $script:UpdateOffer = $previous
            Update-UpdateButtons
            Set-Status ([string]$previous.Message) 'ok'
        } else {
            $script:UpdateOffer = $null
            Update-UpdateButtons
            Set-Status $message 'err'
        }
    } finally {
        $script:Form.Cursor = [Windows.Forms.Cursors]::Default
    }
}

function Receive-SetupFile([string]$url, [string]$dest, [int64]$expected) {
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $client = New-Object Net.WebClient
    $client.Headers['User-Agent'] = $script:UpdateProduct
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'Update'
    $dialog.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.StartPosition = [Windows.Forms.FormStartPosition]::CenterParent
    $dialog.ClientSize = New-Object Drawing.Size(420, 128)
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ControlBox = $false
    $dialog.Font = $script:FontUi
    $label = New-Object Windows.Forms.Label
    $label.Text = 'Downloading the update...'
    $label.SetBounds(20, 18, 380, 24)
    $bar = New-Object Windows.Forms.ProgressBar
    $bar.SetBounds(20, 50, 380, 22)
    $bar.Minimum = 0
    $bar.Maximum = 100
    $cancel = New-Button 'Cancel' 'secondary' 100 32
    $cancel.SetBounds(300, 82, 100, 32)
    Set-Tip $cancel 'Stop the download. This copy stays as it is.'
    $dialog.Controls.Add($label)
    $dialog.Controls.Add($bar)
    $dialog.Controls.Add($cancel)
    $state = New-Object psobject -Property @{ Done = $false; Error = $null; Cancelled = $false }
    $client.add_DownloadProgressChanged({
        try {
            $pct = [int]$args[1].ProgressPercentage
            if ($pct -lt 0) { $pct = 0 }
            if ($pct -gt 100) { $pct = 100 }
            $bar.Value = $pct
            $label.Text = 'Downloading the update... ' + $pct + '%'
        } catch { }
    })
    $client.add_DownloadFileCompleted({
        $state.Done = $true
        if ($args[1].Cancelled) { $state.Cancelled = $true }
        elseif ($args[1].Error) { $state.Error = $args[1].Error }
        try { if (-not $dialog.IsDisposed) { $dialog.Close() } } catch { }
    })
    $cancel.Add_Click({
        $state.Cancelled = $true
        try { $client.CancelAsync() } catch { }
    })
    $dialog.Add_Shown({
        try { $client.DownloadFileAsync([Uri]$url, $dest) }
        catch {
            $state.Done = $true
            $state.Error = $_.Exception
            try { $dialog.Close() } catch { }
        }
    })
    [void]$dialog.ShowDialog($script:Form)
    $client.Dispose()
    if ($state.Cancelled) {
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue }
        Set-Status 'Update cancelled.' 'idle'
        Write-Activity 'Update cancelled.' 'dim'
        return $false
    }
    if ($state.Error -or -not (Test-Path -LiteralPath $dest)) {
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue }
        Set-Status 'The download did not finish.' 'err'
        Write-Activity 'The download did not finish.' 'err'
        return $false
    }
    $got = [int64](Get-Item -LiteralPath $dest).Length
    if ($expected -gt 0 -and $got -ne $expected) {
        Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        Set-Status 'The download did not match the size published on GitHub.' 'err'
        Write-Activity ('The download was ' + $got + ' bytes. GitHub published ' + $expected + ' bytes.') 'err'
        return $false
    }
    return $true
}

function Start-UpdateInstall {
    if (Test-UpdateBusy) {
        [Windows.Forms.MessageBox]::Show($script:Form, 'Finish or cancel the current job before updating.', $script:UpdateProduct, 'OK', 'Information') | Out-Null
        return
    }
    $offer = $script:UpdateOffer
    if ($null -eq $offer -or -not $offer.Newer) { return }
    $prompt = 'Version ' + $offer.Version + ' is ready to install. This window will close and the setup program will open.'
    if (-not (Test-InstalledCopy)) {
        $prompt = 'Version ' + $offer.Version + ' is ready to install. This folder was not installed by the setup program, so the setup installs the new version for this Windows user and leaves this folder as it is. This window will close.'
    }
    $answer = [Windows.Forms.MessageBox]::Show($script:Form, $prompt, $script:UpdateProduct, 'OKCancel', 'Question')
    if ($answer -ne [Windows.Forms.DialogResult]::OK) { return }
    $dest = Join-Path $env:TEMP ($script:UpdateAsset.Replace('.exe', '') + '-' + $offer.Version + '.exe')
    if (-not (Receive-SetupFile $offer.Url $dest $offer.Size)) { return }
    Start-Process -FilePath $dest | Out-Null
    $script:UpdateClosing = $true
    $script:Form.Close()
}

function Layout-Actions {
    $panel = $script:ActionPanel
    if ($null -eq $panel -or $panel.ClientSize.Width -lt 20) { return }
    $y = 2
    $script:ScanButton.Location = New-Object Drawing.Point(0, $y)
    $script:ConvertButton.Location = New-Object Drawing.Point(($script:ScanButton.Right + 8), $y)
    $script:CancelButton.Location = New-Object Drawing.Point(($script:ConvertButton.Right + 8), ($y + 2))
    if ($script:StopAfterButton) { $script:StopAfterButton.Location = New-Object Drawing.Point(0, 44) }
    if ($script:ContinueButton) {
        $continueLeft = 0
        if ($script:StopAfterButton) { $continueLeft = $script:StopAfterButton.Right + 8 }
        $script:ContinueButton.Location = New-Object Drawing.Point($continueLeft, 44)
    }
    if ($script:ForceButton) {
        $forceLeft = 0
        if ($script:ContinueButton) { $forceLeft = $script:ContinueButton.Right + 8 }
        $script:ForceButton.Location = New-Object Drawing.Point($forceLeft, 44)
    }
    if ($script:LogButton) {
        $logLeft = 0
        if ($script:ForceButton) { $logLeft = $script:ForceButton.Right + 8 }
        $script:LogButton.Location = New-Object Drawing.Point($logLeft, 44)
    }
    if ($script:FindBox) {
        $script:FindBox.Location = New-Object Drawing.Point(($panel.ClientSize.Width - $script:FindBox.Width), 44)
        if ($script:FindLabel) {
            $script:FindLabel.Location = New-Object Drawing.Point(($script:FindBox.Left - 8 - $script:FindLabel.Width), 48)
        }
    }
    if ($script:JobBox) {
        $anchor = $panel.ClientSize.Width
        if ($script:FindLabel) { $anchor = $script:FindLabel.Left }
        elseif ($script:FindBox) { $anchor = $script:FindBox.Left }
        $script:JobBox.Location = New-Object Drawing.Point(($anchor - 8 - $script:JobBox.Width), 44)
        if ($script:JobLabel) {
            $labelWidth = $script:JobLabel.Width
            if ($labelWidth -lt 20) { $labelWidth = $script:JobLabel.PreferredSize.Width }
            if ($labelWidth -lt 20) { $labelWidth = 108 }
            $script:JobLabel.Location = New-Object Drawing.Point(($script:JobBox.Left - 8 - $labelWidth), 48)
        }
    }
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
        $text = "$($anchor.Name): $($box.Text). Encode at $($numbers.Kbps) kbps. HEVC and AV1 use $hevc."
        Set-Tip $box $text
    }
}

function Update-RowsForBudgets {
    $removed = New-Object System.Collections.Generic.List[object]
    foreach ($item in @(Get-EveryFileItem)) {
        if (-not $item -or -not $item.Tag) { continue }
        $status = [string]$item.Tag.Status
        if ($status -ne 'Bloated' -and $status -ne 'Can shrink' -and $status -ne 'Failed' -and $status -ne 'Skipped') { continue }
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
        if ($decision.Decision -eq 'lean' -or $decision.Decision -eq 'within' -or $decision.Decision -eq 'dv') {
            $removed.Add($item)
            continue
        }
        if ($decision.Decision -ne 'bloated' -and $decision.Decision -ne 'shrink') { continue }
        $item.Tag.BudgetGiBph = $decision.BudgetGiBph
        $item.Tag.TargetKbps = $decision.TargetKbps
        $item.Tag.GiBph = $decision.GiBph
        if ($null -ne $decision.EstimateBytes) { $item.Tag.EstimateBytes = $decision.EstimateBytes }
        $item.Tag.EstimateRough = [bool]$decision.EstimateRough
        if ($status -eq 'Bloated' -or $status -eq 'Can shrink') {
            if ($decision.Decision -eq 'shrink') { $item.Tag.Status = 'Can shrink' } else { $item.Tag.Status = 'Bloated' }
            $item.Tag.Reason = $decision.Reason
        }
        Update-ResultRow $item
    }
    if ($removed.Count -gt 0) {
        $script:Files.BeginUpdate()
        try {
            foreach ($item in $removed) {
                $script:Files.Items.Remove($item)
                if ($script:HiddenItems) { [void]$script:HiddenItems.Remove($item) }
            }
        }
        finally { $script:Files.EndUpdate() }
    }
    Apply-ShowFilter
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
    foreach ($chk in @($script:SubfoldersCheck, $script:AutoCheck, $script:RecycleCheck, $script:ReencodeCheck, $script:DetailedCheck, $script:ShutdownCheck)) {
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
        $swatch = $null
        if ($script:BudgetSwatches -and $i -lt @($script:BudgetSwatches).Count) { $swatch = $script:BudgetSwatches[$i] }
        if ($swatch) { $swatch.SetBounds($x, ($rowY + 8), 14, 14) }
        $label.SetBounds(($x + 20), ($rowY + 4), 64, 22)
        $boxW = $col - 84 - 14
        if ($boxW -lt 120) { $boxW = 120 }
        $box.SetBounds(($x + 88), $rowY, $boxW, 28)
    }
    if ($script:ClearSkipsButton) {
        $script:ClearSkipsButton.Location = New-Object Drawing.Point(16, $y)
    }
    Update-OptionsScroll
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
    if (-not $script:SelectOverButton -or -not $script:OverPick) { return }
    $script:ListLabel.Location = New-Object Drawing.Point(0, 6)
    $script:ClearButton.Location = New-Object Drawing.Point(($panel.ClientSize.Width - $script:ClearButton.Width), 2)
    $script:SelectNoneButton.Location = New-Object Drawing.Point(($script:ClearButton.Left - 8 - $script:SelectNoneButton.Width), 2)
    $script:SelectAllButton.Location = New-Object Drawing.Point(($script:SelectNoneButton.Left - 8 - $script:SelectAllButton.Width), 2)
    $script:SelectOverButton.Location = New-Object Drawing.Point(($script:SelectAllButton.Left - 8 - $script:SelectOverButton.Width), 2)
    $overWidth = 176
    $left = $script:ListLabel.Right + 12
    $folderRoom = $script:SelectOverButton.Left - 8 - $overWidth - 8 - $script:SelectFolderButton.Width - 8 - $left
    if ($folderRoom -lt 120) {
        $overWidth = [Math]::Max(128, $overWidth - (120 - $folderRoom))
        $folderRoom = $script:SelectOverButton.Left - 8 - $overWidth - 8 - $script:SelectFolderButton.Width - 8 - $left
    }
    if ($folderRoom -lt 72) { $folderRoom = 72 }
    $script:SelectFolderButton.Location = New-Object Drawing.Point(($left + $folderRoom + 8), 2)
    $overLeft = $script:SelectFolderButton.Right + 8
    if (($overLeft + $overWidth) -gt ($script:SelectOverButton.Left - 8)) {
        $overWidth = [Math]::Max(110, ($script:SelectOverButton.Left - 8 - $overLeft))
    }
    $script:OverPick.SetBounds($overLeft, 3, $overWidth, 26)
    $script:FolderPick.SetBounds($left, 3, $folderRoom, 26)
    if ($script:ShowButton) { $script:ShowButton.Location = New-Object Drawing.Point(0, 36) }
    if ($script:SelectShownButton -and $script:ShowButton) {
        $script:SelectShownButton.Location = New-Object Drawing.Point(($script:ShowButton.Right + 8), 36)
    }
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

function Get-ListSplitMetrics {
    $table = $script:MainTable
    $empty = @{ Available = 0 }
    if (-not $table) { return $empty }
    if ($table.RowStyles.Count -le $script:LogRow) { return $empty }
    $fixed = 0.0
    for ($i = 0; $i -lt $table.RowStyles.Count; $i++) {
        if ($i -eq $script:ListRow -or $i -eq $script:OptionsRow -or $i -eq $script:LogRow) { continue }
        $style = $table.RowStyles[$i]
        if ($style.SizeType -eq [Windows.Forms.SizeType]::Absolute) { $fixed += [double]$style.Height }
    }
    $pad = $table.Padding
    $available = [double]$table.ClientSize.Height - [double]$pad.Top - [double]$pad.Bottom - $fixed
    if ($available -lt 1) { return $empty }
    return @{ Available = [int][Math]::Floor($available) }
}

function Get-ListSplitPlan([int]$Extra) {
    $minOptions = [int]$script:OptionsSplitMin
    $naturalOptions = [int]$script:OptionsSplitNatural
    $minList = [int]$script:ListSplitMin
    $minLog = [int]$script:LogSplitMin
    $available = [int](Get-ListSplitMetrics).Available
    if ($available -lt 1) {
        return @{ Extra = $Extra; List = 0; Log = 0; Options = $naturalOptions; Ready = $false }
    }
    $options = $naturalOptions
    $room = $available - $options
    if ($room -lt 2) {
        $options = [Math]::Max($minOptions, $available - 2)
        $room = [Math]::Max(2, $available - $options)
    }
    $defaultList = [int][Math]::Round($room * 0.58)
    if ($defaultList -lt 1) { $defaultList = 1 }
    if ($defaultList -gt ($room - 1)) { $defaultList = $room - 1 }
    $defaultLog = $room - $defaultList
    $logSlack = $defaultLog - $minLog
    if ($logSlack -lt 0) { $logSlack = 0 }
    $optionsSlack = $options - $minOptions
    if ($optionsSlack -lt 0) { $optionsSlack = 0 }
    $maxExtra = $logSlack + $optionsSlack
    $minExtra = $minList - $defaultList
    if ($minExtra -gt 0) { $minExtra = 0 }
    if ($Extra -gt $maxExtra) { $Extra = $maxExtra }
    if ($Extra -lt $minExtra) { $Extra = $minExtra }
    $list = $defaultList + $Extra
    $log = $defaultLog
    $logExtra = 0
    if ($null -ne $script:LogExtra) { $logExtra = [int]$script:LogExtra }
    $growRoom = $list - $minList
    if ($growRoom -lt 0) { $growRoom = 0 }
    $shrinkRoom = $log - $minLog
    if ($shrinkRoom -lt 0) { $shrinkRoom = 0 }
    if ($logExtra -gt $growRoom) { $logExtra = $growRoom }
    if ($logExtra -lt (0 - $shrinkRoom)) { $logExtra = 0 - $shrinkRoom }
    $list -= $logExtra
    $log += $logExtra
    if ($Extra -ge 0) {
        $fromLog = $Extra
        if ($fromLog -gt $logSlack) { $fromLog = $logSlack }
        $log -= $fromLog
        $options -= ($Extra - $fromLog)
    } else {
        $log -= $Extra
    }
    if ($list -lt 1) { $list = 1 }
    if ($log -lt 1) { $log = 1 }
    if ($options -lt 1) { $options = 1 }
    return @{ Extra = $Extra; List = $list; Log = $log; Options = $options; Ready = $true }
}

function Update-ListSplit {
    if ($script:ListSplitLock) { return }
    $plan = Get-ListSplitPlan ([int]$script:ListExtra)
    if (-not $plan.Ready) { return }
    $table = $script:MainTable
    if (-not $table) { return }
    $script:ListExtra = [int]$plan.Extra
    $script:ListSplitLock = $true
    try {
        $table.SuspendLayout()
        $table.RowStyles[$script:ListRow].SizeType = [Windows.Forms.SizeType]::Absolute
        $table.RowStyles[$script:ListRow].Height = [single]$plan.List
        $table.RowStyles[$script:OptionsRow].SizeType = [Windows.Forms.SizeType]::Absolute
        $table.RowStyles[$script:OptionsRow].Height = [single]$plan.Options
        $table.RowStyles[$script:LogRow].SizeType = [Windows.Forms.SizeType]::Absolute
        $table.RowStyles[$script:LogRow].Height = [single]$plan.Log
    } finally {
        $table.ResumeLayout($true)
        $script:ListSplitLock = $false
    }
}

function Set-ListExtra([int]$Extra) {
    $script:ListExtra = $Extra
    Update-ListSplit
}

function Update-OptionsScroll {
    $card = $script:OptionsCard
    if (-not $card) { return }
    $need = 240
    if ($script:ClearSkipsButton) { $need = $script:ClearSkipsButton.Bottom + 12 }
    $short = ($card.ClientSize.Height -gt 0) -and ($card.ClientSize.Height -lt $need)
    if ($card.AutoScroll -ne $short) { $card.AutoScroll = $short }
    if ($short) { $card.AutoScrollMinSize = New-Object Drawing.Size(0, $need) }
}

function Update-ChromeLayout {
    $header = $script:Header
    if ($header -and $header.ClientSize.Width -gt 0) {
        $reserve = 28
        if ($script:CheckUpdateButton -and $script:UpdateButton) {
            $right = $header.ClientSize.Width - 24
            $script:UpdateButton.Location = New-Object Drawing.Point(($right - $script:UpdateButton.Width), 18)
            $script:CheckUpdateButton.Location = New-Object Drawing.Point(($script:UpdateButton.Left - 8 - $script:CheckUpdateButton.Width), 18)
            $leftEdge = $script:CheckUpdateButton.Left
            if ($script:ReportBugButton -and $script:DonateButton) {
                $script:ReportBugButton.Location = New-Object Drawing.Point(($right - $script:ReportBugButton.Width), 60)
                $script:DonateButton.Location = New-Object Drawing.Point(($script:ReportBugButton.Left - 8 - $script:DonateButton.Width), 60)
                if ($script:DonateButton.Left -lt $leftEdge) { $leftEdge = $script:DonateButton.Left }
            }
            $reserve = $header.ClientSize.Width - $leftEdge + 16
        }
        $textWidth = [Math]::Max(160, ($header.ClientSize.Width - 28 - $reserve))
        $script:TitleLabel.SetBounds(28, 16, $textWidth, 36)
        $script:SubtitleLabel.SetBounds(28, 54, $textWidth, 48)
    }
    $status = $script:StatusPanel
    if ($status -and $status.ClientSize.Width -gt 0) {
        $versionGap = 0
        if ($script:VersionLabel) {
            $vw = $script:VersionLabel.PreferredSize.Width
            if ($vw -lt 1) { $vw = 48 }
            $script:VersionLabel.SetBounds(($status.ClientSize.Width - 24 - $vw), 8, $vw, 22)
            $versionGap = $vw + 12
        }
        $script:StatusLabel.SetBounds(24, 8, ([Math]::Max(80, $status.ClientSize.Width - 48 - $versionGap)), 22)
        $trackY = 36
        if ($script:EtaLabel) {
            $showEta = -not [string]::IsNullOrWhiteSpace([string]$script:EtaLabel.Text)
            $script:EtaLabel.Visible = $showEta
            if ($showEta) {
                $script:EtaLabel.SetBounds(24, 32, ([Math]::Max(80, $status.ClientSize.Width - 48)), 22)
                $trackY = 56
            }
        }
        $script:ProgressTrack.SetBounds(24, $trackY, ([Math]::Max(0, $status.ClientSize.Width - 48)), 8)
        Set-Progress $script:ProgressValue
        if ($script:JobHost -and $script:JobHost.Visible) {
            $script:JobHost.SetBounds(24, ($trackY + 12), ([Math]::Max(80, $status.ClientSize.Width - 48)), $script:JobHost.Height)
            $rowTop = 0
            $rows = @($script:JobRows)
            for ($i = 0; $i -lt $rows.Count; $i++) {
                $row = $rows[$i]
                if (-not $row -or -not $row.Panel.Visible) { continue }
                $row.Panel.SetBounds(0, $rowTop, $script:JobHost.ClientSize.Width, 34)
                $row.Label.SetBounds(0, 0, $row.Panel.Width, 16)
                $row.Track.SetBounds(0, 18, $row.Panel.Width, 8)
                $pct = 0.0
                if ($script:Lanes -and $i -lt @($script:Lanes).Count) { $pct = [double]@($script:Lanes)[$i].Percent }
                Set-BarFill $row.Track $row.Fill $pct
                $rowTop += 36
            }
        }
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
            Body = "A 1920x1080 video is too big when the whole file is 2 GiB per hour or more. HEVC and AV1 use a higher line, 3 GiB per hour at 1080p. A file under that line is still listed when its picture is above the target rate. The status then says Can shrink. The target for that 1080p picture is 3000 kbps of video. This is the same rule the media library uses.`r`n`r`nOther picture sizes multiply those numbers by how many pixels they have compared with 1920x1080. 3840x2160 has four times the pixels, so 4K is allowed 8 GiB per hour and is encoded at 12000 kbps. 1280x720 is encoded at 1333 kbps. 720x480 is encoded at 500 kbps. A very small picture stays at 200 kbps.`r`n`r`nThe Budgets row has a choice for 2160p, 1080p, 720p, and 480p. Each choice has its own color, and Dimensions on a file uses that same color when the file follows that choice. 2160p is blue, 1080p is teal, 720p is purple, and 480p is orange. Each one starts on Recommended, which is the line above. Half, 1.5 times, and Double lower or raise that line, and the encode rate moves with it. A picture of some other size uses the closest of those four, then scales by its number of pixels. HEVC and AV1 stay at one and a half times the budget you picked. The choices are remembered.`r`n`r`nScan again after a change. A higher budget takes a file off the list when its picture is no longer above the target rate. A file under the new line stays when the picture is still above that rate, and its status changes to Can shrink. A lower budget finds new files on the next scan.`r`n`r`nThe encode is software x265, two passes, medium speed. The frame rate stays as it was. The picture is not cropped or scaled. Audio that can be copied is copied. Re-encode audio that cannot be copied turns the other kinds, such as Windows Media Audio, into AAC. With that box off, a file whose audio cannot be copied is left as it was. Subtitles are copied and are not burned into the picture.`r`n`r`nA file whose picture is already at that target rate is left alone, even when the file is large because of the audio. Dolby Vision is left alone."
        },
        @{
            Title = 'Scanning'
            Body = "Browse, or drop a folder onto the path, then click Scan. Include subfolders looks inside every folder within the one you chose. The list shows bloated files and Can shrink files, checked and ready to convert.`r`n`r`nSelect all checks every row. Deselect all clears every check. Clear removes the scanned files from the list. Files still waiting in .vd-originals stay. The folder list names each folder that has bloated or can-shrink files, and a show is listed along with the season folders inside it. Select folder checks the bloated and can-shrink files in the folder you picked and clears the other checks, so Convert is that smaller job. Right-click a row for the same choices.`r`n`r`nGiB/h is the size of the whole file per hour of runtime. Budget is the line for that picture size. Ratio is how many times the budget the file uses. 1.00x is on the line. 2.00x is twice the line. A file just over the line keeps the extra digits, such as 1.04x, so it does not look like 1.00x. A file under 1.00x is listed when its picture is still above the target rate. The status says Can shrink, the Ratio cell is not colored, and the row starts checked. Select slight, Select heavy, and Select extreme leave those rows alone. Select all and Select folder include them. Showing all opens a checkbox for each group: Can shrink, Bloated, Slight, Heavy, Extreme, Failed, Skipped, Ready to delete, and Finished. With none checked, every row stays. Check one group to show only those rows, then check more groups to add them. A checked box is the group on screen. Hidden rows are unchecked, so Convert leaves them out. Select shown checks the rows still on screen that Convert can take. Slight, shown in green, is under 1.5 times and barely over. Heavy, shown in yellow, is from 1.5 times up to 3 times. Extreme, shown in red, is 3 times the budget or more. Click a heading to sort. The first click on Ratio puts the largest ratios first. Drag a heading sideways to move that column. The order is remembered, and an update can put the columns back. Drag the bar under the list to make that list taller or shorter. The activity box shrinks first, then Options if you keep going. Double-click the bar to put the list back. Drag the bar above the activity box to make that box taller or shorter. Double-click that bar to put the activity box back.`r`n`r`nThe list beside Select folder offers Slight, Heavy, and Extreme. Select slight, Select heavy, or Select extreme checks only that group and clears the other checks, so Convert is that group. Right-click a row for the same choice.`r`n`r`nTarget is the video rate the new file will use. New size is a rough guess of the new file. When the current picture rate can be read, the guess keeps the audio and other tracks. When that rate is missing, the guess uses the target picture rate for the length of the video, so it can run a little high. That New size starts with a tilde. Estimated savings is the current size minus New size, added up for the checked files. It changes as those checks change. A file with no New size figure is left out of the total. ~Savings is the current size minus New size, on each row, before the convert. The first click on ~Savings puts the largest estimates first. A value that starts with ~ had no picture rate, so that guess can run high. After a convert, ~Savings clears and Space Saved shows the real result. Space Saved is the original file size minus the converted file. It fills in when a convert finishes and stays blank before that."
        },
        @{
            Title = 'Converting'
            Body = "Convert shrinks every checked file whose status is Bloated, Can shrink, or Failed. Parallel jobs chooses how many files encode together, from 1 to 6. Each file uses about 8 cores. One is right for most computers. Two needs about 16 cores, three about 24, four about 32, five about 40, and six about 48. On fewer cores the files share the processor and the batch does not finish sooner. Log opens the conversion record, a Markdown file grouped by the day and time each file finished. Find can stop the scan after 5, 10, 25, 50, or 100 files that can be reduced. All keeps scanning the whole folder. Updating the program keeps that file. Each running file has its own bar and name. The bar is that file. Under the bar, this file is how long that encode still has. The first pass shows only that pass until a finished file has shown how long the second pass takes. Estimated time remaining is the rest of the batch. It stays on estimating until this run has a speed to measure, and 10-bit files are timed apart from 8-bit files. The time line keeps a rolling average and changes about every 30 seconds, and when a file starts. Stop after current file leaves Estimated time remaining on the file that is still running. Cancel stops the file that is running. Stop after current file lets that file finish, then leaves the rest of the batch for later. Continue keeps the batch going. Files that already finished stay finished. Manual converts a chosen file or folder even when it is not over the budget. Test savings reads those files and estimates the savings, then asks you to proceed or cancel. Convert now skips that estimate. Include subfolders when the path is a folder. Dolby Vision is still left alone, and a result that is not smaller is still thrown away.`r`n`r`nThe new file is written inside .vd-originals first, then checked: it has to be smaller, the same length, the same picture size, with the same audio when that audio can be copied, and at least as many subtitles, and the start and end have to play. When the check passes, the original moves into .vd-originals and the new .mkv takes its place. When the check fails, the original stays where it was. When the new file is not smaller, the row is marked Skipped and the activity box says why. The picture rate plus the audio can be larger than a file that was already small. That file is left unchecked and remembered. Later scans leave it off the list. A smaller budget lists it again. Clear skips forgets those marks so the same budget can be tried again.`r`n`r`nThe folder needs free space for the new file while the original is still there. Show detailed activity lists each encode step. The activity box does not add a line for each percent. A moving mark on the last line shows that the file is still being worked on. With that box off, the activity box lists when a file starts and when it finishes. The bar along the bottom still shows the percent.`r`n`r`nShutdown computer upon completion turns the computer off after the convert finishes. A one-minute countdown gives you a chance to cancel. If you stop the convert, the computer stays on. A scan does not turn the computer off."
        },
        @{
            Title = 'Checking the picture'
            Body = "Select a file marked Ready to delete and click Compare. The window plays both copies side by side: original on the left, new file on the right. Sound is the new file. It will not stay in sync with the picture. Go to the file on disk to confirm the audio. The slider moves through both pictures together.`r`n`r`nThis preview is for review. It is a smaller picture than the files themselves, so you can see them next to each other."
        },
        @{
            Title = 'Originals and deleting'
            Body = "Delete originals removes the checked files that are still in .vd-originals. The new files stay. The button refuses to delete anything outside that holding folder. If the new file is missing, the original is kept. The program asks before it deletes. Don't show this in the future hides that question until the next version of the program.`r`n`r`nUndo puts back the last conversion. The originals return to where they were, and the new files are deleted. The program lists the files and asks before it does this. One use covers every file from that convert. It can only undo a conversion whose original is still in .vd-originals. If those originals were already deleted, there is nothing to put back.`r`n`r`nA .plexignore file in the video's folder tells Plex to skip .vd-originals while originals are held there. When that holding folder is removed, the .plexignore file is removed too. If the file also names other things for Plex to skip, those lines stay. Held originals are remembered in app\pending.json, so they are still listed the next time you open the program.`r`n`r`nEach result is also written to app\convert-log.tsv. On a shared drive, the drive can keep a copy in #recycle. The Drive recycle bin section explains that copy and the steps to remove it by hand."
        },
        @{
            Title = 'Auto'
            Body = "Delete originals automatically does the deletion as soon as a file checks out. The check looks at size, length, picture size, audio, subtitles, and whether the start and end play. It does not judge how the picture looks. The first time Auto is turned on, the program explains that Compare and Undo cannot bring the original back. You can hide that explanation. The program still asks before every convert with Auto turned on. Stop asking on that window hides it from then on. Cancel leaves the warning on. With Auto off, every original stays until you press Delete originals. Clear the drive recycle copy is separate. With that box on, the matching copy in #recycle is removed when the path and the size match. The .plexignore from that convert is removed when it only hides the holding folder. When that removal fails, a window opens with a link to the manual steps. Mute on that window hides it after this one time."
        },
        @{
            Title = 'Drive recycle bin'
            Body = @'
A shared drive can keep its own copy of a file after Video Dehydrator deletes it. The copy goes in a folder named #recycle at the top of the share. The folders underneath stay the same, including .vd-originals. That folder is on the drive. It is separate from the recycle bin Windows keeps on this PC.

Clear the drive recycle copy starts off. With that box off, the program leaves #recycle alone. The copy stays on the drive until you remove it with the steps below.

With that box on, after Delete originals, after Delete originals automatically removes a file, after undo discards a new file, or after a temporary encode file is removed, the program looks for that one copy. It builds the path from the share, then #recycle, then the same folders. The file has to sit directly inside .vd-originals, and the size has to match the file that was just deleted. When both match, that copy is deleted. The .plexignore from that convert is removed too, when the recycled copy contains only the lines that hide .vd-originals. A .plexignore that lists anything else stays. Empty folders left behind are removed, and the folders above them are removed when those are empty too. A folder that still contains another file or folder is left, so another computer can finish its own delete. Removal stops at the #recycle folder. Anything else in the bin stays, including a file you deleted yourself. The new video that stays in the library is left alone.

When this step cannot remove the copy, a window opens. The link in that window opens this section. Mute hides that window after this one time. Later failures are still written in the activity list, and these steps stay here. Shutdown still runs when that box is on, because Mute does not open this section. The original is already gone from the library. The copy in the bin is the leftover. A share with a #recycle folder and no matching file shows the same window. When the share does not keep deleted files, there is nothing to remove.

To remove a leftover yourself:

1. Open the share in File Explorer. When the videos are on Z: and Z: is the whole share, the bin is Z:\#recycle. When Z: is a folder inside the share, use the address that starts with \\server\share. The #recycle folder is at the top of that share.
2. Open #recycle, then the same show and season folders, then .vd-originals.
3. Delete the original file there. A file deleted from inside #recycle is removed for good.
4. Leave every file that is outside a .vd-originals folder.

When #recycle is not visible, this Windows account is not allowed to open it. Use the drive's admin site to empty that share's recycle bin, or use the SSH commands below.

PowerShell can list the holding folders from this PC. Change \\server\share to your share, then read every path that prints:

Get-ChildItem -LiteralPath '\\server\share\#recycle' -Recurse -Force -Directory | Where-Object { $_.Name -eq '.vd-originals' }

Remove only those folders:

Get-ChildItem -LiteralPath '\\server\share\#recycle' -Recurse -Force -Directory | Where-Object { $_.Name -eq '.vd-originals' } | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force }

To remove one file, change the show, season, and file name:

Remove-Item -LiteralPath '\\server\share\#recycle\TV\Show\Season 1\.vd-originals\Episode.avi' -Force

When Windows cannot open the bin, sign in to the drive with SSH and list the folders first. Change /volume1/share to the volume path of this share:

find '/volume1/share/#recycle' -type d -name '.vd-originals' -print

When that list is the leftovers you want gone, remove them:

find '/volume1/share/#recycle' -type d -name '.vd-originals' -exec rm -rf '{}' +

Keep an SSH path in single quotes. A name with an apostrophe needs the quotes closed and reopened around that mark. A delete run on the drive itself leaves the file out of #recycle.
'@
        },
        @{
            Title = 'Updates'
            Body = "The bottom right corner shows this copy's version.`r`n`r`nThe program checks for updates when it opens. Check for updates looks again. When a newer version is found, a window tells you once. Closing that window keeps it from opening again until a later version is published. The status line keeps saying that version is available. Update downloads it and opens the setup program. The setup replaces the installed copy and keeps your settings. The setup asks whether to create a Start menu shortcut and whether to create a desktop shortcut.`r`n`r`nFinish or cancel the current job before you update. The program closes while the setup runs, then you can open it again.`r`n`r`nDonate opens a tip page. The program stays free. A tip of `$5` or more can include a feature suggestion on that page. Report a bug opens a GitHub page with this version and the Windows version filled in. Include latest activity is a choice on that step. Leave it unchecked and nothing else is added. The latest lines from the activity box can include folder paths. This program does not send the report. You submit it on the GitHub page."
        },
        @{
            Title = 'What is in this folder'
            Body = "Video Dehydrator: double-click this to open the program.`r`napp: the program, your settings, the list of originals still waiting, and the convert log.`r`ntools: HandBrake, which encodes, and FFmpeg, which reads the files and plays the comparison. FFmpeg is free software. Its license is $license. HandBrake is free software under the GPL."
        }
    )
}

function Add-HelpHeading($box, [string]$text) {
    if (-not $script:HelpMarks) { $script:HelpMarks = @{} }
    if ($box.TextLength -gt 0) {
        $box.SelectionStart = $box.TextLength
        $box.SelectionLength = 0
        $box.SelectionFont = $script:FontHelpBody
        $box.SelectionColor = $script:ColorBody
        $box.AppendText([Environment]::NewLine)
    }
    $script:HelpMarks[$text] = $box.TextLength
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
    $sub.Text = 'Folders, the size rule, comparing, deleting, and the drive recycle bin.'
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
    Set-Tip $close 'Close this guide.'
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
    $script:HelpMarks = @{}
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

function Move-HelpToSection([string]$Section) {
    if (-not $Section) { return }
    if (-not $script:HelpBox -or $script:HelpBox.IsDisposed) { return }
    if (-not $script:HelpMarks -or -not $script:HelpMarks.Contains($Section)) { return }
    $script:HelpBox.SelectionStart = [int]$script:HelpMarks[$Section]
    $script:HelpBox.SelectionLength = 0
    $script:HelpBox.ScrollToCaret()
}

function Show-Help {
    param([string]$Section)
    if ($script:HelpForm -and -not $script:HelpForm.IsDisposed) {
        $script:HelpForm.Activate()
    }
    else {
        $script:HelpForm = New-HelpForm
        [void]$script:HelpForm.Show($script:Form)
    }
    Move-HelpToSection $Section
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
$script:AutoWarnAccepted = [bool]$settings.AutoWarnAccepted
$script:AutoAsk = [bool]$settings.AutoAsk
$script:UpdatePrompt = [string]$settings.UpdatePrompt
$script:DeleteConfirmVersion = [string]$settings.DeleteConfirmVersion
$script:RecycleAlertMuted = [bool]$settings.RecycleAlertMuted
$script:RecyclePurgeEnabled = [bool]$settings.PurgeRecycle
$script:ListExtra = [int]$settings.ListExtra
$script:LogExtra = [int]$settings.LogExtra
$script:JobCount = [int]$settings.JobCount
if ($script:JobCount -lt 1 -or $script:JobCount -gt 6) { $script:JobCount = 1 }
$script:FindLimit = [int]$settings.FindLimit
$script:AutoWarnShown = $false
$script:AutoWarnBusy = $false
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
$wantH = 948
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
$script:CheckUpdateButton = New-Button 'Check for updates' 'secondary' 168 34
$script:UpdateButton = New-Button 'Update' 'primary' 100 34
$script:UpdateButton.Enabled = $false
$script:DonateButton = New-Button 'Donate' 'secondary' 96 28
$script:ReportBugButton = New-Button 'Report a bug' 'secondary' 132 28
$script:Header.Controls.Add($script:TitleLabel)
$script:Header.Controls.Add($script:SubtitleLabel)
$script:Header.Controls.Add($script:CheckUpdateButton)
$script:Header.Controls.Add($script:UpdateButton)
$script:Header.Controls.Add($script:DonateButton)
$script:Header.Controls.Add($script:ReportBugButton)

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
$script:EtaLabel = New-Object Windows.Forms.Label
$script:EtaLabel.Text = ''
$script:EtaLabel.Font = $script:FontUi
$script:EtaLabel.ForeColor = $script:ColorInk
$script:EtaLabel.AutoEllipsis = $true
$script:EtaLabel.BackColor = [Drawing.Color]::White
$script:EtaLabel.Visible = $false
$script:VersionLabel = New-Object Windows.Forms.Label
$script:VersionLabel.Text = Get-AppVersion
$script:VersionLabel.Font = $script:FontHint
$script:VersionLabel.ForeColor = $script:ColorMuted
$script:VersionLabel.BackColor = [Drawing.Color]::White
$script:VersionLabel.TextAlign = 'MiddleRight'
$script:VersionLabel.AutoSize = $true
$script:ProgressTrack = New-Object Windows.Forms.Panel
$script:ProgressTrack.BackColor = [Drawing.Color]::FromArgb(229, 231, 235)
$script:ProgressTrack.Height = 8
$script:ProgressFill = New-Object Windows.Forms.Panel
$script:ProgressFill.BackColor = $script:ColorPrimary
$script:ProgressFill.Height = 8
$script:ProgressFill.Width = 0
$script:ProgressTrack.Controls.Add($script:ProgressFill)
function New-JobRow {
    $panel = New-Object Windows.Forms.Panel
    $panel.BackColor = [Drawing.Color]::White
    $label = New-Object Windows.Forms.Label
    $label.Font = $script:FontUi
    $label.ForeColor = $script:ColorInk
    $label.BackColor = [Drawing.Color]::White
    $label.AutoEllipsis = $true
    $track = New-Object Windows.Forms.Panel
    $track.BackColor = [Drawing.Color]::FromArgb(229, 231, 235)
    $track.Height = 8
    $fill = New-Object Windows.Forms.Panel
    $fill.BackColor = $script:ColorPrimary
    $fill.Height = 8
    $fill.Width = 0
    $track.Controls.Add($fill)
    $panel.Controls.Add($label)
    $panel.Controls.Add($track)
    return @{ Panel = $panel; Label = $label; Track = $track; Fill = $fill }
}
$script:JobHost = New-Object Windows.Forms.Panel
$script:JobHost.BackColor = [Drawing.Color]::White
$script:JobHost.Visible = $false
$script:JobHost.Height = 0
$jobRows = @()
$encodeLanes = @()
for ($i = 0; $i -lt 6; $i++) {
    $jobRow = New-JobRow
    $jobRows += $jobRow
    $script:JobHost.Controls.Add($jobRow.Panel)
    $encodeLanes += [pscustomobject]@{
        Index = $i
        Pump = (New-Object VideoDehydrator.JobPump)
        Item = $null
        Plan = $null
        Probe = $null
        Decision = $null
        Lines = (New-Object 'System.Collections.Generic.List[string]')
        ReencodeAudio = $false
        Encoder = ''
        Percent = [double]0
        Pass = ''
        SinglePass = $false
        OutputRetries = 0
        Row = $jobRow
    }
}
$script:JobRows = $jobRows
$script:Lanes = $encodeLanes
$script:StatusPanel.Controls.Add($script:JobHost)
$script:StatusPanel.Controls.Add($script:StatusLabel)
$script:StatusPanel.Controls.Add($script:EtaLabel)
$script:StatusPanel.Controls.Add($script:VersionLabel)
$script:StatusPanel.Controls.Add($script:ProgressTrack)
$script:StatusPanel.Add_Paint({
    $pen = New-Object Drawing.Pen $script:ColorLine
    $_.Graphics.DrawLine($pen, 0, 0, $script:StatusPanel.Width, 0)
    $pen.Dispose()
})

$script:ListSplitMin = 72
$script:LogSplitMin = 52
$script:OptionsSplitNatural = 280
$script:OptionsSplitMin = 188
$script:ListRow = 4
$script:OptionsRow = 6
$script:LogRow = 10
$script:ListSplitLock = $false
$table = New-Object Windows.Forms.TableLayoutPanel
$script:MainTable = $table
$table.Dock = 'Fill'
$table.BackColor = $script:ColorPage
$table.ColumnCount = 1
$table.RowCount = 11
$table.Padding = New-Object Windows.Forms.Padding(24, 16, 24, 8)
$table.Margin = New-Object Windows.Forms.Padding(0)
$table.GrowStyle = 'FixedSize'
[void]$table.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 26)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 48)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 40)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 70)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 58)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 12)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 280)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 92)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 26)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 12)))
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
$script:OverPick = New-Object Windows.Forms.ComboBox
$script:OverPick.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
$script:OverPick.Font = $script:FontUi
$script:OverPick.IntegralHeight = $false
$script:OverPick.DropDownHeight = 160
$script:OverPick.DropDownWidth = 240
$script:SelectOverButton = New-Button 'Select slight' 'secondary' 136 28
$script:SelectAllButton = New-Button 'Select all' 'secondary' 104 28
$script:SelectNoneButton = New-Button 'Deselect all' 'secondary' 120 28
$script:ClearButton = New-Button 'Clear' 'secondary' 80 28
$script:SelectFolderButton.Margin = New-Object Windows.Forms.Padding(0)
$script:SelectOverButton.Margin = New-Object Windows.Forms.Padding(0)
$script:SelectAllButton.Margin = New-Object Windows.Forms.Padding(0)
$script:SelectNoneButton.Margin = New-Object Windows.Forms.Padding(0)
$script:ClearButton.Margin = New-Object Windows.Forms.Padding(0)
$script:ShowButton = New-Button 'Showing all' 'secondary' 280 28
$script:SelectShownButton = New-Button 'Select shown' 'secondary' 130 28
$script:ShowButton.Margin = New-Object Windows.Forms.Padding(0)
$script:SelectShownButton.Margin = New-Object Windows.Forms.Padding(0)
$script:ShowFilters = @{
    shrink = $false
    bloated = $false
    slight = $false
    heavy = $false
    extreme = $false
    failed = $false
    skipped = $false
    ready = $false
    finished = $false
}
$script:ShowOrder = @('shrink', 'bloated', 'slight', 'heavy', 'extreme', 'failed', 'skipped', 'ready', 'finished')
$script:ShowBoxes = @{}
$script:ShowMenu = New-Object Windows.Forms.ToolStripDropDown
$script:ShowMenu.Padding = New-Object Windows.Forms.Padding(8, 6, 12, 6)
$script:ShowMenu.AutoSize = $true
$script:ShowMenu.Add_Closing({
    $reason = $_.CloseReason
    if ($reason -eq [Windows.Forms.ToolStripDropDownCloseReason]::ItemClicked) { $_.Cancel = $true }
    if ($reason -eq [Windows.Forms.ToolStripDropDownCloseReason]::AppClicked) {
        $point = $script:ShowMenu.PointToClient([Windows.Forms.Cursor]::Position)
        if ($script:ShowMenu.ClientRectangle.Contains($point)) { $_.Cancel = $true }
    }
})
foreach ($pair in @(
    @{ Id = 'shrink'; Text = 'Can shrink' },
    @{ Id = 'bloated'; Text = 'Bloated' },
    @{ Id = 'slight'; Text = 'Slight' },
    @{ Id = 'heavy'; Text = 'Heavy' },
    @{ Id = 'extreme'; Text = 'Extreme' },
    @{ Id = 'failed'; Text = 'Failed' },
    @{ Id = 'skipped'; Text = 'Skipped' },
    @{ Id = 'ready'; Text = 'Ready to delete' },
    @{ Id = 'finished'; Text = 'Finished' }
)) {
    $box = New-Object Windows.Forms.CheckBox
    $box.Text = [string]$pair.Text
    $box.Tag = [string]$pair.Id
    $box.AutoSize = $true
    $box.Font = $script:FontUi
    $box.BackColor = [Drawing.Color]::White
    $box.Padding = New-Object Windows.Forms.Padding(2, 1, 4, 1)
    $box.Checked = $false
    $box.Add_CheckedChanged({
        $id = [string]$this.Tag
        if ($script:ShowFilters -and $id) { $script:ShowFilters[$id] = [bool]$this.Checked }
        Apply-ShowFilter
        if ($script:Work -eq 'idle' -and -not $script:FilterBusy) {
            $names = @(Get-ShowFilterNames)
            if ($names.Count -eq 0) { Write-Activity 'The list is showing every file.' 'text' }
            else { Write-Activity ('The list is showing ' + ($names -join ', ') + '. Hidden files are unchecked.') 'text' }
        }
    })
    $hostItem = New-Object Windows.Forms.ToolStripControlHost($box)
    $hostItem.AutoSize = $true
    $hostItem.Margin = New-Object Windows.Forms.Padding(2, 2, 2, 2)
    [void]$script:ShowMenu.Items.Add($hostItem)
    $script:ShowBoxes[[string]$pair.Id] = $box
}
$script:ShowButton.Add_Click({
    if ($script:ShowMenu) { $script:ShowMenu.Show($script:ShowButton, 0, $script:ShowButton.Height) }
})
$script:SelectShownButton.Add_Click({ Select-ShownFiles })
$script:ListHeader.Controls.Add($script:ListLabel)
$script:ListHeader.Controls.Add($script:ShowButton)
$script:ListHeader.Controls.Add($script:SelectShownButton)
$script:ListHeader.Controls.Add($script:FolderPick)
$script:ListHeader.Controls.Add($script:SelectFolderButton)
$script:ListHeader.Controls.Add($script:OverPick)
$script:ListHeader.Controls.Add($script:SelectOverButton)
$script:ListHeader.Controls.Add($script:SelectAllButton)
$script:ListHeader.Controls.Add($script:SelectNoneButton)
$script:ListHeader.Controls.Add($script:ClearButton)
$script:SelectFolderButton.Add_Click({ Select-ChosenFolder })
$script:SelectOverButton.Add_Click({ Select-OverBand (Get-SelectedOverId) })
$script:OverPick.Add_SelectedIndexChanged({
    if ($script:LoadingOver) { return }
    Update-OverButton
    Update-Buttons
})
$script:SelectAllButton.Add_Click({ Set-AllChecks $true })
$script:SelectNoneButton.Add_Click({ Set-AllChecks $false })
$script:ClearButton.Add_Click({ Clear-ListedFiles })
Update-OverChoices

$script:Files = New-Object Windows.Forms.ListView
$script:Files.Dock = 'Fill'
$script:Files.View = 'Details'
$script:Files.FullRowSelect = $true
$script:Files.CheckBoxes = $true
$script:Files.AllowColumnReorder = $false
$script:Files.GridLines = $false
$script:Files.HideSelection = $false
$script:Files.MultiSelect = $false
$script:Files.Font = $script:FontUi
$script:Files.BackColor = [Drawing.Color]::White
$script:Files.ForeColor = $script:ColorInk
$script:Files.BorderStyle = 'FixedSingle'
$script:Files.ShowItemToolTips = $true
$script:Files.Margin = New-Object Windows.Forms.Padding(0)
$script:ColumnTitles = @('File', 'Dimensions', 'Length', 'Size', 'GiB/h', 'Budget', 'Ratio', 'Target', 'New size', 'Status', 'Space Saved', '~Savings')
$script:SortColumn = -1
$script:SortAscending = $true
[void]$script:Files.Columns.Add('File', 280)
[void]$script:Files.Columns.Add('Dimensions', 120)
[void]$script:Files.Columns.Add('Length', 80)
[void]$script:Files.Columns.Add('Size', 170)
[void]$script:Files.Columns.Add('GiB/h', 70)
[void]$script:Files.Columns.Add('Budget', 70)
[void]$script:Files.Columns.Add('Ratio', 96)
[void]$script:Files.Columns.Add('Target', 100)
[void]$script:Files.Columns.Add('New size', 110)
[void]$script:Files.Columns.Add('Status', 150)
[void]$script:Files.Columns.Add('Space Saved', 120)
[void]$script:Files.Columns.Add('~Savings', 120)
$script:Files.Add_ColumnClick({
    if ($script:SkipNextColumnClick) {
        $script:SkipNextColumnClick = $false
        return
    }
    Sort-FileList $_.Column
})
$script:Files.Add_ItemChecked({ if (-not $script:BulkCheck) { Update-Buttons } })
$script:Files.Add_SelectedIndexChanged({ Update-Buttons })
$script:FileMenu = New-Object Windows.Forms.ContextMenuStrip
$script:FileMenu.Font = $script:FontUi
[void]$script:FileMenu.Items.Add('Select all')
[void]$script:FileMenu.Items.Add('Deselect all')
[void]$script:FileMenu.Items.Add('Select files in this folder')
[void]$script:FileMenu.Items.Add('Select this overage')
[void]$script:FileMenu.Items.Add('Clear')
$script:FileMenu.Items[0].Add_Click({ Set-AllChecks $true })
$script:FileMenu.Items[1].Add_Click({ Set-AllChecks $false })
$script:FileMenu.Items[2].Add_Click({ Select-FolderOfSelectedFile })
$script:FileMenu.Items[3].Add_Click({
    if ($script:Files.SelectedItems.Count -ne 1) { return }
    $bandId = Get-RowOverBand $script:Files.SelectedItems[0].Tag
    if ($bandId) { Select-OverBand $bandId }
})
$script:FileMenu.Items[4].Add_Click({ Clear-ListedFiles })
$script:FileMenu.Add_Opening({
    $busy = ($script:Work -ne 'idle')
    $hasRow = ($script:Files.SelectedItems.Count -eq 1)
    $bandId = ''
    if ($hasRow) { $bandId = Get-RowOverBand $script:Files.SelectedItems[0].Tag }
    $band = Get-OverBand $bandId
    if ($band) { $script:FileMenu.Items[3].Text = ('Select ' + ([string]$band.Label).ToLowerInvariant() + ' files') }
    else { $script:FileMenu.Items[3].Text = 'Select this overage' }
    $script:FileMenu.Items[0].Enabled = -not $busy
    $script:FileMenu.Items[1].Enabled = -not $busy
    $script:FileMenu.Items[2].Enabled = ((-not $busy) -and $hasRow)
    $script:FileMenu.Items[3].Enabled = ((-not $busy) -and $null -ne $band)
    $script:FileMenu.Items[4].Enabled = ((-not $busy) -and (Test-ScanRows))
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
$script:AutoCheck.AutoCheck = $false
$script:RecycleCheck = New-Check 'Clear the drive recycle copy'
$script:ReencodeCheck = New-Check 'Re-encode audio that cannot be copied'
$script:DetailedCheck = New-Check 'Show detailed activity'
$script:ShutdownCheck = New-Check 'Shutdown computer upon completion'
$script:JobLabel = New-Object Windows.Forms.Label
$script:JobLabel.Text = 'Parallel jobs'
$script:JobLabel.Font = $script:FontUi
$script:JobLabel.ForeColor = $script:ColorInk
$script:JobLabel.BackColor = $script:ColorPage
$script:JobLabel.AutoSize = $true
$script:JobBox = New-Object Windows.Forms.ComboBox
$script:JobBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
$script:JobBox.FlatStyle = [Windows.Forms.FlatStyle]::Flat
$script:JobBox.Font = $script:FontUi
$script:JobBox.SetBounds(0, 0, 52, 28)
for ($job = 1; $job -le 6; $job++) { [void]$script:JobBox.Items.Add([string]$job) }
$jobPick = [int]$script:JobCount
if ($jobPick -lt 1 -or $jobPick -gt 6) { $jobPick = 1 }
$script:JobBox.SelectedIndex = $jobPick - 1
$script:JobBox.Add_SelectedIndexChanged({
    if ($script:Loading) { return }
    $script:JobCount = Get-JobCount
    Save-Settings
})
$script:SubfoldersCheck.Checked = [bool]$settings.IncludeSubfolders
$script:AutoCheck.Checked = [bool]$settings.AutoDelete
$script:RecycleCheck.Checked = [bool]$settings.PurgeRecycle
$script:ReencodeCheck.Checked = [bool]$settings.ReencodeAudio
$script:DetailedCheck.Checked = [bool]$settings.Detailed
$script:ShutdownCheck.Checked = [bool]$settings.Shutdown
$script:OptionsCard.Controls.Add($script:OptionsTitle)
$script:OptionsCard.Controls.Add($script:SubfoldersCheck)
$script:OptionsCard.Controls.Add($script:AutoCheck)
$script:OptionsCard.Controls.Add($script:RecycleCheck)
$script:OptionsCard.Controls.Add($script:ReencodeCheck)
$script:OptionsCard.Controls.Add($script:DetailedCheck)
$script:OptionsCard.Controls.Add($script:ShutdownCheck)
$script:ClearSkipsButton = New-Button 'Clear skips' 'secondary' 120 28
$script:ClearSkipsButton.Margin = New-Object Windows.Forms.Padding(0)
$script:ClearSkipsButton.Enabled = $false
$script:OptionsCard.Controls.Add($script:ClearSkipsButton)
$script:ClearSkipsButton.Add_Click({ Clear-RememberedSkips })
$script:BudgetTitle = New-Object Windows.Forms.Label
$script:BudgetTitle.Text = 'Budgets'
$script:BudgetTitle.Font = $script:FontSection
$script:BudgetTitle.ForeColor = $script:ColorInk
$script:BudgetTitle.BackColor = [Drawing.Color]::White
$script:BudgetLabels = @()
$script:BudgetBoxes = @()
$script:BudgetSwatches = @()
foreach ($anchor in (Get-BudgetAnchors)) {
    $mark = Get-BudgetMark ([string]$anchor.Id)
    $swatch = New-Object Windows.Forms.Panel
    $swatch.BackColor = $(if ($mark) { $mark.Mark } else { $script:ColorLine })
    $name = New-Object Windows.Forms.Label
    $name.Text = [string]$anchor.Name
    $name.Font = $script:FontUi
    $name.ForeColor = $(if ($mark) { $mark.Fore } else { $script:ColorInk })
    $name.BackColor = [Drawing.Color]::White
    $name.AutoEllipsis = $true
    $box = New-Object Windows.Forms.ComboBox
    $box.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    $box.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $box.Font = $script:FontUi
    $box.Tag = [string]$anchor.Id
    $box.DropDownWidth = 280
    if ($mark) {
        $box.BackColor = $mark.Back
        $box.ForeColor = $mark.Fore
    }
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
    $script:OptionsCard.Controls.Add($swatch)
    $script:OptionsCard.Controls.Add($name)
    $script:OptionsCard.Controls.Add($box)
    $script:BudgetSwatches += $swatch
    $script:BudgetLabels += $name
    $script:BudgetBoxes += $box
}
$script:BudgetSwatches = @($script:BudgetSwatches)
$script:BudgetLabels = @($script:BudgetLabels)
$script:BudgetBoxes = @($script:BudgetBoxes)
$script:OptionsCard.Controls.Add($script:BudgetTitle)
$script:OptionsCard.Add_Paint({
    $pen = New-Object Drawing.Pen $script:ColorLine
    $_.Graphics.DrawRectangle($pen, 0, 0, ($script:OptionsCard.Width - 1), ($script:OptionsCard.Height - 1))
    $pen.Dispose()
})
foreach ($chk in @($script:SubfoldersCheck, $script:ReencodeCheck, $script:DetailedCheck, $script:ShutdownCheck)) {
    $chk.Add_CheckedChanged({ if (-not $script:Loading) { Save-Settings } })
}
$script:RecycleCheck.Add_CheckedChanged({
    if ($script:Loading) { return }
    Sync-RecyclePurge
    Save-Settings
})
$script:AutoCheck.Add_Click({
    if ($script:Loading -or $script:AutoWarnBusy) { return }
    $script:AutoCheck.Checked = -not $script:AutoCheck.Checked
    Update-AutoChoice
})

$script:ActionPanel = New-Object Windows.Forms.Panel
$script:ActionPanel.Dock = 'Fill'
$script:ActionPanel.BackColor = $script:ColorPage
$script:ActionPanel.Margin = New-Object Windows.Forms.Padding(0, 4, 0, 0)
$script:ScanButton = New-Button 'Scan' 'primary' 110 38
$script:ConvertButton = New-Button 'Optimize' 'primary' 130 38
$script:CancelButton = New-Button 'Cancel' 'danger' 100 34
$script:ForceButton = New-Button 'Manual' 'secondary' 100 34
$script:StopAfterButton = New-Button 'Stop after current file' 'secondary' 210 34
$script:ContinueButton = New-Button 'Continue' 'secondary' 110 34
$script:CompareButton = New-Button 'Compare' 'secondary' 110 34
$script:UndoButton = New-Button 'Undo' 'secondary' 90 34
$script:DeleteButton = New-Button 'Delete originals' 'secondary' 150 34
$script:HelpButton = New-Button 'How this works' 'secondary' 148 34
$script:LogButton = New-Button 'Log' 'secondary' 72 34
$script:LogButton.Add_Click({ Open-ConversionLog })
$script:FindLabel = New-Object Windows.Forms.Label
$script:FindLabel.Text = 'Find'
$script:FindLabel.AutoSize = $true
$script:FindLabel.Font = $script:FontUi
$script:FindLabel.ForeColor = $script:ColorInk
$script:FindLabel.BackColor = [Drawing.Color]::FromArgb(244, 246, 248)
$script:FindBox = New-Object Windows.Forms.ComboBox
$script:FindBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
$script:FindBox.Font = $script:FontUi
$script:FindBox.Width = 88
$script:FindBox.IntegralHeight = $false
$script:FindBox.DropDownHeight = 180
[void]$script:FindBox.Items.Add('All')
foreach ($count in @(5, 10, 25, 50, 100)) { [void]$script:FindBox.Items.Add([string]$count) }
$findText = if ([int]$script:FindLimit -gt 0) { [string][int]$script:FindLimit } else { 'All' }
$findIndex = $script:FindBox.Items.IndexOf($findText)
$script:FindBox.SelectedIndex = $(if ($findIndex -ge 0) { $findIndex } else { 0 })
$script:FindBox.Add_SelectedIndexChanged({ if (-not $script:Loading) { Save-Settings } })
$script:CancelButton.Enabled = $false
$script:StopAfterButton.Enabled = $false
$script:ContinueButton.Enabled = $false
$script:ActionPanel.Controls.Add($script:ScanButton)
$script:ActionPanel.Controls.Add($script:ConvertButton)
$script:ActionPanel.Controls.Add($script:CancelButton)
$script:ActionPanel.Controls.Add($script:ForceButton)
$script:ActionPanel.Controls.Add($script:StopAfterButton)
$script:ActionPanel.Controls.Add($script:ContinueButton)
$script:ActionPanel.Controls.Add($script:CompareButton)
$script:ActionPanel.Controls.Add($script:UndoButton)
$script:ActionPanel.Controls.Add($script:DeleteButton)
$script:ActionPanel.Controls.Add($script:HelpButton)
$script:ActionPanel.Controls.Add($script:LogButton)
$script:ActionPanel.Controls.Add($script:FindLabel)
$script:ActionPanel.Controls.Add($script:FindBox)
$script:ActionPanel.Controls.Add($script:JobLabel)
$script:ActionPanel.Controls.Add($script:JobBox)
$script:ScanButton.Add_Click({ Start-Scan })
$script:ConvertButton.Add_Click({ Start-Convert })
$script:ForceButton.Add_Click({ Start-Force })
$script:CancelButton.Add_Click({ Request-Cancel })
$script:StopAfterButton.Add_Click({ Request-StopAfterFile })
$script:ContinueButton.Add_Click({ Request-ContinueBatch })
$script:CompareButton.Add_Click({ Show-Compare })
$script:UndoButton.Add_Click({ Start-UndoLast })
$script:DeleteButton.Add_Click({ Remove-CheckedOriginals })
$script:HelpButton.Add_Click({ Show-Help })
$script:CheckUpdateButton.Add_Click({ Start-UpdateCheck })
$script:DonateButton.Add_Click({ Open-HttpLink 'https://ko-fi.com/philipvern' })
$script:ReportBugButton.Add_Click({ Show-BugReport })
$script:UpdateButton.Add_Click({ Start-UpdateInstall })

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

$script:ListSplit = New-Object Windows.Forms.Panel
$script:ListSplit.Dock = 'Fill'
$script:ListSplit.Height = 12
$script:ListSplit.Margin = New-Object Windows.Forms.Padding(0)
$script:ListSplit.Cursor = [Windows.Forms.Cursors]::SizeNS
$script:ListSplit.BackColor = $script:ColorPage
$script:ListSplit.TabStop = $false
Enable-DoubleBuffer $script:ListSplit
$script:ListSplit.Add_Paint({
    $g = $_.Graphics
    $mid = [int]($this.ClientSize.Height / 2)
    $line = New-Object Drawing.Pen $script:ColorLine
    $g.DrawLine($line, 0, $mid, $this.ClientSize.Width, $mid)
    $line.Dispose()
    $tone = $(if ($script:ListSplitHot -or $script:ListSplitDrag) { [Drawing.Color]::FromArgb(71, 85, 105) } else { [Drawing.Color]::FromArgb(148, 156, 168) })
    $brush = New-Object Drawing.SolidBrush $tone
    $cx = [int]($this.ClientSize.Width / 2)
    foreach ($offset in @(-18, -6, 6, 18)) {
        $g.FillRectangle($brush, ($cx + $offset), ($mid - 1), 4, 3)
    }
    $brush.Dispose()
})
$script:ListSplit.Add_MouseEnter({
    $script:ListSplitHot = $true
    $this.Invalidate()
})
$script:ListSplit.Add_MouseLeave({
    if ($script:ListSplitDrag) { return }
    $script:ListSplitHot = $false
    $this.Invalidate()
})
$script:ListSplit.Add_MouseDown({
    if ($_.Button -ne [Windows.Forms.MouseButtons]::Left) { return }
    $script:ListSplitDrag = @{
        Y = [Windows.Forms.Cursor]::Position.Y
        Extra = [int]$script:ListExtra
    }
    $this.Capture = $true
    $this.Invalidate()
})
$script:ListSplit.Add_MouseMove({
    if (-not $script:ListSplitDrag) { return }
    if ($_.Button -ne [Windows.Forms.MouseButtons]::Left) { return }
    $drag = $script:ListSplitDrag
    $dy = [Windows.Forms.Cursor]::Position.Y - [int]$drag.Y
    $script:ListExtra = [int]$drag.Extra + $dy
    Update-ListSplit
})
$script:ListSplit.Add_MouseUp({
    if (-not $script:ListSplitDrag) { return }
    $script:ListSplitDrag = $null
    $this.Capture = $false
    $script:ListSplitHot = $this.ClientRectangle.Contains($this.PointToClient([Windows.Forms.Cursor]::Position))
    $this.Invalidate()
    Save-Settings
})
$script:ListSplit.Add_MouseDoubleClick({
    if ($_.Button -ne [Windows.Forms.MouseButtons]::Left) { return }
    $script:ListSplitDrag = $null
    $this.Capture = $false
    Set-ListExtra 0
    Save-Settings
})

[void]$table.Controls.Add($folderCaption, 0, 0)
[void]$table.Controls.Add($script:FolderCard, 0, 1)
[void]$table.Controls.Add($script:HintPanel, 0, 2)
[void]$table.Controls.Add($script:ListHeader, 0, 3)
[void]$table.Controls.Add($script:Files, 0, 4)
[void]$table.Controls.Add($script:ListSplit, 0, 5)
[void]$table.Controls.Add($script:OptionsCard, 0, 6)
[void]$table.Controls.Add($script:ActionPanel, 0, 7)
$script:LogSplit = New-Object Windows.Forms.Panel
$script:LogSplit.Dock = 'Fill'
$script:LogSplit.Height = 12
$script:LogSplit.Margin = New-Object Windows.Forms.Padding(0)
$script:LogSplit.Cursor = [Windows.Forms.Cursors]::SizeNS
$script:LogSplit.BackColor = $script:ColorPage
$script:LogSplit.TabStop = $false
Enable-DoubleBuffer $script:LogSplit
$script:LogSplit.Add_Paint({
    $g = $_.Graphics
    $mid = [int]($this.ClientSize.Height / 2)
    $line = New-Object Drawing.Pen $script:ColorLine
    $g.DrawLine($line, 0, $mid, $this.ClientSize.Width, $mid)
    $line.Dispose()
    $tone = $(if ($script:LogSplitHot -or $script:LogSplitDrag) { [Drawing.Color]::FromArgb(71, 85, 105) } else { [Drawing.Color]::FromArgb(148, 156, 168) })
    $brush = New-Object Drawing.SolidBrush $tone
    $cx = [int]($this.ClientSize.Width / 2)
    foreach ($offset in @(-18, -6, 6, 18)) {
        $g.FillRectangle($brush, ($cx + $offset), ($mid - 1), 4, 3)
    }
    $brush.Dispose()
})
$script:LogSplit.Add_MouseEnter({
    $script:LogSplitHot = $true
    $this.Invalidate()
})
$script:LogSplit.Add_MouseLeave({
    if ($script:LogSplitDrag) { return }
    $script:LogSplitHot = $false
    $this.Invalidate()
})
$script:LogSplit.Add_MouseDown({
    if ($_.Button -ne [Windows.Forms.MouseButtons]::Left) { return }
    $script:LogSplitDrag = @{
        Y = [Windows.Forms.Cursor]::Position.Y
        Extra = [int]$script:LogExtra
    }
    $this.Capture = $true
    $this.Invalidate()
})
$script:LogSplit.Add_MouseMove({
    if (-not $script:LogSplitDrag) { return }
    if ($_.Button -ne [Windows.Forms.MouseButtons]::Left) { return }
    $drag = $script:LogSplitDrag
    $dy = [Windows.Forms.Cursor]::Position.Y - [int]$drag.Y
    $script:LogExtra = [int]$drag.Extra - $dy
    Update-ListSplit
    $this.Invalidate()
})
$script:LogSplit.Add_MouseUp({
    if ($_.Button -ne [Windows.Forms.MouseButtons]::Left) { return }
    $script:LogSplitDrag = $null
    $this.Capture = $false
    $script:LogSplitHot = $false
    $this.Invalidate()
    Save-Settings
})
$script:LogSplit.Add_MouseDoubleClick({
    if ($_.Button -ne [Windows.Forms.MouseButtons]::Left) { return }
    $script:LogSplitDrag = $null
    $this.Capture = $false
    $script:LogExtra = 0
    Update-ListSplit
    Save-Settings
})

[void]$table.Controls.Add($activityLabel, 0, 8)
[void]$table.Controls.Add($script:LogSplit, 0, 9)
[void]$table.Controls.Add($logHost, 0, 10)

$script:Form.Controls.Add($table)
$script:Form.Controls.Add($script:StatusPanel)
$script:Form.Controls.Add($script:Header)

Set-Tip $script:FolderBox 'Folder to scan. Drop a folder here, or click Browse.'
Set-Tip $script:SavingsLabel 'Current size minus New size, for the checked files. A ~ means the picture rate was missing.'
Set-Tip $script:BrowseButton 'Choose the folder to scan.'
Set-Tip $script:SubfoldersCheck 'Also scan the folders inside the chosen folder.'
Set-Tip $script:AutoCheck 'Delete each original as soon as the new file checks out. The #recycle copy is removed only when Clear the drive recycle copy is on.'
Set-Tip $script:RecycleCheck 'Remove the matching #recycle copy after a delete. Mute hides the failure window after one time.'
Set-Tip $script:ReencodeCheck 'Turn audio that cannot be copied, such as Windows Media Audio, into AAC.'
Set-Tip $script:DetailedCheck 'List each encode step. The percent stays on the bar.'
Set-Tip $script:ShutdownCheck 'Turn the computer off after Convert finishes. You get one minute to cancel.'
Set-Tip $script:ClearSkipsButton 'Forget files skipped because the new copy was larger. Scan again to list them.'
Set-Tip $script:BudgetTitle 'Size line for each picture. Recommended is the starting choice.'
Update-BudgetTips
Set-Tip $script:ScanButton 'List videos that are too big for their picture size.'
Set-Tip $script:ConvertButton 'Shrink the checked bloated, can-shrink, failed, and skipped files.'
Set-Tip $script:ForceButton 'Convert a file or folder even when it is under the budget.'
Set-Tip $script:CancelButton 'Stop the scan or the file that is converting. Esc does this too.'
Set-Tip $script:StopAfterButton 'Finish this file, then stop. The rest stay checked.'
Set-Tip $script:ContinueButton 'Keep converting the rest of the batch.'
Set-Tip $script:CompareButton 'Play both files side by side. The sound will not stay in sync.'
Set-Tip $script:UndoButton 'Put the last conversion back. The program asks first.'
Set-Tip $script:DeleteButton 'Delete the checked originals in .vd-originals. The #recycle copy is removed only when that box is on.'
Set-Tip $script:HelpButton 'Open the guide, including how to clear a drive recycle bin by hand.'
Set-Tip $script:CheckUpdateButton 'Look on GitHub for a newer version.'
Set-Tip $script:DonateButton 'Free forever. Tips of $5 or more can include a feature suggestion.'
Set-Tip $script:ReportBugButton 'Open a GitHub bug report with this version filled in.'
Set-Tip $script:UpdateButton 'Download the newer version and open its setup. This window closes while that runs.'
Set-Tip $script:FolderPick 'Folders with files to shrink. Pick one for a smaller job.'
Set-Tip $script:SelectFolderButton 'Check the files in this folder and clear the other checks.'
Set-Tip $script:OverPick 'Slight is under 1.5x, Heavy is under 3x, and Extreme is 3x or more.'
Set-Tip $script:SelectOverButton 'Check this ratio group and clear the other checks.'
Set-Tip $script:SelectAllButton 'Check every row.'
Set-Tip $script:SelectNoneButton 'Clear every check.'
Set-Tip $script:ClearButton 'Remove scanned files from the list. Files in .vd-originals stay.'
Set-Tip $script:ShowButton 'Check a group to show only those rows. Hidden rows stay unchecked.'
Set-Tip $script:SelectShownButton 'Check the visible rows Convert can take.'
Set-Tip $script:Files 'Checked rows are ready to shrink. Click a heading to sort, or drag it to move that column.'
Set-Tip $script:ListSplit 'Drag to make the video list taller or shorter. Double-click to put it back.'
Set-Tip $script:JobLabel (Get-JobTip)
Set-Tip $script:JobBox (Get-JobTip)
Set-Tip $script:LogButton 'Open the conversion log. It is a Markdown file of every conversion, grouped by the day and time it finished. Updating the program keeps this file.'
Set-Tip $script:FindBox 'Stop scanning after this many files that can be reduced. All keeps scanning the whole folder.'
Set-Tip $script:FindLabel 'Stop scanning after this many files that can be reduced. All keeps scanning the whole folder.'
Set-Tip $script:Log 'Saved space, skipped videos, and problems are listed here.'
Set-Tip $script:LogSplit 'Drag to make the activity box taller or shorter. Double-click to put it back.'
Set-Tip $script:ProgressTrack 'How far the current file has been encoded. The two passes share the bar evenly.'
Set-Tip $script:EtaLabel 'This file is the encode in progress. Estimated time remaining is the rest of the batch.'
Set-Tip $script:StatusLabel 'What the program is doing right now.'
Set-Tip $script:VersionLabel 'This copy of Video Dehydrator.'
foreach ($panel in @($script:Header, $script:FolderCard, $script:ListHeader, $script:OptionsCard, $script:ActionPanel)) {
    Install-DisabledButtonTips $panel
}

if ($settings.Folder) { Set-FolderText $settings.Folder }
[void]$script:Files.Handle
if (-not (Restore-ColumnOrder @($settings.ColumnOrder))) {
    $script:ColumnOrder = @($script:ColumnTitles)
}
Install-ColumnDrag
$script:Loading = $false
Sync-RecyclePurge

$script:Form.Add_KeyDown({
    if ($_.KeyCode -eq [Windows.Forms.Keys]::Escape -and $script:Work -ne 'idle') {
        $_.SuppressKeyPress = $true
        Request-Cancel
    }
})
$script:Form.Add_FormClosing({
    if ($script:SmokeTest) { return }
    if (-not $script:UpdateClosing -and $script:Work -ne 'idle') {
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
    if ($script:Lanes) {
        foreach ($lane in @($script:Lanes)) {
            Release-EncodeHold $lane.Plan
            try { if ($lane.Pump) { $lane.Pump.Stop() } } catch {}
            $lane.Item = $null
            $lane.Plan = $null
        }
    }
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
$script:MainTable.Add_Resize({ Update-ListSplit })
Update-ListSplit
$script:Form.Add_Shown({
    if ($script:HeaderDrag) { $script:HeaderDrag.Attach() }
    Update-ChromeLayout
    Update-ListSplit
    if (-not $script:SmokeTest) {
        try {
            $script:Form.WindowState = [Windows.Forms.FormWindowState]::Normal
            $script:Form.Visible = $true
            [void][VideoDehydrator.Native]::ShowWindow($script:Form.Handle, 9)
            [void][VideoDehydrator.Native]::SetForegroundWindow($script:Form.Handle)
        } catch {
        }
        Start-UpdateCheck
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

$script:SkipRows = @(Read-SkipFile)
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

function Add-OverFile([string]$Path, $GiBph, $Budget, [string]$Status) {
    if (-not $Status) { $Status = 'Bloated' }
    $tag = @{
        Status = $Status
        Path = $Path
        Kept = ''
        New = ''
        Source = $Path
        Width = 1920
        Height = 1080
        DurationSec = 60
        SizeBytes = 100000000
        OldBytes = $null
        GiBph = $GiBph
        BudgetGiBph = $Budget
        TargetKbps = 3000
        EstimateBytes = 20000000
        Codec = 'h264'
        PendingId = ''
        Reason = 'smoke over'
    }
    Add-ResultRow $tag | Out-Null
}

function Invoke-OverCheck {
    $script:Files.Items.Clear()
    $script:SortColumn = -1
    Update-SortHeaders
    Add-OverFile 'C:\Library\slight.mkv' 2.4 2 'Bloated'
    Add-OverFile 'C:\Library\heavy.mkv' 4 2 'Bloated'
    Add-OverFile 'C:\Library\extreme.mkv' 10 2 'Bloated'
    Add-OverFile 'C:\Library\done.mkv' 8 2 'Ready to delete'
    Update-OverChoices
    $byPath = @{}
    foreach ($item in @($script:Files.Items)) { $byPath[[string]$item.Tag.Path] = $item }
    $slight = $byPath['C:\Library\slight.mkv']
    $heavy = $byPath['C:\Library\heavy.mkv']
    $extreme = $byPath['C:\Library\extreme.mkv']
    $done = $byPath['C:\Library\done.mkv']
    Assert-True ($slight.SubItems[6].Text -eq '1.20x') ("Slight ratio was $($slight.SubItems[6].Text)")
    Assert-True ($heavy.SubItems[6].Text -eq '2.00x') ("Heavy ratio was $($heavy.SubItems[6].Text)")
    Assert-True ($extreme.SubItems[6].Text -eq '5.00x') ("Extreme ratio was $($extreme.SubItems[6].Text)")
    Assert-True ($script:Files.Columns[1].Text -eq 'Dimensions') 'Dimensions heading was missing'
    Assert-True ($script:Files.Columns[8].Text -eq 'New size') 'New size heading was missing'
    Assert-True ($script:Files.Columns[10].Text -eq 'Space Saved') 'Space Saved heading was missing'
    Assert-True ([string]$slight.SubItems[10].Text -eq '') 'An unconverted file showed space saved'
    $done.Tag.OldBytes = 100000000
    $done.Tag.SizeBytes = 20000000
    Update-ResultRow $done
    Assert-True ($done.SubItems[10].Text -eq (Format-ByteSize 80000000)) ("Space saved was $($done.SubItems[10].Text)")
    Assert-True ($script:Files.Columns[11].Text -eq '~Savings') '~Savings heading was missing'
    Assert-True ($slight.SubItems[11].Text -eq (Format-ByteSize 80000000)) ("~Savings was $($slight.SubItems[11].Text)")
    Assert-True ([string]$done.SubItems[11].Text -eq '') 'A finished file kept its estimate'
    $slight.Tag.EstimateBytes = 10000000
    $heavy.Tag.EstimateBytes = 60000000
    Update-ResultRow $slight
    Update-ResultRow $heavy
    Sort-FileList 11
    Assert-True ($script:Files.Columns[11].Text -eq '~Savings v') ("~Savings heading was $($script:Files.Columns[11].Text)")
    Assert-True ([string]$script:Files.Items[0].Tag.Path -match 'slight') 'Largest estimate was not first'
    Assert-True ($done.SubItems[9].Text -eq 'Ready to delete') 'Status moved out of its column'
    Assert-True ($slight.SubItems[1].BackColor.ToArgb() -eq (Get-BudgetMark '1080').Back.ToArgb()) '1080p file did not match its budget color'
    Assert-True ($script:BudgetBoxes[1].BackColor.ToArgb() -eq (Get-BudgetMark '1080').Back.ToArgb()) '1080p budget did not use its color'
    Assert-True ($script:BudgetSwatches[0].BackColor.ToArgb() -eq (Get-BudgetMark '2160').Mark.ToArgb()) '2160p mark was missing'
    Assert-True ($slight.SubItems[6].BackColor.ToArgb() -eq $script:ColorOverSlightBack.ToArgb()) 'Slight was not green'
    Assert-True ($heavy.SubItems[6].BackColor.ToArgb() -eq $script:ColorOverHeavyBack.ToArgb()) 'Heavy was not yellow'
    Assert-True ($extreme.SubItems[6].BackColor.ToArgb() -eq $script:ColorOverExtremeBack.ToArgb()) 'Extreme was not red'
    Assert-True ($done.SubItems[6].Text -eq '4.00x') 'A finished row hid its ratio'
    Assert-True ($done.SubItems[6].BackColor.ToArgb() -eq [Drawing.Color]::White.ToArgb()) 'A finished row was colored as an offender'
    Assert-True ($script:OverPick.Items[0] -match 'Slight' -and $script:OverPick.Items[0] -match '1 file') 'Slight count'
    Assert-True ($script:OverPick.Items[2] -match 'Extreme' -and $script:OverPick.Items[2] -match '1 file') 'Extreme count'
    $script:OverPick.SelectedIndex = 2
    Assert-True ($script:SelectOverButton.Text -eq 'Select extreme') ("Overage button was $($script:SelectOverButton.Text)")
    Select-OverBand 'extreme'
    $checked = @($script:Files.Items | Where-Object { $_.Checked })
    Assert-True ($checked.Count -eq 1 -and [string]$checked[0].Tag.Path -match 'extreme') 'Select extreme checked the wrong rows'
    Sort-FileList 6
    Assert-True ($script:Files.Columns[6].Text -eq 'Ratio v') ("Ratio heading was $($script:Files.Columns[6].Text)")
    Assert-True ([string]$script:Files.Items[0].Tag.Path -match 'extreme') 'Worst overage was not first'
    Sort-FileList 6
    Assert-True ($script:Files.Columns[6].Text -eq 'Ratio ^') 'Second click did not reverse Ratio'
    Assert-True ([string]$script:Files.Items[0].Tag.Path -match 'slight') 'Smallest overage was not first'
    Update-ChromeLayout
    [Windows.Forms.Application]::DoEvents()
    Save-FormImage $script:Form (Join-Path $env:TEMP 'vdh-over.png')
    $script:Files.Items.Clear()
    $script:SortColumn = -1
    Update-SortHeaders
    Update-OverChoices
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
    $script:Files.Items.Clear()
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
    foreach ($id in @('2160', '1080', '720', '480')) { Set-BudgetBoxPick $id 'recommended' }
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
    Set-BudgetBoxPick '1080' 'recommended'
    $modest = @{
        Status = 'Bloated'
        Path = 'C:\Library\clip-modest.mkv'
        Kept = ''
        New = ''
        Source = 'C:\Library\clip-modest.mkv'
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
        VideoBitrate = [int64]5000000
        PendingId = ''
        Reason = 'smoke budget modest'
    }
    Add-ResultRow $modest | Out-Null
    Set-BudgetBoxPick '1080' 'double'
    $still = @($script:Files.Items | Where-Object { [string]$_.Tag.Path -eq 'C:\Library\clip.mkv' })
    Assert-True ($still.Count -eq 1 -and [string]$still[0].Tag.Status -eq 'Can shrink') 'Double budget dropped a file whose picture is still above the target'
    $gone = @($script:Files.Items | Where-Object { [string]$_.Tag.Path -eq 'C:\Library\clip-modest.mkv' })
    Assert-True ($gone.Count -eq 0) 'Double budget kept a file whose picture fits the new target'
    Set-BudgetBoxPick '1080' 'recommended'
    $script:Files.Items.Clear()
    Update-BloatFolders
}

function Invoke-ClearCheck {
    $script:Files.Items.Clear()
    $rough = @{
        Status = 'Bloated'
        Path = 'C:\Library\rough.mkv'
        Kept = ''
        New = ''
        Source = 'C:\Library\rough.mkv'
        Width = 1920
        Height = 1080
        DurationSec = 3600
        SizeBytes = 3000000000
        OldBytes = $null
        GiBph = 3
        BudgetGiBph = 2
        TargetKbps = 3000
        EstimateBytes = 1350000000
        EstimateRough = $true
        VideoBitrate = [int64]0
        Codec = 'h264'
        PendingId = ''
        Reason = 'smoke rough'
    }
    $exact = @{
        Status = 'Bloated'
        Path = 'C:\Library\exact.mkv'
        Kept = ''
        New = ''
        Source = 'C:\Library\exact.mkv'
        Width = 1920
        Height = 1080
        DurationSec = 3600
        SizeBytes = 3000000000
        OldBytes = $null
        GiBph = 3
        BudgetGiBph = 2
        TargetKbps = 3000
        EstimateBytes = 1400000000
        EstimateRough = $false
        VideoBitrate = [int64]8000000
        Codec = 'h264'
        PendingId = ''
        Reason = 'smoke exact'
    }
    $pending = @{
        Status = 'Ready to delete'
        Path = 'C:\Library\new.mkv'
        Kept = 'C:\Library\.vd-originals\old.mkv'
        New = 'C:\Library\new.mkv'
        Source = 'C:\Library\old.mkv'
        Width = 1920
        Height = 1080
        DurationSec = 0
        SizeBytes = 1000
        OldBytes = 2000
        GiBph = $null
        BudgetGiBph = $null
        TargetKbps = 3000
        EstimateBytes = $null
        EstimateRough = $false
        Codec = ''
        PendingId = 'keep-me'
        Reason = 'smoke pending'
    }
    Add-ResultRow $rough | Out-Null
    Add-ResultRow $exact | Out-Null
    Add-ResultRow $pending | Out-Null
    Update-Buttons
    $byPath = @{}
    foreach ($item in @($script:Files.Items)) { $byPath[[string]$item.Tag.Path] = $item }
    Assert-True ($byPath['C:\Library\rough.mkv'].SubItems[8].Text.StartsWith('~')) 'A missing picture rate did not show a tilde'
    Assert-True (-not $byPath['C:\Library\exact.mkv'].SubItems[8].Text.StartsWith('~')) 'A known picture rate showed a tilde'
    Assert-True ($script:ClearButton.Enabled) 'Clear stayed disabled with scanned files'
    Clear-ListedFiles
    Assert-True ($script:Files.Items.Count -eq 1) 'Clear removed a held original'
    Assert-True ([string]$script:Files.Items[0].Tag.PendingId -eq 'keep-me') 'Clear kept the wrong row'
    Assert-True (-not $script:ClearButton.Enabled) 'Clear stayed enabled after the scan list was empty'
    $script:Files.Items.Clear()
    Update-BloatFolders
    Update-Buttons
}

function Invoke-ColumnOrderCheck {
    $saved = @(Get-ColumnOrderNames)
    $kept = Restore-ColumnOrder @('Space Saved', 'Status', 'File', 'Dimensions', 'Length', 'Size', 'GiB/h', 'Budget', 'Ratio', 'Target', 'New size', '~Savings')
    Assert-True $kept 'A full column order was rejected'
    Assert-True ($script:Files.Columns[10].DisplayIndex -eq 0) 'Space Saved did not move to the front'
    Assert-True ($script:Files.Columns[0].DisplayIndex -eq 2) 'File did not move with the saved order'
    Assert-True ((Get-ColumnOrderNames)[0] -eq 'Space Saved') 'The remembered order did not start with Space Saved'
    $before = @(Get-ColumnOrderNames) -join '|'
    Assert-True (-not (Restore-ColumnOrder @('File', 'Missing'))) 'An unknown column order was kept'
    Assert-True (-not (Restore-ColumnOrder @('File'))) 'A short column order was kept'
    Assert-True ((@(Get-ColumnOrderNames) -join '|') -eq $before) 'A bad order changed the columns'
    [void](Restore-ColumnOrder @($script:ColumnTitles))
    Update-ChromeLayout
    [Windows.Forms.Application]::DoEvents()
    $script:SortColumn = -1
    Update-SortHeaders
    if ($script:HeaderDrag) { $script:HeaderDrag.Attach() }
    $script:Files.Items.Clear()
    Add-OverFile 'C:\Library\column-move.mkv' 2.4 2 'Bloated'
    $row = $script:Files.Items[0]
    $row.Checked = $true
    $row.Selected = $true
    $row.SubItems[3].BackColor = [Drawing.Color]::FromArgb(255, 128, 0)
    $color = $row.SubItems[3].BackColor.ToArgb()
    $sizeText = [string]$row.SubItems[3].Text
    [Windows.Forms.Application]::DoEvents()
    Assert-True (-not $script:HeaderDrag.RowsNeedPaint()) 'The file list was already waiting to paint'
    $fileX = Get-ColumnHeaderCenter 0
    $dimX = Get-ColumnHeaderCenter 1
    $script:HeaderDrag.InjectMouse(0x0201, $fileX, 10)
    $script:HeaderDrag.InjectMouse(0x0200, [int](($fileX + $dimX) / 2), 10)
    $script:HeaderDrag.InjectMouse(0x0202, $dimX, 10)
    Assert-True ($script:SortColumn -eq -1) 'Dragging a heading also sorted'
    Assert-True ($script:HeaderDrag.RowsNeedPaint()) 'Moving a heading left the current rows unpainted'
    [Windows.Forms.Application]::DoEvents()
    Assert-True ($script:Files.Columns[0].DisplayIndex -eq 1) ("Dragging File left it at display $($script:Files.Columns[0].DisplayIndex) fileX=$fileX dimX=$dimX listW=$($script:Files.ClientSize.Width) fileW=$($script:Files.Columns[0].Width)")
    Assert-True ($script:Files.Items.Count -eq 1) 'The row disappeared while a heading moved'
    $row = $script:Files.Items[0]
    Assert-True $row.Checked 'The checkbox cleared while a heading moved'
    Assert-True $row.Selected 'The selection cleared while a heading moved'
    Assert-True ($row.SubItems[3].BackColor.ToArgb() -eq $color) 'A cell color cleared while a heading moved'
    Assert-True ([string]$row.SubItems[3].Text -eq $sizeText) 'A cell value changed while a heading moved'
    for ($i = 0; $i -lt $script:Files.Columns.Count; $i++) {
        $header = $script:HeaderDrag.HeaderLeft($i)
        $cell = $script:HeaderDrag.CellLeft($i)
        $gap = [math]::Abs($cell - $header)
        Assert-True ($gap -le 30) ("Column $i ($($script:ColumnTitles[$i])) cell was $gap px from its heading (header $header cell $cell)")
    }
    $dimX = Get-ColumnHeaderCenter 1
    $script:HeaderDrag.InjectMouse(0x0201, $dimX, 10)
    $script:HeaderDrag.InjectMouse(0x0202, $dimX, 10)
    Assert-True ($script:SortColumn -eq 1) ("Clicking Dimensions sorted column $($script:SortColumn)")
    [void](Restore-ColumnOrder $saved)
    $script:Files.Items.Clear()
    $script:SortColumn = -1
    Update-SortHeaders
    $script:ColumnOrder = @($saved)
    Update-OverChoices
    Update-Buttons
}

function Set-ShowFilter([string]$Id, [bool]$On) {
    $box = $null
    if ($script:ShowBoxes) { $box = $script:ShowBoxes[$Id] }
    if (-not $box) { throw "Missing show filter $Id" }
    if ([bool]$box.Checked -ne $On) { $box.Checked = $On }
}

function Invoke-ShowCheck {
    $script:Files.Items.Clear()
    if ($script:HiddenItems) { $script:HiddenItems.Clear() }
    Add-OverFile 'C:\Library\show-slight.mkv' 2.4 2 'Bloated'
    Add-OverFile 'C:\Library\show-extreme.mkv' 10 2 'Bloated'
    $shrink = @{
        Status = 'Can shrink'
        Path = 'C:\Library\show-shrink.mkv'
        Kept = ''
        New = ''
        Source = 'C:\Library\show-shrink.mkv'
        Width = 1920
        Height = 1080
        DurationSec = 60
        SizeBytes = 100000000
        OldBytes = $null
        GiBph = 1.9
        BudgetGiBph = 2
        TargetKbps = 3000
        EstimateBytes = 20000000
        Codec = 'h264'
        PendingId = ''
        Reason = 'smoke show'
    }
    Add-ResultRow $shrink | Out-Null
    try {
        Assert-True ($script:Files.Items.Count -eq 3) 'The list hid rows before a filter was checked'
        Assert-True (-not $script:ShowBoxes['slight'].Checked) 'Slight started checked'
        Set-ShowFilter 'slight' $true
        $shown = @($script:Files.Items | ForEach-Object { [string]$_.Tag.Path })
        Assert-True ($shown.Count -eq 1 -and $shown[0] -eq 'C:\Library\show-slight.mkv') 'The first checked filter did not show only that group'
        Set-ShowFilter 'shrink' $true
        $shown = @($script:Files.Items | ForEach-Object { [string]$_.Tag.Path })
        Assert-True ($shown -contains 'C:\Library\show-slight.mkv' -and $shown -contains 'C:\Library\show-shrink.mkv') 'A second filter did not add its rows'
        Assert-True ($shown -notcontains 'C:\Library\show-extreme.mkv') 'An unchecked group stayed visible'
        $hiddenExtreme = @($script:HiddenItems.ToArray() | Where-Object { [string]$_.Tag.Path -eq 'C:\Library\show-extreme.mkv' })
        Assert-True ($hiddenExtreme.Count -eq 1 -and -not $hiddenExtreme[0].Checked) 'A hidden row stayed checked'
        Select-ShownFiles
        $checked = @($script:Files.Items | Where-Object { $_.Checked } | ForEach-Object { [string]$_.Tag.Path })
        Assert-True ($checked.Count -eq 2) ("Select shown checked $($checked.Count) rows")
        Assert-True ($script:ShowButton.Text -eq 'Showing Can shrink, Slight') ("Show button was $($script:ShowButton.Text)")
    }
    finally {
        foreach ($id in @($script:ShowOrder)) { Set-ShowFilter $id $false }
        $script:Files.Items.Clear()
        if ($script:HiddenItems) { $script:HiddenItems.Clear() }
        Update-Buttons
    }
}

function Invoke-EtaCheck {
    Assert-True ($null -ne $script:EtaLabel) 'The time line is missing'
    Assert-True ($script:EtaLabel.Parent -eq $script:StatusPanel) 'The time line is not in the status bar'
    Assert-True ([string]::IsNullOrWhiteSpace($script:EtaLabel.Text)) 'The time line started with text'
    Assert-True ($script:StatusPanel.Height -eq 58) 'The status bar started tall'
    Assert-True ($script:Tips.GetToolTip($script:EtaLabel) -match 'Estimated time remaining') 'The time line tip omitted the batch label'
    $keptWork = [string]$script:Work
    $keptStop = [bool]$script:StopAfterFile
    $keptItems = $script:EncodeItems
    $keptIndex = $script:EncodeIndex
    $keptRates8 = @($script:EtaRates8)
    $keptRates10 = @($script:EtaRates10)
    $keptRatios = @($script:EtaRatios)
    try {
        $script:EtaRates8.Clear()
        $script:EtaRates10.Clear()
        $script:EtaLive8.Clear()
        $script:EtaLive10.Clear()
        $script:EtaRatios.Clear()
        Clear-EtaWindow
        $script:Work = 'encode'
        $script:StopAfterFile = $false
        $script:EtaChecking = $false
        $script:EtaRemembered = $false
        $script:EtaTenBit = $false
        $script:EtaPass1Sec = 20
        $script:EtaTask = 2
        $script:EtaPixels = 1000
        $script:EtaPassStart = [datetime]::UtcNow.AddSeconds(-60)
        $script:EtaProgress = Get-HandBrakeProgress 'Encoding: task 2 of 2, 50.00 % (8.00 fps, avg 8.00 fps, ETA 00h01m00s)'
        $later = New-Object Windows.Forms.ListViewItem 'later.mkv'
        $later.Tag = @{ Width = 100; Height = 100; DurationSec = 12; TenBit = $false }
        $script:EncodeItems = @($later)
        $script:EncodeIndex = 0
        Update-EtaLine
        Assert-True ($script:EtaLabel.Text -match 'Estimated time remaining: ') ("The batch line omitted its label: $($script:EtaLabel.Text)")
        Assert-True ($script:EtaLabel.Text -notmatch 'Estimated time remaining: estimating') ("A measured batch stayed on estimating: $($script:EtaLabel.Text)")
        $held = [string]$script:EtaLabel.Text
        $script:EtaProgress = Get-HandBrakeProgress 'Encoding: task 2 of 2, 50.00 % (8.00 fps, avg 8.00 fps, ETA 00h05m00s)'
        Update-EtaLine
        Assert-True ($script:EtaLabel.Text -eq $held) ("The time line moved before 30 seconds: $($script:EtaLabel.Text)")
        $script:EtaShownAt = [datetime]::UtcNow.AddSeconds(-31)
        Update-EtaLine
        Assert-True ($script:EtaLabel.Text -ne $held) ("The time line stayed after 30 seconds: $($script:EtaLabel.Text)")
        $script:EtaProgress = Get-HandBrakeProgress 'Encoding: task 2 of 2, 50.00 % (8.00 fps, avg 8.00 fps, ETA 00h01m00s)'
        Assert-True ($script:EtaLabel.Visible) 'The time line stayed hidden'
        Assert-True ($script:StatusPanel.Height -eq 78) 'The status bar did not grow for the time line'
        Assert-True ($script:ProgressTrack.Top -gt $script:EtaLabel.Top) 'The bar covered the time line'
        Assert-True ($script:EtaLabel.Right -le ($script:StatusPanel.ClientSize.Width - 8)) 'The time line sits outside the status bar'
        $script:StopAfterFile = $true
        Update-EtaLine
        Assert-True ($script:EtaLabel.Text -eq 'This file: about 2 min left. Estimated time remaining: about 2 min') ("Stop after left the batch on $($script:EtaLabel.Text)")
        $script:StopAfterFile = $false
        $script:EtaTask = 1
        $script:EtaPass1Sec = 0
        $script:EtaRatios.Clear()
        $script:EtaProgress = Get-HandBrakeProgress 'Encoding: task 1 of 2, 10.00 % (avg 20.00 fps, ETA 00h02m00s)'
        Update-EtaLine
        Assert-True ($script:EtaLabel.Text -match 'first pass') ("The first pass was labeled as the whole file: $($script:EtaLabel.Text)")
        Assert-True ($script:EtaLabel.Text -match 'Estimated time remaining: estimating') ("The first pass invented a batch time: $($script:EtaLabel.Text)")
    }
    finally {
        $script:Work = $keptWork
        $script:StopAfterFile = $keptStop
        $script:EncodeItems = $keptItems
        $script:EncodeIndex = $keptIndex
        $script:EtaRates8.Clear()
        $script:EtaRates10.Clear()
        $script:EtaLive8.Clear()
        $script:EtaLive10.Clear()
        $script:EtaRatios.Clear()
        Clear-EtaWindow
        foreach ($rate in @($keptRates8)) { if ($rate -gt 0) { [void]$script:EtaRates8.Add([double]$rate) } }
        foreach ($rate in @($keptRates10)) { if ($rate -gt 0) { [void]$script:EtaRates10.Add([double]$rate) } }
        foreach ($ratio in @($keptRatios)) { if ($ratio -gt 0) { [void]$script:EtaRatios.Add([double]$ratio) } }
        $script:EtaPassStart = $null
        $script:EtaPass1Sec = 0
        $script:EtaTask = 0
        $script:EtaPixels = 0
        $script:EtaTenBit = $false
        $script:EtaRemembered = $false
        $script:EtaChecking = $false
        Clear-EtaLine
    }
}

function Invoke-ListSplitCheck {
    Assert-True ($null -ne $script:ListSplit) 'The video list has no resize bar'
    Assert-True ($script:ListSplit.Cursor -eq [Windows.Forms.Cursors]::SizeNS) 'The resize bar does not show a resize pointer'
    Assert-True ($script:MainTable.GetRow($script:Files) -eq $script:ListRow) 'The video list left its row'
    Assert-True ($script:MainTable.GetRow($script:ListSplit) -eq ($script:ListRow + 1)) 'The resize bar is not under the video list'
    Assert-True ($script:MainTable.GetRow($script:OptionsCard) -eq $script:OptionsRow) 'Options left its row'
    $tip = [string]$script:Tips.GetToolTip($script:ListSplit)
    Assert-True ($tip -eq 'Drag to make the video list taller or shorter. Double-click to put it back.') ("List resize tip was $tip")
    $kept = [int]$script:ListExtra
    $keptLog = 0
    if ($null -ne $script:LogExtra) { $keptLog = [int]$script:LogExtra }
    $script:LogExtra = 0
    Set-ListExtra 0
    [Windows.Forms.Application]::DoEvents()
    $plan0 = Get-ListSplitPlan 0
    Assert-True ($plan0.Ready) 'The list split has no room'
    Assert-True ([Math]::Abs([double]$script:MainTable.RowStyles[$script:ListRow].Height - $plan0.List) -lt 1.1) 'The video list ignored its height'
    Assert-True ([Math]::Abs([double]$script:MainTable.RowStyles[$script:OptionsRow].Height - $plan0.Options) -lt 1.1) 'Options changed when the list was put back'
    $used = [double]$script:MainTable.Padding.Top + [double]$script:MainTable.Padding.Bottom
    for ($i = 0; $i -lt $script:MainTable.RowStyles.Count; $i++) { $used += [double]$script:MainTable.RowStyles[$i].Height }
    $gap = [double]$script:MainTable.ClientSize.Height - $used
    Assert-True ($gap -ge -1.5 -and $gap -lt 4) ("The list split left a gap of $gap")
    $taller = Get-ListSplitPlan 80
    Set-ListExtra 80
    [Windows.Forms.Application]::DoEvents()
    Assert-True ($taller.List -gt $plan0.List) 'Dragging down did not make the video list taller'
    Assert-True ([Math]::Abs([double]$script:MainTable.RowStyles[$script:ListRow].Height - $taller.List) -lt 1.1) 'The video list did not keep the dragged height'
    Assert-True ($taller.Options -ge $script:OptionsSplitMin) 'Options shrank past its minimum'
    Assert-True ($taller.Options -le $plan0.Options) 'Options grew while the list grew'
    Assert-True ($taller.Log -le $plan0.Log) 'The activity box grew while the list grew'
    $shorter = Get-ListSplitPlan -80
    Set-ListExtra -80
    [Windows.Forms.Application]::DoEvents()
    Assert-True ($shorter.List -lt $plan0.List) 'Dragging up did not make the video list shorter'
    Assert-True ([Math]::Abs([double]$script:MainTable.RowStyles[$script:ListRow].Height - $shorter.List) -lt 1.1) 'The shorter video list was not applied'
    Assert-True ($shorter.Options -eq $plan0.Options) 'Making the list shorter changed Options'
    Set-ListExtra 0
    [Windows.Forms.Application]::DoEvents()
    Assert-True ([int]$script:ListExtra -eq 0) 'The video list did not return to its normal height'
    $script:LogExtra = $keptLog
    if ($kept -ne 0) { Set-ListExtra $kept } else { Set-ListExtra 0 }
}

function Invoke-SmokeTest {
    $missing = @(Get-MissingTools)
    Assert-True ($missing.Count -eq 0) ("Missing tools: " + ($missing -join ', '))
    Assert-True ($script:Log.Text -match 'Choose a folder') 'Startup text was missing'
    $fraction = Get-HandBrakeFraction 'Encoding: task 1 of 2, 50 %'
    Assert-True ([math]::Abs($fraction - 25) -lt 0.01) 'Progress parser'
    $script:Form.Show()
    Update-ChromeLayout
    Set-ListExtra 0
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 200
    [Windows.Forms.Application]::DoEvents()
    Invoke-EtaCheck
    Invoke-FolderSelectCheck
    Invoke-OverCheck
    Invoke-ShowCheck
    Invoke-ColumnOrderCheck
    Invoke-BudgetCheck
    Invoke-ClearCheck
    Save-FormImage $script:Form (Join-Path $env:TEMP 'vdh-main.png')
    Show-Help
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 200
    Save-FormImage $script:HelpForm (Join-Path $env:TEMP 'vdh-help.png')
    Assert-True (@($script:Lanes).Count -eq 6) 'Encode lanes did not go to six'
    Assert-True (@($script:JobRows).Count -eq 6) 'Job bars did not go to six'
    Assert-True ($script:JobBox.Items.Count -eq 6) 'Jobs at once is missing a level'
    Assert-True ([string]$script:JobBox.Items[0] -eq '1') 'Jobs at once does not start at one'
    Assert-True ([string]$script:JobBox.Items[5] -eq '6') 'Jobs at once does not go to six'
    Assert-True ((Get-JobCount) -ge 1 -and (Get-JobCount) -le 6) 'Jobs at once was out of range'
    $jobTip = Get-JobTip
    Assert-True ($jobTip -match '16 cores' -and $jobTip -match '48 cores' -and $jobTip -match 'does not finish sooner') 'The jobs tip skipped an efficiency level'
    Assert-True ([string]$script:Tips.GetToolTip($script:JobBox) -eq $jobTip) 'The jobs dropdown has no efficiency tip'
    Assert-True ($script:JobLabel.Text -eq 'Parallel jobs') 'Parallel jobs label'
    Assert-True ($script:JobBox.Parent -eq $script:ActionPanel) 'Parallel jobs left the action row'
    Assert-True ($script:JobBox.Right -le ($script:FindLabel.Left + 1)) 'Parallel jobs is not left of Find'
    Assert-True ($script:JobLabel.Right -le ($script:JobBox.Left + 1)) 'Parallel jobs label overlaps its dropdown'
    $script:ProgressPaintAt = [datetime]::UtcNow
    Assert-True (-not (Test-ProgressPaintDue)) 'The status bar would repaint too often'
    $script:ProgressPaintAt = [datetime]::UtcNow.AddSeconds(-2)
    Assert-True (Test-ProgressPaintDue) 'The status bar would stay frozen'
    $script:ProgressPaintAt = $null
    Assert-True ($script:HelpBox.Text -match '12000 kbps') 'The guide was missing the 4K rate'
    Assert-True ($script:HelpBox.Text -match 'from 1 to 6') 'The guide was missing jobs at once'
    Assert-True ($script:HelpBox.Text -match '\.vd-originals') 'The guide was missing the holding folder'
    Assert-True ($script:HelpBox.Text -match 'Select folder') 'The guide was missing folder selection'
    Assert-True ($script:HelpBox.Text -match 'Slight' -and $script:HelpBox.Text -match 'Extreme') 'The guide was missing overage groups'
    Assert-True ($script:HelpBox.Text -match 'Estimated savings') 'The guide was missing the savings total'
    Assert-True ($script:HelpBox.Text -match 'Drag a heading sideways') 'The guide was missing column dragging'
    Assert-True ($script:HelpBox.Text -match 'Drag the bar under the list') 'The guide was missing the list resize bar'
    Assert-True ($script:HelpBox.Text -match 'starts on Recommended') 'The guide was missing the budget choices'
    Assert-True ($script:HelpBox.Text -match 'one-minute countdown') 'The guide was missing shutdown'
    Assert-True ($script:HelpBox.Text -match 'Undo puts back the last conversion') 'The guide was missing undo'
    Assert-True ($script:HelpBox.Text -match '\.plexignore file is removed') 'The guide was missing plexignore cleanup'
    Show-Help 'Drive recycle bin'
    Assert-True ($script:HelpMarks.Contains('Drive recycle bin')) 'The guide has no recycle section'
    Assert-True ($script:HelpBox.SelectionStart -eq [int]$script:HelpMarks['Drive recycle bin']) 'The guide did not open at the recycle steps'
    Assert-True ($script:HelpBox.Text -match '#recycle') 'The guide was missing the drive recycle bin'
    Assert-True ($script:HelpBox.Text -match 'size has to match') 'The guide was missing the recycle size check'
    Assert-True ($script:HelpBox.Text -match 'recycled copy contains only the lines') 'The guide was missing the plexignore recycle rule'
    Assert-True ($script:HelpBox.Text -match 'another computer can finish') 'The guide was missing the empty recycle folder rule'
    Assert-True ($script:HelpBox.Text -match "Don't show this in the future") 'The guide was missing the delete confirmation choice'
    Assert-True ($script:HelpBox.Text -match 'Remove-Item -LiteralPath') 'The guide was missing the recycle removal command'
    Assert-True ($script:HelpBox.Text -match "find '/volume1/share/#recycle'") 'The guide was missing the SSH recycle command'
    Assert-True ($script:Tips.GetToolTip($script:DeleteButton) -match '#recycle') 'Delete tooltip missed the recycle bin'
    Assert-True ($script:Tips.GetToolTip($script:AutoCheck) -match '#recycle') 'Auto tooltip missed the recycle bin'
    Assert-True ($script:Tips.GetToolTip($script:HelpButton) -match 'drive recycle bin') 'Help tooltip missed the recycle steps'
    Assert-True ($script:UndoButton.Text -eq 'Undo') 'Undo button was missing'
    Assert-True ($script:HelpBox.Text -match 'Check for updates') 'The guide was missing updates'
    Assert-True ($script:HelpBox.Text -match 'a window tells you') 'The guide was missing the update window'
    Assert-True ($script:HelpBox.Text -match 'Clear removes the scanned files') 'The guide was missing Clear'
    Assert-True ($script:HelpBox.Text -match 'starts with a tilde') 'The guide was missing the rough new size'
    Assert-True ($script:HelpBox.Text -match 'does not judge how the picture looks') 'The guide was missing the auto warning'
    Assert-True ($script:HelpBox.Text -match 'asks before every convert') 'The guide was missing the convert warning'
    Assert-True ($script:HelpBox.Text -match 'Stop asking on that window hides it from then on') 'The guide was missing Stop asking'
    Assert-True ($script:HelpBox.Text -match 'does not add a line for each percent') 'The guide was missing the activity percent note'
    Assert-True ($script:HelpBox.Text -match 'Estimated time remaining is the rest of the batch') 'The guide was missing the batch time'
    Assert-True ($script:HelpBox.Text -match 'changes about every 30 seconds') 'The guide was missing the steady time line'
    Assert-True ($script:HelpBox.Text -match 'will not stay in sync with the picture') 'The guide was missing the compare sync note'
    Assert-True ($script:HelpBox.Text -match 'Go to the file on disk to confirm the audio') 'The guide was missing the disk audio note'
    Assert-True ($script:HelpBox.Text -match 'checks for updates when it opens') 'The guide was missing the startup update check'
    Assert-True ($script:HelpBox.Text -match 'Windows Media Audio') 'The guide was missing the re-encode note'
    Assert-True ($script:HelpBox.Text -match 'marked Skipped') 'The guide was missing the skip note'
    Assert-True ($script:HelpBox.Text -match 'Clear skips forgets those marks') 'The guide was missing Clear skips'
    Assert-True (Test-EncodeProgressLine 'Encoding: task 1 of 2, 50.00 % (12.00 fps, avg 10.00 fps, ETA 00h00m10s)') 'An encode percent was treated as a step'
    Assert-True (Test-EncodeProgressLine 'Muxing: 40 %') 'A mux percent was treated as a step'
    Assert-True (-not (Test-EncodeProgressLine '[00:00:01] hb_init: starting libhb thread')) 'A real encode step was hidden'
    Write-Activity 'TASK-START smoke' 'text'
    Start-ActivityPulse
    $lastPulse = @($script:Log.Text -split '\r?\n' | Where-Object { $_ -ne '' })[-1]
    Assert-True ($lastPulse -eq 'Working  |') 'The working mark did not appear'
    $lines = @($script:Log.Text -split '\r?\n')
    $script:PulseStamp = [datetime]::MinValue
    Update-ActivityPulse
    $turned = @($script:Log.Text -split '\r?\n')
    $lastTurn = @($turned | Where-Object { $_ -ne '' })[-1]
    Assert-True ($turned.Count -eq $lines.Count) 'The working mark added a line'
    Assert-True ($lastTurn -eq 'Working  /') 'The working mark did not turn'
    Write-Activity 'TASK-STEP smoke' 'dim'
    $afterStep = @($script:Log.Text -split '\r?\n' | Where-Object { $_ -ne '' })
    Assert-True ($afterStep -contains 'TASK-STEP smoke') 'A step was dropped while the mark was showing'
    Assert-True ($afterStep[-1] -eq 'Working  /') 'The working mark did not stay on the last line'
    Assert-True ($afterStep[-2] -eq 'TASK-STEP smoke') 'The step did not stay above the working mark'
    Stop-ActivityPulse
    $afterStop = @($script:Log.Text -split '\r?\n' | Where-Object { $_ -ne '' })[-1]
    Assert-True ($afterStop -eq 'TASK-STEP smoke') 'The working mark stayed after the job'
    Assert-True ($script:HelpBox.Text -match 'bottom right corner shows this copy') 'The guide was missing the version corner'
    Assert-True ($script:CheckUpdateButton.Text -eq 'Check for updates') 'Check for updates was missing'
    Assert-True (-not $script:UpdateButton.Enabled) 'Update started enabled'
    Assert-True ($script:CheckUpdateButton.Parent -eq $script:Header) 'Check for updates is not in the header'
    Assert-True ((Get-AppVersion) -eq '1.0.9.4') 'Version file was not 1.0.9.4'
    Assert-True ($null -ne $script:Form.Icon) 'The window has no icon'
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $script:Root 'Video Dehydrator.lnk'))
    Assert-True ($shortcut.IconLocation -match 'vd-icon\.ico') 'The shortcut icon was not vd-icon.ico'
    Assert-True ($script:DonateButton.Text -eq 'Donate') 'Donate was missing'
    Assert-True ($script:ReportBugButton.Text -eq 'Report a bug') 'Report a bug was missing'
    Assert-True ($script:DonateButton.Parent -eq $script:Header) 'Donate is not in the header'
    Assert-True ($script:Tips.GetToolTip($script:DonateButton) -eq 'Free forever. Tips of $5 or more can include a feature suggestion.') 'Donate tooltip'
    Assert-True ($script:Tips.GetToolTip($script:ReportBugButton) -match 'GitHub bug report') 'Report a bug tooltip'
    $bugUrl = Get-BugReportUrl
    Assert-True ($bugUrl.StartsWith('https://github.com/philipvern-dot/video-dehydrator/issues/new?template=bug_report.yml&')) 'Bug report link was not the GitHub form'
    Assert-True ($bugUrl -match 'version=1\.0\.9\.4') 'Bug report link was missing the version'
    Assert-True ($bugUrl -match 'windows=Windows%20(10|11)%20\(build%20\d+\)') 'Bug report link was missing the Windows version'
    Assert-True ($script:HelpBox.Text -match 'Report a bug opens a GitHub page') 'The guide was missing Report a bug'
    Assert-True ($script:HelpBox.Text -match 'Include latest activity is a choice') 'The guide was missing the activity choice'
    $plainBug = Get-BugReportUrl
    Assert-True ($plainBug -notmatch 'activity=') 'The bug report link added activity on its own'
    $script:Log.Clear()
    Write-Activity 'older activity line' 'text'
    Write-Activity 'LATEST-ACTIVITY-MARK' 'text'
    Start-ActivityPulse
    $withPulse = Get-LatestActivityText
    Stop-ActivityPulse
    Assert-True ($withPulse -match 'LATEST-ACTIVITY-MARK') 'Latest activity was dropped'
    Assert-True ($withPulse -match 'older activity line') 'Earlier activity was dropped'
    Assert-True ($withPulse -notmatch 'Working') 'The working mark was included'
    $filledBug = Get-BugReportUrl $withPulse
    Assert-True ($filledBug -match 'activity=older%20activity%20line%0ALATEST-ACTIVITY-MARK') 'The activity was not added to the bug report link'
    $script:Log.Clear()
    Write-Activity ('Y' * 20000) 'text'
    Write-Activity 'TAIL-MARK' 'text'
    $capped = Get-LatestActivityText
    Assert-True ($capped.EndsWith('TAIL-MARK')) 'The latest activity line was trimmed off'
    Assert-True (([uri]::EscapeDataString($capped)).Length -le 4500) 'The activity text was too long for the link'
    $script:Log.Clear()
    $emptyBugForm = New-BugReportForm
    try {
        $emptyBox = @($emptyBugForm.Controls) | Where-Object { $_.Text -eq 'Include latest activity' } | Select-Object -First 1
        Assert-True ($null -ne $emptyBox) 'Include latest activity was missing'
        Assert-True (-not $emptyBox.Checked) 'Include latest activity started checked'
        Assert-True (-not $emptyBox.Enabled) 'Include latest activity stayed available when the activity box was empty'
    }
    finally { if (-not $emptyBugForm.IsDisposed) { $emptyBugForm.Dispose() } }
    Write-Activity 'choice activity' 'text'
    $bugForm = New-BugReportForm
    try {
        $bugForm.StartPosition = 'Manual'
        $bugForm.Location = New-Object Drawing.Point(-32000, -32000)
        $bugForm.Show()
        $choice = @($bugForm.Controls) | Where-Object { $_.Text -eq 'Include latest activity' } | Select-Object -First 1
        Assert-True ($choice.Enabled) 'Include latest activity stayed off when the activity box had text'
        Assert-True (-not $choice.Checked) 'Include latest activity started checked'
        $openReport = @($bugForm.Controls) | Where-Object { $_.Text -eq 'Open report' } | Select-Object -First 1
        $openReport.PerformClick()
        Assert-True ($bugForm.Tag.Open -and -not $bugForm.Tag.Include) 'Open report included activity without the box'
        if (-not $bugForm.IsDisposed) { $bugForm.Close() }
    }
    finally { if (-not $bugForm.IsDisposed) { $bugForm.Dispose() } }
    $checkedForm = New-BugReportForm
    try {
        $checkedForm.StartPosition = 'Manual'
        $checkedForm.Location = New-Object Drawing.Point(-32000, -32000)
        $checkedForm.Show()
        $choice = @($checkedForm.Controls) | Where-Object { $_.Text -eq 'Include latest activity' } | Select-Object -First 1
        $choice.Checked = $true
        $openReport = @($checkedForm.Controls) | Where-Object { $_.Text -eq 'Open report' } | Select-Object -First 1
        $openReport.PerformClick()
        Assert-True ($checkedForm.Tag.Open -and $checkedForm.Tag.Include) 'Open report left the activity choice off'
        if (-not $checkedForm.IsDisposed) { $checkedForm.Close() }
    }
    finally { if (-not $checkedForm.IsDisposed) { $checkedForm.Dispose() } }
    Assert-True ($script:VersionLabel.Text -eq (Get-AppVersion)) 'Version label did not show the version'
    Assert-True ($script:VersionLabel.Parent -eq $script:StatusPanel) 'Version is not in the status bar'
    Assert-True ((Compare-AppVersion '1.0.1' '1.0.0') -eq 1) 'A newer version compared as older'
    Assert-True ((Compare-AppVersion '1.0.1' '1.0.1') -eq 0) 'The same version did not match'
    Assert-True ((Compare-AppVersion '1.0.1' '1.0.2') -eq -1) 'An older version compared as newer'
    Assert-True ($null -eq (Compare-AppVersion 'not-a-version' '1.0.1')) 'A name was treated as a version'
    Assert-True ((Compare-AppVersion 'v1.2.0' '1.1.9') -eq 1) 'A v prefix was not read'
    Assert-True ((Compare-AppVersion '1.0.4.1' '1.0.4') -eq 1) 'A fourth version number was ignored'
    Assert-True ((Compare-AppVersion '1.0.4' '1.0.4.0') -eq 0) 'A missing fourth number did not match zero'
    $sameOffer = Get-UpdateOffer ([pscustomobject]@{
        tag_name = 'v1.0.6.1'
        assets = @([pscustomobject]@{ name = 'video_dehydrator.exe'; browser_download_url = 'https://github.com/philipvern-dot/video-dehydrator/releases/download/v1.0.6.1/video_dehydrator.exe'; size = 12 })
    })
    Assert-True (-not $sameOffer.Newer) 'The current version was offered as an update'
    $bareOffer = Get-UpdateOffer ([pscustomobject]@{ tag_name = 'v9.9.9'; assets = @() })
    Assert-True ($bareOffer.Message -match 'setup program') 'A release without a setup program was accepted'
    $offer = Get-UpdateOffer ([pscustomobject]@{
        tag_name = 'v9.9.9'
        assets = @([pscustomobject]@{ name = 'video_dehydrator.exe'; browser_download_url = 'https://github.com/philipvern-dot/video-dehydrator/releases/download/v9.9.9/video_dehydrator.exe'; size = 12 })
    })
    Assert-True ($offer.Newer) 'A newer release was not offered'
    Apply-UpdateOffer $offer
    Assert-True ($script:UpdateButton.Enabled) 'Update stayed disabled after a newer release'
    $script:Work = 'encode'
    Update-UpdateButtons
    Assert-True ((-not $script:CheckUpdateButton.Enabled) -and (-not $script:UpdateButton.Enabled)) 'Update buttons stayed enabled during a job'
    $script:Work = 'idle'
    $script:UpdateOffer = $null
    Update-UpdateButtons
    Assert-True ($script:CheckUpdateButton.Enabled -and -not $script:UpdateButton.Enabled) 'Update buttons did not return to normal after the job'
    $script:Work = 'encode'
    $script:StopAfterFile = $false
    Update-Buttons
    Assert-True ($script:StopAfterButton.Enabled -and -not $script:ContinueButton.Enabled) 'Stop after this file was not available during a convert'
    $script:StopAfterFile = $true
    Update-Buttons
    Assert-True ((-not $script:StopAfterButton.Enabled) -and $script:ContinueButton.Enabled) 'Continue did not take over from Stop after this file'
    $script:Work = 'scan'
    Update-Buttons
    Assert-True ((-not $script:StopAfterButton.Enabled) -and (-not $script:ContinueButton.Enabled)) 'Stop after this file stayed available during a scan'
    $script:Work = 'idle'
    $script:StopAfterFile = $false
    Update-Buttons
    Assert-True ($script:HelpBox.Text -match 'Stop after current file lets that file finish') 'The guide was missing Stop after current file'
    Assert-True ($script:HelpBox.Text -match 'Test savings reads those files') 'The guide was missing Manual'
    Assert-True ($script:HelpBox.Text -match 'Manual converts a chosen file') 'The guide still calls the button Force'
    Assert-True ($script:ForceButton.Text -eq 'Manual') 'The Manual button was renamed'
    $manualTip = [string]$script:Tips.GetToolTip($script:ForceButton)
    Assert-True ($manualTip -eq 'Convert a file or folder even when it is under the budget.') ("Manual tip was $manualTip")
    Assert-True (($manualTip.Split('.').Count -le 3) -and ($manualTip.Length -le 120)) 'The Manual tip is too long'
    Assert-True ($script:ForceButton.Parent -eq $script:ActionPanel) 'Manual is outside the action row, so a disabled tip cannot show'
    $manualNeed = $script:ForceButton.GetPreferredSize((New-Object Drawing.Size(0, 0))).Width
    Assert-True ($manualNeed -le $script:ForceButton.Width) ("Manual is clipped (" + $manualNeed + " in " + $script:ForceButton.Width + ")")
    $script:Work = 'scan'
    Update-Buttons
    Assert-True (-not $script:ForceButton.Enabled) 'Manual stayed enabled during a scan'
    Assert-True ([string]$script:Tips.GetToolTip($script:ForceButton) -eq $manualTip) 'The disabled Manual tip changed'
    $script:Work = 'idle'
    Update-Buttons
    Assert-True ($script:ForceButton.Left -ge $script:ContinueButton.Right) 'Force overlaps Continue'
    Assert-True ($script:ForceButton.Bottom -le $script:ActionPanel.ClientSize.Height) 'Force sits outside the action row'
    $forcePick = New-ForcePickForm
    try {
        $forcePick.StartPosition = 'Manual'
        $forcePick.Location = New-Object Drawing.Point(-32000, -32000)
        $forcePick.Show()
        $forceLabel = @($forcePick.Controls) | Where-Object { $_ -is [Windows.Forms.Label] } | Select-Object -First 1
        $forceNeed = $forceLabel.GetPreferredSize((New-Object Drawing.Size($forceLabel.Width, 0))).Height
        Assert-True ($forceNeed -le $forceLabel.Height) ("The force window is clipped (" + $forceNeed + " in " + $forceLabel.Height + ")")
        $forceTest = @($forcePick.Controls) | Where-Object { $_.Text -eq 'Test savings' } | Select-Object -First 1
        $forceNow = @($forcePick.Controls) | Where-Object { $_.Text -eq 'Convert now' } | Select-Object -First 1
        $forceCancel = @($forcePick.Controls) | Where-Object { $_.Text -eq 'Cancel' } | Select-Object -First 1
        Assert-True ($null -ne $forceTest -and $null -ne $forceNow -and $null -ne $forceCancel) 'The force window is missing a choice'
        Assert-True ($forceTest.Bottom -le $forcePick.ClientSize.Height) 'Test savings sits outside the force window'
        Assert-True ($forcePick.Tag.Choice -eq 'cancel') 'The force window started confirmed'
        $forceTest.PerformClick()
        Assert-True ($forcePick.Tag.Choice -eq 'test') 'Test savings did not stay on the estimate'
        if (-not $forcePick.IsDisposed) { $forcePick.Close() }
    }
    finally { if (-not $forcePick.IsDisposed) { $forcePick.Dispose() } }
    $forceNowForm = New-ForcePickForm
    try {
        $forceNowForm.StartPosition = 'Manual'
        $forceNowForm.Location = New-Object Drawing.Point(-32000, -32000)
        $forceNowForm.Show()
        $forceNowBtn = @($forceNowForm.Controls) | Where-Object { $_.Text -eq 'Convert now' } | Select-Object -First 1
        $forceNowBtn.PerformClick()
        Assert-True ($forceNowForm.Tag.Choice -eq 'convert') 'Convert now still estimated first'
        if (-not $forceNowForm.IsDisposed) { $forceNowForm.Close() }
    }
    finally { if (-not $forceNowForm.IsDisposed) { $forceNowForm.Dispose() } }
    $forceStop = New-ForcePickForm
    try {
        $forceStop.StartPosition = 'Manual'
        $forceStop.Location = New-Object Drawing.Point(-32000, -32000)
        $forceStop.Show()
        $forceStopBtn = @($forceStop.Controls) | Where-Object { $_.Text -eq 'Cancel' } | Select-Object -First 1
        $forceStopBtn.PerformClick()
        Assert-True ($forceStop.Tag.Choice -eq 'cancel') 'Cancel started a force convert'
        if (-not $forceStop.IsDisposed) { $forceStop.Close() }
    }
    finally { if (-not $forceStop.IsDisposed) { $forceStop.Dispose() } }
    $forceReport = New-ForceReportForm "2 files can be converted." $true
    try {
        $forceReport.StartPosition = 'Manual'
        $forceReport.Location = New-Object Drawing.Point(-32000, -32000)
        $forceReport.Show()
        $forceGo = @($forceReport.Controls) | Where-Object { $_.Text -eq 'Proceed' } | Select-Object -First 1
        Assert-True ($forceGo.Enabled) 'Proceed was disabled when files can be converted'
        Assert-True (-not $forceReport.Tag.Proceed) 'The savings report started confirmed'
        $forceGo.PerformClick()
        Assert-True ($forceReport.Tag.Proceed) 'Proceed did not continue'
        if (-not $forceReport.IsDisposed) { $forceReport.Close() }
    }
    finally { if (-not $forceReport.IsDisposed) { $forceReport.Dispose() } }
    $forceEmpty = New-ForceReportForm 'No video files were found.' $false
    try {
        $forceEmpty.StartPosition = 'Manual'
        $forceEmpty.Location = New-Object Drawing.Point(-32000, -32000)
        $forceEmpty.Show()
        $forceNo = @($forceEmpty.Controls) | Where-Object { $_.Text -eq 'Proceed' } | Select-Object -First 1
        Assert-True (-not $forceNo.Enabled) 'Proceed stayed available when nothing can be converted'
        if (-not $forceEmpty.IsDisposed) { $forceEmpty.Close() }
    }
    finally { if (-not $forceEmpty.IsDisposed) { $forceEmpty.Dispose() } }
    Assert-True ($script:StopAfterButton.Text -eq 'Stop after current file') ("Stop button was $($script:StopAfterButton.Text)")
    foreach ($pair in @(
        @{ Name = 'Stop after current file'; Button = $script:StopAfterButton },
        @{ Name = 'Continue'; Button = $script:ContinueButton },
        @{ Name = 'Showing all'; Button = $script:ShowButton },
        @{ Name = 'Select shown'; Button = $script:SelectShownButton },
        @{ Name = 'Optimize'; Button = $script:ConvertButton },
        @{ Name = 'Manual'; Button = $script:ForceButton }
    )) {
        $tip = [string]$script:Tips.GetToolTip($pair.Button)
        Assert-True (-not [string]::IsNullOrWhiteSpace($tip)) ("$($pair.Name) has no tooltip")
    }
    Assert-True ($script:HelpBox.Text -match 'Closing that window keeps it from opening again') 'The guide was missing the one-time update window'
    $keptPrompt = [string]$script:UpdatePrompt
    $script:UpdatePrompt = ''
    $script:UpdateOffer = $null
    Assert-True (Test-UpdatePromptDue $offer) 'A new version did not ask'
    Remember-UpdatePrompt '9.9.9'
    Assert-True ($script:UpdatePrompt -eq '9.9.9') 'The dismissed version was forgotten'
    Assert-True (-not (Test-UpdatePromptDue $offer)) 'The same version asked again'
    $laterOffer = Get-UpdateOffer ([pscustomobject]@{
        tag_name = 'v9.9.10'
        assets = @([pscustomobject]@{ name = 'video_dehydrator.exe'; browser_download_url = 'https://github.com/philipvern-dot/video-dehydrator/releases/download/v9.9.10/video_dehydrator.exe'; size = 12 })
    })
    Assert-True (Test-UpdatePromptDue $laterOffer) 'A later version stayed quiet'
    $script:UpdateOffer = $offer
    Set-Status 'Ready' 'idle'
    Assert-True ($script:StatusLabel.Text -eq 'Version 9.9.9 is available.') 'The status line dropped the new version'
    Set-Status 'Listing videos...' 'busy'
    Assert-True ($script:StatusLabel.Text -eq 'Listing videos...') 'The scan status was replaced by the update'
    Set-Status 'Scan stopped' 'idle'
    Assert-True ($script:StatusLabel.Text -eq 'Scan stopped. Version 9.9.9 is available.') 'The update left the status line'
    $script:UpdateOffer = $null
    $script:UpdatePrompt = ''
    Set-Status 'Ready' 'idle'
    Assert-True ($script:StatusLabel.Text -eq 'Ready') 'An old update stayed after it was cleared'
    $script:UpdatePrompt = '9.9.9'
    Set-Status 'Ready' 'idle'
    Assert-True ($script:StatusLabel.Text -eq 'Version 9.9.9 is available.') 'A dismissed version left the status line'
    $script:UpdatePrompt = $keptPrompt
    $script:UpdateOffer = $null
    Set-Status 'Ready' 'idle'
    $keptWidth = $script:Form.ClientSize.Width
    $script:Form.ClientSize = New-Object Drawing.Size(900, $script:Form.ClientSize.Height)
    Update-ChromeLayout
    Assert-True ($script:TitleLabel.Right -le $script:CheckUpdateButton.Left) 'The title overlaps Check for updates'
    Assert-True ($script:UpdateButton.Right -le ($script:Header.ClientSize.Width - 8)) 'Update sits outside the header'
    Assert-True ($script:ReportBugButton.Right -le ($script:Header.ClientSize.Width - 8)) 'Report a bug sits outside the header'
    Assert-True ($script:DonateButton.Right -le ($script:ReportBugButton.Left + 1)) 'Donate overlaps Report a bug'
    Assert-True ($script:DonateButton.Top -ge $script:UpdateButton.Bottom) 'Donate overlaps the update buttons'
    Assert-True ($script:TitleLabel.Right -le $script:DonateButton.Left) 'The title overlaps Donate'
    Assert-True ($script:VersionLabel.Right -le ($script:StatusPanel.ClientSize.Width - 8)) 'Version sits outside the status bar'
    Assert-True ($script:StatusLabel.Right -le ($script:VersionLabel.Left + 1)) 'Status overlaps the version'
    Assert-True ($script:FolderPick.Right -le ($script:SelectFolderButton.Left + 1)) 'Folder list overlaps Select folder'
    Assert-True ($script:SelectFolderButton.Right -le ($script:OverPick.Left + 1)) 'Select folder overlaps the overage list'
    Assert-True ($script:OverPick.Right -le ($script:SelectOverButton.Left + 1)) 'Overage list overlaps its button'
    Assert-True ($script:ClearButton.Text -eq 'Clear') 'Clear was missing'
    Assert-True ($script:ClearButton.Right -le ($script:ListHeader.ClientSize.Width + 1)) 'Clear sits outside the list header'
    Assert-True ($script:SelectNoneButton.Right -le ($script:ClearButton.Left + 1)) 'Deselect all overlaps Clear'
    $script:Form.ClientSize = New-Object Drawing.Size($keptWidth, $script:Form.ClientSize.Height)
    Update-ChromeLayout
    Invoke-ListSplitCheck
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
    $keptWarn = [bool]$script:AutoWarnAccepted
    $keptShown = [bool]$script:AutoWarnShown
    $script:AutoWarnAccepted = $false
    $script:AutoWarnShown = $false
    Assert-True (Test-AutoWarnPending) 'Auto warning was hidden before a choice'
    Assert-True (-not (Apply-AutoWarnChoice 'off' $true)) 'Leaving auto off was accepted'
    Assert-True (-not $script:AutoWarnAccepted) 'Leaving auto off hid the warning'
    Assert-True (Test-AutoWarnPending) 'The warning stayed after leaving auto off'
    Assert-True (Apply-AutoWarnChoice 'on' $false) 'Turning auto on was refused'
    Assert-True (-not $script:AutoWarnAccepted) 'Turning auto on without the box hid the warning'
    Assert-True (-not (Test-AutoWarnPending)) 'The warning repeated in the same session'
    $script:AutoWarnShown = $false
    Assert-True (Test-AutoWarnPending) 'The warning did not return on a later open'
    Assert-True (Apply-AutoWarnChoice 'on' $true) 'Turning auto on with the box was refused'
    Assert-True ($script:AutoWarnAccepted) 'The warning was not remembered'
    Assert-True (-not (Test-AutoWarnPending)) 'A remembered warning was still due'
    $script:AutoWarnAccepted = $keptWarn
    $script:AutoWarnShown = $keptShown
    $keptDeleteConfirm = [string]$script:DeleteConfirmVersion
    $script:DeleteConfirmVersion = ''
    Assert-True (-not (Test-DeleteConfirmHidden)) 'An empty delete confirmation was hidden'
    Assert-True (-not (Complete-DeleteConfirm $false $true)) 'Cancel hid the delete question'
    Assert-True ([string]$script:DeleteConfirmVersion -eq '') 'Cancel stored a version'
    Assert-True (Complete-DeleteConfirm $true $false) 'Delete was refused'
    Assert-True ([string]$script:DeleteConfirmVersion -eq '') 'Delete without the box stored a version'
    Assert-True (Complete-DeleteConfirm $true $true) 'Delete with the box was refused'
    Assert-True ((Compare-AppVersion $script:DeleteConfirmVersion (Get-AppVersion)) -eq 0) 'The delete question was not tied to this version'
    Assert-True (Test-DeleteConfirmHidden) 'The delete question stayed after it was hidden'
    Assert-True (Show-DeleteConfirm 2) 'A remembered delete question was shown'
    $script:DeleteConfirmVersion = '1.0.0'
    Assert-True (-not (Test-DeleteConfirmHidden)) 'An older version kept the delete question hidden'
    $script:DeleteConfirmVersion = 'not-a-version'
    Assert-True (-not (Test-DeleteConfirmHidden)) 'A bad delete confirmation version was hidden'
    $script:DeleteConfirmVersion = $keptDeleteConfirm
    $deleteForm = New-DeleteConfirmForm 2
    try {
        $deleteForm.StartPosition = 'Manual'
        $deleteForm.Location = New-Object Drawing.Point(-32000, -32000)
        $deleteForm.Show()
        $hideBox = @($deleteForm.Controls) | Where-Object { $_ -is [Windows.Forms.CheckBox] } | Select-Object -First 1
        Assert-True ($null -ne $hideBox -and $hideBox.Text -eq "Don't show this in the future") 'The delete window has no hide box'
        Assert-True ($hideBox.Bottom -lt (@($deleteForm.Controls) | Where-Object { $_.Text -eq 'Delete' } | Select-Object -First 1).Top) 'The hide box overlaps Delete'
        Assert-True (-not $deleteForm.Tag.Delete) 'The delete window started confirmed'
        $hideBox.Checked = $true
        $deleteBtn = @($deleteForm.Controls) | Where-Object { $_.Text -eq 'Delete' } | Select-Object -First 1
        $deleteBtn.PerformClick()
        Assert-True ($deleteForm.Tag.Delete -and $deleteForm.Tag.Hide) 'Delete did not remember the box'
        if (-not $deleteForm.IsDisposed) { $deleteForm.Close() }
    }
    finally { if (-not $deleteForm.IsDisposed) { $deleteForm.Dispose() } }
    $cancelForm = New-DeleteConfirmForm 1
    try {
        $cancelForm.StartPosition = 'Manual'
        $cancelForm.Location = New-Object Drawing.Point(-32000, -32000)
        $cancelForm.Show()
        $cancelBox = @($cancelForm.Controls) | Where-Object { $_ -is [Windows.Forms.CheckBox] } | Select-Object -First 1
        $cancelBox.Checked = $true
        $cancelBtn = @($cancelForm.Controls) | Where-Object { $_.Text -eq 'Cancel' } | Select-Object -First 1
        $cancelBtn.PerformClick()
        Assert-True (-not $cancelForm.Tag.Delete -and -not $cancelForm.Tag.Hide) 'Cancel remembered the delete warning'
        if (-not $cancelForm.IsDisposed) { $cancelForm.Close() }
    }
    finally { if (-not $cancelForm.IsDisposed) { $cancelForm.Dispose() } }
    $keptAutoAsk = [bool]$script:AutoAsk
    $script:AutoAsk = $true
    Assert-True (-not (Test-AutoAskHidden)) 'The convert warning started hidden'
    Assert-True (-not (Complete-AutoAsk $false $true)) 'Cancel hid the convert warning'
    Assert-True ($script:AutoAsk) 'Cancel stored Stop asking'
    Assert-True (Complete-AutoAsk $true $false) 'Convert was refused'
    Assert-True ($script:AutoAsk) 'Convert without Stop asking hid the warning'
    Assert-True (Complete-AutoAsk $true $true) 'Convert with Stop asking was refused'
    Assert-True (-not $script:AutoAsk) 'Stop asking was not remembered'
    Assert-True (Test-AutoAskHidden) 'The convert warning stayed after Stop asking'
    Assert-True (Show-AutoAsk) 'A hidden convert warning was shown'
    $script:AutoAsk = $keptAutoAsk
    $askForm = New-AutoAskForm
    try {
        $askForm.StartPosition = 'Manual'
        $askForm.Location = New-Object Drawing.Point(-32000, -32000)
        $askForm.Show()
        $askLabel = @($askForm.Controls) | Where-Object { $_ -is [Windows.Forms.Label] } | Select-Object -First 1
        $askNeed = $askLabel.GetPreferredSize((New-Object Drawing.Size($askLabel.Width, 0))).Height
        Assert-True ($askNeed -le $askLabel.Height) ("The convert warning is clipped (" + $askNeed + " in " + $askLabel.Height + ")")
        $askBox = @($askForm.Controls) | Where-Object { $_ -is [Windows.Forms.CheckBox] } | Select-Object -First 1
        Assert-True ($null -ne $askBox -and $askBox.Text -eq 'Stop asking') 'The convert warning has no Stop asking box'
        $askConvert = @($askForm.Controls) | Where-Object { $_.Text -eq 'Convert' } | Select-Object -First 1
        Assert-True ($null -ne $askConvert) 'The convert warning has no Convert button'
        Assert-True ($askBox.Bottom -lt $askConvert.Top) 'Stop asking overlaps Convert'
        Assert-True ($askConvert.Bottom -le $askForm.ClientSize.Height) 'Convert sits outside the warning'
        Assert-True (-not $askForm.Tag.Convert) 'The convert warning started confirmed'
        $askBox.Checked = $true
        $askConvert.PerformClick()
        Assert-True ($askForm.Tag.Convert -and $askForm.Tag.Hide) 'Convert did not remember Stop asking'
        if (-not $askForm.IsDisposed) { $askForm.Close() }
    }
    finally { if (-not $askForm.IsDisposed) { $askForm.Dispose() } }
    $askCancel = New-AutoAskForm
    try {
        $askCancel.StartPosition = 'Manual'
        $askCancel.Location = New-Object Drawing.Point(-32000, -32000)
        $askCancel.Show()
        $askCancelBox = @($askCancel.Controls) | Where-Object { $_ -is [Windows.Forms.CheckBox] } | Select-Object -First 1
        $askCancelBox.Checked = $true
        $askCancelBtn = @($askCancel.Controls) | Where-Object { $_.Text -eq 'Cancel' } | Select-Object -First 1
        $askCancelBtn.PerformClick()
        Assert-True (-not $askCancel.Tag.Convert -and -not $askCancel.Tag.Hide) 'Cancel remembered Stop asking'
        if (-not $askCancel.IsDisposed) { $askCancel.Close() }
    }
    finally { if (-not $askCancel.IsDisposed) { $askCancel.Dispose() } }
    Assert-True (-not $script:AutoCheck.AutoCheck) 'Auto would turn itself off after the warning'
    $warnForm = New-AutoWarnForm
    try {
        $warnForm.StartPosition = 'Manual'
        $warnForm.Location = New-Object Drawing.Point(-32000, -32000)
        $warnForm.Show()
        $turnOn = @($warnForm.Controls) | Where-Object { $_.Text -eq 'Turn auto on' } | Select-Object -First 1
        $turnOn.PerformClick()
        Assert-True ($warnForm.Tag.Choice -eq 'on') 'Turn auto on was recorded as off'
        if (-not $warnForm.IsDisposed) { $warnForm.Close() }
    }
    finally { if (-not $warnForm.IsDisposed) { $warnForm.Dispose() } }
    Assert-True ($script:ReencodeCheck.Text -eq 'Re-encode audio that cannot be copied') 'Re-encode label'
    Assert-True ($script:Tips.GetToolTip($script:ReencodeCheck) -match 'Windows Media Audio') 'Re-encode tooltip'
    Assert-True ($script:ReencodeCheck.Bottom -le $script:OptionsCard.ClientSize.Height) 'Re-encode sits outside the options card'
    Assert-True ($script:ReencodeCheck.Right -lt $script:BudgetTitle.Left) 'Re-encode overlaps the budgets'
    Assert-True ($script:FindBox.Items.Count -eq 6) 'Find is missing a choice'
    Assert-True ([string]$script:FindBox.Items[0] -eq 'All') 'Find does not start with All'
    Assert-True ([string]$script:FindBox.Items[3] -eq '25') 'Find is missing 25'
    Assert-True (@(0, 5, 10, 25, 50, 100) -contains (Get-FindLimit)) 'Find was not one of the listed limits'
    Assert-True ($script:LogButton.Text -eq 'Log') 'Log label'
    Assert-True ($script:LogButton.Parent -eq $script:ActionPanel) 'Log is outside the action row'
    Assert-True ($script:Tips.GetToolTip($script:LogButton) -match 'Markdown file') 'Log tooltip'
    $sample = Format-ConversionLogMarkdown @([pscustomobject]@{
        Timestamp = '2026-10-22T14:15:03'; Status = 'REPLACED'; Reason = 'ok'; Source = 'Show\Episode.mkv'
        OldGiB = '1.240'; NewGiB = '0.420'; Width = '1920'; Height = '1080'; Kbps = '2250'
    }, [pscustomobject]@{
        Timestamp = '2026-10-22T16:02:11'; Status = 'KEPT'; Reason = 'ok'; Source = 'Movie.mkv'
        OldGiB = '8.100'; NewGiB = '2.010'; Width = '3840'; Height = '2160'; Kbps = '8000'
    })
    Assert-True ($sample -match '# Video Dehydrator conversions') 'The log title was missing'
    Assert-True ($sample -match '## October 22, 2026') 'The log day heading was missing'
    Assert-True ($sample -match '### 2:15 PM') 'The log time heading was missing'
    Assert-True ($sample -match '### 4:02 PM') 'A later conversion was not grouped on its own time'
    Assert-True ($sample -match 'Episode.mkv') 'The log left out the file name'
    Assert-True ((Format-ConversionLogMarkdown @()) -match 'No conversions are recorded yet') 'An empty log had no empty state'
    $listed = New-Object System.Collections.Generic.List[object]
    $listed.Add([pscustomobject]@{ Timestamp = '2026-10-22T14:15:03'; Status = 'KEPT'; Reason = 'ok'; Source = 'Listed.mkv'; OldGiB = '1'; NewGiB = '1'; Width = '1'; Height = '1'; Kbps = '1' })
    Assert-True ((Format-ConversionLogMarkdown $listed) -match 'Listed.mkv') 'A stored list of conversions could not be formatted'
    Assert-True (Test-PassTwoDidNotStart @('encoded 0 frames', 'Encoding: task 2 of 2, 0.00 %')) 'A second pass that never started was missed'
    Assert-True (-not (Test-PassTwoDidNotStart @('encoded 300 frames', 'work result = 0'))) 'A finished encode looked like a failed second pass'
    $missingOutput = @(
        'ERROR: avio_open2 failed, errno -2: Could not write to indicated output file. Please check destination path and file permissions',
        '[05:45:34] aac-decoder done: 0 frames, 0 decoder errors',
        '[05:45:34] h264-decoder done: 0 frames, 0 decoder errors',
        '[05:45:34] libhb: work result = 3',
        'Encode failed (error 3).',
        'encoded 0 frames',
        'Encoding: task 2 of 2, 0.00 %'
    )
    Assert-True (Test-OutputPathMissing $missingOutput) 'A missing output folder was not recognized'
    Assert-True (-not (Test-OutputPathMissing @('encoded 0 frames', 'Encoding: task 2 of 2, 0.00 %'))) 'A second pass that never started looked like a missing folder'
    $missingText = Get-EncodeFailureText $missingOutput
    Assert-True ($missingText -match 'avio_open2 failed, errno -2') 'The convert log dropped the missing output folder'
    Assert-True ($missingText -match 'work result = 3') 'The convert log dropped the HandBrake result'
    Assert-True ($script:ClearSkipsButton.Text -eq 'Clear skips') 'Clear skips label'
    Assert-True ($script:Tips.GetToolTip($script:ClearSkipsButton) -match 'new copy was larger') 'Clear skips tooltip'
    Assert-True ($script:ClearSkipsButton.Bottom -le $script:OptionsCard.ClientSize.Height) 'Clear skips sits outside the options card'
    Assert-True ($script:ClearSkipsButton.Right -lt $script:BudgetTitle.Left) 'Clear skips overlaps the budgets'
    Assert-True (-not $script:ShutdownCheck.Checked) 'Shutdown started checked'
    Assert-True ($script:ShutdownCheck.Text -eq 'Shutdown computer upon completion') 'Shutdown label'
    Assert-True ($script:RecycleCheck.Text -eq 'Clear the drive recycle copy') 'Recycle checkbox label'
    Assert-True ($script:Tips.GetToolTip($script:RecycleCheck) -match '#recycle') 'Recycle checkbox tooltip'
    Assert-True ($script:Tips.GetToolTip($script:RecycleCheck) -match 'Mute') 'Recycle checkbox tooltip skipped Mute'
    Assert-True ($script:RecycleCheck.Bottom -le $script:OptionsCard.ClientSize.Height) 'Recycle checkbox sits outside the options card'
    Assert-True ($script:RecycleCheck.Right -lt $script:BudgetTitle.Left) 'Recycle checkbox overlaps the budgets'
    Assert-True ($script:ClearSkipsButton.Top -gt $script:RecycleCheck.Bottom) 'Clear skips covers the recycle checkbox'
    $keptRecycle = [bool]$script:RecycleCheck.Checked
    $script:RecycleCheck.Checked = $false
    Sync-RecyclePurge
    Assert-True (-not (Test-RecyclePurgeEnabled)) 'An unchecked recycle box still purged'
    $script:RecycleCheck.Checked = $true
    Sync-RecyclePurge
    Assert-True (Test-RecyclePurgeEnabled) 'A checked recycle box did not purge'
    $script:RecycleCheck.Checked = $keptRecycle
    Sync-RecyclePurge
    $script:ShutdownRequested = $false
    $script:ShutdownCheck.Checked = $true
    Offer-Shutdown
    Assert-True (-not $script:ShutdownRequested) 'Smoke test scheduled a shutdown'
    $script:ShutdownCheck.Checked = $false
    $recycleProblem = New-RecycleResult 'missing' 'Z:\TV\Show\.vd-originals\Episode.avi' '\\nas\share\#recycle\TV\Show\.vd-originals\Episode.avi' 'The drive recycle bin has no copy of Episode.avi at \\nas\share\#recycle\TV\Show\.vd-originals\Episode.avi.' 'Episode.avi'
    $recycleForm = New-RecycleProblemForm @($recycleProblem)
    try {
        $recycleForm.StartPosition = 'Manual'
        $recycleForm.Location = New-Object Drawing.Point(-32000, -32000)
        $recycleForm.Show()
        $recycleLink = @($recycleForm.Controls) | Where-Object { $_ -is [Windows.Forms.LinkLabel] } | Select-Object -First 1
        Assert-True ($null -ne $recycleLink) 'The recycle window has no link'
        Assert-True ($recycleLink.Text -eq 'Show the manual deletion steps') 'The recycle link text was wrong'
        Assert-True ($recycleForm.Tag.OpenHelp -eq $false) 'The recycle link started open'
        $recycleDetail = @($recycleForm.Controls) | Where-Object { $_ -is [Windows.Forms.TextBox] } | Select-Object -First 1
        Assert-True ($null -ne $recycleDetail -and $recycleDetail.Text -match 'Episode\.avi') 'The recycle window hid the file'
        $recycleIntro = @($recycleForm.Controls) | Where-Object { $_ -is [Windows.Forms.Label] } | Select-Object -First 1
        $introNeed = $recycleIntro.GetPreferredSize((New-Object Drawing.Size($recycleIntro.Width, 0))).Height
        Assert-True ($introNeed -le $recycleIntro.Height) ("The recycle intro is clipped (" + $introNeed + " in " + $recycleIntro.Height + ", width " + $recycleIntro.Width + ")")
        Assert-True ($recycleDetail.Top -ge $recycleIntro.Bottom) 'The recycle list covers the intro'
        $muteBtn = @($recycleForm.Controls) | Where-Object { $_.Text -eq 'Mute' } | Select-Object -First 1
        Assert-True ($null -ne $muteBtn) 'The recycle window has no Mute button'
        Assert-True ($muteBtn.Bottom -le $recycleForm.ClientSize.Height) 'Mute sits outside the recycle window'
        Assert-True ($muteBtn.Top -gt $recycleLink.Bottom) 'Mute covers the manual-steps link'
        Assert-True ($script:Tips.GetToolTip($muteBtn) -match 'one time') 'Mute tooltip'
        Assert-True (-not $recycleForm.Tag.Mute) 'Mute started on'
        $clicked = New-Object Windows.Forms.LinkLabelLinkClickedEventArgs($recycleLink.Links[0])
        $clicked = $clicked.psobject.BaseObject
        $flags = [Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic
        [void]$recycleLink.GetType().GetMethod('OnLinkClicked', $flags).Invoke($recycleLink, @($clicked))
        Assert-True ($recycleForm.Tag.OpenHelp) 'The recycle link did not open the steps'
    }
    finally { if (-not $recycleForm.IsDisposed) { $recycleForm.Dispose() } }
    $muteForm = New-RecycleProblemForm @($recycleProblem)
    try {
        $muteForm.StartPosition = 'Manual'
        $muteForm.Location = New-Object Drawing.Point(-32000, -32000)
        $muteForm.Show()
        $muteClick = @($muteForm.Controls) | Where-Object { $_.Text -eq 'Mute' } | Select-Object -First 1
        $muteClick.PerformClick()
        Assert-True ($muteForm.Tag.Mute) 'Mute did not remember the click'
        Assert-True (-not $muteForm.Tag.OpenHelp) 'Mute opened the manual steps'
    }
    finally { if (-not $muteForm.IsDisposed) { $muteForm.Dispose() } }
    $keptMuted = [bool]$script:RecycleAlertMuted
    Complete-RecycleMute $true
    Assert-True ($script:RecycleAlertMuted) 'Mute was not remembered'
    $script:RecycleAlertMuted = $false
    Assert-True (-not $script:RecycleAlertMuted) 'Mute could not be cleared in the test'
    $script:RecycleAlertMuted = $keptMuted
    Clear-RecycleResults
    $script:RecycleResults.Add($recycleProblem)
    Show-PendingRecycleProblems
    Assert-True (-not $recycleProblem.Shown) 'Smoke test opened the recycle window'
    Clear-RecycleResults
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
