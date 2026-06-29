# ============================================================
# SC_SGA_UC023_CTX_CdriveCleanup
# Version  : v01.06
# Purpose  : C Drive cleanup for Citrix Session Hosts
# Changes  : Full failure handling added across all phases;
#            per-phase result tracking; correct exit codes;
#            ErrorActionPreference scoped properly.
# ============================================================

# --- Global error preference: Stop so try/catch can intercept ---
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────
$global:ScriptTimeoutSec   = 480    # Hard ceiling for entire script (seconds)
$global:CleanMgrTimeoutSec = 120    # Max time to wait for CleanMgr.exe (seconds)
$global:ServiceTimeoutSec  = 30     # Max wait for service stop/start (seconds)
$global:FileAgeDays        = 7      # Only delete files older than N days
$global:ScriptStartTime    = Get-Date
$global:LogDate            = Get-Date -Format "yyyyMMdd_HHmmss"
$global:LogFile            = "C:\Windows\Temp\CTX_CdriveCleanup_$($global:LogDate).log"

# Per-phase result tracker  [Phase] -> "OK" | "WARN:..." | "FAIL:..."
$global:PhaseResults       = [ordered]@{}
$global:FailureOccurred    = $false

# ─────────────────────────────────────────────
# HELPER: Structured logging
# ─────────────────────────────────────────────
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","SUCCESS")]
        [string]$Level = "INFO"
    )
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    Write-Output $line
    try { $line | Out-File -Append -FilePath $global:LogFile -ErrorAction SilentlyContinue } catch {}
}

# ─────────────────────────────────────────────
# HELPER: Record phase result
# ─────────────────────────────────────────────
function Set-PhaseResult {
    param([string]$Phase, [string]$Status)   # Status: OK | WARN:msg | FAIL:msg
    $global:PhaseResults[$Phase] = $Status
    if ($Status -like "FAIL:*") { $global:FailureOccurred = $true }
}

# ─────────────────────────────────────────────
# HELPER: Assert script is within time budget
# ─────────────────────────────────────────────
function Assert-TimeRemaining {
    param([string]$Phase = "")
    $elapsed = (New-TimeSpan -Start $global:ScriptStartTime -End (Get-Date)).TotalSeconds
    if ($elapsed -ge $global:ScriptTimeoutSec) {
        Write-Log "Script time budget exhausted at phase [$Phase] after ${elapsed}s. Exiting." "WARN"
        Invoke-FinalSummary
        Exit 2   # Exit code 2 = timeout / partial completion — NOT success, NOT hard failure
    }
}

# ─────────────────────────────────────────────
# HELPER: C Drive space snapshot
# ─────────────────────────────────────────────
function Show-CDriveSpace {
    try {
        $drive = Get-CimInstance -Class Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        if (-not $drive) { throw "Win32_LogicalDisk returned no result for C:" }
        return [Ordered]@{
            TotalGB = [math]::Round($drive.Size / 1GB, 2)
            FreeGB  = [math]::Round($drive.FreeSpace / 1GB, 2)
            UsedGB  = [math]::Round(($drive.Size - $drive.FreeSpace) / 1GB, 2)
        }
    }
    catch {
        Write-Log "Could not query C drive space: $($_.Exception.Message)" "WARN"
        return [Ordered]@{ TotalGB = 0; FreeGB = 0; UsedGB = 0 }
    }
}

function Report-CDriveSpace {
    param([string]$Label, $Space)
    Write-Log "[$Label] Total: $($Space.TotalGB) GB  |  Used: $($Space.UsedGB) GB  |  Free: $($Space.FreeGB) GB" "INFO"
}

