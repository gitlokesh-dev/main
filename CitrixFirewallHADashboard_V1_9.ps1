############################################################################################################
# Script Name  : CitrixFirewallHADashboard.ps1
# Description  : Citrix Firewall HA & Health Dashboard | Citrix Workspace Automation Suite
#                Replaces the manual screenshot routine (management-console HA, CPU, Device Summary, Health
#                Summary - All/Deviating Devices, and per-site PA Firewall HA + Terminal Server
#                Agent status) with a single automated HTML dashboard.
#                Sites are discovered dynamically from Panorama's device-group hierarchy at
#                runtime (Get-SiteGroups) -- there is no hardcoded site/firewall list in this
#                script. Add or remove a device group in Panorama and it appears/disappears
#                from the report on the next run.
#
# IMPORTANT    : Panorama/PAN-OS XML-API operational command tags can differ slightly by version.
#                The op-commands below (HA state, system resources, managed-device summary,
#                session info, resource-monitor, environmentals, interfaces, TS-Agent info) are
#                all standard/documented PAN-OS commands. "Deviating" devices are computed in
#                this script from the live per-device metrics against $Thresholds below (not
#                from a separate, version-specific "health-check" API) -- tune $Thresholds to
#                your environment's normal baseline. The device-group discovery command
#                ($OpCmd.DeviceGroups) is best-effort like the others -- if "show devicegroups"
#                returns a different shape on your PAN-OS version, adjust Get-SiteGroups' parsing.
############################################################################################################

#region PARAMETERS
# (no external parameters for now -- all configuration lives in the CONFIG region below.
#  INI/JSON-based external config can be reintroduced later once this is validated in prod.)
#endregion PARAMETERS


#region CONFIG
$ErrorActionPreference = "Continue"   # script level: HPSA/Camunda sees all console output
$ScriptVersion         = "V1.2"
$OutputDir             = "C:\Scripts\CitrixFirewallHA\output\"

# ---- Panorama ---------------------------------------------------------------
$Panorama = @{
    Host     = "panorama.corp.example.com"   # <-- update
    User     = "svc-panorama-ro"             # <-- update (read-only account recommended)
    Password = ""                            # <-- update, or leave blank to prompt/inject via HPSA secret
    ApiKey   = ""                            # <-- optional: pre-generated key skips the keygen call
}

# ---- Regional PA Firewall pairs + Terminal Server (User-ID) Agent ----------
# Sites and their member firewalls are NO LONGER hardcoded here -- they are discovered
# dynamically at runtime from Panorama's device-group hierarchy (Get-SiteGroups, below),
# the same hierarchy visible under Panorama > Device Groups. Each device group becomes
# one "site" card in the report, with its member firewalls pulled in automatically.
# Add/remove a site in Panorama itself and the report picks it up on the next run --
# nothing to edit in this script.

# Per-firewall API key/credential. Populate at runtime (below) using $Panorama credentials by default,
# or fill in $FirewallApiKeys["hostname"] = "..." if firewalls use independent local accounts.
$FirewallApiKeys = @{}

# ---- Thresholds ---------------------------------------------------------------
$CpuWarnPct = 75
$CpuCritPct = 90

# Per-metric deviation thresholds used to flag a device as "Deviating" in the
# Health Summary table -- tune these to your environment's normal baseline.
$Thresholds = @{
    CpsWarn      = 200     # connections/sec
    SessionWarn  = 10000   # concurrent sessions
    DpCpuWarnPct = 80      # data-plane CPU %
    MpCpuWarnPct = 80      # management-plane CPU %
    MpMemWarnPct = 85      # management-plane memory %
    LogRateWarn  = 200     # logs/sec
}

# ---- XML-API operational commands ---------------------------------------------
# All of these are standard, documented PAN-OS/Panorama op-commands. When run
# against Panorama with a &target=<serial> parameter, Panorama transparently
# proxies the command to that managed firewall -- this is how per-device
# health metrics (session/CPU/environmentals/interfaces) are pulled without
# needing direct network access to every firewall's management IP.
$OpCmd = @{
    HAState         = "<show><high-availability><state></state></high-availability></show>"
    SystemResources = "<show><system><resources></resources></system></show>"
    DevicesAll      = "<show><devices><all></all></devices></show>"
    SessionInfo     = "<show><session><info></info></show>"
    ResourceMonitor = "<show><running><resource-monitor><minute><last>1</last></minute></resource-monitor></running></show>"
    Environmentals  = "<show><system><environmentals></environmentals></system></show>"
    InterfaceAll    = "<show><interface>all</interface></show>"
    TsAgentInfo     = "<show><user><ts-agent-info></ts-agent-info></user></show>"
    DeviceGroups    = "<show><devicegroups></devicegroups></show>"
}
#endregion CONFIG


#region HELPERS

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Msg,
        [ValidateSet("INFO","SUCCESS","WARN","ERROR","STEP")][string]$Lvl = "INFO"
    )
    $col = switch ($Lvl) {
        "SUCCESS" { "Green"  }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red"    }
        "STEP"    { "Magenta"}
        default   { "Cyan"   }
    }
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][$Lvl] $Msg" -ForegroundColor $col
}

function EscapeJson {
    param([string]$s)
    if ([string]::IsNullOrEmpty($s)) { return "" }
    $s = $s.Replace('\', '\\')
    $s = $s -replace '"',    '\"'  `
            -replace "`r`n", '\n'  `
            -replace "`n",   '\n'  `
            -replace "`t",   '\t'
    return $s
}

function Get-Compliance {
    param([double]$Pct)
    if ($Pct -ge $CpuCritPct) { return "CRITICAL" }
    if ($Pct -ge $CpuWarnPct) { return "WARNING"  }
    return "NORMAL"
}

# Trust self-signed certs commonly used on PAN-OS mgmt interfaces (scoped to this process only).
function Enable-PanSelfSignedCerts {
    if ("TrustAllCertsPolicy" -as [type]) { return }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    } catch { }
}

# Generic PAN-OS / Panorama XML-API caller with retry. Pass -Target <serial> to have
# Panorama proxy the op-command to that specific managed firewall (standard PAN-OS capability).
function Invoke-PanApi {
    param(
        [Parameter(Mandatory)][string]$DeviceHost,
        [Parameter(Mandatory)][string]$ApiKey,
        [Parameter(Mandatory)][ValidateSet("op","keygen")][string]$Type,
        [string]$Cmd,
        [string]$Target,
        [int]$Retries = 2,
        [int]$TimeoutSec = 20
    )
    Enable-PanSelfSignedCerts
    $uri = "https://$DeviceHost/api/?type=$Type"
    if ($Type -eq "op") {
        $uri += "&cmd=" + [uri]::EscapeDataString($Cmd) + "&key=" + [uri]::EscapeDataString($ApiKey)
        if ($Target) { $uri += "&target=" + [uri]::EscapeDataString($Target) }
    }

    $attempt = 0
    do {
        $attempt++
        try {
            [xml]$resp = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec $TimeoutSec -ErrorAction Stop
            if ($resp.response.status -ne "success") {
                throw "API returned status='$($resp.response.status)' for $DeviceHost$(if($Target){" (target=$Target)"})"
            }
            return $resp.response
        } catch {
            if ($attempt -gt $Retries) { throw }
            Write-Log "  [$DeviceHost$(if($Target){"/$Target"})] API call failed (attempt $attempt/$($Retries+1)): $($_.Exception.Message) -- retrying..." "WARN"
            Start-Sleep -Seconds (2 * $attempt)
        }
    } while ($attempt -le $Retries)
}

function Get-PanApiKey {
    param([Parameter(Mandatory)][string]$DeviceHost,[Parameter(Mandatory)][string]$User,[Parameter(Mandatory)][string]$Password)
    Enable-PanSelfSignedCerts
    $uri = "https://$DeviceHost/api/?type=keygen&user=$([uri]::EscapeDataString($User))&password=$([uri]::EscapeDataString($Password))"
    try {
        [xml]$resp = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 20 -ErrorAction Stop
        if ($resp.response.status -ne "success") {
            throw "Panorama returned status='$($resp.response.status)' during keygen"
        }
        return $resp.response.result.key
    } catch {
        throw "Could not obtain API key from $DeviceHost -- check hostname/DNS, network reachability, and credentials. Original error: $($_.Exception.Message)"
    }
}

#endregion HELPERS


#region DATA COLLECTION

function Get-PanoramaHA {
    param([string]$DeviceHost,[string]$ApiKey)
    try {
        $r = Invoke-PanApi -DeviceHost $DeviceHost -ApiKey $ApiKey -Type op -Cmd $OpCmd.HAState
        $n = $r.result
        if (-not $n.enabled -or $n.enabled -eq "no") {
            return [pscustomobject]@{ Enabled=$false; LocalState="N/A"; PeerState="N/A"; Mode="Standalone"; ConfigSync="N/A"; Error=$null }
        }
        [pscustomobject]@{
            Enabled     = $true
            Mode        = "$($n.'group'.'mode')"
            LocalState  = "$($n.group.'local-info'.state)"
            LocalPrio   = "$($n.group.'local-info'.priority)"
            PeerState   = "$($n.group.'peer-info'.state)"
            PeerPrio    = "$($n.group.'peer-info'.priority)"
            ConfigSync  = "$($n.group.'running-sync')"
            Error       = $null
        }
    } catch {
        Write-Log "  Panorama HA query failed: $($_.Exception.Message)" "ERROR"
        [pscustomobject]@{ Enabled=$false; LocalState="UNKNOWN"; PeerState="UNKNOWN"; Mode="UNKNOWN"; ConfigSync="UNKNOWN"; Error=$_.Exception.Message }
    }
}

