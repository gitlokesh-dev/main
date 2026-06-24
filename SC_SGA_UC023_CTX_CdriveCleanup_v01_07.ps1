$ErrorActionPreference = "SilentlyContinue"

# ═══════════════════════════════════════════════════════════════
# SCRIPT  : SC_SGA_UC023_CTX_CdriveCleanup
# VERSION : v01_07
# PURPOSE : Citrix Session Host — C Drive Cleanup Automation
# ═══════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────
# CONFIGURATION  (tune here, nowhere else)
# ─────────────────────────────────────────────
$global:ScriptTimeoutSec  = 480   # Hard script ceiling  : 8 minutes
$global:ServiceTimeoutSec = 30    # Stop/Start-Service   : 30 seconds
$global:FileAgeDays       = 7     # Delete files older than N days
$global:ScriptStartTime   = Get-Date
$global:LogFile           = "C:\Windows\Temp\UC023_Cleanup_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# ═══════════════════════════════════════════════════════════════
# SECTION 1 — HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────
# HELPER: Structured log writer
# ─────────────────────────────────────────────
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS')]
        [string]$Level = 'INFO'
    )
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    Write-Output $line
    try {
        $line | Out-File -Append -FilePath $global:LogFile -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # Log file write failure is non-fatal — continue
    }
}

# ─────────────────────────────────────────────
# HELPER: Guard remaining time budget
# ─────────────────────────────────────────────
function Assert-TimeRemaining {
    param([string]$Phase = "")
    $elapsed = (New-TimeSpan -Start $global:ScriptStartTime -End (Get-Date)).TotalSeconds
    if ($elapsed -ge $global:ScriptTimeoutSec) {
        Write-Log "Script time budget exhausted at phase [$Phase] after ${elapsed}s. Exiting cleanly." -Level WARN
        Exit 0
    }
}

# ─────────────────────────────────────────────
# HELPER: C Drive space snapshot
# ─────────────────────────────────────────────
function Get-CDriveSpace {
    try {
        $drive = Get-CimInstance -Class Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        return [Ordered]@{
            TotalGB = [math]::Round($drive.Size      / 1GB, 2)
            FreeGB  = [math]::Round($drive.FreeSpace / 1GB, 2)
            UsedGB  = [math]::Round(($drive.Size - $drive.FreeSpace) / 1GB, 2)
        }
    }
    catch {
        Write-Log "Failed to query C Drive space: $($_.Exception.Message)" -Level WARN
        return [Ordered]@{ TotalGB = 0; FreeGB = 0; UsedGB = 0 }
    }
}

function Write-DriveSpaceReport {
    param([string]$Label, [System.Collections.Specialized.OrderedDictionary]$Space)
    Write-Log "[$Label] Total: $($Space.TotalGB) GB  |  Used: $($Space.UsedGB) GB  |  Free: $($Space.FreeGB) GB" -Level INFO
}

# ─────────────────────────────────────────────
# HELPER: Delete files older than FileAgeDays
#         Skips locked files silently.
#         Checks time budget on every file.
# ─────────────────────────────────────────────
function Remove-OldFiles {
    param(
        [string]$Path,
        [switch]$Recurse
    )

    Assert-TimeRemaining -Phase "Remove-OldFiles:$Path"

    $cutoff = (Get-Date).AddDays(-$global:FileAgeDays)

    # Resolve wildcard base paths (e.g. C:\Users\*\AppData\...)
    try {
        $resolvedPaths = @()
        if ($Path -match '\*') {
            $base    = Split-Path $Path -Parent
            $pattern = Split-Path $Path -Leaf
            $resolvedPaths = Get-ChildItem -Path $base -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName $pattern }
        }
        else {
            $resolvedPaths = @($Path)
        }
    }
    catch {
        Write-Log "Failed to resolve path [$Path]: $($_.Exception.Message)" -Level WARN
        return
    }

    foreach ($rPath in $resolvedPaths) {

        if (!(Test-Path $rPath)) { continue }

        # ── Delete old files ──
        try {
            $getArgs = @{
                Path        = $rPath
                File        = $true
                Force       = $true
                ErrorAction = 'SilentlyContinue'
            }
            if ($Recurse) { $getArgs['Recurse'] = $true }

            Get-ChildItem @getArgs |
                Where-Object { $_.LastWriteTime -lt $cutoff } |
                ForEach-Object {
                    if ((New-TimeSpan -Start $global:ScriptStartTime -End (Get-Date)).TotalSeconds -ge $global:ScriptTimeoutSec) {
                        Write-Log "Time budget exhausted mid-delete at [$rPath] — stopping cleanly." -Level WARN
                        return
                    }
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                }
        }
        catch {
            Write-Log "Error deleting files in [$rPath]: $($_.Exception.Message)" -Level WARN
        }

        # ── Remove empty subdirectories when recursing ──
        if ($Recurse) {
            try {
                Get-ChildItem -Path $rPath -Directory -Recurse -Force -ErrorAction SilentlyContinue |
                    Sort-Object FullName -Descending |
                    ForEach-Object {
                        if ((Get-ChildItem $_.FullName -Force -ErrorAction SilentlyContinue |
                             Measure-Object).Count -eq 0) {
                            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                        }
                    }
            }
            catch {
                Write-Log "Error pruning empty directories in [$rPath]: $($_.Exception.Message)" -Level WARN
            }
        }
    }
}

