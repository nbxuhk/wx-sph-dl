# Windows helper for wx-sph-dl (ASCII only: PowerShell 5.1 reads .ps1 as ANSI)
# Modes: saveproxy | getproxy | setpac | restoreproxy | dropownpac | portpid | delcert | certinfo | scan
# Exit codes: 0 = ok, 1 = refused/failed (callers MUST treat non-zero as "do not proceed")
param(
  [Parameter(Mandatory=$true)][string]$Mode,
  [string]$State = '',
  [string]$PacUrl = '',
  [string]$Thumb = '',
  [string]$HeadsDir = '',
  [string]$OutFile = '',
  [int]$Shard = 0,
  [int]$Shards = 1,
  [int]$Minutes = 30,
  [int]$MaxHits = 30,
  [int]$Port = 0
)
$ErrorActionPreference = 'Continue'
if ([string]::IsNullOrWhiteSpace($State)) { $State = Join-Path (Split-Path -Parent $PSScriptRoot) 'state' }
$reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
# Records of what THIS tool installed, kept in ONE machine-global directory (never inside
# the state dir) so they survive a wiped state AND a cleanup run from a different --state:
#   <LOCALAPPDATA>\wx-sph-dl\records\pac-endpoints.json lists PAC URLs we wrote.
# Ownership must come from these records, not from a URL shape: http://127.0.0.1:8080/
# proxy.pac may well be the user's own local PAC server. WXSPH_RECORDS overrides the dir.
if ($env:WXSPH_RECORDS) {
  $RecordsDir = $env:WXSPH_RECORDS
} elseif ($env:LOCALAPPDATA) {
  $RecordsDir = Join-Path $env:LOCALAPPDATA 'wx-sph-dl\records'
} else {
  $RecordsDir = Join-Path $env:USERPROFILE '.wx-sph-dl\records'
}
$PacEndpointsFile = Join-Path $RecordsDir 'pac-endpoints.json'