function Get-PanoramaResources {
    param([string]$DeviceHost,[string]$ApiKey)
    try {
        $r    = Invoke-PanApi -DeviceHost $DeviceHost -ApiKey $ApiKey -Type op -Cmd $OpCmd.SystemResources
        $text = "$($r.result)"
        # 'show system resources' returns raw top-style text, e.g.: "Cpu(s):  4.2%us,  1.1%sy, ..."
        $cpuPct = 0.0
        if ($text -match '(\d+(\.\d+)?)\s*%\s*us') { $cpuPct = [double]$Matches[1] }
        $memPct = 0.0
        if ($text -match 'Mem:\s*\d+k total,\s*(\d+)k used') {
            $memPct = 0.0  # left as 0 unless total/used both parsed below
        }
        $memTotal = $null; $memUsed = $null
        if ($text -match 'Mem:\s*(\d+)k total,\s*(\d+)k used') { $memTotal=[double]$Matches[1]; $memUsed=[double]$Matches[2] }
        if ($memTotal -gt 0) { $memPct = [math]::Round(($memUsed / $memTotal) * 100, 1) }
        [pscustomobject]@{
            CpuPct   = [math]::Round($cpuPct,1)
            MemPct   = $memPct
            State    = Get-Compliance -Pct $cpuPct
            Raw      = $text
            Error    = $null
        }
    } catch {
        Write-Log "  Panorama resources query failed: $($_.Exception.Message)" "ERROR"
        [pscustomobject]@{ CpuPct=0; MemPct=0; State="UNKNOWN"; Raw=""; Error=$_.Exception.Message }
    }
}

function Get-DeviceSummary {
    param([string]$DeviceHost,[string]$ApiKey)
    $list = [System.Collections.Generic.List[object]]::new()
    try {
        $r = Invoke-PanApi -DeviceHost $DeviceHost -ApiKey $ApiKey -Type op -Cmd $OpCmd.DevicesAll
        $entries = @($r.result.devices.entry)
        foreach ($d in $entries) {
            $haState   = if ($d.'ha' -and $d.'ha'.state) { "$($d.ha.state)" } else { "n/a" }
            $clusterSt = if ($d.'ha' -and $d.'ha'.'cluster-state') { "$($d.ha.'cluster-state')" } else { "n/a" }

            $vsysNames = @()
            if ($d.vsys -and $d.vsys.entry) { $vsysNames = @($d.vsys.entry | ForEach-Object { "$($_.'display-name')" }) }
            $virtualSystem = if ($vsysNames.Count -gt 0) { $vsysNames -join ', ' } else { "vsys1" }

            $tagList = @()
            if ($d.tag -and $d.tag.member) { $tagList = @($d.tag.member) }
            $tags = if ($tagList.Count -gt 0) { $tagList -join ', ' } else { "n/a" }

            $templateVal = if ($d.'template-stack') { "$($d.'template-stack')" }
                           elseif ($d.template)      { "$($d.template)" }
                           else { "n/a" }

            $deviceState = if ($d.deactivated -eq "yes") { "Deactivated" }
                           elseif ($d.connected -eq "yes") { "Connected" }
                           else { "Disconnected" }

            $certStatus = if ($d.'device-cert-present') { "$($d.'device-cert-present')" } else { "n/a" }
            $certExpiry = if ($d.'device-cert-expiry-date') { "$($d.'device-cert-expiry-date')" } else { "n/a" }
            $sharedPol  = if ($d.'shared-policy-status') { "$($d.'shared-policy-status')" } else { "n/a" }
            $cellFw     = if ($d.'cellular-firmware') { "$($d.'cellular-firmware')" } else { "n/a" }
            $ipv6       = if ($d.'ipv6-address') { "$($d.'ipv6-address')" } else { "n/a" }
            $cfgSize    = if ($d.'last-commit-all-merged-config-size') { "$($d.'last-commit-all-merged-config-size')" }
                          elseif ($d.'multi-vsys' ) { "n/a" } else { "n/a" }

            $list.Add([pscustomobject]@{
                Hostname          = "$($d.hostname)"
                VirtualSystem     = $virtualSystem
                Model             = "$($d.model)"
                ConfigSize        = $cfgSize
                Tags              = $tags
                CellularFirmware  = $cellFw
                Serial            = "$($d.serial)"
                IPv4              = "$($d.'ip-address')"
                IPv6              = $ipv6
                ClusterState      = $clusterSt
                Template          = $templateVal
                DeviceState       = $deviceState
                DeviceCert        = $certStatus
                DeviceCertExpiry  = $certExpiry
                SharedPolicy      = $sharedPol
                SwVersion         = "$($d.'sw-version')"
                Connected         = "$($d.connected)"
                HAState           = $haState
            })
        }
    } catch {
        Write-Log "  Device summary query failed: $($_.Exception.Message)" "ERROR"
    }
    return $list
}

function Get-DeviceHealthMetrics {
    param(
        [Parameter(Mandatory)][string]$PanoramaHost,
        [Parameter(Mandatory)][string]$ApiKey,
        [Parameter(Mandatory)][string]$Serial,
        [Parameter(Mandatory)][string]$Hostname,
        [string]$Model,
        [string]$ClusterState,
        [string]$HAPairStatus
    )

    $throughputKbps = 0.0; $cps = 0.0; $sessionCount = 0
    try {
        $r  = Invoke-PanApi -DeviceHost $PanoramaHost -ApiKey $ApiKey -Type op -Cmd $OpCmd.SessionInfo -Target $Serial
        $si = $r.result
        if ($si.'num-active') { $sessionCount = [int]("$($si.'num-active')" -as [int]) }
        if ($si.cps)          { $cps          = [double]("$($si.cps)" -as [double]) }
        if ($si.kbps)         { $throughputKbps = [double]("$($si.kbps)" -as [double]) }
    } catch {
        Write-Log "  [$Hostname] Session info query failed: $($_.Exception.Message)" "WARN"
    }

    $dpCpuPct = 0.0
    try {
        $r2  = Invoke-PanApi -DeviceHost $PanoramaHost -ApiKey $ApiKey -Type op -Cmd $OpCmd.ResourceMonitor -Target $Serial
        $cores = @($r2.result.'resource-monitor'.'data-processors'.entry.'second'.entry.'cpu-load-average'.entry.value)
        $cores = $cores | Where-Object { $_ -match '^\d+(\.\d+)?$' } | ForEach-Object { [double]$_ }
        if ($cores.Count -gt 0) { $dpCpuPct = [math]::Round((($cores | Measure-Object -Average).Average), 1) }
    } catch {
        Write-Log "  [$Hostname] Data-plane resource-monitor query failed: $($_.Exception.Message)" "WARN"
    }

    $mpCpuPct = 0.0; $mpMemPct = 0.0
    try {
        $r3   = Invoke-PanApi -DeviceHost $PanoramaHost -ApiKey $ApiKey -Type op -Cmd $OpCmd.SystemResources -Target $Serial
        $text = "$($r3.result)"
        if ($text -match '(\d+(\.\d+)?)\s*%\s*us') { $mpCpuPct = [double]$Matches[1] }
        if ($text -match 'Mem:\s*(\d+)k total,\s*(\d+)k used') {
            $memTotal = [double]$Matches[1]; $memUsed = [double]$Matches[2]
            if ($memTotal -gt 0) { $mpMemPct = [math]::Round(($memUsed / $memTotal) * 100, 1) }
        }
    } catch {
        Write-Log "  [$Hostname] Management-plane resources query failed: $($_.Exception.Message)" "WARN"
    }

    $fansState = "n/a"; $powerState = "n/a"
    try {
        $r4  = Invoke-PanApi -DeviceHost $PanoramaHost -ApiKey $ApiKey -Type op -Cmd $OpCmd.Environmentals -Target $Serial
        $env = $r4.result.Thermal
        $fanEntries = @($r4.result.Fan.entry)
        if ($fanEntries.Count -gt 0) {
            $bad = @($fanEntries | Where-Object { "$($_.alarm)" -eq "True" -or "$($_.alarm)" -eq "1" })
            $fansState = if ($bad.Count -gt 0) { "FAIL ($($bad.Count))" } else { "OK" }
        }
        $psEntries = @($r4.result.Power.entry)
        if ($psEntries.Count -gt 0) {
            $badPs = @($psEntries | Where-Object { "$($_.alarm)" -eq "True" -or "$($_.alarm)" -eq "1" })
            $powerState = if ($badPs.Count -gt 0) { "FAIL ($($badPs.Count))" } else { "OK" }
        }
    } catch {
        Write-Log "  [$Hostname] Environmentals query failed (chassis/VM without fans/PSU returns n/a): $($_.Exception.Message)" "WARN"
    }

    $portsUp = 0; $portsTotal = 0
    try {
        $r5  = Invoke-PanApi -DeviceHost $PanoramaHost -ApiKey $ApiKey -Type op -Cmd $OpCmd.InterfaceAll -Target $Serial
        $hw  = @($r5.result.hw.entry)
        $portsTotal = $hw.Count
        $portsUp    = @($hw | Where-Object { "$($_.state)" -eq "up" }).Count
    } catch {
        Write-Log "  [$Hostname] Interface status query failed: $($_.Exception.Message)" "WARN"
    }

    # Logging rate isn't exposed via a single universal op-command across PAN-OS versions;
    # left as n/a here unless your Panorama exposes it via a log-collector-stats command --
    # swap in the correct op-command for your version if you want this populated.
    [pscustomobject]@{
        Hostname        = $Hostname
        Model           = $Model
        ClusterState    = $ClusterState
        HAPairStatus    = $HAPairStatus
        ThroughputKbps  = [math]::Round($throughputKbps,0)
        CPS             = [math]::Round($cps,0)
        SessionCount    = $sessionCount
        DataPlaneCpuPct = $dpCpuPct
        MgmtCpuPct      = $mpCpuPct
        MgmtMemPct      = $mpMemPct
        LoggingRate     = "n/a"
        Fans            = $fansState
        PowerSupply     = $powerState
        Ports           = "$portsUp/$portsTotal"
    }
}