# ─────────────────────────────────────────────
# HELPER: Stop a service with timeout guard
# ─────────────────────────────────────────────
function Stop-ServiceSafe {
    param([string]$Name)
    try {
        $svc = Get-Service -Name $Name -ErrorAction Stop
        if ($svc.Status -eq 'Stopped') {
            Write-Log "Service '$Name' already stopped." -Level INFO
            return
        }
        Stop-Service -Name $Name -Force -ErrorAction Stop
        $waited = 0
        while ((Get-Service -Name $Name -ErrorAction SilentlyContinue).Status -ne 'Stopped' `
               -and $waited -lt $global:ServiceTimeoutSec) {
            Start-Sleep -Seconds 2
            $waited += 2
        }
        if ($waited -ge $global:ServiceTimeoutSec) {
            Write-Log "Service '$Name' did not stop within $($global:ServiceTimeoutSec)s — continuing." -Level WARN
        }
        else {
            Write-Log "Service '$Name' stopped successfully." -Level INFO
        }
    }
    catch {
        Write-Log "Failed to stop service '$Name': $($_.Exception.Message)" -Level WARN
    }
}

# ─────────────────────────────────────────────
# HELPER: Start a service with timeout guard
# ─────────────────────────────────────────────
function Start-ServiceSafe {
    param([string]$Name)
    try {
        $svc = Get-Service -Name $Name -ErrorAction Stop
        if ($svc.Status -eq 'Running') {
            Write-Log "Service '$Name' already running." -Level INFO
            return
        }
        Start-Service -Name $Name -ErrorAction Stop
        $waited = 0
        while ((Get-Service -Name $Name -ErrorAction SilentlyContinue).Status -ne 'Running' `
               -and $waited -lt $global:ServiceTimeoutSec) {
            Start-Sleep -Seconds 2
            $waited += 2
        }
        if ($waited -ge $global:ServiceTimeoutSec) {
            Write-Log "Service '$Name' did not start within $($global:ServiceTimeoutSec)s — continuing." -Level WARN
        }
        else {
            Write-Log "Service '$Name' started successfully." -Level INFO
        }
    }
    catch {
        Write-Log "Failed to start service '$Name': $($_.Exception.Message)" -Level WARN
    }
}

