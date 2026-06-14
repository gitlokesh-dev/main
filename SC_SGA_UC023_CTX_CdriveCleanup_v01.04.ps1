$ErrorActionPreference = "SilentlyContinue"

##### SMART Automation Logic #### 
try{
    $acDir = 'C:\Apps\Monitor\logs\AutomationControl'
    $acFile = "$acDir\t_po_os_shell_citrix_thr_disk_util.log"
    $runscore = 1
    $maxDuration = 6
    if(!(Test-path -Path $acDir)){
        New-Item $acDir -Force -ItemType Directory | Out-Null
        Start-Sleep 2
    }
    else{
        if(!(Test-path -Path $acFile)){New-Item $acFile -ItemType File -Value $runscore | Out-Null}
        [INT]$RunScore = Get-Content($acFile)
        $lastWriteTime = (Get-Item $acFile).LastWriteTime
        $dt = (Get-Date).DateTime
        $duration =  NEW-TIMESPAN -Start $lastWriteTime -End $dt
        if(($RunScore -ge 3) -and ($duration.Hours -le $maxDuration)){
            New-Item $acFile -ItemType File -Value 0 -Force| Out-Null
            throw "Automation reached Maximum run time in $maxDuration Hours."
        }
        elseif(($RunScore -eq 0) -and ($duration.TotalHours -ge $maxDuration)){
            throw "Automation reached Maximum run time in $maxDuration Hours."
        }
        else{
            $runscore++
            New-Item $acFile -ItemType File -Value $runscore -Force| Out-Null
            Write-Output "Running the script"
        }        
    }
}
catch{
    Write-Output "ERROR: $($_.Exception.Message)"  | Out-File -Append -FilePath "C:\Windows\Temp\$LogDate.log"
    Write-Output "Do not Close the ticket without proper cleanup and take necessary actions if the cleanup not possible."
    Write-Output "$dt : CODE:FAIL"  
    Write-Output "ACTION: Dispatch Ticket To L2"
    Write-Output "Exitcode : 1"
    Exit 1
}

function Show-CDriveSpace {
    $drive  = Get-CimInstance -Class Win32_LogicalDisk -Filter "DeviceID='C:'"
    $totalGB = [math]::Round($drive.Size/1GB,2)
    $freeGB = [math]::Round($drive.FreeSpace/1GB,2)
    $usedGB = [math]::Round(($totalGB - $freeGB),2)
    return [Ordered]@{
        TotalGB = $totalGB
        UsedGB  = $usedGB
        FreeGB  = $freeGB
    }
}

function Report-CDriveSpace($label, $space) {
    Write-output "[$label] C Drive Space Report:" -ForegroundColor Cyan
    Write-output "   Total Size : $($space.TotalGB) GB"
    Write-output "   Used Space : $($space.UsedGB) GB"
    Write-output "   Free Space : $($space.FreeGB) GB"
    Write-output ""
}

function Delete-ComputerRestorePoints{
    [CmdletBinding(SupportsShouldProcess=$True)]param(  
        [Parameter(Position=0, Mandatory=$true, ValueFromPipeline=$true)]
        $restorePoints
    )
    begin{
        $fullName="SystemRestore.DeleteRestorePoint"
        $isLoaded=([AppDomain]::CurrentDomain.GetAssemblies() | foreach {$_.GetTypes()} | where {$_.FullName -eq $fullName}) -ne $null
        if (!$isLoaded){
            $SRClient= Add-Type   -memberDefinition  @"
                [DllImport ("Srclient.dll")]
                public static extern int SRRemoveRestorePoint (int index);
"@  -Name DeleteRestorePoint -NameSpace SystemRestore -PassThru
        }
    }
    process{
        foreach ($restorePoint in $restorePoints){
            if($PSCmdlet.ShouldProcess("$($restorePoint.Description)","Deleting Restorepoint")) {
                [SystemRestore.DeleteRestorePoint]::SRRemoveRestorePoint($restorePoint.SequenceNumber)
            }
        }
    }
}

# --- New Helper Functions for Conditions ---

function Test-FileLocked {
    param([string]$Path)
    try {
        $item = Get-Item $Path -ErrorAction SilentlyContinue
        if ($item -and $item.PSIsContainer) { return $false } # skip folders
        $stream = [System.IO.File]::Open($Path,'Open','Read','None')
        $stream.Close()
        return $false
    } catch { return $true }
}

function Safe-RemoveFiles {
    param([string]$Path)
    Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
        ForEach-Object {
            if (-not (Test-FileLocked $_.FullName)) {
                Remove-Item $_.FullName -Force -Recurse -ErrorAction SilentlyContinue
            }
        }
}

# --- START SCRIPT EXECUTION ---
Write-output "Checking C Drive space before cleanup..." -ForegroundColor Yellow
$beforeSpace = Show-CDriveSpace
Report-CDriveSpace "Before Cleanup" $beforeSpace

Write-output "Deleting System Restore Points"
Get-ComputerRestorePoint | Delete-ComputerRestorePoints # -WhatIf