function Test-DeviceDeviation {
    param([Parameter(Mandatory)]$Row)
    $breaches = [System.Collections.Generic.List[object]]::new()
    if ($Row.CPS -gt $Thresholds.CpsWarn) {
        $breaches.Add([pscustomobject]@{ Hostname=$Row.Hostname; CheckName="CPS Threshold"; Status="WARNING"; CurrentValue="$($Row.CPS)"; Threshold="$($Thresholds.CpsWarn)"; Details="CPS $($Row.CPS) exceeds baseline of $($Thresholds.CpsWarn)" })
    }
    if ($Row.SessionCount -gt $Thresholds.SessionWarn) {
        $breaches.Add([pscustomobject]@{ Hostname=$Row.Hostname; CheckName="Session Count"; Status="WARNING"; CurrentValue="$($Row.SessionCount)"; Threshold="$($Thresholds.SessionWarn)"; Details="Sessions $($Row.SessionCount) exceeds baseline of $($Thresholds.SessionWarn)" })
    }
    if ($Row.DataPlaneCpuPct -gt $Thresholds.DpCpuWarnPct) {
        $breaches.Add([pscustomobject]@{ Hostname=$Row.Hostname; CheckName="Data-Plane CPU"; Status="WARNING"; CurrentValue="$($Row.DataPlaneCpuPct)%"; Threshold="$($Thresholds.DpCpuWarnPct)%"; Details="DP CPU $($Row.DataPlaneCpuPct)% exceeds baseline of $($Thresholds.DpCpuWarnPct)%" })
    }
    if ($Row.MgmtCpuPct -gt $Thresholds.MpCpuWarnPct) {
        $breaches.Add([pscustomobject]@{ Hostname=$Row.Hostname; CheckName="Mgmt-Plane CPU"; Status="WARNING"; CurrentValue="$($Row.MgmtCpuPct)%"; Threshold="$($Thresholds.MpCpuWarnPct)%"; Details="Mgmt CPU $($Row.MgmtCpuPct)% exceeds baseline of $($Thresholds.MpCpuWarnPct)%" })
    }
    if ($Row.MgmtMemPct -gt $Thresholds.MpMemWarnPct) {
        $breaches.Add([pscustomobject]@{ Hostname=$Row.Hostname; CheckName="Mgmt-Plane Memory"; Status="WARNING"; CurrentValue="$($Row.MgmtMemPct)%"; Threshold="$($Thresholds.MpMemWarnPct)%"; Details="Mgmt Mem $($Row.MgmtMemPct)% exceeds baseline of $($Thresholds.MpMemWarnPct)%" })
    }
    if ($Row.Fans -match '^FAIL') {
        $breaches.Add([pscustomobject]@{ Hostname=$Row.Hostname; CheckName="Fans"; Status="CRITICAL"; CurrentValue=$Row.Fans; Threshold="OK"; Details=$Row.Fans })
    }
    if ($Row.PowerSupply -match '^FAIL') {
        $breaches.Add([pscustomobject]@{ Hostname=$Row.Hostname; CheckName="Power Supply"; Status="CRITICAL"; CurrentValue=$Row.PowerSupply; Threshold="OK"; Details=$Row.PowerSupply })
    }
    return $breaches
}

function Test-VersionMatch {
    param([string]$Local,[string]$Peer)
    if ([string]::IsNullOrWhiteSpace($Local) -or [string]::IsNullOrWhiteSpace($Peer)) { return "n/a" }
    if ($Local -eq $Peer) { return "Match" } else { return "Mismatch" }
}

function Get-FirewallDetail {
    param([string]$Site,[string]$DeviceHost,[string]$ApiKey)

    $detail = [pscustomobject]@{
        Site = $Site; Firewall = $DeviceHost; Enabled = $false
        Mode = "n/a"; LocalState = "UNKNOWN"; PeerState = "UNKNOWN"; PeerIP = "n/a"; ConfigSync = "n/a"
        AppVersion = "n/a"; ThreatVersion = "n/a"; AntivirusVersion = "n/a"; PanOsVersion = "n/a"; GlobalProtectVersion = "n/a"
        HA1 = "n/a"; HA1Backup = "n/a"; HA2 = "n/a"; HA2Backup = "n/a"
        Plugins = @()
        MgmtCpuPct = 0; DataPlaneCpuPct = 0; SessionCount = 0; SessionMax = 0
        PortsUp = 0; PortsTotal = 0
        Error = $null
    }

    try {
        $r  = Invoke-PanApi -DeviceHost $DeviceHost -ApiKey $ApiKey -Type op -Cmd $OpCmd.HAState
        $n  = $r.result
        if ($n.enabled -and $n.enabled -ne "no") {
            $detail.Enabled    = $true
            $detail.Mode       = "$($n.group.mode)"
            $li = $n.group.'local-info'; $pi = $n.group.'peer-info'
            $detail.LocalState = "$($li.state)"
            $detail.PeerState  = "$($pi.state)"
            $detail.PeerIP     = if ($pi.'mgmt-ip') { "$($pi.'mgmt-ip')" } else { "$($pi.'ha1-ipaddr')" }
            $detail.ConfigSync = "$($n.group.'running-sync')"

            $detail.AppVersion           = Test-VersionMatch "$($li.'app-version')"      "$($pi.'app-version')"
            $detail.ThreatVersion        = Test-VersionMatch "$($li.'threat-version')"   "$($pi.'threat-version')"
            $detail.AntivirusVersion     = Test-VersionMatch "$($li.'av-version')"       "$($pi.'av-version')"
            $detail.PanOsVersion         = Test-VersionMatch "$($li.'build-rel')"        "$($pi.'build-rel')"
            $detail.GlobalProtectVersion = Test-VersionMatch "$($li.'gpclient-version')" "$($pi.'gpclient-version')"

            # HA1/HA2 link status tag names vary by PAN-OS version/model -- best effort, falls back to n/a.
            $detail.HA1       = if ($li.'ha1-link-status')        { "$($li.'ha1-link-status')" }        else { "n/a" }
            $detail.HA1Backup = if ($li.'ha1-backup-link-status') { "$($li.'ha1-backup-link-status')" }  else { "n/a" }
            $detail.HA2       = if ($li.'ha2-link-status')        { "$($li.'ha2-link-status')" }         else { "n/a" }
            $detail.HA2Backup = if ($li.'ha2-backup-link-status') { "$($li.'ha2-backup-link-status')" }  else { "n/a" }

            # Plugin match (opsconfig/dlp/vm_series/...) -- also version-dependent, best effort.
            if ($li.'plugin-version' -and $li.'plugin-version'.entry) {
                $localPlugins = @($li.'plugin-version'.entry)
                $peerPlugins  = @()
                if ($pi.'plugin-version' -and $pi.'plugin-version'.entry) { $peerPlugins = @($pi.'plugin-version'.entry) }
                $detail.Plugins = @($localPlugins | ForEach-Object {
                    $lp = $_
                    $pp = $peerPlugins | Where-Object { "$($_.name)" -eq "$($lp.name)" } | Select-Object -First 1
                    $st = if ($pp -and "$($pp.'#text')" -eq "$($lp.'#text')") { "Match" } elseif ($pp) { "Mismatch" } else { "n/a" }
                    [pscustomobject]@{ Name = "$($lp.name)"; Status = $st }
                })
            }
        }
    } catch {
        Write-Log "  [$Site] HA query failed on $DeviceHost -- $($_.Exception.Message)" "ERROR"
        $detail.Error = $_.Exception.Message
    }

    try {
        $r2   = Invoke-PanApi -DeviceHost $DeviceHost -ApiKey $ApiKey -Type op -Cmd $OpCmd.SystemResources
        $text = "$($r2.result)"
        if ($text -match '(\d+(\.\d+)?)\s*%\s*us') { $detail.MgmtCpuPct = [double]$Matches[1] }
    } catch {
        Write-Log "  [$Site] Mgmt-plane resources query failed on $DeviceHost -- $($_.Exception.Message)" "WARN"
    }

    try {
        $r3    = Invoke-PanApi -DeviceHost $DeviceHost -ApiKey $ApiKey -Type op -Cmd $OpCmd.ResourceMonitor
        $cores = @($r3.result.'resource-monitor'.'data-processors'.entry.'second'.entry.'cpu-load-average'.entry.value)
        $cores = $cores | Where-Object { $_ -match '^\d+(\.\d+)?$' } | ForEach-Object { [double]$_ }
        if ($cores.Count -gt 0) { $detail.DataPlaneCpuPct = [math]::Round((($cores | Measure-Object -Average).Average), 1) }
    } catch {
        Write-Log "  [$Site] Data-plane resource-monitor query failed on $DeviceHost -- $($_.Exception.Message)" "WARN"
    }

    try {
        $r4 = Invoke-PanApi -DeviceHost $DeviceHost -ApiKey $ApiKey -Type op -Cmd $OpCmd.SessionInfo
        $si = $r4.result
        if ($si.'num-active') { $detail.SessionCount = [int]("$($si.'num-active')" -as [int]) }
        if ($si.'num-max')    { $detail.SessionMax    = [int]("$($si.'num-max')" -as [int]) }
    } catch {
        Write-Log "  [$Site] Session info query failed on $DeviceHost -- $($_.Exception.Message)" "WARN"
    }

    try {
        $r5 = Invoke-PanApi -DeviceHost $DeviceHost -ApiKey $ApiKey -Type op -Cmd $OpCmd.InterfaceAll
        $hw = @($r5.result.hw.entry)
        $detail.PortsTotal = $hw.Count
        $detail.PortsUp    = @($hw | Where-Object { "$($_.state)" -eq "up" }).Count
    } catch {
        Write-Log "  [$Site] Interface status query failed on $DeviceHost -- $($_.Exception.Message)" "WARN"
    }

    return $detail
}

function Get-TsAgents {
    param([string]$Site,[string]$DeviceHost,[string]$ApiKey)
    $list = [System.Collections.Generic.List[object]]::new()
    try {
        $r = Invoke-PanApi -DeviceHost $DeviceHost -ApiKey $ApiKey -Type op -Cmd $OpCmd.TsAgentInfo
        $entries = @($r.result.entry)
        foreach ($e in $entries) {
            $list.Add([pscustomobject]@{
                Site      = $Site
                Firewall  = $DeviceHost
                Name      = "$($e.name)"
                Enabled   = ("$($e.enabled)" -match '(?i)^(yes|true|1)$')
                Host      = "$($e.ip)"
                Port      = "$($e.port)"
                Connected = ("$($e.status)" -match '(?i)conn')
            })
        }
    } catch {
        Write-Log "  [$Site] TS-Agent query failed on $DeviceHost -- $($_.Exception.Message)" "WARN"
    }
    return $list
}