# ═══════════════════════════════════════════════════════════════
# SECTION 2 — SMART AUTOMATION CONTROL
#   Prevents the script running more than 3 times within 6 hours
# ═══════════════════════════════════════════════════════════════
try {
    $acDir       = 'C:\Apps\Monitor\logs\AutomationControl'
    $acFile      = "$acDir\t_po_os_shell_citrix_thr_disk_util.log"
    $runScore    = 1
    $maxDuration = 6

    if (!(Test-Path -Path $acDir)) {
        New-Item $acDir -Force -ItemType Directory -ErrorAction Stop | Out-Null
        Start-Sleep 2
    }
    else {
        if (!(Test-Path -Path $acFile)) {
            New-Item $acFile -ItemType File -Value $runScore -ErrorAction Stop | Out-Null
        }

        [int]$runScore     = Get-Content $acFile -ErrorAction Stop
        $lastWriteTime     = (Get-Item $acFile -ErrorAction Stop).LastWriteTime
        $dt                = (Get-Date).DateTime
        $duration          = New-TimeSpan -Start $lastWriteTime -End $dt

        if (($runScore -ge 3) -and ($duration.Hours -le $maxDuration)) {
            New-Item $acFile -ItemType File -Value 0 -Force -ErrorAction Stop | Out-Null
            throw "Automation reached maximum run count within $maxDuration hours."
        }
        elseif (($runScore -eq 0) -and ($duration.TotalHours -ge $maxDuration)) {
            throw "Automation run count reset — maximum duration of $maxDuration hours reached."
        }
        else {
            $runScore++
            New-Item $acFile -ItemType File -Value $runScore -Force -ErrorAction Stop | Out-Null
            Write-Output "INFO: Automation control check passed. RunScore = $runScore"
        }
    }
}
catch {
    $dt = (Get-Date).DateTime
    Write-Output "ERROR: $($_.Exception.Message)" |
        Out-File -Append -FilePath "C:\Windows\Temp\UC023_AutoCtrl_Error.log"
    Write-Output "Do not close the ticket without proper cleanup. Take necessary actions if cleanup is not possible."
    Write-Output "$dt : CODE:FAIL"
    Write-Output "ACTION: Dispatch Ticket To L2"
    Write-Output "Exitcode : 1"
    Exit 1
}

# ═══════════════════════════════════════════════════════════════
# SECTION 3 — ADMIN RIGHTS CHECK
# ═══════════════════════════════════════════════════════════════
try {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Script must be run as Administrator."
    }
    Write-Log "Administrator rights confirmed." -Level INFO
}
catch {
    Write-Log "Admin check failed: $($_.Exception.Message)" -Level ERROR
    Write-Output "$(Get-Date) : CODE:FAIL"
    Exit 1
}

# ═══════════════════════════════════════════════════════════════
# SECTION 4 — PRE-CLEANUP SPACE SNAPSHOT
# ═══════════════════════════════════════════════════════════════
Write-Log "--- PRE-CLEANUP SPACE SNAPSHOT ---" -Level INFO
$beforeSpace = Get-CDriveSpace
Write-DriveSpaceReport -Label "Before Cleanup" -Space $beforeSpace

# ═══════════════════════════════════════════════════════════════
# SECTION 5 — CLEANUP PHASES
# ═══════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────
# PHASE 1: Rogue Folders + Memory Dump
# ─────────────────────────────────────────────
Assert-TimeRemaining -Phase "RogueFolders"
Write-Log "--- PHASE 1: Rogue Folders + Memory Dump ---" -Level INFO

try {
    @('C:\Config.Msi', 'C:\Intel', 'C:\PerfLogs') | ForEach-Object {
        if (Test-Path $_) {
            Remove-Item -Path $_ -Force -Recurse -ErrorAction SilentlyContinue
            Write-Log "Removed rogue folder: $_" -Level INFO
        }
    }
}
catch {
    Write-Log "Error removing rogue folders: $($_.Exception.Message)" -Level WARN
}

