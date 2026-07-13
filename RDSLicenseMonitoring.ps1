############################################################################################################
# Script Name  : RDSLicenseMonitoring.ps1
# Description  : RDS License Usage Monitoring | Citrix Workspace Automation Suite
############################################################################################################

#region PARAMETERS
param(
    # One server FQDN, or several separated by semicolons (e.g. "srv1;srv2;srv3").
    [Parameter(Mandatory = $true)]
    [string]$LicenseServerFQDN
)
#endregion PARAMETERS


#region CONFIG
$ErrorActionPreference = "Continue"   # script level: HPSA sees all console output

$OutputDir            = "C:\Scripts\RDL\Output\"
$WarningThresholdPct  = 80
$CriticalThresholdPct = 95
$ScriptVersion        = "V1.6.0"
#endregion CONFIG


#region HELPERS

# Writes a timestamped, colour-coded line to the console (visible to HPSA).
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Msg,
        [ValidateSet("INFO","SUCCESS","WARN","ERROR")][string]$Lvl = "INFO"
    )
    try {
        $col = switch ($Lvl) {
            "SUCCESS" { "Green"  }
            "WARN"    { "Yellow" }
            "ERROR"   { "Red"    }
            default   { "Cyan"   }
        }
        Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][$Lvl] $Msg" -ForegroundColor $col
    } catch {
        # Logging must never break the run -- fall back to a plain, uncoloured line.
        Write-Host "[$Lvl] $Msg"
    }
}

