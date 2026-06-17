############################################################################################################
# Script Name : UC3_RDSLicenseMonitoring.ps1
# Description : RDS License Usage Monitoring | Citrix Workspace Automation Suite
#               Queries RDS License Server via WMI/CIM, collects session host metrics via WinRM,
#               generates a self-contained HTML report, emits HPSA Base64 output for Camunda.
# Architecture: Self-contained single file.
#               HTML template is embedded as a here-string and written to disk on every run.
#               Output HTML is saved to <DeployDir>\Output\ (timestamped).
# HPSA Usage  : powershell.exe -ExecutionPolicy Bypass -File UC3_RDSLicenseMonitoring.ps1 -LicenseServerFQDN rdslicense.corp.com
# ExitCode    : 0=COMPLIANT  1=WARNING  2=CRITICAL
############################################################################################################

param(
    [Parameter(Mandatory = $true)]
    [string]$LicenseServerFQDN        # e.g. rdslicense.corp.com  -- passed from HPSA job step
)

$ErrorActionPreference = "Continue"
# NOTE: "SilentlyContinue" was previously used here, which suppressed every
# error in the script - including file write failures, WMI failures, and
# JSON build failures - with no visible trace. "Continue" lets errors print
# to the console while still allowing the script to proceed. Each risky
# operation below uses its own try/catch with -ErrorAction Stop so failures
# are handled explicitly and logged, rather than disappearing silently.

# HPSA copies the PS1 to C:\Windows\TEMP at runtime so
# $MyInvocation.MyCommand.Path points to TEMP - not the deploy folder.
# Always use $DeployDir so output goes to the correct location.
# Edit $DeployDir to match where this PS1 is deployed on the server.
$DeployDir = "C:\Scripts\RDL\"
$ScriptDir = $DeployDir

# ============================================================================
# SECTION 1 - SETTINGS  (edit this block)
# ============================================================================
$WarningThresholdPct  = 80
$CriticalThresholdPct = 95

# ============================================================================

# ============================================================================
# UTILITY FUNCTIONS
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

function EscapeJson {
    param([string]$s)
    if ($null -eq $s) { return "" }
    return $s -replace '\\','\\' -replace '"','\"' -replace "`r`n",'\n' -replace "`n",'\n' -replace "`t",'\t'
}

