#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]  [string]   $LicenseServerFQDN,
    [Parameter(Mandatory=$false)] [string[]] $SessionHosts         = @(),
    [Parameter(Mandatory=$false)] [string]   $ADOrgUnit            = "",
    [Parameter(Mandatory=$false)] [string]   $ADHostFilter         = "(objectClass=computer)",
    [Parameter(Mandatory=$false)] [int]      $WarningThresholdPct  = 80,
    [Parameter(Mandatory=$false)] [int]      $CriticalThresholdPct = 95,
    [Parameter(Mandatory=$false)] [System.Management.Automation.PSCredential]
                                             $WinRMCredential       = $null,
    [Parameter(Mandatory=$false)] [string]   $CamundaBaseUrl       = "",
    [Parameter(Mandatory=$false)] [string]   $CamundaProcessKey    = "",
    [Parameter(Mandatory=$false)] [string]   $CamundaBusinessKey   = "",
    [Parameter(Mandatory=$false)] [System.Management.Automation.PSCredential]
                                             $CamundaCredential     = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

if ([System.IntPtr]::Size -ne 8) {
    Write-Warning "Running in 32-bit PowerShell. Some WMI/CIM operations may be limited."
}



# ============================================================================
#region CONFIG
# ============================================================================
# Edit ONLY this block for branding, colours, thresholds, and report labels.
# Do not change anything outside this region for routine customisation.

$CFG = @{
    ColorOK   = "#0A7A09"
    ColorWarn = "#B05E00"
    ColorErr  = "#BF0E1A"
    UseCase   = "UC3"
}

#endregion CONFIG
# ============================================================================


# ============================================================================
#region UTILITY FUNCTIONS
# ============================================================================

function Write-Log {
    param([string]$Msg, [string]$Lvl = "INFO")
    $col = switch ($Lvl) {
        "ERROR"   { "Red"    }
        "WARN"    { "Yellow" }
        "SUCCESS" { "Green"  }
        default   { "Cyan"   }
    }
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][$Lvl] $Msg" -ForegroundColor $col
}

function ConvertTo-Base64Utf8 {
    param([string]$InputString)
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($InputString))
}

function Get-SHA256Hash {
    param([string]$InputString)
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputString)
    $hash  = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
    $sha.Dispose()
    return $hash
}

function EscapeJson {
    param([string]$s)
    if ($null -eq $s) { return "" }
    return $s -replace '\\','\\' -replace '"','\"' -replace "`r`n",'\n' -replace "`n",'\n' -replace "`t",'\t'
}