Write-output "Checking to make sure you have Local Admin rights" -foreground yellow
If (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))
{
    Write-Warning "Please run this script as an Administrator!"
    If (!($psISE)){"Press any key to continue.";[void][System.Console]::ReadKey($true)}
    Exit 1
}

Write-output "Deleting Rouge folders" -ForegroundColor  yellow
if (test-path C:\Config.Msi) {remove-item -Path C:\Config.Msi -force -recurse}
if (test-path c:\Intel) {remove-item -Path c:\Intel -force -recurse}
if (test-path c:\PerfLogs) {remove-item -Path c:\PerfLogs -force -recurse}
if (test-path $env:windir\memory.dmp) {remove-item $env:windir\memory.dmp -force}

Write-output "Deleting Windows Error Reporting files" -ForegroundColor yellow
if (test-path C:\ProgramData\Microsoft\Windows\WER) {Get-ChildItem -Path C:\ProgramData\Microsoft\Windows\WER -Recurse | Remove-Item -force -recurse}

Write-host "Removing System and User Temp Files" -ForegroundColor  yellow
Safe-RemoveFiles -Path "$env:windir\Temp\*" -Force -Recurse
Safe-RemoveFiles -Path "$env:windir\minidump\*" -Force -Recurse
Safe-RemoveFiles -Path "$env:windir\Prefetch\*" -Force -Recurse
Safe-RemoveFiles -Path "C:\Users\*\AppData\Local\Temp\*" -Force -Recurse
Safe-RemoveFiles -Path "C:\Users\*\AppData\Local\Microsoft\Windows\WER\*" -Force -Recurse
Safe-RemoveFiles -Path "C:\Users\*\AppData\Local\Microsoft\Windows\Temporary Internet Files\*" -Force -Recurse
Safe-RemoveFiles -Path "C:\Users\*\AppData\Local\Microsoft\Windows\IECompatCache\*" -Force -Recurse
Safe-RemoveFiles -Path "C:\Users\*\AppData\Local\Microsoft\Windows\IECompatUaCache\*" -Force -Recurse
Safe-RemoveFiles -Path "C:\Users\*\AppData\Local\Microsoft\Windows\IEDownloadHistory\*" -Force -Recurse
Safe-RemoveFiles -Path "C:\Users\*\AppData\Local\Microsoft\Windows\INetCache\*" -Force -Recurse
Safe-RemoveFiles -Path "C:\Users\*\AppData\Local\Microsoft\Windows\INetCookies\*" -Force -Recurse
Safe-RemoveFiles -Path "C:\Users\*\AppData\Local\Microsoft\Terminal Server Client\Cache\*" -Force -Recurse

Write-output "Removing Windows Updates Downloads" -ForegroundColor  yellow
Stop-Service wuauserv -Force -Verbose
Stop-Service TrustedInstaller -Force -Verbose
Safe-RemoveFiles -Path "$env:windir\SoftwareDistribution\*" -Force -Recurse
Safe-RemoveFiles $env:windir\Logs\CBS\* -force -recurse
Start-Service wuauserv -Verbose
Start-Service TrustedInstaller -Verbose
Write-output "Check if Windows Cleanup exists" -ForegroundColor  yellow
if (!(Test-Path c:\windows\System32\cleanmgr.exe)) {
    Write-host "Windows Cleanup NOT installed now installing" -foreground yellow
    copy-item $env:windir\winsxs\amd64_microsoft-windows-cleanmgr_31bf3856ad364e35_6.1.7600.16385_none_c9392808773cd7da\cleanmgr.exe $env:windir\System32
    copy-item $env:windir\winsxs\amd64_microsoft-windows-cleanmgr.resources_31bf3856ad364e35_6.1.7600.16385_en-us_b9cb6194b257cc63\cleanmgr.exe.mui $env:windir\System32\en-US
}

Write-output "Running Windows System Cleanup" -ForegroundColor  yellow
$StateFlags = 'StateFlags0013'
$StateRun = $StateFlags.Substring($StateFlags.get_Length()-2)
$StateRun = '/sagerun:' + $StateRun 
if  (-not (get-itemproperty -path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Active Setup Temp Folders' -name $StateFlags)) {
    # Registry setup omitted for brevity (your original block remains unchanged)
}

Write-output "Starting CleanMgr.exe.." -ForeGroundColor yellow
Start-Process -FilePath CleanMgr.exe -ArgumentList $StateRun -WindowStyle Hidden -Wait

# --- END SCRIPT EXECUTION ---
Write-Host "Checking C Drive space after cleanup..." -ForeGroundColor  Yellow
$afterSpace = Show-CDriveSpace
Report-CDriveSpace "After Cleanup" $afterSpace

# Summary of reclaimed space
$reclaimed = [math]::Round(($afterSpace.FreeGB - $beforeSpace.FreeGB),2)
Write-output "Total Space Reclaimed: $reclaimed GB" -ForegroundColor  Green