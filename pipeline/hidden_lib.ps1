Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices; using System.Collections.Generic;
public class HD {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct SI { public int cb; public string r; public string desk; public string title; public int x,y,w,h,xc,yc,fill,flags; public short show, r2; public IntPtr r3, i, o, e; }
  [StructLayout(LayoutKind.Sequential)] public struct PI { public IntPtr hp, ht; public int pid, tid; }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr CreateDesktop(string n, IntPtr d, IntPtr dm, int f, uint acc, IntPtr sa);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] public static extern bool CreateProcess(string app, string cmd, IntPtr pa, IntPtr ta, bool inh, uint fl, IntPtr env, string dir, ref SI si, out PI pi);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumDesktopWindows(IntPtr d, EnumProc f, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc f, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out int pid);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, string l);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr d);
  public struct RECT { public int L, T, R, B; }
  public static IntPtr Desk;
  public static PI Start(string desk, string exe, string args) {
    if (Desk == IntPtr.Zero) Desk = CreateDesktop(desk, IntPtr.Zero, IntPtr.Zero, 0, 0x10000000, IntPtr.Zero);
    SI si = new SI(); si.cb = Marshal.SizeOf(si); si.desk = desk; PI pi;
    if (!CreateProcess(exe, "\"" + exe + "\" " + args, IntPtr.Zero, IntPtr.Zero, false, 0, IntPtr.Zero, null, ref si, out pi)) throw new Exception("CreateProcess failed " + Marshal.GetLastWin32Error());
    return pi;
  }
  static string Desc(IntPtr h) { var t = new StringBuilder(512); var c = new StringBuilder(256); GetWindowText(h, t, 512); GetClassName(h, c, 256); return h + " | " + c + " | " + t + " | id=" + GetDlgCtrlID(h) + " | vis=" + IsWindowVisible(h); }
  public static List<string> List(int pid) {
    var l = new List<string>();
    EnumDesktopWindows(Desk, (h, x) => { int p; GetWindowThreadProcessId(h, out p); if (p == pid) l.Add(Desc(h)); return true; }, IntPtr.Zero);
    return l;
  }
  public static List<string> Children(IntPtr parent) {
    var l = new List<string>(); EnumChildWindows(parent, (h, x) => { l.Add(Desc(h)); return true; }, IntPtr.Zero); return l;
  }
  public static IntPtr FindTop(int pid, string pattern) {
    IntPtr found = IntPtr.Zero;
    EnumDesktopWindows(Desk, (h, x) => { int p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h)) { var t = new StringBuilder(512); GetWindowText(h, t, 512); if (Like(t.ToString(), pattern)) { found = h; return false; } } return true; }, IntPtr.Zero);
    return found;
  }
  public static IntPtr FindChild(IntPtr parent, string cls, int id) {
    IntPtr found = IntPtr.Zero;
    EnumChildWindows(parent, (h, x) => { var c = new StringBuilder(256); GetClassName(h, c, 256); if (c.ToString() == cls && (id < 0 || GetDlgCtrlID(h) == id)) { found = h; return false; } return true; }, IntPtr.Zero);
    return found;
  }
  static bool Like(string s, string p) { return System.Text.RegularExpressions.Regex.IsMatch(s, "^" + System.Text.RegularExpressions.Regex.Escape(p).Replace("\\*", ".*") + "$"); }
}
"@
