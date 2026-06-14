############################################################################################################
# Script Name : UC3_RDSLicenseMonitoring.ps1
# Description : RDS License Usage Monitoring | Citrix Workspace Automation Suite
#               Queries RDS License Server via WMI/CIM, collects session host metrics via WinRM,
#               generates a self-contained HTML report, emits HPSA Base64 output for Camunda.
# Architecture: Self-contained single file.
#               HTML template is embedded as a here-string and written to disk on every run.
#               Output HTML is saved to <ScriptDir>\Output\ (timestamped).
# HPSA Usage  : powershell.exe -ExecutionPolicy Bypass -File UC3_RDSLicenseMonitoring.ps1
# ExitCode    : 0=COMPLIANT  1=WARNING  2=CRITICAL
############################################################################################################

$ErrorActionPreference = "SilentlyContinue"
$ScriptDir = (Split-Path $script:MyInvocation.MyCommand.Path) + "\"

# ============================================================================
# SECTION 1 - SETTINGS  (edit this block)
# ============================================================================
$LicenseServerFQDN    = "YOUR_RDS_LICENSE_SERVER_FQDN"   # e.g. "rdslicense.corp.com"
$WarningThresholdPct  = 80
$CriticalThresholdPct = 95
$SessionHosts         = @()       # e.g. @("host1.corp.com","host2.corp.com")  leave @() to skip
$ADOrgUnit            = ""        # e.g. "OU=SessionHosts,DC=corp,DC=com"     leave "" to skip
$WinRMCredential      = $null     # Set to a PSCredential if WinRM needs auth
$CamundaBaseUrl       = ""        # e.g. "http://camunda:8080/engine-rest"
$CamundaProcessKey    = ""        # Camunda process/message key
$CamundaBusinessKey   = ""        # Camunda business key (auto-set if empty)
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