# Discovers sites dynamically from Panorama's device-group hierarchy (Panorama > Device Groups),
# replacing what used to be a hardcoded $Sites list. Each device group becomes one "site",
# and its member device hostnames become that site's firewall list. No hardcoded hostnames.
function Get-SiteGroups {
    param([Parameter(Mandatory)][string]$DeviceHost,[Parameter(Mandatory)][string]$ApiKey)
    $sites = [System.Collections.Generic.List[object]]::new()
    try {
        $r  = Invoke-PanApi -DeviceHost $DeviceHost -ApiKey $ApiKey -Type op -Cmd $OpCmd.DeviceGroups
        $dg = @($r.result.devicegroups.entry)
        foreach ($g in $dg) {
            $members = @($g.devices.entry | ForEach-Object { "$($_.hostname)" } | Where-Object { $_ })
            if ($members.Count -eq 0) { continue }   # skip empty/template-only groups
            $sites.Add([pscustomobject]@{
                Site      = "$($g.name)"
                Firewalls = $members
            })
        }
    } catch {
        Write-Log "  Device-group discovery failed (check `$OpCmd.DeviceGroups tag for your PAN-OS version): $($_.Exception.Message)" "ERROR"
    }
    return $sites
}

#endregion DATA COLLECTION


#region HTML TEMPLATE

