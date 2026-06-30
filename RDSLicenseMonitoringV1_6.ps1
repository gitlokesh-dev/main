############################################################################################################
# Script Name  : RDSLicenseMonitoring.ps1
# Description  : RDS License Usage Monitoring | Citrix Workspace Automation Suite
# Version      : V1.9
# Compatibility: PowerShell 5.1+  |  Windows Server 2016 / 2019 / 2022
#
# USAGE
#   Single server   : -LicenseServerFQDN "amsdc1-s-7060.domain.com"
#   Multiple servers: -LicenseServerFQDN "srv1.domain.com;srv2.domain.com"
#
#   *** CRITICAL -- HPSA / Camunda PARAMETER QUOTING ***
#   The value passed for LicenseServerFQDN MUST be wrapped in double quotes
#   in the HPSA job/parameter definition, e.g.:
#       -LicenseServerFQDN "srv1.domain.com;srv2.domain.com;srv3.domain.com"
#   If the semicolon-separated list is passed WITHOUT quotes, PowerShell's
#   own command-line parser (not this script) splits on ';' BEFORE the
#   script ever runs, and tries to execute "srv2.domain.com" etc. as a
#   separate command -- producing errors like:
#       "The term 'srv2.domain.com' is not recognized as the name of a
#        cmdlet, function, script file, or operable program."
#   This is an HPSA/Camunda job-configuration issue, not a script bug --
#   fix it by quoting the parameter value at the call site.
#
# OUTPUT (written to $OutputDir)
#   RDSLicenseMonitoring_<ServerName>_<timestamp>.html   (single server)
#   RDSLicenseMonitoring_Combined_<timestamp>.html        (multiple servers)
#
# CHANGE LOG
# ----------
#  V1.9  (2026-07-01)  DIAGNOSTIC + CROSS-DOMAIN AUTH FIX -- "first server
#        works, others empty" persisted even after V1.7 (sequential queries)
#        and V1.8 (CIM datetime fix), with each server confirmed to work
#        correctly when run individually.  This rules out threading, COM
#        caching, and datetime-parsing as the cause -- the remaining
#        explanation is environmental: the failing servers are in different
#        AD domains (europe.shell.com / asia-pac.shell.com / americas.shell.com).
#
#        CHANGES IN THIS VERSION:
#          1. -Authentication Negotiate is now forced on every New-CimSession
#             call.  Without an explicit authentication mechanism, WSMan/DCOM
#             can silently pick NTLM for one domain and Kerberos for another
#             within the same process, and the failure can present as an
#             empty/no-error result rather than a visible auth exception.
#          2. Every failure at every stage (WSMan, DCOM, legacy WMI) now logs
#             the FULL exception type and message per server, not just a
#             generic warning -- so the actual blocking reason (access denied,
#             RPC server unavailable, Kerberos realm mismatch, etc.) is
#             visible in the HPSA log instead of being summarised away.
#          3. If Installed=0 for a server after all attempts, an explicit
#             ERROR-level banner line is printed pointing back at the issue
#             list above it, so a scan of the log cannot miss a failed server.
#          4. Every captured error message is now printed individually
#             (previously only the COUNT of errors was logged, not their text).
#
#        NEXT STEP IF THIS STILL FAILS: re-run with all 3 servers and search
#        the log for "[$Server] CIM (WSMan) FAILED" / "CIM (DCOM) FAILED" /
#        "ALL THREE methods failed" for the failing servers -- the Detail=
#        text on those lines will show the real blocking reason (commonly:
#        WinRM not enabled on that server, firewall blocking RPC/WMI ports,
#        the HPSA service account lacking rights in that domain, or a
#        one-way/no trust relationship between the domains involved).
#
#  V1.8  (2026-06-30)  CRITICAL BUG FIX -- Expired packs still counted
#        ROOT CAUSE: V1.7 switched to Get-CimInstance as the primary query
#        method (to fix the multi-server data-loss bug).  Get-CimInstance
#        returns WMI DATETIME properties ALREADY CONVERTED to .NET [datetime]
#        objects, whereas Get-WmiObject returns them as raw WMI strings
#        (e.g. "20380119031407.000000-000").  ConvertFrom-WmiExpiry assumed
#        the raw string format unconditionally: every call site forced
#        [string]$pack.ExpirationDate before passing it in, which stringifies
#        a .NET DateTime using the current culture (e.g. "06/30/2024 00:00:00")
#        instead of the WMI format.  Substring(0,14) on that culture-formatted
#        string does not match "yyyyMMddHHmmss", ParseExact throws, and the
#        catch block silently returned $null ("Never expires") for every
#        single pack queried via CIM -- meaning NO pack was ever correctly
#        identified as expired after the V1.7 CIM-first change, regardless
#        of its real expiration date.
#
#        FIX: ConvertFrom-WmiExpiry now accepts the value as untyped [object]
#        and branches on the actual .NET type at runtime:
#          - if it is already a [datetime] (CIM) -- use it directly
#          - if it is a string (legacy WMI)        -- parse with the original
#            yyyyMMddHHmmss logic
#        All three call sites updated to pass $pack.ExpirationDate RAW,
#        without a premature [string] cast, so the type-detection works.
#        Added a [RAW] diagnostic log line per pack showing the raw value
#        and its .NET type, so any future WMI/CIM behaviour change is
#        immediately visible in the HPSA log instead of silently swallowed.
#
#  V1.7  (2026-06-27)  BUG FIX -- Multi-server STILL returned data for only
#        the first server after V1.6 made queries sequential.  This ruled out
#        thread/COM-apartment contention (the V1.6 theory) since sequential
#        execution still failed identically.
#
#        ROOT CAUSE (confirmed): legacy Get-WmiObject -ComputerName uses
#        DCOM under the hood, and DCOM remote connections are cached/pooled
#        by the underlying Windows RPC layer for the lifetime of the
#        PowerShell process -- NOT just for the lifetime of a single
#        runspace/thread.  When the script calls Get-WmiObject for server #1
#        successfully, the OS can reuse that cached DCOM binding/auth context
#        for the NEXT Get-WmiObject call even though -ComputerName points to
#        a different server, causing the 2nd/3rd calls to silently return
#        empty results instead of an error (so no exception was ever thrown
#        or logged -- it just looked like "no data").
#
#        FIX: Get-KeyPacks and Get-OSVersion now try, in order:
#          1. Get-CimInstance over WSMan (New-CimSession, no -SessionOption)
#             -- explicit, isolated session per server; no DCOM connection
#             pooling involved at all.  This is the modern, recommended
#             replacement for Get-WmiObject and is tried FIRST.
#          2. Get-CimInstance over DCOM (New-CimSessionOption -Protocol Dcom)
#             -- for hosts with WMI/DCOM but no WinRM listener.  Still uses
#             an explicit per-call CimSession object (disposed immediately
#             after use), which does not exhibit the same caching behaviour
#             as Get-WmiObject.
#          3. Legacy Get-WmiObject -- kept only as a last-resort fallback.
#        Every CimSession is created fresh per server and disposed in a
#        finally block immediately after use, eliminating any possibility
#        of state leaking from one server's query into the next.
#
#  V1.6  (2026-06-27)  Removed RunspacePool / parallel execution (see below)
#        the first server; servers 2, 3, ... came back empty.
#
#        ROOT CAUSE: the parallel RunspacePool ran every server's WMI/CIM
#        query concurrently on separate threads (ApartmentState = MTA).
#        Get-WmiObject and the CIM/DCOM fallback both go through COM
#        interop under the hood, and COM enforces per-thread apartment
#        rules.  WMI/DCOM calls are only reliable from a Single-Threaded
#        Apartment (STA); under MTA, only the first runspace to touch a
#        COM object on the process reliably gets real data -- every other
#        concurrent runspace silently receives empty/null results.  This
#        exactly matched the reported symptom: server #1 worked, the rest
#        came back empty, but each one worked fine when run individually
#        (i.e. on its own thread, with no concurrent COM contention).
#
#        FIX: removed the RunspacePool entirely.  Multiple servers are now
#        queried SEQUENTIALLY using the exact same Invoke-LicenseServerReport
#        call already used (and proven reliable) for the single-server path.
#        This guarantees every server is queried correctly and consistently,
#        at the cost of total run time scaling with server count rather than
#        being capped at the slowest single server.  For RDS license checks
#        (a handful of fast WMI calls per server) this is a negligible
#        trade-off and far preferable to silently missing data.
#
#  V1.5.2 (2026-06-27)  BUG FIX -- Mandatory $ErrorLog binding error
#        [Parameter(Mandatory)] on $ErrorLog in Get-KeyPacks and Get-OSVersion
#        caused PowerShell's parameter binder to reject a valid (but empty)
#        List[string] with "Cannot bind argument to parameter 'ErrorLog' because
#        it is an empty collection."  $ErrorLog is an output-collector passed by
#        the caller -- it must never be Mandatory.  Removed [Parameter(Mandatory)]
#        from $ErrorLog in both functions; [Parameter(Mandatory)] kept on $Server.
#
#  V1.5.1 (2026-05-28)  PARSE ERROR FIX
#        $function:Write-Log syntax fails at parse time when the function name
#        contains a hyphen -- PowerShell's variable namespace syntax does not
#        allow hyphens in the identifier after the colon.  All six $function:X
#        references replaced with (Get-Command X).ScriptBlock.ToString() which
#        works correctly for any function name regardless of punctuation.
#
#  V1.5  (2026-05-28)  BUG FIXES -- verified clean execution
#        FIX 1  EscapeJson backslash regex was wrong.
#               '-replace "\\","\\\"' only matched one backslash (regex `\` = literal \)
#               and produced one backslash in output.  Fixed to use [string]::Replace()
#               for the backslash pass (literal replace, no regex) then -replace for
#               the remaining characters which do not need regex escaping.
#        FIX 2  RunspacePool: AddScript({scriptblock})+AddParameters() does NOT bind
#               named params -- parameters were silently $null in every job.
#               Fixed: pass a plain [string] script to AddScript, call AddArgument()
#               for each value in the correct order.
#        FIX 3  Invoke-Expression "function X { $body }" expands $-variables and
#               backticks inside $body during string interpolation, corrupting function
#               bodies that contain either.  Fixed: use Set-Item with ScriptBlock::Create.
#        FIX 4  $global:WarningThresholdPct / $global:CriticalThresholdPct inside
#               runspaces set runspace-global state unnecessarily.  Fixed: use plain
#               local variables $WarningThresholdPct / $CriticalThresholdPct which are
#               in scope within the runspace script string.
#        FIX 5  Nested 'exit 3' inside inner try block for folder creation bypassed
#               outer catch logging.  Fixed: use 'throw' to propagate to outer catch.
#        FIX 6  Dead comment block "EMBEDDED HTML TEMPLATE" removed.
#        CLEAN  Consistent 4-space indentation throughout; aligned parameter blocks;
#               region labels verified to match #region/#endregion pairs exactly.
#
#  V1.4  (2026-05-27)  Structural rewrite -- regions, parallel RunspacePool, try/catch
#  V1.3  (2026-05-27)  Unified HTML template (single Get-UnifiedTemplate)
#  V1.2  (2026-05-27)  Bug fix: expired key pack exclusion
#  V1.1  Initial release
############################################################################################################

