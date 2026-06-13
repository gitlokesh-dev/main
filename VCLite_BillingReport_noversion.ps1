#Requires -Version 5.1
# ==============================================================================
#  VCLite Citrix Billing Report  - LOCAL TEST BUILD
#  Credentials : Hardcoded in SECTION 1 below (for local testing only)
#  INI file    : NOT required
#  Date range  : Optional parameters; defaults to previous calendar month (UTC)
#  Output      : <ScriptDir>\output\VCLite_BillingReport_<stamp>.html
# ==============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$QueryStart = "",   # e.g. "2026-05-01T00:00:00Z"  -- defaults to start of last month
    [Parameter(Mandatory=$false)]
    [string]$QueryEnd   = ""    # e.g. "2026-05-31T23:59:59Z"  -- defaults to end of last month
)

# ==============================================================================
# SECTION 1 - CREDENTIALS & SETTINGS  (edit this block for local testing)
# ==============================================================================
$CustomerId   = "ewy3n89x3jns"
$ClientId     = "ba3e7acc-79b1-41ad-835c-90f10f4dd185"
$ClientSecret = "a6P_9bHH2ADWbWF5VCf0TQ=="
$TrustUrl     = "https://api-us.cloud.com/cctrustoauth2"
$MonitorUrl   = "https://api-us.cloud.com/monitorodata"

# IMPORTANT: Set this to the folder where VCLite_BillingReport.html is deployed.
# HPSA copies the PS1 to C:\Windows\TEMP at runtime, so $MyInvocation.MyCommand.Path
# would point to TEMP - not here. This variable pins the correct deploy location.
$DeployDir    = "C:\Scripts\VCLite"
# ==============================================================================

# ==============================================================================
# SCRIPT DIRECTORY & PATHS
# Always use $DeployDir (set in SECTION 1) as the base path.
# Do NOT use $MyInvocation.MyCommand.Path here - HPSA copies the PS1 to
# C:\Windows\TEMP at runtime so that path would be wrong.
# ==============================================================================
$ScriptDir    = $DeployDir
$TemplatePath = Join-Path $ScriptDir "VCLite_BillingReport.html"
$OutputFolder = Join-Path $ScriptDir "output"

# ==============================================================================
# DATE RANGE  - defaults to previous full calendar month (UTC)
# Fix: use .NET DateTime formatting to avoid PS string interpolation issues
#      with format specifiers containing T and Z.
# ==============================================================================
$_utcNow         = [datetime]::UtcNow
$_firstThisMonth = [datetime]::new($_utcNow.Year, $_utcNow.Month, 1, 0, 0, 0,
                       [System.DateTimeKind]::Utc)
$_firstLastMonth = $_firstThisMonth.AddMonths(-1)
$_lastLastMonth  = $_firstThisMonth.AddSeconds(-1)

if ([string]::IsNullOrWhiteSpace($QueryStart)) {
    # Build ISO-8601 string without relying on format-specifier quoting
    $QueryStart = $_firstLastMonth.ToString("yyyy-MM-dd") + "T00:00:00Z"
}
if ([string]::IsNullOrWhiteSpace($QueryEnd)) {
    $QueryEnd = $_lastLastMonth.ToString("yyyy-MM-dd") + "T" +
                $_lastLastMonth.ToString("HH:mm:ss") + "Z"
}

# ==============================================================================
# CONSTANTS
# ==============================================================================
$ScriptVersion = "9.4"
$ApiPageSize   = 1000
$MaxRetries    = 3
$RetryDelayMs  = 2000
$HtmlChunkSize = 200000   # rows per output HTML file (reduce if memory constrained)

$ODataSelect = "StartDate,EndDate"
$ODataExpand = (
    "User(`$select=UserName,FullName,Upn)," +
    "Machine(`$select=Name,OSType;" +
        "`$expand=Catalog(`$select=Name),DesktopGroup(`$select=Name))," +
    "CurrentConnection(`$select=ClientVersion,ClientPlatform,ClientAddress," +
        "ClientPublicIP,ClientName,Protocol,ClientISP," +
        "ClientLocationCountry,ClientLocationCity," +
        "ConnectedViaHostName,ConnectedViaIPAddress," +
        "LaunchedViaHostName,LaunchedViaIPAddress)"
)

$TodayUtcDate = [datetime]::UtcNow.ToString("yyyy-MM-dd")

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================
function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    $ts    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "OK"    { "Green"  }
        "WARN"  { "Yellow" }
        "ERROR" { "Red"    }
        "STEP"  { "Cyan"   }
        default { "White"  }
    }
    Write-Host "[$ts][$Level] $Msg" -ForegroundColor $color
}

# Safe null-to-empty-string conversion
function Safe-Str {
    param($v)
    if ($null -eq $v) { return "" }
    return [string]$v
}

function Get-SHA256Hash {
    param([string]$InputString)
    try {
        $sha   = [System.Security.Cryptography.SHA256]::Create()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputString)
        $hash  = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace("-", "").ToLower()
        $sha.Dispose()
        return $hash
    } catch { return "hash-unavailable" }
}

# Sanitise a JSON string so it is safe to embed inside an HTML <script> block
function Sanitize-Json {
    param([string]$Json)
    # Use string,string overload for ALL Replace calls.
    # char overload cannot accept empty string and throws at runtime.
    # Escape </script> using unicode escapes so it cannot prematurely close
    # a <script> tag. Browsers parse the JSON string correctly after this.
    $Json = $Json.Replace('</script>', '<\/script>')
    $Json = $Json.Replace([string][char]0x2028, ' ')   # LS - line separator
    $Json = $Json.Replace([string][char]0x2029, ' ')   # PS - paragraph separator
    $Json = $Json.Replace([string][char]0x0000, '')    # NUL - remove entirely
    return $Json
}

function ConvertTo-Base64Utf8 {
    param([string]$InputString)
    # Encode to Base64 then wrap at 76 chars per line (MIME standard).
    # Line-wrapping prevents HPSA job-step output buffer truncation and
    # lets Camunda reassemble by stripping newlines between the markers.
    $raw  = [Convert]::ToBase64String(
                [System.Text.Encoding]::UTF8.GetBytes($InputString))
    $sb   = [System.Text.StringBuilder]::new($raw.Length + ($raw.Length / 76) + 10)
    $pos  = 0
    while ($pos -lt $raw.Length) {
        $len = [Math]::Min(76, $raw.Length - $pos)
        [void]$sb.AppendLine($raw.Substring($pos, $len))
        $pos += $len
    }
    return $sb.ToString().TrimEnd()
}

# ==============================================================================
# SESSION VALIDITY
# Rule 1 : StartDate missing                    -> skip
# Rule 2 : EndDate missing (session still live) -> skip
# Rule 3 : StartDate >= EndDate when parsed     -> skip (zero-duration / equal)
#           Parsed comparison catches different string representations of the
#           same instant (e.g. with/without milliseconds).
# Rule 4 : StartDate date-part = today UTC      -> skip (may still be running)
# ==============================================================================
function Test-ValidSession {
    param([Parameter(Mandatory)]$Session)
    $sd = Safe-Str $Session.StartDate
    $ed = Safe-Str $Session.EndDate

    if ([string]::IsNullOrWhiteSpace($sd)) { return $false }   # Rule 1
    if ([string]::IsNullOrWhiteSpace($ed)) { return $false }   # Rule 2

    try {                                                        # Rule 3
        $ts = [datetime]::Parse($sd, $null,
                  [System.Globalization.DateTimeStyles]::AssumeUniversal)
        $te = [datetime]::Parse($ed, $null,
                  [System.Globalization.DateTimeStyles]::AssumeUniversal)
        if ($ts -ge $te) { return $false }
    } catch {
        if ($sd -eq $ed) { return $false }   # fallback string compare
    }

    $sdDate = $sd.Substring(0, [Math]::Min(10, $sd.Length))
    if ($sdDate -eq $TodayUtcDate) { return $false }            # Rule 4

    return $true
}

# ==============================================================================
# DATA FLATTENING
# Safely extracts nested API properties, returning "" for any missing value.
# ==============================================================================
function ConvertTo-FlatRow {
    param([Parameter(Mandatory)]$Session)

    $u  = if ($null -ne $Session.User)              { $Session.User }              else { $null }
    $m  = if ($null -ne $Session.Machine)           { $Session.Machine }           else { $null }
    $ca = if ($null -ne $m -and $null -ne $m.Catalog)      { $m.Catalog }      else { $null }
    $dg = if ($null -ne $m -and $null -ne $m.DesktopGroup) { $m.DesktopGroup } else { $null }
    $c  = if ($null -ne $Session.CurrentConnection) { $Session.CurrentConnection } else { $null }

    return [PSCustomObject]@{
        StartDate             = Safe-Str $Session.StartDate
        EndDate               = Safe-Str $Session.EndDate
        UserName              = if ($u)  { Safe-Str $u.UserName  } else { "" }
        FullName              = if ($u)  { Safe-Str $u.FullName  } else { "" }
        UserUPN               = if ($u)  { Safe-Str $u.Upn       } else { "" }
        MachineName           = if ($m)  { Safe-Str $m.Name      } else { "" }
        MachineOS             = if ($m)  { Safe-Str $m.OSType    } else { "" }
        CatalogName           = if ($ca) { Safe-Str $ca.Name     } else { "" }
        DesktopGroupName      = if ($dg) { Safe-Str $dg.Name     } else { "" }
        ClientVersion         = if ($c)  { Safe-Str $c.ClientVersion         } else { "" }
        ClientPlatform        = if ($c)  { Safe-Str $c.ClientPlatform        } else { "" }
        ClientName            = if ($c)  { Safe-Str $c.ClientName            } else { "" }
        ClientIP              = if ($c)  { Safe-Str $c.ClientAddress         } else { "" }
        ClientPublicIP        = if ($c)  { Safe-Str $c.ClientPublicIP        } else { "" }
        Protocol              = if ($c)  { Safe-Str $c.Protocol              } else { "" }
        ClientISP             = if ($c)  { Safe-Str $c.ClientISP             } else { "" }
        ClientCountry         = if ($c)  { Safe-Str $c.ClientLocationCountry } else { "" }
        ClientCity            = if ($c)  { Safe-Str $c.ClientLocationCity    } else { "" }
        ConnectedViaHostName  = if ($c)  { Safe-Str $c.ConnectedViaHostName  } else { "" }
        ConnectedViaIPAddress = if ($c)  { Safe-Str $c.ConnectedViaIPAddress } else { "" }
        LaunchedViaHostName   = if ($c)  { Safe-Str $c.LaunchedViaHostName   } else { "" }
        LaunchedViaIPAddress  = if ($c)  { Safe-Str $c.LaunchedViaIPAddress  } else { "" }
    }
}