# memory.dmp — lock-check before deletion
try {
    $dmpPath = "$env:windir\memory.dmp"
    if (Test-Path $dmpPath) {
        $isLocked = $false
        try {
            $stream = [System.IO.File]::Open(
                $dmpPath,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
            $stream.Close()
            $stream.Dispose()
        }
        catch {
            $isLocked = $true
            Write-Log "memory.dmp is locked/in-use (crash dump may still be in progress) — skipping." -Level WARN
        }
        if (-not $isLocked) {
            Remove-Item -LiteralPath $dmpPath -Force -ErrorAction Stop
            Write-Log "Deleted memory.dmp successfully." -Level INFO
        }
    }
}
catch {
    Write-Log "Error handling memory.dmp: $($_.Exception.Message)" -Level WARN
}

# ─────────────────────────────────────────────
# PHASE 2: Windows Error Reporting
# ─────────────────────────────────────────────
Assert-TimeRemaining -Phase "WER"
Write-Log "--- PHASE 2: Windows Error Reporting ---" -Level INFO

try {
    $werPath = 'C:\ProgramData\Microsoft\Windows\WER'
    if (Test-Path $werPath) {
        Get-ChildItem -Path $werPath -Recurse -Force -ErrorAction SilentlyContinue |
            Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
        Write-Log "WER files removed." -Level INFO
    }
    else {
        Write-Log "WER path not found — skipping." -Level INFO
    }
}
catch {
    Write-Log "Error removing WER files: $($_.Exception.Message)" -Level WARN
}

# ─────────────────────────────────────────────
# PHASE 3: System Temp / Prefetch / Minidump
# ─────────────────────────────────────────────
Assert-TimeRemaining -Phase "SystemTemp"
Write-Log "--- PHASE 3: System Temp / Prefetch / Minidump ---" -Level INFO

try {
    Remove-OldFiles -Path "$env:windir\Temp"     -Recurse
    Remove-OldFiles -Path "$env:windir\minidump"
    Remove-OldFiles -Path "$env:windir\Prefetch"
    Write-Log "System Temp / Prefetch / Minidump cleanup completed." -Level INFO
}
catch {
    Write-Log "Error in System Temp cleanup: $($_.Exception.Message)" -Level WARN
}

# ─────────────────────────────────────────────
# PHASE 4: User Profile Temp and Cache
# ─────────────────────────────────────────────
Assert-TimeRemaining -Phase "UserProfiles"
Write-Log "--- PHASE 4: User Profile Temp and Cache ---" -Level INFO

$userSubPaths = @(
    'AppData\Local\Temp'
    'AppData\Local\Microsoft\Windows\WER'
    'AppData\Local\Microsoft\Windows\Temporary Internet Files'
    'AppData\Local\Microsoft\Windows\IECompatCache'
    'AppData\Local\Microsoft\Windows\IECompatUaCache'
    'AppData\Local\Microsoft\Windows\IEDownloadHistory'
    'AppData\Local\Microsoft\Windows\INetCache'
    'AppData\Local\Microsoft\Windows\INetCookies'
    'AppData\Local\Microsoft\Terminal Server Client\Cache'
)

$cutoff = (Get-Date).AddDays(-$global:FileAgeDays)

try {
    $profiles = Get-ChildItem -Path 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue
    foreach ($profile in $profiles) {
        $profileRoot = $profile.FullName
        foreach ($sub in $userSubPaths) {
            Assert-TimeRemaining -Phase "UserProfile:$($profile.Name):$sub"
            $target = Join-Path $profileRoot $sub
            if (!(Test-Path $target)) { continue }
            try {
                Get-ChildItem -Path $target -File -Recurse -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt $cutoff } |
                    ForEach-Object {
                        if ((New-TimeSpan -Start $global:ScriptStartTime -End (Get-Date)).TotalSeconds -ge $global:ScriptTimeoutSec) {
                            Write-Log "Time budget exhausted mid-delete at [$target] — stopping cleanly." -Level WARN
                            return
                        }
                        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                    }
            }
            catch {
                Write-Log "Error cleaning [$target]: $($_.Exception.Message)" -Level WARN
            }
        }
    }
    Write-Log "User profile cache cleanup completed." -Level INFO
}
catch {
    Write-Log "Error enumerating user profiles: $($_.Exception.Message)" -Level WARN
}

# ─────────────────────────────────────────────
# PHASE 5: Windows Update Downloads
# ─────────────────────────────────────────────
Assert-TimeRemaining -Phase "SoftwareDistribution"
Write-Log "--- PHASE 5: Windows Update Downloads ---" -Level INFO

try {
    Stop-ServiceSafe -Name 'wuauserv'
    Stop-ServiceSafe -Name 'TrustedInstaller'

    Remove-OldFiles -Path "$env:windir\SoftwareDistribution" -Recurse
    Remove-OldFiles -Path "$env:windir\Logs\CBS"             -Recurse

    Start-ServiceSafe -Name 'wuauserv'
    Start-ServiceSafe -Name 'TrustedInstaller'
    Write-Log "Windows Update Downloads cleanup completed." -Level INFO
}
catch {
    Write-Log "Error in Windows Update cleanup: $($_.Exception.Message)" -Level WARN
    # Attempt to restore services even if cleanup failed
    Start-ServiceSafe -Name 'wuauserv'
    Start-ServiceSafe -Name 'TrustedInstaller'
}

