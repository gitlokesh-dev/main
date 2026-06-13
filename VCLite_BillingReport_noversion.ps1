#Requires -Version 5.1
# ==============================================================================
#  VCLite Citrix Billing Report  — LOCAL TEST BUILD
#  Credentials : Hardcoded below in SECTION 1 (for local testing only)
#  INI file    : NOT required — all values set directly in this script
#  Date range  : Optional parameters; defaults to previous calendar month
#  Output      : Saved to <ScriptDir>\output\VCLite_BillingReport_<stamp>.html
# ==============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$QueryStart = "",      # ISO-8601 e.g. "2026-05-01T00:00:00Z"
                                   # If omitted: first day of previous month (UTC)

    [Parameter(Mandatory=$false)]
    [string]$QueryEnd   = ""       # ISO-8601 e.g. "2026-05-31T23:59:59Z"
                                   # If omitted: last second of previous month (UTC)
)

# ==============================================================================
# SECTION 1 — CREDENTIALS & SETTINGS  (edit this block for local testing)
# ==============================================================================
$CustomerId   = "ewy3n89x3jns"
$ClientId     = "ba3e7acc-79b1-41ad-835c-90f10f4dd185"
$ClientSecret = "a6P_9bHH2ADWbWF5VCf0TQ=="

$TrustUrl   = "https://api-us.cloud.com/cctrustoauth2"
$MonitorUrl = "https://api-us.cloud.com/monitorodata"
# ==============================================================================

# ==============================================================================
# RESOLVE SCRIPT DIRECTORY & OUTPUT FOLDER
# ==============================================================================
$ScriptDir    = if ($MyInvocation.MyCommand.Path) {
    Split-Path $MyInvocation.MyCommand.Path -Parent
} else { $PWD.Path }

$TemplatePath = Join-Path $ScriptDir "VCLite_BillingReport.html"
$OutputFolder = Join-Path $ScriptDir "output"

# ==============================================================================
# DATE RANGE  -- optional; defaults to previous full calendar month (UTC)
# ==============================================================================
$_utcNow           = [datetime]::UtcNow
$_firstThisMonth   = [datetime]::new($_utcNow.Year, $_utcNow.Month, 1, 0, 0, 0,
                         [System.DateTimeKind]::Utc)
$_firstLastMonth   = $_firstThisMonth.AddMonths(-1)
$_lastLastMonth    = $_firstThisMonth.AddSeconds(-1)

if ([string]::IsNullOrWhiteSpace($QueryStart)) {
    $QueryStart = $_firstLastMonth.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
}
if ([string]::IsNullOrWhiteSpace($QueryEnd)) {
    $QueryEnd   = $_lastLastMonth.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
}

# ==============================================================================
# CONSTANTS
# ==============================================================================
$ScriptVersion = "9.4"
$ApiPageSize   = 1000
$MaxRetries    = 3
$RetryDelayMs  = 2000
# Records per output HTML file. At ~800 bytes/row a 500k-row file ≈ 400 MB.
# Reduce if memory is constrained; increase for fewer files.
$HtmlChunkSize = 200000

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
# HELPERS
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
    Write-Host "[$ts] [$Level] $Msg" -ForegroundColor $color
}

function Safe-Str {
    param($v)
    if ($null -eq $v) { return "" }
    return [string]$v
}

function Get-SHA256Hash {
    param([string]$s)
    try {
        $h = [System.Security.Cryptography.SHA256]::Create()
        $b = $h.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s))
        $h.Dispose()
        return [BitConverter]::ToString($b).Replace("-","").ToLower()
    } catch { return "hash-unavailable" }
}

function Sanitize-Json {
    param([string]$j)
    $j = $j.Replace('</script>', '<\/script>')
    $j = $j.Replace([string][char]0x2028, '\u2028')
    $j = $j.Replace([string][char]0x2029, '\u2029')
    $j = $j.Replace([string][char]0x0000, '')
    return $j
}

function To-Base64 {
    param([string]$s)
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($s))
}

# ==============================================================================
# SESSION VALIDITY
# Rule 1: StartDate must be present
# Rule 2: EndDate must be present   (missing = still active)
# Rule 3: StartDate >= EndDate when parsed = zero-duration artefact -- skip
# Rule 4: StartDate date-part = today UTC -- may still be running -- skip
# ==============================================================================
function Is-ValidSession {
    param([Parameter(Mandatory)]$s)
    $sd = Safe-Str $s.StartDate
    $ed = Safe-Str $s.EndDate
    if ([string]::IsNullOrWhiteSpace($sd)) { return $false }   # Rule 1
    if ([string]::IsNullOrWhiteSpace($ed)) { return $false }   # Rule 2
    try {                                                        # Rule 3
        $ts = [datetime]::Parse($sd,$null,[System.Globalization.DateTimeStyles]::RoundtripKind)
        $te = [datetime]::Parse($ed,$null,[System.Globalization.DateTimeStyles]::RoundtripKind)
        if ($ts -ge $te) { return $false }
    } catch { if ($sd -eq $ed) { return $false } }
    $sdDate = $sd.Substring(0,[Math]::Min(10,$sd.Length))
    if ($sdDate -eq $TodayUtcDate) { return $false }            # Rule 4
    return $true
}