# ==============================================================================
# AUTHENTICATION
# ==============================================================================
function Get-BearerToken {
    param(
        [string]$CustomerId,
        [string]$ClientId,
        [string]$ClientSecret
    )
    Write-Log "Requesting bearer token..." "STEP"
    $uri  = "$TrustUrl/$CustomerId/tokens/clients"
    $body = "grant_type=client_credentials" +
            "&client_id=$([uri]::EscapeDataString($ClientId))" +
            "&client_secret=$([uri]::EscapeDataString($ClientSecret))"
    try {
        $response = Invoke-WebRequest -Uri $uri -Method POST -Body $body `
                        -ContentType "application/x-www-form-urlencoded" `
                        -UseBasicParsing -ErrorAction Stop
        $token = ($response.Content | ConvertFrom-Json).access_token
        if ([string]::IsNullOrWhiteSpace($token)) {
            throw "Empty token returned - verify CustomerId, ClientId, ClientSecret."
        }
        Write-Log "Bearer token acquired." "OK"
        return $token
    } catch {
        throw "Authentication failed: $($_.Exception.Message)"
    }
}

# ==============================================================================
# ==============================================================================
# EMBEDDED HTML TEMPLATE
# Stored here so PS1 is self-contained. If VCLite_BillingReport.html is missing
# from the deploy folder it is written automatically on first run.
# ==============================================================================
function Get-EmbeddedTemplate {
    return @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Citrix Session Report v9.0</title>
<style>
/* ===========================================================
   CITRIX SESSION REPORT  v9.0
   Brand   : rgb(216,0,116) -- Company Standard
   Theme   : Light (white / #f4f5f8)
   Fixes   : Row-number off-by-one &middot; reset clears active class
             &middot; export key _rn corrected &middot; duration filter logic
   New     : Min/Max Duration &middot; UserName dropdown &middot; ISP filter
             &middot; two-row filter bar with section labels
             &middot; "Skipped" stat card &middot; improved rbar info
=========================================================== */
:root{
  --brand       :rgb(216,0,116);
  --brand-dk    :rgb(175,0,93);
  --brand-lt    :rgba(216,0,116,.10);
  --brand-xlt   :rgba(216,0,116,.05);
  --brand-glow  :rgba(216,0,116,.20);
  --brand-border:rgba(216,0,116,.28);
  --white       :#ffffff;
  --bg          :#f4f5f8;
  --bg2         :#f9fafb;
  --border      :#e0e4ea;
  --border-lt   :#edf0f4;
  --text        :#1a1d23;
  --text-sub    :#4b5563;
  --text-muted  :#9ca3af;
  --green       :#059669;
  --amber       :#d97706;
  --blue        :#2563eb;
  --red         :#dc2626;
  --row-even    :#fdf4f9;
  --row-odd     :#ffffff;
  --row-hover   :rgba(216,0,116,.06);
  --sh-hdr      :0 2px 10px rgba(216,0,116,.18),0 1px 3px rgba(0,0,0,.10);
  --sh-card     :0 1px 4px rgba(0,0,0,.07);
  --sh-tbl      :0 2px 10px rgba(0,0,0,.09);
  --radius      :8px;
  --rsm         :5px;
}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
html,body{height:100%}
body{font-family:Arial,Helvetica,sans-serif;font-size:13px;
  background:var(--bg);color:var(--text);
  display:flex;flex-direction:column;overflow:hidden}

/* == Setup Banner ======================================== */
#setupBanner{background:#fff8f0;border-bottom:3px solid #f59e0b;
  padding:14px 22px;display:none}
#setupBanner.show{display:block}
.sb-title{color:#92400e;font-size:13px;font-weight:700;
  margin-bottom:9px;display:flex;align-items:center;gap:7px}
