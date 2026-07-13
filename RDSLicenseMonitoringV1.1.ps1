############################################################################################################
# Script Name : RDSLicenseMonitoring.ps1
# Description : RDS License Usage Monitoring | Citrix Workspace Automation Suite
############################################################################################################

param(
    [Parameter(Mandatory = $true)]
    [string]$LicenseServerFQDN
)

$ErrorActionPreference = "Continue"

$DeployDir = "C:\Scripts\RDL\"
$ScriptDir = $DeployDir

$WarningThresholdPct  = 80
$CriticalThresholdPct = 95

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
        /*  RDS License Usage Monitoring */
        :root {
            --brand        : rgba(216,0,116,1);
            --brand-dark   : rgba(160,0,85,1);
            --brand-deeper : rgba(110,0,58,1);
            --brand-ultra  : rgba(216,0,116,0.04);
            --brand-soft   : rgba(216,0,116,0.09);
            --ok           : #0A7A09;   --ok-bg   : #F0FBF0;   --ok-line   : #CDEFC9;
            --warn         : #B05E00;   --warn-bg : #FFF8EC;   --warn-line : #F6E2B8;
            --err          : #BF0E1A;   --err-bg  : #FFF3F4;   --err-line  : #F6C7CB;
            --text-h       : #15121A;
            --text-b       : #322B3B;
            --text-m       : #6B6378;
            --text-l       : #9A93A6;
            --line         : #E9E5F0;
            --surface      : #FFFFFF;
            --canvas-top   : #F3EEF6;
            --canvas-bot   : #ECE7F2;
            --font         : 'Segoe UI','Helvetica Neue',Arial,sans-serif;
            --font-num     : 'Segoe UI','Helvetica Neue',Arial,sans-serif;
            --mono         : 'Cascadia Code','Consolas','Courier New',monospace;
            --max-w        : 1380px;
            --r            : 14px;
            --r-sm         : 10px;
            --sh           : 0 1px 2px rgba(40,0,25,.04), 0 6px 20px rgba(40,0,25,.06);
            --sh-lg        : 0 10px 30px rgba(40,0,25,.12);
            --sh-press     : 0 1px 3px rgba(40,0,25,.06);
        }
        *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
        html { scroll-behavior: smooth; }
        body {
            font-family: var(--font); font-size: 13.5px; color: var(--text-b); line-height: 1.6;
            background: linear-gradient(165deg, var(--canvas-top) 0%, var(--canvas-bot) 55%, var(--canvas-bot) 100%);
            min-height: 100vh;
        }

        /* ---- Header --------------------------------------------------- */
        .rpt-hdr {
            background: linear-gradient(120deg, var(--brand) 0%, var(--brand-dark) 78%, var(--brand-deeper) 100%);
            color: #fff; position: relative; overflow: hidden;
        }
        .rpt-hdr::before {
            content: ''; position: absolute; inset: 0;
            background:
                radial-gradient(circle at 88% -10%, rgba(255,255,255,.16) 0%, rgba(255,255,255,0) 42%),
                repeating-linear-gradient(-45deg, rgba(255,255,255,0) 0px, rgba(255,255,255,0) 18px, rgba(255,255,255,.025) 18px, rgba(255,255,255,.025) 20px);
        }
        .rpt-hdr::after {
            content: ''; position: absolute; bottom: 0; left: 0; right: 0; height: 3px;
            background: linear-gradient(90deg, rgba(255,255,255,.55), rgba(255,255,255,.05) 45%, rgba(255,255,255,.05) 55%, rgba(255,255,255,.55));
        }
        .hdr-inner {
            position: relative; z-index: 1; padding: 22px 40px 16px; display: flex; align-items: baseline;
            justify-content: space-between; gap: 16px; flex-wrap: wrap;
        }
        .hdr-eyebrow {
            font-size: .68rem; font-weight: 700; letter-spacing: 1.6px; text-transform: uppercase;
            color: rgba(255,255,255,.62); margin-bottom: 5px;
        }
        .hdr-title { font-size: 1.82rem; font-weight: 800; letter-spacing: -.4px; line-height: 1.15; }
        .hdr-gen   { font-size: .75rem; color: rgba(255,255,255,.78); white-space: nowrap; }
        .hdr-strip {
            position: relative; z-index: 1; display: flex; align-items: center; justify-content: space-between;
            background: rgba(15,0,10,.20); padding: 10px 42px; font-size: .76rem; color: rgba(255,255,255,.90);
            gap: 12px; flex-wrap: wrap; border-top: 1px solid rgba(255,255,255,.08);
        }
        .hdr-strip-left { display: flex; align-items: center; gap: 18px; flex-wrap: wrap; }
        .hdr-strip-left span { display: flex; align-items: center; gap: 6px; }
        .hdr-strip-left strong { color: #fff; font-weight: 700; }
        .status-pill {
            padding: 5px 18px; border-radius: 30px; font-weight: 800; font-size: .72rem; letter-spacing: .4px;
            white-space: nowrap; box-shadow: 0 2px 10px rgba(0,0,0,.16);
        }
        .pill-ok   { background: linear-gradient(135deg, #1C9A1A, #0A7A09); color: #fff; }
        .pill-warn { background: linear-gradient(135deg, #D67A00, #B05E00); color: #fff; }
        .pill-err  { background: linear-gradient(135deg, #DC2030, #BF0E1A); color: #fff; }

        .rpt-body { max-width: var(--max-w); margin: 28px auto; padding: 0 26px 56px; }

        /* ---- Alerts ----------------------------------------------------- */
        .alert {
            display: flex; align-items: flex-start; gap: 14px; border-radius: var(--r-sm); padding: 14px 18px;
            margin-bottom: 18px; border-left: 4px solid; font-size: .85rem; background: var(--surface); box-shadow: var(--sh);
        }
        .alert .ico { font-size: 1.15rem; flex-shrink: 0; margin-top: 1px; }
        .alert ul   { margin-top: 6px; padding-left: 16px; }
        .alert li   { margin-top: 3px; }
        .alert-err  { border-color: var(--err); color: #5A000A; }
        .alert-err strong { color: var(--err); }

        /* ---- Overview banner -------------------------------------------- */
        .ov-banner {
            display: flex; align-items: center; gap: 18px; padding: 18px 24px; border-radius: var(--r);
            margin-bottom: 18px; background: var(--surface); box-shadow: var(--sh); border: 1px solid var(--line);
            border-left: 5px solid currentColor; position: relative; overflow: hidden;
        }
        .ov-banner::before {
            content: ''; position: absolute; inset: 0; opacity: .05; pointer-events: none;
            background: radial-gradient(circle at 100% 0%, currentColor 0%, transparent 60%);
        }
        .ov-badge {
            padding: 8px 22px; border-radius: 30px; font-weight: 800; font-size: .85rem; letter-spacing: .4px;
            white-space: nowrap; color: #fff; background: currentColor; position: relative; z-index: 1;
            box-shadow: 0 4px 14px rgba(0,0,0,.14);
        }
        .ov-badge span { color: #fff; }
        .ov-detail { position: relative; z-index: 1; }
        .ov-detail strong { font-size: 1.02rem; color: var(--text-h); }
        .ov-detail .sub   { font-size: .79rem; color: var(--text-m); margin-top: 3px; }

        /* ---- KPI cards ---------------------------------------------------- */
        .card-grid { display: grid; grid-template-columns: repeat(6, 1fr); gap: 10px; margin-bottom: 18px; align-items: stretch; }
        .card {
            background: var(--surface); border-radius: var(--r-sm); padding: 13px 14px 11px; box-shadow: var(--sh);
            border-top: 3px solid var(--brand); position: relative; overflow: hidden; min-width: 0;
            transition: transform .16s ease, box-shadow .16s ease;
        }
        .card:hover  { transform: translateY(-3px); box-shadow: var(--sh-lg); }
        .card::after {
            content: attr(data-ico); position: absolute; right: 8px; top: 8px; font-size: 1.5rem; opacity: .06;
        }
        .card .c-lbl {
            font-size: .58rem; font-weight: 700; text-transform: uppercase; letter-spacing: .6px; color: var(--text-l);
            margin-bottom: 5px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
        }
        .card .c-val {
            font-family: var(--font-num); font-size: .92rem; font-weight: 800; color: var(--text-h); line-height: 1.25;
            white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
        }
        .card .c-sub { font-size: .64rem; color: var(--text-m); margin-top: 3px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

        /* ---- Sections / table -------------------------------------------- */
        .sec { background: var(--surface); border-radius: var(--r); box-shadow: var(--sh); margin-bottom: 16px; overflow: hidden; border: 1px solid var(--line); }
        .sec-hdr {
            display: flex; align-items: center; justify-content: space-between; padding: 13px 20px;
            background: linear-gradient(120deg, var(--brand) 0%, var(--brand-dark) 100%); color: #fff;
            cursor: pointer; user-select: none; transition: filter .18s;
        }
        .sec-hdr:hover      { filter: brightness(1.06); }
        .sec-hdr-l          { display: flex; align-items: center; gap: 9px; font-weight: 700; font-size: .88rem; letter-spacing: .1px; }
        .sec-hdr-r          { display: flex; align-items: center; gap: 8px; font-size: .74rem; opacity: .9; }
        .chev               { transition: transform .24s; display: inline-block; font-size: .7rem; }
        .sec-body           { overflow: hidden; }
        .sec-body.collapsed { display: none; }
        .tbl-wrap { overflow-x: auto; }
        table     { width: 100%; border-collapse: collapse; font-size: .81rem; }
        thead th  {
            background: var(--brand-ultra); color: var(--brand-dark); padding: 11px 14px; text-align: left;
            font-weight: 700; font-size: .71rem; letter-spacing: .3px; text-transform: uppercase; white-space: nowrap;
            border-bottom: 2px solid var(--brand-soft);
        }
        tbody tr            { border-bottom: 1px solid var(--line); transition: background .12s; }
        tbody tr:last-child { border: none; }
        tbody tr:hover      { background: var(--brand-ultra); }
        tbody td            { padding: 11px 14px; vertical-align: middle; }
        .r-ok  td  { background: var(--ok-bg);   }
        .r-warn td { background: var(--warn-bg); }
        .r-err  td { background: var(--err-bg);  }
        .td-name   { font-weight: 700; color: var(--text-h); }
        .td-mono   { font-family: var(--mono); font-size: .74rem; }
        .badge {
            display: inline-block; padding: 3px 11px; border-radius: 30px; font-size: .68rem; font-weight: 700;
            letter-spacing: .2px; white-space: nowrap;
        }
        .b-ok   { background: var(--ok-bg);   color: var(--ok);   border: 1px solid var(--ok-line); }
        .b-warn { background: var(--warn-bg); color: var(--warn); border: 1px solid var(--warn-line); }
        .b-err  { background: var(--err-bg);  color: var(--err);  border: 1px solid var(--err-line); }

        /* ---- Progress bar --------------------------------------------- */
        .pw { display: flex; align-items: center; gap: 9px; }
        .pt { flex: 1; height: 9px; background: #ECE7F2; border-radius: 8px; overflow: hidden; box-shadow: inset 0 1px 2px rgba(0,0,0,.06); }
        .pf { height: 100%; border-radius: 8px; transition: width .7s cubic-bezier(.22,.9,.34,1); }
        .pp { font-weight: 700; font-size: .76rem; min-width: 38px; text-align: right; }

        code { font-family: var(--mono); font-size: .74rem; background: var(--brand-ultra); padding: 2px 6px; border-radius: 5px; color: var(--brand-dark); word-break: break-all; }

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
        <div>
            <div class="hdr-eyebrow">Citrix Workspace Automation Suite</div>
            <div class="hdr-title">RDS License Usage Monitoring</div>
        </div>
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

function Save-SingleServerReport {
    param([PSCustomObject]$Result)

    $cDT            = Get-Date -Format "yyyyMMdd_HHmmss"
    $SafeServerName = ($Result.Server -replace '[^a-zA-Z0-9\-\.]', '_')
    $OutputDir      = $ScriptDir + "Output\"
    $htmlOutputFile = $OutputDir + "RDSLicenseMonitoring_${SafeServerName}_$cDT.html"

    try {
        if (-not (Test-Path $OutputDir)) {
            New-Item -Path $OutputDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
            Write-Log "Output folder created: $OutputDir" "SUCCESS"
        }

        $HtmlContent  = Get-EmbeddedTemplate
        $GenDate      = Get-Date -Format "dddd, dd MMMM yyyy HH:mm:ss"
        $WarnPctLabel = "$WarningThresholdPct%"
        $CritPctLabel = "$CriticalThresholdPct%"
        $HeadroomPct  = if ($Result.Installed -gt 0) { [math]::Round(($Result.Available / $Result.Installed) * 100, 1) } else { 0 }
        $WarnCardSub  = if ($Result.UsagePct -ge $WarningThresholdPct)  { "BREACHED" } else { "Not reached" }
        $CritCardSub  = if ($Result.UsagePct -ge $CriticalThresholdPct) { "BREACHED" } else { "Not reached" }

        $errJsonItems = $Result.Errors | ForEach-Object { '"' + (EscapeJson $_) + '"' }
        $errJson      = '[' + ($errJsonItems -join ',') + ']'

        $JsonBlock = @"
    <script>
    window.REPORT_DATA = {
      "GenDate"           : "$(EscapeJson $GenDate)",
      "LicenseServerFQDN" : "$(EscapeJson $Result.Server)",
      "LicServerOSVersion": "$(EscapeJson $Result.OSVersion)",
      "Compliance"        : "$(EscapeJson $Result.Compliance)",
      "UsagePct"          : $($Result.UsagePct),
      "Issued"            : $($Result.Issued),
      "Installed"         : $($Result.Installed),
      "Available"         : $($Result.Available),
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
        $HtmlContent = $HtmlContent.Replace('</body>', ($JsonBlock + "`n</body>"))
        $HtmlContent | Out-File -FilePath $htmlOutputFile -Encoding UTF8 -ErrorAction Stop
        Write-Log "Report saved: $htmlOutputFile" "SUCCESS"
    } catch {
        Write-Log "FATAL: Could not save single-server report: $($_.Exception.Message)" "ERROR"
    }
}


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
            --brand        : rgba(216,0,116,1);
            --brand-dark   : rgba(160,0,85,1);
            --brand-deeper : rgba(110,0,58,1);
            --brand-ultra  : rgba(216,0,116,0.04);
            --brand-soft   : rgba(216,0,116,0.09);
            --ok           : #0A7A09;   --ok-bg   : #F0FBF0;   --ok-line   : #CDEFC9;
            --warn         : #B05E00;   --warn-bg : #FFF8EC;   --warn-line : #F6E2B8;
            --err          : #BF0E1A;   --err-bg  : #FFF3F4;   --err-line  : #F6C7CB;
            --text-h       : #15121A;
            --text-b       : #322B3B;
            --text-m       : #6B6378;
            --text-l       : #9A93A6;
            --line         : #E9E5F0;
            --surface      : #FFFFFF;
            --canvas-top   : #F3EEF6;
            --canvas-bot   : #ECE7F2;
            --font         : 'Segoe UI','Helvetica Neue',Arial,sans-serif;
            --max-w        : 1380px;
            --r            : 14px;
            --r-sm         : 10px;
            --sh           : 0 1px 2px rgba(40,0,25,.04), 0 6px 20px rgba(40,0,25,.06);
            --sh-lg        : 0 10px 30px rgba(40,0,25,.12);
        }
        *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: var(--font); font-size: 13.5px; color: var(--text-b); line-height: 1.6;
            background: linear-gradient(165deg, var(--canvas-top) 0%, var(--canvas-bot) 55%, var(--canvas-bot) 100%);
            min-height: 100vh;
        }
        .rpt-hdr {
            background: linear-gradient(120deg, var(--brand) 0%, var(--brand-dark) 78%, var(--brand-deeper) 100%);
            color: #fff; position: relative; overflow: hidden;
        }
        .rpt-hdr::before {
            content: ''; position: absolute; inset: 0;
            background:
                radial-gradient(circle at 88% -10%, rgba(255,255,255,.16) 0%, rgba(255,255,255,0) 42%),
                repeating-linear-gradient(-45deg, rgba(255,255,255,0) 0px, rgba(255,255,255,0) 18px, rgba(255,255,255,.025) 18px, rgba(255,255,255,.025) 20px);
        }
        .rpt-hdr::after {
            content: ''; position: absolute; bottom: 0; left: 0; right: 0; height: 3px;
            background: linear-gradient(90deg, rgba(255,255,255,.55), rgba(255,255,255,.05) 45%, rgba(255,255,255,.05) 55%, rgba(255,255,255,.55));
        }
        .hdr-inner {
            position: relative; z-index: 1; padding: 22px 40px 16px; display: flex; align-items: baseline;
            justify-content: space-between; gap: 16px; flex-wrap: wrap;
        }
        .hdr-eyebrow {
            font-size: .68rem; font-weight: 700; letter-spacing: 1.6px; text-transform: uppercase;
            color: rgba(255,255,255,.62); margin-bottom: 5px;
        }
        .hdr-title { font-size: 1.82rem; font-weight: 800; letter-spacing: -.4px; line-height: 1.15; }
        .hdr-gen   { font-size: .75rem; color: rgba(255,255,255,.78); white-space: nowrap; }
        .hdr-strip {
            position: relative; z-index: 1; display: flex; align-items: center; justify-content: space-between;
            background: rgba(15,0,10,.20); padding: 10px 42px; font-size: .76rem; color: rgba(255,255,255,.90);
            gap: 12px; flex-wrap: wrap; border-top: 1px solid rgba(255,255,255,.08);
        }
        .status-pill {
            padding: 5px 18px; border-radius: 30px; font-weight: 800; font-size: .72rem; letter-spacing: .4px;
            white-space: nowrap; box-shadow: 0 2px 10px rgba(0,0,0,.16);
        }
        .pill-ok   { background: linear-gradient(135deg, #1C9A1A, #0A7A09); color: #fff; }
        .pill-warn { background: linear-gradient(135deg, #D67A00, #B05E00); color: #fff; }
        .pill-err  { background: linear-gradient(135deg, #DC2030, #BF0E1A); color: #fff; }
        .rpt-body { max-width: var(--max-w); margin: 28px auto; padding: 0 26px 56px; }
        .card-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 10px; margin-bottom: 18px; align-items: stretch; }
        .card {
            background: var(--surface); border-radius: var(--r-sm); padding: 14px 16px 12px; box-shadow: var(--sh);
            border-top: 3px solid var(--brand); position: relative; overflow: hidden; min-width: 0;
            transition: transform .16s ease, box-shadow .16s ease;
        }
        .card:hover { transform: translateY(-3px); box-shadow: var(--sh-lg); }
        .card .c-lbl { font-size: .6rem; font-weight: 700; text-transform: uppercase; letter-spacing: .6px; color: var(--text-l); margin-bottom: 5px; }
        .card .c-val { font-size: 1.15rem; font-weight: 800; color: var(--text-h); line-height: 1.25; }
        .sec { background: var(--surface); border-radius: var(--r); box-shadow: var(--sh); margin-bottom: 16px; overflow: hidden; border: 1px solid var(--line); }
        .sec-hdr {
            display: flex; align-items: center; justify-content: space-between; padding: 13px 20px;
            background: linear-gradient(120deg, var(--brand) 0%, var(--brand-dark) 100%); color: #fff;
            font-weight: 700; font-size: .88rem; letter-spacing: .1px;
        }
        .tbl-wrap { overflow-x: auto; }
        table     { width: 100%; border-collapse: collapse; font-size: .81rem; }
        thead th  {
            background: var(--brand-ultra); color: var(--brand-dark); padding: 11px 14px; text-align: left;
            font-weight: 700; font-size: .71rem; letter-spacing: .3px; text-transform: uppercase; white-space: nowrap;
            border-bottom: 2px solid var(--brand-soft);
        }
        tbody tr            { border-bottom: 1px solid var(--line); transition: background .12s; }
        tbody tr:last-child { border: none; }
        tbody tr:hover      { background: var(--brand-ultra); }
        tbody td            { padding: 11px 14px; vertical-align: middle; }
        .r-ok  td  { background: var(--ok-bg);   }
        .r-warn td { background: var(--warn-bg); }
        .r-err  td { background: var(--err-bg);  }
        .td-name   { font-weight: 700; color: var(--text-h); }
        .pw { display: flex; align-items: center; gap: 9px; }
        .pt { flex: 1; height: 9px; background: #ECE7F2; border-radius: 8px; overflow: hidden; box-shadow: inset 0 1px 2px rgba(0,0,0,.06); }
        .pf { height: 100%; border-radius: 8px; transition: width .7s cubic-bezier(.22,.9,.34,1); }
        .pp { font-weight: 700; font-size: .76rem; min-width: 38px; text-align: right; }
        .badge { display: inline-block; padding: 3px 11px; border-radius: 30px; font-size: .68rem; font-weight: 700; }
        .b-ok   { background: var(--ok-bg);   color: var(--ok);   border: 1px solid var(--ok-line); }
        .b-warn { background: var(--warn-bg); color: var(--warn); border: 1px solid var(--warn-line); }
        .b-err  { background: var(--err-bg);  color: var(--err);  border: 1px solid var(--err-line); }
    </style>
</head>
<body>

<div class="rpt-hdr">
    <div class="hdr-inner">
        <div>
            <div class="hdr-eyebrow">Citrix Workspace Automation Suite &middot; Combined Summary</div>
            <div class="hdr-title">RDS License Usage Monitoring</div>
        </div>
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
    $combinedFile = ($ScriptDir + "Output\") + "RDSLicenseMonitoring_Combined_$cDT.html"

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
    $ErrorLog  = [System.Collections.Generic.List[string]]::new()
    $KeyPacks  = @()
    $Issued    = 0
    $Available = 0
    $Installed = 0

    Write-Log "License Server: $Server"

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
    if ($KeyPacks.Count -eq 0) {
        $ErrorLog.Add("Query to [$Server] returned zero license key packs. Verify this server has the RD Licensing role installed, that key packs are activated, and that the HPSA service account has WMI/CIM access to this host.")
        Write-Log "WARNING: Zero key packs returned from $Server" "WARN"
    }

    # Windows version of the license server 
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

        $SeenSignatures     = @{}
        $DedupedPacks       = [System.Collections.Generic.List[object]]::new()
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

    if ($ErrorLog.Count -gt 0) {
        Write-Log "$($ErrorLog.Count) error(s)/warning(s) were captured for this server:" "WARN"
        foreach ($e in $ErrorLog) { Write-Log "  - $e" "WARN" }
    }
    Write-Log "=== Complete for [$Server] | $Compliance ($UsagePct%) ==="

    return [PSCustomObject]@{
        Server      = $Server
        OSVersion   = $LicServerOSVersion
        Installed   = $Installed
        Issued      = $Issued
        Available   = $Available
        UsagePct    = $UsagePct
        Compliance  = $Compliance
        Errors      = $ErrorLog
    }
}

# ============================================================================
# MAIN  - parse server list and process each server independently
# ============================================================================
$ServerList = @(
    $LicenseServerFQDN -split ';' |
        ForEach-Object { $_.Trim() } |
        Where-Object   { $_ -ne '' }
)

if ($ServerList.Count -eq 0) {
    Write-Log "FATAL: LicenseServerFQDN did not contain any valid server name after parsing." "ERROR"
    exit 3
}

Write-Log "=== RDS License Monitoring | Citrix Workspace Automation Suite ==="
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
Write-Log "=== Batch Complete | $($ServerResults.Count) succeeded, $($FailedServers.Count) failed (of $($ServerList.Count) total) ===" "SUCCESS"
if ($FailedServers.Count -gt 0) {
    Write-Log "Failed server(s): $($FailedServers -join ', ')" "ERROR"
}

if ($ServerResults.Count -eq 1) {
    Save-SingleServerReport -Result $ServerResults[0]
} elseif ($ServerResults.Count -gt 1) {
    Build-CombinedReport -Results $ServerResults
}


if ($FailedServers.Count -gt 0) {
    exit 3
} else {
    exit 0
}
