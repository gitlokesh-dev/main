# ==============================================================================
#  VCLite Citrix Billing Report  - LOCAL TEST BUILD
#  Credentials : Hardcoded in SECTION 1 below (for local testing only)
#  INI file    : NOT required
#  Date range  : Set $QueryStart and $QueryEnd below, or leave empty for
#                previous calendar month (default)
#  Output      : <ScriptDir>\output\VCLite_BillingReport_<stamp>.html
#  Compatible  : Works with HPSA -Command and -File execution modes
# ==============================================================================

# Date range - leave empty for automatic previous calendar month default
# Set values here if you want a specific range e.g. "2026-05-01T00:00:00Z"
if (-not (Get-Variable -Name QueryStart -ErrorAction SilentlyContinue)) {
    $QueryStart = ""
}
if (-not (Get-Variable -Name QueryEnd -ErrorAction SilentlyContinue)) {
    $QueryEnd = ""
}

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
# HPSA copies the PS1 to C:\Windows\TEMP at runtime, so
# $MyInvocation.MyCommand.Path points to TEMP - not the deploy folder.
# Always use $DeployDir so the HTML template and output go to the
# correct, consistent location regardless of how the script is executed.
# ==============================================================================
$ScriptDir    = $DeployDir + "\"
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
<title>VCLite Citrix Billing Report</title>
<style>
/* VCLite Citrix Billing Report */
:root{
  --brand    :rgb(216,0,116);
  --brand-dk :rgb(175,0,93);
  --brand-lt :rgba(216,0,116,.10);
  --brand-xlt:rgba(216,0,116,.05);
  --brand-bd :rgba(216,0,116,.28);
  --white    :#fff;
  --bg       :#f2f4f8;
  --bg2      :#f9fafb;
  --border   :#e0e4ea;
  --border-lt:#edf0f4;
  --text     :#1a1d23;
  --text-s   :#4b5563;
  --text-m   :#9ca3af;
  --green    :#059669;
  --amber    :#d97706;
  --blue     :#2563eb;
  --red      :#dc2626;
  --r-even   :#fdf4f9;
  --r-odd    :#fff;
  --r-hover  :rgba(216,0,116,.06);
  --sh-hdr   :0 2px 12px rgba(216,0,116,.22),0 1px 4px rgba(0,0,0,.12);
  --sh-card  :0 1px 4px rgba(0,0,0,.07);
  --sh-tbl   :0 2px 12px rgba(0,0,0,.10);
  --rad      :8px;
  --rsm      :5px;
}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
html,body{height:100%;overflow:hidden}
body{font-family:Arial,Helvetica,sans-serif;font-size:13px;
     background:var(--bg);color:var(--text);
     display:flex;flex-direction:column}