.sb-steps{display:flex;flex-wrap:wrap;gap:6px}
.sb-step{display:flex;align-items:flex-start;gap:8px;flex:1;min-width:200px;
  background:#fffbf5;border:1px solid #fde68a;border-radius:6px;padding:8px 11px}
.sb-num{background:var(--brand);color:#fff;border-radius:50%;
  width:18px;height:18px;display:flex;align-items:center;justify-content:center;
  font-size:9px;font-weight:700;flex-shrink:0;margin-top:1px}
.sb-step p{font-size:11.5px;color:#78350f;line-height:1.5}
.sb-step code{background:rgba(0,0,0,.07);border-radius:3px;padding:1px 5px;
  font-family:'Courier New',monospace;font-size:10.5px;color:#7c3aed}

/* == Header ============================================== */
.hdr{background:var(--brand);color:#fff;padding:0 20px;height:50px;
  display:flex;align-items:center;justify-content:space-between;
  box-shadow:var(--sh-hdr);position:sticky;top:0;z-index:600;flex-shrink:0}
.hdr-left{display:flex;align-items:center;gap:9px}
.hdr-icon{width:28px;height:28px;background:rgba(255,255,255,.16);
  border-radius:6px;border:1px solid rgba(255,255,255,.26);
  display:flex;align-items:center;justify-content:center;flex-shrink:0}
.hdr-title{font-size:15px;font-weight:700;letter-spacing:-.1px}
.hdr-ver{font-size:10px;font-weight:600;background:rgba(255,255,255,.17);
  color:#fff;padding:2px 7px;border-radius:9px;margin-left:4px;
  border:1px solid rgba(255,255,255,.28)}
.hdr-meta{font-size:10px;color:rgba(255,255,255,.72);margin-left:6px}
.hdr-right{display:flex;align-items:center;gap:7px}

/* == Buttons ============================================= */
.btn{display:inline-flex;align-items:center;gap:5px;padding:0 12px;height:28px;
  border:none;border-radius:var(--rsm);font-size:11px;font-weight:700;
  cursor:pointer;transition:filter .12s,transform .09s;
  white-space:nowrap;font-family:inherit;position:relative}
.btn:hover{filter:brightness(1.10);transform:translateY(-1px)}
.btn:active{transform:none;filter:brightness(.92)}
.btn:disabled{opacity:.35;cursor:not-allowed;transform:none;filter:none}
.btn-csv {background:#fff;color:var(--brand);
  border:1.5px solid rgba(255,255,255,.55);box-shadow:0 1px 4px rgba(0,0,0,.13)}
.btn-xlsx{background:rgba(255,255,255,.14);color:#fff;
  border:1.5px solid rgba(255,255,255,.32)}
.btn-apply{background:var(--brand);color:#fff;
  box-shadow:0 1px 6px var(--brand-glow)}
.btn-apply:hover{background:var(--brand-dk)}
.btn-reset{background:var(--white);color:var(--text-sub);
  border:1px solid var(--border)}
.btn-reset:hover{border-color:var(--brand);color:var(--brand)}
.fbadge{display:none;position:absolute;top:-6px;right:-6px;
  background:var(--amber);color:#fff;border-radius:7px;
  font-size:8.5px;font-weight:800;padding:1px 4px;line-height:13px;
  border:1.5px solid #fff}
.fbadge.on{display:block}

/* == Stat Cards ========================================== */
.stats-strip{background:var(--white);border-bottom:1px solid var(--border);
  padding:8px 20px;display:flex;gap:8px;flex-wrap:wrap;flex-shrink:0}
.stat-card{flex:1;min-width:95px;background:var(--bg2);
  border:1px solid var(--border);border-top:3px solid var(--brand);
  border-radius:var(--radius);padding:8px 12px;
  box-shadow:var(--sh-card);text-align:center;transition:box-shadow .15s}
.stat-card:hover{box-shadow:0 3px 10px rgba(216,0,116,.14)}
.stat-card .val{font-size:20px;font-weight:700;color:var(--brand);line-height:1.1;
  font-family:'Courier New',Courier,monospace}
.stat-card .lbl{font-size:8.5px;color:var(--text-muted);
  text-transform:uppercase;letter-spacing:.7px;margin-top:3px;font-weight:600}
.stat-card.skipped .val{color:var(--amber)}
.stat-card.skipped{border-top-color:var(--amber)}

/* == Filter Bar -- 2 rows ================================= */
.fbar{background:var(--white);border-bottom:2px solid var(--border);
  padding:8px 20px;display:flex;flex-direction:column;gap:6px;
  position:sticky;top:50px;z-index:500;flex-shrink:0}
.frow{display:flex;flex-wrap:wrap;gap:7px;align-items:flex-end}
.frow-label{font-size:9px;font-weight:700;color:var(--brand);
  text-transform:uppercase;letter-spacing:.5px;align-self:center;
  padding:0 4px 0 2px;white-space:nowrap;border-left:2px solid var(--brand);
  padding-left:6px;margin-right:2px}
.fg{display:flex;flex-direction:column;gap:3px}
.fg label{font-size:9px;font-weight:700;color:var(--text-muted);
  text-transform:uppercase;letter-spacing:.55px}
.fg input,.fg select{height:27px;padding:0 7px;
  border:1px solid var(--border);border-radius:var(--rsm);
  font-size:11.5px;font-family:Arial,Helvetica,sans-serif;
  background:var(--white);color:var(--text);outline:none;
  transition:border-color .12s,box-shadow .12s}
.fg input:focus,.fg select:focus{
  border-color:var(--brand);box-shadow:0 0 0 2px var(--brand-lt)}
.fg input.active,.fg select.active{
  border-color:var(--brand);background:var(--brand-xlt);
  font-weight:700;color:var(--brand)}
.fg-wide{min-width:170px}
.fg-med {min-width:115px}
.fg-sm  {min-width:80px}
.fg-dur {min-width:88px}

/* filter chip & notice */
#filterChip{display:none;align-items:center;gap:4px;align-self:flex-end;
  background:var(--brand-lt);border:1px solid var(--brand-border);
  border-radius:12px;padding:2px 9px;font-size:10.5px;font-weight:700;
  color:var(--brand);white-space:nowrap;height:27px}
#filterChip.on{display:flex}
.date-note{display:none;align-items:center;gap:4px;align-self:flex-end;
  background:#fff8e1;border:1px solid #fbbf24;border-radius:12px;
  padding:2px 9px;font-size:10px;font-weight:600;
  color:#92400e;white-space:nowrap;height:27px}
.date-note.on{display:flex}
.fg-act{display:flex;gap:6px;align-self:flex-end}
.frow-sep{width:1px;background:var(--border);height:27px;align-self:flex-end;margin:0 2px}

/* == Result Bar ========================================== */
.rbar{display:flex;align-items:center;justify-content:space-between;
  flex-wrap:wrap;gap:7px;padding:4px 20px;font-size:11.5px;
  color:var(--text-sub);background:var(--bg2);
  border-bottom:1px solid var(--border);flex-shrink:0}
.rbar-left{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.prog{display:none;align-items:center;gap:7px;font-size:11px;
  color:var(--brand);font-weight:700}
.prog-track{width:130px;height:4px;background:var(--brand-lt);
  border-radius:3px;overflow:hidden}
.prog-fill{height:100%;width:0%;background:var(--brand);
  border-radius:3px;transition:width .2s}

/* == Table =============================================== */
.t-outer{flex:1;overflow:hidden;padding:8px 20px 8px;
  display:flex;flex-direction:column}
.vscroll-wrap{flex:1;position:relative;overflow-x:auto;overflow-y:auto;
  border:1px solid var(--border);border-radius:var(--radius);
  box-shadow:var(--sh-tbl);background:var(--white)}
.vscroll-head{position:sticky;top:0;z-index:10}
.vscroll-head table{width:100%;border-collapse:collapse;min-width:2750px}
th{background:rgb(216,0,116);color:#fff;padding:8px 10px;text-align:left;
  white-space:nowrap;font-weight:700;font-size:10.5px;letter-spacing:.25px;
  border-right:1px solid rgba(255,255,255,.14);
  border-bottom:2px solid rgba(0,0,0,.12);
  user-select:none;cursor:pointer}
th:last-child{border-right:none}
th:hover{background:rgb(175,0,93)}
th.sort-asc::after {content:" ^";font-size:8.5px;opacity:.85}
th.sort-desc::after{content:" v";font-size:8.5px;opacity:.85}
th.no-sort{cursor:default}
.vscroll-body{min-width:2750px;background:var(--white)}
.vrow{display:flex;transition:background .06s}
.vrow:hover .vcell{background:var(--row-hover)!important}
.vcell{flex-shrink:0;padding:4px 10px;
  border-bottom:1px solid var(--border-lt);
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis;
  font-size:11.5px;display:flex;align-items:center}
.vrow.even .vcell{background:var(--row-even)}
.vrow.odd  .vcell{background:var(--row-odd)}
.vcell.num  {color:var(--text-muted);font-size:10px;
  font-family:'Courier New',monospace;justify-content:flex-end}
.vcell.dur  {font-family:'Courier New',monospace;font-size:11px;
  color:var(--green);font-weight:700}
.vcell.mono {font-family:'Courier New',monospace;font-size:11px;color:var(--blue)}
.vcell.bold {font-weight:700;color:var(--text)}
.vcell.muted{color:var(--text-muted);font-size:11px}
.no-rows{text-align:center;padding:60px 20px;color:var(--text-muted);font-size:13px}
.no-rows svg{display:block;margin:0 auto 12px;opacity:.3}

/* == Badges ============================================== */
.bdg{display:inline-block;padding:1px 7px;border-radius:9px;
  font-size:10px;font-weight:700;letter-spacing:.1px}
.b-win{background:#dbeafe;color:#1d4ed8}
.b-mac{background:#fce7f3;color:#9d174d}
.b-lnx{background:#d1fae5;color:#065f46}
.b-ios{background:#ede9fe;color:#5b21b6}
.b-adr{background:#fef3c7;color:#92400e}
.b-oth{background:#f3f4f6;color:#374151}
.b-hdx{background:#d1fae5;color:#065f46}
.b-rdp{background:#dbeafe;color:#1d4ed8}
.b-prt{background:#f3f4f6;color:#374151}

/* == Pager =============================================== */
.pgr{display:flex;align-items:center;flex-wrap:wrap;gap:5px;
  padding:6px 20px;background:var(--white);
  border-top:1px solid var(--border);font-size:11.5px;flex-shrink:0}
.pgr-info{color:var(--text-sub)}
.pgr select,.pgr button{font-family:inherit;font-size:11px;
  border:1px solid var(--border);border-radius:var(--rsm);
  background:var(--white);color:var(--text);cursor:pointer;
  transition:all .1s}
.pgr select{padding:3px 6px}
.pgr button{padding:2px 10px}
.pgr button:hover:not(.pga):not(:disabled){
  background:var(--brand-lt);border-color:var(--brand-border);color:var(--brand)}
.pgr button.pga{background:var(--brand);color:#fff;border-color:var(--brand)}
.pgr button:disabled{opacity:.28;cursor:not-allowed}

/* == Footer ============================================== */
.footer{text-align:center;padding:5px;font-size:10px;
  color:var(--text-muted);border-top:1px solid var(--border);
  background:var(--white);flex-shrink:0;line-height:1.7}
.footer strong{color:var(--text-sub)}

/* == Toast =============================================== */
.toast{position:fixed;bottom:18px;right:18px;background:#1f2937;color:#fff;
  padding:8px 15px;border-radius:8px;font-size:12px;font-weight:600;
  box-shadow:0 4px 14px rgba(0,0,0,.28);z-index:9999;
  border-left:3px solid var(--brand);
  opacity:0;transform:translateY(8px);
  transition:opacity .23s,transform .23s;pointer-events:none}
.toast.on{opacity:1;transform:translateY(0)}
::-webkit-scrollbar{width:5px;height:5px}
::-webkit-scrollbar-track{background:#f0f0f0}
::-webkit-scrollbar-thumb{background:rgba(216,0,116,.33);border-radius:3px}
::-webkit-scrollbar-thumb:hover{background:var(--brand)}
</style>
</head>
<body>

<!-- DATA blocks -- PS1 replaces placeholder tokens -->
<script type="application/json" id="citrix-data">CITRIX_DATA_PLACEHOLDER_JSON_ARRAY</script>
<script type="application/json" id="citrix-meta">CITRIX_META_PLACEHOLDER_JSON_OBJECT</script>

<!-- Setup banner (visible only when template is raw) -->
<div id="setupBanner">
  <div class="sb-title">
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
      <path d="M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z"/>
      <line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/>
    </svg>
    Raw template -- not yet populated with live data
  </div>
  <div class="sb-steps">
    <div class="sb-step"><div class="sb-num">1</div>
      <p>Place this file in same folder as <code>CitrixSessionReport_v9.ps1</code></p></div>
    <div class="sb-step"><div class="sb-num">2</div>
      <p>Fill in <code>$CustomerId</code>, <code>$ClientId</code>, <code>$ClientSecretBase64</code> &amp; date range</p></div>
    <div class="sb-step"><div class="sb-num">3</div>
      <p>Run: <code>powershell -ExecutionPolicy Bypass -File CitrixSessionReport_v9.ps1</code></p></div>
    <div class="sb-step"><div class="sb-num">4</div>
      <p>Open <strong>output</strong> file from <code>%USERPROFILE%\Desktop\CitrixReports\</code></p></div>
  </div>
</div>

<!-- Header -->
<header class="hdr">
  <div class="hdr-left">
    <div class="hdr-icon">
      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.2">
        <rect x="2" y="3" width="20" height="14" rx="2"/>
        <path d="M8 21h8M12 17v4"/>
      </svg>
    </div>
    <span class="hdr-title">Citrix Session Report</span>
    <span class="hdr-ver">v9.0</span>
    <span class="hdr-meta" id="hdrMeta"></span>
  </div>
  <div class="hdr-right">
    <button class="btn btn-csv" id="btnCSV" onclick="doCSV()" title="Download CSV (respects active filters)">
      <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
        <path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4"/>
        <polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/>
      </svg>v CSV<span class="fbadge" id="csvBadge">F</span>
    </button>
    <button class="btn btn-xlsx" id="btnExcel" onclick="doExcel()" title="Download Excel (respects active filters)">
      <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
        <path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4"/>
        <polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/>
      </svg>v Excel<span class="fbadge" id="excelBadge">F</span>
    </button>
  </div>
</header>

<!-- Stat cards -->
<div class="stats-strip">
  <div class="stat-card"><div class="val" id="sc-total">--</div><div class="lbl">Total Sessions</div></div>
  <div class="stat-card"><div class="val" id="sc-users">--</div><div class="lbl">Unique Users</div></div>
  <div class="stat-card"><div class="val" id="sc-mach">--</div><div class="lbl">Machines</div></div>
  <div class="stat-card"><div class="val" id="sc-ctry">--</div><div class="lbl">Countries</div></div>
  <div class="stat-card"><div class="val" id="sc-plat">--</div><div class="lbl">Platforms</div></div>
  <div class="stat-card"><div class="val" id="sc-cat">--</div><div class="lbl">Catalogs</div></div>
  <div class="stat-card"><div class="val" id="sc-avgd">--</div><div class="lbl">Avg Duration</div></div>
  <div class="stat-card skipped"><div class="val" id="sc-skip">0</div><div class="lbl">Skipped</div></div>
</div>

<!-- Filter bar -- Row 1: Text + Dropdowns -->
<div class="fbar">
  <div class="frow">
    <span class="frow-label">Search &amp; Filter</span>

    <div class="fg fg-wide">
      <label>Search</label>
      <input type="text" id="fSrch" placeholder="User / Machine / IP / ISP..." oninput="debounce()">
    </div>

    <div class="fg fg-med">
      <label>User Name</label>
      <select id="fUN" onchange="applyFilters()"><option value="">All Users</option></select>
    </div>

    <div class="fg fg-med">
      <label>Country</label>
      <select id="fCo" onchange="applyFilters()"><option value="">All Countries</option></select>
    </div>

    <div class="fg fg-med">
      <label>City</label>
      <select id="fCi" onchange="applyFilters()"><option value="">All Cities</option></select>
    </div>

    <div class="fg fg-med">
      <label>ISP</label>
      <select id="fIS" onchange="applyFilters()"><option value="">All ISPs</option></select>
    </div>

    <div class="fg fg-med">
      <label>Platform</label>
      <select id="fPl" onchange="applyFilters()"><option value="">All Platforms</option></select>
    </div>

    <div class="fg fg-med">
      <label>OS Type</label>
      <select id="fOS" onchange="applyFilters()"><option value="">All OS</option></select>
    </div>

    <div class="fg fg-med">
      <label>Catalog</label>
      <select id="fCa" onchange="applyFilters()"><option value="">All Catalogs</option></select>
    </div>

    <div class="fg fg-med">
      <label>Desktop Group</label>
      <select id="fDG" onchange="applyFilters()"><option value="">All Groups</option></select>
    </div>

    <div class="fg fg-med">
      <label>Protocol</label>
      <select id="fPr" onchange="applyFilters()"><option value="">All Protocols</option></select>
    </div>
  </div>

  <!-- Row 2: Date range + Duration range + actions -->
  <div class="frow">
    <span class="frow-label">Date &amp; Duration</span>

    <div class="fg fg-med">
      <label>Date From</label>
      <input type="date" id="fDf" onchange="applyFilters()">
    </div>

    <div class="fg fg-med">
      <label>Date To</label>
      <input type="date" id="fDt" onchange="applyFilters()">
    </div>

    <div class="frow-sep"></div>

    <div class="fg fg-dur">
      <label>Min Duration</label>
      <input type="number" id="fDurMin" min="0" placeholder="secs" title="Minimum session duration in seconds" oninput="debounce()">
    </div>

    <div class="fg fg-dur">
      <label>Max Duration</label>
      <input type="number" id="fDurMax" min="0" placeholder="secs" title="Maximum session duration in seconds" oninput="debounce()">
    </div>

    <div class="frow-sep"></div>

    <!-- Active filter count chip -->
    <div id="filterChip">
      <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
        <polygon points="22 3 2 3 10 12.46 10 19 14 21 14 12.46 22 3"/>
      </svg>
      <span id="filterChipTxt">0 filters</span>
    </div>

    <!-- Today / zero-duration exclusion notice -->
    <div class="date-note" id="dateNote">
      <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
        <circle cx="12" cy="12" r="10"/>
        <line x1="12" y1="8" x2="12" y2="12"/>
        <line x1="12" y1="16" x2="12.01" y2="16"/>
      </svg>
      Today &amp; zero-duration sessions excluded
    </div>

    <div class="fg-act">
      <button class="btn btn-apply" onclick="applyFilters()">Apply</button>
      <button class="btn btn-reset" onclick="resetFilters()">Reset All</button>
    </div>
  </div>
</div>

<!-- Result / progress bar -->
<div class="rbar">
  <div class="rbar-left">
    <span id="rbarTxt">Loading...</span>
    <span id="rbarSkip" style="color:var(--amber);font-size:11px;display:none"></span>
  </div>
  <div class="prog" id="progArea">
    <span id="progTxt"></span>
    <div class="prog-track"><div class="prog-fill" id="progFill"></div></div>
  </div>
</div>

<!-- Virtual scroll table -->
<div class="t-outer">
  <div class="vscroll-wrap" id="vWrap">
    <div class="vscroll-head">
      <table><thead><tr>
        <th class="no-sort" style="width:48px">#</th>
        <th onclick="sortBy('StartDate')">Start Date</th>
        <th onclick="sortBy('EndDate')">End Date</th>
        <th onclick="sortBy('_durSecs')">Duration</th>
        <th onclick="sortBy('UserName')">User Name</th>
        <th onclick="sortBy('FullName')">Full Name</th>
        <th onclick="sortBy('UserUPN')">UPN</th>
        <th onclick="sortBy('MachineName')">Machine</th>
        <th onclick="sortBy('MachineOS')">OS</th>
        <th onclick="sortBy('CatalogName')">Catalog</th>
        <th onclick="sortBy('DesktopGroupName')">Desktop Group</th>
        <th onclick="sortBy('ClientPlatform')">Platform</th>
        <th onclick="sortBy('Protocol')">Protocol</th>
        <th onclick="sortBy('ClientName')">Client Name</th>
        <th onclick="sortBy('ClientVersion')">Client Ver</th>
        <th onclick="sortBy('ClientIP')">Client IP</th>
        <th onclick="sortBy('ClientPublicIP')">Public IP</th>
        <th onclick="sortBy('ClientCountry')">Country</th>
        <th onclick="sortBy('ClientCity')">City</th>
        <th onclick="sortBy('ClientISP')">ISP</th>
        <th onclick="sortBy('ConnectedViaHostName')">Connected Via Host</th>
        <th onclick="sortBy('ConnectedViaIPAddress')">Connected Via IP</th>
        <th onclick="sortBy('LaunchedViaHostName')">Launched Via Host</th>
        <th onclick="sortBy('LaunchedViaIPAddress')">Launched Via IP</th>
      </tr></thead></table>
    </div>
    <div id="vBody"></div>
  </div>
</div>

<!-- Pager -->
<div class="pgr">
  <span class="pgr-info">Rows per page:</span>
  <select id="pgSz" onchange="changePageSize()">
    <option value="200">200</option>
    <option value="500">500</option>
    <option value="1000" selected>1000</option>
    <option value="2000">2000</option>
    <option value="5000">5000</option>
  </select>
  <button id="pgFi" onclick="goPage(1)">&laquo;</button>
  <button id="pgPv" onclick="goPage(curPage-1)">&lsaquo; Prev</button>
  <span id="pgNm"></span>
  <button id="pgNx" onclick="goPage(curPage+1)">Next &rsaquo;</button>
  <button id="pgLa" onclick="goPage(totalPages())">&raquo;</button>
  <span id="pgIn" class="pgr-info" style="margin-left:5px"></span>
</div>

<!-- Footer -->
<div class="footer">
  <span id="ftrLine1"><strong>Citrix Session Report v9.0</strong></span>
  &nbsp;|&nbsp;<span id="ftrLine2"></span>
</div>

<div class="toast" id="toast"></div>

<script>
/* ===========================================================
   CITRIX SESSION REPORT v9.0 -- Engine
   BUG FIXES vs v8:
     1. Row numbers now always 1-based from absolute position
     2. resetFilters() fully clears every .active class
     3. Export row-number key fixed (_rn handled inline)
     4. Duration filter uses parsed float, not NaN check
   NEW:
     5. UserName dropdown filter
     6. ISP dropdown filter
     7. Min / Max Duration (seconds) filters
     8. Skipped stat card
     9. rbar shows skipped count separately
    10. Two-row filter bar with section labels
=========================================================== */

/* -- Column definitions ----------------------------------- */
var COLS=[
  {key:"StartDate",             w:148,cls:""},
  {key:"EndDate",               w:148,cls:""},
  {key:"_durLabel",             w:90, cls:"dur"},
  {key:"UserName",              w:130,cls:"bold"},
  {key:"FullName",              w:145,cls:""},
  {key:"UserUPN",               w:185,cls:"muted"},
  {key:"MachineName",           w:150,cls:""},
  {key:"MachineOS",             w:130,cls:""},
  {key:"CatalogName",           w:130,cls:""},
  {key:"DesktopGroupName",      w:145,cls:""},
  {key:"ClientPlatform",        w:100,cls:"bdg-plat"},
  {key:"Protocol",              w:82, cls:"bdg-proto"},
  {key:"ClientName",            w:145,cls:""},
  {key:"ClientVersion",         w:125,cls:"muted"},
  {key:"ClientIP",              w:130,cls:"mono"},
  {key:"ClientPublicIP",        w:130,cls:"mono"},
  {key:"ClientCountry",         w:110,cls:""},
  {key:"ClientCity",            w:110,cls:""},
  {key:"ClientISP",             w:165,cls:""},
  {key:"ConnectedViaHostName",  w:185,cls:""},
  {key:"ConnectedViaIPAddress", w:142,cls:"mono"},
  {key:"LaunchedViaHostName",   w:185,cls:""},
  {key:"LaunchedViaIPAddress",  w:142,cls:"mono"}
];
var NUM_W=48, ROW_H=30;

/* -- State ------------------------------------------------ */
var RAW=[], filtered=[], META={};
var SKIPPED_TOTAL=0;
var curPage=1, pageSize=1000;
var debT=null, sortCol="", sortAsc=true;
var vWrap=null, vBody=null, pageRows=[];
var TODAY=todayLocal();

/* -- Today string ----------------------------------------- */
function todayLocal(){
  var d=new Date();
  return d.getFullYear()+"-"+
    pad2(d.getMonth()+1)+"-"+pad2(d.getDate());
}
function pad2(n){return n<10?"0"+n:String(n);}

/* ==========================================================
   SESSION VALIDITY (mirrors PS1 Is-ValidSession)
   Rule 1: StartDate missing             -&gt; skip
   Rule 2: EndDate   missing             -&gt; skip (still active)
   Rule 3: StartDate === EndDate (exact) -&gt; skip (zero-duration)
   Rule 4: StartDate date part == today  -&gt; skip (may still run)
========================================================== */
function isValidSession(r){
  var sd=r.StartDate||"";
  var ed=r.EndDate  ||"";
  if(!sd)return false;                          /* Rule 1 */
  if(!ed)return false;                          /* Rule 2 */
  if(sd===ed)return false;                      /* Rule 3 */
  if(sd.substring(0,10)===TODAY)return false;   /* Rule 4 */
  return true;
}

/* -- Safe JSON reader ------------------------------------- */
function safeGet(id){
  var el=document.getElementById(id);
  if(!el)return null;
  var txt=el.textContent.trim();
  if(txt.indexOf("CITRIX_")===0&&txt.indexOf("PLACEHOLDER")>0)return"PLACEHOLDER";
  try{return JSON.parse(txt);}catch(e){console.error("JSON#"+id,e);return null;}
}

/* -- Duration --------------------------------------------- */
function calcDur(a,b){
  if(!a||!b)return{secs:0,label:""};
  try{
    var d=Math.floor((new Date(b)-new Date(a))/1000);
    if(d<=0)return{secs:0,label:"0s"};
    var h=Math.floor(d/3600),m=Math.floor((d%3600)/60),s=d%60;
    return{secs:d,label:((h?h+"h ":"")+(m||h?m+"m ":"")+s+"s").trim()};
  }catch(e){return{secs:0,label:""};}
}

/* -- Init ------------------------------------------------- */
window.addEventListener("DOMContentLoaded",function(){
  vWrap=document.getElementById("vWrap");
  vBody=document.getElementById("vBody");

  var rawData=safeGet("citrix-data");
  META=safeGet("citrix-meta")||{};

  if(rawData==="PLACEHOLDER"||META==="PLACEHOLDER"){
    document.getElementById("setupBanner").classList.add("show");
    document.getElementById("rbarTxt").textContent="No data -- run the PS1 script first.";
    document.getElementById("hdrMeta").textContent=" -- Template not populated";
    document.getElementById("btnCSV").disabled=true;
    document.getElementById("btnExcel").disabled=true;
    return;
  }
  if(!Array.isArray(rawData)){
    document.getElementById("rbarTxt").textContent=
      "Data missing or corrupted -- re-run CitrixSessionReport_v9.ps1";
    document.getElementById("btnCSV").disabled=true;
    document.getElementById("btnExcel").disabled=true;
    return;
  }

  /* Validate, enrich */
  SKIPPED_TOTAL=0;
  RAW=[];
  rawData.forEach(function(r){
    if(!isValidSession(r)){SKIPPED_TOTAL++;return;}
    var dur=calcDur(r.StartDate,r.EndDate);
    r._durSecs=dur.secs;
    r._durLabel=dur.label;
    RAW.push(r);
  });

  /* Header */
  var m="";
  if(META.queryStart&&META.queryEnd)
    m=" -- "+META.queryStart.substring(0,10)+" -&gt; "+META.queryEnd.substring(0,10);
  if(META.generated)m+="  |  Generated: "+META.generated;
  document.getElementById("hdrMeta").textContent=m;

  /* Footer */
  document.getElementById("ftrLine1").innerHTML=
    "<strong>Citrix Session Report v9.0</strong>";
  document.getElementById("ftrLine2").textContent=
    RAW.length.toLocaleString()+" valid sessions"+
    (SKIPPED_TOTAL?" | "+SKIPPED_TOTAL.toLocaleString()+" skipped (invalid/incomplete)":"")+
    (META.sha256?" | SHA-256: "+META.sha256.substring(0,16)+"...":"");

  /* Skipped card */
  document.getElementById("sc-skip").textContent=SKIPPED_TOTAL.toLocaleString();
  if(SKIPPED_TOTAL>0){
    var skipEl=document.getElementById("rbarSkip");
    skipEl.style.display="inline";
    skipEl.textContent="(!) "+SKIPPED_TOTAL.toLocaleString()+" invalid/incomplete sessions excluded";
  }

  buildDropdowns();
  applyFilters();
  vWrap.addEventListener("scroll",function(){renderVisible();},{passive:true});
});

/* -- Dropdown population ---------------------------------- */
function buildDropdowns(){
  var map={
    fUN:"UserName",fCo:"ClientCountry",fCi:"ClientCity",
    fIS:"ClientISP",fPl:"ClientPlatform",fOS:"MachineOS",
    fCa:"CatalogName",fDG:"DesktopGroupName",fPr:"Protocol"
  };
  var sets={fUN:{},fCo:{},fCi:{},fIS:{},fPl:{},fOS:{},fCa:{},fDG:{},fPr:{}};
  RAW.forEach(function(r){
    Object.keys(map).forEach(function(id){
      var v=r[map[id]];if(v)sets[id][v]=1;
    });
  });
  Object.keys(sets).forEach(function(id){
    var sel=document.getElementById(id);
    Object.keys(sets[id]).sort().forEach(function(v){
      var o=document.createElement("option");o.value=v;o.textContent=v;sel.appendChild(o);
    });
  });
}

/* ==========================================================
   APPLY FILTERS
   Note: validity rules are already applied at load time (RAW
   only contains valid sessions). Filters here are user-driven.
========================================================== */
var ALL_FILTER_IDS=["fSrch","fUN","fCo","fCi","fIS","fPl","fOS",
                    "fCa","fDG","fPr","fDf","fDt","fDurMin","fDurMax"];

function applyFilters(){
  var srch =(document.getElementById("fSrch").value||"").toLowerCase().trim();
  var un   =document.getElementById("fUN").value;
  var co   =document.getElementById("fCo").value;
  var ci   =document.getElementById("fCi").value;
  var isp  =document.getElementById("fIS").value;
  var pl   =document.getElementById("fPl").value;
  var os   =document.getElementById("fOS").value;
  var ca   =document.getElementById("fCa").value;
  var dg   =document.getElementById("fDG").value;
  var pr   =document.getElementById("fPr").value;
  var df   =document.getElementById("fDf").value;
  var dt   =document.getElementById("fDt").value;
  var durMinRaw=document.getElementById("fDurMin").value;
  var durMaxRaw=document.getElementById("fDurMax").value;

  /* Parse duration bounds -- FIX: use parseFloat, guard NaN */
  var durMin=durMinRaw!=""?parseFloat(durMinRaw):null;
  var durMax=durMaxRaw!=""?parseFloat(durMaxRaw):null;
  if(durMin!==null&&isNaN(durMin))durMin=null;
  if(durMax!==null&&isNaN(durMax))durMax=null;

  /* Count active filters */
  var active=0;
  if(srch)active++;if(un)active++;if(co)active++;if(ci)active++;
  if(isp)active++;if(pl)active++;if(os)active++;if(ca)active++;
  if(dg)active++;if(pr)active++;if(df)active++;if(dt)active++;
  if(durMin!==null)active++;if(durMax!==null)active++;

  /* FIX: properly toggle .active on all inputs + selects */
  ALL_FILTER_IDS.forEach(function(id){
    var el=document.getElementById(id);
    if(!el)return;
    var hasVal=el.value!=="";
    el.classList.toggle("active",hasVal);
  });

  /* Filter chip */
  document.getElementById("filterChip").className=
    "filterChip"+(active?" on":"");
  document.getElementById("filterChipTxt").textContent=
    active+" filter"+(active!==1?"s":"")+" active";

  /* Export badges */
  document.getElementById("csvBadge").className="fbadge"+(active?" on":"");
  document.getElementById("excelBadge").className="fbadge"+(active?" on":"");

  /* Today-exclusion notice -- always on (rules always active) */
  document.getElementById("dateNote").className="date-note on";

  /* -- Filter RAW --------------------------------------- */
  filtered=RAW.filter(function(r){
    if(un &&r.UserName!==un)return false;
    if(co &&r.ClientCountry!==co)return false;
    if(ci &&r.ClientCity!==ci)return false;
    if(isp&&r.ClientISP!==isp)return false;
    if(pl &&r.ClientPlatform!==pl)return false;
    if(os &&r.MachineOS!==os)return false;
    if(ca &&r.CatalogName!==ca)return false;
    if(dg &&r.DesktopGroupName!==dg)return false;
    if(pr &&r.Protocol!==pr)return false;

    /* Date range (date-part only) */
    if(df||dt){
      var sd=(r.StartDate||"").substring(0,10);
      if(df&&sd<df)return false;
      if(dt&&sd>dt)return false;
    }

    /* Duration range -- FIX: compare against _durSecs (number) */
    if(durMin!==null&&r._durSecs<durMin)return false;
    if(durMax!==null&&r._durSecs>durMax)return false;

    /* Text search */
    if(srch){
      var hay=((r.UserName||"")+(r.FullName||"")+(r.MachineName||"")+
               (r.ClientIP||"")+(r.ClientPublicIP||"")+(r.ClientName||"")+
               (r.UserUPN||"")+(r.ClientCountry||"")+(r.ClientCity||"")+
               (r.ClientISP||"")).toLowerCase();
      if(hay.indexOf(srch)<0)return false;
    }
    return true;
  });

  if(sortCol)doSort(false);
  curPage=1;
  updateStats();
  updateRbar();
  goPage(1);
}

/* FIX: resetFilters clears ALL inputs/selects including new ones,
   and explicitly removes .active class from every filter element */
function resetFilters(){
  ALL_FILTER_IDS.forEach(function(id){
    var el=document.getElementById(id);
    if(!el)return;
    if(el.tagName==="SELECT")el.selectedIndex=0;
    else el.value="";
    el.classList.remove("active");   /* explicit class removal */
  });
  sortCol="";sortAsc=true;
  document.querySelectorAll("th[onclick]").forEach(function(th){
    th.classList.remove("sort-asc","sort-desc");
  });
  applyFilters();
}

function debounce(){clearTimeout(debT);debT=setTimeout(applyFilters,280);}

/* -- Stats ------------------------------------------------ */
function updateStats(){
  var src=filtered;
  document.getElementById("sc-total").textContent=src.length.toLocaleString();
  var users={},machs={},ctries={},plats={},cats={},durSum=0,durCnt=0;
  src.forEach(function(r){
    if(r.UserName)users[r.UserName]=1;
    if(r.MachineName)machs[r.MachineName]=1;
    if(r.ClientCountry)ctries[r.ClientCountry]=1;
    if(r.ClientPlatform)plats[r.ClientPlatform]=1;
    if(r.CatalogName)cats[r.CatalogName]=1;
    if(r._durSecs>0){durSum+=r._durSecs;durCnt++;}
  });
  document.getElementById("sc-users").textContent=Object.keys(users).length.toLocaleString();
  document.getElementById("sc-mach").textContent=Object.keys(machs).length.toLocaleString();
  document.getElementById("sc-ctry").textContent=Object.keys(ctries).length.toLocaleString();
  document.getElementById("sc-plat").textContent=Object.keys(plats).length.toLocaleString();
  document.getElementById("sc-cat").textContent=Object.keys(cats).length.toLocaleString();
  document.getElementById("sc-skip").textContent=SKIPPED_TOTAL.toLocaleString();
  if(durCnt>0){
    var avg=Math.round(durSum/durCnt);
    var h=Math.floor(avg/3600),m=Math.floor((avg%3600)/60),s=avg%60;
    document.getElementById("sc-avgd").textContent=
      (h?h+"h ":"")+(m||h?m+"m ":"")+s+"s";
  }else document.getElementById("sc-avgd").textContent="--";
}

function updateRbar(){
  var tot=filtered.length,raw=RAW.length;
  var txt=tot.toLocaleString()+" session"+(tot!==1?"s":"");
  if(tot<raw)txt+=" (filtered from "+raw.toLocaleString()+" valid)";
  document.getElementById("rbarTxt").textContent=txt;
}

/* -- Sort ------------------------------------------------- */
function sortBy(col){
  sortCol===col?sortAsc=!sortAsc:(sortCol=col,sortAsc=true);
  document.querySelectorAll("th[onclick]").forEach(function(th){
    th.classList.remove("sort-asc","sort-desc");
    if((th.getAttribute("onclick")||"").indexOf("'"+col+"'")>=0)
      th.classList.add(sortAsc?"sort-asc":"sort-desc");
  });
  doSort(true);goPage(1);
}
function doSort(r){
  var c=sortCol,a=sortAsc;
  filtered.sort(function(x,y){
    var av=x[c]||"",bv=y[c]||"";
    if(typeof av==="number"&&typeof bv==="number")return a?av-bv:bv-av;
    return a?String(av).localeCompare(String(bv)):String(bv).localeCompare(String(av));
  });
  if(r)goPage(1);
}

/* -- Paging ----------------------------------------------- */
function totalPages(){return Math.max(1,Math.ceil(filtered.length/pageSize));}
function goPage(n){
  n=Math.max(1,Math.min(n,totalPages()));curPage=n;
  updatePager();rebuildVirtualScroll();
}
function changePageSize(){
  pageSize=parseInt(document.getElementById("pgSz").value,10);
  curPage=1;updatePager();rebuildVirtualScroll();
}
function updatePager(){
  var tot=totalPages(),cnt=filtered.length;
  var s=(curPage-1)*pageSize+1,e=Math.min(curPage*pageSize,cnt);
  document.getElementById("pgNm").textContent="Page "+curPage+" / "+tot;
  document.getElementById("pgIn").textContent=
    cnt?s.toLocaleString()+"-"+e.toLocaleString()+" of "+cnt.toLocaleString():"No results";
  document.getElementById("pgFi").disabled=curPage<=1;
  document.getElementById("pgPv").disabled=curPage<=1;
  document.getElementById("pgNx").disabled=curPage>=tot;
  document.getElementById("pgLa").disabled=curPage>=tot;
}

/* -- Virtual scroll --------------------------------------- */
function rebuildVirtualScroll(){
  var s=(curPage-1)*pageSize,e=Math.min(s+pageSize,filtered.length);
  pageRows=filtered.slice(s,e);
  vBody.style.height=(pageRows.length*ROW_H)+"px";
  vBody.style.position="relative";
  vWrap.scrollTop=0;renderVisible();
}
function renderVisible(){
  if(!pageRows.length){
    vBody.innerHTML=
      '<div class="no-rows">'+
      '<svg width="36" height="36" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">'+
      '<circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg>'+
      'No sessions match the current filters</div>';
    return;
  }
  var st=vWrap.scrollTop,vh=vWrap.clientHeight;
  var si=Math.max(0,Math.floor(st/ROW_H)-5);
  var ei=Math.min(pageRows.length-1,Math.ceil((st+vh)/ROW_H)+5);

  vBody.querySelectorAll(".vrow[data-i]").forEach(function(el){
    var i=parseInt(el.getAttribute("data-i"),10);
    if(i<si||i>ei)el.remove();
  });
  var rendered={};
  vBody.querySelectorAll(".vrow[data-i]").forEach(function(el){
    rendered[el.getAttribute("data-i")]=true;
  });

  var frag=document.createDocumentFragment();
  /* FIX: row number = absolute position in filtered set (1-based) */
  var pageStart=(curPage-1)*pageSize;

  for(var i=si;i<=ei;i++){
    if(rendered[i])continue;
    var r=pageRows[i];
    var absRowNum=pageStart+i+1;   /* FIX: +1 to make 1-based */
    var row=document.createElement("div");
    row.className="vrow "+(i%2===0?"even":"odd");
    row.setAttribute("data-i",i);
    row.style.cssText=
      "position:absolute;top:"+(i*ROW_H)+"px;left:0;right:0;height:"+ROW_H+"px;display:flex";

    /* Row number cell */
    var nc=document.createElement("div");
    nc.className="vcell num";nc.style.width=NUM_W+"px";
    nc.textContent=absRowNum;      /* FIX: was ps+i (missing +1) */
    row.appendChild(nc);

    COLS.forEach(function(col){
      var c=document.createElement("div");
      c.style.width=col.w+"px";
      var v=r[col.key]||"";
      if(col.cls==="bdg-plat"){
        c.className="vcell";c.innerHTML=platBadge(v);
      }else if(col.cls==="bdg-proto"){
        c.className="vcell";c.innerHTML=protoBadge(v);
      }else{
        c.className="vcell "+(col.cls||"");
        c.textContent=v;if(v)c.title=v;
      }
      row.appendChild(c);
    });
    frag.appendChild(row);
  }
  vBody.appendChild(frag);
}

function platBadge(v){
  if(!v)return"";
  var l=v.toLowerCase();
  var cls=l.indexOf("win")>=0?"b-win":l.indexOf("mac")>=0?"b-mac":
          l.indexOf("lin")>=0?"b-lnx":l.indexOf("ios")>=0?"b-ios":
          l.indexOf("and")>=0?"b-adr":"b-oth";
  return'<span class="bdg '+cls+'">'+esc(v)+'</span>';
}
function protoBadge(v){
  if(!v)return"";
  var l=v.toLowerCase();
  var cls=l.indexOf("hdx")>=0?"b-hdx":l.indexOf("rdp")>=0?"b-rdp":"b-prt";
  return'<span class="bdg '+cls+'">'+esc(v)+'</span>';
}
function esc(s){
  return String(s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
}

/* == EXPORTS ================================================ */
var EH=["#","Start Date","End Date","Duration","User Name","Full Name","UPN",
  "Machine","OS","Catalog","Desktop Group","Platform","Protocol",
  "Client Name","Client Ver","Client IP","Public IP",
  "Country","City","ISP",
  "Connected Via Host","Connected Via IP","Launched Via Host","Launched Via IP"];
var EK=["StartDate","EndDate","_durLabel","UserName","FullName","UserUPN",
  "MachineName","MachineOS","CatalogName","DesktopGroupName","ClientPlatform","Protocol",
  "ClientName","ClientVersion","ClientIP","ClientPublicIP",
  "ClientCountry","ClientCity","ClientISP",
  "ConnectedViaHostName","ConnectedViaIPAddress","LaunchedViaHostName","LaunchedViaIPAddress"];

/* FIX: row number is prepended separately -- no _rn key mismatch */
function buildExportRows(src){
  var rows=[EH.slice()];
  src.forEach(function(r,i){
    var row=[i+1];                   /* row number -- always correct */
    EK.forEach(function(k){row.push(r[k]||"");});
    rows.push(row);
  });
  return rows;
}

function doCSV(){
  var isF=filtered.length!==RAW.length;
  var src=isF?filtered:RAW;
  var rows=buildExportRows(src);
  var csv=rows.map(function(r){
    return r.map(function(v){
      var s=String(v);
      return(s.indexOf(",")>=0||s.indexOf('"')>=0||s.indexOf("\n")>=0)?
        '"'+s.replace(/"/g,'""')+'"':s;
    }).join(",");
  }).join("\r\n");
  triggerDL(new Blob(["\uFEFF"+csv],{type:"text/csv;charset=utf-8"}),
    "CitrixSessions"+(isF?"_FILTERED":"")+"_"+stamp()+".csv");
  toast("CSV downloaded -- "+(rows.length-1).toLocaleString()+" rows"+(isF?" (filtered)":""));
}

function doExcel(){
  var btn=document.getElementById("btnExcel");
  btn.disabled=true;showProg("Building Excel...");
  var isF=filtered.length!==RAW.length;
  var src=isF?filtered:RAW;
  var tot=src.length,proc=0;
  var exRows=[EH.slice()];
  function pump(){
    try{
      var chunk=Math.min(5000,tot-proc);
      for(var i=0;i<chunk;i++){
        var r=src[proc];
        var row=[proc+1];
        EK.forEach(function(k){row.push(r[k]||"");});
        exRows.push(row);proc++;
      }
      setProg(Math.round(proc/Math.max(tot,1)*70),
        "Building "+proc.toLocaleString()+" / "+tot.toLocaleString()+"...");
      if(proc<tot){setTimeout(pump,0);return;}
      setProg(80,"Building XLSX...");
      setTimeout(function(){
        try{
          var xlsx=buildXLSX(exRows,isF);
          setProg(98,"Writing file...");
          setTimeout(function(){
            triggerDL(new Blob([xlsx],
              {type:"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"}),
              "CitrixSessions"+(isF?"_FILTERED":"")+"_"+stamp()+".xlsx");
            setProg(100,"Done -- "+tot.toLocaleString()+" rows");
            setTimeout(function(){hideProg();btn.disabled=false;},2500);
            toast("Excel ready -- "+tot.toLocaleString()+" rows"+(isF?" (filtered)":""));
          },30);
        }catch(e){xFail(btn,e);}
      },30);
    }catch(e){xFail(btn,e);}
  }
  setTimeout(pump,0);
}
function xFail(btn,e){
  console.error(e);hideProg();btn.disabled=false;
  toast("Excel failed -- downloading CSV instead.");doCSV();
}

/* -- Inline XLSX builder ---------------------------------- */
function buildXLSX(rows,isF){
  var cc=rows[0].length,cw="";
  for(var ci=0;ci<cc;ci++)
    cw+='<col min="'+(ci+1)+'" max="'+(ci+1)+'" width="22" customWidth="1"/>';
  var ss=[],ssM={};
  function si(v){var s=v==null?"":String(v);
    if(ssM[s]===undefined){ssM[s]=ss.length;ss.push(s);}return ssM[s];}
  var sr="";
  for(var ri=0;ri<rows.length;ri++){
    var row=rows[ri],cells="";
    for(var ci2=0;ci2<row.length;ci2++){
      var ref=cN(ci2)+(ri+1),st=(ri===0)?1:0;
      cells+='<c r="'+ref+'" t="s" s="'+st+'"><v>'+si(row[ci2])+"</v></c>";
    }
    sr+='<row r="'+(ri+1)+'">'+cells+"</row>";
  }
  var wsN=isF?"Sessions (Filtered)":"Sessions";
  var sh='<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'+
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'+
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'+
    '<sheetViews><sheetView workbookViewId="0">'+
    '<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>'+
    '</sheetView></sheetViews><sheetFormatPr defaultRowHeight="15"/>'+
    '<cols>'+cw+'</cols><sheetData>'+sr+'</sheetData>'+
    '<autoFilter ref="A1:'+cN(cc-1)+'1"/></worksheet>';
  var ssX='<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'+
    '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'+
    ' count="'+ss.length+'" uniqueCount="'+ss.length+'">'+
    ss.map(function(s){return"<si><t>"+xe(s)+"</t></si>";}).join("")+"</sst>";
  var stX='<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'+
    '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'+
    '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font>'+
    '<font><sz val="11"/><b/><color rgb="FFFFFFFF"/><name val="Calibri"/></font></fonts>'+
    '<fills count="3"><fill><patternFill patternType="none"/></fill>'+
    '<fill><patternFill patternType="gray125"/></fill>'+
    '<fill><patternFill patternType="solid"><fgColor rgb="FFD80074"/></patternFill></fill></fills>'+
    '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'+
    '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'+
    '<cellXfs count="2">'+
    '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'+
    '<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>'+
    '</cellXfs></styleSheet>';
  var wbX='<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'+
    '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'+
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'+
    '<sheets><sheet name="'+xe(wsN)+'" sheetId="1" r:id="rId1"/></sheets></workbook>';
  var wbR='<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'+
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'+
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'+
    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>'+
    '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>';
  var rR='<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'+
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'+
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>';
  var ct='<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'+
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'+
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'+
    '<Default Extension="xml" ContentType="application/xml"/>'+
    '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'+
    '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'+
    '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>'+
    '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>';
  return zipFiles([
    {n:"[Content_Types].xml",d:ct},{n:"_rels/.rels",d:rR},
    {n:"xl/workbook.xml",d:wbX},{n:"xl/_rels/workbook.xml.rels",d:wbR},
    {n:"xl/worksheets/sheet1.xml",d:sh},{n:"xl/sharedStrings.xml",d:ssX},
    {n:"xl/styles.xml",d:stX}
  ]);
}

/* -- ZIP helpers ------------------------------------------ */
function s2b(s){var b=new Uint8Array(s.length);for(var i=0;i<s.length;i++)b[i]=s.charCodeAt(i)&0xFF;return b;}
function xe(s){return String(s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;");}
function cN(n){var s="";n++;while(n>0){s=String.fromCharCode(65+((n-1)%26))+s;n=Math.floor((n-1)/26);}return s;}
var CT=(function(){var t=new Int32Array(256);for(var i=0;i<256;i++){var c=i;for(var j=0;j<8;j++)c=(c&1)?(0xEDB88320^(c>>>1)):(c>>>1);t[i]=c;}return t;})();
function crc32(b){var c=0xFFFFFFFF;for(var i=0;i<b.length;i++)c=CT[(c^b[i])&0xFF]^(c>>>8);return(c^0xFFFFFFFF)>>>0;}
function u32(n){return[n&0xFF,(n>>8)&0xFF,(n>>16)&0xFF,(n>>24)&0xFF];}
function u16(n){return[n&0xFF,(n>>8)&0xFF];}
function zipFiles(files){
  var cds=[],off=0,parts=[];
  files.forEach(function(f){
    var nb=s2b(f.n),db=s2b(f.d),crc=crc32(db),sz=db.length;
    var loc=[0x50,0x4B,0x03,0x04,0x14,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00]
      .concat(u32(crc)).concat(u32(sz)).concat(u32(sz)).concat(u16(nb.length)).concat([0x00,0x00]);
    var lb=new Uint8Array(loc.length+nb.length+db.length);
    lb.set(loc,0);lb.set(nb,loc.length);lb.set(db,loc.length+nb.length);
    var cd=[0x50,0x4B,0x01,0x02,0x14,0x00,0x14,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00]
      .concat(u32(crc)).concat(u32(sz)).concat(u32(sz)).concat(u16(nb.length))
      .concat([0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00]).concat(u32(off));
    var cb=new Uint8Array(cd.length+nb.length);cb.set(cd,0);cb.set(nb,cd.length);
    parts.push(lb);cds.push(cb);off+=lb.length;
  });
  var cdSz=cds.reduce(function(a,b){return a+b.length;},0);
  var eocd=[0x50,0x4B,0x05,0x06,0x00,0x00,0x00,0x00]
    .concat(u16(files.length)).concat(u16(files.length))
    .concat(u32(cdSz)).concat(u32(off)).concat([0x00,0x00]);
  var all=parts.concat(cds).concat([new Uint8Array(eocd)]);
  var tot=all.reduce(function(a,b){return a+b.length;},0);
  var out=new Uint8Array(tot),pos=0;
  all.forEach(function(b){out.set(b,pos);pos+=b.length;});
  return out;
}
function triggerDL(blob,name){
  var url=URL.createObjectURL(blob);
  var a=document.createElement("a");a.href=url;a.download=name;a.style.display="none";
  document.body.appendChild(a);a.click();
  setTimeout(function(){document.body.removeChild(a);URL.revokeObjectURL(url);},1000);
}
function stamp(){return new Date().toISOString().substring(0,10);}
function showProg(m){document.getElementById("progArea").style.display="flex";setProg(0,m);}
function setProg(p,m){document.getElementById("progFill").style.width=p+"%";
  document.getElementById("progTxt").textContent=m;}
function hideProg(){document.getElementById("progArea").style.display="none";setProg(0,"");}
function toast(m){var e=document.getElementById("toast");e.textContent=m;
  e.classList.add("on");setTimeout(function(){e.classList.remove("on");},3500);}
</script>
</body>
</html>

'@
}

# PREFLIGHT CHECKS
# ==============================================================================
function Invoke-Preflight {
    $errors   = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    # Credentials
    if ([string]::IsNullOrWhiteSpace($CustomerId))   { $errors.Add("CustomerId is empty - set it in SECTION 1.") }
    if ([string]::IsNullOrWhiteSpace($ClientId))     { $errors.Add("ClientId is empty - set it in SECTION 1.") }
    if ([string]::IsNullOrWhiteSpace($ClientSecret)) { $errors.Add("ClientSecret is empty - set it in SECTION 1.") }

    # HTML template -- auto-deploy from embedded content if missing
    if (-not (Test-Path $TemplatePath)) {
        Write-Log "HTML template missing -- writing from embedded content: $TemplatePath" "WARN"
        try {
            $embeddedHtml = Get-EmbeddedTemplate
            [System.IO.File]::WriteAllText(
                $TemplatePath,
                $embeddedHtml,
                [System.Text.Encoding]::UTF8)
            Write-Log "HTML template written successfully: $TemplatePath" "OK"
        } catch {
            $errors.Add("Failed to write HTML template: $($_.Exception.Message)")
        }
    } else {
        Write-Log "HTML template : $TemplatePath" "OK"
    }

    # Date range
    try {
        $ds   = [datetime]::Parse($QueryStart)
        $de   = [datetime]::Parse($QueryEnd)
        if ($ds -ge $de) { $errors.Add("QueryStart must be earlier than QueryEnd.") }
        $days = ($de - $ds).TotalDays
        if ($days -gt 366) {
            $warnings.Add("Date range spans $([Math]::Round($days)) days - may produce very large output.")
        }
    } catch {
        $errors.Add("QueryStart or QueryEnd is not a valid date: $($_.Exception.Message)")
    }

    # Output folder - create and verify writable
    try {
        if (-not (Test-Path $OutputFolder)) {
            New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
            Write-Log "Output folder created: $OutputFolder" "OK"
        }
        $probe = Join-Path $OutputFolder (".probe_" + (Get-Random))
        [System.IO.File]::WriteAllText($probe, "x")
        Remove-Item $probe -Force -ErrorAction SilentlyContinue
        Write-Log "Output folder writable: $OutputFolder" "OK"
    } catch {
        $errors.Add("Cannot write to output folder '$OutputFolder': $($_.Exception.Message)")
    }

    foreach ($w in $warnings) { Write-Log "WARN: $w" "WARN" }

    if ($errors.Count -gt 0) {
        Write-Host "+============================================================+" -ForegroundColor Red
        Write-Host "|        PREFLIGHT FAILED - ACTION REQUIRED                  |" -ForegroundColor Red
        Write-Host "+============================================================+" -ForegroundColor Red
        foreach ($e in $errors) { Write-Log "[!] $e" "ERROR" }
        exit 1
    }
    Write-Log "All preflight checks passed." "OK"
}

# ==============================================================================
# BUILD ONE HTML OUTPUT FILE FROM A DATA BUFFER
# Moved to script scope (not nested) so all variables are accessible cleanly.
# ==============================================================================
function Write-HtmlChunk {
    param(
        [System.Collections.Generic.List[object]]$Buffer,
        [string]  $Template,
        [string]  $FileStamp,
        [int]     $ChunkIndex,
        [int]     $TotalRows,
        [int]     $SkippedRows,
        [string]  $Generated
    )

    $suffix = if ($ChunkIndex -eq 1) { "" } else { "_part$ChunkIndex" }
    $path   = Join-Path $OutputFolder ("VCLite_BillingReport_" + $FileStamp + $suffix + ".html")

    # Serialise buffer to JSON
    if ($Buffer.Count -eq 0) {
        $rawJson = "[]"
    } elseif ($Buffer.Count -eq 1) {
        $rawJson = "[" + ($Buffer[0] | ConvertTo-Json -Compress -Depth 3) + "]"
    } else {
        $parts   = $Buffer | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 3 }
        $rawJson = "[" + ($parts -join ",") + "]"
    }
    $safeJson = Sanitize-Json $rawJson

    # Build meta object
    $meta = [ordered]@{
        generated     = $Generated
        queryStart    = $QueryStart
        queryEnd      = $QueryEnd
        totalRows     = [string]$TotalRows
        skippedRows   = [string]$SkippedRows
        chunkNumber   = $ChunkIndex
        rowsInChunk   = $Buffer.Count
        sha256        = Get-SHA256Hash $safeJson
        scriptVersion = $ScriptVersion
    }
    $safeMeta = Sanitize-Json ($meta | ConvertTo-Json -Compress)

    # Inject into template and save
    $html = $Template.Replace("CITRIX_DATA_PLACEHOLDER_JSON_ARRAY",  $safeJson)
    $html = $html.Replace(    "CITRIX_META_PLACEHOLDER_JSON_OBJECT", $safeMeta)
    $html | Out-File -FilePath $path -Encoding UTF8 -NoNewline

    $rowCount = $Buffer.Count.ToString("N0")
    Write-Log "  Chunk $ChunkIndex - $rowCount rows -> $path" "OK"
    return $path
}

# ==============================================================================
# HTML REPORT EXPORT
# Pages through the OData API, validates sessions, flattens rows, and
# writes output HTML files in chunks to support 2M+ records.
# ==============================================================================
function Export-HtmlReport {
    param(
        [string]   $BaseUri,
        [hashtable]$ApiHeaders,
        [string]   $FileStamp
    )

    # Load template - restore placeholder tokens if template was previously populated
    $template = Get-Content -Path $TemplatePath -Raw -Encoding UTF8
    if ($template -notlike "*CITRIX_DATA_PLACEHOLDER_JSON_ARRAY*") {
        $template = $template -replace (
            '(?s)<script type="application/json" id="citrix-data">.*?</script>'),
            '<script type="application/json" id="citrix-data">CITRIX_DATA_PLACEHOLDER_JSON_ARRAY</script>'
        $template = $template -replace (
            '(?s)<script type="application/json" id="citrix-meta">.*?</script>'),
            '<script type="application/json" id="citrix-meta">CITRIX_META_PLACEHOLDER_JSON_OBJECT</script>'
    }

    $generated = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $chunkMax  = if ($HtmlChunkSize -gt 0) { $HtmlChunkSize } else { [int]::MaxValue }

    $buffer    = [System.Collections.Generic.List[object]]::new()
    $outFiles  = [System.Collections.Generic.List[string]]::new()
    $chunkNum  = 0
    $totalRows = 0
    $skipped   = 0

    $uri  = $BaseUri
    $page = 0

    do {
        $page++
        $attempt = 0
        $success = $false

        while (-not $success -and $attempt -lt $MaxRetries) {
            $attempt++
            try {
                $response = Invoke-WebRequest -Uri $uri -Headers $ApiHeaders `
                                -UseBasicParsing -ErrorAction Stop
                $parsed   = $response.Content | ConvertFrom-Json
                $records  = if ($null -ne $parsed.value) { @($parsed.value) } else { @() }

                foreach ($sess in $records) {
                    if (-not (Test-ValidSession $sess)) {
                        $skipped++
                        continue
                    }
                    $buffer.Add((ConvertTo-FlatRow $sess))
                    $totalRows++

                    # Flush chunk when buffer reaches chunk size
                    if ($buffer.Count -ge $chunkMax) {
                        $chunkNum++
                        $outFiles.Add((Write-HtmlChunk `
                            -Buffer     $buffer `
                            -Template   $template `
                            -FileStamp  $FileStamp `
                            -ChunkIndex $chunkNum `
                            -TotalRows  $totalRows `
                            -SkippedRows $skipped `
                            -Generated  $generated))
                        $buffer.Clear()
                        [System.GC]::Collect()
                    }
                }

                # Follow OData next-page link
                $uri     = $parsed.'@odata.nextLink'
                $success = $true

            } catch {
                Write-Log "Page $page attempt $attempt failed: $($_.Exception.Message)" "WARN"
                if ($attempt -lt $MaxRetries) {
                    Start-Sleep -Milliseconds $RetryDelayMs
                } else {
                    throw "Data fetch failed on page $page after $MaxRetries attempts: $($_.Exception.Message)"
                }
            }
        }

    } while (-not [string]::IsNullOrWhiteSpace($uri))

    # Write final (or only) chunk
    $chunkNum++
    $outFiles.Add((Write-HtmlChunk `
        -Buffer      $buffer `
        -Template    $template `
        -FileStamp   $FileStamp `
        -ChunkIndex  $chunkNum `
        -TotalRows   $totalRows `
        -SkippedRows $skipped `
        -Generated   $generated))

    $totalStr = $totalRows.ToString("N0")
    Write-Log "Export complete: $totalStr rows, $skipped skipped, $($outFiles.Count) file(s)." "OK"

    # Emit Base64-encoded output HTML for HPSA job-step capture.
    # Camunda reads everything between the START/END markers, strips newlines,
    # decodes Base64, and saves the result as the output HTML file.
    # SHA-256 lets Camunda verify the decoded file is intact.
    if ($outFiles.Count -gt 0) {
        $lastFile   = $outFiles[$outFiles.Count - 1]
        $lastHtml   = Get-Content -Path $lastFile -Raw -Encoding UTF8
        $lastSha256 = Get-SHA256Hash $lastHtml
        $lastB64    = ConvertTo-Base64Utf8 -InputString $lastHtml

        # Write-Host targets stdout which HPSA job-step output captures
        Write-Host "HPSA_REPORT_B64_START"
        Write-Host $lastB64
        Write-Host "HPSA_REPORT_B64_END"
        Write-Host "HPSA_REPORT_SHA256:$lastSha256"
        Write-Host "HPSA_REPORT_PATH:$lastFile"
        Write-Log "HPSA Base64 emitted. SHA-256: $lastSha256" "OK"
    }

    return $outFiles
}

# ==============================================================================
# MAIN
# ==============================================================================
try {
    Write-Log "======================================================" "STEP"
    Write-Log "  VCLite Citrix Billing Report" "STEP"
    Write-Log "======================================================" "STEP"
    Write-Log "CustomerId   : $CustomerId"
    Write-Log "Template     : $TemplatePath"
    Write-Log "Output dir   : $OutputFolder"
    Write-Log "Date range   : $QueryStart  ->  $QueryEnd"
    Write-Log ""

    # Step 0 - Preflight
    Write-Log "[0/3] Preflight checks..." "STEP"
    Invoke-Preflight

    # Step 1 - Authenticate
    Write-Log "[1/3] Authenticating with Citrix Cloud..." "STEP"
    $token = Get-BearerToken -CustomerId $CustomerId `
                             -ClientId   $ClientId `
                             -ClientSecret $ClientSecret
    $apiHeaders = @{
        "Authorization"     = "CwsAuth bearer=$token"
        "Citrix-CustomerId" = $CustomerId
        "Accept"            = "application/json"
    }

    # Step 2 - Build OData query URI
    Write-Log "[2/3] Building OData query..." "STEP"
    $encStart = [uri]::EscapeDataString($QueryStart)
    $encEnd   = [uri]::EscapeDataString($QueryEnd)
    $filter   = "StartDate%20ge%20$encStart%20and%20StartDate%20le%20$encEnd"
    $baseUri  = $MonitorUrl + "/Sessions" +
                "?`$filter="  + $filter +
                "&`$select="  + $ODataSelect +
                "&`$expand="  + $ODataExpand +
                "&`$top="     + $ApiPageSize
    Write-Log "OData URI built successfully." "OK"

    # Step 3 - Generate HTML report
    Write-Log "[3/3] Generating HTML report(s)..." "STEP"
    $fileStamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $htmlFiles = Export-HtmlReport `
                    -BaseUri    $baseUri `
                    -ApiHeaders $apiHeaders `
                    -FileStamp  $fileStamp

    # Summary
    Write-Host ""
    Write-Host "+============================================================+" -ForegroundColor Green
    Write-Host "|         REPORT COMPLETE - VCLite Billing Report            |" -ForegroundColor Green
    Write-Host "+============================================================+" -ForegroundColor Green
    Write-Host ("|  Date range : " + $QueryStart.Substring(0,10) + "  ->  " + $QueryEnd.Substring(0,10)) -ForegroundColor Green
    Write-Host ("|  Files      : " + $htmlFiles.Count)                          -ForegroundColor Green
    Write-Host ("|  Output dir : " + $OutputFolder)                              -ForegroundColor Green
    Write-Host "+============================================================+" -ForegroundColor Green
    foreach ($f in $htmlFiles) { Write-Host "    $f" -ForegroundColor White }
    Write-Host ""

    # Auto-open first report in default browser
    if ($htmlFiles.Count -gt 0) {
        try { Start-Process $htmlFiles[0] } catch { <# non-fatal #> }
    }

} catch {
    Write-Host ""
    Write-Host "+============================================================+" -ForegroundColor Red
    Write-Host "|                  SCRIPT FAILED  [!]                       |" -ForegroundColor Red
    Write-Host "+============================================================+" -ForegroundColor Red
    Write-Log "FATAL: $($_.Exception.Message)" "ERROR"
    Write-Log "At: $($_.InvocationInfo.PositionMessage)" "ERROR"
    exit 1
}