# ============================================================================
# EMBEDDED HTML TEMPLATE
# Written to disk on every run so fixes always take effect immediately.
# ============================================================================
function Get-EmbeddedTemplate {
    return @'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8"/>
    <meta name="viewport" content="width=device-width,initial-scale=1.0"/>
    <title>RDS License Usage Monitoring | Citrix Workspace Automation Suite</title>
    <style>
        /* UC3 - RDS License Usage Monitoring */
        :root {
            --brand       : rgba(216,0,116,1);
            --brand-dark  : rgba(160,0,85,1);
            --brand-ultra : rgba(216,0,116,0.04);
            --ok          : #0A7A09;   --ok-bg   : #F0FBF0;
            --warn        : #B05E00;   --warn-bg : #FFF8EC;
            --err         : #BF0E1A;   --err-bg  : #FFF3F4;
            --text-h      : #111318;
            --text-b      : #2C2C3A;
            --text-m      : #5A5A6E;
            --text-l      : #8A8A9A;
            --line        : #EBEBF0;
            --font        : 'Segoe UI','Helvetica Neue',Arial,sans-serif;
            --mono        : 'Cascadia Code','Consolas','Courier New',monospace;
            --max-w       : 1380px;
            --r           : 12px;
            --r-sm        : 8px;
            --sh          : 0 1px 8px rgba(0,0,0,.06),0 2px 20px rgba(0,0,0,.04);
            --sh-lg       : 0 4px 24px rgba(0,0,0,.10);
        }
        *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
        html { scroll-behavior: smooth; }
        body { font-family: var(--font); font-size: 13.5px; background: #EEF0F4; color: var(--text-b); line-height: 1.6; }
        .rpt-hdr { background: var(--brand); color: #fff; position: relative; overflow: hidden; }
        .rpt-hdr::before {
            content: ''; position: absolute; inset: 0;
            background: repeating-linear-gradient(-45deg,rgba(255,255,255,0) 0px,rgba(255,255,255,0) 18px,rgba(255,255,255,.025) 18px,rgba(255,255,255,.025) 20px);
        }
        .rpt-hdr::after {
            content: ''; position: absolute; bottom: 0; left: 0; right: 0; height: 2px;
            background: linear-gradient(90deg,rgba(255,255,255,.5),transparent 50%,rgba(255,255,255,.5));
        }
        .hdr-inner { position: relative; z-index: 1; padding: 16px 40px 14px; display: flex; align-items: baseline; justify-content: space-between; gap: 16px; flex-wrap: wrap; }
        .hdr-title { font-size: 1.75rem; font-weight: 800; letter-spacing: -.5px; line-height: 1.18; }
        .hdr-gen   { font-size: .75rem; color: rgba(255,255,255,.80); white-space: nowrap; }
        .hdr-strip { position: relative; z-index: 1; display: flex; align-items: center; justify-content: space-between; background: rgba(0,0,0,.18); padding: 9px 42px; font-size: .76rem; color: rgba(255,255,255,.88); gap: 12px; flex-wrap: wrap; }
        .hdr-strip-left { display: flex; align-items: center; gap: 16px; flex-wrap: wrap; }
        .hdr-strip-left span { display: flex; align-items: center; gap: 5px; }
        .hdr-strip-left strong { color: #fff; }
        .status-pill { padding: 4px 16px; border-radius: 20px; font-weight: 800; font-size: .72rem; letter-spacing: .5px; white-space: nowrap; }
        .pill-ok   { background: rgba(10,122,9,.88);  color: #fff; }
        .pill-warn { background: rgba(176,94,0,.88);  color: #fff; }
        .pill-err  { background: rgba(191,14,26,.88); color: #fff; }
        .rpt-body { max-width: var(--max-w); margin: 26px auto; padding: 0 26px 52px; }
        .alert { display: flex; align-items: flex-start; gap: 14px; border-radius: var(--r-sm); padding: 14px 18px; margin-bottom: 16px; border-left: 4px solid; font-size: .85rem; }
        .alert .ico { font-size: 1.15rem; flex-shrink: 0; margin-top: 1px; }
        .alert ul   { margin-top: 6px; padding-left: 16px; }
        .alert li   { margin-top: 3px; }
        .alert-err  { background: var(--err-bg); border-color: var(--err); color: #5A000A; }
        .ov-banner { display: flex; align-items: center; gap: 16px; padding: 14px 20px; border-radius: var(--r); margin-bottom: 16px; background: #fff; box-shadow: var(--sh); border-left: 5px solid currentColor; }
        .ov-badge  { padding: 7px 20px; border-radius: 20px; font-weight: 800; font-size: .85rem; letter-spacing: .3px; white-space: nowrap; color: #fff; }
        .ov-detail strong { font-size: .95rem; }
        .ov-detail .sub   { font-size: .78rem; color: var(--text-m); margin-top: 2px; }
        .card-grid { display: grid; grid-template-columns: repeat(6, 1fr); gap: 8px; margin-bottom: 16px; align-items: stretch; }
        .card { background: #fff; border-radius: var(--r-sm); padding: 10px 12px 9px; box-shadow: var(--sh); border-top: 3px solid var(--brand); position: relative; overflow: hidden; transition: transform .15s, box-shadow .15s; min-width: 0; }
        .card:hover  { transform: translateY(-2px); box-shadow: var(--sh-lg); }
        .card::after { content: attr(data-ico); position: absolute; right: 6px; top: 6px; font-size: 1.3rem; opacity: .07; }
        .card .c-lbl { font-size: .57rem; font-weight: 700; text-transform: uppercase; letter-spacing: .5px; color: var(--text-l); margin-bottom: 3px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .card .c-val { font-size: .82rem; font-weight: 800; color: var(--text-h); line-height: 1.25; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .card .c-sub { font-size: .62rem; color: var(--text-m); margin-top: 2px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

        .sec { background: #fff; border-radius: var(--r); box-shadow: var(--sh); margin-bottom: 14px; overflow: hidden; border: 1px solid rgba(0,0,0,.04); }
        .sec-hdr { display: flex; align-items: center; justify-content: space-between; padding: 11px 18px; background: var(--brand); color: #fff; cursor: pointer; user-select: none; transition: background .18s; }
        .sec-hdr:hover      { background: var(--brand-dark); }
        .sec-hdr-l          { display: flex; align-items: center; gap: 8px; font-weight: 700; font-size: .87rem; }
        .sec-hdr-r          { display: flex; align-items: center; gap: 8px; font-size: .74rem; opacity: .88; }
        .chev               { transition: transform .24s; display: inline-block; font-size: .7rem; }
        .sec-body           { overflow: hidden; }
        .sec-body.collapsed { display: none; }
        .tbl-wrap { overflow-x: auto; }
        table     { width: 100%; border-collapse: collapse; font-size: .79rem; }
        thead th  { background: var(--brand); color: #fff; padding: 9px 12px; text-align: left; font-weight: 600; font-size: .72rem; letter-spacing: .2px; white-space: nowrap; position: sticky; top: 0; z-index: 2; }
        tbody tr            { border-bottom: 1px solid var(--line); transition: background .1s; }
        tbody tr:last-child { border: none; }
        tbody tr:hover      { background: var(--brand-ultra); }
        tbody td            { padding: 8px 12px; vertical-align: middle; }
        .r-ok  td  { background: var(--ok-bg);   }
        .r-warn td { background: var(--warn-bg); }
        .r-err  td { background: var(--err-bg);  }
        .td-name   { font-weight: 700; }
        .td-mono   { font-family: var(--mono); font-size: .74rem; }
        .badge { display: inline-block; padding: 2px 9px; border-radius: 20px; font-size: .67rem; font-weight: 700; letter-spacing: .2px; white-space: nowrap; }
        .b-ok   { background: #D1F2D1; color: #065006; }
        .b-warn { background: #FEF0CC; color: #6B3A00; }
        .b-err  { background: #FDDCDE; color: #7A0010; }
        .pw { display: flex; align-items: center; gap: 8px; }
        .pt { flex: 1; height: 8px; background: #E8E8EE; border-radius: 6px; overflow: hidden; }
        .pf { height: 100%; border-radius: 6px; transition: width .6s ease; }
        .pp { font-weight: 700; font-size: .74rem; min-width: 36px; text-align: right; }
        code { font-family: var(--mono); font-size: .74rem; background: #F2F2F7; padding: 1px 5px; border-radius: 4px; color: #444; word-break: break-all; }

    </style>
    <script>
        function tog(id) {
            var b    = document.getElementById('b-' + id);
            var c    = document.getElementById('chev-' + id);
            var open = !b.classList.contains('collapsed');
            if (open) { b.classList.add('collapsed');    c.style.transform = 'rotate(-90deg)'; }
            else      { b.classList.remove('collapsed'); c.style.transform = 'rotate(0deg)';   }
        }
        document.addEventListener('DOMContentLoaded', function () {
            document.querySelectorAll('.sec-body').forEach(function (b) {
                if (b.querySelectorAll('tbody tr').length > 10) tog(b.id.replace('b-', ''));
            });
        });
    </script>
</head>
<body>

<div class="rpt-hdr">
    <div class="hdr-inner">
        <div class="hdr-title">RDS License Usage Monitoring</div>
        <div class="hdr-gen">&#128336; Generated: <span id="gen-date">-</span></div>
    </div>
    <div class="hdr-strip">
        <div class="hdr-strip-left">
            <span>&#128220; Server: <strong id="lic-server">-</strong></span>
            <span>&#128202; CALs: <strong id="cal-summary">-</strong></span>

        </div>
        <span class="status-pill" id="status-pill">-</span>
    </div>
</div>

<div class="rpt-body">
    <div id="err-section"></div>
    <div class="ov-banner" id="ov-banner">
        <span class="ov-badge" id="ov-badge">-</span>
        <div class="ov-detail">
            <strong id="ov-detail-main">-</strong>
            <div class="sub" id="ov-detail-sub">-</div>
        </div>
    </div>
    <div class="card-grid">
        <div class="card" data-ico="&#128220;"><div class="c-lbl">License Server</div><div class="c-val" id="c-lic-server">-</div><div class="c-sub" id="c-lic-osver">-</div></div>
        <div class="card" data-ico="&#128202;"><div class="c-lbl">Total CALs</div><div class="c-val" id="c-installed">-</div></div>
        <div class="card" data-ico="&#128273;"><div class="c-lbl">CALs In Use</div><div class="c-val" id="c-issued">-</div><div class="c-sub" id="c-issued-sub">-</div></div>
        <div class="card" data-ico="&#9989;"><div class="c-lbl">CALs Available</div><div class="c-val" id="c-available">-</div><div class="c-sub" id="c-headroom">-</div></div>
        <div class="card" data-ico="&#9888;"><div class="c-lbl">Warn Threshold</div><div class="c-val" id="c-warn">-</div><div class="c-sub" id="c-warn-sub">-</div></div>
        <div class="card" data-ico="&#128308;"><div class="c-lbl">Crit Threshold</div><div class="c-val" id="c-crit">-</div><div class="c-sub" id="c-crit-sub">-</div></div>

    </div>

    <div class="sec" id="s-kp">
        <div class="sec-hdr" onclick="tog('kp')">
            <span class="sec-hdr-l">&#128220; RDS License Key Packs</span>
            <span class="sec-hdr-r"><span id="kp-count">-</span> pack(s) <span class="chev" id="chev-kp">&#9660;</span></span>
        </div>
        <div class="sec-body" id="b-kp">
            <div class="tbl-wrap">
                <table>
                    <thead><tr><th>Pack ID</th><th>Description</th><th>Product Version</th><th>Total</th><th>Issued</th><th>Available</th><th>Utilisation</th></tr></thead>
                    <tbody id="kp-tbody"><tr><td colspan="7" style="text-align:center;padding:20px;color:#8A8A9A;">Awaiting data...</td></tr></tbody>
                </table>
            </div>
        </div>
    </div>

</div>

<script>
function renderReport() {
    if (!window.REPORT_DATA) return;
    var d        = window.REPORT_DATA;
    var colorMap = { COMPLIANT: '#0A7A09', WARNING: '#B05E00', CRITICAL: '#BF0E1A' };
    var pillMap  = { COMPLIANT: 'pill-ok', WARNING: 'pill-warn', CRITICAL: 'pill-err' };
    var color    = colorMap[d.Compliance] || '#0A7A09';
    function set(id, val, isHtml) {
        var el = document.getElementById(id); if (!el) return;
        if (isHtml) el.innerHTML = val; else el.textContent = val;
    }
    function setStyled(id, val, style) {
        var el = document.getElementById(id); if (!el) return;
        el.textContent = val; el.style.cssText += style;
    }
    set('gen-date',    d.GenDate);
    set('lic-server',  d.LicenseServerFQDN);
    set('cal-summary', d.Issued + ' / ' + d.Installed + ' (' + d.UsagePct + '%)');

    var pill = document.getElementById('status-pill');
    pill.textContent = d.Compliance + ' - ' + d.UsagePct + '% CAL Utilisation';
    pill.className   = 'status-pill ' + (pillMap[d.Compliance] || 'pill-ok');
    var banner = document.getElementById('ov-banner');
    banner.style.color       = color;
    banner.style.borderColor = color;
    var badge = document.getElementById('ov-badge');
    badge.textContent      = d.Compliance;
    badge.style.background = color;
    set('ov-detail-main', d.Issued + ' of ' + d.Installed + ' CALs in use (' + d.UsagePct + '%) - ' + d.Available + ' remaining');
    set('ov-detail-sub',
        'Warn: <strong>' + d.WarnPctLabel + '</strong> &nbsp;|&nbsp; ' +
        'Critical: <strong>' + d.CritPctLabel + '</strong> &nbsp;|&nbsp; ' +
        '', true);
    set('c-lic-server',  d.LicenseServerFQDN);
    set('c-lic-osver',   d.LicServerOSVersion);
    set('c-installed',   d.Installed);
    setStyled('c-issued', d.Issued, 'color:' + color + ';');
    set('c-issued-sub',  d.UsagePct + '% utilisation');
    set('c-available',   d.Available);
    set('c-headroom',    d.HeadroomPct + '% headroom');
    set('c-warn',        d.WarnPctLabel);
    set('c-warn-sub',    d.WarnCardSub);
    set('c-crit',        d.CritPctLabel);
    set('c-crit-sub',    d.CritCardSub);

    if (d.Errors && d.Errors.length > 0) {
        var li = d.Errors.map(function(e){ return '<li>' + e + '</li>'; }).join('');
        document.getElementById('err-section').innerHTML =
            "<div class='alert alert-err'><div class='ico'>&#9888;</div>" +
            "<div><strong>" + d.Errors.length + " error(s) during execution</strong><ul>" + li + "</ul></div></div>";
    }
    set('kp-count', d.KeyPacks.length);
    var kpBody = '';
    d.KeyPacks.forEach(function (kp) {
        if (kp.IsUnlimited) {
            kpBody +=
                "<tr class='r-ok'>" +
                "<td><code>" + kp.KeyPackId + "</code></td>" +
                "<td>" + kp.Description + "</td>" +
                "<td>" + kp.ProductVersion + "</td>" +
                "<td style='text-align:center;font-weight:700;' colspan='4'>" +
                "<span class='badge b-ok'>Unlimited - excluded from totals</span></td>" +
                "</tr>";
            return;
        }
        var pct    = kp.TotalLicenses > 0 ? Math.round((kp.IssuedLicenses / kp.TotalLicenses) * 1000) / 10 : 0;
        var col    = pct >= d.CritThresholdPct ? '#BF0E1A' : pct >= d.WarnThresholdPct ? '#B05E00' : '#0A7A09';
        var rowCls = pct >= d.CritThresholdPct ? 'r-err'   : pct >= d.WarnThresholdPct ? 'r-warn'  : 'r-ok';
        kpBody +=
            "<tr class='" + rowCls + "'>" +
            "<td><code>" + kp.KeyPackId + "</code></td>" +
            "<td>" + kp.Description + "</td>" +
            "<td>" + kp.ProductVersion + "</td>" +
            "<td style='text-align:center;font-weight:700;'>" + kp.TotalLicenses + "</td>" +
            "<td style='text-align:center;font-weight:700;color:" + col + ";'>" + kp.IssuedLicenses + "</td>" +
            "<td style='text-align:center;'>" + kp.AvailableLicenses + "</td>" +
            "<td><div class='pw'><div class='pt'><div class='pf' style='width:" + Math.min(pct,100) + "%;background:" + col + ";'></div></div>" +
            "<div class='pp' style='color:" + col + ";'>" + pct + "%</div></div></td>" +
            "</tr>";
    });
    document.getElementById('kp-tbody').innerHTML = kpBody ||
        "<tr><td colspan='7' style='text-align:center;padding:20px;color:#8A8A9A;'>No key pack data available</td></tr>";
}
</script>
</body>
</html>
'@
}

# ============================================================================
# INITIALISATION
# ============================================================================
$ScriptStartTime = Get-Date

$ErrorLog    = [System.Collections.Generic.List[string]]::new()
$KeyPacks    = @()
$Issued      = 0
$Available   = 0
$Installed   = 0

Write-Log "=== UC3 RDS License Monitoring | Citrix Workspace Automation Suite ==="
Write-Log "License Server: $LicenseServerFQDN"

# ============================================================================
# ENSURE OUTPUT FOLDER EXISTS
# ============================================================================
$cDT            = Get-Date -Format "yyyyMMdd_HHmmss"
$OutputDir      = $ScriptDir + "Output\"
$htmlOutputFile = $OutputDir + "UC3_RDSLicenseMonitoring_$cDT.html"

try {
    if (-not (Test-Path $OutputDir)) {
        New-Item -Path $OutputDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        Write-Log "Output folder created: $OutputDir" "SUCCESS"
    }
} catch {
    Write-Log "FATAL: Could not create output folder [$OutputDir]: $($_.Exception.Message)" "ERROR"
    exit 3
}

# ============================================================================
# ALWAYS WRITE FRESH HTML TEMPLATE
# ============================================================================
$TemplatePath = $ScriptDir + "UC3_RDSLicenseMonitoring_Report.html"
try {
    $embeddedHtml = Get-EmbeddedTemplate
    [System.IO.File]::WriteAllText($TemplatePath, $embeddedHtml, [System.Text.Encoding]::UTF8)
    Write-Log "HTML template written: $TemplatePath" "SUCCESS"
} catch {
    Write-Log "FATAL: Could not write HTML template [$TemplatePath]: $($_.Exception.Message)" "ERROR"
    exit 3
}

# ============================================================================
# QUERY RDS LICENSE SERVER
# ============================================================================
Write-Log "Querying license server via WMI: $LicenseServerFQDN"
try {
    $KeyPacks = @(Get-WmiObject -Class "Win32_TSLicenseKeyPack" -ComputerName $LicenseServerFQDN -ErrorAction Stop)
    Write-Log "WMI query OK - $($KeyPacks.Count) key pack(s) returned" "SUCCESS"
} catch {
    Write-Log "WMI failed ($($_.Exception.Message)), retrying via CIM..." "WARN"
    try {
        $cimOpts  = New-CimSessionOption -Protocol Dcom
        $cimSess  = New-CimSession -ComputerName $LicenseServerFQDN -SessionOption $cimOpts -ErrorAction Stop
        $KeyPacks = @(Get-CimInstance -CimSession $cimSess -ClassName "Win32_TSLicenseKeyPack" -ErrorAction Stop)
        Remove-CimSession $cimSess
        Write-Log "CIM query OK - $($KeyPacks.Count) key pack(s) returned" "SUCCESS"
    } catch {
        $ErrorLog.Add("License server [$LicenseServerFQDN] unreachable: $($_.Exception.Message)")
        Write-Log "License server unreachable. CAL counts will show 0." "ERROR"
    }
}

# Windows version of the license server - shown on the License Server card
$LicServerOSVersion = "N/A"
try {
    $osInfo = Get-WmiObject -Class "Win32_OperatingSystem" -ComputerName $LicenseServerFQDN -ErrorAction Stop
    $LicServerOSVersion = "$($osInfo.Caption)".Trim()
} catch {
    try {
        $osInfo = Get-CimInstance -ClassName "Win32_OperatingSystem" -ComputerName $LicenseServerFQDN -ErrorAction Stop
        $LicServerOSVersion = "$($osInfo.Caption)".Trim()
    } catch {
        Write-Log "Could not retrieve OS version for $LicenseServerFQDN" "WARN"
    }
}

# Win32_TSLicenseKeyPack reports TotalLicenses = -1 (shown as the unsigned
# value 4294967295 by some providers) for "unlimited" key packs - e.g.
# built-in or temporary packs that are not capacity-limited. Summing this
# value directly produces grossly inflated totals (the bug seen in the
# report: Installed showing in the billions). Unlimited packs are excluded
# from the numeric totals and flagged separately so the dashboard reflects
# only real, finite capacity.
try {
    $UnlimitedPackCount = 0
    $FinitePacks = @($KeyPacks | Where-Object {
        $tl = [int64]$_.TotalLicenses
        if ($tl -eq -1 -or $tl -eq 4294967295) {
            $script:UnlimitedPackCount++
            return $false
        }
        return $true
    })

    $Issued    = if ($FinitePacks.Count -gt 0) { ($FinitePacks | Measure-Object IssuedLicenses    -Sum).Sum } else { 0 }
    $Available = if ($FinitePacks.Count -gt 0) { ($FinitePacks | Measure-Object AvailableLicenses -Sum).Sum } else { 0 }
    $Installed = if ($FinitePacks.Count -gt 0) { ($FinitePacks | Measure-Object TotalLicenses     -Sum).Sum } else { 0 }

    if ($UnlimitedPackCount -gt 0) {
        Write-Log "$UnlimitedPackCount unlimited key pack(s) excluded from totals (not capacity-limited)" "WARN"
    }
    Write-Log "Installed: $Installed | Issued: $Issued | Available: $Available (from $($FinitePacks.Count) finite pack(s))" "SUCCESS"
} catch {
    Write-Log "Error calculating CAL totals: $($_.Exception.Message)" "ERROR"
    $ErrorLog.Add("CAL calculation failed: $($_.Exception.Message)")
    $Issued = 0; $Available = 0; $Installed = 0
}

$UsagePct   = if ($Installed -gt 0) { [math]::Round(($Issued / $Installed) * 100, 1) } else { 0 }
$Compliance = if     ($UsagePct -ge $CriticalThresholdPct) { "CRITICAL"  }
              elseif ($UsagePct -ge $WarningThresholdPct)  { "WARNING"   }
              else                                          { "COMPLIANT" }
Write-Log "CAL Usage: $Issued / $Installed = $UsagePct% => $Compliance"

# ============================================================================
# COMPUTED VARIABLES
# ============================================================================
try {
    $GenDate      = Get-Date -Format "dddd, dd MMMM yyyy HH:mm:ss"
    $WarnPctLabel = "$WarningThresholdPct%"
    $CritPctLabel = "$CriticalThresholdPct%"
    $HeadroomPct  = if ($Installed -gt 0) { [math]::Round(($Available / $Installed) * 100, 1) } else { 0 }
    $WarnCardSub  = if ($UsagePct -ge $WarningThresholdPct)  { "BREACHED" } else { "Not reached" }
    $CritCardSub  = if ($UsagePct -ge $CriticalThresholdPct) { "BREACHED" } else { "Not reached" }
} catch {
    Write-Log "Error computing derived values: $($_.Exception.Message)" "ERROR"
    $GenDate      = Get-Date -Format "dddd, dd MMMM yyyy HH:mm:ss"
    $WarnPctLabel = "$WarningThresholdPct%"
    $CritPctLabel = "$CriticalThresholdPct%"
    $HeadroomPct  = 0
    $WarnCardSub  = "Unknown"
    $CritCardSub  = "Unknown"
}

# ============================================================================
# BUILD JSON DATA BLOCK
# ============================================================================
try {
    $kpJsonItems = $KeyPacks | ForEach-Object {
        $tl          = [int64]$_.TotalLicenses
        $isUnlimited = ($tl -eq -1 -or $tl -eq 4294967295)
        '{"KeyPackId":"'       + (EscapeJson "$($_.KeyPackId)")      + '",' +
        '"Description":"'      + (EscapeJson "$($_.Description)")    + '",' +
        '"ProductVersion":"'   + (EscapeJson "$($_.ProductVersion)") + '",' +
        '"TotalLicenses":'     + $(if ($isUnlimited) { 0 } else { [int]$tl })                       + ',' +
        '"IssuedLicenses":'    + [int]$_.IssuedLicenses                                              + ',' +
        '"AvailableLicenses":' + $(if ($isUnlimited) { 0 } else { [int]$_.AvailableLicenses })       + ',' +
        '"IsUnlimited":'       + $(if ($isUnlimited) { "true" } else { "false" })                    + '}'
    }
    $kpJson = '[' + ($kpJsonItems -join ',') + ']'

    $errJsonItems = $ErrorLog | ForEach-Object { '"' + (EscapeJson $_) + '"' }
    $errJson      = '[' + ($errJsonItems -join ',') + ']'

    $JsonBlock = @"
<script>
window.REPORT_DATA = {
  "GenDate"           : "$(EscapeJson $GenDate)",
  "LicenseServerFQDN" : "$(EscapeJson $LicenseServerFQDN)",
  "LicServerOSVersion": "$(EscapeJson $LicServerOSVersion)",
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
  "KeyPacks"          : $kpJson,
  "Errors"            : $errJson
};
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", renderReport);
} else {
  renderReport();
}
</script>
"@
    Write-Log "JSON data block built successfully ($($KeyPacks.Count) key pack(s), $($ErrorLog.Count) error(s))" "SUCCESS"
} catch {
    Write-Log "FATAL: Could not build JSON data block: $($_.Exception.Message)" "ERROR"
    exit 3
}

# ============================================================================
# INJECT JSON INTO HTML AND SAVE OUTPUT
# ============================================================================
try {
    Write-Log "Template : $TemplatePath"
    Write-Log "Output   : $htmlOutputFile"

    $HtmlContent = Get-Content -Path $TemplatePath -Raw -Encoding UTF8 -ErrorAction Stop

    # .Replace() is used instead of -replace because -replace is regex-based
    # and JsonBlock contains $ { } \ characters that break regex silently,
    # producing an HTML file with no data injected (REPORT_DATA stays unset).
    $HtmlContent = $HtmlContent.Replace('</body>', ($JsonBlock + "`n</body>"))

    $HtmlContent | Out-File -FilePath $htmlOutputFile -Encoding UTF8 -ErrorAction Stop
    Write-Log "Output report saved: $htmlOutputFile" "SUCCESS"
} catch {
    Write-Log "FATAL: Could not inject data or save output report: $($_.Exception.Message)" "ERROR"
    exit 3
}

Write-Log "=== UC3 Complete | $Compliance ($UsagePct%) ===" "SUCCESS"

if     ($Compliance -eq "CRITICAL") { exit 2 }
elseif ($Compliance -eq "WARNING")  { exit 1 }
else                                 { exit 0 }