# ─────────────────────────────────────────────
# PHASE 6: CleanMgr.exe (if present on server)
# ─────────────────────────────────────────────
Assert-TimeRemaining -Phase "CleanMgr"
Write-Log "--- PHASE 6: CleanMgr.exe ---" -Level INFO

$cleanMgrPath = 'C:\Windows\System32\cleanmgr.exe'

if (-not (Test-Path $cleanMgrPath)) {
    Write-Log "cleanmgr.exe not present on this server — skipping." -Level INFO
}
else {
    try {
        $StateFlags = 'StateFlags0013'
        $StateRun   = '/sagerun:' + $StateFlags.Substring($StateFlags.Length - 2)
        $regBase    = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'

        # Configure registry keys only if not already set
        if (-not (Get-ItemProperty -Path "$regBase\Active Setup Temp Folders" `
                  -Name $StateFlags -ErrorAction SilentlyContinue)) {
            $cleanupKeys = @(
                'Active Setup Temp Folders', 'BranchCache', 'Content Indexer Cleaner',
                'Device Driver Packages', 'Downloaded Program Files', 'GameNewsFiles',
                'GameStatisticsFiles', 'GameUpdateFiles', 'Internet Cache Files',
                'Memory Dump Files', 'Offline Pages Files', 'Old ChkDsk Files',
                'Previous Installations', 'Recycle Bin', 'Service Pack Cleanup',
                'Setup Log Files', 'System error memory dump files',
                'System error minidump files', 'Temporary Files', 'Temporary Setup Files',
                'Temporary Sync Files', 'Thumbnail Cache', 'Update Cleanup',
                'Upgrade Discarded Files', 'User file versions', 'Windows Defender',
                'Windows Error Reporting Archive Files', 'Windows Error Reporting Queue Files',
                'Windows Error Reporting System Archive Files',
                'Windows Error Reporting System Queue Files',
                'Windows ESD installation files', 'Windows Upgrade Log Files'
            )
            foreach ($key in $cleanupKeys) {
                $keyPath = "$regBase\$key"
                if (Test-Path $keyPath) {
                    Set-ItemProperty -Path $keyPath -Name $StateFlags -Value 2 -ErrorAction SilentlyContinue
                }
            }
            Write-Log "CleanMgr registry keys configured." -Level INFO
        }

        # Launch with 120s hard timeout
        Write-Log "Launching CleanMgr.exe with 120s timeout..." -Level INFO
        $proc = Start-Process -FilePath $cleanMgrPath -ArgumentList $StateRun -WindowStyle Hidden -PassThru -ErrorAction Stop
        if (-not $proc.WaitForExit(120000)) {
            Write-Log "CleanMgr.exe exceeded 120s timeout — killing process." -Level WARN
            $proc | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        else {
            Write-Log "CleanMgr.exe completed successfully." -Level INFO
        }
    }
    catch {
        Write-Log "Error running CleanMgr.exe: $($_.Exception.Message)" -Level WARN
    }
}

# ═══════════════════════════════════════════════════════════════
# SECTION 6 — POST-CLEANUP SPACE SNAPSHOT & SUMMARY
# ═══════════════════════════════════════════════════════════════
Write-Log "--- POST-CLEANUP SPACE SNAPSHOT ---" -Level INFO
$afterSpace = Get-CDriveSpace
Write-DriveSpaceReport -Label "After Cleanup" -Space $afterSpace

$reclaimed = [math]::Round(($afterSpace.FreeGB - $beforeSpace.FreeGB), 2)
$elapsed   = [math]::Round((New-TimeSpan -Start $global:ScriptStartTime -End (Get-Date)).TotalSeconds, 1)

Write-Log "Total Space Reclaimed : $reclaimed GB"  -Level INFO
Write-Log "Total Script Duration : ${elapsed}s"    -Level INFO
Write-Log "Log File              : $global:LogFile" -Level INFO
Write-Log "$(Get-Date) : CODE:SUCCESS"              -Level SUCCESS
