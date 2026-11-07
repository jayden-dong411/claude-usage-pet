// Which app is in front, so the pet can show only over Claude.
// Windows: a resident PowerShell loop prints "<process name>|<fullscreen 0/1>" whenever it changes.
// macOS (development only): polls System Events.
const { spawn, execFile } = require('child_process');
const { isWin, isMac } = require('./paths');

const PS = `
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System; using System.Runtime.InteropServices;
public class FG {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Rt, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
}
"@
$last = ""
while ($true) {
  $h = [FG]::GetForegroundWindow(); $p = 0; [void][FG]::GetWindowThreadProcessId($h, [ref]$p)
  $n = ""; try { $n = (Get-Process -Id $p -ErrorAction Stop).ProcessName } catch {}
  $fs = 0; $r = New-Object FG+R
  if ([FG]::GetWindowRect($h, [ref]$r)) {
    $b = [System.Windows.Forms.Screen]::FromHandle($h).Bounds
    if (($r.Rt - $r.L) -ge $b.Width -and ($r.B - $r.T) -ge $b.Height) { $fs = 1 }
  }
  $line = "$n|$fs"
  if ($line -ne $last) { [Console]::Out.WriteLine($line); [Console]::Out.Flush(); $last = $line }
  Start-Sleep -Milliseconds 600
}`;

class Foreground {
  /** onChange({ name, fullscreen }) */
  constructor(onChange) {
    this.onChange = onChange;
    this.current = { name: '', fullscreen: false, known: false };
    this.proc = null;
    this.timer = null;
  }

  start() {
    if (isWin) this.startWindows();
    else if (isMac) this.startMac();
  }

  set(name, fullscreen) {
    const next = { name: (name || '').toLowerCase(), fullscreen: !!fullscreen, known: true };
    if (next.name === this.current.name && next.fullscreen === this.current.fullscreen && this.current.known) return;
    this.current = next;
    this.onChange(next);
  }

  startWindows() {
    const run = () => {
      this.proc = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', '-'],
        { windowsHide: true, stdio: ['pipe', 'pipe', 'ignore'] });
      let buf = '';
      this.proc.stdout.on('data', (d) => {
        buf += d.toString();
        let i;
        while ((i = buf.indexOf('\n')) >= 0) {
          const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
          const [n, fs] = line.split('|');
          this.set(n, fs === '1');
        }
      });
      this.proc.on('exit', () => { this.proc = null; if (!this.stopped) setTimeout(run, 3000); });
      this.proc.stdin.end(PS);
    };
    run();
  }

  startMac() {
    const poll = () => execFile('osascript', ['-e', 'tell application "System Events" to get name of first process whose frontmost is true'],
      { timeout: 4000 }, (err, out) => { if (!err) this.set(String(out).trim(), false); });
    poll();
    this.timer = setInterval(poll, 1500);
  }

  stop() {
    this.stopped = true;
    if (this.proc) this.proc.kill();
    if (this.timer) clearInterval(this.timer);
  }
}

module.exports = { Foreground };
