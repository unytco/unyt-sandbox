<#
.SYNOPSIS
  What Windows will tell us about one process's windows, and a photograph of the
  largest of them.

.DESCRIPTION
  window-capture.ps1 [-TargetPid <int>] [-PrintTo <path>] [-CopyTo <path>]
                     [-DesktopTo <path>] [-RectTo <path>] [-RectW n] [-RectH n]

  prove.py's eyes on Windows, and the only part of that lane still in
  PowerShell: no cmdlet does window-scoped capture, and System.Drawing belongs
  to the .NET Framework, so this runs under powershell.exe (5.1) and must not
  use PowerShell 7 syntax. Everything it is asked for happens in ONE invocation,
  because the C# below is compiled on every start.

  On stdout, one line each, in this order:
    STATION <name>            the window station this process runs on
    WINDOW <hwnd> <x> <y> <w> <h> <title>    per visible window of -TargetPid
    LARGEST <hwnd>            which of them was photographed
    WROTE <what> <path>       print | copy | desktop | rect
    FAILED <what> <why>
#>
param(
  [int]$TargetPid = 0,
  [string]$PrintTo = '',
  [string]$CopyTo = '',
  [string]$DesktopTo = '',
  [string]$RectTo = '',
  [int]$RectW = 800,
  [int]$RectH = 800
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

trap {
  [Console]::Error.WriteLine("::error::window-capture: $($_.Exception.Message)")
  [Console]::Error.WriteLine($_.ScriptStackTrace)
  exit 1
}

# Referenced by its actual location: a partial assembly name is resolved out of
# the GAC, which is one more thing that can be missing on a runner.
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies ([System.Drawing.Bitmap].Assembly.Location) -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

public static class UnytShot {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

  [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] private static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr h, StringBuilder s, int max);
  [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] private static extern IntPtr GetProcessWindowStation();
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool GetUserObjectInformationW(IntPtr h, int index, StringBuilder info, int len, out int needed);
  [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);

  private delegate bool EnumProc(IntPtr h, IntPtr p);

  // Which window station this process runs on. "WinSta0" is the interactive one;
  // anything else has no visible desktop, so a GUI app can put nothing on screen.
  public static string WindowStation() {
    StringBuilder sb = new StringBuilder(256);
    int needed;
    if (!GetUserObjectInformationW(GetProcessWindowStation(), 2 /* UOI_NAME */, sb, sb.Capacity * 2, out needed)) {
      return "<unavailable>";
    }
    return sb.ToString();
  }

  // "<hwnd> <x> <y> <w> <h> <title>" per visible top-level window of one process.
  // The delegate is held in a local for the duration of the call: handed to
  // EnumWindows as a temporary, nothing roots it and a collection mid-enumeration
  // would take the callback with it.
  public static string[] Windows(int pid) {
    List<string> found = new List<string>();
    EnumProc callback = delegate(IntPtr h, IntPtr p) {
      uint owner;
      GetWindowThreadProcessId(h, out owner);
      if (owner != (uint)pid) return true;
      if (!IsWindowVisible(h)) return true;
      RECT r;
      if (!GetWindowRect(h, out r)) return true;
      StringBuilder sb = new StringBuilder(512);
      GetWindowTextW(h, sb, sb.Capacity);
      found.Add(string.Format("{0} {1} {2} {3} {4} {5}",
        h.ToInt64(), r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top, sb.ToString()));
      return true;
    };
    EnumWindows(callback, IntPtr.Zero);
    GC.KeepAlive(callback);
    return found.ToArray();
  }

  // PW_RENDERFULLCONTENT (0x2): added for DirectComposition-rendered windows,
  // which is what a WebView2 surface is. Without it the webview area comes back
  // empty even when the app is painting perfectly.
  public static bool CapturePrintWindow(long hwnd, string path) {
    IntPtr h = new IntPtr(hwnd);
    RECT r;
    if (!GetWindowRect(h, out r)) return false;
    int w = r.Right - r.Left, ht = r.Bottom - r.Top;
    if (w <= 0 || ht <= 0) return false;
    using (Bitmap bmp = new Bitmap(w, ht, PixelFormat.Format32bppArgb)) {
      using (Graphics g = Graphics.FromImage(bmp)) {
        IntPtr hdc = g.GetHdc();
        bool ok = PrintWindow(h, hdc, 2);
        g.ReleaseHdc(hdc);
        if (!ok) return false;
      }
      bmp.Save(path, ImageFormat.Png);
    }
    return true;
  }

  public static bool CaptureWindowFromScreen(long hwnd, string path) {
    IntPtr h = new IntPtr(hwnd);
    RECT r;
    if (!GetWindowRect(h, out r)) return false;
    return CaptureRect(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top, path);
  }

  // SM_XVIRTUALSCREEN / SM_YVIRTUALSCREEN / SM_CXVIRTUALSCREEN / SM_CYVIRTUALSCREEN.
  public static bool CaptureVirtualScreen(string path) {
    return CaptureRect(GetSystemMetrics(76), GetSystemMetrics(77), GetSystemMetrics(78), GetSystemMetrics(79), path);
  }

  // The footprint a centred window of this size would occupy, on the primary
  // screen (SM_CXSCREEN / SM_CYSCREEN). The second negative control: a sub-rect
  // of a desktop can pass thresholds the whole desktop does not.
  public static bool CaptureCentredRect(int w, int h, string path) {
    int sw = GetSystemMetrics(0), sh = GetSystemMetrics(1);
    if (sw <= 0 || sh <= 0) return false;
    return CaptureRect(Math.Max(0, (sw - w) / 2), Math.Max(0, (sh - h) / 2), Math.Min(w, sw), Math.Min(h, sh), path);
  }

  private static bool CaptureRect(int x, int y, int w, int h, string path) {
    if (w <= 0 || h <= 0) return false;
    using (Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb)) {
      using (Graphics g = Graphics.FromImage(bmp)) {
        g.CopyFromScreen(x, y, 0, 0, new Size(w, h), CopyPixelOperation.SourceCopy);
      }
      bmp.Save(path, ImageFormat.Png);
    }
    return true;
  }
}
'@