# ─────────────────────────────────────────────
# HELPER: Restore-point deletion
# ─────────────────────────────────────────────
function Delete-ComputerRestorePoints {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
        $restorePoints
    )
    begin {
        try {
            $fullName = "SystemRestore.DeleteRestorePoint"
            $isLoaded = ([AppDomain]::CurrentDomain.GetAssemblies() |
                ForEach-Object { $_.GetTypes() } |
                Where-Object { $_.FullName -eq $fullName }) -ne $null
            if (!$isLoaded) {
                Add-Type -MemberDefinition @"
                    [DllImport("Srclient.dll")]
                    public static extern int SRRemoveRestorePoint(int index);
"@ -Name DeleteRestorePoint -NameSpace SystemRestore -ErrorAction Stop
            }
        }
        catch {
            Write-Log "Could not load Srclient.dll for restore point deletion: $($_.Exception.Message)" "WARN"
            return
        }
    }
    process {
        foreach ($rp in $restorePoints) {
            try {
                if ($PSCmdlet.ShouldProcess("$($rp.Description)", "Deleting Restore Point")) {
                    [SystemRestore.DeleteRestorePoint]::SRRemoveRestorePoint($rp.SequenceNumber) | Out-Null
                }
            }
            catch {
                Write-Log "Failed to delete restore point '$($rp.Description)': $($_.Exception.Message)" "WARN"
            }
        }
    }
}

# ─────────────────────────────────────────────
# HELPER: Fast bulk delete — age-filtered, locked files skipped
# ─────────────────────────────────────────────
function Remove-OldFiles {
    param(
        [string]$Path,
        [switch]$Recurse
    )
    Assert-TimeRemaining -Phase "Remove-OldFiles:$Path"

    $cutoff       = (Get-Date).AddDays(-$global:FileAgeDays)
    $deletedCount = 0
    $errorCount   = 0

    try {
        $targets = if ($Path -match '\*') {
            $base = Split-Path $Path -Parent
            Get-ChildItem -Path $base -Directory -Force -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName (Split-Path $Path -Leaf) }
        } else { @($Path) }

        foreach ($t in $targets) {
            if (!(Test-Path $t -ErrorAction SilentlyContinue)) { continue }
            $getArgs = @{ Path = $t; File = $true; Force = $true; ErrorAction = 'SilentlyContinue' }
            if ($Recurse) { $getArgs['Recurse'] = $true }

            Get-ChildItem @getArgs |
                Where-Object { $_.LastWriteTime -lt $cutoff } |
                ForEach-Object {
                    try {
                        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                        $deletedCount++
                    }
                    catch {
                        # Locked / access-denied files are expected — count but don't fail
                        $errorCount++
                    }
                }

            # Prune empty subdirectories
            if ($Recurse) {
                Get-ChildItem -Path $t -Directory -Recurse -Force -ErrorAction SilentlyContinue |
                    Sort-Object FullName -Descending |
                    ForEach-Object {
                        if (!(Get-ChildItem $_.FullName -Force -ErrorAction SilentlyContinue)) {
                            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                        }
                    }
            }
        }
        Write-Log "  Path [$Path] — Deleted: $deletedCount file(s), Skipped/locked: $errorCount" "INFO"
    }
    catch {
        Write-Log "  Remove-OldFiles failed for [$Path]: $($_.Exception.Message)" "WARN"
    }
}

# ─────────────────────────────────────────────
# HELPER: Service stop/start with timeout + error handling
# ─────────────────────────────────────────────
function Stop-ServiceSafe {
    param([string]$Name)
    try {
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if (!$svc -or $svc.Status -eq 'Stopped') { return }
        Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
        $waited = 0
        while ((Get-Service -Name $Name -ErrorAction SilentlyContinue).Status -ne 'Stopped' -and
               $waited -lt $global:ServiceTimeoutSec) {
            Start-Sleep -Seconds 2; $waited += 2
        }
        if ($waited -ge $global:ServiceTimeoutSec) {
            Write-Log "Service '$Name' did not stop within $($global:ServiceTimeoutSec)s — continuing." "WARN"
        }
    }
    catch {
        Write-Log "Stop-ServiceSafe failed for '$Name': $($_.Exception.Message)" "WARN"
    }
}

function Start-ServiceSafe {
    param([string]$Name)
    try {
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if (!$svc -or $svc.Status -eq 'Running') { return }
        Start-Service -Name $Name -ErrorAction SilentlyContinue
        $waited = 0
        while ((Get-Service -Name $Name -ErrorAction SilentlyContinue).Status -ne 'Running' -and
               $waited -lt $global:ServiceTimeoutSec) {
            Start-Sleep -Seconds 2; $waited += 2
        }
        if ($waited -ge $global:ServiceTimeoutSec) {
            Write-Log "Service '$Name' did not start within $($global:ServiceTimeoutSec)s — continuing." "WARN"
        }
    }
    catch {
        Write-Log "Start-ServiceSafe failed for '$Name': $($_.Exception.Message)" "WARN"
    }
}