function Invoke-CamundaRestApi {
    param(
        [string]    $BaseUrl,
        [string]    $ProcessKey,
        [string]    $BusinessKey,
        [hashtable] $Variables,
        [System.Management.Automation.PSCredential] $Credential
    )
    Write-Log "Camunda: Posting to $BaseUrl"
    $headers = @{ "Content-Type" = "application/json" }
    if ($Credential) {
        $raw = "$($Credential.GetNetworkCredential().UserName):$($Credential.GetNetworkCredential().Password)"
        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($raw))
        $headers["Authorization"] = "Basic $b64"
    }
    $cvars = @{}
    foreach ($kv in $Variables.GetEnumerator()) {
        $t = switch ($kv.Value.GetType().Name) {
            "Int32" { "Integer" } "Int64" { "Long" } "Double" { "Double" }
            "Boolean" { "Boolean" } default { "String" }
        }
        $cvars[$kv.Key] = @{ value = $kv.Value; type = $t }
    }
    $body = @{
        messageName      = $ProcessKey
        businessKey      = $BusinessKey
        processVariables = $cvars
        resultEnabled    = $true
    } | ConvertTo-Json -Depth 6
    try {
        $r = Invoke-RestMethod -Uri "$BaseUrl/message" -Method Post -Headers $headers -Body $body -ErrorAction Stop
        Write-Log "Camunda: Correlated successfully (businessKey=$BusinessKey)" "SUCCESS"
        return $r
    } catch {
        Write-Log "Camunda: Correlation failed ($($_.Exception.Message)), trying start..." "WARN"
    }
    $body2 = @{ businessKey = $BusinessKey; variables = $cvars } | ConvertTo-Json -Depth 6
    try {
        $r = Invoke-RestMethod -Uri "$BaseUrl/process-definition/key/$ProcessKey/start" `
            -Method Post -Headers $headers -Body $body2 -ErrorAction Stop
        Write-Log "Camunda: Process started (id=$($r.id))" "SUCCESS"
        return $r
    } catch {
        Write-Log "Camunda: Failed - $($_.Exception.Message)" "ERROR"
        return $null
    }
}

#endregion UTILITY FUNCTIONS
# ============================================================================


# ============================================================================
#region INITIALISATION
# ============================================================================

$ScriptStartTime = Get-Date
$ExecutionHost   = $env:COMPUTERNAME
$ExecutionUser   = "$env:USERDOMAIN\$env:USERNAME"
$PSVersion       = $PSVersionTable.PSVersion.ToString()
$Is64Bit         = [System.IntPtr]::Size -eq 8

$HostResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$ErrorLog    = [System.Collections.Generic.List[string]]::new()

$KeyPacks  = @()
$Issued    = 0
$Available = 0
$Installed = 0   # Calculated from WMI/CIM TotalLicenses sum

Write-Log "=== RDS License Usage Monitoring | Citrix Workspace Automation Suite ==="
Write-Log "Host: $ExecutionHost | User: $ExecutionUser | PS $PSVersion | 64-bit: $Is64Bit"

#endregion INITIALISATION
# ============================================================================


# ============================================================================
#region QUERY RDS LICENSE SERVER
# ============================================================================

Write-Log "Querying license server via WMI: $LicenseServerFQDN"

try {
    $KeyPacks  = @(Get-WmiObject -Class "Win32_TSLicenseKeyPack" `
                    -ComputerName $LicenseServerFQDN -ErrorAction Stop)
    $Issued    = ($KeyPacks | Measure-Object IssuedLicenses    -Sum).Sum
    $Available = ($KeyPacks | Measure-Object AvailableLicenses -Sum).Sum
    $Installed = ($KeyPacks | Measure-Object TotalLicenses     -Sum).Sum
    Write-Log "WMI OK - Installed: $Installed | Issued: $Issued | Available: $Available" "SUCCESS"
} catch {
    Write-Log "WMI failed ($($_.Exception.Message)), retrying via CIM..." "WARN"
    try {
        $cimOpts = New-CimSessionOption -Protocol Dcom
        $cimSess = New-CimSession -ComputerName $LicenseServerFQDN -SessionOption $cimOpts -ErrorAction Stop
        $KeyPacks  = @(Get-CimInstance -CimSession $cimSess -ClassName "Win32_TSLicenseKeyPack" -ErrorAction Stop)
        $Issued    = ($KeyPacks | Measure-Object IssuedLicenses    -Sum).Sum
        $Available = ($KeyPacks | Measure-Object AvailableLicenses -Sum).Sum
        $Installed = ($KeyPacks | Measure-Object TotalLicenses     -Sum).Sum
        Remove-CimSession $cimSess
        Write-Log "CIM OK - Installed: $Installed | Issued: $Issued" "SUCCESS"
    } catch {
        $ErrorLog.Add("License server [$LicenseServerFQDN] unreachable: $($_.Exception.Message)")
        Write-Log "License server unreachable. CAL counts will show 0." "ERROR"
    }
}

$UsagePct   = if ($Installed -gt 0) { [math]::Round(($Issued / $Installed) * 100, 1) } else { 0 }
$Compliance = if     ($UsagePct -ge $CriticalThresholdPct) { "CRITICAL"  }
              elseif ($UsagePct -ge $WarningThresholdPct)  { "WARNING"   }
              else                                          { "COMPLIANT" }
$StatColor  = switch ($Compliance) {
    "CRITICAL" { $CFG.ColorErr  }
    "WARNING"  { $CFG.ColorWarn }
    default    { $CFG.ColorOK   }
}

Write-Log "CAL Usage: $Issued / $Installed = $UsagePct% => $Compliance"

#endregion QUERY RDS LICENSE SERVER
# ============================================================================


# ============================================================================
#region SESSION HOST DISCOVERY
# ============================================================================

$ResolvedHosts = [System.Collections.Generic.List[string]]::new()

