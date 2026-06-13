#Requires -Version 5.1
# ==============================================================================
#  VCLite Citrix Billing Report  — LOCAL TEST BUILD
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
# SECTION 1 — CREDENTIALS & SETTINGS  (edit this block for local testing)
# ==============================================================================
$CustomerId   = "ewy3n89x3jns"
$ClientId     = "ba3e7acc-79b1-41ad-835c-90f10f4dd185"
$ClientSecret = "a6P_9bHH2ADWbWF5VCf0TQ=="
$TrustUrl     = "https://api-us.cloud.com/cctrustoauth2"
$MonitorUrl   = "https://api-us.cloud.com/monitorodata"
# ==============================================================================

# ==============================================================================
# SCRIPT DIRECTORY & PATHS
# ==============================================================================
$ScriptDir    = if ($MyInvocation.MyCommand.Path) {
                    Split-Path $MyInvocation.MyCommand.Path -Parent
                } else { $PWD.Path }

$TemplatePath = Join-Path $ScriptDir "VCLite_BillingReport.html"
$OutputFolder = Join-Path $ScriptDir "output"

# ==============================================================================
# DATE RANGE  — defaults to previous full calendar month (UTC)
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
    # Use single-quoted replacement targets to avoid PS escape confusion
    $Json = $Json.Replace('</script>', '<\/script>')
    $Json = $Json.Replace([char]0x2028, ' ')   # LS — line separator
    $Json = $Json.Replace([char]0x2029, ' ')   # PS — paragraph separator
    $Json = $Json.Replace([char]0x0000, '')    # NUL
    return $Json
}

function ConvertTo-Base64Utf8 {
    param([string]$InputString)
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($InputString))
}

# ==============================================================================
# SESSION VALIDITY
# Rule 1 : StartDate missing                    → skip
# Rule 2 : EndDate missing (session still live) → skip
# Rule 3 : StartDate >= EndDate when parsed     → skip (zero-duration / equal)
#           Parsed comparison catches different string representations of the
#           same instant (e.g. with/without milliseconds).
# Rule 4 : StartDate date-part = today UTC      → skip (may still be running)
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
            throw "Empty token returned — verify CustomerId, ClientId, ClientSecret."
        }
        Write-Log "Bearer token acquired." "OK"
        return $token
    } catch {
        throw "Authentication failed: $($_.Exception.Message)"
    }
}

# ==============================================================================
# PREFLIGHT CHECKS
# ==============================================================================
function Invoke-Preflight {
    $errors   = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    # Credentials
    if ([string]::IsNullOrWhiteSpace($CustomerId))   { $errors.Add("CustomerId is empty — set it in SECTION 1.") }
    if ([string]::IsNullOrWhiteSpace($ClientId))     { $errors.Add("ClientId is empty — set it in SECTION 1.") }
    if ([string]::IsNullOrWhiteSpace($ClientSecret)) { $errors.Add("ClientSecret is empty — set it in SECTION 1.") }

    # HTML template
    if (Test-Path $TemplatePath) {
        Write-Log "HTML template : $TemplatePath" "OK"
    } else {
        $errors.Add("HTML template not found: $TemplatePath`n  Place VCLite_BillingReport.html beside the PS1.")
    }

    # Date range
    try {
        $ds   = [datetime]::Parse($QueryStart)
        $de   = [datetime]::Parse($QueryEnd)
        if ($ds -ge $de) { $errors.Add("QueryStart must be earlier than QueryEnd.") }
        $days = ($de - $ds).TotalDays
        if ($days -gt 366) {
            $warnings.Add("Date range spans $([Math]::Round($days)) days — may produce very large output.")
        }
    } catch {
        $errors.Add("QueryStart or QueryEnd is not a valid date: $($_.Exception.Message)")
    }

    # Output folder — create and verify writable
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
        Write-Host "|        PREFLIGHT FAILED — ACTION REQUIRED                  |" -ForegroundColor Red
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
    Write-Log "  Chunk $ChunkIndex — $rowCount rows → $path" "OK"
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

    # Load template — restore placeholder tokens if template was previously populated
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

    # Always emit Base64 for HPSA / Camunda job-step capture
    if ($outFiles.Count -gt 0) {
        $lastFile = $outFiles[$outFiles.Count - 1]
        $lastHtml = Get-Content -Path $lastFile -Raw -Encoding UTF8
        Write-Output "HPSA_REPORT_B64_START"
        Write-Output (ConvertTo-Base64Utf8 -InputString $lastHtml)
        Write-Output "HPSA_REPORT_B64_END"
        Write-Output ("HPSA_REPORT_SHA256:" + (Get-SHA256Hash $lastHtml))
        Write-Output ("HPSA_REPORT_PATH:" + $lastFile)
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

    # Step 0 — Preflight
    Write-Log "[0/3] Preflight checks..." "STEP"
    Invoke-Preflight

    # Step 1 — Authenticate
    Write-Log "[1/3] Authenticating with Citrix Cloud..." "STEP"
    $token = Get-BearerToken -CustomerId $CustomerId `
                             -ClientId   $ClientId `
                             -ClientSecret $ClientSecret
    $apiHeaders = @{
        "Authorization"     = "CwsAuth bearer=$token"
        "Citrix-CustomerId" = $CustomerId
        "Accept"            = "application/json"
    }

    # Step 2 — Build OData query URI
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

    # Step 3 — Generate HTML report
    Write-Log "[3/3] Generating HTML report(s)..." "STEP"
    $fileStamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $htmlFiles = Export-HtmlReport `
                    -BaseUri    $baseUri `
                    -ApiHeaders $apiHeaders `
                    -FileStamp  $fileStamp

    # Summary
    Write-Host ""
    Write-Host "+============================================================+" -ForegroundColor Green
    Write-Host "|         REPORT COMPLETE — VCLite Billing Report            |" -ForegroundColor Green
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