# ─────────────────────────────────────────────
# HELPER: Print phase summary table and final exit
# ─────────────────────────────────────────────
function Invoke-FinalSummary {
    $elapsed = [math]::Round((New-TimeSpan -Start $global:ScriptStartTime -End (Get-Date)).TotalSeconds, 1)
    Write-Log "─────────────────────────────────────────" "INFO"
    Write-Log "PHASE RESULTS SUMMARY" "INFO"
    Write-Log "─────────────────────────────────────────" "INFO"
    foreach ($key in $global:PhaseResults.Keys) {
        $val   = $global:PhaseResults[$key]
        $level = if ($val -eq "OK") { "SUCCESS" } elseif ($val -like "WARN:*") { "WARN" } else { "ERROR" }
        Write-Log ("  {0,-35} {1}" -f $key, $val) $level
    }
    Write-Log "─────────────────────────────────────────" "INFO"
    Write-Log "Total Script Duration : ${elapsed}s" "INFO"
    Write-Log "Log File              : $($global:LogFile)" "INFO"
}


# ════════════════════════════════════════════════════════
# SMART AUTOMATION CONTROL BLOCK
# ════════════════════════════════════════════════════════
try {
    $acDir  = 'C:\Apps\Monitor\logs\AutomationControl'
    $acFile = "$acDir\t_po_os_shell_citrix_thr_disk_util.log"
    $runscore    = 1
    $maxDuration = 6

    if (!(Test-Path -Path $acDir)) {
        New-Item $acDir -Force -ItemType Directory | Out-Null
        Start-Sleep 2
    }
    else {
        if (!(Test-Path -Path $acFile)) {
            New-Item $acFile -ItemType File -Value $runscore | Out-Null
        }
        [int]$RunScore   = Get-Content $acFile -ErrorAction Stop
        $lastWriteTime   = (Get-Item $acFile -ErrorAction Stop).LastWriteTime
        $dt              = Get-Date
        $duration        = New-TimeSpan -Start $lastWriteTime -End $dt

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
            Write-Log "Automation control check passed. RunScore: $runscore" "INFO"
        }
    }
}
catch {
    $msg = $_.Exception.Message
    Write-Output "ERROR: $msg"
    Write-Output "Do not close the ticket without proper cleanup. Take necessary action if cleanup is not possible."
    Write-Output "$(Get-Date) : CODE:FAIL"
    Write-Output "ACTION: Dispatch Ticket To L2"
    Write-Output "Exitcode : 1"
    try { "ERROR: $msg" | Out-File -Append -FilePath $global:LogFile -ErrorAction SilentlyContinue } catch {}
    Exit 1
}


# ════════════════════════════════════════════════════════
# ADMIN CHECK
# ════════════════════════════════════════════════════════
Write-Log "Checking Local Admin rights..." "INFO"
If (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]"Administrator")) {
    Write-Log "Script must be run as Administrator." "ERROR"
    Write-Output "$(Get-Date) : CODE:FAIL"
    Write-Output "ACTION: Dispatch Ticket To L2"
    Write-Output "Exitcode : 1"
    Exit 1
}


# ════════════════════════════════════════════════════════
# PRE-CLEANUP SNAPSHOT
# ════════════════════════════════════════════════════════
Write-Log "Checking C Drive space BEFORE cleanup..." "INFO"
$beforeSpace = Show-CDriveSpace
Report-CDriveSpace "Before Cleanup" $beforeSpace


# ════════════════════════════════════════════════════════
# PHASE 1 — SYSTEM RESTORE POINTS
# ════════════════════════════════════════════════════════
Assert-TimeRemaining -Phase "Phase1_RestorePoints"
Write-Log "Phase 1: Deleting System Restore Points..." "INFO"
try {
    $rps = Get-ComputerRestorePoint -ErrorAction SilentlyContinue
    if ($rps) {
        $rps | Delete-ComputerRestorePoints
        Write-Log "Phase 1: Restore points deleted." "INFO"
    } else {
        Write-Log "Phase 1: No restore points found." "INFO"
    }
    Set-PhaseResult "Phase1_RestorePoints" "OK"
}
catch {
    $errMsg = $_.Exception.Message
    Write-Log "Phase 1 FAILED: $errMsg" "ERROR"
    Set-PhaseResult "Phase1_RestorePoints" "FAIL:$errMsg"
}