# ==============================================================================
# DATA FLATTENING
# ==============================================================================
function ConvertTo-FlatRow {
    param([Parameter(Mandatory)]$s)
    $u  = $s.User
    $m  = $s.Machine
    $ca = if ($m) { $m.Catalog      } else { $null }
    $dg = if ($m) { $m.DesktopGroup } else { $null }
    $c  = $s.CurrentConnection
    return [PSCustomObject]@{
        StartDate             = Safe-Str $s.StartDate
        EndDate               = Safe-Str $s.EndDate
        UserName              = Safe-Str $u.UserName
        FullName              = Safe-Str $u.FullName
        UserUPN               = Safe-Str $u.Upn
        MachineName           = Safe-Str $m.Name
        MachineOS             = Safe-Str $m.OSType
        CatalogName           = Safe-Str $ca.Name
        DesktopGroupName      = Safe-Str $dg.Name
        ClientVersion         = Safe-Str $c.ClientVersion
        ClientPlatform        = Safe-Str $c.ClientPlatform
        ClientName            = Safe-Str $c.ClientName
        ClientIP              = Safe-Str $c.ClientAddress
        ClientPublicIP        = Safe-Str $c.ClientPublicIP
        Protocol              = Safe-Str $c.Protocol
        ClientISP             = Safe-Str $c.ClientISP
        ClientCountry         = Safe-Str $c.ClientLocationCountry
        ClientCity            = Safe-Str $c.ClientLocationCity
        ConnectedViaHostName  = Safe-Str $c.ConnectedViaHostName
        ConnectedViaIPAddress = Safe-Str $c.ConnectedViaIPAddress
        LaunchedViaHostName   = Safe-Str $c.LaunchedViaHostName
        LaunchedViaIPAddress  = Safe-Str $c.LaunchedViaIPAddress
    }
}

# ==============================================================================
# AUTHENTICATION
# ==============================================================================
function Get-BearerToken {
    param([string]$Cid,[string]$Kid,[string]$Sec)
    Write-Log "Requesting bearer token..." "STEP"
    $uri  = "$TrustUrl/$Cid/tokens/clients"
    $body = "grant_type=client_credentials" +
            "&client_id=$([uri]::EscapeDataString($Kid))" +
            "&client_secret=$([uri]::EscapeDataString($Sec))"
    try {
        $r = Invoke-WebRequest -Uri $uri -Method POST -Body $body `
                 -ContentType "application/x-www-form-urlencoded" `
                 -UseBasicParsing -ErrorAction Stop
        $t = ($r.Content | ConvertFrom-Json).access_token
        if ([string]::IsNullOrWhiteSpace($t)) { throw "Empty token returned." }
        Write-Log "Bearer token acquired." "OK"
        return $t
    } catch { throw "Authentication failed: $_" }
}

# ==============================================================================
# PREFLIGHT
# ==============================================================================
function Invoke-Preflight {
    $errs  = [System.Collections.Generic.List[string]]::new()
    $warns = [System.Collections.Generic.List[string]]::new()

    # Credentials
    if ([string]::IsNullOrWhiteSpace($CustomerId))   { $errs.Add("CustomerId is empty  -- set it in SECTION 1 of this script.") }
    if ([string]::IsNullOrWhiteSpace($ClientId))     { $errs.Add("ClientId is empty    -- set it in SECTION 1 of this script.") }
    if ([string]::IsNullOrWhiteSpace($ClientSecret)) { $errs.Add("ClientSecret is empty -- set it in SECTION 1 of this script.") }

    # HTML template
    if (Test-Path $TemplatePath) {
        Write-Log "HTML template: $TemplatePath" "OK"
    } else {
        $errs.Add("HTML template not found: $TemplatePath`n  Place VCLite_BillingReport.html beside the PS1.")
    }

    # Date range validation
    try {
        $ds = [datetime]::Parse($QueryStart)
        $de = [datetime]::Parse($QueryEnd)
        if ($ds -ge $de) { $errs.Add("QueryStart must be earlier than QueryEnd.") }
        $days = ($de - $ds).TotalDays
        if ($days -gt 366) { $warns.Add("Range is $([Math]::Round($days)) days -- may produce very large output.") }
    } catch { $errs.Add("QueryStart/QueryEnd are not valid ISO-8601 dates.") }

    # Output folder
    try {
        if (-not (Test-Path $OutputFolder)) {
            New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
            Write-Log "Output folder created: $OutputFolder" "OK"
        }
        $probe = Join-Path $OutputFolder ".probe_$(Get-Random)"
        [System.IO.File]::WriteAllText($probe,"x")
        Remove-Item $probe -Force
        Write-Log "Output folder writable: $OutputFolder" "OK"
    } catch { $errs.Add("Cannot write to output folder '$OutputFolder': $_") }

    $warns | ForEach-Object { Write-Log "  WARN: $_" "WARN" }

    if ($errs.Count -gt 0) {
        Write-Host "+============================================================+" -ForegroundColor Red
        Write-Host "|          PREFLIGHT FAILED -- ACTION REQUIRED               |" -ForegroundColor Red
        Write-Host "+============================================================+" -ForegroundColor Red
        $errs | ForEach-Object { Write-Log "  [!] $_" "ERROR"; Write-Host "" }
        exit 1
    }
    Write-Log "All preflight checks passed." "OK"
}

