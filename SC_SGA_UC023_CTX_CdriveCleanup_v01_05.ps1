$ErrorActionPreference = "SilentlyContinue"

##### SMART Automation Logic ####
try {
    $acDir  = 'C:\Apps\Monitor\logs\AutomationControl'
    $acFile = "$acDir\t_po_os_shell_citrix_thr_disk_util.log"
    $runscore   = 1
    $maxDuration = 6
    if (!(Test-Path -Path $acDir)) {
        New-Item $acDir -Force -ItemType Directory | Out-Null
        Start-Sleep 2
    }
    else {
        if (!(Test-Path -Path $acFile)) { New-Item $acFile -ItemType File -Value $runscore | Out-Null }
        [INT]$RunScore   = Get-Content($acFile)
        $lastWriteTime   = (Get-Item $acFile).LastWriteTime
        $dt              = (Get-Date).DateTime
        $duration        = NEW-TIMESPAN -Start $lastWriteTime -End $dt
        if (($RunScore -ge 3) -and ($duration.Hours -le $maxDuration)) {
            New-Item $acFile -ItemType File -Value 0 -Force | Out-Null
            throw "Automation reached Maximum run time in $maxDuration Hours."
        }
        elseif (($RunScore -eq 0) -and ($duration.TotalHours -ge $maxDuration)) {
            throw "Automation reached Maximum run time in $maxDuration Hours."
        }
        else {
            $runscore++
            New-Item $acFile -ItemType File -Value $runscore -Force | Out-Null
            Write-Output "Running the script"
        }
    }
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)" | Out-File -Append -FilePath "C:\Windows\Temp\$LogDate.log"
    Write-Output "Do not Close the ticket without proper cleanup and take necessary actions if the cleanup not possible."
    Write-Output "$dt : CODE:FAIL"
    Write-Output "ACTION: Dispatch Ticket To L2"
    Write-Output "Exitcode : 1"
    Exit 1
}

# ─────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────
$global:ScriptTimeoutSec   = 480          # Hard script ceiling: 8 minutes
$global:CleanMgrTimeoutSec = 120          # CleanMgr.exe ceiling: 2 minutes
$global:ServiceTimeoutSec  = 30           # Stop/Start-Service ceiling: 30 s
$global:FileAgeDays        = 7            # Only delete files older than N days
$global:ScriptStartTime    = Get-Date

# ─────────────────────────────────────────────
# HELPER: Guard remaining time budget
# ─────────────────────────────────────────────
function Assert-TimeRemaining {
    param([string]$Phase = "")
    $elapsed = (New-TimeSpan -Start $global:ScriptStartTime -End (Get-Date)).TotalSeconds
    if ($elapsed -ge $global:ScriptTimeoutSec) {
        Write-Output "WARN: Script time budget exhausted at phase [$Phase] after ${elapsed}s. Exiting cleanly."
        Exit 0
    }
}

# ─────────────────────────────────────────────
# HELPER: C Drive space snapshot
# ─────────────────────────────────────────────
function Show-CDriveSpace {
    $drive   = Get-CimInstance -Class Win32_LogicalDisk -Filter "DeviceID='C:'"
    $totalGB = [math]::Round($drive.Size / 1GB, 2)
    $freeGB  = [math]::Round($drive.FreeSpace / 1GB, 2)
    $usedGB  = [math]::Round(($totalGB - $freeGB), 2)
    return [Ordered]@{ TotalGB = $totalGB; UsedGB = $usedGB; FreeGB = $freeGB }
}

function Report-CDriveSpace($label, $space) {
    Write-Output "[$label] C Drive Space Report:"
    Write-Output "   Total Size : $($space.TotalGB) GB"
    Write-Output "   Used Space : $($space.UsedGB) GB"
    Write-Output "   Free Space : $($space.FreeGB) GB"
    Write-Output ""
}