if ($SessionHosts.Count -gt 0) {
    foreach ($h in $SessionHosts) { $t = $h.Trim(); if ($t) { $ResolvedHosts.Add($t) } }
    Write-Log "Explicit host list: $($ResolvedHosts.Count) host(s)." "SUCCESS"
} elseif ($ADOrgUnit) {
    Write-Log "Discovering hosts from AD OU: $ADOrgUnit"
    try {
        $searcher = [adsisearcher]"$ADHostFilter"
        $searcher.SearchRoot = [adsi]"LDAP://$ADOrgUnit"
        $searcher.PropertiesToLoad.AddRange(@("dnshostname","name")) | Out-Null
        $searcher.PageSize = 1000
        $results = $searcher.FindAll()
        foreach ($r in $results) {
            $dns = if ($r.Properties["dnshostname"].Count -gt 0) {
                $r.Properties["dnshostname"][0]
            } else { $r.Properties["name"][0] }
            if ($dns) { $ResolvedHosts.Add($dns.ToString()) }
        }
        $results.Dispose()
        Write-Log "AD discovery: $($ResolvedHosts.Count) host(s) found." "SUCCESS"
    } catch {
        $ErrorLog.Add("AD host discovery failed: $($_.Exception.Message)")
        Write-Log "AD discovery failed." "ERROR"
    }
} else {
    $ErrorLog.Add("No session hosts provided. Supply -SessionHosts or -ADOrgUnit.")
    Write-Log "No session hosts configured." "WARN"
}

#endregion SESSION HOST DISCOVERY
# ============================================================================


# ============================================================================
#region QUERY CITRIX SESSION HOSTS  (WinRM)
# ============================================================================