function Get-UnifiedTemplate {
    return @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<title>Citrix Firewall HA &amp; Health Dashboard</title>
<style>
:root{
  --brand       : rgba(216,0,116,1);
  --brand-ultra : rgba(216,0,116,0.04);
  --brand-soft  : rgba(216,0,116,0.09);
  --ok          : #1a9e5c;
  --warn        : #d9822b;
  --crit        : #d64545;
  --ink         : #1c1c26;
  --sub         : #6b6b76;
  --line        : #e6e6ec;
}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',Arial,sans-serif;background:#f5f5f8;color:var(--ink);font-size:13px}
.hdr{background:linear-gradient(135deg,var(--brand),#8d0050);color:#fff;padding:22px 28px}
.hdr h1{font-size:20px;font-weight:800}
.hdr .sub{font-size:12px;opacity:.9;margin-top:4px}
.wrap{padding:20px 28px 60px}
.kpi-row{display:grid;grid-template-columns:repeat(6,1fr);gap:12px;margin-bottom:22px}
.kpi{background:#fff;border:1px solid var(--line);border-radius:10px;padding:14px 16px;border-top:4px solid var(--brand)}
.kpi.ok{border-top-color:var(--ok)} .kpi.warn{border-top-color:var(--warn)} .kpi.crit{border-top-color:var(--crit)}
.kpi .lbl{font-size:10.5px;text-transform:uppercase;letter-spacing:.04em;color:var(--sub);font-weight:700}
.kpi .val{font-size:24px;font-weight:800;margin-top:4px}
.kpi .sub2{font-size:11px;color:var(--sub);margin-top:2px}
.sec{background:#fff;border:1px solid var(--line);border-radius:10px;margin-bottom:20px;overflow:hidden}
.sec-hd{background:var(--brand-ultra);padding:12px 16px;font-weight:800;font-size:13px;color:var(--brand);
        border-bottom:1px solid var(--line);cursor:pointer;display:flex;justify-content:space-between;align-items:center}
.sec-hd .car{transition:transform .15s}
.sec.collapsed .sec-body{display:none}
.sec.collapsed .car{transform:rotate(-90deg)}
.sec-body{padding:14px 16px}
table{width:100%;border-collapse:collapse;font-size:12px}
th{background:var(--brand);color:#fff;text-align:left;padding:8px 10px;font-size:11px;text-transform:uppercase;
   letter-spacing:.03em;cursor:pointer;user-select:none;white-space:nowrap}
th.sa::after{content:" \25B2";font-size:8px;opacity:.9}
th.sd::after{content:" \25BC";font-size:8px;opacity:.9}
th .th-lbl{display:inline-block}
th select.th-filt{
  display:block;width:100%;height:19px;margin-top:4px;
  padding:0 4px;font-size:8.5px;font-weight:600;font-family:inherit;
  text-transform:none;letter-spacing:0;
  border:1px solid rgba(255,255,255,.45);border-radius:3px;
  background:rgba(255,255,255,.14);color:#fff;outline:none;
  cursor:pointer;white-space:nowrap;
}
th select.th-filt:hover{background:rgba(255,255,255,.24)}
th select.th-filt.act{background:#fff;color:var(--brand);border-color:#fff;font-weight:800}
th select.th-filt option{color:#111;background:#fff;font-weight:500}
td{padding:7px 10px;border-bottom:1px solid var(--line)}
tr:hover td{background:var(--brand-ultra)}
.badge{display:inline-block;padding:2px 9px;border-radius:20px;font-size:10.5px;font-weight:700}
.b-ok{background:rgba(26,158,92,.12);color:var(--ok)}
.b-warn{background:rgba(217,130,43,.12);color:var(--warn)}
.b-crit{background:rgba(214,69,69,.12);color:var(--crit)}
.b-mut{background:#eee;color:#777}
.site-grid{display:flex;flex-direction:column;gap:18px}
.site-card{border:1px solid var(--line);border-radius:8px;padding:16px}
.site-card h4{color:var(--brand);font-size:13px;margin-bottom:10px;text-transform:uppercase;letter-spacing:.03em}
.site-sub-lbl{font-size:10.5px;font-weight:700;color:var(--sub);text-transform:uppercase;letter-spacing:.03em;margin:12px 0 6px}
.site-sub-lbl:first-of-type{margin-top:0}
.ts-wrap{max-height:260px;overflow-y:auto;border:1px solid var(--line);border-radius:8px;margin-top:2px}
.ts-wrap table{font-size:11.5px;width:100%}
.ts-wrap th{position:sticky;top:0}
.fw-row{display:flex;justify-content:space-between;padding:5px 0;border-bottom:1px dashed var(--line);font-size:12px}
.fw-row:last-child{border-bottom:none}
.footer{text-align:center;color:var(--sub);font-size:11px;padding:20px 0}
.health-flex{display:flex;gap:20px;align-items:flex-start;justify-content:space-between;flex-wrap:wrap-reverse}
.health-legend{flex:1;min-width:220px}
.health-legend .fw-row .cnt{font-weight:800}
.health-donut-wrap{flex:0 0 auto;display:flex;flex-direction:column;align-items:center}
.health-donut-wrap .dn-lbl{font-size:9.5px;color:var(--sub);text-transform:uppercase;letter-spacing:.04em;margin-top:4px;font-weight:700}
.tbl-scroll{overflow-x:auto}
.tbl-scroll table{min-width:900px}
#tblHealth{margin-top:16px}
</style>
</head>
<body>
<div class="hdr">
  <h1>Citrix Firewall HA &amp; Health Dashboard</h1>
  <div class="sub" id="genDateHdr">Generated --</div>
</div>
<div class="wrap">

  <div class="kpi-row" id="kpiRow"></div>

  <div class="sec" id="secPanorama">
    <div class="sec-hd" onclick="toggleSec('secPanorama')"><span>Firewall Management Console HA &amp; CPU Utilization</span><span class="car">&#9660;</span></div>
    <div class="sec-body" id="panoramaBody"></div>
  </div>

  <div class="sec" id="secDevices">
    <div class="sec-hd" onclick="toggleSec('secDevices')"><span>Citrix Firewall Device Summary</span><span class="car">&#9660;</span></div>
    <div class="sec-body"><div class="tbl-scroll"><table id="tblDevices"><thead><tr>
      <th onclick="sortT('tblDevices',0)">Device Name</th>
      <th onclick="sortT('tblDevices',1)">Virtual System</th>
      <th onclick="sortT('tblDevices',2)"><span class="th-lbl">Model</span><br>
        <select id="tblDevices_f2" class="th-filt" data-col="2" onclick="event.stopPropagation()" onchange="applyTableFilter('tblDevices')"><option value="">All</option></select></th>
      <th onclick="sortT('tblDevices',3)">Config Size</th>
      <th onclick="sortT('tblDevices',4)">Tags</th>
      <th onclick="sortT('tblDevices',5)">Cellular FW</th>
      <th onclick="sortT('tblDevices',6)">Serial Number</th>
      <th onclick="sortT('tblDevices',7)">IPv4</th>
      <th onclick="sortT('tblDevices',8)">IPv6</th>
      <th onclick="sortT('tblDevices',9)"><span class="th-lbl">Cluster State</span><br>
        <select id="tblDevices_f9" class="th-filt" data-col="9" onclick="event.stopPropagation()" onchange="applyTableFilter('tblDevices')"><option value="">All</option></select></th>
      <th onclick="sortT('tblDevices',10)">Template</th>
      <th onclick="sortT('tblDevices',11)"><span class="th-lbl">Device State</span><br>
        <select id="tblDevices_f11" class="th-filt" data-col="11" onclick="event.stopPropagation()" onchange="applyTableFilter('tblDevices')"><option value="">All</option></select></th>
      <th onclick="sortT('tblDevices',12)">Device Cert</th>
      <th onclick="sortT('tblDevices',13)">Cert Expiry</th>
      <th onclick="sortT('tblDevices',14)">Shared Policy</th>
      <th onclick="sortT('tblDevices',15)">SW Version</th>
      <th onclick="sortT('tblDevices',16)"><span class="th-lbl">Connected</span><br>
        <select id="tblDevices_f16" class="th-filt" data-col="16" onclick="event.stopPropagation()" onchange="applyTableFilter('tblDevices')"><option value="">All</option></select></th>
      <th onclick="sortT('tblDevices',17)"><span class="th-lbl">HA State</span><br>
        <select id="tblDevices_f17" class="th-filt" data-col="17" onclick="event.stopPropagation()" onchange="applyTableFilter('tblDevices')"><option value="">All</option></select></th>
    </tr></thead><tbody id="tbodyDevices"></tbody></table></div></div>
  </div>

  <div class="sec" id="secHealthAll">
    <div class="sec-hd" onclick="toggleSec('secHealthAll')"><span>Citrix Firewall Health Summary &mdash; All Devices</span><span class="car">&#9660;</span></div>
    <div class="sec-body">
      <div class="health-flex">
        <div class="health-legend" id="healthAllBody"></div>
        <div class="health-donut-wrap"><div id="healthDonut"></div><span class="dn-lbl">Device Health</span></div>
      </div>
      <div class="tbl-scroll"><table id="tblHealth"><thead><tr>
        <th onclick="sortT('tblHealth',0)">Device Name</th>
        <th onclick="sortT('tblHealth',1)"><span class="th-lbl">Model</span><br>
          <select id="tblHealth_f1" class="th-filt" data-col="1" onclick="event.stopPropagation()" onchange="applyTableFilter('tblHealth')"><option value="">All</option></select></th>
        <th onclick="sortT('tblHealth',2)"><span class="th-lbl">Cluster State</span><br>
          <select id="tblHealth_f2" class="th-filt" data-col="2" onclick="event.stopPropagation()" onchange="applyTableFilter('tblHealth')"><option value="">All</option></select></th>
        <th onclick="sortT('tblHealth',3)"><span class="th-lbl">HA Pair Status</span><br>
          <select id="tblHealth_f3" class="th-filt" data-col="3" onclick="event.stopPropagation()" onchange="applyTableFilter('tblHealth')"><option value="">All</option></select></th>
        <th onclick="sortT('tblHealth',4)">Throughput (Kbps)</th>
        <th onclick="sortT('tblHealth',5)">CPS</th>
        <th onclick="sortT('tblHealth',6)">Session Count</th>
        <th onclick="sortT('tblHealth',7)">DP CPU %</th>
        <th onclick="sortT('tblHealth',8)">MP CPU %</th>
        <th onclick="sortT('tblHealth',9)">MP MEM %</th>
        <th onclick="sortT('tblHealth',10)">Logging Rate</th>
        <th onclick="sortT('tblHealth',11)"><span class="th-lbl">Fans</span><br>
          <select id="tblHealth_f11" class="th-filt" data-col="11" onclick="event.stopPropagation()" onchange="applyTableFilter('tblHealth')"><option value="">All</option></select></th>
        <th onclick="sortT('tblHealth',12)"><span class="th-lbl">Power Supply</span><br>
          <select id="tblHealth_f12" class="th-filt" data-col="12" onclick="event.stopPropagation()" onchange="applyTableFilter('tblHealth')"><option value="">All</option></select></th>
        <th onclick="sortT('tblHealth',13)">Ports</th>
      </tr></thead><tbody id="tbodyHealth"></tbody></table></div>
    </div>
  </div>

  <div class="sec" id="secHealthDev">
    <div class="sec-hd" onclick="toggleSec('secHealthDev')"><span>Citrix Firewall Health Summary &mdash; Deviating Devices</span><span class="car">&#9660;</span></div>
    <div class="sec-body"><div class="tbl-scroll"><table id="tblDeviating"><thead><tr>
      <th onclick="sortT('tblDeviating',0)">Device Name</th>
      <th onclick="sortT('tblDeviating',1)"><span class="th-lbl">Model</span><br>
        <select id="tblDeviating_f1" class="th-filt" data-col="1" onclick="event.stopPropagation()" onchange="applyTableFilter('tblDeviating')"><option value="">All</option></select></th>
      <th onclick="sortT('tblDeviating',2)"><span class="th-lbl">Cluster State</span><br>
        <select id="tblDeviating_f2" class="th-filt" data-col="2" onclick="event.stopPropagation()" onchange="applyTableFilter('tblDeviating')"><option value="">All</option></select></th>
      <th onclick="sortT('tblDeviating',3)"><span class="th-lbl">HA Pair Status</span><br>
        <select id="tblDeviating_f3" class="th-filt" data-col="3" onclick="event.stopPropagation()" onchange="applyTableFilter('tblDeviating')"><option value="">All</option></select></th>
      <th onclick="sortT('tblDeviating',4)">Throughput (Kbps)</th>
      <th onclick="sortT('tblDeviating',5)">CPS</th>
      <th onclick="sortT('tblDeviating',6)">Session Count</th>
      <th onclick="sortT('tblDeviating',7)">DP CPU %</th>
      <th onclick="sortT('tblDeviating',8)">MP CPU %</th>
      <th onclick="sortT('tblDeviating',9)">MP MEM %</th>
      <th onclick="sortT('tblDeviating',10)">Logging Rate</th>
      <th onclick="sortT('tblDeviating',11)"><span class="th-lbl">Fans</span><br>
        <select id="tblDeviating_f11" class="th-filt" data-col="11" onclick="event.stopPropagation()" onchange="applyTableFilter('tblDeviating')"><option value="">All</option></select></th>
      <th onclick="sortT('tblDeviating',12)"><span class="th-lbl">Power Supply</span><br>
        <select id="tblDeviating_f12" class="th-filt" data-col="12" onclick="event.stopPropagation()" onchange="applyTableFilter('tblDeviating')"><option value="">All</option></select></th>
      <th onclick="sortT('tblDeviating',13)">Ports</th>
      <th onclick="sortT('tblDeviating',14)">Reason(s)</th>
    </tr></thead><tbody id="tbodyDeviating"></tbody></table></div></div>
  </div>

  <div class="sec" id="secSites">
    <div class="sec-hd" onclick="toggleSec('secSites')"><span>PA Firewall HA &amp; Terminal Server Agent &mdash; By Site</span><span class="car">&#9660;</span></div>
    <div class="sec-body"><div class="site-grid" id="siteGrid"></div></div>
  </div>

  <div class="footer">Citrix Firewall HA Dashboard &middot; auto-generated, no manual screenshots &middot; Citrix Workspace Automation Suite</div>
</div>

<script>
function toggleSec(id){ document.getElementById(id).classList.toggle('collapsed'); }
function badge(status){
  var s=(status||"").toString().toUpperCase();
  var crit = ["DISCONNECTED","MISMATCH","CRITICAL","DEACTIVATED","FAIL","DOWN"];
  var warn = ["PASSIVE","WARNING","OUT OF SYNC"];
  var ok   = ["ACTIVE","CONNECTED","HEALTHY","SUCCESS","SYNCHRONIZED","MATCH","VALID","IN SYNC"];
  if (crit.some(function(k){return s.indexOf(k)>=0;}) || /\bNO\b/.test(s))
    return '<span class="badge b-crit">'+status+'</span>';
  if (warn.some(function(k){return s.indexOf(k)>=0;}))
    return '<span class="badge b-warn">'+status+'</span>';
  if (ok.some(function(k){return s.indexOf(k)>=0;}) || /\b(YES|UP)\b/.test(s))
    return '<span class="badge b-ok">'+status+'</span>';
  return '<span class="badge b-mut">'+status+'</span>';
}
function kpi(lbl,val,sub,cls){
  return '<div class="kpi '+(cls||"")+'"><div class="lbl">'+lbl+'</div><div class="val">'+val+'</div><div class="sub2">'+(sub||"")+'</div></div>';
}
function kpiNum(lbl,target,suffix,sub,cls){
  return '<div class="kpi '+(cls||"")+'"><div class="lbl">'+lbl+'</div>'+
         '<div class="val cnt" data-target="'+target+'" data-suffix="'+(suffix||"")+'">0'+(suffix||"")+'</div>'+
         '<div class="sub2">'+(sub||"")+'</div></div>';
}
function animateCounters(){
  document.querySelectorAll('.val.cnt').forEach(function(el){
    var target = parseFloat(el.getAttribute('data-target')) || 0;
    var suffix = el.getAttribute('data-suffix') || '';
    var t0 = null, dur = 700;
    function step(ts){
      if(!t0) t0 = ts;
      var p = Math.min((ts - t0) / dur, 1);
      var cur = target * p;
      el.textContent = Math.round(cur) + suffix;
      if(p < 1) requestAnimationFrame(step); else el.textContent = Math.round(target) + suffix;
    }
    requestAnimationFrame(step);
  });
}

function buildDonut(healthy,deviating,disconnected){
  var total = healthy + deviating + disconnected;
  var safeTotal = total > 0 ? total : 1;
  var r = 32, c = 2 * Math.PI * r;
  var segs = [
    { v: healthy,      color: 'var(--ok)'   },
    { v: deviating,    color: 'var(--warn)' },
    { v: disconnected, color: 'var(--crit)' }
  ];
  var offset = 0, rings = '';
  segs.forEach(function(s){
    var len = (s.v / safeTotal) * c;
    if (len > 0) {
      rings += '<circle cx="45" cy="45" r="'+r+'" fill="none" stroke="'+s.color+'" stroke-width="11" ' +
               'stroke-dasharray="'+len.toFixed(2)+' '+(c-len).toFixed(2)+'" ' +
               'stroke-dashoffset="'+(-offset).toFixed(2)+'" transform="rotate(-90 45 45)"/>';
      offset += len;
    }
  });
  if (total === 0) rings = '<circle cx="45" cy="45" r="'+r+'" fill="none" stroke="var(--line)" stroke-width="11"/>';
  return '<svg width="100" height="100" viewBox="0 0 90 90">' + rings +
         '<circle cx="45" cy="45" r="22" fill="#fff"/>' +
         '<text x="45" y="42" text-anchor="middle" font-size="15" font-weight="800" fill="var(--ink)">'+total+'</text>' +
         '<text x="45" y="54" text-anchor="middle" font-size="6.5" fill="var(--sub)" letter-spacing="0.3">DEVICES</text>' +
         '</svg>';
}
function sortT(tableId,col){
  var t=document.getElementById(tableId), tb=t.tBodies[0], rows=Array.prototype.slice.call(tb.rows);
  var th=t.tHead.rows[0].cells[col];
  var asc = !th.classList.contains('sa');
  Array.prototype.forEach.call(t.tHead.rows[0].cells,function(c){c.classList.remove('sa','sd');});
  th.classList.add(asc?'sa':'sd');
  rows.sort(function(a,b){
    var x=a.cells[col].innerText.trim(), y=b.cells[col].innerText.trim();
    var nx=parseFloat(x), ny=parseFloat(y);
    if(!isNaN(nx) && !isNaN(ny)) return asc?(nx-ny):(ny-nx);
    return asc? x.localeCompare(y) : y.localeCompare(x);
  });
  rows.forEach(function(r){tb.appendChild(r);});
}

function populateColFilters(tableId, cols){
  var t = document.getElementById(tableId);
  if (!t) return;
  var tb = t.tBodies[0];
  cols.forEach(function(col){
    var sel = document.getElementById(tableId+'_f'+col);
    if (!sel) return;
    var seen = {};
    Array.prototype.forEach.call(tb.rows, function(r){
      var cell = r.cells[col];
      if (!cell) return;
      var txt = cell.innerText.trim();
      if (txt) seen[txt] = true;
    });
    var opts = Object.keys(seen).sort();
    sel.innerHTML = '<option value="">All</option>' + opts.map(function(v){
      return '<option value="'+v+'">'+v+'</option>';
    }).join('');
  });
}

function applyTableFilter(tableId){
  var t = document.getElementById(tableId);
  if (!t) return;
  var tb = t.tBodies[0];
  var filters = {};
  Array.prototype.forEach.call(t.tHead.querySelectorAll('select.th-filt'), function(sel){
    var col = parseInt(sel.getAttribute('data-col'), 10);
    if (sel.value) { filters[col] = sel.value; }
    sel.classList.toggle('act', !!sel.value);
  });
  Array.prototype.forEach.call(tb.rows, function(r){
    var show = true;
    Object.keys(filters).forEach(function(col){
      var cell = r.cells[col];
      var txt = cell ? cell.innerText.trim() : '';
      if (txt !== filters[col]) { show = false; }
    });
    r.style.display = show ? '' : 'none';
  });
}

function renderReport(){
  var D = window.REPORT_DATA;
  document.getElementById('genDateHdr').textContent = "Generated " + D.GenDate;

  var tsDown = D.Sites.reduce(function(n,s){return n + s.TsAgents.filter(function(a){return !a.Connected;}).length;},0);

  var kpis = "";
  kpis += kpi("Mgmt Console HA", D.Panorama.HA.LocalState + (D.Panorama.HA.Enabled? (" / "+D.Panorama.HA.PeerState) : ""),
              D.Panorama.HA.Enabled? ("Sync: "+D.Panorama.HA.ConfigSync) : "Standalone",
              D.Panorama.HA.LocalState==="active" ? "ok":"warn");
  kpis += kpiNum("Mgmt Console CPU", D.Panorama.Resources.CpuPct, "%", "Mem "+D.Panorama.Resources.MemPct+"%",
              D.Panorama.Resources.State==="NORMAL"?"ok":(D.Panorama.Resources.State==="WARNING"?"warn":"crit"));
  kpis += kpiNum("Managed Devices", D.Devices.length, "", "total reporting", "");
  kpis += kpiNum("Devices Healthy", D.HealthAll.Healthy, "", D.HealthAll.TotalDevices+" total", "ok");
  var devCls = D.HealthAll.Deviating>0 ? "warn":"ok";
  kpis += kpiNum("Devices Deviating", D.HealthAll.Deviating, "", D.HealthAll.Disconnected+" disconnected", devCls);
  kpis += kpiNum("TS Agents Down", tsDown, "", D.Sites.length+" site(s) monitored", tsDown>0?"crit":"ok");
  document.getElementById('kpiRow').innerHTML = kpis;
  animateCounters();

  var pb = '<div class="fw-row"><span>Local State</span>'+badge(D.Panorama.HA.LocalState)+'</div>';
  pb += '<div class="fw-row"><span>Peer State</span>'+badge(D.Panorama.HA.PeerState)+'</div>';
  pb += '<div class="fw-row"><span>Mode</span><span>'+D.Panorama.HA.Mode+'</span></div>';
  pb += '<div class="fw-row"><span>Config Sync</span>'+badge(D.Panorama.HA.ConfigSync)+'</div>';
  pb += '<div class="fw-row"><span>CPU Utilization</span><span>'+D.Panorama.Resources.CpuPct+'%</span></div>';
  pb += '<div class="fw-row"><span>Memory Utilization</span><span>'+D.Panorama.Resources.MemPct+'%</span></div>';
  document.getElementById('panoramaBody').innerHTML = pb;

  var rowsD = D.Devices.map(function(d){
    return '<tr><td>'+d.Hostname+'</td><td>'+d.VirtualSystem+'</td><td>'+d.Model+'</td><td>'+d.ConfigSize+'</td>'+
           '<td>'+d.Tags+'</td><td>'+d.CellularFirmware+'</td><td>'+d.Serial+'</td><td>'+d.IPv4+'</td><td>'+d.IPv6+'</td>'+
           '<td>'+d.ClusterState+'</td><td>'+d.Template+'</td><td>'+badge(d.DeviceState)+'</td><td>'+badge(d.DeviceCert)+'</td>'+
           '<td>'+d.DeviceCertExpiry+'</td><td>'+badge(d.SharedPolicy)+'</td><td>'+d.SwVersion+'</td>'+
           '<td>'+badge(d.Connected)+'</td><td>'+badge(d.HAState)+'</td></tr>';
  }).join('');
  document.getElementById('tbodyDevices').innerHTML = rowsD || '<tr><td colspan="18" style="text-align:center;color:#999">No devices returned</td></tr>';
  populateColFilters('tblDevices',[2,9,11,16,17]);

  document.getElementById('healthDonut').innerHTML = buildDonut(D.HealthAll.Healthy, D.HealthAll.Deviating, D.HealthAll.Disconnected);
  var hb = '<div class="fw-row"><span>Total Devices</span><span class="cnt">'+D.HealthAll.TotalDevices+'</span></div>';
  hb += '<div class="fw-row"><span>&#9679; Healthy</span><span class="cnt" style="color:var(--ok)">'+D.HealthAll.Healthy+'</span></div>';
  hb += '<div class="fw-row"><span>&#9679; Deviating</span><span class="cnt" style="color:var(--warn)">'+D.HealthAll.Deviating+'</span></div>';
  hb += '<div class="fw-row"><span>&#9679; Disconnected</span><span class="cnt" style="color:var(--crit)">'+D.HealthAll.Disconnected+'</span></div>';
  document.getElementById('healthAllBody').innerHTML = hb;

  function isBreach(hostname, checkName){
    return D.Deviating.some(function(d){ return d.Hostname===hostname && d.CheckName===checkName; });
  }
  function metricCell(hostname, checkName, val){
    return isBreach(hostname, checkName) ? '<span style="color:var(--crit);font-weight:700">'+val+'</span>' : val;
  }
  function healthRowCells(h){
    return '<td>'+h.Hostname+'</td><td>'+h.Model+'</td><td>'+(h.ClusterState||'n/a')+'</td><td>'+badge(h.HAPairStatus)+'</td>'+
           '<td>'+h.ThroughputKbps+'</td><td>'+metricCell(h.Hostname,'CPS Threshold',h.CPS)+'</td>'+
           '<td>'+metricCell(h.Hostname,'Session Count',h.SessionCount)+'</td>'+
           '<td>'+metricCell(h.Hostname,'Data-Plane CPU',h.DataPlaneCpuPct+'%')+'</td>'+
           '<td>'+metricCell(h.Hostname,'Mgmt-Plane CPU',h.MgmtCpuPct+'%')+'</td>'+
           '<td>'+metricCell(h.Hostname,'Mgmt-Plane Memory',h.MgmtMemPct+'%')+'</td>'+
           '<td>'+h.LoggingRate+'</td><td>'+badge(h.Fans)+'</td><td>'+badge(h.PowerSupply)+'</td><td>'+h.Ports+'</td>';
  }
  var rowsH = D.HealthRows.map(function(h){
    return '<tr>'+healthRowCells(h)+'</tr>';
  }).join('');
  document.getElementById('tbodyHealth').innerHTML = rowsH || '<tr><td colspan="14" style="text-align:center;color:#999">No health metrics returned</td></tr>';
  populateColFilters('tblHealth',[1,2,3,11,12]);

  var deviatingHostList = D.Deviating.map(function(d){return d.Hostname;});
  var deviatingRows = D.HealthRows.filter(function(h){ return deviatingHostList.indexOf(h.Hostname)>=0; });
  var rowsDev = deviatingRows.map(function(h){
    var reasons = D.Deviating.filter(function(d){ return d.Hostname===h.Hostname; })
                    .map(function(d){ return d.CheckName+': '+d.CurrentValue+' (baseline '+d.Threshold+')'; })
                    .join('<br>');
    return '<tr>'+healthRowCells(h)+'<td>'+reasons+'</td></tr>';
  }).join('');
  document.getElementById('tbodyDeviating').innerHTML = rowsDev || '<tr><td colspan="15" style="text-align:center;color:#999">No deviating devices</td></tr>';
  populateColFilters('tblDeviating',[1,2,3,11,12]);

  function fwTable(firewalls){
    var rows = firewalls.map(function(f){
      var pluginsTxt = (f.Plugins||[]).map(function(p){ return p.Name+': '+p.Status; }).join(', ') || 'n/a';
      return '<tr>' +
        '<td><b>'+f.Firewall+'</b></td>' +
        '<td>'+badge(f.Mode)+'</td>' +
        '<td>'+badge(f.LocalState)+'</td>' +
        '<td>'+badge(f.PeerState)+'</td>' +
        '<td>'+badge(f.ConfigSync)+'</td>' +
        '<td>'+badge(f.AppVersion)+'</td>' +
        '<td>'+badge(f.ThreatVersion)+'</td>' +
        '<td>'+badge(f.AntivirusVersion)+'</td>' +
        '<td>'+badge(f.PanOsVersion)+'</td>' +
        '<td>'+badge(f.GlobalProtectVersion)+'</td>' +
        '<td>'+badge(f.HA1)+'</td>' +
        '<td>'+badge(f.HA1Backup)+'</td>' +
        '<td>'+badge(f.HA2)+'</td>' +
        '<td>'+badge(f.HA2Backup)+'</td>' +
        '<td>'+pluginsTxt+'</td>' +
        '<td>'+f.MgmtCpuPct+'%</td>' +
        '<td>'+f.DataPlaneCpuPct+'%</td>' +
        '<td>'+f.SessionCount+(f.SessionMax? ' / '+f.SessionMax : '')+'</td>' +
        '<td>'+f.PortsUp+'/'+f.PortsTotal+'</td>' +
      '</tr>';
    }).join('');
    return '<div class="tbl-scroll"><table><thead><tr>' +
      '<th>Firewall</th><th>Mode</th><th>Local</th><th>Peer</th><th>Cfg Sync</th>' +
      '<th>App</th><th>Threat</th><th>AV</th><th>PAN-OS</th><th>GlobalProtect</th>' +
      '<th>HA1</th><th>HA1 Backup</th><th>HA2</th><th>HA2 Backup</th><th>Plugins</th>' +
      '<th>Mgmt CPU</th><th>Data Plane CPU</th><th>Sessions</th><th>Ports</th>' +
      '</tr></thead><tbody>' +
      (rows || '<tr><td colspan="19" style="text-align:center;color:#999">No firewall data returned</td></tr>') +
      '</tbody></table></div>';
  }
  function tsTable(rows){
    var body = rows.map(function(a){
      return '<tr><td>'+a.Name+'</td><td>'+(a.Enabled? '&#10004;':'&#10005;')+'</td><td>'+a.Host+'</td><td>'+a.Port+'</td>'+
             '<td>'+badge(a.Connected? 'CONNECTED':'DISCONNECTED')+'</td></tr>';
    }).join('');
    return '<div class="ts-wrap"><table><thead><tr><th>Name</th><th>Enabled</th><th>Host</th><th>Port</th><th>Connected</th></tr></thead>'+
           '<tbody>'+(body || '<tr><td colspan="5" style="text-align:center;color:#999">No TS agents returned</td></tr>')+'</tbody></table></div>';
  }
  var siteHtml = D.Sites.map(function(s){
    return '<div class="site-card"><h4>'+s.Site+' &mdash; '+s.Firewalls.length+' Firewall(s), '+s.TsAgents.length+' Terminal Server Agent(s)</h4>'+
           '<div class="site-sub-lbl">Firewall HA &amp; Version Status</div>' + fwTable(s.Firewalls) +
           '<div class="site-sub-lbl">Terminal Server Agents</div>' + tsTable(s.TsAgents) + '</div>';
  }).join('');
  document.getElementById('siteGrid').innerHTML = siteHtml;
}
document.addEventListener('DOMContentLoaded', renderReport);
</script>
</body>
</html>
'@
}

#endregion HTML TEMPLATE


#region SAVE REPORT

function Save-Report {
    param(
        [Parameter(Mandatory)]$PanoramaHA,
        [Parameter(Mandatory)]$PanoramaResources,
        [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Devices,
        [Parameter(Mandatory)]$HealthSummary,
        [Parameter(Mandatory)][System.Collections.Generic.List[object]]$HealthRows,
        [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Deviating,
        [Parameter(Mandatory)][array]$SiteResults
    )

    try {
        if (-not (Test-Path $OutputDir)) {
            New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
            Write-Log "Output folder created: $OutputDir" "SUCCESS"
        }
    } catch {
        Write-Log "FATAL: Could not create output folder '$OutputDir' -- $($_.Exception.Message)" "ERROR"
        return $null
    }

    $cDT        = Get-Date -Format "yyyyMMdd_HHmmss"
    $OutputFile = Join-Path $OutputDir "CitrixFirewallHADashboard_${cDT}.html"
    $GenDate    = Get-Date -Format "dddd, dd MMMM yyyy HH:mm:ss"

    $devicesJson = '[' + (
        @($Devices | ForEach-Object {
            '{"Hostname":"'         + (EscapeJson $_.Hostname)         + '",' +
            '"VirtualSystem":"'     + (EscapeJson $_.VirtualSystem)    + '",' +
            '"Model":"'             + (EscapeJson $_.Model)            + '",' +
            '"ConfigSize":"'        + (EscapeJson $_.ConfigSize)       + '",' +
            '"Tags":"'              + (EscapeJson $_.Tags)             + '",' +
            '"CellularFirmware":"'  + (EscapeJson $_.CellularFirmware) + '",' +
            '"Serial":"'            + (EscapeJson $_.Serial)           + '",' +
            '"IPv4":"'              + (EscapeJson $_.IPv4)             + '",' +
            '"IPv6":"'              + (EscapeJson $_.IPv6)             + '",' +
            '"ClusterState":"'      + (EscapeJson $_.ClusterState)     + '",' +
            '"Template":"'          + (EscapeJson $_.Template)         + '",' +
            '"DeviceState":"'       + (EscapeJson $_.DeviceState)      + '",' +
            '"DeviceCert":"'        + (EscapeJson $_.DeviceCert)       + '",' +
            '"DeviceCertExpiry":"'  + (EscapeJson $_.DeviceCertExpiry) + '",' +
            '"SharedPolicy":"'      + (EscapeJson $_.SharedPolicy)     + '",' +
            '"SwVersion":"'         + (EscapeJson $_.SwVersion)        + '",' +
            '"Connected":"'         + (EscapeJson $_.Connected)        + '",' +
            '"HAState":"'           + (EscapeJson $_.HAState)          + '"}'
        }) -join ','
    ) + ']'

    $healthRowsJson = '[' + (
        @($HealthRows | ForEach-Object {
            '{"Hostname":"'        + (EscapeJson $_.Hostname)     + '",' +
            '"Model":"'            + (EscapeJson $_.Model)        + '",' +
            '"ClusterState":"'     + (EscapeJson $_.ClusterState) + '",' +
            '"HAPairStatus":"'     + (EscapeJson $_.HAPairStatus) + '",' +
            '"ThroughputKbps":'    + $_.ThroughputKbps            + ',' +
            '"CPS":'               + $_.CPS                       + ',' +
            '"SessionCount":'      + $_.SessionCount              + ',' +
            '"DataPlaneCpuPct":'   + $_.DataPlaneCpuPct           + ',' +
            '"MgmtCpuPct":'        + $_.MgmtCpuPct                + ',' +
            '"MgmtMemPct":'        + $_.MgmtMemPct                + ',' +
            '"LoggingRate":"'      + (EscapeJson "$($_.LoggingRate)") + '",' +
            '"Fans":"'             + (EscapeJson $_.Fans)         + '",' +
            '"PowerSupply":"'      + (EscapeJson $_.PowerSupply)  + '",' +
            '"Ports":"'            + (EscapeJson $_.Ports)        + '"}'
        }) -join ','
    ) + ']'

    $deviatingJson = '[' + (
        @($Deviating | ForEach-Object {
            '{"Hostname":"'      + (EscapeJson $_.Hostname)      + '",' +
            '"CheckName":"'      + (EscapeJson $_.CheckName)     + '",' +
            '"CurrentValue":"'   + (EscapeJson "$($_.CurrentValue)") + '",' +
            '"Threshold":"'      + (EscapeJson "$($_.Threshold)")    + '",' +
            '"Status":"'         + (EscapeJson $_.Status)        + '",' +
            '"Details":"'        + (EscapeJson $_.Details)       + '"}'
        }) -join ','
    ) + ']'

    $sitesJson = '[' + (
        @($SiteResults | ForEach-Object {
            $fwJson = '[' + (@($_.Firewalls | ForEach-Object {
                $pluginsJson = '[' + (@($_.Plugins | ForEach-Object {
                    '{"Name":"' + (EscapeJson $_.Name) + '","Status":"' + (EscapeJson $_.Status) + '"}'
                }) -join ',') + ']'
                '{"Firewall":"'            + (EscapeJson $_.Firewall)             + '",' +
                '"Mode":"'                 + (EscapeJson $_.Mode)                 + '",' +
                '"LocalState":"'           + (EscapeJson $_.LocalState)           + '",' +
                '"PeerState":"'            + (EscapeJson $_.PeerState)            + '",' +
                '"PeerIP":"'               + (EscapeJson $_.PeerIP)               + '",' +
                '"ConfigSync":"'           + (EscapeJson $_.ConfigSync)           + '",' +
                '"AppVersion":"'           + (EscapeJson $_.AppVersion)           + '",' +
                '"ThreatVersion":"'        + (EscapeJson $_.ThreatVersion)        + '",' +
                '"AntivirusVersion":"'     + (EscapeJson $_.AntivirusVersion)     + '",' +
                '"PanOsVersion":"'         + (EscapeJson $_.PanOsVersion)         + '",' +
                '"GlobalProtectVersion":"' + (EscapeJson $_.GlobalProtectVersion) + '",' +
                '"HA1":"'                  + (EscapeJson $_.HA1)                  + '",' +
                '"HA1Backup":"'            + (EscapeJson $_.HA1Backup)            + '",' +
                '"HA2":"'                  + (EscapeJson $_.HA2)                  + '",' +
                '"HA2Backup":"'            + (EscapeJson $_.HA2Backup)            + '",' +
                '"Plugins":'               + $pluginsJson                        + ',' +
                '"MgmtCpuPct":'            + $_.MgmtCpuPct                        + ',' +
                '"DataPlaneCpuPct":'       + $_.DataPlaneCpuPct                   + ',' +
                '"SessionCount":'          + $_.SessionCount                      + ',' +
                '"SessionMax":'            + $_.SessionMax                        + ',' +
                '"PortsUp":'               + $_.PortsUp                           + ',' +
                '"PortsTotal":'            + $_.PortsTotal                        + '}'
            }) -join ',') + ']'
            $tsJson = '[' + (@($_.TsAgents | ForEach-Object {
                '{"Name":"'     + (EscapeJson $_.Name)                            + '",' +
                '"Enabled":'    + $(if($_.Enabled){'true'}else{'false'})          + ',' +
                '"Host":"'      + (EscapeJson $_.Host)                            + '",' +
                '"Port":"'      + (EscapeJson $_.Port)                            + '",' +
                '"Connected":'  + $(if($_.Connected){'true'}else{'false'})        + '}'
            }) -join ',') + ']'
            '{"Site":"' + (EscapeJson $_.Site) + '","Firewalls":' + $fwJson + ',"TsAgents":' + $tsJson + '}'
        }) -join ','
    ) + ']'

    $JsonBlock = @"
<script>
window.REPORT_DATA = {
  "GenDate"   : "$(EscapeJson $GenDate)",
  "Panorama"  : {
    "HA": {
      "Enabled"    : $(if($PanoramaHA.Enabled){'true'}else{'false'}),
      "LocalState" : "$(EscapeJson $PanoramaHA.LocalState)",
      "PeerState"  : "$(EscapeJson $PanoramaHA.PeerState)",
      "Mode"       : "$(EscapeJson $PanoramaHA.Mode)",
      "ConfigSync" : "$(EscapeJson $PanoramaHA.ConfigSync)"
    },
    "Resources": {
      "CpuPct" : $($PanoramaResources.CpuPct),
      "MemPct" : $($PanoramaResources.MemPct),
      "State"  : "$(EscapeJson $PanoramaResources.State)"
    }
  },
  "Devices"    : $devicesJson,
  "HealthRows" : $healthRowsJson,
  "HealthAll"  : {
    "TotalDevices" : $($HealthSummary.TotalDevices),
    "Healthy"      : $($HealthSummary.Healthy),
    "Deviating"    : $($HealthSummary.Deviating),
    "Disconnected" : $($HealthSummary.Disconnected)
  },
  "Deviating" : $deviatingJson,
  "Sites"     : $sitesJson
};
</script>
"@

    try {
        $Html = Get-UnifiedTemplate
        $Html.Replace('</body>', $JsonBlock + "`n</body>") |
            Out-File -FilePath $OutputFile -Encoding UTF8 -ErrorAction Stop
        Write-Log "Dashboard report saved: $OutputFile" "SUCCESS"

        # Embed raw HTML into the job's stdout output, same convention as VCLite/RDS scripts,
        # for HPSA/Camunda capture when other users lack filesystem access to this host.
        try {
            Write-Output ""
            Write-Output "===== HTML_REPORT_START : $(Split-Path $OutputFile -Leaf) ====="
            Get-Content -Path $OutputFile -Raw | Write-Output
            Write-Output "===== HTML_REPORT_END : $(Split-Path $OutputFile -Leaf) ====="
        } catch {
            Write-Log "Could not embed $OutputFile into job output: $($_.Exception.Message)" "WARN"
        }
        return $OutputFile
    } catch {
        Write-Log "FATAL: Report could not be saved -- $($_.Exception.Message)" "ERROR"
        Write-Log "  Stack: $($_.ScriptStackTrace)" "ERROR"
        return $null
    }
}

#endregion SAVE REPORT


#region MAIN

try {
    Write-Log "=================================================================" "STEP"
    Write-Log "  Citrix Firewall HA & Health Dashboard | Citrix Workspace Automation Suite" "STEP"
    Write-Log "  $ScriptVersion" "STEP"
    Write-Log "=================================================================" "STEP"

    try {
        if (-not (Test-Path $OutputDir)) { New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null }
    } catch {
        throw "Could not create/access output folder '$OutputDir' -- check permissions. Original error: $($_.Exception.Message)"
    }
    Write-Log "Output folder: $OutputDir" "INFO"

    try {
        $probe = Test-NetConnection -ComputerName $Panorama.Host -Port 443 -WarningAction SilentlyContinue
        if (-not $probe.TcpTestSucceeded) {
            throw "TCP 443 to $($Panorama.Host) did not succeed from this host ($env:COMPUTERNAME) -- check firewall rules between this Citrix server and Panorama's management network."
        }
        Write-Log "Network reachability to Panorama ($($Panorama.Host):443) confirmed from $env:COMPUTERNAME." "SUCCESS"
    } catch {
        throw "Preflight network check failed -- $($_.Exception.Message)"
    }
    Write-Log "All preflight checks passed." "SUCCESS"

    # ---- [1/4] Authenticate to Panorama --------------------------------------
    Write-Log "[1/4] Authenticating with Panorama..." "STEP"
    if ([string]::IsNullOrWhiteSpace($Panorama.ApiKey)) {
        if ([string]::IsNullOrWhiteSpace($Panorama.Password)) {
            throw "No Panorama ApiKey or Password supplied -- populate `$Panorama.ApiKey or `$Panorama.Password."
        }
        $Panorama.ApiKey = Get-PanApiKey -DeviceHost $Panorama.Host -User $Panorama.User -Password $Panorama.Password
    }
    Write-Log "Panorama API key acquired." "SUCCESS"

    # ---- [2/4] Panorama HA / CPU / Devices / Health --------------------------
    Write-Log "[2/4] Querying Panorama HA, resources, device summary and per-device health metrics..." "STEP"
    $panoramaHA        = Get-PanoramaHA        -DeviceHost $Panorama.Host -ApiKey $Panorama.ApiKey
    $panoramaResources = Get-PanoramaResources -DeviceHost $Panorama.Host -ApiKey $Panorama.ApiKey
    $devices           = Get-DeviceSummary     -DeviceHost $Panorama.Host -ApiKey $Panorama.ApiKey

    $healthRows = [System.Collections.Generic.List[object]]::new()
    $deviating  = [System.Collections.Generic.List[object]]::new()
    foreach ($dev in $devices) {
        try {
            $row = Get-DeviceHealthMetrics -PanoramaHost $Panorama.Host -ApiKey $Panorama.ApiKey `
                                            -Serial $dev.Serial -Hostname $dev.Hostname -Model $dev.Model `
                                            -ClusterState $dev.ClusterState -HAPairStatus $dev.HAState
            $healthRows.Add($row)
            foreach ($b in (Test-DeviceDeviation -Row $row)) { $deviating.Add($b) }
        } catch {
            Write-Log "  Health metrics failed for [$($dev.Hostname)] -- skipping this device. $($_.Exception.Message)" "ERROR"
        }
    }
    $disconnectedCount = @($devices | Where-Object { $_.Connected -ne "yes" }).Count
    $deviatingHosts    = @($deviating.Hostname | Select-Object -Unique)
    $healthSummary = [pscustomobject]@{
        TotalDevices = $devices.Count
        Disconnected = $disconnectedCount
        Deviating    = $deviatingHosts.Count
        Healthy      = [math]::Max(0, $devices.Count - $disconnectedCount - $deviatingHosts.Count)
    }
    Write-Log ("  HA: {0}/{1} | CPU: {2}% | Devices: {3} | Healthy: {4} | Deviating: {5}" -f `
        $panoramaHA.LocalState, $panoramaHA.PeerState, $panoramaResources.CpuPct, $devices.Count, `
        $healthSummary.Healthy, $healthSummary.Deviating) "SUCCESS"

    # ---- [3/4] Per-site PA Firewall HA + Terminal Server Agent ---------------
    Write-Log "[3/4] Discovering sites (device groups) and querying firewall HA + Terminal Server Agents..." "STEP"
    $Sites = Get-SiteGroups -DeviceHost $Panorama.Host -ApiKey $Panorama.ApiKey
    if ($Sites.Count -eq 0) {
        Write-Log "  No device groups discovered -- site section of the report will be empty. Check `$OpCmd.DeviceGroups for your PAN-OS version." "WARN"
    } else {
        Write-Log "  Discovered $($Sites.Count) site(s): $($Sites.Site -join ', ')" "SUCCESS"
    }

    $siteResults = foreach ($site in $Sites) {
        try {
            Write-Log "  --- [$($site.Site)] Starting ---" "INFO"
            $fwResults = foreach ($fw in $site.Firewalls) {
                $key = if ($FirewallApiKeys.ContainsKey($fw)) { $FirewallApiKeys[$fw] } else { $Panorama.ApiKey }
                Get-FirewallDetail -Site $site.Site -DeviceHost $fw -ApiKey $key
            }

            # Query the Terminal Server Agent list from whichever firewall in this site is
            # actually active right now (falls back to the first member if HA state is unknown) --
            # no manually-configured TsAgentHost needed.
            $tsHost = ($fwResults | Where-Object { $_.LocalState -eq "active" } | Select-Object -First 1).Firewall
            if (-not $tsHost) { $tsHost = $site.Firewalls | Select-Object -First 1 }

            $tsKey  = if ($FirewallApiKeys.ContainsKey($tsHost)) { $FirewallApiKeys[$tsHost] } else { $Panorama.ApiKey }
            $tsRows = Get-TsAgents -Site $site.Site -DeviceHost $tsHost -ApiKey $tsKey
            $tsConnectedCount = @($tsRows | Where-Object { $_.Connected }).Count
            Write-Log ("  [{0}] Firewalls: {1} | TS-Agent host: {2} | TS-Agents: {3}/{4} connected" -f `
                $site.Site, ($fwResults.LocalState -join '/'), $tsHost, $tsConnectedCount, $tsRows.Count) "SUCCESS"
            Write-Log "  --- [$($site.Site)] Complete ---" "INFO"
            [pscustomobject]@{ Site = $site.Site; Firewalls = @($fwResults); TsAgents = @($tsRows) }
        } catch {
            Write-Log "  [$($site.Site)] Site processing failed -- skipping this site. $($_.Exception.Message)" "ERROR"
            [pscustomobject]@{ Site = $site.Site; Firewalls = @(); TsAgents = @() }
        }
    }

    # ---- [4/4] Build & save dashboard -----------------------------------------
    Write-Log "[4/4] Generating HTML dashboard..." "STEP"
    $reportFile = Save-Report -PanoramaHA $panoramaHA -PanoramaResources $panoramaResources `
                               -Devices $devices -HealthSummary $healthSummary -HealthRows $healthRows `
                               -Deviating $deviating -SiteResults $siteResults

    Write-Log "=================================================================" "SUCCESS"
    Write-Log "  DASHBOARD COMPLETE" "SUCCESS"
    Write-Log "=================================================================" "SUCCESS"
    if ($reportFile) { Write-Log "HTML File : $reportFile" "SUCCESS" }
    Write-Output "Script Completed: $(Get-Date -Format 'yyyyMMdd_HHmmss')"

} catch {
    Write-Log "FATAL: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack: $($_.ScriptStackTrace)" "ERROR"
    exit 1
}

#endregion MAIN
