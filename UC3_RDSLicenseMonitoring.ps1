############################################################################################################
# Script Name : UC3_RDSLicenseMonitoring.ps1
# Description : RDS License Usage Monitoring | Citrix Workspace Automation Suite
#               Queries one or more RDS License Servers via WMI/CIM and generates a
#               separate, self-contained HTML report for each server.
# Architecture: Self-contained single file. Each server is processed independently by
#               Invoke-LicenseServerReport - its own variables, its own try/catch blocks,
#               its own output file - so one server failing never affects the others.
#               Output HTML is saved to <DeployDir>\Output\ (one file per server, timestamped).
# HPSA Usage  : powershell.exe -ExecutionPolicy Bypass -File UC3_RDSLicenseMonitoring.ps1 -LicenseServerFQDN rdslicense1.corp.com
#               Multiple servers: separate FQDNs with a semicolon (no spaces required, extra
#               spaces around each entry are trimmed automatically):
#               powershell.exe -ExecutionPolicy Bypass -File UC3_RDSLicenseMonitoring.ps1 -LicenseServerFQDN "rdslicense1.corp.com;rdslicense2.corp.com;rdslicense3.corp.com"
# ExitCode    : 0=all servers processed successfully (regardless of CAL compliance state)
#               3=one or more servers FAILED to process (genuine script/connectivity error,
#                 not a CAL compliance finding - see console log for which server(s) failed)
############################################################################################################

param(
    [Parameter(Mandatory = $true)]
    # One or more license server FQDNs. Separate multiple servers with a semicolon, e.g.
    # "rdslicense1.corp.com;rdslicense2.corp.com". A single server is also valid as-is.
    [string]$LicenseServerFQDN
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
            <span class="sec-hdr-l">&#128220; License Summary</span>
            <span class="sec-hdr-r"><span class="chev" id="chev-kp">&#9660;</span></span>
        </div>
        <div class="sec-body" id="b-kp">
            <div class="tbl-wrap">
                <table>
                    <thead><tr><th>Server Name</th><th>OS Version</th><th>Total</th><th>Issued</th><th>Available</th><th>Utilisation</th></tr></thead>
                    <tbody id="kp-tbody"><tr><td colspan="6" style="text-align:center;padding:20px;color:#8A8A9A;">Awaiting data...</td></tr></tbody>
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
        'Critical: <strong>' + d.CritPctLabel + '</strong>', true);
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

    /* Single summary row for this server. Total/Issued/Available are
       already deduplicated (exact-duplicate and unlimited key packs
       excluded) by the PowerShell calculation, so this row always matches
       the KPI cards above - no per-pack detail is shown here. */
    var pct    = d.Installed > 0 ? Math.round((d.Issued / d.Installed) * 1000) / 10 : 0;
    var rowCol = pct >= d.CritThresholdPct ? '#BF0E1A' : pct >= d.WarnThresholdPct ? '#B05E00' : '#0A7A09';
    var rowCls = pct >= d.CritThresholdPct ? 'r-err'   : pct >= d.WarnThresholdPct ? 'r-warn'  : 'r-ok';
    var kpBody =
        "<tr class='" + rowCls + "'>" +
        "<td class='td-name'>" + d.LicenseServerFQDN + "</td>" +
        "<td>" + d.LicServerOSVersion + "</td>" +
        "<td style='text-align:center;font-weight:700;'>" + d.Installed + "</td>" +
        "<td style='text-align:center;font-weight:700;color:" + rowCol + ";'>" + d.Issued + "</td>" +
        "<td style='text-align:center;'>" + d.Available + "</td>" +
        "<td><div class='pw'><div class='pt'><div class='pf' style='width:" + Math.min(pct,100) + "%;background:" + rowCol + ";'></div></div>" +
        "<div class='pp' style='color:" + rowCol + ";'>" + pct + "%</div></div></td>" +
        "</tr>";
    document.getElementById('kp-tbody').innerHTML = kpBody;
}
</script>
</body>
</html>
'@
}