function Write-TextNoBom([string]$Path, [string]$Text) {
  $dir = Split-Path -Parent $Path
  if ($dir -ne '' -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Read-TextNoBom([string]$Path) {
  $enc = New-Object System.Text.UTF8Encoding($false)
  $t = [System.IO.File]::ReadAllText($Path, $enc)
  if ($t.Length -gt 0 -and [int][char]$t[0] -eq 0xFEFF) { $t = $t.Substring(1) }
  return $t
}

function Get-PacKey([string]$Url) {
  return ([string]$Url).Trim().TrimEnd('/').ToLower()
}

function Get-RecordedPacs {
  if (-not (Test-Path $PacEndpointsFile)) { return @() }
  try { return @((Read-TextNoBom $PacEndpointsFile) | ConvertFrom-Json) } catch { return @() }
}

function Add-RecordedPac([string]$Url, [string]$StateDir) {
  $key = Get-PacKey $Url
  $kept = @()
  foreach ($r in (Get-RecordedPacs)) { if ($r -and (Get-PacKey $r.url) -ne $key) { $kept += $r } }
  $kept += [pscustomobject]@{ url = $Url; state = $StateDir; ts = (Get-Date).ToUniversalTime().ToString('o') }
  if ($kept.Count -gt 20) { $kept = $kept[($kept.Count - 20)..($kept.Count - 1)] }
  Write-TextNoBom $PacEndpointsFile (($kept | ConvertTo-Json -Depth 4) -replace "`r?`n", ' ')
}

function Test-RecordedPac([string]$Url) {
  $key = Get-PacKey $Url
  foreach ($r in (Get-RecordedPacs)) { if ($r -and (Get-PacKey $r.url) -eq $key) { return $true } }
  return $false
}

function Notify-Proxy {
  Add-Type -Namespace Win32 -Name NetNotify -MemberDefinition @'
[DllImport("wininet.dll", SetLastError=true)]
public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
'@ -ErrorAction SilentlyContinue
  [Win32.NetNotify]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
  [Win32.NetNotify]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
}

switch ($Mode) {

  'saveproxy' {
    # Must either produce a verifiably good backup, or fail loudly (exit 1).
    # A silently missing/invalid backup would make the caller fall back to DIRECT
    # and bypass the user's real proxy.
    try {
      New-Item -ItemType Directory -Force -Path $State | Out-Null
      $p = Get-ItemProperty $reg -ErrorAction Stop
      # A stale PAC of OUR OWN must never be recorded as "the user's original": after an
      # interrupted run the state can be gone while the PAC is still installed, and
      # capturing it here would make cleanup restore our PAC forever. Ownership comes from
      # our own record file, not from the URL shape.
      $ac = [string]$p.AutoConfigURL
      $normalized = $false
      if (Test-RecordedPac $ac) { $ac = ''; $normalized = $true }
      $o = [ordered]@{
        ProxyEnable   = [int]$p.ProxyEnable
        ProxyServer   = [string]$p.ProxyServer
        ProxyOverride = [string]$p.ProxyOverride
        AutoConfigURL = $ac
      }
      # Write UTF-8 WITHOUT BOM. PowerShell 5.1 "-Encoding UTF8" adds a BOM,
      # which breaks Node's JSON.parse and would silently turn the PAC fallback into DIRECT.
      $json = ($o | ConvertTo-Json)
      $enc = New-Object System.Text.UTF8Encoding($false)
      $f = Join-Path $State 'original-proxy.json'
      [System.IO.File]::WriteAllText($f, $json, $enc)

      # Verify what we just wrote: exists, non-empty, no BOM, schema-valid.
      if (-not (Test-Path $f)) { throw 'backup file missing right after write' }
      $bytes = [System.IO.File]::ReadAllBytes($f)
      if ($bytes.Length -eq 0) { throw 'backup file is empty after write' }
      if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { throw 'backup file has a UTF-8 BOM' }
      $back = [System.IO.File]::ReadAllText($f, $enc) | ConvertFrom-Json
      $names = @($back.PSObject.Properties.Name)
      foreach ($need in @('ProxyEnable', 'ProxyServer', 'ProxyOverride', 'AutoConfigURL')) {
        if ($names -notcontains $need) { throw ('backup missing field: ' + $need) }
      }
      Write-Output ('SAVED ' + ($json -replace "`r?`n", ' '))
      if ($normalized) {
        Write-Output 'WARN normalized: a stale wx-sph-dl PAC was present in AutoConfigURL and was recorded as empty (it is never the user''s original setting)'
      }
    } catch {
      Write-Output ('SAVEPROXY-FAIL ' + $_.Exception.Message)
      exit 1
    }
  }

  'getproxy' {
    # Read-only: report the CURRENT registry proxy settings (no assumptions).
    try {
      $p = Get-ItemProperty $reg -ErrorAction Stop
      $o = [ordered]@{
        ProxyEnable   = [int]$p.ProxyEnable
        ProxyServer   = [string]$p.ProxyServer
        ProxyOverride = [string]$p.ProxyOverride
        AutoConfigURL = [string]$p.AutoConfigURL
      }
      Write-Output ('PROXY ' + (($o | ConvertTo-Json) -replace "`r?`n", ' '))
    } catch {
      Write-Output ('GETPROXY-FAIL ' + $_.Exception.Message)
      exit 1
    }
  }

  'setpac' {
    Set-ItemProperty $reg -Name AutoConfigURL -Value $PacUrl -Type String
    Set-ItemProperty $reg -Name ProxyEnable -Value 0 -Type DWord
    Add-RecordedPac $PacUrl $State
    Notify-Proxy
    Write-Output ('pac set recorded=1 url=' + $PacUrl)
  }

  'restoreproxy' {
    # Refuse to touch the registry unless the backup is readable AND schema-valid.
    $f = Join-Path $State 'original-proxy.json'
    if (-not (Test-Path $f)) { Write-Output 'RESTORE-FAIL no original-proxy.json'; exit 1 }
    try {
      $enc = New-Object System.Text.UTF8Encoding($false)
      $raw = [System.IO.File]::ReadAllText($f, $enc)
      if ($raw.Length -gt 0 -and [int][char]$raw[0] -eq 0xFEFF) { $raw = $raw.Substring(1) }
      $o = $raw | ConvertFrom-Json
      if ($null -eq $o) { throw 'backup is not a JSON object' }
      $names = @($o.PSObject.Properties.Name)
      foreach ($need in @('ProxyEnable', 'ProxyServer')) {
        if ($names -notcontains $need) { throw ('backup missing field: ' + $need) }
      }
      $pe = [int]$o.ProxyEnable
      if ($pe -ne 0 -and $pe -ne 1) { throw ('ProxyEnable out of range: ' + $pe) }
      Set-ItemProperty $reg -Name ProxyEnable -Value $pe -Type DWord
      Set-ItemProperty $reg -Name ProxyServer -Value ([string]$o.ProxyServer) -Type String
      if ($names -contains 'ProxyOverride') {
        Set-ItemProperty $reg -Name ProxyOverride -Value ([string]$o.ProxyOverride) -Type String
      }
      if (($names -notcontains 'AutoConfigURL') -or [string]::IsNullOrEmpty($o.AutoConfigURL)) {
        Remove-ItemProperty $reg -Name AutoConfigURL -ErrorAction SilentlyContinue
      } else {
        Set-ItemProperty $reg -Name AutoConfigURL -Value ([string]$o.AutoConfigURL) -Type String
      }
      Notify-Proxy
      Write-Output 'restored'
    } catch {
      Write-Output ('RESTORE-FAIL ' + $_.Exception.Message)
      exit 1
    }
  }

  'portpid' {
    # Which process owns a listening port? Returns PID + process start time (UTC ms) +
    # command line, so the caller can prove identity AND rule out a recycled PID before
    # killing anything (never kill by process name).
    if ($Port -le 0) { Write-Output 'PORTPID-FAIL -Port required'; exit 1 }
    try {
      $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
      if (-not $conn) { Write-Output 'PORTPID none'; exit 0 }
      $proc = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $conn.OwningProcess) -ErrorAction SilentlyContinue
      $cmd = if ($proc) { [string]$proc.CommandLine } else { '' }
      $started = 0
      if ($proc -and $proc.CreationDate) {
        try {
          $epoch = New-Object System.DateTime(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
          $started = [int64](([datetime]$proc.CreationDate).ToUniversalTime() - $epoch).TotalMilliseconds
        } catch { $started = 0 }
      }
      Write-Output ('PORTPID ' + $conn.OwningProcess + ' ' + $started + ' ' + $cmd)
    } catch {
      Write-Output ('PORTPID-FAIL ' + $_.Exception.Message)
      exit 1
    }
  }

  'dropownpac' {
    # Fallback used by cleanup when original-proxy.json is gone: remove AutoConfigURL
    # ONLY if it is an endpoint THIS tool recorded as installed (exact URL match against
    # records/pac-endpoints.json). A user's own local PAC - even on 127.0.0.1 with the
    # same /proxy.pac path - is left untouched.
    try {
      $p = Get-ItemProperty $reg -ErrorAction Stop
      $ac = [string]$p.AutoConfigURL
      $records = @(Get-RecordedPacs)
      if ($ac -eq '') {
        Write-Output 'KEEP (empty)'
      } elseif (Test-RecordedPac $ac) {
        Remove-ItemProperty $reg -Name AutoConfigURL -ErrorAction SilentlyContinue
        Notify-Proxy
        Write-Output ('DROPPED ' + $ac + ' recorded=1')
      } else {
        Write-Output ('KEEP ' + $ac + ' recorded=' + $records.Count + ' (not an endpoint this tool installed)')
      }
    } catch {
      Write-Output ('DROPOWNPAC-FAIL ' + $_.Exception.Message)
      exit 1
    }
  }

  'certinfo' {
    $ca = Get-ChildItem Cert:\CurrentUser\Root | Where-Object { $_.Subject -like '*DSH Local MITM CA*' }
    if ($ca) { Write-Output ('present ' + $ca.Thumbprint) } else { Write-Output 'absent' }
  }

  'delcert' {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CertDel3 {
  [DllImport("crypt32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr CertOpenStore(int lprov, int enc, IntPtr hprov, uint flags, string para);
  [DllImport("crypt32.dll", SetLastError=true)]
  public static extern IntPtr CertEnumCertificatesInStore(IntPtr h, IntPtr prev);
  [DllImport("crypt32.dll", SetLastError=true)]
  public static extern bool CertDeleteCertificateFromStore(IntPtr ctx);
  [DllImport("crypt32.dll", SetLastError=true)]
  public static extern bool CertCloseStore(IntPtr h, uint flags);
  [DllImport("crypt32.dll", SetLastError=true)]
  public static extern bool CertGetCertificateContextProperty(IntPtr ctx, uint propId, byte[] data, ref int cb);
}
'@ -Language CSharp
    $h = [CertDel3]::CertOpenStore(10, 0, [IntPtr]::Zero, 0x00010000, 'Root')
    if ($h -eq [IntPtr]::Zero) { Write-Output 'open failed'; exit 1 }
    $target = $Thumb.ToUpper()
    $ctx = [IntPtr]::Zero
    $done = $false
    while ($true) {
      $ctx = [CertDel3]::CertEnumCertificatesInStore($h, $ctx)
      if ($ctx -eq [IntPtr]::Zero) { break }
      $cb = 20
      $buf = New-Object byte[] 20
      if ([CertDel3]::CertGetCertificateContextProperty($ctx, 3, $buf, [ref]$cb)) {
        $t = ($buf | ForEach-Object { $_.ToString('x2') }) -join ''
        if ($target -eq '' -or $t.ToUpper() -eq $target) {
          $ok = [CertDel3]::CertDeleteCertificateFromStore($ctx)
          Write-Output ('delete=' + $ok + ' err=' + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
          $done = $true
          break
        }
      }
    }
    [CertDel3]::CertCloseStore($h, 0) | Out-Null
    if (-not $done) { Write-Output 'not found' }
  }

  'scan' {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
public static class SphKeyScan {
  [StructLayout(LayoutKind.Sequential)]
  public struct MEMORY_BASIC_INFORMATION {
    public IntPtr BaseAddress; public IntPtr AllocationBase; public uint AllocationProtect;
    public IntPtr RegionSize; public uint State; public uint Protect; public uint Type;
  }
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint a, bool i, int pid);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr VirtualQueryEx(IntPtr h, IntPtr a, out MEMORY_BASIC_INFORMATION m, IntPtr l);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool ReadProcessMemory(IntPtr h, IntPtr a, byte[] b, IntPtr s, out IntPtr r);

  static bool ReadAt(IntPtr h, long addr, byte[] buf) {
    if (addr < 0x10000) return false;
    IntPtr got;
    return ReadProcessMemory(h, (IntPtr)addr, buf, (IntPtr)buf.Length, out got) && (long)got == buf.Length;
  }

  // cipher: first 128KB of an encrypted video; keystream = ISAAC-64(seed) output, XORed over the first 128KB.
  public static List<string> Scan(int pid, byte[][] ciphers, string[] tags, string outDir, int maxHits) {
    var found = new List<string>();
    IntPtr h = OpenProcess(0x0410, false, pid);
    if (h == IntPtr.Zero) return found;
    int np = ciphers.Length;
    byte[][] pats = new byte[np][];
    for (int k = 0; k < np; k++) {
      pats[k] = new byte[8];
      pats[k][0] = ciphers[k][0]; pats[k][1] = ciphers[k][1]; pats[k][2] = ciphers[k][2];
      pats[k][4] = (byte)(ciphers[k][4] ^ (byte)'f');
      pats[k][5] = (byte)(ciphers[k][5] ^ (byte)'t');
      pats[k][6] = (byte)(ciphers[k][6] ^ (byte)'y');
      pats[k][7] = (byte)(ciphers[k][7] ^ (byte)'p');
    }
    long addr = 0x10000, max = 0x00007FFFFFFFFFFF;
    var mbi = new MEMORY_BASIC_INFORMATION();
    int mbiSize = Marshal.SizeOf(typeof(MEMORY_BASIC_INFORMATION));
    int chunk = 8388608, hits = 0;
    while (addr < max && hits < maxHits) {
      if (VirtualQueryEx(h, (IntPtr)addr, out mbi, (IntPtr)mbiSize) == IntPtr.Zero) break;
      long regionSize = (long)mbi.RegionSize;
      uint p = mbi.Protect;
      bool readable = mbi.State == 0x1000 && (p & 0x100) == 0 && (p & 0x01) == 0 &&
        ((p & 0x02) != 0 || (p & 0x04) != 0 || (p & 0x08) != 0 || (p & 0x20) != 0 || (p & 0x40) != 0 || (p & 0x80) != 0);
      if (readable && regionSize > 4096 && regionSize < 0x40000000) {
        long offset = 0;
        while (offset < regionSize && hits < maxHits) {
          int toRead = (int)Math.Min(chunk, regionSize - offset);
          byte[] buf = new byte[toRead];
          IntPtr got;
          if (ReadProcessMemory(h, (IntPtr)(addr + offset), buf, (IntPtr)toRead, out got) && (long)got > 0) {
            int n = (int)got;
            for (int i = 0; i + 8 <= n; i++) {
              byte b0 = buf[i];
              for (int k = 0; k < np; k++) {
                byte[] pt = pats[k];
                if (b0 != pt[0] || buf[i+1] != pt[1] || buf[i+2] != pt[2]) continue;
                if (buf[i+4] != pt[4] || buf[i+5] != pt[5] || buf[i+6] != pt[6] || buf[i+7] != pt[7]) continue;
                hits++;
                long ksBase = addr + offset + i;
                byte[] ks = new byte[131072];
                if (!ReadAt(h, ksBase, ks)) continue;
                byte[] c = ciphers[k];
                int size = c[3] ^ ks[3];
                if (size < 8 || size > 65536) continue;
                bool moov = false;
                for (int q = 0; q + 4 < 131072; q++) {
                  if ((byte)(c[q] ^ ks[q]) == 'm' && (byte)(c[q+1] ^ ks[q+1]) == 'o' &&
                      (byte)(c[q+2] ^ ks[q+2]) == 'o' && (byte)(c[q+3] ^ ks[q+3]) == 'v') { moov = true; break; }
                }
                if (!moov) continue;
                string file = Path.Combine(outDir, "KEYSTREAM_" + tags[k] + "_" + pid + "_" + ksBase.ToString("X") + ".bin");
                File.WriteAllBytes(file, ks);
                found.Add("FOUND head=" + tags[k] + " pid=" + pid + " ksBase=0x" + ksBase.ToString("X") + " boxSize=" + size + " file=" + file);
                return found;
              }
            }
          }
          offset += Math.Max(toRead - 1024, 1);
        }
      }
      long next = addr + regionSize;
      if (next <= addr) break;
      addr = next;
    }
    CloseHandle(h);
    return found;
  }
}
'@ -Language CSharp

    New-Item -ItemType Directory -Force -Path $OutFile | Out-Null
    $heads = Get-ChildItem $HeadsDir -Filter *.bin -ErrorAction SilentlyContinue | Sort-Object Name
    if (-not $heads) { Write-Output 'no heads'; exit 1 }
    $tags = @(); $list = New-Object 'System.Collections.Generic.List[byte[]]'
    foreach ($f in $heads) {
      $b = [System.IO.File]::ReadAllBytes($f.FullName)
      if ($b.Length -lt 131072) { continue }
      $tags += [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
      $list.Add($b[0..131071])
    }
    $arr = $list.ToArray()
    Write-Output ('heads=' + $tags.Count + ' shard=' + $Shard + '/' + $Shards)

    $deadline = (Get-Date).AddMinutes($Minutes)
    $round = 0
    while ((Get-Date) -lt $deadline) {
      $round++
      $all = Get-Process WeChatAppEx, Weixin -ErrorAction SilentlyContinue
      $pids = @()
      for ($i = 0; $i -lt $all.Count; $i++) { if ($i % $Shards -eq $Shard) { $pids += $all[$i].Id } }
      foreach ($procId in $pids) {
        try {
          $res = [SphKeyScan]::Scan($procId, $arr, $tags, $OutFile, 40)
          foreach ($r in $res) {
            Write-Output ('  ' + $r)
            Set-Content (Join-Path $OutFile 'FOUND.txt') $r -Encoding UTF8
            exit 0
          }
        } catch { }
      }
      Write-Output ('round ' + $round + ' ' + (Get-Date -Format 'HH:mm:ss'))
      Start-Sleep -Seconds 1
    }
    Write-Output 'timeout'
  }

  default { Write-Output ('unknown mode: ' + $Mode); exit 1 }
}