# ─────────────────────────────────────────────
# HELPER: Restore-point deletion
# ─────────────────────────────────────────────
function Delete-ComputerRestorePoints {
    [CmdletBinding(SupportsShouldProcess = $True)]
    param(
        [Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
        $restorePoints
    )
    begin {
        $fullName = "SystemRestore.DeleteRestorePoint"
        $isLoaded = ([AppDomain]::CurrentDomain.GetAssemblies() |
            ForEach-Object { $_.GetTypes() } |
            Where-Object { $_.FullName -eq $fullName }) -ne $null
        if (!$isLoaded) {
            $SRClient = Add-Type -MemberDefinition @"
                [DllImport ("Srclient.dll")]
                public static extern int SRRemoveRestorePoint (int index);
"@ -Name DeleteRestorePoint -NameSpace SystemRestore -PassThru
        }
    }
    process {
        foreach ($restorePoint in $restorePoints) {
            if ($PSCmdlet.ShouldProcess("$($restorePoint.Description)", "Deleting Restorepoint")) {
                [SystemRestore.DeleteRestorePoint]::SRRemoveRestorePoint($restorePoint.SequenceNumber)
            }
        }
    }
}

# ─────────────────────────────────────────────
# HELPER: Fast bulk delete — no per-file lock check
# Uses cmd.exe /c del for speed; skips files in use gracefully.
# Only removes files older than $global:FileAgeDays days.
# ─────────────────────────────────────────────
function Remove-OldFiles {
    param(
        [string]$Path,
        [switch]$Recurse
    )

    Assert-TimeRemaining -Phase "Remove-OldFiles:$Path"

    $cutoff = (Get-Date).AddDays(-$global:FileAgeDays)

    # Resolve wildcard paths (e.g. C:\Users\*\AppData\...)
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

    foreach ($rPath in $resolvedPaths) {
        if (!(Test-Path $rPath)) { continue }

        $getArgs = @{
            Path            = $rPath
            File            = $true
            Force           = $true
            ErrorAction     = 'SilentlyContinue'
        }
        if ($Recurse) { $getArgs['Recurse'] = $true }

        Get-ChildItem @getArgs |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            ForEach-Object {
                # SilentlyContinue means locked/in-use files are skipped without error
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }

        # Remove empty subdirectories when recursing
        if ($Recurse) {
            Get-ChildItem -Path $rPath -Directory -Recurse -Force -ErrorAction SilentlyContinue |
                Sort-Object FullName -Descending |
                ForEach-Object {
                    if ((Get-ChildItem $_.FullName -Force -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) {
                        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                    }
                }
        }
    }
}

# ─────────────────────────────────────────────
# HELPER: Stop a service with timeout
# ─────────────────────────────────────────────
function Stop-ServiceSafe {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (!$svc -or $svc.Status -eq 'Stopped') { return }
    Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
    $waited = 0
    while ((Get-Service -Name $Name -ErrorAction SilentlyContinue).Status -ne 'Stopped' -and $waited -lt $global:ServiceTimeoutSec) {
        Start-Sleep -Seconds 2
        $waited += 2
    }
    if ($waited -ge $global:ServiceTimeoutSec) {
        Write-Output "WARN: Service '$Name' did not stop within ${global:ServiceTimeoutSec}s — continuing."
    }
}

function Start-ServiceSafe {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (!$svc -or $svc.Status -eq 'Running') { return }
    Start-Service -Name $Name -ErrorAction SilentlyContinue
    $waited = 0
    while ((Get-Service -Name $Name -ErrorAction SilentlyContinue).Status -ne 'Running' -and $waited -lt $global:ServiceTimeoutSec) {
        Start-Sleep -Seconds 2
        $waited += 2
    }
    if ($waited -ge $global:ServiceTimeoutSec) {
        Write-Output "WARN: Service '$Name' did not start within ${global:ServiceTimeoutSec}s — continuing."
    }
}

# ─────────────────────────────────────────────
# ADMIN CHECK
# ─────────────────────────────────────────────
Write-Output "Checking Local Admin rights..."
If (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "Please run this script as an Administrator!"
    Exit 1
}

# ─────────────────────────────────────────────
# PRE-CLEANUP SPACE SNAPSHOT
# ─────────────────────────────────────────────
Write-Output "Checking C Drive space before cleanup..."
$beforeSpace = Show-CDriveSpace
Report-CDriveSpace "Before Cleanup" $beforeSpace

# ─────────────────────────────────────────────
# 1. SYSTEM RESTORE POINTS
# ─────────────────────────────────────────────
Assert-TimeRemaining -Phase "RestorePoints"
Write-Output "Deleting System Restore Points..."
Get-ComputerRestorePoint | Delete-ComputerRestorePoints

# ─────────────────────────────────────────────
# 2. ROGUE FOLDERS
# ─────────────────────────────────────────────
Assert-TimeRemaining -Phase "RogueFolders"
Write-Output "Deleting Rogue folders..."
@('C:\Config.Msi', 'C:\Intel', 'C:\PerfLogs') | ForEach-Object {
    if (Test-Path $_) { Remove-Item -Path $_ -Force -Recurse -ErrorAction SilentlyContinue }
}
if (Test-Path "$env:windir\memory.dmp") {
    Remove-Item "$env:windir\memory.dmp" -Force -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────
# 3. WINDOWS ERROR REPORTING
# ─────────────────────────────────────────────
Assert-TimeRemaining -Phase "WER"
Write-Output "Deleting Windows Error Reporting files..."
if (Test-Path 'C:\ProgramData\Microsoft\Windows\WER') {
    Get-ChildItem -Path 'C:\ProgramData\Microsoft\Windows\WER' -Recurse -Force -ErrorAction SilentlyContinue |
        Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────
# 4. SYSTEM TEMP / PREFETCH / MINIDUMP
# ─────────────────────────────────────────────
Assert-TimeRemaining -Phase "SystemTemp"
Write-Output "Removing System Temp, Prefetch, Minidump files..."
Remove-OldFiles -Path "$env:windir\Temp"        -Recurse
Remove-OldFiles -Path "$env:windir\minidump"    -Recurse
Remove-OldFiles -Path "$env:windir\Prefetch"

# ─────────────────────────────────────────────
# 5. USER PROFILE TEMP AND CACHE
#    Batched into one pass per profile to avoid repeated wildcard expansion
# ─────────────────────────────────────────────
Assert-TimeRemaining -Phase "UserProfiles"
Write-Output "Removing User Profile Temp and Cache files..."

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

# Enumerate profiles once, then walk sub-paths — avoids 9 separate wildcard expansions
Get-ChildItem -Path 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
    $profileRoot = $_.FullName
    foreach ($sub in $userSubPaths) {
        Assert-TimeRemaining -Phase "UserProfile:$($_.Name):$sub"
        $target = Join-Path $profileRoot $sub
        if (!(Test-Path $target)) { continue }
        Get-ChildItem -Path $target -File -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    }
}

# ─────────────────────────────────────────────
# 6. WINDOWS UPDATE DOWNLOADS
# ─────────────────────────────────────────────
Assert-TimeRemaining -Phase "SoftwareDistribution"
Write-Output "Removing Windows Update Downloads..."
Stop-ServiceSafe -Name 'wuauserv'
Stop-ServiceSafe -Name 'TrustedInstaller'

Remove-OldFiles -Path "$env:windir\SoftwareDistribution" -Recurse
Remove-OldFiles -Path "$env:windir\Logs\CBS"             -Recurse

Start-ServiceSafe -Name 'wuauserv'
Start-ServiceSafe -Name 'TrustedInstaller'

# ─────────────────────────────────────────────
# 7. CLEANMGR.EXE — with hard timeout
# ─────────────────────────────────────────────
Assert-TimeRemaining -Phase "CleanMgr"
Write-Output "Checking if Windows Cleanup (cleanmgr.exe) exists..."

if (!(Test-Path 'C:\Windows\System32\cleanmgr.exe')) {
    Write-Output "Windows Cleanup NOT installed — attempting to install..."
    $winsxsCleanmgr = "$env:windir\winsxs\amd64_microsoft-windows-cleanmgr_31bf3856ad364e35_6.1.7600.16385_none_c9392808773cd7da\cleanmgr.exe"
    $winsxsMui      = "$env:windir\winsxs\amd64_microsoft-windows-cleanmgr.resources_31bf3856ad364e35_6.1.7600.16385_en-us_b9cb6194b257cc63\cleanmgr.exe.mui"
    if (Test-Path $winsxsCleanmgr) { Copy-Item $winsxsCleanmgr "$env:windir\System32" -Force -ErrorAction SilentlyContinue }
    if (Test-Path $winsxsMui)      { Copy-Item $winsxsMui "$env:windir\System32\en-US" -Force -ErrorAction SilentlyContinue }
}

if (Test-Path 'C:\Windows\System32\cleanmgr.exe') {
    Write-Output "Running Windows System Cleanup (CleanMgr.exe) with $($global:CleanMgrTimeoutSec)s timeout..."
    $StateFlags = 'StateFlags0013'
    $StateRun   = '/sagerun:' + $StateFlags.Substring($StateFlags.Length - 2)

    if (-not (Get-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Active Setup Temp Folders' -Name $StateFlags -ErrorAction SilentlyContinue)) {
        $regBase = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
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
    }

    # ── Launch CleanMgr with a hard timeout — never block the automation ──
    $proc = Start-Process -FilePath 'CleanMgr.exe' -ArgumentList $StateRun -WindowStyle Hidden -PassThru
    if (!$proc.WaitForExit($global:CleanMgrTimeoutSec * 1000)) {
        Write-Output "WARN: CleanMgr.exe exceeded ${global:CleanMgrTimeoutSec}s timeout — killing process."
        $proc | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Output "CleanMgr.exe completed successfully."
    }
}
else {
    Write-Output "WARN: cleanmgr.exe not found — skipping Windows System Cleanup."
}

# ─────────────────────────────────────────────
# POST-CLEANUP SPACE SNAPSHOT & SUMMARY
# ─────────────────────────────────────────────
Write-Output "Checking C Drive space after cleanup..."
$afterSpace = Show-CDriveSpace
Report-CDriveSpace "After Cleanup" $afterSpace

$reclaimed = [math]::Round(($afterSpace.FreeGB - $beforeSpace.FreeGB), 2)
$elapsed   = [math]::Round((New-TimeSpan -Start $global:ScriptStartTime -End (Get-Date)).TotalSeconds, 1)
Write-Output "Total Space Reclaimed : $reclaimed GB"
Write-Output "Total Script Duration : ${elapsed}s"
Write-Output "$(Get-Date) : CODE:SUCCESS"