# ════════════════════════════════════════════════════════
# PHASE 2 — ROGUE FOLDERS
# ════════════════════════════════════════════════════════
Assert-TimeRemaining -Phase "Phase2_RogueFolders"
Write-Log "Phase 2: Deleting Rogue folders..." "INFO"
try {
    $roguePaths = @('C:\Config.Msi','C:\Intel','C:\PerfLogs')
    foreach ($p in $roguePaths) {
        if (Test-Path $p -ErrorAction SilentlyContinue) {
            Remove-Item -Path $p -Force -Recurse -ErrorAction SilentlyContinue
            Write-Log "  Removed: $p" "INFO"
        }
    }
    $dmpFile = "$env:windir\memory.dmp"
    if (Test-Path $dmpFile -ErrorAction SilentlyContinue) {
        Remove-Item $dmpFile -Force -ErrorAction SilentlyContinue
        Write-Log "  Removed: $dmpFile" "INFO"
    }
    Set-PhaseResult "Phase2_RogueFolders" "OK"
}
catch {
    $errMsg = $_.Exception.Message
    Write-Log "Phase 2 FAILED: $errMsg" "ERROR"
    Set-PhaseResult "Phase2_RogueFolders" "FAIL:$errMsg"
}


# ════════════════════════════════════════════════════════
# PHASE 3 — WINDOWS ERROR REPORTING
# ════════════════════════════════════════════════════════
Assert-TimeRemaining -Phase "Phase3_WER"
Write-Log "Phase 3: Deleting Windows Error Reporting files..." "INFO"
try {
    $werPath = 'C:\ProgramData\Microsoft\Windows\WER'
    if (Test-Path $werPath) {
        Get-ChildItem -Path $werPath -Recurse -Force -ErrorAction SilentlyContinue |
            Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
        Write-Log "Phase 3: WER files removed." "INFO"
    } else {
        Write-Log "Phase 3: WER path not found — skipped." "INFO"
    }
    Set-PhaseResult "Phase3_WER" "OK"
}
catch {
    $errMsg = $_.Exception.Message
    Write-Log "Phase 3 FAILED: $errMsg" "ERROR"
    Set-PhaseResult "Phase3_WER" "FAIL:$errMsg"
}


# ════════════════════════════════════════════════════════
# PHASE 4 — SYSTEM TEMP / PREFETCH / MINIDUMP
# ════════════════════════════════════════════════════════
Assert-TimeRemaining -Phase "Phase4_SystemTemp"
Write-Log "Phase 4: Removing System Temp, Prefetch, Minidump files..." "INFO"
try {
    Remove-OldFiles -Path "$env:windir\Temp"     -Recurse
    Remove-OldFiles -Path "$env:windir\minidump" -Recurse
    Remove-OldFiles -Path "$env:windir\Prefetch"
    Set-PhaseResult "Phase4_SystemTemp" "OK"
}
catch {
    $errMsg = $_.Exception.Message
    Write-Log "Phase 4 FAILED: $errMsg" "ERROR"
    Set-PhaseResult "Phase4_SystemTemp" "FAIL:$errMsg"
}


