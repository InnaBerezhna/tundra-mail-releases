# install-windows.ps1 -- one-line Tundra Mail beta installer for Windows.
#
#   irm https://raw.githubusercontent.com/InnaBerezhna/tundra-mail-releases/main/install.ps1 | iex
#
# Downloads the latest setup.exe, checks its SHA-256 against the release
# sidecar, installs silently, launches, and explains any blocker it finds.
# A PowerShell download carries no Mark-of-the-Web, so SmartScreen does not
# prompt. It deliberately does NOT touch Smart App Control or Defender
# (no exclusions, no policy edits): it detects them and tells the user.
# Windows PowerShell 5.1 compatible (no ??, no ternary).
#
# Runs in a child scope (& { }) so nothing leaks into the user's session, and
# never calls `exit`: under `irm | iex` that would close the user's window.
# Fail() throws a marker that the outer catch swallows.

& {
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # 5.1's progress bar makes IWR ~10x slower
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$base  = 'https://github.com/InnaBerezhna/tundra-mail-releases/releases/latest/download'
$name  = 'TundraMail-windows-amd64-setup.exe'
$work  = Join-Path $env:TEMP ('tundra-install-' + [guid]::NewGuid())
$setup = Join-Path $work $name
$stop  = 'tundra-install-stop'

function Say($msg, $color = 'Gray') { Write-Host $msg -ForegroundColor $color }
function Fail($msg) { Say "`n$msg`n" 'Red'; throw $stop }

try {
    Say "`nTundra Mail installer`n" 'Cyan'

    # 1. Smart App Control (Windows 11). 1 = On: blocks every unsigned app; no script can fix that.
    $sac = $null
    try { $sac = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction Stop).VerifiedAndReputablePolicyState } catch {}
    if ($sac -eq 1) {
        Fail ("Smart App Control is ON, and it blocks Tundra's beta build (not yet code-signed).`n" +
              "Options: test inside Windows Sandbox, or turn it off in`n" +
              "Windows Security > App & browser control > Smart App Control (on some builds this cannot be turned back on).")
    }

    # A running copy (close-to-tray keeps it alive) locks the exe the installer must replace.
    if (Get-Process -Name 'tundra-mail' -ErrorAction SilentlyContinue) {
        Fail "Tundra Mail is running. Quit it first (tray icon by the clock > Quit), then run this again."
    }

    # 2. Download + verify.
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    Say "Downloading $name ..."
    try {
        Invoke-WebRequest "$base/$name" -OutFile $setup -UseBasicParsing
        # To a file, not .Content: GitHub serves .sha256 as octet-stream, and .Content is then byte[].
        Invoke-WebRequest "$base/$name.sha256" -OutFile "$setup.sha256" -UseBasicParsing
        $expected = ((Get-Content "$setup.sha256" -Raw).Trim() -split '\s+')[0].ToLower()
    } catch { Fail "Download failed: $($_.Exception.Message)`nCheck your internet connection and try again." }
    $actual = (Get-FileHash $setup -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected) { Fail "Checksum mismatch -- the download is corrupt or was altered. Nothing was installed." }
    Say "Checksum OK." 'Green'

    # 3. Silent install. Admin accounts get one UAC prompt ("Unknown publisher" until signing lands).
    Say "Installing (click Yes if Windows asks for permission) ..."
    $p = $null
    try { $p = Start-Process $setup -ArgumentList '/S' -Wait -PassThru } catch { Fail "The installer did not start (permission declined?): $($_.Exception.Message)" }
    if ($p.ExitCode -ne 0) { Fail "The installer stopped with code $($p.ExitCode). Run this again and click Yes on the permission prompt." }

    # 4. Find the exe via the uninstall key (machine or per-user scope).
    $dir = $null
    foreach ($hive in 'HKLM:', 'HKCU:') {
        try { $dir = (Get-ItemProperty "$hive\Software\Microsoft\Windows\CurrentVersion\Uninstall\TundraMail" -ErrorAction Stop).InstallLocation; break } catch {}
    }
    if (-not $dir) { Fail "Install finished but Tundra's install location is missing from the registry." }
    $exe = Join-Path $dir 'tundra-mail.exe'
    Start-Sleep -Seconds 2
    if (-not (Test-Path $exe)) {
        Fail ("Tundra was installed but tundra-mail.exe is gone -- Microsoft Defender most likely quarantined it (false positive).`n" +
              "Fix: Windows Security > Virus & threat protection > Protection history > the Tundra item > Actions > Allow on device.`n" +
              "Then start Tundra Mail from the Start menu.")
    }

    # 5. Launch and confirm it stays up.
    Say "Starting Tundra Mail ..."
    Start-Process $exe
    Start-Sleep -Seconds 8
    if (Get-Process -Name 'tundra-mail' -ErrorAction SilentlyContinue) {
        Say "`nTundra Mail is running. Next time, open it from the Start menu.`n" 'Green'
        return
    }

    # 6. It quit: show the log so the tester can send it.
    $log = $null
    foreach ($d in (Join-Path $env:LOCALAPPDATA 'Tundra Mail\logs'), (Join-Path $env:USERPROFILE '.tundra-mail\logs')) {
        $f = Join-Path $d 'tundra.log'
        if (Test-Path $f) { $log = $f; break }
    }
    if ($log) {
        Say "`nTundra Mail started but closed. Last log lines:`n" 'Yellow'
        Get-Content $log -Tail 30
        Fail "Please send this file to the Tundra team: $log"
    }
    Fail ("Tundra Mail did not start and wrote no log -- Windows likely blocked it before launch.`n" +
          "Check Windows Security > Protection history, then send a screenshot to the Tundra team.")
} catch {
    if ("$($_.Exception.Message)" -ne $stop) { Say "`nUnexpected error: $($_.Exception.Message)`n" 'Red' }
} finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
}