# Escapes a string for safe embedding inside the JSON block written into the HTML report.
function EscapeJson {
    param([string]$s)
    if ([string]::IsNullOrEmpty($s)) { return "" }
    try {
        # Backslash must be escaped first, before any other replace below.
        $s = $s.Replace('\', '\\')
        $s = $s -replace '"',    '\"'  `
                -replace "`r`n", '\n'  `
                -replace "`n",   '\n'  `
                -replace "`t",   '\t'
        return $s
    } catch {
        Write-Log "EscapeJson failed for input value -- returning empty string." "WARN"
        return ""
    }
}

# Maps a usage percentage to a compliance state using the configured thresholds.
function Get-Compliance {
    param([double]$Pct)
    if ($Pct -ge $CriticalThresholdPct) { return "CRITICAL"  }
    if ($Pct -ge $WarningThresholdPct)  { return "WARNING"   }
    return "COMPLIANT"
}

# Converts a raw WMI datetime string (e.g. license expiry) to UTC, or $null if it never expires.
function ConvertFrom-WmiExpiry {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    try {
        # WMI datetime format: yyyyMMddHHmmss.ffffff+UUU -- only the first 14 chars are needed.
        $datePart = $Raw.Substring(0, 14)
        $dt = [datetime]::ParseExact(
                  $datePart,
                  'yyyyMMddHHmmss',
                  [System.Globalization.CultureInfo]::InvariantCulture,
                  [System.Globalization.DateTimeStyles]::AssumeUniversal)
        # Year <= 1970 is the WMI "Never expires" sentinel value.
        if ($dt.Year -le 1970) { return $null }
        return $dt.ToUniversalTime()
    } catch {
        # Unparseable date -- treat as non-expiring to avoid false exclusions.
        return $null
    }
}

#endregion HELPERS


#region DATA COLLECTION

function Get-KeyPacks {
    param(
        [Parameter(Mandatory)][string]$Server,
        [System.Collections.Generic.List[string]]$ErrorLog
    )

    # Attempt 1: WMI (fastest path)
    try {
        $packs = @(Get-WmiObject -Class "Win32_TSLicenseKeyPack" `
                       -ComputerName $Server -ErrorAction Stop)
        Write-Log "  WMI OK -- $($packs.Count) key pack(s)" "SUCCESS"
        return $packs
    } catch {
        Write-Log "  WMI failed: $($_.Exception.Message) -- retrying via CIM..." "WARN"
    }

    # Attempt 2: CIM over DCOM (fallback)
    $cimSess = $null
    try {
        $cimOpts = New-CimSessionOption -Protocol Dcom
        $cimSess = New-CimSession -ComputerName $Server `
                       -SessionOption $cimOpts -ErrorAction Stop
        $packs   = @(Get-CimInstance -CimSession $cimSess `
                         -ClassName "Win32_TSLicenseKeyPack" -ErrorAction Stop)
        Write-Log "  CIM OK -- $($packs.Count) key pack(s)" "SUCCESS"
        return $packs
    } catch {
        $msg = "[$Server] unreachable via WMI and CIM: $($_.Exception.Message)"
        $ErrorLog.Add($msg)
        Write-Log "  $msg" "ERROR"
        return @()
    } finally {
        if ($null -ne $cimSess) {
            try { Remove-CimSession $cimSess -ErrorAction SilentlyContinue } catch {}
        }
    }
}
function Get-OSVersion {
    param(
        [Parameter(Mandatory)][string]$Server,
        [System.Collections.Generic.List[string]]$ErrorLog
    )

    # Attempt 1: WMI
    try {
        $os = Get-WmiObject -Class "Win32_OperatingSystem" `
                  -ComputerName $Server -ErrorAction Stop
        return "$($os.Caption)".Trim()
    } catch {
        Write-Log "  WMI OS query failed: $($_.Exception.Message) -- retrying via CIM..." "WARN"
    }

    # Attempt 2: CIM over DCOM
    $cimSess = $null
    try {
        $cimOpts = New-CimSessionOption -Protocol Dcom
        $cimSess = New-CimSession -ComputerName $Server `
                       -SessionOption $cimOpts -ErrorAction Stop
        $os      = Get-CimInstance -CimSession $cimSess `
                       -ClassName "Win32_OperatingSystem" -ErrorAction Stop
        return "$($os.Caption)".Trim()
    } catch {
        $msg = "Could not retrieve OS version for [$Server]: $($_.Exception.Message)"
        $ErrorLog.Add($msg)
        Write-Log "  $msg" "WARN"
        return "N/A"
    } finally {
        if ($null -ne $cimSess) {
            try { Remove-CimSession $cimSess -ErrorAction SilentlyContinue } catch {}
        }
    }
}
function Invoke-LicenseServerReport {
    param([Parameter(Mandatory)][string]$Server)

    Write-Log "--- [$Server] Starting ---"
    $ErrorLog = [System.Collections.Generic.List[string]]::new()

    # 1. Query key packs
    $KeyPacks = Get-KeyPacks -Server $Server -ErrorLog $ErrorLog

    if ($KeyPacks.Count -eq 0) {
        $ErrorLog.Add("[$Server] Zero key packs returned. Verify the RD Licensing role is installed, packs are activated, and the service account has WMI/CIM access.")
        Write-Log "  Zero key packs returned from [$Server]" "WARN"
    }

    # 2. Query OS version (runs regardless of key pack success)
    $OSVersion = Get-OSVersion -Server $Server -ErrorLog $ErrorLog

    # 3. Filter key packs and calculate CAL totals
    [int64]$Installed      = 0
    [int64]$Issued         = 0
    [int64]$Available      = 0
    $UnlimitedCount        = 0
    $ExpiredCount          = 0
    $DuplicateCount        = 0
    $ActivePacks           = [System.Collections.Generic.List[object]]::new()

    try {
        $NowUtc         = [datetime]::UtcNow
        $SeenSignatures = [System.Collections.Generic.HashSet[string]]::new(
                              [System.StringComparer]::OrdinalIgnoreCase)

        foreach ($pack in $KeyPacks) {

            # Step 1 -- exclude unlimited / built-in packs
            $tl = [int64]$pack.TotalLicenses
            if ($tl -eq -1 -or $tl -eq 4294967295) {
                $UnlimitedCount++
                continue
            }

            # Step 2 -- exclude explicitly expired (KeyPackType = 6)
            if ([int]$pack.KeyPackType -eq 6) {
                $ExpiredCount++
                Write-Log "  [SKIP-EXPIRED-TYPE] $($pack.Description)" "WARN"
                continue
            }

            # Step 3 -- exclude expired by ExpirationDate
            $expiry = ConvertFrom-WmiExpiry -Raw ([string]$pack.ExpirationDate)
            if ($null -ne $expiry -and $expiry -lt $NowUtc) {
                $ExpiredCount++
                Write-Log ("  [SKIP-EXPIRED-DATE] {0} | Expiry={1:yyyy-MM-dd}" -f `
                    $pack.Description, $expiry) "WARN"
                continue
            }

            # Step 4 -- deduplicate on Description|Version|Total|Issued
            $sig = '{0}|{1}|{2}|{3}' -f `
                $pack.Description, $pack.ProductVersion,
                $pack.TotalLicenses, $pack.IssuedLicenses
            if (-not $SeenSignatures.Add($sig)) {
                $DuplicateCount++
                Write-Log "  [SKIP-DUPLICATE] $($pack.Description)" "WARN"
                continue
            }

            $ActivePacks.Add($pack)
        }

        # Sum totals from active packs only
        foreach ($pack in $ActivePacks) {
            $Installed += [int64]$pack.TotalLicenses
            $Issued    += [int64]$pack.IssuedLicenses
            $Available += [int64]$pack.AvailableLicenses
        }

        # Audit log -- one line per active pack that contributes to totals
        foreach ($pack in $ActivePacks) {
            $expStr = if ([string]::IsNullOrWhiteSpace([string]$pack.ExpirationDate)) {
                          "Never"
                      } else {
                          $dt = ConvertFrom-WmiExpiry -Raw ([string]$pack.ExpirationDate)
                          if ($null -ne $dt) { $dt.ToString("yyyy-MM-dd") } else { "Never" }
                      }
            Write-Log ("  [ACTIVE] {0} | Total={1} | Issued={2} | Available={3} | Expiry={4}" -f `
                $pack.Description,
                [int64]$pack.TotalLicenses,
                [int64]$pack.IssuedLicenses,
                [int64]$pack.AvailableLicenses,
                $expStr) "SUCCESS"
        }

        Write-Log ("  Filter: Raw={0} | Unlimited={1} | Expired={2} | Duplicate={3} | Active={4}" -f `
            $KeyPacks.Count, $UnlimitedCount, $ExpiredCount, $DuplicateCount, $ActivePacks.Count) "INFO"
        Write-Log ("  Totals: Installed={0} | Issued={1} | Available={2}" -f `
            $Installed, $Issued, $Available) "SUCCESS"

    } catch {
        $msg = "CAL calculation error for [$Server]: $($_.Exception.Message)"
        $ErrorLog.Add($msg)
        Write-Log "  $msg" "ERROR"
        $Installed = 0; $Issued = 0; $Available = 0
    }

    # 4. Compliance
    $UsagePct   = if ($Installed -gt 0) {
                      [math]::Round(($Issued / $Installed) * 100, 1)
                  } else { 0 }
    $Compliance = Get-Compliance -Pct $UsagePct

    Write-Log ("  Result: {0}/{1} ({2}%) => {3}" -f $Issued, $Installed, $UsagePct, $Compliance)
    if ($ErrorLog.Count -gt 0) {
        Write-Log "  $($ErrorLog.Count) issue(s) captured for [$Server]" "WARN"
    }
    Write-Log "--- [$Server] Complete ---"

    return [PSCustomObject]@{
        Server     = $Server
        OSVersion  = $OSVersion
        Installed  = [int]$Installed
        Issued     = [int]$Issued
        Available  = [int]$Available
        UsagePct   = $UsagePct
        Compliance = $Compliance
        Errors     = $ErrorLog
    }
}

#endregion DATA COLLECTION


#region HTML TEMPLATE

function Get-UnifiedTemplate {
    return @'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8"/>
    <meta name="viewport" content="width=device-width,initial-scale=1.0"/>
    <title>RDS License Usage Report </title>
    <style>
        /* ---- Design tokens ------------------------------------------------ */
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
            --max-w        : 1380px;
            --r            : 14px;
            --r-sm         : 10px;
            --sh           : 0 1px 2px rgba(40,0,25,.04), 0 6px 20px rgba(40,0,25,.06);
            --sh-lg        : 0 10px 30px rgba(40,0,25,.12);
        }
        *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
        html { scroll-behavior: smooth; }
        body {
            font-family: var(--font); font-size: 13.5px; color: var(--text-b); line-height: 1.6;
            background: linear-gradient(165deg, var(--canvas-top) 0%, var(--canvas-bot) 55%, var(--canvas-bot) 100%);
            min-height: 100vh;
        }

        /* ---- Header ------------------------------------------------------- */
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
            position: relative; z-index: 1; padding: 10px 28px 7px;
            display: flex; align-items: baseline; justify-content: space-between; gap: 16px; flex-wrap: wrap;
        }
        .hdr-title { font-size: 1.12rem; font-weight: 800; letter-spacing: -.3px; line-height: 1.15; }
        .hdr-gen   { font-size: .62rem; color: rgba(255,255,255,.78); white-space: nowrap; }
        .hdr-strip {
            position: relative; z-index: 1; display: flex; align-items: center; justify-content: space-between;
            background: rgba(15,0,10,.20); padding: 5px 28px; font-size: .66rem;
            color: rgba(255,255,255,.90); gap: 12px; flex-wrap: wrap;
            border-top: 1px solid rgba(255,255,255,.08);
        }
        .hdr-strip-left { display: flex; align-items: center; gap: 14px; flex-wrap: wrap; }
        .hdr-strip-left span { display: flex; align-items: center; gap: 5px; }
        .hdr-strip-left strong { color: #fff; font-weight: 700; }
        .status-pill {
            padding: 3px 13px; border-radius: 30px; font-weight: 800; font-size: .62rem;
            letter-spacing: .3px; white-space: nowrap; box-shadow: 0 2px 10px rgba(0,0,0,.16);
        }
        .pill-ok   { background: linear-gradient(135deg, #1C9A1A, #0A7A09); color: #fff; }
        .pill-warn { background: linear-gradient(135deg, #D67A00, #B05E00); color: #fff; }
        .pill-err  { background: linear-gradient(135deg, #DC2030, #BF0E1A); color: #fff; }

        /* ---- Body --------------------------------------------------------- */
        .rpt-body { max-width: var(--max-w); margin: 28px auto; padding: 0 26px 56px; }

        /* ---- KPI cards (one 4-column layout, used for single or multi server) */
        .card-grid { display: grid; gap: 10px; margin-bottom: 18px; align-items: stretch; grid-template-columns: repeat(4, 1fr); }
        .card {
            background: var(--surface); border-radius: var(--r-sm); padding: 13px 14px 11px;
            box-shadow: var(--sh); border-top: 3px solid var(--brand);
            position: relative; overflow: hidden; min-width: 0;
            transition: transform .16s ease, box-shadow .16s ease;
        }
        .card:hover  { transform: translateY(-3px); box-shadow: var(--sh-lg); }
        .card::after {
            content: attr(data-ico); position: absolute; right: 8px; top: 8px;
            font-size: 1.5rem; opacity: .06;
        }
        .card .c-lbl {
            font-size: .58rem; font-weight: 700; text-transform: uppercase; letter-spacing: .6px;
            color: var(--text-l); margin-bottom: 5px; white-space: nowrap;
            overflow: hidden; text-overflow: ellipsis;
        }
        .card .c-val {
            font-family: var(--font-num); font-size: .92rem; font-weight: 800;
            color: var(--text-h); line-height: 1.25; white-space: nowrap;
            overflow: hidden; text-overflow: ellipsis;
        }
        .card .c-sub {
            font-size: .64rem; color: var(--text-m); margin-top: 3px;
            white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
        }

        /* ---- Section / table ---------------------------------------------- */
        .sec { background: var(--surface); border-radius: var(--r); box-shadow: var(--sh); margin-bottom: 16px; overflow: hidden; border: 1px solid var(--line); }
        .sec-hdr {
            display: flex; align-items: center; justify-content: space-between; padding: 13px 20px;
            background: linear-gradient(120deg, var(--brand) 0%, var(--brand-dark) 100%);
            color: #fff; cursor: pointer; user-select: none; transition: filter .18s;
        }
        .sec-hdr:hover      { filter: brightness(1.06); }
        .sec-hdr-l          { display: flex; align-items: center; gap: 9px; font-weight: 700; font-size: .88rem; }
        .sec-hdr-r          { display: flex; align-items: center; gap: 8px; font-size: .74rem; opacity: .9; }
        .chev               { transition: transform .24s; display: inline-block; font-size: .7rem; }
        .sec-body           { overflow: hidden; }
        .sec-body.collapsed { display: none; }
        .tbl-wrap { overflow-x: auto; }
        table     { width: 100%; border-collapse: collapse; font-size: .81rem; }
        thead th  {
            background: var(--brand-ultra); color: var(--brand-dark); padding: 11px 14px;
            text-align: left; font-weight: 700; font-size: .71rem; letter-spacing: .3px;
            text-transform: uppercase; white-space: nowrap; border-bottom: 2px solid var(--brand-soft);
        }
        tbody tr            { border-bottom: 1px solid var(--line); transition: background .12s; }
        tbody tr:last-child { border: none; }
        tbody tr:hover      { background: var(--brand-ultra); }
        tbody td            { padding: 11px 14px; vertical-align: middle; }
        .r-ok  td  { background: var(--ok-bg);   }
        .r-warn td { background: var(--warn-bg); }
        .r-err  td { background: var(--err-bg);  }
        .td-name   { font-weight: 700; color: var(--text-h); }

        /* ---- Progress bar ------------------------------------------------- */
        .pw { display: flex; align-items: center; gap: 9px; }
        .pt { flex: 1; height: 9px; background: #ECE7F2; border-radius: 8px; overflow: hidden; box-shadow: inset 0 1px 2px rgba(0,0,0,.06); }
        .pf { height: 100%; border-radius: 8px; transition: width .7s cubic-bezier(.22,.9,.34,1); }
        .pp { font-weight: 700; font-size: .76rem; min-width: 38px; text-align: right; }
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
            <div class="hdr-title">RDS License Usage Monitoring</div>
        </div>
        <div class="hdr-gen">&#128336; Generated: <span id="gen-date">-</span></div>
    </div>
    <div class="hdr-strip">
        <div class="hdr-strip-left" id="hdr-strip-left">-</div>
        <span class="status-pill" id="status-pill">-</span>
    </div>
</div>

<div class="rpt-body">

    <!-- KPI cards -- same 4-column layout for 1 server or many -->
    <div class="card-grid" id="card-grid"></div>

    <!-- License summary table -->
    <div class="sec" id="s-kp">
        <div class="sec-hdr" onclick="tog('kp')">
            <span class="sec-hdr-l" id="sec-hdr-label">&#128220; License Summary</span>
            <span class="sec-hdr-r"><span class="chev" id="chev-kp">&#9660;</span></span>
        </div>
        <div class="sec-body" id="b-kp">
            <div class="tbl-wrap">
                <table>
                    <thead>
                        <tr>
                            <th>Server Name</th><th>OS Version</th>
                            <th>Total CALs</th><th>Issued</th><th>Available</th><th>Utilisation</th>
                        </tr>
                    </thead>
                    <tbody id="kp-tbody">
                        <tr><td colspan="6" style="text-align:center;padding:20px;color:#8A8A9A;">Awaiting data...</td></tr>
                    </tbody>
                </table>
            </div>
        </div>
    </div>

</div>

<script>
(function () {

    var colorMap = { COMPLIANT: '#0A7A09', WARNING: '#B05E00', CRITICAL: '#BF0E1A' };
    var pillMap  = { COMPLIANT: 'pill-ok', WARNING:  'pill-warn', CRITICAL: 'pill-err' };

    function set(id, txt) {
        var el = document.getElementById(id); if (el) el.textContent = txt;
    }
    function setHtml(id, html) {
        var el = document.getElementById(id); if (el) el.innerHTML = html;
    }

    /* Progress bar cell */
    function progCell(pct, col) {
        return "<div class='pw'><div class='pt'><div class='pf' style='width:" + Math.min(pct,100) + "%;background:" + col + ";'></div></div>" +
               "<div class='pp' style='color:" + col + ";'>" + pct + "%</div></div>";
    }

    /* One table row */
    function makeRow(server, osver, installed, issued, available, usagePct, warnPct, critPct) {
        var col    = usagePct >= critPct ? '#BF0E1A' : usagePct >= warnPct ? '#B05E00' : '#0A7A09';
        var rowCls = usagePct >= critPct ? 'r-err'   : usagePct >= warnPct ? 'r-warn'  : 'r-ok';
        return "<tr class='" + rowCls + "'>" +
               "<td class='td-name'>" + server    + "</td>" +
               "<td>" + osver + "</td>" +
               "<td style='text-align:center;font-weight:700;'>" + installed + "</td>" +
               "<td style='text-align:center;font-weight:700;color:" + col + ";'>" + issued + "</td>" +
               "<td style='text-align:center;'>" + available + "</td>" +
               "<td>" + progCell(usagePct, col) + "</td>" +
               "</tr>";
    }

    /* Single render function -- used for one server or many, same layout */
    function renderReport(d) {
        var overallColor = colorMap[d.OverallState] || '#0A7A09';
        var isSingle      = d.ServerCount === 1;

        /* Header strip -- one format, server count just changes the numbers */
        set('gen-date', d.GenDate);
        setHtml('hdr-strip-left',
            "<span>&#128421; Servers: <strong>" + d.ServerCount + "</strong></span>" +
            "<span>&#128202; Total CALs: <strong>" + d.TotalInstalled + "</strong></span>" +
            "<span>&#128273; In Use: <strong>" + d.TotalIssued + " (" + d.OverallPct + "%)</strong></span>"
        );
        var pill = document.getElementById('status-pill');
        pill.textContent = d.OverallState + ' \u2013 ' + d.OverallPct + '% Utilisation';
        pill.className   = 'status-pill ' + (pillMap[d.OverallState] || 'pill-ok');

        /* KPI cards -- same 4-column set for 1 server or many */
        var grid = document.getElementById('card-grid');
        grid.innerHTML =
            "<div class='card' data-ico='&#128421;'><div class='c-lbl'>" + (isSingle ? 'License Server' : 'License Servers') + "</div>" +
                "<div class='c-val'>" + (isSingle ? d.Rows[0].Server : d.ServerCount) + "</div>" +
                "<div class='c-sub'>" + (isSingle ? d.Rows[0].OSVersion : 'Queried this run') + "</div></div>" +
            "<div class='card' data-ico='&#128202;'><div class='c-lbl'>Total CALs</div>" +
                "<div class='c-val'>" + d.TotalInstalled + "</div></div>" +
            "<div class='card' data-ico='&#128273;'><div class='c-lbl'>CALs In Use</div>" +
                "<div class='c-val' style='color:" + overallColor + ";'>" + d.TotalIssued + "</div>" +
                "<div class='c-sub'>" + d.OverallPct + "% utilisation</div></div>" +
            "<div class='card' data-ico='&#9989;'><div class='c-lbl'>CALs Available</div>" +
                "<div class='c-val'>" + d.TotalAvailable + "</div></div>";

        /* Section header & table -- one row per server, sorted by usage desc */
        set('sec-hdr-label', '\uD83D\uDCDC License Summary \u2013 ' + d.ServerCount + ' server(s)');
        var sorted = d.Rows.slice().sort(function(a,b){ return b.UsagePct - a.UsagePct; });
        var body = '';
        sorted.forEach(function(r) {
            body += makeRow(r.Server, r.OSVersion, r.Installed, r.Issued, r.Available,
                            r.UsagePct, d.WarnThresholdPct, d.CritThresholdPct);
        });
        setHtml('kp-tbody', body ||
            "<tr><td colspan='6' style='text-align:center;padding:20px;color:#8A8A9A;'>No server data available</td></tr>"
        );

        /* Any collection issues are kept in the data for troubleshooting but
           are not shown on the report itself -- check the browser console. */
        if (d.Errors && d.Errors.length > 0 && window.console && console.warn) {
            console.warn(d.Errors.length + ' issue(s) captured during collection:', d.Errors);
        }
    }

    /* Entry point */
    function init() {
        if (window.REPORT_DATA) { renderReport(window.REPORT_DATA); }
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

}());
</script>
</body>
</html>
'@
}

#endregion HTML TEMPLATE


#region REPORT WRITERS

function Save-Report {
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[object]]$Results
    )

    if ($Results.Count -eq 0) {
        Write-Log "Save-Report: no results to write -- report skipped." "WARN"
        return
    }

    $cDT = Get-Date -Format "yyyyMMdd_HHmmss"

    try {
        $Html    = Get-UnifiedTemplate
        $GenDate = Get-Date -Format "dddd, dd MMMM yyyy HH:mm:ss"

        if ($Results.Count -eq 1) {
            $SafeName   = $Results[0].Server -replace '[^a-zA-Z0-9\-\.]', '_'
            $OutputFile = Join-Path $OutputDir "RDSLicenseMonitoring_${SafeName}_${cDT}.html"
        } else {
            $OutputFile = Join-Path $OutputDir "RDSLicenseMonitoring_Combined_${cDT}.html"
        }

        # Aggregate totals -- same calculation whether there is 1 row or many
        $TotalInstalled = [int]($Results | Measure-Object Installed -Sum).Sum
        $TotalIssued    = [int]($Results | Measure-Object Issued    -Sum).Sum
        $TotalAvailable = [int]($Results | Measure-Object Available -Sum).Sum
        $OverallPct     = if ($TotalInstalled -gt 0) {
                              [math]::Round(($TotalIssued / $TotalInstalled) * 100, 1)
                          } else { 0 }
        $OverallState   = Get-Compliance -Pct $OverallPct

        # One row per server (works for a single server too)
        $rowsJson = '[' + (
            @($Results | ForEach-Object {
                '{"Server":"'    + (EscapeJson $_.Server)    + '",' +
                '"OSVersion":"'  + (EscapeJson $_.OSVersion) + '",' +
                '"Installed":'   + [int]$_.Installed         + ',' +
                '"Issued":'      + [int]$_.Issued            + ',' +
                '"Available":'   + [int]$_.Available         + ',' +
                '"UsagePct":'    + $_.UsagePct                + ',' +
                '"Compliance":"' + (EscapeJson $_.Compliance) + '"}'
            }) -join ','
        ) + ']'

        # All errors from all queried servers, combined into one list
        $errJson = '[' + (
            @($Results | ForEach-Object { $_.Errors } |
                ForEach-Object { '"' + (EscapeJson $_) + '"' }) -join ','
        ) + ']'

        $JsonBlock = @"
<script>
window.REPORT_DATA = {
  "GenDate"          : "$(EscapeJson $GenDate)",
  "ServerCount"      : $($Results.Count),
  "TotalInstalled"   : $TotalInstalled,
  "TotalIssued"      : $TotalIssued,
  "TotalAvailable"   : $TotalAvailable,
  "OverallPct"       : $OverallPct,
  "OverallState"     : "$(EscapeJson $OverallState)",
  "WarnThresholdPct" : $WarningThresholdPct,
  "CritThresholdPct" : $CriticalThresholdPct,
  "Rows"             : $rowsJson,
  "Errors"           : $errJson
};
</script>
"@
        $Html.Replace('</body>', $JsonBlock + "`n</body>") |
            Out-File -FilePath $OutputFile -Encoding UTF8 -ErrorAction Stop
        Write-Log "Report saved ($($Results.Count) server(s)): $OutputFile" "SUCCESS"

    } catch {
        Write-Log "FATAL: Report could not be saved -- $($_.Exception.Message)" "ERROR"
        Write-Log "  Stack: $($_.ScriptStackTrace)" "ERROR"
    }
}

#endregion REPORT WRITERS

#region MAIN

try {

    Write-Log "================================================================="
    Write-Log "  RDS License Usage Monitoring | Citrix Workspace Automation Suite"
    Write-Log "  $ScriptVersion  |  Warn=$WarningThresholdPct%  Crit=$CriticalThresholdPct%"
    Write-Log "================================================================="

    # Parse server list
    $ServerList = @(
        $LicenseServerFQDN -split ';' |
            ForEach-Object { $_.Trim() } |
            Where-Object   { $_ -ne ''  }
    )

    if ($ServerList.Count -eq 0) {
        throw "LicenseServerFQDN is empty or contains no valid server names."
    }
    Write-Log "$($ServerList.Count) server(s): $($ServerList -join ', ')"

    # Ensure output folder exists
    if (-not (Test-Path $OutputDir)) {
        try {
            New-Item -Path $OutputDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
            Write-Log "Output folder created: $OutputDir" "SUCCESS"
        } catch {
            throw "Cannot create output folder '$OutputDir': $($_.Exception.Message)"
        }
    } else {
        Write-Log "Output folder: $OutputDir" "INFO"
    }

    # Query servers
    $ServerResults = [System.Collections.Generic.List[object]]::new()
    $FailedServers = [System.Collections.Generic.List[string]]::new()

    if ($ServerList.Count -eq 1) {
        # Single server -- direct call, no runspace overhead
        try {
            $result = Invoke-LicenseServerReport -Server $ServerList[0]
            $ServerResults.Add($result)
        } catch {
            $FailedServers.Add($ServerList[0])
            Write-Log "Query failed for [$($ServerList[0])]: $($_.Exception.Message)" "ERROR"
        }

    } else {
        # Multiple servers -- parallel RunspacePool (run time = slowest server)
        Write-Log "Starting parallel queries ($($ServerList.Count) threads)..." "INFO"

        $Pool = $null
        try {
            $Pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(
                        1, $ServerList.Count)
            $Pool.ApartmentState = "MTA"
            $Pool.Open()
            $fnBodies = @{
                WriteLog    = (Get-Command Write-Log).ScriptBlock.ToString()
                GetComp     = (Get-Command Get-Compliance).ScriptBlock.ToString()
                WmiExpiry   = (Get-Command ConvertFrom-WmiExpiry).ScriptBlock.ToString()
                GetKeyPacks = (Get-Command Get-KeyPacks).ScriptBlock.ToString()
                GetOsVer    = (Get-Command Get-OSVersion).ScriptBlock.ToString()
                Invoke      = (Get-Command Invoke-LicenseServerReport).ScriptBlock.ToString()
            }

            $Jobs = [System.Collections.Generic.List[object]]::new()

            $runspaceScript = @'
param(
    [string]$Server,
    [int]   $Warn,
    [int]   $Crit,
    [string]$fnWriteLog,
    [string]$fnGetComp,
    [string]$fnWmiExpiry,
    [string]$fnGetKeyPacks,
    [string]$fnGetOsVer,
    [string]$fnInvoke
)
# Define functions safely using Set-Item (no string-expansion risk)
Set-Item -Path function:Write-Log              -Value ([ScriptBlock]::Create($fnWriteLog))
Set-Item -Path function:Get-Compliance         -Value ([ScriptBlock]::Create($fnGetComp))
Set-Item -Path function:ConvertFrom-WmiExpiry  -Value ([ScriptBlock]::Create($fnWmiExpiry))
Set-Item -Path function:Get-KeyPacks           -Value ([ScriptBlock]::Create($fnGetKeyPacks))
Set-Item -Path function:Get-OSVersion          -Value ([ScriptBlock]::Create($fnGetOsVer))
Set-Item -Path function:Invoke-LicenseServerReport -Value ([ScriptBlock]::Create($fnInvoke))
# Threshold variables in local scope (visible to all functions via script scope)
$WarningThresholdPct  = $Warn
$CriticalThresholdPct = $Crit
Invoke-LicenseServerReport -Server $Server
'@

            foreach ($srv in $ServerList) {
                $ps = [System.Management.Automation.PowerShell]::Create()
                $ps.RunspacePool = $Pool
                # AddScript([string]) + AddArgument() = correct param binding
                [void]$ps.AddScript($runspaceScript)
                [void]$ps.AddArgument($srv)
                [void]$ps.AddArgument($WarningThresholdPct)
                [void]$ps.AddArgument($CriticalThresholdPct)
                [void]$ps.AddArgument($fnBodies.WriteLog)
                [void]$ps.AddArgument($fnBodies.GetComp)
                [void]$ps.AddArgument($fnBodies.WmiExpiry)
                [void]$ps.AddArgument($fnBodies.GetKeyPacks)
                [void]$ps.AddArgument($fnBodies.GetOsVer)
                [void]$ps.AddArgument($fnBodies.Invoke)

                $handle = $ps.BeginInvoke()
                $Jobs.Add([PSCustomObject]@{ PS = $ps; Handle = $handle; Server = $srv })
            }

            # Collect results in submission order
            foreach ($job in $Jobs) {
                try {
                    $result = $job.PS.EndInvoke($job.Handle)
                    if ($job.PS.HadErrors) {
                        $job.PS.Streams.Error |
                            ForEach-Object { Write-Log "  [RunspaceErr][$($job.Server)] $_" "WARN" }
                    }
                    if ($null -ne $result -and $result.Count -gt 0) {
                        $ServerResults.Add($result[0])
                    } else {
                        $FailedServers.Add($job.Server)
                        Write-Log "No result returned for [$($job.Server)]" "ERROR"
                    }
                } catch {
                    $FailedServers.Add($job.Server)
                    Write-Log "Job failed [$($job.Server)]: $($_.Exception.Message)" "ERROR"
                } finally {
                    try { $job.PS.Dispose() } catch {}
                }
            }

        } finally {
            # Pool always closed even if a job throws
            if ($null -ne $Pool) {
                try { $Pool.Close();   } catch {}
                try { $Pool.Dispose(); } catch {}
            }
        }

        Write-Log "Parallel queries complete." "SUCCESS"
    }

    # Summary
    Write-Log "================================================================="
    Write-Log ("Batch complete: {0} succeeded, {1} failed of {2} total" -f `
        $ServerResults.Count, $FailedServers.Count, $ServerList.Count) "SUCCESS"
    if ($FailedServers.Count -gt 0) {
        Write-Log "Failed: $($FailedServers -join ', ')" "ERROR"
    }

    # Save report
    if ($ServerResults.Count -gt 0) {
        Save-Report -Results $ServerResults
    } else {
        Write-Log "No successful results -- no report generated." "WARN"
    }

    # Exit
    if ($FailedServers.Count -gt 0) { exit 3 } else { exit 0 }

} catch {
    Write-Log "FATAL: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack: $($_.ScriptStackTrace)" "ERROR"
    exit 3
}
#endregion MAIN