$SessionScript = {
    $sessions = query session 2>&1
    $active   = ($sessions | Where-Object { $_ -match "Active" }).Count
    $disco    = ($sessions | Where-Object { $_ -match "Disc"   }).Count

    $cpu = try {
        (Get-WmiObject Win32_Processor -ErrorAction Stop |
         Measure-Object LoadPercentage -Average).Average
    } catch { -1 }

    $os = try { Get-WmiObject Win32_OperatingSystem -ErrorAction Stop } catch { $null }

    $memPct = if ($os) {
        [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) /
                        $os.TotalVisibleMemorySize) * 100, 1)
    } else { -1 }

    $uptime = if ($os) {
        [math]::Round(((Get-Date) - $os.ConvertToDateTime($os.LastBootUpTime)).TotalHours, 1)
    } else { -1 }

    $disk       = try { Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop } catch { $null }
    $diskFreeGB = if ($disk) { [math]::Round($disk.FreeSpace / 1GB, 1) } else { -1 }

    $licMode = try {
        (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM" `
            -Name "Licensing Mode" -ErrorAction Stop)."Licensing Mode"
    } catch { "N/A" }

    $ctxVda = try {
        (Get-Service -Name "BrokerAgent" -ErrorAction Stop).Status.ToString()
    } catch { "N/A" }

    $ctxFarm = try {
        (Get-ItemProperty "HKLM:\SOFTWARE\Citrix\VirtualDesktopAgent" `
            -Name "ListOfDDCs" -ErrorAction SilentlyContinue).ListOfDDCs
    } catch { "N/A" }

    [PSCustomObject]@{
        HostName       = $env:COMPUTERNAME
        ActiveSessions = $active
        DiscoSessions  = $disco
        TotalSessions  = ($active + $disco)
        CPUPct         = $cpu
        MemUsedPct     = $memPct
        DiskFreeGB     = $diskFreeGB
        OSCaption      = if ($os) { $os.Caption    } else { "N/A" }
        OSBuild        = if ($os) { $os.BuildNumber } else { "N/A" }
        LicMode        = $licMode
        UptimeHrs      = $uptime
        CtxVdaStatus   = $ctxVda
        CtxFarm        = $ctxFarm
    }
}

# ── Parallel WinRM query (all reachable hosts in one round-trip) ──────────────
# Invoke-Command with an array of -ComputerName values fans out concurrently
# up to -ThrottleLimit connections (default 32). Each remote object comes back
# with a synthetic PSComputerName property — used below to match results back
# to the original host list.

if ($ResolvedHosts.Count -gt 0) {
    $invokeParams = @{
        ComputerName  = $ResolvedHosts.ToArray()
        ScriptBlock   = $SessionScript
        ThrottleLimit = 32
        ErrorAction   = "SilentlyContinue"
        ErrorVariable = "WinRMErrors"
    }
    if ($WinRMCredential) { $invokeParams["Credential"] = $WinRMCredential }

    Write-Log "WinRM: querying $($ResolvedHosts.Count) host(s) in parallel (ThrottleLimit=32)..."
    $t0          = Get-Date
    $AllInfos    = @(Invoke-Command @invokeParams)
    $batchDurSec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    Write-Log "WinRM batch complete in ${batchDurSec}s — $($AllInfos.Count)/$($ResolvedHosts.Count) responded." "SUCCESS"

    # Index successful results by PSComputerName (upper-cased for case-insensitive match)
    $InfoMap = @{}
    foreach ($info in $AllInfos) {
        $InfoMap[$info.PSComputerName.ToUpper()] = $info
    }

    # Collect names that failed so we can log them
    $FailedHosts = @{}
    foreach ($err in $WinRMErrors) {
        $tgt = $err.TargetObject
        if ($tgt) { $FailedHosts[$tgt.ToUpper()] = $err.Exception.Message }
    }

    foreach ($HostName in $ResolvedHosts) {
        $key  = $HostName.ToUpper()
        $info = $InfoMap[$key]

        if ($info) {
            $health = if     ($info.TotalSessions -gt 80)                    { "High Load"   }
                      elseif ($info.CPUPct -gt 85)                           { "CPU Warning" }
                      elseif ($info.MemUsedPct -gt 90)                       { "Mem Warning" }
                      elseif ($info.CtxVdaStatus -ne "Running" -and
                               $info.CtxVdaStatus -ne "N/A")                { "VDA Offline" }
                      else                                                    { "OK"          }

            $rowCss = if ($health -ne "OK") { "warn" } else { "ok" }
            Write-Log "  $HostName | Sessions: $($info.TotalSessions) | Health: $health" "SUCCESS"

            $HostResults.Add([PSCustomObject]@{
                VMName         = $HostName
                HostName       = $info.HostName
                OSCaption      = $info.OSCaption
                OSBuild        = $info.OSBuild
                ActiveSessions = $info.ActiveSessions
                DiscoSessions  = $info.DiscoSessions
                TotalSessions  = $info.TotalSessions
                CPUPct         = $info.CPUPct
                MemUsedPct     = $info.MemUsedPct
                DiskFreeGB     = $info.DiskFreeGB
                UptimeHrs      = $info.UptimeHrs
                LicMode        = $info.LicMode
                CtxVdaStatus   = $info.CtxVdaStatus
                CtxFarm        = $info.CtxFarm
                Health         = $health
                RowCss         = $rowCss
                DurationSec    = $batchDurSec
            })
        } else {
            $errMsg = if ($FailedHosts[$key]) { $FailedHosts[$key] } else { "No response" }
            $ErrorLog.Add("[$HostName] WinRM: $errMsg")
            Write-Log "ERROR $HostName : $errMsg" "ERROR"
            $HostResults.Add([PSCustomObject]@{
                VMName="$HostName"; HostName="N/A"; OSCaption="N/A"; OSBuild="N/A"
                ActiveSessions="N/A"; DiscoSessions="N/A"; TotalSessions="N/A"
                CPUPct="N/A"; MemUsedPct="N/A"; DiskFreeGB="N/A"; UptimeHrs="N/A"
                LicMode="N/A"; CtxVdaStatus="N/A"; CtxFarm="N/A"
                Health="WinRM Error"; RowCss="err"; DurationSec=0
            })
        }
    }
}

#endregion QUERY CITRIX SESSION HOSTS
# ============================================================================


# ============================================================================
#region COMPUTED VARIABLES
# ============================================================================

$ScriptDur    = [math]::Round(((Get-Date) - $ScriptStartTime).TotalSeconds, 1)
$GenDate      = Get-Date -Format "dddd, dd MMMM yyyy HH:mm:ss"
$GenISO       = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
$WarnPctLabel = "$WarningThresholdPct%"
$CritPctLabel = "$CriticalThresholdPct%"
$HeadroomPct  = if ($Installed -gt 0) { [math]::Round(($Available / $Installed) * 100, 1) } else { 0 }
$WarnCardSub  = if ($UsagePct -ge $WarningThresholdPct)  { "BREACHED"    } else { "Not reached" }
$CritCardSub  = if ($UsagePct -ge $CriticalThresholdPct) { "BREACHED"    } else { "Not reached" }
$HostDiscovery = if ($SessionHosts.Count -gt 0) { "Explicit list ($($ResolvedHosts.Count) hosts)" }
                 elseif ($ADOrgUnit)             { "AD OU: $ADOrgUnit" }
                 else                            { "None configured"   }

#endregion COMPUTED VARIABLES
# ============================================================================


# ============================================================================
#region SVG GAUGE
# ============================================================================

$GaugeDeg = [math]::Min(($UsagePct / 100) * 180, 180)
$GaugeRad = ($GaugeDeg - 90) * [math]::PI / 180
$GX       = [math]::Round(100 + 70 * [math]::Cos($GaugeRad), 1)
$GY       = [math]::Round(90  + 70 * [math]::Sin($GaugeRad), 1)
$LargeArc = if ($GaugeDeg -gt 90) { 1 } else { 0 }

$GaugeSVG = "<svg viewBox=`"0 0 200 115`" xmlns=`"http://www.w3.org/2000/svg`" style=`"width:150px;display:block;margin:0 auto;`">" +
            "<path d=`"M 30 90 A 70 70 0 0 1 170 90`" fill=`"none`" stroke=`"#E8E8EE`" stroke-width=`"18`" stroke-linecap=`"round`"/>" +
            "<path d=`"M 30 90 A 70 70 0 $LargeArc 1 $GX $GY`" fill=`"none`" stroke=`"$StatColor`" stroke-width=`"18`" stroke-linecap=`"round`"/>" +
            "<circle cx=`"$GX`" cy=`"$GY`" r=`"8`" fill=`"$StatColor`" stroke=`"#fff`" stroke-width=`"2.5`"/>" +
            "<text x=`"100`" y=`"71`" text-anchor=`"middle`" font-size=`"24`" font-weight=`"800`" fill=`"$StatColor`" font-family=`"Segoe UI,Arial,sans-serif`">$UsagePct%</text>" +
            "<text x=`"100`" y=`"87`" text-anchor=`"middle`" font-size=`"8`" fill=`"#888`" font-family=`"Segoe UI,Arial,sans-serif`">CAL Utilisation</text>" +
            "<text x=`"28`" y=`"108`" text-anchor=`"middle`" font-size=`"7`" fill=`"#BBB`">0%</text>" +
            "<text x=`"96`" y=`"113`" text-anchor=`"middle`" font-size=`"6.5`" fill=`"$($CFG.ColorWarn)`">WARN $WarnPctLabel</text>" +
            "<text x=`"172`" y=`"108`" text-anchor=`"middle`" font-size=`"7`" fill=`"#BBB`">100%</text>" +
            "</svg>"

#endregion SVG GAUGE
# ============================================================================


# ============================================================================
#region BUILD JSON DATA BLOCK
# ============================================================================
# All live data is serialised to JSON and injected into the HTML file.
# The HTML's JavaScript reads REPORT_DATA and renders every element dynamically.

# Key packs JSON array
$kpJsonItems = $KeyPacks | ForEach-Object {
    '{"KeyPackId":"' + (EscapeJson "$($_.KeyPackId)") + '",' +
    '"Description":"' + (EscapeJson "$($_.Description)") + '",' +
    '"ProductVersion":"' + (EscapeJson "$($_.ProductVersion)") + '",' +
    '"TotalLicenses":' + [int]$_.TotalLicenses + ',' +
    '"IssuedLicenses":' + [int]$_.IssuedLicenses + ',' +
    '"AvailableLicenses":' + [int]$_.AvailableLicenses + '}'
}
$kpJson = '[' + ($kpJsonItems -join ',') + ']'

# Hosts JSON array
$hostJsonItems = $HostResults | ForEach-Object {
    '{"VMName":"'         + (EscapeJson $_.VMName)         + '",' +
    '"OSCaption":"'       + (EscapeJson $_.OSCaption)       + '",' +
    '"OSBuild":"'         + (EscapeJson "$($_.OSBuild)")    + '",' +
    '"ActiveSessions":"'  + $_.ActiveSessions               + '",' +
    '"DiscoSessions":"'   + $_.DiscoSessions                + '",' +
    '"TotalSessions":"'   + $_.TotalSessions                + '",' +
    '"CPUPct":"'          + $_.CPUPct                       + '",' +
    '"MemUsedPct":"'      + $_.MemUsedPct                   + '",' +
    '"DiskFreeGB":"'      + $_.DiskFreeGB                   + '",' +
    '"UptimeHrs":"'       + $_.UptimeHrs                    + '",' +
    '"LicMode":"'         + (EscapeJson $_.LicMode)         + '",' +
    '"CtxVdaStatus":"'    + (EscapeJson $_.CtxVdaStatus)    + '",' +
    '"CtxFarm":"'         + (EscapeJson $_.CtxFarm)         + '",' +
    '"Health":"'          + (EscapeJson $_.Health)          + '",' +
    '"RowCss":"'          + $_.RowCss                       + '",' +
    '"DurationSec":"'     + $_.DurationSec                  + '"}'
}
$hostsJson = '[' + ($hostJsonItems -join ',') + ']'

# Errors JSON array
$errJsonItems = $ErrorLog | ForEach-Object { '"' + (EscapeJson $_) + '"' }
$errJson = '[' + ($errJsonItems -join ',') + ']'

# GaugeSVG — escape for JSON string
$gaugeSvgJson = EscapeJson $GaugeSVG

# Full JSON data block injected as a JS variable
$JsonBlock = @"
<script>
var REPORT_DATA = {
  "GenDate"           : "$(EscapeJson $GenDate)",
  "GenISO"            : "$(EscapeJson $GenISO)",
  "LicenseServerFQDN" : "$(EscapeJson $LicenseServerFQDN)",
  "Compliance"        : "$(EscapeJson $Compliance)",
  "UsagePct"          : $UsagePct,
  "Issued"            : $Issued,
  "Installed"         : $Installed,
  "Available"         : $Available,
  "HeadroomPct"       : $HeadroomPct,
  "WarnPctLabel"      : "$(EscapeJson $WarnPctLabel)",
  "CritPctLabel"      : "$(EscapeJson $CritPctLabel)",
  "WarnThresholdPct"  : $WarningThresholdPct,
  "CritThresholdPct"  : $CriticalThresholdPct,
  "WarnCardSub"       : "$(EscapeJson $WarnCardSub)",
  "CritCardSub"       : "$(EscapeJson $CritCardSub)",
  "HostCount"         : $($HostResults.Count),
  "HostDiscovery"     : "$(EscapeJson $HostDiscovery)",
  "ScriptDur"         : $ScriptDur,
  "PSVersion"         : "$(EscapeJson $PSVersion)",
  "Is64Bit"           : "$Is64Bit",
  "ExecutionHost"     : "$(EscapeJson $ExecutionHost)",
  "GaugeSVG"          : "$gaugeSvgJson",
  "ReportSHA256"      : "",
  "KeyPacks"          : $kpJson,
  "Hosts"             : $hostsJson,
  "Errors"            : $errJson
};
</script>
"@

#endregion BUILD JSON DATA BLOCK
# ============================================================================


# ============================================================================
#region INJECT DATA INTO HTML AND SAVE TO OUTPUT FOLDER
# ============================================================================
# Architecture:
#   UC3_RDSLicenseMonitoring.ps1               — this script (deployed via HPSA)
#   UC3_RDSLicenseMonitoring_Report.html        — static template (NEVER overwritten)
#   <ScriptDir>\output\UC3_RDS_<stamp>.html     — populated output (handed to Camunda)
#   <ScriptDir>\output\UC3_RDS_<stamp>.sha256   — integrity file
#
# Template stays clean. Every run generates a fresh timestamped output file.
# ---------------------------------------------------------------------------

$ScriptDir = if ($MyInvocation.MyCommand.Path) {
    Split-Path $MyInvocation.MyCommand.Path
} else { $PWD.Path }

# HTML template — same folder as PS1, never modified
$TemplatePath = Join-Path $ScriptDir "UC3_RDSLicenseMonitoring_Report.html"

# Output folder: <ScriptDir>\output\  (auto-created)
$OutputDir = Join-Path $ScriptDir "output"
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    Write-Log "Output folder created: $OutputDir" "SUCCESS"
}

# Timestamped output HTML filename
$FileStamp  = Get-Date -Format "yyyyMMdd_HHmmss"
$OutputFile = Join-Path $OutputDir "UC3_RDSLicenseMonitoring_${FileStamp}.html"

Write-Log "Template : $TemplatePath"
Write-Log "Output   : $OutputFile"

if (-not (Test-Path $TemplatePath)) {
    Write-Log "HTML template not found: $TemplatePath" "ERROR"
    Write-Log "Deploy UC3_RDSLicenseMonitoring_Report.html to the same folder as this PS1." "ERROR"
    exit 1
}

# Read clean template, inject live JSON before </body>, save to output file
$HtmlContent = Get-Content -Path $TemplatePath -Raw -Encoding UTF8
$HtmlContent = $HtmlContent -replace '</body>', "$JsonBlock`n</body>"

try {
    $HtmlContent | Out-File -FilePath $OutputFile -Encoding UTF8 -Force
    Write-Log "Output report saved: $OutputFile" "SUCCESS"
} catch {
    Write-Log "Could not save output report: $($_.Exception.Message)" "ERROR"
    exit 1
}

#endregion INJECT DATA INTO HTML AND SAVE TO OUTPUT FOLDER
# ============================================================================


# ============================================================================
#region SHA-256 AND HPSA OUTPUT
# ============================================================================

$ReportHash = Get-SHA256Hash -InputString $HtmlContent
Write-Log "SHA-256: $ReportHash"

# Back-fill SHA-256 into the output file (template placeholder stays empty)
$HtmlContent = $HtmlContent -replace '"ReportSHA256"\s*:\s*""', "`"ReportSHA256`": `"$ReportHash`""
$HtmlContent | Out-File -FilePath $OutputFile -Encoding UTF8 -Force

# Companion .sha256 integrity file in output folder
$HashFilePath = [System.IO.Path]::ChangeExtension($OutputFile, ".sha256")
"SHA256: $ReportHash  $([System.IO.Path]::GetFileName($OutputFile))" |
    Out-File -FilePath $HashFilePath -Encoding UTF8 -Force
Write-Log "SHA-256 file: $HashFilePath" "SUCCESS"

# Always emit Base64 + SHA-256 for HPSA/Camunda — no switch required
Write-Log "Emitting HPSA Base64 output..." "SUCCESS"
Write-Output "HPSA_REPORT_B64_START"
Write-Output (ConvertTo-Base64Utf8 -InputString $HtmlContent)
Write-Output "HPSA_REPORT_B64_END"
Write-Output "HPSA_REPORT_SHA256:$ReportHash"
Write-Output "HPSA_REPORT_PATH:$OutputFile"

#endregion SHA-256 AND HPSA OUTPUT
# ============================================================================


# ============================================================================
#region CAMUNDA INTEGRATION
# ============================================================================

if ($CamundaBaseUrl -and $CamundaProcessKey) {
    Write-Log "Camunda: BaseUrl=$CamundaBaseUrl ProcessKey=$CamundaProcessKey"
    $cvars = @{
        Compliance        = $Compliance
        UsagePct          = $UsagePct
        Issued            = $Issued
        Installed         = $Installed
        Available         = $Available
        HeadroomPct       = $HeadroomPct
        LicenseServer     = $LicenseServerFQDN
        SessionHostCount  = $HostResults.Count
        ErrorCount        = $ErrorLog.Count
        ReportSHA256      = $ReportHash
        ReportPath        = $OutputFile
        ReportBase64      = ConvertTo-Base64Utf8 -InputString $HtmlContent
        GeneratedISO      = $GenISO
        ScriptDurationSec = $ScriptDur
        ExecutionHost     = $ExecutionHost
        ExitCode          = $(if ($Compliance -eq "CRITICAL") { 2 } elseif ($Compliance -eq "WARNING") { 1 } else { 0 })
    }
    $bk = if ($CamundaBusinessKey) { $CamundaBusinessKey } else { "UC3-$(Get-Date -Format 'yyyyMMdd')" }
    $cr = Invoke-CamundaRestApi -BaseUrl $CamundaBaseUrl -ProcessKey $CamundaProcessKey `
            -BusinessKey $bk -Variables $cvars -Credential $CamundaCredential
    if ($cr) { Write-Log "Camunda: Posted successfully." "SUCCESS" }
    else     { Write-Log "Camunda: Post failed (non-fatal)." "WARN"  }
} else {
    Write-Log "Camunda integration not configured."
}

#endregion CAMUNDA INTEGRATION
# ============================================================================


Write-Log "Output   : $OutputFile" "SUCCESS"
Write-Log "SHA-256  : $ReportHash" "SUCCESS"
Write-Log "=== $($CFG.UseCase) Complete | $Compliance ($UsagePct%) | ${ScriptDur}s ===" "SUCCESS"

# Exit codes: 0=COMPLIANT  1=WARNING  2=CRITICAL
if     ($Compliance -eq "CRITICAL") { exit 2 }
elseif ($Compliance -eq "WARNING")  { exit 1 }
else                                 { exit 0 }