function ConvertTo-Base64Utf8 {
    param([string]$InputString)
    $raw = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($InputString))
    # Wrap at 76 chars per line (MIME standard) to prevent HPSA buffer truncation
    $sb  = [System.Text.StringBuilder]::new()
    $pos = 0
    while ($pos -lt $raw.Length) {
        $len = [Math]::Min(76, $raw.Length - $pos)
        [void]$sb.AppendLine($raw.Substring($pos, $len))
        $pos += $len
    }
    return $sb.ToString().TrimEnd()
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
            "Int32"   { "Integer" } "Int64"  { "Long"    } "Double" { "Double" }
            "Boolean" { "Boolean" } default  { "String"  }
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
        Write-Log "Camunda: Correlated OK (businessKey=$BusinessKey)" "SUCCESS"
        return $r
    } catch {
        Write-Log "Camunda: Correlation failed, trying start..." "WARN"
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
        .card-grid { display: grid; grid-template-columns: repeat(8, 1fr) 200px; gap: 8px; margin-bottom: 16px; align-items: stretch; }
        .card { background: #fff; border-radius: var(--r-sm); padding: 10px 12px 9px; box-shadow: var(--sh); border-top: 3px solid var(--brand); position: relative; overflow: hidden; transition: transform .15s, box-shadow .15s; min-width: 0; }
        .card:hover  { transform: translateY(-2px); box-shadow: var(--sh-lg); }
        .card::after { content: attr(data-ico); position: absolute; right: 6px; top: 6px; font-size: 1.3rem; opacity: .07; }
        .card .c-lbl { font-size: .57rem; font-weight: 700; text-transform: uppercase; letter-spacing: .5px; color: var(--text-l); margin-bottom: 3px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .card .c-val { font-size: .82rem; font-weight: 800; color: var(--text-h); line-height: 1.25; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .card .c-sub { font-size: .62rem; color: var(--text-m); margin-top: 2px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .card-gauge { background: #fff; border-radius: var(--r-sm); box-shadow: var(--sh); border-top: 3px solid var(--brand); padding: 8px 10px 6px; display: flex; flex-direction: column; align-items: center; justify-content: center; transition: transform .15s, box-shadow .15s; }
        .card-gauge:hover   { transform: translateY(-2px); box-shadow: var(--sh-lg); }
        .card-gauge .cg-lbl { font-size: .57rem; font-weight: 700; text-transform: uppercase; letter-spacing: .5px; color: var(--text-l); margin-bottom: 3px; white-space: nowrap; }
        .gauge-footer { margin-top: 2px; width: 100%; }
        .gauge-ruler  { display: flex; justify-content: space-between; font-size: .57rem; color: var(--text-l); margin-top: 2px; }
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
        .rpt-footer { text-align: center; font-size: .72rem; color: var(--text-l); padding: 18px 0 28px; border-top: 1px solid var(--line); margin-top: 8px; }
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
            <span>&#128187; Hosts: <strong id="host-count">-</strong></span>
            <span>&#9203; Duration: <strong id="duration">-</strong></span>
            <span>&#128295; PS: <strong id="ps-ver">-</strong></span>
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
        <div class="card" data-ico="&#128220;"><div class="c-lbl">License Server</div><div class="c-val" id="c-lic-server">-</div><div class="c-sub">WMI / CIM</div></div>
        <div class="card" data-ico="&#128202;"><div class="c-lbl">CALs Installed</div><div class="c-val" id="c-installed">-</div></div>
        <div class="card" data-ico="&#128273;"><div class="c-lbl">CALs In Use</div><div class="c-val" id="c-issued">-</div><div class="c-sub" id="c-issued-sub">-</div></div>
        <div class="card" data-ico="&#9989;"><div class="c-lbl">CALs Available</div><div class="c-val" id="c-available">-</div><div class="c-sub" id="c-headroom">-</div></div>
        <div class="card" data-ico="&#9888;"><div class="c-lbl">Warn Threshold</div><div class="c-val" id="c-warn">-</div><div class="c-sub" id="c-warn-sub">-</div></div>
        <div class="card" data-ico="&#128308;"><div class="c-lbl">Crit Threshold</div><div class="c-val" id="c-crit">-</div><div class="c-sub" id="c-crit-sub">-</div></div>
        <div class="card" data-ico="&#128187;"><div class="c-lbl">Session Hosts</div><div class="c-val" id="c-hosts">-</div><div class="c-sub">WinRM direct</div></div>
        <div class="card" data-ico="&#9201;"><div class="c-lbl">Script Duration</div><div class="c-val" id="c-duration">-</div></div>
        <div class="card-gauge">
            <div class="cg-lbl">&#128200; Live CAL Utilisation</div>
            <div id="gauge-svg-container"></div>
            <div class="gauge-footer">
                <div class="pw" style="margin:0 auto;max-width:140px;">
                    <div class="pt"><div class="pf" id="gauge-bar" style="width:0%;"></div></div>
                    <div class="pp" id="gauge-pct">-</div>
                </div>
                <div class="gauge-ruler">
                    <span>0%</span>
                    <span id="ruler-warn" style="color:#B05E00;">v-</span>
                    <span id="ruler-crit" style="color:#BF0E1A;">v-</span>
                    <span>100%</span>
                </div>
            </div>
        </div>
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

    <div class="sec" id="s-hosts">
        <div class="sec-hdr" onclick="tog('hosts')">
            <span class="sec-hdr-l">&#128187; Citrix Session Host Details</span>
            <span class="sec-hdr-r"><span id="host-count-sec">-</span> host(s) <span class="chev" id="chev-hosts">&#9660;</span></span>
        </div>
        <div class="sec-body" id="b-hosts">
            <div class="tbl-wrap">
                <table>
                    <thead><tr><th>Host Name</th><th>OS</th><th>Active</th><th>Disconnected</th><th>Total Sessions</th><th>CPU %</th><th>Mem %</th><th>Disk Free</th><th>Uptime</th><th>License Mode</th><th>Citrix VDA</th><th>DDC / Farm</th><th>Health</th><th>Duration</th></tr></thead>
                    <tbody id="hosts-tbody"><tr><td colspan="14" style="text-align:center;padding:20px;color:#8A8A9A;">Awaiting data...</td></tr></tbody>
                </table>
            </div>
        </div>
    </div>
</div>

<div class="rpt-footer">
    UC3 &mdash; RDS License Usage Monitoring &nbsp;|&nbsp; Citrix Workspace Automation Suite
    &nbsp;|&nbsp; Generated by <strong>UC3_RDSLicenseMonitoring.ps1</strong><br>
    <span id="footer-sha" style="font-family:'Cascadia Code','Consolas','Courier New',monospace;font-size:.65rem;color:#aaa;display:inline-block;margin-top:4px;"></span>
</div>

<script>
var REPORT_DATA = null;
(function () {
    if (!REPORT_DATA) return;
    var d        = REPORT_DATA;
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
    set('host-count',  d.HostCount);
    set('duration',    d.ScriptDur + 's');
    set('ps-ver',      d.PSVersion + ' (64-bit: ' + d.Is64Bit + ')');
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
        'Hosts: <strong>' + d.HostCount + '</strong> &nbsp;|&nbsp; ' +
        'Discovery: <strong>' + d.HostDiscovery + '</strong>', true);
    set('c-lic-server',  d.LicenseServerFQDN);
    set('c-installed',   d.Installed);
    setStyled('c-issued', d.Issued, 'color:' + color + ';');
    set('c-issued-sub',  d.UsagePct + '% utilisation');
    set('c-available',   d.Available);
    set('c-headroom',    d.HeadroomPct + '% headroom');
    set('c-warn',        d.WarnPctLabel);
    set('c-warn-sub',    d.WarnCardSub);
    set('c-crit',        d.CritPctLabel);
    set('c-crit-sub',    d.CritCardSub);
    set('c-hosts',       d.HostCount);
    set('c-duration',    d.ScriptDur + 's');
    document.getElementById('gauge-svg-container').innerHTML = d.GaugeSVG;
    var bar = document.getElementById('gauge-bar');
    bar.style.width      = Math.min(d.UsagePct, 100) + '%';
    bar.style.background = color;
    setStyled('gauge-pct', d.UsagePct + '%', 'color:' + color + ';');
    set('ruler-warn', 'v' + d.WarnPctLabel);
    set('ruler-crit', 'v' + d.CritPctLabel);
    if (d.Errors && d.Errors.length > 0) {
        var li = d.Errors.map(function(e){ return '<li>' + e + '</li>'; }).join('');
        document.getElementById('err-section').innerHTML =
            "<div class='alert alert-err'><div class='ico'>&#9888;</div>" +
            "<div><strong>" + d.Errors.length + " error(s) during execution</strong><ul>" + li + "</ul></div></div>";
    }
    set('kp-count', d.KeyPacks.length);
    var kpBody = '';
    d.KeyPacks.forEach(function (kp) {
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
    set('host-count-sec', d.Hosts.length);
    var hostBody = '';
    d.Hosts.forEach(function (h) {
        var cpuStyle = (h.CPUPct     !== 'N/A' && parseFloat(h.CPUPct)     > 85) ? 'color:#BF0E1A;' : '';
        var memStyle = (h.MemUsedPct !== 'N/A' && parseFloat(h.MemUsedPct) > 90) ? 'color:#BF0E1A;' : '';
        var hBadge   = h.RowCss === 'ok'  ? 'b-ok'  : h.RowCss === 'err' ? 'b-err' : 'b-warn';
        var vdaBadge = h.CtxVdaStatus === 'Running' ? "<span class='badge b-ok'>Running</span>"
                     : h.CtxVdaStatus === 'N/A'     ? "<span class='badge'>N/A</span>"
                     :                                "<span class='badge b-err'>" + h.CtxVdaStatus + "</span>";
        hostBody +=
            "<tr class='r-" + h.RowCss + "'>" +
            "<td class='td-name'>" + h.VMName + "</td>" +
            "<td>" + h.OSCaption + " (" + h.OSBuild + ")</td>" +
            "<td style='text-align:center;font-weight:700;color:#0A7A09;'>" + h.ActiveSessions + "</td>" +
            "<td style='text-align:center;'>" + h.DiscoSessions + "</td>" +
            "<td style='text-align:center;font-weight:700;'>" + h.TotalSessions + "</td>" +
            "<td style='text-align:center;" + cpuStyle + "'>" + h.CPUPct + "%</td>" +
            "<td style='text-align:center;" + memStyle + "'>" + h.MemUsedPct + "%</td>" +
            "<td style='text-align:center;'>" + h.DiskFreeGB + " GB</td>" +
            "<td style='text-align:center;'>" + h.UptimeHrs + " hrs</td>" +
            "<td>" + h.LicMode + "</td>" +
            "<td>" + vdaBadge + "</td>" +
            "<td style='font-size:.7rem;color:#666;'>" + h.CtxFarm + "</td>" +
            "<td><span class='badge " + hBadge + "'>" + h.Health + "</span></td>" +
            "<td class='td-mono'>" + h.DurationSec + "s</td>" +
            "</tr>";
    });
    document.getElementById('hosts-tbody').innerHTML = hostBody ||
        "<tr><td colspan='14' style='text-align:center;padding:20px;color:#8A8A9A;'>No host data available</td></tr>";
    var fsha = document.getElementById('footer-sha');
    if (fsha && d.ReportSHA256) {
        fsha.textContent = 'SHA-256: ' + d.ReportSHA256 + '  |  Host: ' + (d.ExecutionHost || '-') + '  |  ' + (d.GenISO || '-');
    }
})();
</script>
</body>
</html>
'@
}

# ============================================================================
# INITIALISATION
# ============================================================================
$ScriptStartTime = Get-Date
$ExecutionHost   = $env:COMPUTERNAME
$ExecutionUser   = "$env:USERDOMAIN\$env:USERNAME"
$PSVersion       = $PSVersionTable.PSVersion.ToString()
$Is64Bit         = [System.IntPtr]::Size -eq 8

$HostResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$ErrorLog    = [System.Collections.Generic.List[string]]::new()
$KeyPacks    = @()
$Issued      = 0
$Available   = 0
$Installed   = 0

Write-Log "=== UC3 RDS License Monitoring | Citrix Workspace Automation Suite ==="
Write-Log "Host: $ExecutionHost | User: $ExecutionUser | PS $PSVersion | 64-bit: $Is64Bit"
Write-Log "License Server: $LicenseServerFQDN"

# ============================================================================
# ENSURE OUTPUT FOLDER EXISTS
# ============================================================================
if (-not (Test-Path ($ScriptDir + "Output"))) {
    New-Item -Path $ScriptDir -Name "Output" -ItemType Directory | Out-Null
}
$cDT         = Get-Date -Format "yyyyMMdd_HHmmss"
$htmlOutputFile = $ScriptDir + "Output\UC3_RDSLicenseMonitoring_$cDT.html"
$HashFile       = $ScriptDir + "Output\UC3_RDSLicenseMonitoring_$cDT.sha256"

# ============================================================================
# ALWAYS WRITE FRESH HTML TEMPLATE
# ============================================================================
$TemplatePath = $ScriptDir + "UC3_RDSLicenseMonitoring_Report.html"
Write-Log "Writing HTML template: $TemplatePath"
$embeddedHtml = Get-EmbeddedTemplate
[System.IO.File]::WriteAllText($TemplatePath, $embeddedHtml, [System.Text.Encoding]::UTF8)

# ============================================================================
# QUERY RDS LICENSE SERVER
# ============================================================================
Write-Log "Querying license server via WMI: $LicenseServerFQDN"
try {
    $KeyPacks  = @(Get-WmiObject -Class "Win32_TSLicenseKeyPack" -ComputerName $LicenseServerFQDN -ErrorAction Stop)
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
$StatColor  = switch ($Compliance) { "CRITICAL" { "#BF0E1A" } "WARNING"  { "#B05E00" } default { "#0A7A09" } }
Write-Log "CAL Usage: $Issued / $Installed = $UsagePct% => $Compliance"

# ============================================================================
# SESSION HOST DISCOVERY
# ============================================================================
$ResolvedHosts = [System.Collections.Generic.List[string]]::new()
if ($SessionHosts.Count -gt 0) {
    foreach ($h in $SessionHosts) { $t = $h.Trim(); if ($t) { $ResolvedHosts.Add($t) } }
    Write-Log "Explicit host list: $($ResolvedHosts.Count) host(s)." "SUCCESS"
} elseif ($ADOrgUnit) {
    Write-Log "Discovering hosts from AD OU: $ADOrgUnit"
    try {
        $searcher = [adsisearcher]"(objectClass=computer)"
        $searcher.SearchRoot = [adsi]"LDAP://$ADOrgUnit"
        $searcher.PropertiesToLoad.AddRange(@("dnshostname","name")) | Out-Null
        $searcher.PageSize = 1000
        $results = $searcher.FindAll()
        foreach ($r in $results) {
            $dns = if ($r.Properties["dnshostname"].Count -gt 0) { $r.Properties["dnshostname"][0] } else { $r.Properties["name"][0] }
            if ($dns) { $ResolvedHosts.Add($dns.ToString()) }
        }
        $results.Dispose()
        Write-Log "AD discovery: $($ResolvedHosts.Count) host(s) found." "SUCCESS"
    } catch {
        $ErrorLog.Add("AD host discovery failed: $($_.Exception.Message)")
        Write-Log "AD discovery failed." "ERROR"
    }
} else {
    Write-Log "No session hosts configured (no -SessionHosts or -ADOrgUnit). Host table will be empty." "WARN"
}

# ============================================================================
# QUERY CITRIX SESSION HOSTS via WinRM (parallel)
# ============================================================================
$SessionScript = {
    $sessions = query session 2>&1
    $active   = ($sessions | Where-Object { $_ -match "Active" }).Count
    $disco    = ($sessions | Where-Object { $_ -match "Disc"   }).Count
    $cpu = try { (Get-WmiObject Win32_Processor -ErrorAction Stop | Measure-Object LoadPercentage -Average).Average } catch { -1 }
    $os  = try { Get-WmiObject Win32_OperatingSystem -ErrorAction Stop } catch { $null }
    $memPct    = if ($os) { [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 1) } else { -1 }
    $uptime    = if ($os) { [math]::Round(((Get-Date) - $os.ConvertToDateTime($os.LastBootUpTime)).TotalHours, 1) } else { -1 }
    $disk      = try { Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop } catch { $null }
    $diskFreeGB= if ($disk) { [math]::Round($disk.FreeSpace / 1GB, 1) } else { -1 }
    $licMode   = try { (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM" -Name "Licensing Mode" -ErrorAction Stop)."Licensing Mode" } catch { "N/A" }
    $ctxVda    = try { (Get-Service -Name "BrokerAgent" -ErrorAction Stop).Status.ToString() } catch { "N/A" }
    $ctxFarm   = try { (Get-ItemProperty "HKLM:\SOFTWARE\Citrix\VirtualDesktopAgent" -Name "ListOfDDCs" -ErrorAction SilentlyContinue).ListOfDDCs } catch { "N/A" }
    [PSCustomObject]@{
        HostName="$env:COMPUTERNAME"; ActiveSessions=$active; DiscoSessions=$disco; TotalSessions=($active+$disco)
        CPUPct=$cpu; MemUsedPct=$memPct; DiskFreeGB=$diskFreeGB
        OSCaption=if($os){$os.Caption}else{"N/A"}; OSBuild=if($os){$os.BuildNumber}else{"N/A"}
        LicMode=$licMode; UptimeHrs=$uptime; CtxVdaStatus=$ctxVda; CtxFarm=$ctxFarm
    }
}

if ($ResolvedHosts.Count -gt 0) {
    $invokeParams = @{
        ComputerName  = $ResolvedHosts.ToArray()
        ScriptBlock   = $SessionScript
        ThrottleLimit = 32
        ErrorAction   = "SilentlyContinue"
        ErrorVariable = "WinRMErrors"
    }
    if ($WinRMCredential) { $invokeParams["Credential"] = $WinRMCredential }
    Write-Log "WinRM: querying $($ResolvedHosts.Count) host(s) in parallel..."
    $t0       = Get-Date
    $AllInfos = @(Invoke-Command @invokeParams)
    $batchDur = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    Write-Log "WinRM batch complete in ${batchDur}s - $($AllInfos.Count)/$($ResolvedHosts.Count) responded." "SUCCESS"

    $InfoMap = @{}
    foreach ($info in $AllInfos) { $InfoMap[$info.PSComputerName.ToUpper()] = $info }
    $FailedHosts = @{}
    foreach ($err in $WinRMErrors) { $tgt = $err.TargetObject; if ($tgt) { $FailedHosts[$tgt.ToUpper()] = $err.Exception.Message } }

    foreach ($HostName in $ResolvedHosts) {
        $key  = $HostName.ToUpper()
        $info = $InfoMap[$key]
        if ($info) {
            $health = if ($info.TotalSessions -gt 80) { "High Load" }
                      elseif ($info.CPUPct -gt 85)    { "CPU Warning" }
                      elseif ($info.MemUsedPct -gt 90) { "Mem Warning" }
                      elseif ($info.CtxVdaStatus -ne "Running" -and $info.CtxVdaStatus -ne "N/A") { "VDA Offline" }
                      else { "OK" }
            $rowCss = if ($health -ne "OK") { "warn" } else { "ok" }
            Write-Log "  $HostName | Sessions: $($info.TotalSessions) | Health: $health" "SUCCESS"
            $HostResults.Add([PSCustomObject]@{
                VMName=$HostName; HostName=$info.HostName; OSCaption=$info.OSCaption; OSBuild=$info.OSBuild
                ActiveSessions=$info.ActiveSessions; DiscoSessions=$info.DiscoSessions; TotalSessions=$info.TotalSessions
                CPUPct=$info.CPUPct; MemUsedPct=$info.MemUsedPct; DiskFreeGB=$info.DiskFreeGB; UptimeHrs=$info.UptimeHrs
                LicMode=$info.LicMode; CtxVdaStatus=$info.CtxVdaStatus; CtxFarm=$info.CtxFarm
                Health=$health; RowCss=$rowCss; DurationSec=$batchDur
            })
        } else {
            $errMsg = if ($FailedHosts[$key]) { $FailedHosts[$key] } else { "No response" }
            $ErrorLog.Add("[$HostName] WinRM: $errMsg")
            Write-Log "ERROR $HostName : $errMsg" "ERROR"
            $HostResults.Add([PSCustomObject]@{
                VMName=$HostName; HostName="N/A"; OSCaption="N/A"; OSBuild="N/A"
                ActiveSessions="N/A"; DiscoSessions="N/A"; TotalSessions="N/A"
                CPUPct="N/A"; MemUsedPct="N/A"; DiskFreeGB="N/A"; UptimeHrs="N/A"
                LicMode="N/A"; CtxVdaStatus="N/A"; CtxFarm="N/A"
                Health="WinRM Error"; RowCss="err"; DurationSec=0
            })
        }
    }
}

# ============================================================================
# COMPUTED VARIABLES
# ============================================================================
$ScriptDur    = [math]::Round(((Get-Date) - $ScriptStartTime).TotalSeconds, 1)
$GenDate      = Get-Date -Format "dddd, dd MMMM yyyy HH:mm:ss"
$GenISO       = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
$WarnPctLabel = "$WarningThresholdPct%"
$CritPctLabel = "$CriticalThresholdPct%"
$HeadroomPct  = if ($Installed -gt 0) { [math]::Round(($Available / $Installed) * 100, 1) } else { 0 }
$WarnCardSub  = if ($UsagePct -ge $WarningThresholdPct)  { "BREACHED"    } else { "Not reached" }
$CritCardSub  = if ($UsagePct -ge $CriticalThresholdPct) { "BREACHED"    } else { "Not reached" }
$_hostCount   = $ResolvedHosts.Count
$HostDiscovery= if ($SessionHosts.Count -gt 0) { "Explicit list ($_hostCount hosts)" }
               elseif ($ADOrgUnit)             { "AD OU: $ADOrgUnit" }
               else                            { "None configured"   }

# ============================================================================
# SVG GAUGE
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
            "<text x=`"96`" y=`"113`" text-anchor=`"middle`" font-size=`"6.5`" fill=`"#B05E00`">WARN $WarnPctLabel</text>" +
            "<text x=`"172`" y=`"108`" text-anchor=`"middle`" font-size=`"7`" fill=`"#BBB`">100%</text>" +
            "</svg>"

# ============================================================================
# BUILD JSON DATA BLOCK
# ============================================================================
$kpJsonItems = $KeyPacks | ForEach-Object {
    '{"KeyPackId":"'         + (EscapeJson "$($_.KeyPackId)")         + '",' +
    '"Description":"'        + (EscapeJson "$($_.Description)")       + '",' +
    '"ProductVersion":"'     + (EscapeJson "$($_.ProductVersion)")    + '",' +
    '"TotalLicenses":'       + [int]$_.TotalLicenses                  + ','  +
    '"IssuedLicenses":'      + [int]$_.IssuedLicenses                 + ','  +
    '"AvailableLicenses":'   + [int]$_.AvailableLicenses              + '}'
}
$kpJson = '[' + ($kpJsonItems -join ',') + ']'

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
$hostsJson   = '[' + ($hostJsonItems -join ',') + ']'
$errJsonItems= $ErrorLog | ForEach-Object { '"' + (EscapeJson $_) + '"' }
$errJson     = '[' + ($errJsonItems -join ',') + ']'
$gaugeSvgJson= EscapeJson $GaugeSVG

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

# ============================================================================
# INJECT JSON INTO HTML AND SAVE OUTPUT
# ============================================================================
Write-Log "Template : $TemplatePath"
Write-Log "Output   : $htmlOutputFile"

$HtmlContent = Get-Content -Path $TemplatePath -Raw -Encoding UTF8
$HtmlContent = $HtmlContent -replace '</body>', "$JsonBlock`n</body>"

$HtmlContent | Out-File -FilePath $htmlOutputFile -Encoding UTF8
Write-Log "Output report saved: $htmlOutputFile" "SUCCESS"

# ============================================================================
# SHA-256  (from file bytes - same pattern as citrix_audit_v6.ps1)
# ============================================================================
$hashAlgorithm = [System.Security.Cryptography.SHA256]::Create()
$hashBytes     = [System.IO.File]::ReadAllBytes($htmlOutputFile)
$hashValue     = ([BitConverter]::ToString($hashAlgorithm.ComputeHash($hashBytes)) -replace "-", "").ToLower()
$hashAlgorithm.Dispose()

# Back-fill SHA-256 into the saved HTML
$HtmlContent   = [System.Text.Encoding]::UTF8.GetString($hashBytes)
$HtmlContent   = $HtmlContent -replace '"ReportSHA256"\s*:\s*""', "`"ReportSHA256`": `"$hashValue`""
$HtmlContent   | Out-File -FilePath $htmlOutputFile -Encoding UTF8

# Write .sha256 companion file
"$htmlOutputFile : $hashValue" | Add-Content -Path $HashFile -Force
Write-Log "SHA-256: $hashValue" "SUCCESS"

# ============================================================================
# HPSA BASE64 OUTPUT  (Write-Output = stdout, captured by HPSA job step)
# Pattern matches citrix_audit_v6.ps1 exactly
# ============================================================================
$finalBytes = [System.IO.File]::ReadAllBytes($htmlOutputFile)
$finalHtml  = [System.Text.Encoding]::UTF8.GetString($finalBytes)

Write-Output "HPSA_REPORT_B64_START"
Write-Output (ConvertTo-Base64Utf8 -InputString $finalHtml)
Write-Output "HPSA_REPORT_B64_END"
Write-Output "HPSA_REPORT_SHA256:$hashValue"
Write-Output "HPSA_REPORT_PATH:$htmlOutputFile"
Write-Output "Script Completed:$(Get-Date -Format 'yyyyMMdd_HHmmss')"
Write-Output "HTML File : $htmlOutputFile"

# ============================================================================
# CAMUNDA INTEGRATION
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
        ReportSHA256      = $hashValue
        ReportPath        = $htmlOutputFile
        ReportBase64      = (ConvertTo-Base64Utf8 -InputString $finalHtml)
        GeneratedISO      = $GenISO
        ScriptDurationSec = $ScriptDur
        ExecutionHost     = $ExecutionHost
        ExitCode          = $(if ($Compliance -eq "CRITICAL") { 2 } elseif ($Compliance -eq "WARNING") { 1 } else { 0 })
    }
    $bk = if ($CamundaBusinessKey) { $CamundaBusinessKey } else { "UC3-$(Get-Date -Format 'yyyyMMdd')" }
    $cr = Invoke-CamundaRestApi -BaseUrl $CamundaBaseUrl -ProcessKey $CamundaProcessKey `
            -BusinessKey $bk -Variables $cvars -Credential $WinRMCredential
    if ($cr) { Write-Log "Camunda: Posted successfully." "SUCCESS" }
    else     { Write-Log "Camunda: Post failed (non-fatal)." "WARN"  }
}

Write-Log "Output   : $htmlOutputFile" "SUCCESS"
Write-Log "SHA-256  : $hashValue" "SUCCESS"
Write-Log "=== UC3 Complete | $Compliance ($UsagePct%) | ${ScriptDur}s ===" "SUCCESS"

if     ($Compliance -eq "CRITICAL") { exit 2 }
elseif ($Compliance -eq "WARNING")  { exit 1 }
else                                 { exit 0 }