# Each capture is reported on its own, and a throw is one capture's answer: the
# CopyFromScreen frame is the evidence when PrintWindow gives us nothing, so one
# GDI+ exception must not take the other with it.
function Report {
  param([string]$What, [string]$Path, [scriptblock]$Capture)
  try {
    if (& $Capture) { "WROTE $What $Path" } else { "FAILED $What nothing was written" }
  }
  catch { "FAILED $What $($_.Exception.Message)" }
}

"STATION $([UnytShot]::WindowStation())"

if ($DesktopTo) { Report 'desktop' $DesktopTo { [UnytShot]::CaptureVirtualScreen($DesktopTo) } }
if ($RectTo) { Report 'rect' $RectTo { [UnytShot]::CaptureCentredRect($RectW, $RectH, $RectTo) } }

if ($TargetPid -gt 0) {
  # The largest, because a tooltip is also a window and a frame of one would be
  # a true picture of the wrong thing.
  $best = $null
  $bestArea = 0
  foreach ($line in [UnytShot]::Windows($TargetPid)) {
    "WINDOW $line"
    $fields = $line.Split(' ')
    if ($fields.Count -lt 5) { continue }
    $area = [int]$fields[3] * [int]$fields[4]
    if ($area -gt $bestArea) { $bestArea = $area; $best = [int64]$fields[0] }
  }
  if ($null -ne $best) {
    "LARGEST $best"
    if ($PrintTo) { Report 'print' $PrintTo { [UnytShot]::CapturePrintWindow($best, $PrintTo) } }
    if ($CopyTo) { Report 'copy' $CopyTo { [UnytShot]::CaptureWindowFromScreen($best, $CopyTo) } }
  }
}