/* ------ HEADER --------------------------------------------------------------------------------------------------------------------------------------------- */
.page-hdr{
  background:var(--brand);color:#fff;
  box-shadow:var(--sh-hdr);
  flex-shrink:0;position:relative;overflow:hidden;
}
.page-hdr::before{
  content:'';position:absolute;inset:0;
  background:repeating-linear-gradient(-45deg,
    rgba(255,255,255,0) 0,rgba(255,255,255,0) 18px,
    rgba(255,255,255,.03) 18px,rgba(255,255,255,.03) 20px);
}
.page-hdr::after{
  content:'';position:absolute;bottom:0;left:0;right:0;height:2px;
  background:linear-gradient(90deg,rgba(255,255,255,.5),
    transparent 50%,rgba(255,255,255,.5));
}
.hdr-top{
  position:relative;z-index:1;
  display:flex;align-items:center;justify-content:space-between;
  padding:13px 24px 11px;gap:16px;flex-wrap:wrap;
}
.hdr-brand{display:flex;align-items:center;gap:10px}
.hdr-icon{
  width:32px;height:32px;background:rgba(255,255,255,.16);
  border-radius:7px;border:1px solid rgba(255,255,255,.28);
  display:flex;align-items:center;justify-content:center;flex-shrink:0;
}
.hdr-title{font-size:16px;font-weight:800;letter-spacing:-.2px;line-height:1.2}
.hdr-actions{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.hdr-strip{
  position:relative;z-index:1;
  display:flex;align-items:center;justify-content:space-between;
  background:rgba(0,0,0,.20);padding:7px 26px;
  font-size:10.5px;color:rgba(255,255,255,.85);
  gap:12px;flex-wrap:wrap;
}
.hdr-strip-left{display:flex;align-items:center;gap:18px;flex-wrap:wrap}
.hdr-strip-left span{display:flex;align-items:center;gap:5px}
.hdr-strip-left strong{color:#fff}
.status-pill{
  padding:3px 14px;border-radius:20px;font-weight:800;
  font-size:10px;letter-spacing:.4px;white-space:nowrap;
}
.p-ok  {background:rgba(10,122,9,.88); color:#fff}
.p-warn{background:rgba(176,94,0,.88); color:#fff}
.p-info{background:rgba(37,99,235,.88);color:#fff}

/* ------ BUTTONS --------------------------------------------------------------------------------------------------------------------------------------------- */
.btn{
  display:inline-flex;align-items:center;gap:5px;
  padding:0 13px;height:30px;border:none;border-radius:var(--rsm);
  font-size:11px;font-weight:700;cursor:pointer;white-space:nowrap;
  font-family:inherit;transition:filter .12s,transform .09s;
  position:relative;
}
.btn:hover  {filter:brightness(1.10);transform:translateY(-1px)}
.btn:active {transform:none;filter:brightness(.92)}
.btn:disabled{opacity:.35;cursor:not-allowed;transform:none;filter:none}
.btn-csv  {background:#fff;color:var(--brand);
           border:1.5px solid rgba(255,255,255,.55);
           box-shadow:0 1px 4px rgba(0,0,0,.15)}
.btn-apply{background:var(--brand);color:#fff;
           box-shadow:0 1px 6px rgba(216,0,116,.35)}
.btn-apply:hover{background:var(--brand-dk)}
.btn-ghost{background:rgba(255,255,255,.13);color:#fff;
           border:1.5px solid rgba(255,255,255,.32)}
.btn-reset{background:var(--white);color:var(--text-s);
           border:1px solid var(--border)}
.btn-reset:hover{border-color:var(--brand);color:var(--brand)}
.fbadge{
  display:none;position:absolute;top:-6px;right:-6px;
  background:var(--amber);color:#fff;border-radius:7px;
  font-size:8px;font-weight:800;padding:1px 4px;
  line-height:13px;border:1.5px solid #fff;
}
.fbadge.on{display:block}

/* ------ STAT CARDS ------------------------------------------------------------------------------------------------------------------------------------ */
.stats-strip{
  background:var(--white);border-bottom:1px solid var(--border);
  padding:8px 22px;display:flex;gap:8px;flex-wrap:wrap;flex-shrink:0;
}
.sc{
  flex:1;min-width:90px;background:var(--bg2);
  border:1px solid var(--border);border-top:3px solid var(--brand);
  border-radius:var(--rad);padding:8px 12px;
  box-shadow:var(--sh-card);text-align:center;
  transition:box-shadow .15s,transform .15s;
}
.sc:hover{box-shadow:0 3px 12px rgba(216,0,116,.16);transform:translateY(-1px)}
.sc .val{
  font-size:19px;font-weight:800;color:var(--brand);
  line-height:1.1;font-family:'Courier New',monospace;
}
.sc .lbl{
  font-size:8px;color:var(--text-m);text-transform:uppercase;
  letter-spacing:.7px;margin-top:3px;font-weight:700;
}
.sc.skip{border-top-color:var(--amber)}
.sc.skip .val{color:var(--amber)}

/* ------ FILTER BAR ------------------------------------------------------------------------------------------------------------------------------------ */
.fbar{
  background:var(--white);border-bottom:2px solid var(--border);
  padding:8px 22px;display:flex;flex-direction:column;gap:7px;
  position:sticky;top:0;z-index:500;flex-shrink:0;
}
.frow{display:flex;flex-wrap:wrap;gap:7px;align-items:flex-end}
.f-sec-lbl{
  font-size:8.5px;font-weight:800;color:var(--brand);
  text-transform:uppercase;letter-spacing:.5px;
  border-left:2.5px solid var(--brand);padding-left:6px;
  align-self:center;white-space:nowrap;margin-right:2px;
}
.fg{display:flex;flex-direction:column;gap:3px}
.fg label{
  font-size:8.5px;font-weight:700;color:var(--text-m);
  text-transform:uppercase;letter-spacing:.5px;
}
.fg input,.fg select{
  height:28px;padding:0 8px;
  border:1px solid var(--border);border-radius:var(--rsm);
  font-size:11.5px;font-family:inherit;
  background:var(--white);color:var(--text);outline:none;
  transition:border-color .12s,box-shadow .12s;
}
.fg input:focus,.fg select:focus{
  border-color:var(--brand);box-shadow:0 0 0 2px var(--brand-lt);
}
.fg input.act,.fg select.act{
  border-color:var(--brand);background:var(--brand-xlt);
  font-weight:700;color:var(--brand);
}
.fw{min-width:175px}.fm{min-width:120px}.fd{min-width:136px}.fn{min-width:88px}
.vsep{width:1px;background:var(--border);height:28px;align-self:flex-end;margin:0 2px}
.f-chip{
  display:none;align-items:center;gap:4px;align-self:flex-end;
  background:var(--brand-lt);border:1px solid var(--brand-bd);
  border-radius:12px;padding:2px 10px;font-size:10px;
  font-weight:700;color:var(--brand);white-space:nowrap;height:28px;
}
.f-chip.on{display:flex}
.f-note{
  display:flex;align-items:center;gap:4px;align-self:flex-end;
  background:#fff8e1;border:1px solid #fbbf24;border-radius:12px;
  padding:2px 10px;font-size:9.5px;font-weight:600;
  color:#92400e;white-space:nowrap;height:28px;
}
.f-act{display:flex;gap:6px;align-self:flex-end}

/* ------ RESULT BAR ------------------------------------------------------------------------------------------------------------------------------------ */
.rbar{
  display:flex;align-items:center;justify-content:space-between;
  flex-wrap:wrap;gap:7px;padding:4px 22px;
  font-size:11.5px;color:var(--text-s);
  background:var(--bg2);border-bottom:1px solid var(--border);flex-shrink:0;
}
.rbar-l{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.prog{display:none;align-items:center;gap:7px;font-size:11px;color:var(--brand);font-weight:700}
.prog-track{width:140px;height:4px;background:var(--brand-lt);border-radius:3px;overflow:hidden}
.prog-fill {height:100%;width:0%;background:var(--brand);border-radius:3px;transition:width .2s}

/* ------ VIRTUAL SCROLL TABLE ------------------------------------------------------------------------------------------------------ */
.t-outer{flex:1;overflow:hidden;padding:8px 22px 6px;display:flex;flex-direction:column;min-height:0}
.vwrap{
  flex:1;min-height:0;overflow-x:auto;overflow-y:auto;
  border:1px solid var(--border);border-radius:var(--rad);
  box-shadow:var(--sh-tbl);background:var(--white);
}
.vshead{position:sticky;top:0;z-index:10}
.vshead table{border-collapse:collapse;table-layout:fixed}
th{
  background:var(--brand);color:#fff;
  padding:8px 10px;text-align:left;white-space:nowrap;
  font-weight:700;font-size:10.5px;letter-spacing:.2px;
  border-right:1px solid rgba(255,255,255,.13);
  border-bottom:2px solid rgba(0,0,0,.13);
  cursor:pointer;user-select:none;
}
th:last-child{border-right:none}
th:hover{background:var(--brand-dk)}
th.sa::after{content:" ---";font-size:8px;opacity:.85}
th.sd::after{content:" ---";font-size:8px;opacity:.85}
th.ns{cursor:default}
.vsbody{position:relative;background:var(--white)}
.vrow{display:flex;transition:background .06s}
.vrow:hover .vc{background:var(--r-hover)!important}
.vc{
  flex-shrink:0;padding:4px 10px;
  border-bottom:1px solid var(--border-lt);
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis;
  font-size:11.5px;display:flex;align-items:center;
}
.vrow.ev .vc{background:var(--r-even)}
.vrow.od .vc{background:var(--r-odd)}
.vc.num  {color:var(--text-m);font-size:10px;font-family:'Courier New',monospace;justify-content:flex-end}
.vc.dur  {font-family:'Courier New',monospace;font-size:11px;color:var(--green);font-weight:700}
.vc.mono {font-family:'Courier New',monospace;font-size:11px;color:var(--blue)}
.vc.bold {font-weight:700}
.vc.mu   {color:var(--text-m);font-size:11px}
.no-rows {text-align:center;padding:60px 20px;color:var(--text-m);font-size:13px}
.bdg{display:inline-block;padding:1px 7px;border-radius:9px;font-size:10px;font-weight:700}
.bw{background:#dbeafe;color:#1d4ed8}.bm{background:#fce7f3;color:#9d174d}
.bl{background:#d1fae5;color:#065f46}.bi{background:#ede9fe;color:#5b21b6}
.ba{background:#fef3c7;color:#92400e}.bo{background:#f3f4f6;color:#374151}
.bh{background:#d1fae5;color:#065f46}.br{background:#dbeafe;color:#1d4ed8}
.bp{background:#f3f4f6;color:#374151}

/* ------ PAGER --------------------------------------------------------------------------------------------------------------------------------------------------- */
.pgr{
  display:flex;align-items:center;flex-wrap:wrap;gap:5px;
  padding:6px 22px;background:var(--white);
  border-top:1px solid var(--border);font-size:11.5px;flex-shrink:0;
}
.pgr-info{color:var(--text-s)}
.pgr select,.pgr button{
  font-family:inherit;font-size:11px;
  border:1px solid var(--border);border-radius:var(--rsm);
  background:var(--white);color:var(--text);
  cursor:pointer;transition:all .1s;
}
.pgr select{padding:3px 6px}
.pgr button{padding:2px 10px}
.pgr button:hover:not(.pga):not(:disabled){
  background:var(--brand-lt);border-color:var(--brand-bd);color:var(--brand);
}
.pgr button.pga{background:var(--brand);color:#fff;border-color:var(--brand)}
.pgr button:disabled{opacity:.28;cursor:not-allowed}

/* ------ FOOTER ------------------------------------------------------------------------------------------------------------------------------------------------ */
.page-ftr{
  background:var(--white);border-top:1px solid var(--border);
  padding:6px 24px;display:flex;align-items:center;
  justify-content:space-between;flex-wrap:wrap;gap:8px;
  font-size:10px;color:var(--text-m);flex-shrink:0;
}
.ftr-brand{display:flex;align-items:center;gap:7px;font-weight:700;color:var(--text-s)}
.ftr-brand span{color:var(--brand)}
.ftr-meta{font-size:9.5px;text-align:right;line-height:1.6}

/* ------ TOAST --------------------------------------------------------------------------------------------------------------------------------------------------- */
.toast{
  position:fixed;bottom:18px;right:18px;background:#1f2937;color:#fff;
  padding:9px 16px;border-radius:8px;font-size:12px;font-weight:600;
  box-shadow:0 4px 16px rgba(0,0,0,.30);z-index:9999;
  border-left:3px solid var(--brand);
  opacity:0;transform:translateY(8px);
  transition:opacity .23s,transform .23s;pointer-events:none;
}
.toast.on{opacity:1;transform:translateY(0)}
::-webkit-scrollbar{width:5px;height:5px}
::-webkit-scrollbar-track{background:#f0f0f0}
::-webkit-scrollbar-thumb{background:rgba(216,0,116,.33);border-radius:3px}
::-webkit-scrollbar-thumb:hover{background:var(--brand)}
</style>
</head>
<body>

<!-- DATA blocks - PS1 replaces placeholder tokens at runtime -->
<script type="application/json" id="citrix-data">CITRIX_DATA_PLACEHOLDER_JSON_ARRAY</script>
<script type="application/json" id="citrix-meta">CITRIX_META_PLACEHOLDER_JSON_OBJECT</script>

<!-- ---------------------------------------------------------------------  HEADER  ------------------------------------------------------------------------------------------ -->
<header class="page-hdr">
  <div class="hdr-top">
    <div class="hdr-brand">
      <div class="hdr-icon">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.2">
          <rect x="2" y="3" width="20" height="14" rx="2"/>
          <path d="M8 21h8M12 17v4"/>
        </svg>
      </div>
      <div>
        <div class="hdr-title">VCLite Citrix Billing Report</div>
      </div>
    </div>
    <div class="hdr-actions">
      <button class="btn btn-csv" id="btnCSV" onclick="doCSV()" disabled title="Download filtered data as CSV">
        <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
          <path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4"/>
          <polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/>
        </svg>
        Download CSV
        <span class="fbadge" id="csvBadge">F</span>
      </button>
    </div>
  </div>
  <div class="hdr-strip">
    <div class="hdr-strip-left">
      <span>&#128197; Range: <strong id="hMeta-range">-</strong></span>
      <span>&#128336; Generated: <strong id="hMeta-gen">-</strong></span>
      <span>&#9989; Showing: <strong id="hMeta-rows">-</strong></span>
      <span>&#9888; Skipped: <strong id="hMeta-skip">-</strong></span>
    </div>
    <span class="status-pill p-info" id="statusPill">Initialising</span>
  </div>
</header>

<!-- ---------------------------------------------------------------------  STAT CARDS  ------------------------------------------------------------------------------ -->
<div class="stats-strip">
  <div class="sc"><div class="val" id="sc-tot">--</div><div class="lbl">Total Sessions</div></div>
  <div class="sc"><div class="val" id="sc-usr">--</div><div class="lbl">Unique Users</div></div>
  <div class="sc"><div class="val" id="sc-mac">--</div><div class="lbl">Machines</div></div>
  <div class="sc"><div class="val" id="sc-ctr">--</div><div class="lbl">Countries</div></div>
  <div class="sc"><div class="val" id="sc-plt">--</div><div class="lbl">Platforms</div></div>
  <div class="sc"><div class="val" id="sc-cat">--</div><div class="lbl">Catalogs</div></div>
  <div class="sc"><div class="val" id="sc-avg">--</div><div class="lbl">Avg Duration</div></div>
  <div class="sc skip"><div class="val" id="sc-skp">0</div><div class="lbl">Skipped</div></div>
</div>

<!-- ---------------------------------------------------------------------  FILTER BAR  ------------------------------------------------------------------------------ -->
<div class="fbar">
  <!-- Row 1: Date range filter -->
  <div class="frow">
    <span class="f-sec-lbl">&#128197; Date Range Filter</span>
    <div class="fg fd">
      <label>From Date</label>
      <input type="date" id="fDf" onchange="debounce()">
    </div>
    <div class="fg fd">
      <label>To Date</label>
      <input type="date" id="fDt" onchange="debounce()">
    </div>
    <button class="btn btn-apply" onclick="applyFilters()" style="align-self:flex-end">Apply</button>
    <button class="btn btn-reset" onclick="resetFilters()" style="align-self:flex-end">Reset All</button>
    <div class="f-chip" id="fChip">
      <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
        <polygon points="22 3 2 3 10 12.46 10 19 14 21 14 12.46 22 3"/>
      </svg>
      <span id="fChipTxt">0 filters</span>
    </div>
    <div class="f-note">
      <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
        <circle cx="12" cy="12" r="10"/>
        <line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/>
      </svg>
      Today &amp; zero-duration sessions excluded automatically
    </div>
  </div>
  <!-- Row 2: Search and field filters -->
  <div class="frow">
    <span class="f-sec-lbl">Search &amp; Filter</span>
    <div class="fg fw">
      <label>Search</label>
      <input type="text" id="fSrch" placeholder="User / Machine / IP / ISP..." oninput="debounce()">
    </div>
    <div class="fg fm"><label>User</label>
      <select id="fUN" onchange="applyFilters()"><option value="">All Users</option></select></div>
    <div class="fg fm"><label>Country</label>
      <select id="fCo" onchange="applyFilters()"><option value="">All Countries</option></select></div>
    <div class="fg fm"><label>City</label>
      <select id="fCi" onchange="applyFilters()"><option value="">All Cities</option></select></div>
    <div class="fg fm"><label>ISP</label>
      <select id="fIS" onchange="applyFilters()"><option value="">All ISPs</option></select></div>
    <div class="fg fm"><label>Platform</label>
      <select id="fPl" onchange="applyFilters()"><option value="">All Platforms</option></select></div>
    <div class="fg fm"><label>OS</label>
      <select id="fOS" onchange="applyFilters()"><option value="">All OS</option></select></div>
    <div class="fg fm"><label>Catalog</label>
      <select id="fCa" onchange="applyFilters()"><option value="">All Catalogs</option></select></div>
    <div class="fg fm"><label>Desktop Group</label>
      <select id="fDG" onchange="applyFilters()"><option value="">All Groups</option></select></div>
    <div class="fg fm"><label>Protocol</label>
      <select id="fPr" onchange="applyFilters()"><option value="">All Protocols</option></select></div>
    <div class="vsep"></div>
    <div class="fg fn"><label>Min Dur (s)</label>
      <input type="number" id="fDurMin" min="0" placeholder="secs" oninput="debounce()"></div>
    <div class="fg fn"><label>Max Dur (s)</label>
      <input type="number" id="fDurMax" min="0" placeholder="secs" oninput="debounce()"></div>
  </div>
</div>

<!-- ---------------------------------------------------------------------  RESULT BAR  ------------------------------------------------------------------------------ -->
<div class="rbar">
  <div class="rbar-l">
    <span id="rbarTxt">Loading...</span>
    <span id="rbarSkip" style="color:var(--amber);display:none"></span>
  </div>
  <div class="prog" id="progArea">
    <span id="progTxt"></span>
    <div class="prog-track"><div class="prog-fill" id="progFill"></div></div>
  </div>
</div>

<!-- ---------------------------------------------------------------------  TABLE  --------------------------------------------------------------------------------------------- -->
<div class="t-outer">
  <div class="vwrap" id="vWrap">
    <div class="vshead" id="vsHead">
      <table id="hdrTable"><colgroup id="hdrCols"></colgroup><thead><tr>
        <th class="ns" style="width:48px">#</th>
        <th onclick="sortBy('StartDate')">Start Date</th>
        <th onclick="sortBy('EndDate')">End Date</th>
        <th onclick="sortBy('_dur')">Duration</th>
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

<!-- ---------------------------------------------------------------------  PAGER  --------------------------------------------------------------------------------------------- -->
<div class="pgr">
  <span class="pgr-info">Rows/page:</span>
  <select id="pgSz" onchange="changePageSize()">
    <option value="500">500</option>
    <option value="1000" selected>1000</option>
    <option value="2000">2000</option>
    <option value="5000">5000</option>
  </select>
  <button id="pgFi" onclick="goPage(1)">&laquo;</button>
  <button id="pgPv" onclick="goPage(cur-1)">&lsaquo; Prev</button>
  <span id="pgNm"></span>
  <button id="pgNx" onclick="goPage(cur+1)">Next &rsaquo;</button>
  <button id="pgLa" onclick="goPage(totPages())">&raquo;</button>
  <span id="pgIn" class="pgr-info" style="margin-left:5px"></span>
</div>

<!-- ---------------------------------------------------------------------  FOOTER  ------------------------------------------------------------------------------------------ -->
<footer class="page-ftr">
  <div class="ftr-brand">
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="rgb(216,0,116)" stroke-width="2.2">
      <rect x="2" y="3" width="20" height="14" rx="2"/><path d="M8 21h8M12 17v4"/>
    </svg>
    <span>VCLite Citrix Billing Report</span>
  </div>
  <div class="ftr-meta" id="ftrMeta"></div>
</footer>

<div class="toast" id="toast"></div>

<script>
/* ================================================================
   VCLite Billing Report Engine
   - No hardcoded dates - user selects date range via pickers
   - Zero-duration / equal StartDate=EndDate sessions excluded
     (both string equality AND parsed-ms comparison)
   - Virtual scroll handles 2M+ rows with constant memory
   - Streaming CSV export (no memory spike for large datasets)
   - CSV only (Excel removed)
================================================================ */

/* -- Column definitions ----------------------------------- */
var COLS=[
  {k:"StartDate",             w:148,cls:""},
  {k:"EndDate",               w:148,cls:""},
  {k:"_durLabel",             w:90, cls:"dur"},
  {k:"UserName",              w:130,cls:"bold"},
  {k:"FullName",              w:148,cls:""},
  {k:"UserUPN",               w:188,cls:"mu"},
  {k:"MachineName",           w:152,cls:""},
  {k:"MachineOS",             w:130,cls:""},
  {k:"CatalogName",           w:132,cls:""},
  {k:"DesktopGroupName",      w:150,cls:""},
  {k:"ClientPlatform",        w:100,cls:"_plat"},
  {k:"Protocol",              w:80, cls:"_proto"},
  {k:"ClientName",            w:148,cls:""},
  {k:"ClientVersion",         w:125,cls:"mu"},
  {k:"ClientIP",              w:130,cls:"mono"},
  {k:"ClientPublicIP",        w:130,cls:"mono"},
  {k:"ClientCountry",         w:110,cls:""},
  {k:"ClientCity",            w:110,cls:""},
  {k:"ClientISP",             w:168,cls:""},
  {k:"ConnectedViaHostName",  w:185,cls:""},
  {k:"ConnectedViaIPAddress", w:142,cls:"mono"},
  {k:"LaunchedViaHostName",   w:185,cls:""},
  {k:"LaunchedViaIPAddress",  w:142,cls:"mono"}
];
var NW=48, RH=30;

/* -- State ------------------------------------------------ */
var ALL_ROWS=[]; // all valid rows loaded from JSON
var filtered=[];
var META={};
var SKIP_TOTAL=0;
var cur=1, psz=1000;
var debT=null, sCol="", sAsc=true;
var vWrap, vBody, pageRows=[];
var TODAY=todayUTC();

/* TODAY is UTC date string yyyy-mm-dd matching session StartDate format */
function todayUTC(){
  var d=new Date();
  var y=d.getUTCFullYear();
  var m=d.getUTCMonth()+1;
  var day=d.getUTCDate();
  return y+"-"+(m<10?"0"+m:m)+"-"+(day<10?"0"+day:day);
}
function p2(n){return n<10?"0"+n:String(n);}

/* ================================================================
   SESSION VALIDITY
   Only excludes permanently invalid sessions (no start, no end,
   zero-duration). TODAY check removed so all historical data shows.
   Date RANGE filtering is done in applyFilters() so the user can
   change the displayed range freely.
================================================================ */
function isValidSession(r){
  var sd=r.StartDate||"", ed=r.EndDate||"";
  if(!sd||!ed) return false;                    // no start or end
  try{
    var ts=Date.parse(sd), te=Date.parse(ed);
    if(!isNaN(ts)&&!isNaN(te)){ if(ts>=te) return false; } // zero/negative duration
    else if(sd===ed) return false;
  }catch(e){ if(sd===ed) return false; }
  return true;  // TODAY sessions are included - date filter handles them
}

/* -- Duration --------------------------------------------- */
function calcDur(a,b){
  if(!a||!b) return{s:0,l:""};
  try{
    var d=Math.floor((new Date(b)-new Date(a))/1000);
    if(d<=0) return{s:0,l:"0s"};
    var h=Math.floor(d/3600),m=Math.floor((d%3600)/60),s=d%60;
    return{s:d,l:((h?h+"h ":"")+(m||h?m+"m ":"")+s+"s").trim()};
  }catch(e){return{s:0,l:""};}
}

/* -- Safe JSON reader ------------------------------------- */
function safeGet(id){
  var el=document.getElementById(id);
  if(!el) return null;
  var t=el.textContent.trim();
  if(t.indexOf("CITRIX_")===0&&t.indexOf("PLACEHOLDER")>0) return "PH";
  try{return JSON.parse(t);}catch(e){return null;}
}

/* -- Helpers ---------------------------------------------- */
function g(id){return document.getElementById(id);}
function set(id,val){var e=g(id);if(e)e.textContent=val;}
function fmt(d){return d?d.substring(0,10):"";}

/* ================================================================
   INIT
================================================================ */
window.addEventListener("DOMContentLoaded",function(){
  vWrap=g("vWrap");
  vBody=g("vBody");

  var raw=safeGet("citrix-data");
  META=safeGet("citrix-meta")||{};

  if(raw==="PH"||META==="PH"){
    set("rbarTxt","No data - run VCLite_BillingReport.ps1 first.");
    set("statusPill","Template not populated");
    return;
  }
  if(!Array.isArray(raw)){
    set("rbarTxt","Data error - re-run the PS1.");
    return;
  }

  /* Validate and enrich all rows */
  SKIP_TOTAL=0; ALL_ROWS=[];
  raw.forEach(function(r){
    if(!isValidSession(r)){SKIP_TOTAL++;return;}
    var d=calcDur(r.StartDate,r.EndDate);
    r._dur=d.s; r._durLabel=d.l;
    ALL_ROWS.push(r);
  });

  /* Populate header strip from META */
  var metaFrom=fmt(META.queryStart);
  var metaTo  =fmt(META.queryEnd);
  set("hMeta-range", (metaFrom||"?")+" -> "+(metaTo||"?"));
  set("hMeta-gen",   META.generated||"-");
  set("hMeta-rows",  ALL_ROWS.length.toLocaleString());
  set("hMeta-skip",  SKIP_TOTAL.toLocaleString());

  /* Status pill */
  var pill=g("statusPill");
  pill.textContent=ALL_ROWS.length.toLocaleString()+" valid sessions";
  pill.className="status-pill "+(ALL_ROWS.length>0?"p-ok":"p-warn");

  /* Footer */
  set("ftrMeta", "Generated: " + (META.generated || "-"));

  /* Stat card - skipped */
  set("sc-skp",SKIP_TOTAL.toLocaleString());
  if(SKIP_TOTAL>0){
    var sk=g("rbarSkip");
    if(sk){sk.style.display="inline";
      sk.textContent=SKIP_TOTAL.toLocaleString()+" sessions skipped (zero-duration/incomplete)";}
  }

  /* Pre-fill date pickers from META query range */
  if(metaFrom) g("fDf").value=metaFrom;
  if(metaTo)   g("fDt").value=metaTo;

  buildDropdowns();
  buildHeaderCols();
  g("btnCSV").disabled=false;

  /* Apply filters AFTER pickers are set - shows full META range by default */
  applyFilters();

  vWrap.addEventListener("scroll",renderVisible,{passive:true});
});

/* ================================================================
   HEADER COLUMN SYNC
   Sets <colgroup> widths to exactly match the virtual scroll body
   so header and data rows are always pixel-perfectly aligned.
================================================================ */
function buildHeaderCols(){
  var cg=g("hdrCols");
  if(!cg) return;
  cg.innerHTML="";
  /* row-number column */
  var c0=document.createElement("col");
  c0.style.width=NW+"px";
  cg.appendChild(c0);
  /* data columns */
  COLS.forEach(function(col){
    var cc=document.createElement("col");
    cc.style.width=col.w+"px";
    cg.appendChild(cc);
  });
  var totalW=NW+COLS.reduce(function(s,col){return s+col.w;},0);
  var tbl=g("hdrTable");
  if(tbl){tbl.style.width=totalW+"px";tbl.style.minWidth=totalW+"px";}
  /* also set vsbody min-width */
  if(vBody){vBody.style.minWidth=totalW+"px";}
}

/* ================================================================
   DROPDOWNS  - built from ALL valid data so options are always full
================================================================ */
function buildDropdowns(){
  var dm={fUN:"UserName",fCo:"ClientCountry",fCi:"ClientCity",
          fIS:"ClientISP",fPl:"ClientPlatform",fOS:"MachineOS",
          fCa:"CatalogName",fDG:"DesktopGroupName",fPr:"Protocol"};
  var sets={};
  Object.keys(dm).forEach(function(k){sets[k]={};});
  ALL_ROWS.forEach(function(r){
    Object.keys(dm).forEach(function(k){var v=r[dm[k]];if(v)sets[k][v]=1;});
  });
  Object.keys(sets).forEach(function(k){
    var sel=g(k); if(!sel) return;
    Object.keys(sets[k]).sort().forEach(function(v){
      var o=document.createElement("option");o.value=v;o.textContent=v;sel.appendChild(o);
    });
  });
}

/* ================================================================
   FILTERS
   Date pickers filter the displayed rows client-side.
   Changing the pickers immediately re-filters and updates the header.
   Date pickers are NOT counted as "active filters" unless the user
   has changed them away from the META query range.
================================================================ */
var FID_FIELDS=["fSrch","fUN","fCo","fCi","fIS","fPl","fOS","fCa","fDG","fPr","fDurMin","fDurMax"];

function applyFilters(){
  var df  =g("fDf").value||"";
  var dt  =g("fDt").value||"";
  var srch=(g("fSrch").value||"").toLowerCase().trim();
  var un  =g("fUN").value;
  var co  =g("fCo").value;
  var ci  =g("fCi").value;
  var isp =g("fIS").value;
  var pl  =g("fPl").value;
  var os  =g("fOS").value;
  var ca  =g("fCa").value;
  var dg  =g("fDG").value;
  var pr  =g("fPr").value;
  var dmin=g("fDurMin").value!==""?parseFloat(g("fDurMin").value):null;
  var dmax=g("fDurMax").value!==""?parseFloat(g("fDurMax").value):null;
  if(dmin!==null&&isNaN(dmin))dmin=null;
  if(dmax!==null&&isNaN(dmax))dmax=null;

  /* Update header Range: live from pickers */
  set("hMeta-range",(df||"?")+" -> "+(dt||"?"));

  /* Count active filters (pickers only count if changed from META range) */
  var active=0;
  FID_FIELDS.forEach(function(id){
    var el=g(id); if(!el) return;
    var on=(el.tagName==="SELECT"?el.value!=="":(el.value!==""));
    el.classList.toggle("act",on);
    if(on) active++;
  });
  var mf=fmt(META.queryStart), mt=fmt(META.queryEnd);
  var dfOn=df&&df!==mf;
  var dtOn=dt&&dt!==mt;
  g("fDf").classList.toggle("act",!!dfOn);
  g("fDt").classList.toggle("act",!!dtOn);
  if(dfOn) active++;
  if(dtOn) active++;

  var chip=g("fChip");
  chip.className="f-chip"+(active?" on":"");
  g("fChipTxt").textContent=active+" filter"+(active!==1?"s":"")+" active";
  g("csvBadge").className="fbadge"+(active?" on":"");

  /* Filter ALL_ROWS */
  filtered=ALL_ROWS.filter(function(r){
    /* Date range - compare yyyy-mm-dd strings (ISO sorts correctly) */
    var sd=(r.StartDate||"").substring(0,10);
    if(df&&sd<df) return false;
    if(dt&&sd>dt) return false;
    /* Field filters */
    if(un  &&r.UserName!==un)         return false;
    if(co  &&r.ClientCountry!==co)    return false;
    if(ci  &&r.ClientCity!==ci)       return false;
    if(isp &&r.ClientISP!==isp)       return false;
    if(pl  &&r.ClientPlatform!==pl)   return false;
    if(os  &&r.MachineOS!==os)        return false;
    if(ca  &&r.CatalogName!==ca)      return false;
    if(dg  &&r.DesktopGroupName!==dg) return false;
    if(pr  &&r.Protocol!==pr)         return false;
    /* Duration range */
    if(dmin!==null&&r._dur<dmin) return false;
    if(dmax!==null&&r._dur>dmax) return false;
    /* Free-text search */
    if(srch){
      var h=((r.UserName||"")+(r.FullName||"")+(r.MachineName||"")+
             (r.ClientIP||"")+(r.ClientPublicIP||"")+(r.ClientName||"")+
             (r.UserUPN||"")+(r.ClientCountry||"")+(r.ClientCity||"")+
             (r.ClientISP||"")).toLowerCase();
      if(h.indexOf(srch)<0) return false;
    }
    return true;
  });

  if(sCol) doSort(false);
  cur=1;
  /* Header strip "Valid" count must reflect the CURRENT filtered view,
     not the one-time total captured at page load. Without this it stays
     frozen at the full dataset count forever, even after changing the
     date range and clicking Apply. */
  set("hMeta-rows", filtered.length.toLocaleString());
  updateStats();
  updateRbar();
  goPage(1);
}

function resetFilters(){
  FID_FIELDS.forEach(function(id){
    var el=g(id); if(!el) return;
    if(el.tagName==="SELECT") el.selectedIndex=0; else el.value="";
    el.classList.remove("act");
  });
  /* Restore pickers to META range */
  g("fDf").value=fmt(META.queryStart)||"";
  g("fDt").value=fmt(META.queryEnd)||"";
  g("fDf").classList.remove("act");
  g("fDt").classList.remove("act");
  sCol=""; sAsc=true;
  document.querySelectorAll("th[onclick]").forEach(function(t){t.classList.remove("sa","sd");});
  applyFilters();
}

function debounce(){clearTimeout(debT);debT=setTimeout(applyFilters,300);}

/* ================================================================
   STATS CARDS
================================================================ */
function updateStats(){
  set("sc-tot",filtered.length.toLocaleString());
  var U={},M={},C={},P={},K={},ds=0,dc=0;
  filtered.forEach(function(r){
    if(r.UserName)       U[r.UserName]=1;
    if(r.MachineName)    M[r.MachineName]=1;
    if(r.ClientCountry)  C[r.ClientCountry]=1;
    if(r.ClientPlatform) P[r.ClientPlatform]=1;
    if(r.CatalogName)    K[r.CatalogName]=1;
    if(r._dur>0){ds+=r._dur;dc++;}
  });
  set("sc-usr",Object.keys(U).length.toLocaleString());
  set("sc-mac",Object.keys(M).length.toLocaleString());
  set("sc-ctr",Object.keys(C).length.toLocaleString());
  set("sc-plt",Object.keys(P).length.toLocaleString());
  set("sc-cat",Object.keys(K).length.toLocaleString());
  set("sc-skp",SKIP_TOTAL.toLocaleString());
  if(dc>0){
    var avg=Math.round(ds/dc),h=Math.floor(avg/3600),m=Math.floor((avg%3600)/60),s=avg%60;
    set("sc-avg",(h?h+"h ":"")+(m||h?m+"m ":"")+s+"s");
  } else set("sc-avg","--");
}

function updateRbar(){
  var tot=filtered.length,all=ALL_ROWS.length;
  var txt=tot.toLocaleString()+" session"+(tot!==1?"s":"");
  if(tot<all) txt+=" (filtered from "+all.toLocaleString()+" valid)";
  set("rbarTxt",txt);
}

/* ================================================================
   SORT
================================================================ */
function sortBy(col){
  sCol===col?sAsc=!sAsc:(sCol=col,sAsc=true);
  document.querySelectorAll("th[onclick]").forEach(function(t){
    t.classList.remove("sa","sd");
    if((t.getAttribute("onclick")||"").indexOf("'"+col+"'")>=0)
      t.classList.add(sAsc?"sa":"sd");
  });
  doSort(true); goPage(1);
}
function doSort(rebuild){
  var col=sCol,asc=sAsc;
  filtered.sort(function(x,y){
    var a=x[col]||"",b=y[col]||"";
    if(typeof a==="number"&&typeof b==="number") return asc?a-b:b-a;
    return asc?String(a).localeCompare(String(b)):String(b).localeCompare(String(a));
  });
  if(rebuild) goPage(1);
}

/* ================================================================
   PAGING
================================================================ */
function totPages(){return Math.max(1,Math.ceil(filtered.length/psz));}
function goPage(n){
  n=Math.max(1,Math.min(n,totPages())); cur=n;
  updatePager(); rebuildVS();
}
function changePageSize(){
  psz=parseInt(g("pgSz").value,10); cur=1;
  updatePager(); rebuildVS();
}
function updatePager(){
  var tot=totPages(),cnt=filtered.length;
  var s=(cur-1)*psz+1,e=Math.min(cur*psz,cnt);
  set("pgNm","Page "+cur+" / "+tot);
  set("pgIn",cnt?s.toLocaleString()+"-"+e.toLocaleString()+" of "+cnt.toLocaleString():"No results");
  g("pgFi").disabled=cur<=1; g("pgPv").disabled=cur<=1;
  g("pgNx").disabled=cur>=tot; g("pgLa").disabled=cur>=tot;
}

/* ================================================================
   VIRTUAL SCROLL
================================================================ */
function rebuildVS(){
  var s=(cur-1)*psz,e=Math.min(s+psz,filtered.length);
  pageRows=filtered.slice(s,e);
  vBody.style.height=(pageRows.length*RH)+"px";
  vBody.style.position="relative";
  vWrap.scrollTop=0;
  renderVisible();
}
function renderVisible(){
  if(!pageRows.length){
    vBody.innerHTML='<div class="no-rows">No sessions match the current filters</div>';
    return;
  }
  var st=vWrap.scrollTop,vh=vWrap.clientHeight;
  var si=Math.max(0,Math.floor(st/RH)-5);
  var ei=Math.min(pageRows.length-1,Math.ceil((st+vh)/RH)+5);

  vBody.querySelectorAll(".vrow[data-i]").forEach(function(el){
    var i=parseInt(el.getAttribute("data-i"),10);
    if(i<si||i>ei) el.remove();
  });
  var rend={};
  vBody.querySelectorAll(".vrow[data-i]").forEach(function(el){rend[el.getAttribute("data-i")]=true;});

  var frag=document.createDocumentFragment();
  var base=(cur-1)*psz;
  for(var i=si;i<=ei;i++){
    if(rend[i]) continue;
    var r=pageRows[i];
    var row=document.createElement("div");
    row.className="vrow "+(i%2===0?"ev":"od");
    row.setAttribute("data-i",i);
    row.style.cssText="position:absolute;top:"+(i*RH)+"px;left:0;right:0;height:"+RH+"px;display:flex;";

    var nc=document.createElement("div");
    nc.className="vc num"; nc.style.width=NW+"px";
    nc.textContent=base+i+1; row.appendChild(nc);

    COLS.forEach(function(col){
      var cell=document.createElement("div");
      cell.style.width=col.w+"px";
      var v=r[col.k]||"";
      if(col.cls==="_plat"){cell.className="vc";cell.innerHTML=platBadge(v);}
      else if(col.cls==="_proto"){cell.className="vc";cell.innerHTML=protoBadge(v);}
      else{cell.className="vc "+(col.cls||"");cell.textContent=v;if(v)cell.title=v;}
      row.appendChild(cell);
    });
    frag.appendChild(row);
  }
  vBody.appendChild(frag);
}

function platBadge(v){
  if(!v) return"";
  var l=v.toLowerCase();
  var c=l.indexOf("win")>=0?"bw":l.indexOf("mac")>=0?"bm":
        l.indexOf("lin")>=0?"bl":l.indexOf("ios")>=0?"bi":
        l.indexOf("and")>=0?"ba":"bo";
  return'<span class="bdg '+c+'">'+esc(v)+'</span>';
}
function protoBadge(v){
  if(!v) return"";
  var l=v.toLowerCase();
  var c=l.indexOf("hdx")>=0?"bh":l.indexOf("rdp")>=0?"br":"bp";
  return'<span class="bdg '+c+'">'+esc(v)+'</span>';
}
function esc(s){
  return String(s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
}

/* ================================================================
   CSV EXPORT  - streaming, 10k rows per chunk, respects filters
================================================================ */
var CSV_HEADERS=["#","Start Date","End Date","Duration","User Name","Full Name","UPN",
  "Machine","OS","Catalog","Desktop Group","Platform","Protocol",
  "Client Name","Client Ver","Client IP","Public IP",
  "Country","City","ISP","Connected Via Host","Connected Via IP",
  "Launched Via Host","Launched Via IP"];
var CSV_KEYS=["StartDate","EndDate","_durLabel","UserName","FullName","UserUPN",
  "MachineName","MachineOS","CatalogName","DesktopGroupName","ClientPlatform","Protocol",
  "ClientName","ClientVersion","ClientIP","ClientPublicIP",
  "ClientCountry","ClientCity","ClientISP",
  "ConnectedViaHostName","ConnectedViaIPAddress","LaunchedViaHostName","LaunchedViaIPAddress"];

function csvCell(v){
  var s=String(v==null?"":v);
  return(s.indexOf(",")>=0||s.indexOf('"')>=0||s.indexOf("\n")>=0)?
    '"'+s.replace(/"/g,'""')+'"':s;
}
function csvLine(arr){return arr.map(csvCell).join(",");}

function doCSV(){
  var btn=g("btnCSV"); btn.disabled=true;
  showProg("Preparing CSV...");
  var isFiltered=filtered.length!==ALL_ROWS.length;
  var src=isFiltered?filtered:ALL_ROWS;
  var tot=src.length, CHUNK=10000, idx=0;
  var parts=["\uFEFF"+csvLine(CSV_HEADERS)+"\r\n"];
  function pump(){
    var end=Math.min(idx+CHUNK,tot);
    for(var i=idx;i<end;i++){
      var r=src[i],row=[i+1];
      CSV_KEYS.forEach(function(k){row.push(r[k]||"");});
      parts.push(csvLine(row)+"\r\n");
    }
    idx=end;
    setProg(Math.round(idx/Math.max(tot,1)*95),"Writing "+idx.toLocaleString()+" / "+tot.toLocaleString()+"...");
    if(idx<tot){setTimeout(pump,0);return;}
    var blob=new Blob(parts,{type:"text/csv;charset=utf-8"});
    var df=g("fDf").value||"all", dt=g("fDt").value||"all";
    var fname="VCLite_BillingReport_"+df+"_to_"+dt+(isFiltered?"_FILTERED":"")+".csv";
    var url=URL.createObjectURL(blob);
    var a=document.createElement("a");a.href=url;a.download=fname;a.style.display="none";
    document.body.appendChild(a);a.click();
    setTimeout(function(){document.body.removeChild(a);URL.revokeObjectURL(url);},1500);
    hideProg(); btn.disabled=false;
    toast("CSV downloaded: "+tot.toLocaleString()+" rows"+(isFiltered?" (filtered)":""));
  }
  setTimeout(pump,0);
}

function showProg(m){g("progArea").style.display="flex";setProg(0,m);}
function setProg(p,m){g("progFill").style.width=p+"%";set("progTxt",m);}
function hideProg(){g("progArea").style.display="none";setProg(0,"");}
function toast(m){
  var e=g("toast");e.textContent=m;e.classList.add("on");
  setTimeout(function(){e.classList.remove("on");},3500);
}
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

    # HTML template -- ALWAYS written fresh from embedded content.
    # This ensures any fixes in the embedded template are immediately applied
    # on every run, even if an old version already exists on the server.
    Write-Log "Writing HTML template from embedded content: $TemplatePath" "INFO"
    try {
        $embeddedHtml = Get-EmbeddedTemplate
        [System.IO.File]::WriteAllText(
            $TemplatePath,
            $embeddedHtml,
            [System.Text.Encoding]::UTF8)
        Write-Log "HTML template written: $TemplatePath" "OK"
    } catch {
        $errors.Add("Failed to write HTML template: $($_.Exception.Message)")
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
    $html | Out-File -FilePath $path -Encoding UTF8

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
    # Write-Output for HPSA stdout capture (mirrors citrix_audit_v6.ps1 pattern)
    Write-Output "Script Completed: $(Get-Date -Format 'yyyyMMdd_HHmmss')"
    foreach ($f in $htmlFiles) { Write-Output "HTML File : $f" }

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