# ==============================================================================
# HTML REPORT EXPORT
# Reads HTML template from disk, injects JSON, saves to output folder.
# Chunks automatically at $HtmlChunkSize rows to support 2M+ records.
# ==============================================================================
function Export-HtmlReport {
    param(
        [string]$BaseUri,
        [hashtable]$ApiHeaders,
        [string]$FileStamp
    )

    # Load template -- restore placeholder tokens if this is a re-run on
    # an already-populated file (idempotent)
    $tpl = Get-Content -Path $TemplatePath -Raw -Encoding UTF8
    if ($tpl -notlike "*CITRIX_DATA_PLACEHOLDER_JSON_ARRAY*") {
        $tpl = $tpl -replace '(?s)<script type="application/json" id="citrix-data">.*?</script>',
            '<script type="application/json" id="citrix-data">CITRIX_DATA_PLACEHOLDER_JSON_ARRAY</script>'
        $tpl = $tpl -replace '(?s)<script type="application/json" id="citrix-meta">.*?</script>',
            '<script type="application/json" id="citrix-meta">CITRIX_META_PLACEHOLDER_JSON_OBJECT</script>'
    }

    $generated = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $chunkMax  = if ($HtmlChunkSize -gt 0) { $HtmlChunkSize } else { [int]::MaxValue }
    $buf       = [System.Collections.Generic.List[object]]::new()
    $chunkNum  = 0
    $totalRows = 0
    $skipped   = 0
    $outFiles  = [System.Collections.Generic.List[string]]::new()

    function Flush-Chunk {
        param([int]$Idx,[int]$Total)
        $suffix = if ($Idx -eq 1) { "" } else { "_part$Idx" }
        $path   = Join-Path $OutputFolder "VCLite_BillingReport_${FileStamp}${suffix}.html"

        $rawJson = if ($buf.Count -eq 0) { "[]" }
                   elseif ($buf.Count -eq 1) {
                       "[" + ($buf[0] | ConvertTo-Json -Compress -Depth 3) + "]"
                   } else {
                       "[" + (($buf | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 3 }) -join ",") + "]"
                   }
        $safeJson = Sanitize-Json $rawJson
        $meta = [ordered]@{
            generated     = $generated
            queryStart    = $QueryStart
            queryEnd      = $QueryEnd
            totalRows     = [string]$Total
            skippedRows   = [string]$skipped
            chunkNumber   = $Idx
            rowsInChunk   = $buf.Count
            sha256        = Get-SHA256Hash $safeJson
            scriptVersion = $ScriptVersion
        }
        $safeMeta = Sanitize-Json ($meta | ConvertTo-Json -Compress)

        $html = $tpl.Replace('CITRIX_DATA_PLACEHOLDER_JSON_ARRAY',  $safeJson)
        $html = $html.Replace('CITRIX_META_PLACEHOLDER_JSON_OBJECT', $safeMeta)
        $html | Out-File -FilePath $path -Encoding UTF8 -NoNewline

        Write-Log ("  Chunk {0} — {1} rows  →  {2}" -f $Idx, $buf.Count.ToString('N0'), $path) "OK"
        return $path
    }

    $uri = $BaseUri; $page = 0
    do {
        $page++; $attempt = 0; $ok = $false
        while (-not $ok -and $attempt -lt $MaxRetries) {
            $attempt++
            try {
                $r       = Invoke-WebRequest -Uri $uri -Headers $ApiHeaders -UseBasicParsing -ErrorAction Stop
                $parsed  = $r.Content | ConvertFrom-Json
                $records = if ($parsed.value) { @($parsed.value) } else { @() }

                foreach ($sess in $records) {
                    if (-not (Is-ValidSession $sess)) { $skipped++; continue }
                    $buf.Add((ConvertTo-FlatRow $sess))
                    $totalRows++
                    if ($buf.Count -ge $chunkMax) {
                        $chunkNum++
                        $outFiles.Add((Flush-Chunk -Idx $chunkNum -Total $totalRows))
                        $buf.Clear(); [System.GC]::Collect()
                    }
                }
                $uri = $parsed.'@odata.nextLink'; $ok = $true
            } catch {
                Write-Log "  Page $page attempt $attempt : $_" "WARN"
                if ($attempt -lt $MaxRetries) { Start-Sleep -Milliseconds $RetryDelayMs }
                else { throw "Fetch failed page $page after $MaxRetries attempts: $_" }
            }
        }
    } while (-not [string]::IsNullOrWhiteSpace($uri))

    # Final chunk
    $chunkNum++
    $outFiles.Add((Flush-Chunk -Idx $chunkNum -Total $totalRows))

    # Always emit Base64 for HPSA/Camunda capture
    if ($outFiles.Count -gt 0) {
        $last = Get-Content -Path $outFiles[$outFiles.Count-1] -Raw -Encoding UTF8
        Write-Host "HPSA_REPORT_B64_START"
        Write-Host (To-Base64 $last)
        Write-Host "HPSA_REPORT_B64_END"
    }

    Write-Log ("Export done: {0} rows, {1} skipped, {2} file(s)." -f `
        $totalRows.ToString('N0'), $skipped, $outFiles.Count) "OK"
    return $outFiles
}

# ==============================================================================
# MAIN
# ==============================================================================
try {
    Write-Log "======================================================" "STEP"
    Write-Log "  VCLite Citrix Billing Report" "STEP"
    Write-Log "======================================================" "STEP"
    Write-Log "CustomerId : $CustomerId"
    Write-Log "Template   : $TemplatePath"
    Write-Log "OutputDir  : $OutputFolder"
    Write-Log "DateRange  : $QueryStart  ->  $QueryEnd"
    Write-Log ""

    Write-Log "[0/3] Preflight..." "STEP"
    Invoke-Preflight

    Write-Log "[1/3] Authenticating..." "STEP"
    $token  = Get-BearerToken -Cid $CustomerId -Kid $ClientId -Sec $ClientSecret
    $hdrs   = @{
        "Authorization"     = "CwsAuth bearer=$token"
        "Citrix-CustomerId" = $CustomerId
        "Accept"            = "application/json"
    }

    Write-Log "[2/3] Building OData query..." "STEP"
    $encS    = [uri]::EscapeDataString($QueryStart)
    $encE    = [uri]::EscapeDataString($QueryEnd)
    $filter  = "StartDate%20ge%20$encS%20and%20StartDate%20le%20$encE"
    $baseUri = "$MonitorUrl/Sessions" +
               "?`$filter=$filter" +
               "&`$select=$ODataSelect" +
               "&`$expand=$ODataExpand" +
               "&`$top=$ApiPageSize"
    Write-Log "OData URI built." "OK"

    Write-Log "[3/3] Generating HTML report(s) in: $OutputFolder" "STEP"
    $stamp     = Get-Date -Format "yyyyMMdd_HHmmss"
    $htmlFiles = Export-HtmlReport -BaseUri $baseUri -ApiHeaders $hdrs -FileStamp $stamp

    Write-Host ""
    Write-Host "+============================================================+" -ForegroundColor Green
    Write-Host "|       REPORT COMPLETE  --  VCLite Billing Report           |" -ForegroundColor Green
    Write-Host "+============================================================+" -ForegroundColor Green
    Write-Host ("|  Date range : {0}  ->  {1}" -f $QueryStart.Substring(0,10),$QueryEnd.Substring(0,10)) -ForegroundColor Green
    Write-Host ("|  Files      : {0}" -f $htmlFiles.Count) -ForegroundColor Green
    Write-Host ("|  Output dir : {0}" -f $OutputFolder) -ForegroundColor Green
    Write-Host "+============================================================+" -ForegroundColor Green
    foreach ($f in $htmlFiles) { Write-Host "    $f" -ForegroundColor White }
    Write-Host ""

    if ($htmlFiles.Count -gt 0) {
        try { Start-Process $htmlFiles[0] } catch {}
    }

} catch {
    Write-Host "+============================================================+" -ForegroundColor Red
    Write-Host "|                  SCRIPT FAILED  [!]                       |" -ForegroundColor Red
    Write-Host "+============================================================+" -ForegroundColor Red
    Write-Log "FATAL: $_" "ERROR"
    exit 1
}