# ════════════════════════════════════════════════════════
# PHASE 5 — USER PROFILE TEMP AND CACHE
# ════════════════════════════════════════════════════════
Assert-TimeRemaining -Phase "Phase5_UserProfiles"
Write-Log "Phase 5: Removing User Profile Temp and Cache files..." "INFO"
try {
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
    $cutoff     = (Get-Date).AddDays(-$global:FileAgeDays)
    $phaseWarn  = $false

    Get-ChildItem -Path 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $profileRoot = $_.FullName
        foreach ($sub in $userSubPaths) {
            Assert-TimeRemaining -Phase "Phase5_UserProfile:$($_.Name)"
            $target = Join-Path $profileRoot $sub
            if (!(Test-Path $target -ErrorAction SilentlyContinue)) { continue }
            try {
                Get-ChildItem -Path $target -File -Recurse -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt $cutoff } |
                    ForEach-Object {
                        try   { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop }
                        catch { <# locked file — skip silently #> }
                    }
            }
            catch {
                Write-Log "  WARN: Could not clean [$target]: $($_.Exception.Message)" "WARN"
                $phaseWarn = $true
            }
        }
    }

    if ($phaseWarn) {
        Set-PhaseResult "Phase5_UserProfiles" "WARN:Some profile sub-paths could not be cleaned"
    } else {
        Set-PhaseResult "Phase5_UserProfiles" "OK"
    }
}
catch {
    $errMsg = $_.Exception.Message
    Write-Log "Phase 5 FAILED: $errMsg" "ERROR"
    Set-PhaseResult "Phase5_UserProfiles" "FAIL:$errMsg"
}


# ════════════════════════════════════════════════════════
# PHASE 6 — WINDOWS UPDATE / SOFTWARE DISTRIBUTION
# ════════════════════════════════════════════════════════
Assert-TimeRemaining -Phase "Phase6_SoftwareDistribution"
Write-Log "Phase 6: Removing Windows Update Downloads..." "INFO"
try {
    Stop-ServiceSafe -Name 'wuauserv'
    Stop-ServiceSafe -Name 'TrustedInstaller'

    Remove-OldFiles -Path "$env:windir\SoftwareDistribution" -Recurse
    Remove-OldFiles -Path "$env:windir\Logs\CBS"             -Recurse

    Start-ServiceSafe -Name 'wuauserv'
    Start-ServiceSafe -Name 'TrustedInstaller'

    # Verify wuauserv came back — if not, that is a WARN not a FAIL
    $wuStatus = (Get-Service -Name 'wuauserv' -ErrorAction SilentlyContinue).Status
    if ($wuStatus -ne 'Running') {
        Write-Log "Phase 6: wuauserv is '$wuStatus' after restart attempt." "WARN"
        Set-PhaseResult "Phase6_SoftwareDistribution" "WARN:wuauserv status=$wuStatus after restart"
    } else {
        Set-PhaseResult "Phase6_SoftwareDistribution" "OK"
    }
}
catch {
    $errMsg = $_.Exception.Message
    Write-Log "Phase 6 FAILED: $errMsg" "ERROR"
    # Attempt service recovery even if deletion failed
    try { Start-ServiceSafe -Name 'wuauserv' } catch {}
    try { Start-ServiceSafe -Name 'TrustedInstaller' } catch {}
    Set-PhaseResult "Phase6_SoftwareDistribution" "FAIL:$errMsg"
}