# ============================================================================
# COMBINED MULTI-SERVER REPORT
# Builds one HTML report listing every server that was processed in this
# run. The table always has exactly one row per server actually supplied
# in -LicenseServerFQDN - it adjusts automatically whether that was one
# server or many, with no fixed/hardcoded row count anywhere in this logic.
# ============================================================================
# ============================================================================
# COMBINED REPORT TEMPLATE
# The table body is built entirely by JavaScript from COMBINED_DATA.Rows,
# so it always renders exactly one row per server that was actually
# processed - no fixed or hardcoded row count anywhere in this template.
# ============================================================================
function Get-CombinedTemplate {
    return @'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8"/>
    <meta name="viewport" content="width=device-width,initial-scale=1.0"/>
    <title>RDS License Usage Monitoring - Combined Summary | Citrix Workspace Automation Suite</title>
    <style>
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
            --max-w       : 1380px;
            --r           : 12px;
            --r-sm        : 8px;
            --sh          : 0 1px 8px rgba(0,0,0,.06),0 2px 20px rgba(0,0,0,.04);
            --sh-lg       : 0 4px 24px rgba(0,0,0,.10);
        }
        *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: var(--font); font-size: 13.5px; background: #EEF0F4; color: var(--text-b); line-height: 1.6; }
        .rpt-hdr { background: var(--brand); color: #fff; position: relative; overflow: hidden; }
        .rpt-hdr::after {
            content: ''; position: absolute; bottom: 0; left: 0; right: 0; height: 2px;
            background: linear-gradient(90deg,rgba(255,255,255,.5),transparent 50%,rgba(255,255,255,.5));
        }
        .hdr-inner { position: relative; z-index: 1; padding: 16px 40px 14px; display: flex; align-items: baseline; justify-content: space-between; gap: 16px; flex-wrap: wrap; }
        .hdr-title { font-size: 1.75rem; font-weight: 800; letter-spacing: -.5px; line-height: 1.18; }
        .hdr-gen   { font-size: .75rem; color: rgba(255,255,255,.80); white-space: nowrap; }
        .hdr-strip { position: relative; z-index: 1; display: flex; align-items: center; justify-content: space-between; background: rgba(0,0,0,.18); padding: 9px 42px; font-size: .76rem; color: rgba(255,255,255,.88); gap: 12px; flex-wrap: wrap; }
        .status-pill { padding: 4px 16px; border-radius: 20px; font-weight: 800; font-size: .72rem; letter-spacing: .5px; white-space: nowrap; }
        .pill-ok   { background: rgba(10,122,9,.88);  color: #fff; }
        .pill-warn { background: rgba(176,94,0,.88);  color: #fff; }
        .pill-err  { background: rgba(191,14,26,.88); color: #fff; }
        .rpt-body { max-width: var(--max-w); margin: 26px auto; padding: 0 26px 52px; }
        .card-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; margin-bottom: 16px; align-items: stretch; }
        .card { background: #fff; border-radius: var(--r-sm); padding: 10px 12px 9px; box-shadow: var(--sh); border-top: 3px solid var(--brand); position: relative; overflow: hidden; min-width: 0; }
        .card .c-lbl { font-size: .57rem; font-weight: 700; text-transform: uppercase; letter-spacing: .5px; color: var(--text-l); margin-bottom: 3px; }
        .card .c-val { font-size: .95rem; font-weight: 800; color: var(--text-h); line-height: 1.25; }
        .sec { background: #fff; border-radius: var(--r); box-shadow: var(--sh); margin-bottom: 14px; overflow: hidden; border: 1px solid rgba(0,0,0,.04); }
        .sec-hdr { display: flex; align-items: center; justify-content: space-between; padding: 11px 18px; background: var(--brand); color: #fff; font-weight: 700; font-size: .87rem; }
        .tbl-wrap { overflow-x: auto; }
        table     { width: 100%; border-collapse: collapse; font-size: .79rem; }
        thead th  { background: var(--brand); color: #fff; padding: 9px 12px; text-align: left; font-weight: 600; font-size: .72rem; letter-spacing: .2px; white-space: nowrap; }
        tbody tr            { border-bottom: 1px solid var(--line); }
        tbody tr:last-child { border: none; }
        tbody tr:hover      { background: var(--brand-ultra); }
        tbody td            { padding: 8px 12px; vertical-align: middle; }
        .r-ok  td  { background: var(--ok-bg);   }
        .r-warn td { background: var(--warn-bg); }
        .r-err  td { background: var(--err-bg);  }
        .td-name   { font-weight: 700; }
        .pw { display: flex; align-items: center; gap: 8px; }
        .pt { flex: 1; height: 8px; background: #E8E8EE; border-radius: 6px; overflow: hidden; }
        .pf { height: 100%; border-radius: 6px; }
        .pp { font-weight: 700; font-size: .74rem; min-width: 36px; text-align: right; }
        .badge { display: inline-block; padding: 2px 9px; border-radius: 20px; font-size: .67rem; font-weight: 700; }
        .b-ok   { background: #D1F2D1; color: #065006; }
        .b-warn { background: #FEF0CC; color: #6B3A00; }
        .b-err  { background: #FDDCDE; color: #7A0010; }
    </style>
</head>
<body>

<div class="rpt-hdr">
    <div class="hdr-inner">
        <div class="hdr-title">RDS License Usage Monitoring - Combined Summary</div>
        <div class="hdr-gen">&#128336; Generated: <span id="gen-date">-</span></div>
    </div>
    <div class="hdr-strip">
        <span>&#128421; Servers: <strong id="server-count">-</strong></span>
        <span class="status-pill" id="status-pill">-</span>
    </div>
</div>

<div class="rpt-body">
    <div class="card-grid">
        <div class="card"><div class="c-lbl">Total CALs (All Servers)</div><div class="c-val" id="c-total-installed">-</div></div>
        <div class="card"><div class="c-lbl">CALs In Use</div><div class="c-val" id="c-total-issued">-</div></div>
        <div class="card"><div class="c-lbl">CALs Available</div><div class="c-val" id="c-total-available">-</div></div>
        <div class="card"><div class="c-lbl">Overall Utilisation</div><div class="c-val" id="c-overall-pct">-</div></div>
    </div>

    <div class="sec">
        <div class="sec-hdr">&#128421; License Servers</div>
        <div class="tbl-wrap">
            <table>
                <thead><tr><th>Server Name</th><th>OS Version</th><th>Total</th><th>Issued</th><th>Available</th><th>Utilisation</th></tr></thead>
                <tbody id="rows-tbody"><tr><td colspan="6" style="text-align:center;padding:20px;color:#8A8A9A;">Awaiting data...</td></tr></tbody>
            </table>
        </div>
    </div>
</div>

<script>
function renderCombinedReport() {
    if (!window.COMBINED_DATA) return;
    var d = window.COMBINED_DATA;
    var pillMap = { COMPLIANT: 'pill-ok', WARNING: 'pill-warn', CRITICAL: 'pill-err' };
    function set(id, val) {
        var el = document.getElementById(id); if (!el) return;
        el.textContent = val;
    }
    set('gen-date', d.GenDate);
    set('server-count', d.ServerCount);
    var pill = document.getElementById('status-pill');
    pill.textContent = d.OverallState + ' - ' + d.OverallPct + '% Overall Utilisation';
    pill.className   = 'status-pill ' + (pillMap[d.OverallState] || 'pill-ok');
    set('c-total-installed', d.TotalInstalled);
    set('c-total-issued',    d.TotalIssued);
    set('c-total-available', d.TotalAvailable);
    set('c-overall-pct',     d.OverallPct + '%');

    /* One row per server in d.Rows - this naturally adjusts to however many
       servers were actually passed to the script, whether that was one or
       many, with no fixed row count anywhere in this rendering logic. */
    var body = '';
    d.Rows.forEach(function (r) {
        var col    = r.UsagePct >= d.CritThresholdPct ? '#BF0E1A' : r.UsagePct >= d.WarnThresholdPct ? '#B05E00' : '#0A7A09';
        var rowCls = r.UsagePct >= d.CritThresholdPct ? 'r-err'   : r.UsagePct >= d.WarnThresholdPct ? 'r-warn'  : 'r-ok';
        body +=
            "<tr class='" + rowCls + "'>" +
            "<td class='td-name'>" + r.Server + "</td>" +
            "<td>" + r.OSVersion + "</td>" +
            "<td style='text-align:center;font-weight:700;'>" + r.Installed + "</td>" +
            "<td style='text-align:center;font-weight:700;color:" + col + ";'>" + r.Issued + "</td>" +
            "<td style='text-align:center;'>" + r.Available + "</td>" +
            "<td><div class='pw'><div class='pt'><div class='pf' style='width:" + Math.min(r.UsagePct,100) + "%;background:" + col + ";'></div></div>" +
            "<div class='pp' style='color:" + col + ";'>" + r.UsagePct + "%</div></div></td>" +
            "</tr>";
    });
    document.getElementById('rows-tbody').innerHTML = body ||
        "<tr><td colspan='6' style='text-align:center;padding:20px;color:#8A8A9A;'>No server data available</td></tr>";
}
</script>
</body>
</html>
'@
}


function Build-CombinedReport {
    param([System.Collections.Generic.List[object]]$Results)

    $TotalInstalled = ($Results | Measure-Object Installed -Sum).Sum
    $TotalIssued    = ($Results | Measure-Object Issued    -Sum).Sum
    $TotalAvailable = ($Results | Measure-Object Available -Sum).Sum
    $OverallPct     = if ($TotalInstalled -gt 0) { [math]::Round(($TotalIssued / $TotalInstalled) * 100, 1) } else { 0 }
    $OverallState   = if     ($OverallPct -ge $CriticalThresholdPct) { "CRITICAL"  }
                       elseif ($OverallPct -ge $WarningThresholdPct)  { "WARNING"   }
                       else                                            { "COMPLIANT" }

    $rowsJsonItems = $Results | ForEach-Object {
        '{"Server":"'     + (EscapeJson $_.Server)     + '",' +
        '"OSVersion":"'   + (EscapeJson $_.OSVersion)   + '",' +
        '"Installed":'    + [int]$_.Installed            + ',' +
        '"Issued":'       + [int]$_.Issued               + ',' +
        '"Available":'    + [int]$_.Available            + ',' +
        '"UsagePct":'     + $_.UsagePct                  + ',' +
        '"Compliance":"'  + (EscapeJson $_.Compliance)  + '"}'
    }
    $rowsJson = '[' + ($rowsJsonItems -join ',') + ']'

    $cDT = Get-Date -Format "yyyyMMdd_HHmmss"
    $combinedFile = ($ScriptDir + "Output\") + "UC3_RDSLicenseMonitoring_Combined_$cDT.html"

    try {
        if (-not (Test-Path ($ScriptDir + "Output\"))) {
            New-Item -Path ($ScriptDir + "Output\") -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        $html = Get-CombinedTemplate
        $jsonBlock = @"
<script>
window.COMBINED_DATA = {
  "GenDate"          : "$(EscapeJson (Get-Date -Format "dddd, dd MMMM yyyy HH:mm:ss"))",
  "ServerCount"      : $($Results.Count),
  "TotalInstalled"   : $TotalInstalled,
  "TotalIssued"      : $TotalIssued,
  "TotalAvailable"   : $TotalAvailable,
  "OverallPct"       : $OverallPct,
  "OverallState"     : "$(EscapeJson $OverallState)",
  "WarnThresholdPct" : $WarningThresholdPct,
  "CritThresholdPct" : $CriticalThresholdPct,
  "Rows"             : $rowsJson
};
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", renderCombinedReport);
} else {
  renderCombinedReport();
}
</script>
"@
        $html = $html.Replace('</body>', ($jsonBlock + "`n</body>"))
        $html | Out-File -FilePath $combinedFile -Encoding UTF8 -ErrorAction Stop
        Write-Log "Combined report saved ($($Results.Count) server(s)): $combinedFile" "SUCCESS"
    } catch {
        Write-Log "FATAL: Could not build combined report: $($_.Exception.Message)" "ERROR"
    }
}


function Invoke-LicenseServerReport {
    param([string]$Server)

    # ============================================================================
    # INITIALISATION
    # ============================================================================
    $ScriptStartTime = Get-Date

    $ErrorLog    = [System.Collections.Generic.List[string]]::new()
    $KeyPacks    = @()
    $Issued      = 0
    $Available   = 0
    $Installed   = 0

    Write-Log "License Server: $Server"

    # ============================================================================
    # ENSURE OUTPUT FOLDER EXISTS
    # ============================================================================
    # The output filename includes a sanitised server name, in addition to the
    # timestamp, so that running this script against multiple license servers
    # at the same time (e.g. several concurrent HPSA jobs) can never produce a
    # filename collision between two different servers' reports.
    $cDT             = Get-Date -Format "yyyyMMdd_HHmmss"
    $SafeServerName  = ($Server -replace '[^a-zA-Z0-9\-\.]', '_')
    $OutputDir       = $ScriptDir + "Output\"
    $htmlOutputFile  = $OutputDir + "UC3_RDSLicenseMonitoring_${SafeServerName}_$cDT.html"

    try {
        if (-not (Test-Path $OutputDir)) {
            New-Item -Path $OutputDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
            Write-Log "Output folder created: $OutputDir" "SUCCESS"
        }
    } catch {
        Write-Log "FATAL: Could not create output folder [$OutputDir]: $($_.Exception.Message)" "ERROR"
        return $null
    }

    # ============================================================================
    # BUILD HTML TEMPLATE IN MEMORY
    # ============================================================================
    # The template is built and held in memory only - it is never written to a
    # shared file on disk. This is what makes it safe to run this script
    # concurrently against several license servers at once: each running
    # instance has its own independent copy of the template string in its own
    # process memory, with no shared file path that two instances could
    # collide on (read mid-write, partial overwrite, file lock contention, etc).
    try {
        $HtmlContent = Get-EmbeddedTemplate
        Write-Log "HTML template loaded into memory" "SUCCESS"
    } catch {
        Write-Log "FATAL: Could not build HTML template: $($_.Exception.Message)" "ERROR"
        return $null
    }

    # ============================================================================
    # QUERY RDS LICENSE SERVER
    # ============================================================================
    Write-Log "Querying license server via WMI: $Server"
    try {
        $KeyPacks = @(Get-WmiObject -Class "Win32_TSLicenseKeyPack" -ComputerName $Server -ErrorAction Stop)
        Write-Log "WMI query OK - $($KeyPacks.Count) key pack(s) returned" "SUCCESS"
    } catch {
        Write-Log "WMI failed ($($_.Exception.Message)), retrying via CIM..." "WARN"
        try {
            $cimOpts  = New-CimSessionOption -Protocol Dcom
            $cimSess  = New-CimSession -ComputerName $Server -SessionOption $cimOpts -ErrorAction Stop
            $KeyPacks = @(Get-CimInstance -CimSession $cimSess -ClassName "Win32_TSLicenseKeyPack" -ErrorAction Stop)
            Remove-CimSession $cimSess
            Write-Log "CIM query OK - $($KeyPacks.Count) key pack(s) returned" "SUCCESS"
        } catch {
            $ErrorLog.Add("License server [$Server] unreachable: $($_.Exception.Message)")
            Write-Log "License server unreachable. CAL counts will show 0." "ERROR"
        }
    }

    # WMI/CIM can return successfully with zero rows (no exception thrown) if the
    # license server has no key packs installed, or if the query ran against the
    # wrong server/role. This is NOT caught by the try/catch above since no
    # error occurs - it must be checked explicitly so the report surfaces it
    # instead of silently showing all-zero data with no explanation.
    if ($KeyPacks.Count -eq 0) {
        $ErrorLog.Add("Query to [$Server] returned zero license key packs. Verify this server has the RD Licensing role installed, that key packs are activated, and that the HPSA service account has WMI/CIM access to this host.")
        Write-Log "WARNING: Zero key packs returned from $Server" "WARN"
    }

    # Windows version of the license server - shown on the License Server card
    $LicServerOSVersion = "N/A"
    try {
        $osInfo = Get-WmiObject -Class "Win32_OperatingSystem" -ComputerName $Server -ErrorAction Stop
        $LicServerOSVersion = "$($osInfo.Caption)".Trim()
    } catch {
        try {
            $osInfo = Get-CimInstance -ClassName "Win32_OperatingSystem" -ComputerName $Server -ErrorAction Stop
            $LicServerOSVersion = "$($osInfo.Caption)".Trim()
        } catch {
            $ErrorLog.Add("Could not retrieve Windows OS version for [$Server]: $($_.Exception.Message)")
            Write-Log "Could not retrieve OS version for $Server" "WARN"
        }
    }

    # Win32_TSLicenseKeyPack reports TotalLicenses = -1 (shown as the unsigned
    # value 4294967295 by some providers) for "unlimited" key packs - e.g.
    # built-in or temporary packs that are not capacity-limited. Summing this
    # value directly produces grossly inflated totals (Installed showing in
    # the billions). Unlimited packs are excluded from the numeric totals so
    # the dashboard reflects only real, finite capacity.
    #
    # Some license servers also return EXACT duplicate key pack entries - same
    # Description, ProductVersion, TotalLicenses, and IssuedLicenses but a
    # different KeyPackId (a known WMI quirk, often seen after a license
    # server migration or re-registration). Each such duplicate represents
    # the SAME underlying license capacity counted twice, not a separate
    # real agreement, so it is excluded here to keep the reported totals
    # accurate (one combined Total/Issued/Available figure per server).
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

        # Group finite packs by their license "signature" (Description + ProductVersion
        # + TotalLicenses + IssuedLicenses). Packs sharing an identical signature are
        # treated as duplicate WMI entries for the same license capacity - only the
        # FIRST occurrence of each signature counts toward the management totals.
        $SeenSignatures  = @{}
        $DedupedPacks    = [System.Collections.Generic.List[object]]::new()
        $DuplicatePackCount = 0
        foreach ($pack in $FinitePacks) {
            $sig = "$($pack.Description)|$($pack.ProductVersion)|$($pack.TotalLicenses)|$($pack.IssuedLicenses)"
            if ($SeenSignatures.ContainsKey($sig)) {
                $script:DuplicatePackCount++
            } else {
                $SeenSignatures[$sig] = $true
                $DedupedPacks.Add($pack)
            }
        }

        $Issued    = if ($DedupedPacks.Count -gt 0) { ($DedupedPacks | Measure-Object IssuedLicenses    -Sum).Sum } else { 0 }
        $Available = if ($DedupedPacks.Count -gt 0) { ($DedupedPacks | Measure-Object AvailableLicenses -Sum).Sum } else { 0 }
        $Installed = if ($DedupedPacks.Count -gt 0) { ($DedupedPacks | Measure-Object TotalLicenses     -Sum).Sum } else { 0 }

        if ($UnlimitedPackCount -gt 0) {
            Write-Log "$UnlimitedPackCount unlimited key pack(s) excluded from totals (not capacity-limited)" "WARN"
        }
        if ($DuplicatePackCount -gt 0) {
            Write-Log "$DuplicatePackCount duplicate key pack(s) excluded from totals (same Description/Version/Total/Issued as another pack)" "WARN"
        }
        Write-Log "Installed: $Installed | Issued: $Issued | Available: $Available (from $($DedupedPacks.Count) unique finite pack(s), $DuplicatePackCount duplicate(s) excluded)" "SUCCESS"
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
        $errJsonItems = $ErrorLog | ForEach-Object { '"' + (EscapeJson $_) + '"' }
        $errJson      = '[' + ($errJsonItems -join ',') + ']'

        $JsonBlock = @"
    <script>
    window.REPORT_DATA = {
      "GenDate"           : "$(EscapeJson $GenDate)",
      "LicenseServerFQDN" : "$(EscapeJson $Server)",
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
        return $null
    }

    # ============================================================================
    # INJECT JSON INTO HTML AND SAVE OUTPUT
    # ============================================================================
    try {
        Write-Log "Output   : $htmlOutputFile"

        # .Replace() is used instead of -replace because -replace is regex-based
        # and JsonBlock contains $ { } \ characters that break regex silently,
        # producing an HTML file with no data injected (REPORT_DATA stays unset).
        # $HtmlContent already holds the in-memory template built earlier - no
        # shared file is read here, so concurrent runs against different
        # servers never interfere with each other.
        $HtmlContent = $HtmlContent.Replace('</body>', ($JsonBlock + "`n</body>"))

        $HtmlContent | Out-File -FilePath $htmlOutputFile -Encoding UTF8 -ErrorAction Stop
        Write-Log "Output report saved: $htmlOutputFile" "SUCCESS"
    } catch {
        Write-Log "FATAL: Could not inject data or save output report: $($_.Exception.Message)" "ERROR"
        return $null
    }

    if ($ErrorLog.Count -gt 0) {
        Write-Log "$($ErrorLog.Count) error(s)/warning(s) were captured and are shown in the HTML report:" "WARN"
        foreach ($e in $ErrorLog) { Write-Log "  - $e" "WARN" }
    }
    Write-Log "=== UC3 Complete for [$Server] | $Compliance ($UsagePct%) ===" "SUCCESS"

    return [PSCustomObject]@{
        Server      = $Server
        OSVersion   = $LicServerOSVersion
        Installed   = $Installed
        Issued      = $Issued
        Available   = $Available
        UsagePct    = $UsagePct
        Compliance  = $Compliance
        OutputFile  = $htmlOutputFile
        ErrorCount  = $ErrorLog.Count
    }
}

# ============================================================================
# MAIN DRIVER - parse server list and process each server independently
# ============================================================================
# $LicenseServerFQDN may contain one server, or multiple servers separated
# by semicolons. Each entry is trimmed of surrounding whitespace and empty
# entries (e.g. from a trailing semicolon) are discarded. Each server is
# processed completely independently via Invoke-LicenseServerReport, which
# has its own local variables and its own try/catch blocks, so a failure
# on one server can never affect or block the processing of another.
$ServerList = @(
    $LicenseServerFQDN -split ';' |
        ForEach-Object { $_.Trim() } |
        Where-Object   { $_ -ne '' }
)

if ($ServerList.Count -eq 0) {
    Write-Log "FATAL: LicenseServerFQDN did not contain any valid server name after parsing." "ERROR"
    exit 3
}

Write-Log "=== UC3 RDS License Monitoring | Citrix Workspace Automation Suite ==="
Write-Log "$($ServerList.Count) license server(s) to process: $($ServerList -join ', ')"

$FailedServers     = [System.Collections.Generic.List[string]]::new()
$ServerResults     = [System.Collections.Generic.List[object]]::new()

foreach ($Server in $ServerList) {
    Write-Log "----------------------------------------------------------------------"
    Write-Log "Processing license server: $Server"
    $result = Invoke-LicenseServerReport -Server $Server
    if ($result) {
        $ServerResults.Add($result)
    } else {
        $FailedServers.Add($Server)
        Write-Log "Server [$Server] FAILED - see FATAL/ERROR lines above for this server. Continuing with remaining servers." "ERROR"
    }
}

Write-Log "========================================================================"
Write-Log "=== UC3 Batch Complete | $($ServerResults.Count) succeeded, $($FailedServers.Count) failed (of $($ServerList.Count) total) ===" "SUCCESS"
if ($FailedServers.Count -gt 0) {
    Write-Log "Failed server(s): $($FailedServers -join ', ')" "ERROR"
}

# Build the combined multi-server report whenever at least one server
# succeeded. It always reflects exactly how many servers were actually
# passed in - one row for a single server, N rows for N servers - so the
# report layout adjusts dynamically to whatever was supplied at runtime.
if ($ServerResults.Count -gt 0) {
    Build-CombinedReport -Results $ServerResults
}

# Exit code reflects whether the SCRIPT ran successfully for every server,
# not CAL compliance state (COMPLIANT/WARNING/CRITICAL is a data finding,
# shown in each server's own HTML report and console log, never the exit
# code - see Invoke-LicenseServerReport). A non-zero exit here means one or
# more servers genuinely failed to be queried or reported on.
if ($FailedServers.Count -gt 0) {
    exit 3
} else {
    exit 0
}