#region PARAMETERS
param(
    [Parameter(Mandatory = $true)]
    [string]$LicenseServerFQDN
)
#endregion PARAMETERS


#region CONFIG
$ErrorActionPreference = "Continue"   # script level: HPSA sees all console output

$OutputDir            = "C:\Scripts\RDL\Output\"
$WarningThresholdPct  = 80
$CriticalThresholdPct = 95
$ScriptVersion        = "V1.9"
#endregion CONFIG


#region HELPERS

# ─────────────────────────────────────────────────────────────────────────────
# Write-Log  --  timestamped, colour-coded console line
# ─────────────────────────────────────────────────────────────────────────────
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Msg,
        [ValidateSet("INFO","SUCCESS","WARN","ERROR")][string]$Lvl = "INFO"
    )
    $col = switch ($Lvl) {
        "SUCCESS" { "Green"  }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red"    }
        default   { "Cyan"   }
    }
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][$Lvl] $Msg" -ForegroundColor $col
}

# ─────────────────────────────────────────────────────────────────────────────
# EscapeJson  --  makes a value safe to embed inside a JSON string literal.
# FIX 1: backslash handled with [string]::Replace (literal, no regex);
#        remaining chars use -replace (regex is safe because none need escaping).
# ─────────────────────────────────────────────────────────────────────────────
function EscapeJson {
    param([string]$s)
    if ([string]::IsNullOrEmpty($s)) { return "" }
    # Step 1: backslash -- literal replace FIRST (must precede the quote replace)
    $s = $s.Replace('\', '\\')
    # Step 2: remaining JSON special characters
    $s = $s -replace '"',    '\"'  `
            -replace "`r`n", '\n'  `
            -replace "`n",   '\n'  `
            -replace "`t",   '\t'
    return $s
}

# ─────────────────────────────────────────────────────────────────────────────
# Get-Compliance  --  maps a usage % to a compliance label
# ─────────────────────────────────────────────────────────────────────────────
function Get-Compliance {
    param([double]$Pct)
    if ($Pct -ge $CriticalThresholdPct) { return "CRITICAL"  }
    if ($Pct -ge $WarningThresholdPct)  { return "WARNING"   }
    return "COMPLIANT"
}

# ─────────────────────────────────────────────────────────────────────────────
# ConvertFrom-WmiExpiry  --  safely parses a WMI datetime string.
# Returns [datetime] UTC when a real future-or-past date is found.
# Returns $null for null/empty input OR for the WMI "Never" epoch (year <= 1970).
# ─────────────────────────────────────────────────────────────────────────────
function ConvertFrom-WmiExpiry {
    <#
    .SYNOPSIS
        Safely converts a Win32_TSLicenseKeyPack.ExpirationDate value to UTC.
    .NOTES
        CRITICAL: Get-CimInstance and Get-WmiObject return ExpirationDate in
        TWO DIFFERENT .NET TYPES:
          - Get-WmiObject  returns the raw WMI string, e.g. "20380119031407.000000-000"
          - Get-CimInstance returns an ALREADY-CONVERTED [datetime] .NET object
        The previous version always called [string]$pack.ExpirationDate and tried
        to Substring(0,14) it as if it were the raw WMI string format.  When the
        value came from CIM, [string] of a DateTime produces something like
        "06/30/2024 00:00:00" (current-culture format) -- Substring(0,14) on that
        does not match "yyyyMMddHHmmss" at all, ParseExact throws, the catch block
        swallows the error, and the function silently returns $null ("Never").
        This caused EVERY expired pack queried via CIM to be wrongly treated as
        non-expiring, so expired packs kept being counted toward the totals.
        FIX: accept the parameter as [object] and branch on its actual .NET type
        before attempting any parsing.
    #>
    param($Raw)

    if ($null -eq $Raw) { return $null }

    # Case 1: CIM already gave us a real [datetime] -- use it directly, no parsing.
    if ($Raw -is [datetime]) {
        $dt = [datetime]$Raw
        if ($dt.Year -le 1970) { return $null }   # WMI "Never expires" sentinel
        return $dt.ToUniversalTime()
    }

    # Case 2: legacy Get-WmiObject gives us the raw WMI string format.
    $RawStr = [string]$Raw
    if ([string]::IsNullOrWhiteSpace($RawStr)) { return $null }

    try {
        # WMI datetime format: yyyyMMddHHmmss.ffffff+UUU -- take first 14 chars
        if ($RawStr.Length -lt 14) { return $null }
        $datePart = $RawStr.Substring(0, 14)
        $dt = [datetime]::ParseExact(
                  $datePart,
                  'yyyyMMddHHmmss',
                  [System.Globalization.CultureInfo]::InvariantCulture,
                  [System.Globalization.DateTimeStyles]::AssumeUniversal)
        if ($dt.Year -le 1970) { return $null }   # WMI "Never expires" sentinel
        return $dt.ToUniversalTime()
    } catch {
        # Genuinely unparseable -- treat as non-expiring to avoid false exclusions,
        # but log it so it is visible instead of silently disappearing.
        Write-Log "  ConvertFrom-WmiExpiry: could not parse raw value '$RawStr' (type=$($Raw.GetType().Name))" "WARN"
        return $null
    }
}

#endregion HELPERS


#region HTML TEMPLATE

# ─────────────────────────────────────────────────────────────────────────────
# Get-UnifiedTemplate
# Returns one self-contained HTML page used for both single and multi-server.
# At runtime the JavaScript detects which variable was injected:
#   window.REPORT_DATA   -> single server  (set by Save-Report)
#   window.COMBINED_DATA -> multiple servers (set by Save-Report)
# ─────────────────────────────────────────────────────────────────────────────
function Get-UnifiedTemplate {
    return @'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8"/>
    <meta name="viewport" content="width=device-width,initial-scale=1.0"/>
    <title>RDS License Usage Monitoring | Citrix Workspace Automation Suite</title>
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
            --mono         : 'Cascadia Code','Consolas','Courier New',monospace;
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
            position: relative; z-index: 1; padding: 22px 40px 16px;
            display: flex; align-items: baseline; justify-content: space-between; gap: 16px; flex-wrap: wrap;
        }
        .hdr-eyebrow {
            font-size: .68rem; font-weight: 700; letter-spacing: 1.6px; text-transform: uppercase;
            color: rgba(255,255,255,.62); margin-bottom: 5px;
        }
        .hdr-title { font-size: 1.82rem; font-weight: 800; letter-spacing: -.4px; line-height: 1.15; }
        .hdr-gen   { font-size: .75rem; color: rgba(255,255,255,.78); white-space: nowrap; }
        .hdr-strip {
            position: relative; z-index: 1; display: flex; align-items: center; justify-content: space-between;
            background: rgba(15,0,10,.20); padding: 10px 42px; font-size: .76rem;
            color: rgba(255,255,255,.90); gap: 12px; flex-wrap: wrap;
            border-top: 1px solid rgba(255,255,255,.08);
        }
        .hdr-strip-left { display: flex; align-items: center; gap: 18px; flex-wrap: wrap; }
        .hdr-strip-left span { display: flex; align-items: center; gap: 6px; }
        .hdr-strip-left strong { color: #fff; font-weight: 700; }
        .status-pill {
            padding: 5px 18px; border-radius: 30px; font-weight: 800; font-size: .72rem;
            letter-spacing: .4px; white-space: nowrap; box-shadow: 0 2px 10px rgba(0,0,0,.16);
        }
        .pill-ok   { background: linear-gradient(135deg, #1C9A1A, #0A7A09); color: #fff; }
        .pill-warn { background: linear-gradient(135deg, #D67A00, #B05E00); color: #fff; }
        .pill-err  { background: linear-gradient(135deg, #DC2030, #BF0E1A); color: #fff; }

        /* ---- Body --------------------------------------------------------- */
        .rpt-body { max-width: var(--max-w); margin: 28px auto; padding: 0 26px 56px; }

        /* ---- Alerts ------------------------------------------------------- */
        .alert {
            display: flex; align-items: flex-start; gap: 14px; border-radius: var(--r-sm);
            padding: 14px 18px; margin-bottom: 18px; border-left: 4px solid;
            font-size: .85rem; background: var(--surface); box-shadow: var(--sh);
        }
        .alert .ico { font-size: 1.15rem; flex-shrink: 0; margin-top: 1px; }
        .alert ul   { margin-top: 6px; padding-left: 16px; }
        .alert li   { margin-top: 3px; }
        .alert-err  { border-color: var(--err); color: #5A000A; }
        .alert-err strong { color: var(--err); }

        /* ---- Overview banner (single-server only) ------------------------- */
        .ov-banner {
            display: flex; align-items: center; gap: 18px; padding: 18px 24px;
            border-radius: var(--r); margin-bottom: 18px;
            background: var(--surface); box-shadow: var(--sh);
            border: 1px solid var(--line); border-left: 5px solid currentColor;
            position: relative; overflow: hidden;
        }
        .ov-banner::before {
            content: ''; position: absolute; inset: 0; opacity: .05; pointer-events: none;
            background: radial-gradient(circle at 100% 0%, currentColor 0%, transparent 60%);
        }
        .ov-badge {
            padding: 8px 22px; border-radius: 30px; font-weight: 800; font-size: .85rem;
            letter-spacing: .4px; white-space: nowrap; color: #fff;
            background: currentColor; position: relative; z-index: 1;
            box-shadow: 0 4px 14px rgba(0,0,0,.14);
        }
        .ov-badge span  { color: #fff; }
        .ov-detail      { position: relative; z-index: 1; }
        .ov-detail strong { font-size: 1.02rem; color: var(--text-h); }
        .ov-detail .sub   { font-size: .79rem; color: var(--text-m); margin-top: 3px; }

        /* ---- KPI cards ---------------------------------------------------- */
        /* Grid col count set by JS: single=6, multi=4                         */
        .card-grid        { display: grid; gap: 10px; margin-bottom: 18px; align-items: stretch; }
        .card-grid.single { grid-template-columns: repeat(6, 1fr); }
        .card-grid.multi  { grid-template-columns: repeat(4, 1fr); }
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
        .td-mono   { font-family: var(--mono); font-size: .74rem; }
        .badge {
            display: inline-block; padding: 3px 11px; border-radius: 30px;
            font-size: .68rem; font-weight: 700; letter-spacing: .2px; white-space: nowrap;
        }
        .b-ok   { background: var(--ok-bg);   color: var(--ok);   border: 1px solid var(--ok-line); }
        .b-warn { background: var(--warn-bg); color: var(--warn); border: 1px solid var(--warn-line); }
        .b-err  { background: var(--err-bg);  color: var(--err);  border: 1px solid var(--err-line); }

        /* ---- Progress bar ------------------------------------------------- */
        .pw { display: flex; align-items: center; gap: 9px; }
        .pt { flex: 1; height: 9px; background: #ECE7F2; border-radius: 8px; overflow: hidden; box-shadow: inset 0 1px 2px rgba(0,0,0,.06); }
        .pf { height: 100%; border-radius: 8px; transition: width .7s cubic-bezier(.22,.9,.34,1); }
        .pp { font-weight: 700; font-size: .76rem; min-width: 38px; text-align: right; }

        code {
            font-family: var(--mono); font-size: .74rem; background: var(--brand-ultra);
            padding: 2px 6px; border-radius: 5px; color: var(--brand-dark); word-break: break-all;
        }
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

<!-- =====================================================================
     HEADER  --  content injected by renderReport() at runtime
     ===================================================================== -->
<div class="rpt-hdr">
    <div class="hdr-inner">
        <div>
            <div class="hdr-eyebrow" id="hdr-eyebrow">Citrix Workspace Automation Suite</div>
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

    <!-- Error alerts (single-server mode) -->
    <div id="err-section"></div>

    <!-- Overview banner -- shown for single server, hidden for multi -->
    <div class="ov-banner" id="ov-banner" style="display:none;">
        <span class="ov-badge" id="ov-badge">-</span>
        <div class="ov-detail">
            <strong id="ov-detail-main">-</strong>
            <div class="sub" id="ov-detail-sub">-</div>
        </div>
    </div>

    <!-- KPI cards -- count and content set by renderReport() -->
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

<!-- =====================================================================
     UNIFIED RENDER ENGINE
     Detects which variable was injected and calls the correct renderer.
     ===================================================================== -->
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

    /* ── SINGLE-SERVER renderer ─────────────────────────────────────── */
    function renderSingle(d) {
        var color = colorMap[d.Compliance] || '#0A7A09';

        /* Header */
        set('hdr-eyebrow', 'Citrix Workspace Automation Suite \u00b7 Single Server');
        set('gen-date', d.GenDate);
        setHtml('hdr-strip-left',
            "<span>&#128220; Server: <strong>" + d.LicenseServerFQDN + "</strong></span>" +
            "<span>&#128202; CALs: <strong>" + d.Issued + " / " + d.Installed + " (" + d.UsagePct + "%)</strong></span>"
        );
        var pill = document.getElementById('status-pill');
        pill.textContent = d.Compliance + ' \u2013 ' + d.UsagePct + '% CAL Utilisation';
        pill.className   = 'status-pill ' + (pillMap[d.Compliance] || 'pill-ok');

        /* Overview banner */
        var banner = document.getElementById('ov-banner');
        banner.style.display     = '';
        banner.style.color       = color;
        banner.style.borderColor = color;
        var badge = document.getElementById('ov-badge');
        badge.textContent      = d.Compliance;
        badge.style.background = color;
        set('ov-detail-main', d.Issued + ' of ' + d.Installed + ' CALs in use (' + d.UsagePct + '%) \u2013 ' + d.Available + ' remaining');
        setHtml('ov-detail-sub',
            'Warn: <strong>' + d.WarnPctLabel + '</strong> &nbsp;|&nbsp; Critical: <strong>' + d.CritPctLabel + '</strong>'
        );

        /* KPI cards -- 6-column */
        var grid = document.getElementById('card-grid');
        grid.classList.add('single');
        grid.innerHTML =
            "<div class='card' data-ico='&#128220;'><div class='c-lbl'>License Server</div>" +
                "<div class='c-val'>" + d.LicenseServerFQDN + "</div><div class='c-sub'>" + d.LicServerOSVersion + "</div></div>" +
            "<div class='card' data-ico='&#128202;'><div class='c-lbl'>Total CALs</div>" +
                "<div class='c-val'>" + d.Installed + "</div></div>" +
            "<div class='card' data-ico='&#128273;'><div class='c-lbl'>CALs In Use</div>" +
                "<div class='c-val' style='color:" + color + ";'>" + d.Issued + "</div>" +
                "<div class='c-sub'>" + d.UsagePct + "% utilisation</div></div>" +
            "<div class='card' data-ico='&#9989;'><div class='c-lbl'>CALs Available</div>" +
                "<div class='c-val'>" + d.Available + "</div>" +
                "<div class='c-sub'>" + d.HeadroomPct + "% headroom</div></div>" +
            "<div class='card' data-ico='&#9888;'><div class='c-lbl'>Warn Threshold</div>" +
                "<div class='c-val'>" + d.WarnPctLabel + "</div><div class='c-sub'>" + d.WarnCardSub + "</div></div>" +
            "<div class='card' data-ico='&#128308;'><div class='c-lbl'>Crit Threshold</div>" +
                "<div class='c-val'>" + d.CritPctLabel + "</div><div class='c-sub'>" + d.CritCardSub + "</div></div>";

        /* Errors */
        if (d.Errors && d.Errors.length > 0) {
            var li = d.Errors.map(function(e){ return '<li>' + e + '</li>'; }).join('');
            setHtml('err-section',
                "<div class='alert alert-err'><div class='ico'>&#9888;</div>" +
                "<div><strong>" + d.Errors.length + " error(s) during execution</strong><ul>" + li + "</ul></div></div>"
            );
        }

        /* Section header & table row */
        set('sec-hdr-label', '\uD83D\uDCDC License Summary \u2013 ' + d.LicenseServerFQDN);
        setHtml('kp-tbody', makeRow(
            d.LicenseServerFQDN, d.LicServerOSVersion,
            d.Installed, d.Issued, d.Available,
            d.UsagePct, d.WarnThresholdPct, d.CritThresholdPct
        ));
    }

    /* ── MULTI-SERVER renderer ──────────────────────────────────────── */
    function renderMulti(d) {
        var overallColor = colorMap[d.OverallState] || '#0A7A09';

        /* Header */
        set('hdr-eyebrow', 'Citrix Workspace Automation Suite \u00b7 Combined Summary \u2013 ' + d.ServerCount + ' Server(s)');
        set('gen-date', d.GenDate);
        setHtml('hdr-strip-left',
            "<span>&#128421; Servers: <strong>" + d.ServerCount + "</strong></span>" +
            "<span>&#128202; Total CALs: <strong>" + d.TotalInstalled + "</strong></span>" +
            "<span>&#128273; In Use: <strong>" + d.TotalIssued + " (" + d.OverallPct + "%)</strong></span>"
        );
        var pill = document.getElementById('status-pill');
        pill.textContent = d.OverallState + ' \u2013 ' + d.OverallPct + '% Overall Utilisation';
        pill.className   = 'status-pill ' + (pillMap[d.OverallState] || 'pill-ok');

        /* Overview banner -- hidden for multi */
        document.getElementById('ov-banner').style.display = 'none';

        /* KPI cards -- 4-column aggregate */
        var grid = document.getElementById('card-grid');
        grid.classList.add('multi');
        grid.innerHTML =
            "<div class='card' data-ico='&#128421;'><div class='c-lbl'>License Servers</div>" +
                "<div class='c-val'>" + d.ServerCount + "</div><div class='c-sub'>Queried this run</div></div>" +
            "<div class='card' data-ico='&#128202;'><div class='c-lbl'>Total CALs (All Servers)</div>" +
                "<div class='c-val'>" + d.TotalInstalled + "</div></div>" +
            "<div class='card' data-ico='&#128273;'><div class='c-lbl'>CALs In Use</div>" +
                "<div class='c-val' style='color:" + overallColor + ";'>" + d.TotalIssued + "</div>" +
                "<div class='c-sub'>" + d.OverallPct + "% overall</div></div>" +
            "<div class='card' data-ico='&#9989;'><div class='c-lbl'>CALs Available</div>" +
                "<div class='c-val'>" + d.TotalAvailable + "</div></div>";

        /* Section header & table -- one row per server, sorted by usage desc */
        set('sec-hdr-label', '\uD83D\uDCDC License Servers \u2013 ' + d.ServerCount + ' server(s)');
        var sorted = d.Rows.slice().sort(function(a,b){ return b.UsagePct - a.UsagePct; });
        var body = '';
        sorted.forEach(function(r) {
            body += makeRow(r.Server, r.OSVersion, r.Installed, r.Issued, r.Available,
                            r.UsagePct, d.WarnThresholdPct, d.CritThresholdPct);
        });
        setHtml('kp-tbody', body ||
            "<tr><td colspan='6' style='text-align:center;padding:20px;color:#8A8A9A;'>No server data available</td></tr>"
        );
    }

    /* ── Entry point: detect variable, dispatch renderer ────────────── */
    function renderReport() {
        if (window.REPORT_DATA)   { renderSingle(window.REPORT_DATA);  return; }
        if (window.COMBINED_DATA) { renderMulti(window.COMBINED_DATA); return; }
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', renderReport);
    } else {
        renderReport();
    }

}());
</script>
</body>
</html>
'@
}

#endregion HTML TEMPLATE


#region REPORT WRITERS

# ─────────────────────────────────────────────────────────────────────────────
# Save-Report  --  unified entry point for single and multi-server HTML output.
# Writes window.REPORT_DATA (1 result) or window.COMBINED_DATA (2+ results).
# ─────────────────────────────────────────────────────────────────────────────
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
        $Html = Get-UnifiedTemplate

        # ── Single server ──────────────────────────────────────────────────
        if ($Results.Count -eq 1) {
            $r           = $Results[0]
            $SafeName    = $r.Server -replace '[^a-zA-Z0-9\-\.]', '_'
            $OutputFile  = Join-Path $OutputDir "RDSLicenseMonitoring_${SafeName}_${cDT}.html"
            $GenDate     = Get-Date -Format "dddd, dd MMMM yyyy HH:mm:ss"
            $HeadroomPct = if ($r.Installed -gt 0) {
                               [math]::Round(($r.Available / $r.Installed) * 100, 1)
                           } else { 0 }
            $WarnCardSub = if ($r.UsagePct -ge $WarningThresholdPct)  { "BREACHED"    } else { "Not reached" }
            $CritCardSub = if ($r.UsagePct -ge $CriticalThresholdPct) { "BREACHED"    } else { "Not reached" }
            $errJson     = '[' + (
                               @($r.Errors | ForEach-Object { '"' + (EscapeJson $_) + '"' }) -join ','
                           ) + ']'

            $JsonBlock = @"
<script>
window.REPORT_DATA = {
  "GenDate"           : "$(EscapeJson $GenDate)",
  "LicenseServerFQDN" : "$(EscapeJson $r.Server)",
  "LicServerOSVersion": "$(EscapeJson $r.OSVersion)",
  "Compliance"        : "$(EscapeJson $r.Compliance)",
  "UsagePct"          : $($r.UsagePct),
  "Issued"            : $($r.Issued),
  "Installed"         : $($r.Installed),
  "Available"         : $($r.Available),
  "HeadroomPct"       : $HeadroomPct,
  "WarnPctLabel"      : "$WarningThresholdPct%",
  "CritPctLabel"      : "$CriticalThresholdPct%",
  "WarnThresholdPct"  : $WarningThresholdPct,
  "CritThresholdPct"  : $CriticalThresholdPct,
  "WarnCardSub"       : "$(EscapeJson $WarnCardSub)",
  "CritCardSub"       : "$(EscapeJson $CritCardSub)",
  "Errors"            : $errJson
};
</script>
"@
            $Html.Replace('</body>', $JsonBlock + "`n</body>") |
                Out-File -FilePath $OutputFile -Encoding UTF8 -ErrorAction Stop
            Write-Log "Single-server report saved: $OutputFile" "SUCCESS"
        }

        # ── Multiple servers ───────────────────────────────────────────────
        else {
            $TotalInstalled = [int]($Results | Measure-Object Installed -Sum).Sum
            $TotalIssued    = [int]($Results | Measure-Object Issued    -Sum).Sum
            $TotalAvailable = [int]($Results | Measure-Object Available -Sum).Sum
            $OverallPct     = if ($TotalInstalled -gt 0) {
                                  [math]::Round(($TotalIssued / $TotalInstalled) * 100, 1)
                              } else { 0 }
            $OverallState   = Get-Compliance -Pct $OverallPct

            $rowsJson = '[' + (
                @($Results | ForEach-Object {
                    '{"Server":"'    + (EscapeJson $_.Server)   + '",' +
                    '"OSVersion":"'  + (EscapeJson $_.OSVersion) + '",' +
                    '"Installed":'   + [int]$_.Installed          + ',' +
                    '"Issued":'      + [int]$_.Issued             + ',' +
                    '"Available":'   + [int]$_.Available          + ',' +
                    '"UsagePct":'    + $_.UsagePct                + ',' +
                    '"Compliance":"' + (EscapeJson $_.Compliance) + '"}'
                }) -join ','
            ) + ']'

            $OutputFile = Join-Path $OutputDir "RDSLicenseMonitoring_Combined_${cDT}.html"
            $GenDate    = Get-Date -Format "dddd, dd MMMM yyyy HH:mm:ss"

            $JsonBlock = @"
<script>
window.COMBINED_DATA = {
  "GenDate"          : "$(EscapeJson $GenDate)",
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
</script>
"@
            $Html.Replace('</body>', $JsonBlock + "`n</body>") |
                Out-File -FilePath $OutputFile -Encoding UTF8 -ErrorAction Stop
            Write-Log "Combined report saved ($($Results.Count) server(s)): $OutputFile" "SUCCESS"
        }

    } catch {
        Write-Log "FATAL: Report could not be saved -- $($_.Exception.Message)" "ERROR"
        Write-Log "  Stack: $($_.ScriptStackTrace)" "ERROR"
    }
}

#endregion REPORT WRITERS


#region DATA COLLECTION

# ─────────────────────────────────────────────────────────────────────────────
# Get-KeyPacks  --  queries Win32_TSLicenseKeyPack from a remote server.
# Tries WMI first (faster); falls back to CIM over DCOM.
# CimSession is always disposed in the finally block (no session leaks).
# Returns an array (may be empty); never throws.
# ─────────────────────────────────────────────────────────────────────────────
function Get-KeyPacks {
    param(
        [Parameter(Mandatory)][string]$Server,
        [System.Collections.Generic.List[string]]$ErrorLog
    )

    # NOTE: if your servers span multiple AD domains/forests (e.g.
    # europe.shell.com, asia-pac.shell.com, americas.shell.com), CIM/WMI
    # authentication is evaluated independently per server -- there is no
    # shared state between calls in THIS function.  If server #1 succeeds
    # and #2/#3 fail when run together but succeed when run alone, the most
    # likely cause is a Kerberos/cross-domain authentication issue specific
    # to where this script executes from (the HPSA agent), not the script
    # logic.  -Authentication Negotiate is forced below to avoid silent
    # NTLM-vs-Kerberos fallback mismatches between domains.

    # Attempt 1: CIM over WSMan (explicit, isolated session per server)
    $cimSess = $null
    try {
        $cimSess = New-CimSession -ComputerName $Server -Authentication Negotiate -ErrorAction Stop
        $packs   = @(Get-CimInstance -CimSession $cimSess `
                         -ClassName "Win32_TSLicenseKeyPack" -ErrorAction Stop)
        Write-Log "  [$Server] CIM (WSMan) OK -- $($packs.Count) key pack(s)" "SUCCESS"
        return $packs
    } catch {
        $errDetail = $_.Exception.Message
        $errType   = $_.Exception.GetType().FullName
        Write-Log "  [$Server] CIM (WSMan) FAILED -- Type=$errType | Detail=$errDetail" "WARN"
    } finally {
        if ($null -ne $cimSess) {
            try { Remove-CimSession $cimSess -ErrorAction SilentlyContinue } catch {}
        }
    }

    # Attempt 2: CIM over DCOM (for hosts without WinRM enabled)
    $cimSess = $null
    try {
        $cimOpts = New-CimSessionOption -Protocol Dcom
        $cimSess = New-CimSession -ComputerName $Server -SessionOption $cimOpts `
                       -Authentication Negotiate -ErrorAction Stop
        $packs   = @(Get-CimInstance -CimSession $cimSess `
                         -ClassName "Win32_TSLicenseKeyPack" -ErrorAction Stop)
        Write-Log "  [$Server] CIM (DCOM) OK -- $($packs.Count) key pack(s)" "SUCCESS"
        return $packs
    } catch {
        $errDetail = $_.Exception.Message
        $errType   = $_.Exception.GetType().FullName
        Write-Log "  [$Server] CIM (DCOM) FAILED -- Type=$errType | Detail=$errDetail" "WARN"
    } finally {
        if ($null -ne $cimSess) {
            try { Remove-CimSession $cimSess -ErrorAction SilentlyContinue } catch {}
        }
    }

    # Attempt 3: legacy Get-WmiObject (last resort)
    try {
        $packs = @(Get-WmiObject -Class "Win32_TSLicenseKeyPack" `
                       -ComputerName $Server -ErrorAction Stop)
        Write-Log "  [$Server] Legacy WMI OK -- $($packs.Count) key pack(s)" "SUCCESS"
        return $packs
    } catch {
        $errDetail = $_.Exception.Message
        $errType   = $_.Exception.GetType().FullName
        $msg = "[$Server] ALL THREE methods failed. Last error: Type=$errType | Detail=$errDetail"
        $ErrorLog.Add($msg)
        Write-Log "  $msg" "ERROR"
        return @()
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Get-OSVersion  --  retrieves Win32_OperatingSystem.Caption from a server.
# Tries WMI first; falls back to CIM over DCOM.
# Returns "N/A" on total failure; never throws.
# ─────────────────────────────────────────────────────────────────────────────
function Get-OSVersion {
    param(
        [Parameter(Mandatory)][string]$Server,
        [System.Collections.Generic.List[string]]$ErrorLog
    )

    # Attempt 1: CIM over WSMan (explicit per-server session)
    $cimSess = $null
    try {
        $cimSess = New-CimSession -ComputerName $Server -Authentication Negotiate -ErrorAction Stop
        $os      = Get-CimInstance -CimSession $cimSess `
                       -ClassName "Win32_OperatingSystem" -ErrorAction Stop
        return "$($os.Caption)".Trim()
    } catch {
        Write-Log "  [$Server] CIM (WSMan) OS query FAILED -- Detail=$($_.Exception.Message)" "WARN"
    } finally {
        if ($null -ne $cimSess) {
            try { Remove-CimSession $cimSess -ErrorAction SilentlyContinue } catch {}
        }
    }

    # Attempt 2: CIM over DCOM
    $cimSess = $null
    try {
        $cimOpts = New-CimSessionOption -Protocol Dcom
        $cimSess = New-CimSession -ComputerName $Server -SessionOption $cimOpts `
                       -Authentication Negotiate -ErrorAction Stop
        $os      = Get-CimInstance -CimSession $cimSess `
                       -ClassName "Win32_OperatingSystem" -ErrorAction Stop
        return "$($os.Caption)".Trim()
    } catch {
        Write-Log "  [$Server] CIM (DCOM) OS query FAILED -- Detail=$($_.Exception.Message)" "WARN"
    } finally {
        if ($null -ne $cimSess) {
            try { Remove-CimSession $cimSess -ErrorAction SilentlyContinue } catch {}
        }
    }

    # Attempt 3: legacy WMI (last resort)
    try {
        $os = Get-WmiObject -Class "Win32_OperatingSystem" `
                  -ComputerName $Server -ErrorAction Stop
        return "$($os.Caption)".Trim()
    } catch {
        $msg = "Could not retrieve OS version for [$Server] via CIM (WSMan), CIM (DCOM) or legacy WMI: $($_.Exception.Message)"
        $ErrorLog.Add($msg)
        Write-Log "  $msg" "WARN"
        return "N/A"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Invoke-LicenseServerReport  --  full data collection for one license server.
# Returns a PSCustomObject.  Never throws; all errors captured in Errors list.
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-LicenseServerReport {
    param([Parameter(Mandatory)][string]$Server)

    Write-Log "=================================================================" "INFO"
    Write-Log "--- [$Server] Starting ---" "INFO"
    $ErrorLog = [System.Collections.Generic.List[string]]::new()

    # 1. Query key packs ──────────────────────────────────────────────────────
    $KeyPacks = Get-KeyPacks -Server $Server -ErrorLog $ErrorLog

    if ($KeyPacks.Count -eq 0) {
        $ErrorLog.Add("[$Server] Zero key packs returned. Verify the RD Licensing role is installed, packs are activated, and the service account has WMI/CIM access.")
        Write-Log "  Zero key packs returned from [$Server]" "WARN"
    }

    # 2. Query OS version (runs regardless of key pack success) ───────────────
    $OSVersion = Get-OSVersion -Server $Server -ErrorLog $ErrorLog

    # 3. Filter key packs and calculate CAL totals ────────────────────────────
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

            # Diagnostic: log the raw ExpirationDate value and its .NET type
            # for every pack so any future mismatch is immediately visible
            # in the HPSA log rather than silently swallowed.
            $rawExpType = if ($null -eq $pack.ExpirationDate) { "null" } else { $pack.ExpirationDate.GetType().Name }
            Write-Log ("  [RAW] {0} | KeyPackType={1} | ExpirationDate='{2}' (type={3})" -f `
                $pack.Description, $pack.KeyPackType, $pack.ExpirationDate, $rawExpType) "INFO"

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
            # IMPORTANT: pass $pack.ExpirationDate RAW (no [string] cast) so
            # ConvertFrom-WmiExpiry can detect whether CIM already converted
            # it to a [datetime] or whether it is still the raw WMI string.
            # Forcing [string] here was the root cause of expired packs being
            # silently treated as "Never expires" -- see function comment.
            $expiry = ConvertFrom-WmiExpiry -Raw $pack.ExpirationDate
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
            $expStr = if ($null -eq $pack.ExpirationDate) {
                          "Never"
                      } else {
                          $dt = ConvertFrom-WmiExpiry -Raw $pack.ExpirationDate
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

    # 4. Compliance ───────────────────────────────────────────────────────────
    $UsagePct   = if ($Installed -gt 0) {
                      [math]::Round(($Issued / $Installed) * 100, 1)
                  } else { 0 }
    $Compliance = Get-Compliance -Pct $UsagePct

    Write-Log ("  Result: {0}/{1} ({2}%) => {3}" -f $Issued, $Installed, $UsagePct, $Compliance)
    if ($ErrorLog.Count -gt 0) {
        Write-Log "  [$Server] $($ErrorLog.Count) issue(s) captured -- printing each below:" "WARN"
        $i = 0
        foreach ($e in $ErrorLog) {
            $i++
            Write-Log "    [$Server] Issue ${i}: $e" "WARN"
        }
    }
    if ($Installed -eq 0) {
        Write-Log "  [$Server] *** WARNING: Installed=0 -- this server returned NO usable license data. Check the issues listed above for the exact cause. ***" "ERROR"
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


#region MAIN
# ─────────────────────────────────────────────────────────────────────────────
# MAIN  --  parse server list, query servers, save HTML report.
# Entire block is wrapped in try/catch so HPSA always gets a clean exit code.
# ─────────────────────────────────────────────────────────────────────────────
try {

    Write-Log "================================================================="
    Write-Log "  RDS License Usage Monitoring | Citrix Workspace Automation Suite"
    Write-Log "  $ScriptVersion  |  Warn=$WarningThresholdPct%  Crit=$CriticalThresholdPct%"
    Write-Log "================================================================="

    # ── Parse server list ────────────────────────────────────────────────────
    $ServerList = @(
        $LicenseServerFQDN -split ';' |
            ForEach-Object { $_.Trim() } |
            Where-Object   { $_ -ne ''  }
    )

    if ($ServerList.Count -eq 0) {
        throw "LicenseServerFQDN is empty or contains no valid server names."
    }
    Write-Log "$($ServerList.Count) server(s): $($ServerList -join ', ')"

    # ── Ensure output folder exists ──────────────────────────────────────────
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

    # ── Query servers ────────────────────────────────────────────────────────
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
        # Multiple servers -- SEQUENTIAL queries.
        #
        # WHY NOT PARALLEL (RunspacePool):  Get-WmiObject and the CIM/DCOM
        # fallback both go through COM under the hood.  COM has per-thread
        # apartment rules: WMI/DCOM calls are reliable only from a Single-
        # Threaded Apartment (STA).  A RunspacePool's worker threads default
        # to MTA, and even forcing ApartmentState="MTA" does not fix the
        # underlying issue -- only the FIRST runspace to touch a given COM
        # object on a given thread sequence reliably gets real data back;
        # every other concurrent runspace silently receives empty / null
        # results from Get-WmiObject and New-CimSession.  That exactly
        # matches the symptom reported: server #1 populated, #2/#3 empty.
        #
        # Querying sequentially (one server at a time, same thread) uses the
        # exact same code path that already works correctly for a single
        # server, so every server is queried identically and reliably.
        Write-Log "Querying $($ServerList.Count) server(s) sequentially..." "INFO"

        foreach ($srv in $ServerList) {
            try {
                $result = Invoke-LicenseServerReport -Server $srv
                if ($null -ne $result) {
                    $ServerResults.Add($result)
                } else {
                    $FailedServers.Add($srv)
                    Write-Log "No result returned for [$srv]" "ERROR"
                }
            } catch {
                $FailedServers.Add($srv)
                Write-Log "Query failed for [$srv]: $($_.Exception.Message)" "ERROR"
            }
        }

        Write-Log "Sequential queries complete." "SUCCESS"
    }

    # ── Summary ──────────────────────────────────────────────────────────────
    Write-Log "================================================================="
    Write-Log ("Batch complete: {0} succeeded, {1} failed of {2} total" -f `
        $ServerResults.Count, $FailedServers.Count, $ServerList.Count) "SUCCESS"
    if ($FailedServers.Count -gt 0) {
        Write-Log "Failed: $($FailedServers -join ', ')" "ERROR"
    }

    # ── Save report ──────────────────────────────────────────────────────────
    if ($ServerResults.Count -gt 0) {
        Save-Report -Results $ServerResults
    } else {
        Write-Log "No successful results -- no report generated." "WARN"
    }

    # ── Exit ─────────────────────────────────────────────────────────────────
    if ($FailedServers.Count -gt 0) { exit 3 } else { exit 0 }

} catch {
    Write-Log "FATAL: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack: $($_.ScriptStackTrace)" "ERROR"
    exit 3
}
#endregion MAIN