# ════════════════════════════════════════════════════════
# PHASE 7 — CLEANMGR.EXE
# ════════════════════════════════════════════════════════
Assert-TimeRemaining -Phase "Phase7_CleanMgr"
Write-Log "Phase 7: Running Windows System Cleanup (CleanMgr.exe)..." "INFO"
try {
    $cleanmgrPath = 'C:\Windows\System32\cleanmgr.exe'

    if (!(Test-Path $cleanmgrPath)) {
        Write-Log "Phase 7: cleanmgr.exe not found — attempting install from WinSxS..." "WARN"
        $winsxsExe = "$env:windir\winsxs\amd64_microsoft-windows-cleanmgr_31bf3856ad364e35_6.1.7600.16385_none_c9392808773cd7da\cleanmgr.exe"
        $winsxsMui = "$env:windir\winsxs\amd64_microsoft-windows-cleanmgr.resources_31bf3856ad364e35_6.1.7600.16385_en-us_b9cb6194b257cc63\cleanmgr.exe.mui"
        if (Test-Path $winsxsExe) { Copy-Item $winsxsExe "$env:windir\System32" -Force -ErrorAction SilentlyContinue }
        if (Test-Path $winsxsMui) { Copy-Item $winsxsMui "$env:windir\System32\en-US" -Force -ErrorAction SilentlyContinue }
    }

    if (Test-Path $cleanmgrPath) {
        $StateFlags = 'StateFlags0013'
        $StateRun   = '/sagerun:' + $StateFlags.Substring($StateFlags.Length - 2)

        $regBase = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
        if (-not (Get-ItemProperty -Path "$regBase\Active Setup Temp Folders" -Name $StateFlags -ErrorAction SilentlyContinue)) {
            $cleanupKeys = @(
                'Active Setup Temp Folders','BranchCache','Content Indexer Cleaner',
                'Device Driver Packages','Downloaded Program Files','GameNewsFiles',
                'GameStatisticsFiles','GameUpdateFiles','Internet Cache Files',
                'Memory Dump Files','Offline Pages Files','Old ChkDsk Files',
                'Previous Installations','Recycle Bin','Service Pack Cleanup',
                'Setup Log Files','System error memory dump files',
                'System error minidump files','Temporary Files','Temporary Setup Files',
                'Temporary Sync Files','Thumbnail Cache','Update Cleanup',
                'Upgrade Discarded Files','User file versions','Windows Defender',
                'Windows Error Reporting Archive Files','Windows Error Reporting Queue Files',
                'Windows Error Reporting System Archive Files',
                'Windows Error Reporting System Queue Files',
                'Windows ESD installation files','Windows Upgrade Log Files'
            )
            foreach ($key in $cleanupKeys) {
                if (Test-Path "$regBase\$key") {
                    Set-ItemProperty -Path "$regBase\$key" -Name $StateFlags -Value 2 -ErrorAction SilentlyContinue
                }
            }
        }

        $proc = Start-Process -FilePath $cleanmgrPath -ArgumentList $StateRun -WindowStyle Hidden -PassThru -ErrorAction Stop
        if (!$proc.WaitForExit($global:CleanMgrTimeoutSec * 1000)) {
            Write-Log "Phase 7: CleanMgr.exe exceeded $($global:CleanMgrTimeoutSec)s — process killed." "WARN"
            $proc | Stop-Process -Force -ErrorAction SilentlyContinue
            Set-PhaseResult "Phase7_CleanMgr" "WARN:Killed after $($global:CleanMgrTimeoutSec)s timeout"
        }
        else {
            Write-Log "Phase 7: CleanMgr.exe completed. ExitCode: $($proc.ExitCode)" "INFO"
            if ($proc.ExitCode -ne 0) {
                Set-PhaseResult "Phase7_CleanMgr" "WARN:ExitCode=$($proc.ExitCode)"
            } else {
                Set-PhaseResult "Phase7_CleanMgr" "OK"
            }
        }
    }
    else {
        Write-Log "Phase 7: cleanmgr.exe not available after install attempt — skipped." "WARN"
        Set-PhaseResult "Phase7_CleanMgr" "WARN:cleanmgr.exe not found, phase skipped"
    }
}
catch {
    $errMsg = $_.Exception.Message
    Write-Log "Phase 7 FAILED: $errMsg" "ERROR"
    Set-PhaseResult "Phase7_CleanMgr" "FAIL:$errMsg"
}


# ════════════════════════════════════════════════════════
# POST-CLEANUP SNAPSHOT & FINAL SUMMARY
# ════════════════════════════════════════════════════════
Write-Log "Checking C Drive space AFTER cleanup..." "INFO"
$afterSpace = Show-CDriveSpace
Report-CDriveSpace "After Cleanup" $afterSpace

$reclaimed = [math]::Round(($afterSpace.FreeGB - $beforeSpace.FreeGB), 2)
Write-Log "Total Space Reclaimed : $reclaimed GB" "INFO"

Invoke-FinalSummary

# ─────────────────────────────────────────────
# FINAL EXIT CODE
#   0 = All phases OK (or only WARNs)
#   1 = One or more phases FAILED
#   2 = Script hit time budget (set by Assert-TimeRemaining)
# ─────────────────────────────────────────────
if ($global:FailureOccurred) {
    Write-Output "$(Get-Date) : CODE:FAIL"
    Write-Output "ACTION: Dispatch Ticket To L2"
    Write-Output "Exitcode : 1"
    Exit 1
}
else {
    Write-Output "$(Get-Date) : CODE:SUCCESS"
    Write-Output "Exitcode : 0"
    Exit 0
}
