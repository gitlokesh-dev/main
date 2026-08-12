############################################################################################################################################################################
# Script Name : Wintel_Audit_Evidence_Report_v1.06.ps1
# Modified By : Mohammed
# Date        : 27-08-2025
# Description : Script to get the WINTEL Audit Evidence Report
# Version     : 1.00
#             : 1.01 --> Few Bug Fixes, Manual and Auto mode, Supports HPSA output format.
#             : 1.02 --> Few Bug Fixes, KBInstalled Fix and Changed the Control Number Name.
#             : 1.03 --> BugFix
#             : 1.04 --> Bug Fix, Added Control numbers as choice.
#             : 1.05 --> Bug Fix, Added MON,ER Controls and Other Control Numbers requires Same EVidence.
#             : 1.06 --> Bug Fix, Added EventLog FileNames, New controls
# Usage       : Wintel_Audit_Evidence_Report_v1.06.ps1 -ServerList <Server1,Server2,...> or Wintel_Audit_Evidence_Report_v1.06.ps1 -ServerList <Server1_Server2_...>
# Input Format: Servers Must be "_" or ","Separated.
# Validation  : Input Entires Must not be Empty
# Functions   : None
# ExitCode    : 0 -->Success, 1 -->Error
# Output      : HTML format for HPSA HTML Report via email
############################################################################################################################################################################
Param([STRING]$ServerList = "$ENV:COMPUTERNAME,",
    [String]$from = 'noreply-TSISRE-team@shell.com',
    #[String[]]$toList = @("hussain-b.mohd-anwar@t-systems.com"),#For testing only, Do not Remove
    #[String[]]$ccList = @("hussain-b.mohd-anwar@t-systems.com"),#For testing only, Do not Remove
    [String[]]$toList = @("DL-TS-Delivery-SL-CSS-Shell-SEC-Secops@t-systems.com",
                            "tsin.sh.wintel_server_ops@t-systems.com"),
    [String[]]$ccList = @("Asmah.Othman@external.t-systems.com","hussain-b.mohd-anwar@t-systems.com"),
    [String]$SMTP = "smtp-eu.shell.com",
    [INT]$port = 25,
    [switch]$bulk,
    [switch]$Manual,
    [ValidateSet("TS.PE-PAT.01 (DS5.SOA.09) - Test  C",
                "TS.PE-PAT.01 B2",
                "TS.PE-PAT.01 (DS5.SOA.09) - Test  D",
                "TS.PE-PAT.01 E",
                "TS.PE-SACM.01 (DS9.SOA.02) - Test C",
                "TS.PE-SACM.01 C",
                "TS.SC-OS.02 - B",
                "TS.SC-OS.02 Audit policy",
                "TS.SC-OS.03 (DS5.SOA.06) - Test B",
                "TS.SC-OS.03-B",
                "TS.SC-OS.04 B.2",
                "TS.SC-OS.02 (DS5.SOA.05) - Test C",
                "TS.PE-CHM.01 (A.16.SOA.01) - Test B",
                "TS.PE-CHM.01 B",
                "TS.OP-MON.01 (DS13.SOA.01) - Test B",
                "TS.SC-OS.04 Test B",
                "TS.SC-OS.06 Test B",
                "TS.SC-OS.06 Test C",
                "TS.SC-LOG.01 (DS13.SOA.02) - Test B",
                "TS.OS-MON.03 B",
                "TS.SC-UAM.22 B",
                "ALL")]$ctrlNum = "ALL"
)
$Host.UI.RawUI.BufferSize = New-Object Management.Automation.Host.Size (1000, 1000)
$ErrorActionPreference = "SilentlyContinue"
$ScriptDir = (Split-Path $script:MyInvocation.MyCommand.Path)+"\"
$ReportData=@()
Function GetRegistryValue($Comp, $InstalledSoftwareKey, $RegKeys){
    $list = [PSCustomObject][Ordered]@{}
    $InstalledSoftware=[microsoft.win32.registrykey]::OpenRemoteBaseKey('LocalMachine',$Comp)
    $RegistryKey=$InstalledSoftware.OpenSubKey($InstalledSoftwareKey)
    Foreach($rKey in $RegKeys){
        $thisSubKey=$RegistryKey.GetValue("$rKey")
        $list | Add-Member -MemberType NoteProperty -Name "$rKey" -Value $thisSubKey -force
        }
    $list
}
Function GetLogStatus{
    Param([STRING]$sElog, [STRING]$sName)
    $elSvrPath = "\\$sElog\E$\DATA\ELogRepository\Managed-Servers\$sName"
    $Remarks = $null
    $elsvr = @()
    Try{
        $elAppDateDiff = $null
        $ApplogDays =  $null
        $elAppData = (Get-ChildItem -Path $elSvrPath).Name | Sort-Object  | Where-Object{$_ -Match "Archive-Application"}
        $elAppInfo = $elAppData  | Select-Object -First 1 -Last 1
        if($elAppInfo.Count -eq 2){
            $CurrentAppLog = $elAppInfo[0]
            $OldestAppLog = $elAppInfo[1]
            $elAppDateDiff =  GetDateDiff $elAppInfo "Application"
            $ApplogDays = $elAppDateDiff
            }
        elseif($elAppInfo.Count -eq 1){
            $CurrentAppLog = $elAppInfo
            }
        else{
            $Remarks = "Application Event Log data not Available!!!,"
            }
        
        }
    Catch{$Remarks += "Application Log Status Error $($_.Exception.Message)"}
    Try{
        $elSecDateDiff =  $null
        $SecLogDays =  $null
        $elSecData = (Get-ChildItem -Path $elSvrPath).Name | Sort-Object  | Where-Object{$_ -Match "Archive-Security"}
        $elSecInfo = $elSecData  | Select-Object -First 1 -Last 1
        if($elSecInfo.Count -eq 2){
            $CurrentSecLog = $elSecInfo[0]
            $OldestSecLog = $elSecInfo[1]
            $elSecDateDiff =  GetDateDiff $elSecInfo "Security"
            $SecLogDays = $elSecDateDiff
            }
        elseif($elSecInfo.Count -eq 1){$CurrentSecLog = $elSecInfo}
        else{$Remarks += "Security Event Log data not Available!!!,"}
        
        }
    Catch{$Remarks += "Security Log Status Error $($_.Exception.Message)"}
    Try{
        $elSecDateDiff =  $null
        $SecLogDays =  $null        
        $elSysData = (Get-ChildItem -Path $elSvrPath).Name | Sort-Object  | Where-Object{$_ -Match "Archive-System"}
        $elSysInfo = $elSysData  | Select-Object -First 1 -Last 1
        if($elSysInfo.Count -eq 2){
            $CurrentSysLog = $elSysInfo[0]
            $OldestSysLog = $elSysInfo[1]
            $elSysDateDiff =  GetDateDiff $elSysInfo "System"
            $SysLogDays = $elSysDateDiff
            }
        elseif($elSysInfo.Count -eq 1){$CurrentSysLog = $elSysInfo}
        else{$Remarks += "System Event Log data not Available!!!,"}
        
        }
    Catch{$Remarks += "System Log Status Error $($_.Exception.Message)"}
    $elsvr += "----------------------------------------------------------------------------"
    $elsvr += "$("LogName : Security Log")"
    $elsvr += "$("EventLogs Available for Days : $SecLogDays")"
    $elsvr += "$("Latest Archive Log File : $CurrentSecLog")"
    $elsvr += "$("Earliest Archive Log File : $OldestSecLog")"
    $elsvr += "$("Security LogFile Names :")"
    $elsvr += "----------------------------------------------------------------------------"
    if($elSecData -ge 1){Foreach($lFName in $elSecData){$elsvr += $lFName}}
    else{$elsvr += "$("CENTRAL LOG SERVER : SECURITY LOGS NOT AVAILABLE")"}
    $elsvr += "----------------------------------------------------------------------------"
    $elsvr += "$("LogName : Application")"
    $elsvr += "$("EventLogs Available for Days : $ApplogDays")"
    $elsvr += "$("Latest Archive Log File : $CurrentAppLog")"
    $elsvr += "$("Earliest Archive Log File : $OldestAppLog")"
    $elsvr += "$("Application LogFile Names :")"
    $elsvr += "----------------------------------------------------------------------------"
    if($elAppData -ge 1){Foreach($lFName in $elAppData){$elsvr += $lFName}}
    else{$elsvr += "$("CENTRAL LOG SERVER : APPLICATION LOGS NOT AVAILABLE")"}
    $elsvr += "----------------------------------------------------------------------------"
    $elsvr += "$("LogName : System")"
    $elsvr += "$("EventLogs Available for Days : $SysLogDays")"
    $elsvr += "$("Latest Archive Log File : $CurrentSysLog")"
    $elsvr += "$("Earliest Archive Log File : $OldestSysLog")"
    $elsvr += "$("System LogFile Names :")"
    $elsvr += "----------------------------------------------------------------------------"
    if($elSysData -ge 1){Foreach($lFName in $elSysData){$elsvr += $lFName}}
    else{$elsvr += "$("CENTRAL LOG SERVER : SYSTEM LOGS NOT AVAILABLE")"}
    $elsvr += "----------------------------------------------------------------------------"
    $elsvr
}
Function GetDateDiff($iElog, $logType){
    $eloDataNotListed = "$logType EventLog Data Not Available"
    $regExElDate =  "(?<=Archive-.*-)(\d\d\d\d-\d\d-\d\d)"
    $elDateDiff = 0
    if($eLog.Length -eq 2){
        $iElog =  $iElog.split(" ")
        $cELog =  ([regex]::match($($eLog[0]), $regExElDate).Value).trim()
        $lELog =  ([regex]::match($($eLog[1]), $regExElDate).Value).trim()
        $cELDate = Get-date([datetime]::ParseExact("$cELog", 'yyyy-MM-dd', $null)) -Format "yyyy-MM-dd"
        $lELDate = Get-date([datetime]::ParseExact("$lELog", 'yyyy-MM-dd', $null)) -Format "yyyy-MM-dd"
        $elDateDiff = (New-TimeSpan -Start $cELDate -End $lELDate).Days
        $elDateDiff
    }
    elseif($iElog.Length -eq 0){$eloDataNotListed}
    else{
        $cELog =  ([regex]::match($($iElog), $regExElDate).Value).trim()
        $crrDate = Get-Date -Format "yyyy-MM-dd"
        $elDateDiff = (New-TimeSpan -Start $cELog -End $crrDate).Days
        $elDateDiff
    }
}
Function ServerLogStatus($svrFQDN){
    $sresults = @()
    if($svrFQDN -match "europe"){$sresults += GetLogStatus -sElog "AMSDC1-S-42732.europe.shell.com" -sName $svrFQDN}
    elseif($svrFQDN -match "asia-pac"){$sresults += GetLogStatus -sElog "PEJJBT-S-08206.asia-pac.shell.com" -sName $apSvrs}
    elseif($svrFQDN -match "americas"){$sresults += GetLogStatus -sElog "HOUCY1-S-06233.americas.shell.com" -sName $amSvrs}
    else{$sresults += "Unknown Server Domain: $svrFQDN"}
    $sresults
}
Function GetKBDetails($comp){
    $isCodes = @{}
    $isCodes.Add(0,"not started")
    $isCodes.Add(1,"in progress")
    $isCodes.Add(2,"succeeded")
    $isCodes.Add(3,"succeededwitherrors")
    $isCodes.Add(4,"failed")
    $isCodes.Add(5,"aborted")
    $kbOutput = @("Installed KBs:")
    $kbOutput += "Date Time : $(Get-Date)"
    $kbOutput += "Command:"
    $kbOutput += '[activator]::CreateInstance([type]::GetTypeFromProgID(“Microsoft.Update.Session”,' + $comp + '))'
$tHead = @"
<div><table>
<thead><tr>
<th>KBNumber</th>
<th>InstalledOn</th>
<th>Status</th>
<th>UpdateTitle</th></tr>
</thead>
<tbody>
"@
$tbody = @"
</tbody></table></div>
"@
    $kbOutput += $tHead
    #$kbOutput += '--------------------------------------------------------------------------------------------'
    #$kbOutput += "InstalledOn,KBNumber,Status,UpdateTitle"
    Try{
        $session = [activator]::CreateInstance([type]::GetTypeFromProgID("Microsoft.Update.Session",$comp))
        $searcher = $session.CreateUpdateSearcher()
        #$historyCount = $searcher.GetTotalHistoryCount()
        $hotfixes = $searcher.QueryHistory(0, 15)
        # custom output object
        #Iterating and finding updates
        if($hotfixes){
            foreach($update in $hotfixes) {
            # 1 means in progress and 2 means succeeded
            if($isCodes.ContainsKey($($update.resultcode))){$sCode = $isCodes[$($update.resultcode)]}
            else{$sCode = "Unknown Resultcode:$($update.resultcode)"}
            #$kbOutput += "$($update.date),$([regex]::match($update.Title,'KB(\d+)')),$sCode,$($update.title)"
            $kbOutput += "<tr><td>$([regex]::match($update.Title,'KB(\d+)'))</td>
                            <td>$($update.date)</td>
                            <td>$sCode</td>
                            <td>$($update.title)</td></tr>"
            } #foreach $update
        }
        else{$kbOutput += '<td colspan="4">Unable to get the Hotfix/KB Information</td>'}        
        $kbOutput += $tbody
        $($kbOutput)
        }
    Catch {
        $kbOutput += '<td colspan="4">Error: '+ $($_.Exception.Message) +'</td>'
        $kbOutput += $tbody
        $($kbOutput)
        }
    }
Function GetServerInfo($comp){
    $svrOSInfo = GetRegistryValue "$comp" "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion" @("ProductName", "ReleaseID", "CurrentBuild", "CurrentVersion")
    $svrName = GetRegistryValue "$comp" "SYSTEM\\CurrentControlSet\\Control\\ComputerName\\ActiveComputerName" "ComputerName"
    $svrDomainInfo = GetRegistryValue "$comp" "SYSTEM\\CurrentControlSet\\Services\\Tcpip\\Parameters" "Domain"
    $tServerInfo = [PSCustomObject][Ordered]@{
        HostName = $($svrName.ComputerName)
        OperatingSystem = $($svrOSInfo.ProductName)
        ReleaseID = $($svrOSInfo.ReleaseID)
        Build = $($svrOSInfo.CurrentBuild)
        Version = $($svrOSInfo.CurrentVersion)
        Domain = $($svrDomainInfo.Domain)
        FQDN = "$($svrName.ComputerName).$($svrDomainInfo.Domain)"
        }
    $tServerInfo
    }
Function GetDomainUserSID($duSID){
    $sidFound = $false
    $sidDetails = $null
    $uSIDdetails = $null
    $Array_DomainNames = @("ASIA-PAC","AMERICAS","EUROPE","AFRICA-ME","VSAT","Shell","RSS")
    $searcher = New-Object System.DirectoryServices.DirectorySearcher
    ForEach($Domain in $Array_DomainNames){
            try{
                $sidDetails = $null
                $searcher.SearchRoot = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$Domain")
                $searcher.Filter = "(objectSid=$duSID)"
                $sResult = $searcher.FindOne()
			    if($sResult){
                    $sidDetails = $sResult.GetDirectoryEntry()
                    $sidFound = $true
                    break
                    }			    
                }
            Catch{$uSIDdetails = "$duSID"}
    }
    if($sidFound){$uSIDdetails = $($sidDetails.SamAccountName)}
    else{$uSIDdetails = "$duSID"}    
    $uSIDdetails
}
Function GetControlNum($cNum,$comp,$Manual,$AllCtrls){
    $ResultData = @()
    $kbData = $null
    $caEvtLogData = @()
    $lEvtLogData = @()
    $laEvtLogData = @()
    $psexec = "C:\Scripts\Tools\PSTools\PsExec.exe"
    $svrDetails = GetServerInfo $comp
    Switch($cNum){
        {($_ -eq "TS.PE-PAT.01 (DS5.SOA.09) - Test  C") -or ($_ -eq "TS.PE-PAT.01 B2")}  {
                            If($AllCtrls){
                                $ctrlName = "TS.PE-PAT.01 (DS5.SOA.09) - Test  C <br> TS.PE-PAT.01 B2"
                                }
                            else{$ctrlName = $cNum}
                            $tempObj = [pscustomobject][ordered]@{
                                            ServerName = $($comp)
                                            OnlineStatus = "ONLINE"
                                            OperatingSystem = "$($svrDetails.OperatingSystem)"
                                            ControlNumber = $ctrlName
                                            Details = "None"
                                            Result = "None"
                                            }
                            $tempObj.Details = @("i. List of latest installed patches")
                            $kbDetails = GetKBDetails $comp
                            $tempObj.Result = $kbDetails
                            $kbData = $kbDetails
                            #if($cNum -eq "ALL"){$kbData = $kbDetails}
                            $ResultData += $tempObj
                            }
        {($_ -eq "TS.PE-PAT.01 (DS5.SOA.09) - Test  D") -or ($_ -eq "TS.PE-PAT.01 E")} {#Write-Warning "Control: $_"
                            If($AllCtrls){
                                $ctrlName = "TS.PE-PAT.01 (DS5.SOA.09) - Test  D <br> TS.PE-PAT.01 E"
                                }
                            else{$ctrlName = $cNum}
                            $tempObj = [pscustomobject][ordered]@{
                                            ServerName = $($comp)
                                            OnlineStatus = "ONLINE"
                                            OperatingSystem = "$($svrDetails.OperatingSystem)"
                                            ControlNumber = $ctrlName
                                            Details = "None"
                                            Result = "None"
                                            }
                            $Details = @($null)
                            $Details += "Antivirus and malware details"
                            $Details += "i. Product name, versions"
                            $Details += "ii. Versions of virus and malware pattern file"
                            $Details += "iii. Scheduled scan is enabled"
                            $Details += "iv. Connected status to central av console"
                            $tempObj.Details = $Details
                            $avServer = (GetRegistryValue "$comp" "SOFTWARE\\WOW6432Node\\TrendMicro\\PC-cillinNTCorp\\CurrentVersion" "Server").Server
                            $avAgentGUID = (GetRegistryValue "$comp" "SOFTWARE\\WOW6432Node\\TrendMicro\\PC-cillinNTCorp\\CurrentVersion" "GUID").GUID
                            $avConnectionStatus = (GetRegistryValue "$comp" "SOFTWARE\\WOW6432Node\\TrendMicro\\PC-cillinNTCorp\\CurrentVersion" "ConnToServer").ConnToServer
                            $avSSLPort = (GetRegistryValue "$comp" "SOFTWARE\\WOW6432Node\\TrendMicro\\PC-cillinNTCorp\\CurrentVersion" "ServerSSLPort").ServerSSLPort
                            $avProductName = (GetRegistryValue "$comp" "SOFTWARE\\WOW6432Node\\TrendMicro\\PC-cillinNTCorp\\CurrentVersion\\Misc." "ProductName").ProductName
                            $avProductVersion = (GetRegistryValue "$comp" "SOFTWARE\\WOW6432Node\\TrendMicro\\PC-cillinNTCorp\\CurrentVersion\\Misc." "ProgramVer").ProgramVer
                            $avProductBuild = (GetRegistryValue "$comp" "SOFTWARE\\WOW6432Node\\TrendMicro\\PC-cillinNTCorp\\CurrentVersion\\Misc." "BuildNum").BuildNum
                            $avPatternVersion = (GetRegistryValue "$comp" "SOFTWARE\\WOW6432Node\\TrendMicro\\PC-cillinNTCorp\\CurrentVersion\\Misc." "InternalPatternVer").InternalPatternVer
                            $avLastUpdateSvr = (GetRegistryValue "$comp" "SOFTWARE\\WOW6432Node\\TrendMicro\\PC-cillinNTCorp\\CurrentVersion\\Misc." "LastUpdateTime").LastUpdateTime
                            $avLastUpdateTime = ((Get-Date 01.01.1970)+([System.TimeSpan]::fromseconds($avLastUpdateSvr))).ToLocalTime()
                            $avLastSuccessfulUpdate = (GetRegistryValue "$comp" "SOFTWARE\\WOW6432Node\\TrendMicro\\PC-cillinNTCorp\\CurrentVersion\\Misc." "OUSTimeStamp").OUSTimeStamp
                            $avLastSuccessfulUpdateTime = [System.DateTime]::ParseExact($avLastSuccessfulUpdate,'yyyyMMddHHmmsss',$null)
                            $avPatternDate = (GetRegistryValue "$comp" "SOFTWARE\\WOW6432Node\\TrendMicro\\PC-cillinNTCorp\\CurrentVersion\\Misc." "PatternDate").PatternDate
                            $avPatternDateTime = [System.DateTime]::ParseExact($avPatternDate,'yyyyMMdd',$null)
                            $avScheduledScan = (GetRegistryValue "$comp" "SOFTWARE\WOW6432Node\TrendMicro\PC-cillinNTCorp\CurrentVersion\Prescheduled Scan Configuration" "ScheduleScanStatus").ScheduleScanStatus
                            $avScanEngineVersion = (GetRegistryValue "$comp" "SOFTWARE\\WOW6432Node\\TrendMicro\\PC-cillinNTCorp\\CurrentVersion\\Misc." "EngineZipVer").EngineZipVer
                            $result = @("Antivirus and malware details:")
                            $result += "Date Time : $(Get-Date)"
                            $result += "Command:"
                            $result += 'Information from Registry Path:'
                            $result += 'HKLM\\SOFTWARE\\WOW6432Node\\TrendMicro\\PC-cillinNTCorp\\CurrentVersion'
                            $result += 'HKLM\\SOFTWARE\\WOW6432Node\\TrendMicro\\PC-cillinNTCorp\\CurrentVersion\\Misc.'
                            $result += 'HKLM\\SOFTWARE\\WOW6432Node\\TrendMicro\\PC-cillinNTCorp\\CurrentVersion\\Prescheduled Scan Configuration'
                            $result += '-------------------------------------------------------------------'
                            $result += "ProductName = $avProductName"
                            $result += "ProductVersion = " + "$avProductVersion . $avProductBuild"
                            $result += "PatternVersion = $avPatternVersion"
                            $result += "ConnectionStatus = $avConnectionStatus"
                            $result += "PATTERNDATE = $avPatternDate"
                            $result += "Scan Engine Version = $avScanEngineVersion"
                            $result += "LastSuccessfulRunTime = $avLastUpdateTime"
                            $result += "LastSuccessfullUpdateTime = $avLastSuccessfulUpdateTime"
                            $result += "ServerNamePort = " + "$avServer : $avSSLPort"
                            $result += "AgentGUID = $avAgentGUID"
                            $result += "ScheduledScan = $avScheduledScan"
                            $tempObj.Result = $($result)
                            $ResultData += $tempObj
                            }
        {($_ -eq "TS.PE-SACM.01 (DS9.SOA.02) - Test C") -or ($_ -eq "TS.PE-SACM.01 C")} {
                             If($AllCtrls){
                                $ctrlName = "TS.PE-SACM.01 (DS9.SOA.02) - Test C <br> TS.PE-SACM.01 C"
                                }
                            else{$ctrlName = $cNum}
                            $tempObj = [pscustomobject][ordered]@{
                                            ServerName = $($comp)
                                            OnlineStatus = "ONLINE"
                                            OperatingSystem = "$($svrDetails.OperatingSystem)"
                                            ControlNumber = $ctrlName
                                            Details = "None"
                                            Result = "None"
                                            }
                            $Details = @($null)
                            $Details += "Server basic information"
                            $Details += "i. Hostname"
                            $Details += "ii. Operating system version & release / patch "
                            $Details += "iii. Domain name / FQDN"
                            $tempObj.Details = $Details
                            $result = @("System Information:")
                            $result += "Date Time : $(Get-Date)"
                            $result += "Command:"
                            $result += 'Information from Registry Path:'
                            $result += 'HKLM\\SYSTEM\\CurrentControlSet\\Control\\ComputerName\\ActiveComputerName'
                            $result += 'HKLM\\SYSTEM\\CurrentControlSet\\Services\\Tcpip\\Parameters'
                            $result += 'HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion'
                            $result += '-------------------------------------------------------------------'
                            #$svrDetails = GetServerInfo $svrName
                            $result += "HostName = $($svrDetails.HostName)"
                            $result += "OperatingSystem = $($svrDetails.OperatingSystem)"
                            $result += "ReleaseID = $($svrDetails.ReleaseID)"
                            $result += "Build = $($svrDetails.Build)"
                            $result += "Version = $($svrDetails.Version)"
                            $result += "Domain = $($svrDetails.Domain)"
                            $result += "FQDN = $($svrDetails.FQDN)"
                            $tempObj.Result = $($result)
                            $ResultData += $tempObj
                            }
        {($_ -eq "TS.SC-OS.02 - B")} {#Write-Warning "Control: $_"
                            $tempObj = [pscustomobject][ordered]@{
                                            ServerName = $($comp)
                                            OnlineStatus = "ONLINE"
                                            OperatingSystem = "$($svrDetails.OperatingSystem)"
                                            ControlNumber = "TS.SC-OS.02 - B"
                                            Details = "None"
                                            Result = "None"
                                            }
                            $compFQDN = "$($svrDetails.FQDN)"
                            $Details = @($null)
                            $Details += "Authentication events (failed and successful) are logged"
                            $Details += "i. Setting"
                            $Details += "ii. Sample of the entry in the log file for failed and successful authentication"
                            $tempObj.Details = $Details
                            $result =@("Authentication events:")
                            $result += "Date Time : $(Get-Date)"
                            $result += 'Command:'
                            $result += 'Get-WinEvent -ComputerName ' + "$comp" +' -FilterHashtable @{LogName="Security";Id=4624} -MaxEvents 1'
                            $result += '----------------------------------------------------------------------------------------------------------------------'
                            $result += ("Success Events:")
                            $result += ("TimeWritten,System,Source,EventID,UserID")
                            if($Manual){
                                [xml]$evtSuccess = & cmd /c "wevtutil /r:$comp  qe Security /q:""*[System[(EventID=4624)]]"" /rd /c:1 /f:xml"
                                $evtSuccess = $null
                                if(!($evtSuccess.Event)){
                                    #$result += ("Generating Event for Login Success Event.")
                                    Try{$null = & cmd /c "$psexec -accepteula -s \\$comp cmd /c powershell.exe -Command Get-Process -Verb RunAs -ErrorAction SilentlyContinue"  2>$null}
                                    Catch{$null = $_.Exception.Message}
                                    Start-Sleep -Seconds 2
                                    [xml]$evtSuccess = & cmd /c "wevtutil /r:$comp  qe Security /q:""*[System[(EventID=4624)]]"" /rd /c:1 /f:xml"
                                    }
                                $evt = @()
                                foreach ($eventXml in $evtSuccess.Event) {
                                        $evt += "$([DateTime]$eventXml.System.TimeCreated.SystemTime)"
                                        $evt += "$($eventXml.System.Computer)"
                                        $evt += "$($eventXml.System.Provider.Name)"
                                        $evt += "$($eventXml.System.EventID)"
                                        $evt += "$(($eventXml.EventData.Data | Where-Object { $_.Name -eq "TargetUserName" }).'#text')"
                                        }
                                $result += $evt -join ","
                                }
                            else{
                                $evtSuccess = Get-WinEvent -ComputerName "$comp" -FilterHashtable @{LogName="Security";Id=4624} -MaxEvents 1
                                if($evtSuccess.count -eq 0){
                                    ### Running a local command with elevated privileges.
                                    Try{Start-Process -WindowStyle Hidden -FilePath "powershell.exe" -ArgumentList "-Command Get-Process" -Verb RunAs -Wait -ErrorAction SilentlyContinue}
                                    Catch{$null = $_.Exception.Message}
                                    Start-Sleep -Seconds 5
                                    $evtSuccess = Get-WinEvent -ComputerName "$comp" -FilterHashtable @{LogName="Security";Id=4624} -MaxEvents 1
                                    }
                                $evt = @()
                                $result += $evtSuccess| ForEach-Object {
                                                            # convert the event to XML and grab the Event node
                                                            $eventXml = ([xml]$_.ToXml()).Event
                                                            $evt += "$([DateTime]$eventXml.System.TimeCreated.SystemTime)"
                                                            $evt += "$($eventXml.System.Computer)"
                                                            $evt += "$($eventXml.System.Provider.Name)"
                                                            $evt += "$($eventXml.System.EventID)"
                                                            $evt += "$(($eventXml.EventData.ChildNodes| where{$_.Name -eq "TargetUserName"} | select '#text').'#text')"
                                                            $evt -join ","
                                                            }
                                }
                            $result += '----------------------------------------------------------------------------------------------------------------------'
                            $result += ("Failed Events:")
                            $result += "Date Time : $(Get-Date)"
                            $result += 'Command:'
                            $result += 'Get-WinEvent -ComputerName ' +"$comp" + '-FilterHashtable @{LogName="Security";Id=4625} -MaxEvents 1'
                            $result += '----------------------------------------------------------------------------------------------------------------------'
                            $result += ("TimeWritten,System,Source,EventID,UserID")
                            if($Manual){
                                [xml]$evtFailed = & cmd /c "wevtutil /r:$comp  qe Security /q:""*[System[(EventID=4625)]]"" /rd /c:1 /f:xml"
                                if(!($evtFailed.Event)){
                                    if($($null = & cmd /c "$psexec -accepteula -s \\$comp cmd /c net user | findstr ""osadmin""" 2>$null)){$username = "osadmin"}
                                    elseif($($null = & cmd /c "$psexec -accepteula -s \\$comp cmd /c net user | findstr ""memberadmin-a""" 2>$null)){$username = "memberadmin-a"}
                                    else{$username = "Administrator"}
                                    #$result += ("Generating Event for Local User : $username")
                                    Try{& cmd /c "$psexec -accepteula -s \\$comp cmd /c net use \\127.0.0.1\C$ /user:$username ""password"""}
                                    Catch{$null = $_.Exception.Message}
                                    Start-Sleep -Seconds 2
                                    [xml]$evtFailed = & cmd /c "wevtutil /r:$comp  qe Security /q:""*[System[(EventID=4625)]]"" /rd /c:1 /f:xml"
                                    }
                                $evt = @()
                                foreach ($eventXml in $evtFailed.Event) {
                                        $evt += "$([DateTime]$eventXml.System.TimeCreated.SystemTime)"
                                        $evt += "$($eventXml.System.Computer)"
                                        $evt += "$($eventXml.System.Provider.Name)"
                                        $evt += "$($eventXml.System.EventID)"
                                        $evt += "$(($eventXml.EventData.Data | Where-Object { $_.Name -eq "TargetUserName" }).'#text')"
                                        }
                                $result += $evt -join ","
                                }
                            else{
                                $evtFailed = Get-WinEvent -ComputerName "$comp" -FilterHashtable @{LogName="Security";Id=4625} -MaxEvents 1
                                $evtFailed = $null
                                if($evtFailed.count -eq 0){
                                    ### Running a local command with incorrect privileges
                                    if($(& cmd /c 'net user | findstr "osadmin"')){$username = "osadmin"}
                                    elseif($(& cmd /c 'net user | findstr "memberadmin-a"')){$username = "memberadmin-a"}
                                    else{$username = "Administrator"}
                                    #$result += ("Generating Event for Local User : $username")
                                    Try{& cmd /c "net use \\127.0.0.1\C$ /user:$username $password"}
                                    Catch{$null = $_.Exception.Message}
                                    Start-Sleep -Seconds 2
                                    $evtFailed = Get-WinEvent -ComputerName "$comp" -FilterHashtable @{LogName="Security";Id=4625} -MaxEvents 1
                                    }
                                $evt = @()
                                $result += $evtFailed | ForEach-Object {
                                            # convert the event to XML and grab the Event node
                                            $eventXml = ([xml]$_.ToXml()).Event
                                            $evt += "$([DateTime]$eventXml.System.TimeCreated.SystemTime)"
                                            $evt += "$($eventXml.System.Computer)"
                                            $evt += "$($eventXml.System.Provider.Name)"
                                            $evt += "$($eventXml.System.EventID)"
                                            $evt += "$(($eventXml.EventData.ChildNodes| where{$_.Name -eq "TargetUserName"} | select '#text').'#text')"
                                            $evt -join ","
                                            }
                                }
                            #Getting Event Logs Availablity Status
                            $result += '--------------------------------------------------------------------------'
                            $result += "Local Log Status:"
                            $result += "Date Time : $(Get-Date)"
                            $result += 'EventLogs from Local Server Location "%SystemRoot%\System32\winevt\Logs"'
                            $result += "Server FQDN : $compFQDN"
                            $result += '--------------------------------------------------------------------------'
                            $result +=  "EventLog;FileName;LastWriteTime;CreationTime;Remarks"
                            $result +=  "----------------------------------------------------------"
                            $lEvtLogs = gci "\\$compFQDN\C$\Windows\System32\winevt\Logs"
                            $seEvtLog = $lEvtLogs | where{$_.Name -eq "Security.evtx"}
                            $aEvtLog = $lEvtLogs | where{$_.Name -eq "Application.evtx"}
                            $syEvtLog = $lEvtLogs | where{$_.Name -eq "System.evtx"}
                            ##File Name format Archive-<Logtype>-YYYY-MM-DD-HH-MM-SSS-mmm.evt
                            $result +=  "Security;Security.evtx;$($seEvtLog.LastWriteTime);$($seEvtLog.CreationTime);None"
                            $lEvtLogData += "Security;Security.evtx;$($seEvtLog.LastWriteTime);$($seEvtLog.CreationTime);None"
                            $result +=  "Application;Application.evtx;$($aEvtLog.LastWriteTime);$($aEvtLog.CreationTime);None"
                            $lEvtLogData += "Application;Application.evtx;$($aEvtLog.LastWriteTime);$($aEvtLog.CreationTime);None"
                            $result +=  "System;System.evtx;$($syEvtLog.LastWriteTime);$($syEvtLog.CreationTime);None"
                            $lEvtLogData += "System;System.evtx;$($syEvtLog.LastWriteTime);$($syEvtLog.CreationTime);None"
                            $aSEEvtLog = $lEvtLogs | where{$_.Name -Match "Archive-Security-"}
                            $aAEvtLog = $lEvtLogs | where{$_.Name -Match "Archive-Application-"}
                            $aSYEvtLog = $lEvtLogs | where{$_.Name -Match "Archive-System-"}
                            if($aSEEvtLog.Count -eq 0){
                                $result +=  "Local-Archive-Security;None;None;None;NO Local Achives Found!"
                                $lEvtLogData += "Local-Archive-Security;None;None;None;NO Local Achives Found!"
                                }
                            else{
                                $null = $aSEEvtLog | %{$result +=  "Local-Archive-Security;$($_.Name);$($_.LastWriteTime);$($_.CreationTime);None"}
                                $null = $aSEEvtLog | %{$lEvtLogData += "Local-Archive-Security;$($_.Name);$($_.LastWriteTime);$($_.CreationTime);None"}
                                }
                            if($aAEvtLog.Count -eq 0){
                                $result += "Local-Archive-Application;None;None;None;NO Local Achives Found!"
                                $lEvtLogData +="Local-Archive-Application;None;None;None;NO Local Achives Found!"                                
                                }
                            else{
                                $null = $aAEvtLog | %{$result +=  "Local-Archive-Application;$($_.Name);$($_.LastWriteTime);$($_.CreationTime);None"}
                                $null = $aAEvtLog | %{$lEvtLogData +=  "Local-Archive-Application;$($_.Name);$($_.LastWriteTime);$($_.CreationTime);None"}
                                }
                            if($aSYEvtLog.Count -eq 0){
                                $result += "Local-Archive-System;None;None;None;NO Local Achives Found!"
                                $lEvtLogData += "Local-Archive-System;None;None;None;NO Local Achives Found!"
                                }
                            else{
                                $null = $aSYEvtLog | %{$result +=  "Local-Archive-System;$($_.Name);$($_.LastWriteTime);$($_.CreationTime);None"}
                                $null = $aSYEvtLog | %{$lEvtLogData +=  "Local-Archive-System;$($_.Name);$($_.LastWriteTime);$($_.CreationTime);None"}
                                }
                            $result +=  "----------------------------------------------------------"
                            $result +=  "Archive Event Logs Path : E:\Data\Elogdump"
                            $result +=  "Date Time : $(Get-Date)"
                            $result +=  'EventLogs from Local Event Log Archive Location'
                            $result +=  "Server FQDN : $compFQDN"
                            $result +=  "----------------------------------------------------------"
                            $result +=  "EventLog;FileName;LastWriteTime;CreationTime;Remarks"
                            $result +=  "----------------------------------------------------------"
                            $lArEvtLogs = gci "\\$compFQDN\E$\Data\Elogdump"
                            ##File Name format in E Drive: AMSDC1-S-40726-Archive-Security-2025-03-07-09-57-16-382.rar
                            $seEvtName = "$ENV:COMPUTERNAME-Archive-Security-"
                            $selArEvt = $lArEvtLogs | where{$_.Name -eq "$seEvtName"} | Sort-Object -Descending
                            if($selArEvt.count -eq 0){
                                $result +=  "Security;None;None;None;NO Local Archives Found!"
                                $laEvtLogData += "Security;None;None;None;NO Local Archives Found!"
                                }
                            else{
                                $null = $selArEvt | %{$result +=  "ELogDump-Security;$($_.Name);$($_.LastWriteTime);$($_.CreationTime);None"}
                                $null = $selArEvt | %{$laEvtLogData += "ELogDump-Security;$($_.Name);$($_.LastWriteTime);$($_.CreationTime);None"}
                                }
                            $aEvtName = "$ENV:COMPUTERNAME-Archive-Application-"
                            $alArEvt = $lArEvtLogs | where{$_.Name -eq "$aEvtName"} | Sort-Object -Descending
                            if($alArEvt.count -eq 0){
                                $result +=  "Application;None;None;None;NO Local Archives Found!"
                                $laEvtLogData += "Application;None;None;None;NO Local Archives Found!"
                                }
                            else{
                                $null = $alArEvt | %{$result +=  "ELogDump-Application;$($_.Name);$($_.LastWriteTime);$($_.CreationTime);None"}
                                $null = $laEvtLogData | %{$result +=  "ELogDump-Application;$($_.Name);$($_.LastWriteTime);$($_.CreationTime);None"}
                                }
                            $syEvtName = "$ENV:COMPUTERNAME-Archive-System-"
                            $sylArEvt = $lArEvtLogs | where{$_.Name -eq "$syEvtName"} | Sort-Object -Descending
                            if($sylArEvt.count -eq 0){
                                $result +=  "System;None;None;None;NO Local Archives Found!"
                                $laEvtLogData += "System;None;None;None;NO Local Archives Found!"
                                }
                            else{
                                $null = $sylArEvt | %{$result +=  "ELogDump-System;$($_.Name);$($_.LastWriteTime);$($_.CreationTime);None"}
                                $null = $sylArEvt | %{$laEvtLogData +=  "ELogDump-System;$($_.Name);$($_.LastWriteTime);$($_.CreationTime);None"}
                                }
                            $result += '----------------------------------------------------------------------------------------------------------------------'
                            $result += "Central Archived Event Log Status:"
                            $result += "Date Time : $(Get-Date)"
                            $result += 'EventLogs from Central Event Log Archive Servers'
                            $result += "Server FQDN : $compFQDN"
                            $result += '----------------------------------------------------------------------------------------------------------------------'
                            $evtLogStatus = ServerLogStatus $compFQDN
                            $null = $evtLogStatus | %{$result += $_}
                            $null = $evtLogStatus | %{$caEvtLogData += $_}
                            $tempObj.Result =  $result
                            $ResultData += $tempObj
                            }
        {($_ -eq "TS.SC-OS.02 Audit policy")} {#Write-Warning "Control: $_"
                            $tempObj = [pscustomobject][ordered]@{
                                            ServerName = $($comp)
                                            OnlineStatus = "ONLINE"
                                            OperatingSystem = "$($svrDetails.OperatingSystem)"
                                            ControlNumber = "TS.SC-OS.02 Audit policy"
                                            Details = "None"
                                            Result = "None"
                                            }
                            $cmdResult = $null
                            $tempObj.Details = @("Account authentication settings / policy")
                            $result = @("Account authentication settings / policy")
                            $result += "Date Time : $(Get-Date)"
                            $result += "Command:"
                            if($Manual){
                                $result += '& cmd /c "$psexec -accepteula -s \\' + $comp + ' C:\Windows\System32\auditpol.exe /get /category:*"'
                                $result += '-------------------------------------------------------------------------------------------------'
                                $cmdResult = & cmd /c "$psexec -accepteula -s \\$comp C:\Windows\System32\auditpol.exe /get /category:*"
                                if($cmdResult -match "PsExec"){
                                    $cmdResult = $cmdResult | select -Skip 4
                                    $cmdResult = $cmdResult | ?{$_}
                                    }
                                $result += $cmdResult
                                $tempObj.Result = $($result)
                                }
                            else{
                                $result += '& cmd /c "C:\Windows\System32\auditpol.exe /get /category:*"'
                                $result += '-------------------------------------------------------------------------------------------------'
                                $result += & cmd /c "C:\Windows\System32\auditpol.exe /get /category:*"
                                $tempObj.Result = $($result)
                                }
                            $ResultData += $tempObj
                            }
        {($_ -eq "TS.SC-OS.03 (DS5.SOA.06) - Test B") -or ($_ -eq "TS.SC-OS.03-B")} {#Write-Warning "Control: $_"
                        $tempObj = [pscustomobject][ordered]@{
                                            ServerName = $($comp)
                                            OnlineStatus = "ONLINE"
                                            OperatingSystem = "$($svrDetails.OperatingSystem)"
                                            ControlNumber = $_
                                            Details = "None"
                                            Result = "None"
                                            }
                        $Details = @($null)
                        $Details += "i. Password policy"
                        $Details += "ii. Account lockout policy"
                        $Details += "iii. Idle time"
                        $tempObj.Details = $Details
                        $rsopResult = @("Password policy, Account lockout policy, Idle time")
                        $rsopResult += "Date Time : $(Get-Date)"
                        $rsopResult += "Command:"
                        if($Manual){
                            $rsopResult += '& cmd /c "$psexec -accepteula -s \\' + $comp + ' C:\Windows\System32\secedit.exe /export /cfg C:\Temp\Secedit.log /areas securitypolicy"'
                            $rsopResult += 'Get-content -Path "\\' + $comp + '\c$\Temp\Secedit.log"'
                            $rsopResult += '-----------------------------------------------------------------------------------------------------------------------------------'
                            $null = & cmd /c "$psexec -accepteula -s \\$comp C:\Windows\System32\secedit.exe /export /cfg C:\Temp\Secedit.log /areas securitypolicy"
                            Start-Sleep 2
                            $cmdOutput = Get-content -Path "\\$comp\c$\Temp\Secedit.log"
                        }
                        else{
                            $rsopResult += '& cmd /c "C:\Windows\System32\secedit.exe /export /cfg C:\Temp\Secedit.log /areas securitypolicy"'
                            $rsopResult += 'Get-content -Path "C:\Temp\Secedit.log"'
                            $rsopResult += '-----------------------------------------------------------------------------------------------------------------------------------'
                            $null = & cmd /c "C:\Windows\System32\secedit.exe /export /cfg C:\Temp\Secedit.log /areas securitypolicy"
                            Start-Sleep 2
                            $cmdOutput = Get-content -Path "C:\Temp\Secedit.log"
                            }
                        $rsopResult += ($cmdOutput -match "MinimumPasswordAge")[0]
                        $rsopResult += ($cmdOutput -match "MaximumPasswordAge")[0]
                        $rsopResult += ($cmdOutput -match "MinimumPasswordLength")[0]
                        $rsopResult += ($cmdOutput -match "PasswordComplexity")[0]
                        $rsopResult += ($cmdOutput -match "PasswordHistorySize")[0]
                        $rsopResult += ($cmdOutput -match "LockoutBadCount")[0]
                        $rsopResult += ($cmdOutput -match "ResetLockoutCount")[0]
                        $rsopResult += ($cmdOutput -match "LockoutDuration")[0]
                        $rsopResult += ($cmdOutput -match "AutoDisconnect")[0]
                        $rsopResult += ($cmdOutput -match "ClearTextPassword")[0]
                        $tempObj.Result = $rsopResult
                        $ResultData += $tempObj
                        }
        {($_ -eq "TS.SC-OS.04 B.2") -or
            ($_ -eq "TS.SC-OS.02 (DS5.SOA.05) - Test C") -or
            ($_ -eq "TS.SC-OS.04 Test B")} 
            {#Write-Warning "Control: $_"
                            $tempObj = [pscustomobject][ordered]@{
                                            ServerName = $($comp)
                                            OnlineStatus = "ONLINE"
                                            OperatingSystem = "$($svrDetails.OperatingSystem)"
                                            ControlNumber = $_
                                            Details = "None"
                                            Result = "None"
                                            }
                            $Details = @($null)
                            $Details += "Default os admin account details (MemberAdmin-A or Osadmin)"
                            $Details += "i.   Account name"
                            $Details += "ii.  Comment"
                            $Details += "iii. Password last set, expires, last logon"
                            $tempObj.Details = $Details
                            $result = @("Default os admin account details:")
                            $result += "Date Time : $(Get-Date)"
                            $result += "Command:"
                            $adminName = $null
                            $members = $([ADSI]"WinNT://$($comp)/Administrators").members()
                            $adminName = $members | ForEach-Object {
                                        $name = $_.GetType().InvokeMember("Name", "GetProperty", $null, $_, $null)
                                        if(("MemberAdmin-A" -Match $name) -or ("osadmin" -match $name)){$name}
                                        }
                            if($Manual -and $adminName){
                                $result += '& cmd /c "$psexec -accepteula -s \\' + $comp + ' net user ' + $adminName +'"'
                                $result += '-------------------------------------------------------------------'
                                $admCMD = & cmd /c "$psexec -accepteula -s \\$comp net user $adminName"
                                if($admCMD -match "PsExec"){
                                    $admCMD = $admCMD | select -Skip 4
                                    $admCMD = $admCMD | ?{$_}
                                    }
                                $result += $admCMD
                                $tempObj.Result = $result
                                }
                            elseif(!($Manual) -and $adminName){
                                $result += '& cmd /c "net user ' + $adminName + '"'
                                $result += '-------------------------------------------------------------------'
                                $admCMD = & cmd /c "net user $adminName"
                                $result += $admCMD
                                $tempObj.Result = $result
                                }
                            else{
                                $result += '& cmd /c "net user ' + $adminName + '"'
                                $result += '-------------------------------------------------------------------'
                                #$admCMD = & cmd /c "net user $adminName"
                                $result += "User Accounts Memberadmin-a or Osadmin Accounts NOT found on the server"
                                $tempObj.Result = $result
                                }
                            $ResultData += $tempObj
                            }
        {($_ -eq "TS.PE-CHM.01 (A.16.SOA.01) - Test B") -or ($_ -eq "TS.PE-CHM.01 B")} {#Write-Warning "Control: $_"
                        $tempObj = [pscustomobject][ordered]@{
                                            ServerName = $($comp)
                                            OnlineStatus = "ONLINE"
                                            OperatingSystem = "$($svrDetails.OperatingSystem)"
                                            ControlNumber = "TS.PE-CHM.01 B"
                                            Details = "None"
                                            Result = "None"
                                            }
                        $Details = @($null)
                        $Details += "i. List of latest installed patches"
                        $Details += "ii. Integrity checks"
                        $tempObj.Details = $Details
                        $result = @("$null")
                        $result += "Date Time : $(Get-Date)"
                        #if(($kbData -ne $null) -and ($cNum -eq "ALL")){$kbData | %{$result += $_ }}
                        if(($kbData -ne $null)){$kbData | %{$result += $_ }}
                        else{
                            $kbDetails = GetKBDetails $comp
                            $kbDetails | %{$result += $_ }
                            }
                        $result += '---------------------------------------------------------------------------------------------'
                        $result += "Integrity checks:"
                        $result += "Date Time : $(Get-Date)"
                        $result += "Command:"
                        if($Manual){
                            $result += '& cmd /c "$psexec -accepteula -s \\ ' + $comp  + ' sfc /verifyFile=C:\Windows\System32\kernel32.dll"'
                            $result += '---------------------------------------------------------------------------------------------'
                            $sfcCMD = & cmd /c "$psexec -accepteula -s \\$comp sfc /verifyFile=C:\Windows\System32\kernel32.dll" | ?{$_.Length -gt 1}
                            if($sfcCMD -match "PsExec"){
                                    $sfcCMD = $sfcCMD | select -Skip 3
                                    $sfcCMD = $sfcCMD | ?{$_}
                                    }
                            $iCheck = ($sfcCMD.ToCharArray() | Where-Object { [int][char]$_ -ne 0 }) -join ''
                            $result += $iCheck
                            $tempObj.Result = $result
                            }
                        else{
                            $result += '& cmd /c "sfc /verifyFile=C:\Windows\System32\kernel32.dll"'
                            $result += '---------------------------------------------------------------------------------------------'
                            $sfcCMD = & cmd /c "sfc /verifyFile=C:\Windows\System32\kernel32.dll" | ?{$_.Length -gt 1}
                            $iCheck = ($sfcCMD.ToCharArray() | Where-Object { [int][char]$_ -ne 0 }) -join ''
                            $result += $iCheck
                            $tempObj.Result = $result
                            }
                        $ResultData += $tempObj
                        }
        {($_ -eq "TS.OP-MON.01 (DS13.SOA.01) - Test B")} {#Write-Warning "Control: $_"
                            $tempObj = [pscustomobject][ordered]@{
                                            ServerName = $($comp)
                                            OnlineStatus = "ONLINE"
                                            OperatingSystem = "$($svrDetails.OperatingSystem)"
                                            ControlNumber = "TS.OP-MON.01 (DS13.SOA.01) - Test B"
                                            Details = "None"
                                            Result = "None"
                                            }
                            $Details = @($null)
                            $Details += "Monitoring Details"
                            $Details += "i.   OVC"
                            $Details += "ii.  OVC List"
                            $tempObj.Details = $Details
                            $result = @("Monitoring Details:")
                            $result += "Date Time : $(Get-Date)"
                            $result += "Command:"
                            if($Manual){
                                $result += '-------------------------------------------------------------------'
                                $result += '& cmd /c "$psexec -accepteula -s \\' + $comp + 'cmd /c ovc '+'"'
                                $result += '-------------------------------------------------------------------'

                                $ovcCMD = & cmd /c "$psexec -accepteula -s \\$comp cmd /c ovc"
                                if($ovcCMD -match "PsExec"){
                                    $ovcCMD = $ovcCMD | select -Skip 4
                                    $ovcCMD = $ovcCMD | ?{$_}
                                    }
                                $result += $ovcCMD
                                $result += '-------------------------------------------------------------------'
                                $result += '& cmd /c "$psexec -accepteula -s \\' + $comp + 'cmd /c ovpolicy -list '+'"'
                                $result += '-------------------------------------------------------------------'
                                $ovpolicyCMD = & cmd /c "$psexec -accepteula -s \\$comp cmd /c ovpolicy -list"
                                if($ovpolicyCMD -match "PsExec"){
                                    $ovpolicyCMD = $ovpolicyCMD | select -Skip 4
                                    $ovpolicyCMD = $ovpolicyCMD | ?{$_}
                                    }
                                $result += $ovpolicyCMD
                                $tempObj.Result = $result
                                }
                            else{

                                $result += '& cmd /c ovc'
                                $result += '-------------------------------------------------------------------'
                                $ovcCMD = & cmd /c "ovc"
                                $result += $ovcCMD
                                $result += '-------------------------------------------------------------------'
                                $result += '& cmd /c ovpolicy -list'
                                $result += '-------------------------------------------------------------------'
                                $ovpolicyCMD = & cmd /c "ovpolicy -list"
                                $result += $ovpolicyCMD
                                $tempObj.Result = $result
                                }
                            $ResultData += $tempObj
                            }
        {($_ -eq "TS.SC-OS.06 Test B")} {#Write-Warning "Control: $_"
                            $tempObj = [pscustomobject][ordered]@{
                                    ServerName = $($comp)
                                    OnlineStatus = "ONLINE"
                                    OperatingSystem = "$($svrDetails.OperatingSystem)"
                                    ControlNumber = "TS.SC-OS.06 Test B"
                                    Details = "None"
                                    Result = "None"
                                    }
                            $compFQDN = $Comp
                            $Details = @("i. Domain Controller connection status")
                            $tempObj.Details = $Details
                            $result = @("Check if the server is joined to a domain:")
                            $result += "Date Time : $(Get-Date)"
                            if($Manual){
                                $result += 'Command: & cmd /c "systeminfo /s \\'+ $compFQDN +'| findstr /B /C:"Domain" & timeout /t 5"'
                                $result += '---------------------------------------------------'
                                $ComputerInfo = & cmd /c "systeminfo /s \\$compFQDN | findstr /B /C:""Domain"" & timeout /t 5"
                                if($ComputerInfo -notmatch "ERROR:") {
                                $DomainName = (($ComputerInfo).Split(":")[1]).Trim()
                                $result += "Domain Membership: $DomainName"
                                $result += '---------------------------------------------------'
                                $result += "Get the current domain controller:"
                                $result += "Date Time : $(Get-Date)"
                                $result += "Command: nltest /SERVER:$compFQDN /dsgetdc:$DomainName"
                                $result += '---------------------------------------------------'
                                $DomainController = & cmd /c "nltest /SERVER:$compFQDN /dsgetdc:$DomainName"
                                $DomainController = $DomainController | ?{$_} | %{$_.Trim()} 
                                $result += "Connected Domain Controller:"
                                $null = $DomainController | %{$result += $_}
                                $result += '---------------------------------------------------'
                                $result += "Checking Secure Channel Verification:"
                                $result += "Date Time : $(Get-Date)"
                                $result += "Command: nltest /SERVER:$compFQDN /sc_verify:$DomainName"
                                $result += '---------------------------------------------------'
                                $SecureChannel = & cmd /c "nltest /SERVER:$compFQDN /sc_verify:$DomainName"
                                $SecureChannel = $SecureChannel | ?{$_} | %{$_.Trim()} 
                                $result += "Secure Channel Details:"
                                $null = $SecureChannel | %{$result += $_}
                                $result += '---------------------------------------------------'
                                $result += "Recent Domain Connectivity Events:"
                                $result += "Date Time : $(Get-Date)"
                                $result += "Command: wevtutil /r:$compFQDN  qe System /q:""*[System[Provider[@Name='Netlogon']]]"" /rd /c:5 /f:xml"
                                $result += '-------------------------------------------------------------------------------------------------------'
                                $result += ("TimeWritten,Source,EventID,EntryType,Message")
                                $result += '-------------------------------------------------------------------------------------------------------'
                                #wevtutil qe System /q:"*[System[Provider[@Name='NETLOGON']]]" /c:5 /f:text /rd:true
                                [xml]$Events = & cmd /c "wevtutil /r:$compFQDN  qe System /q:""*[System[Provider[@Name='Netlogon']]]"" /rd /c:5 /f:xml"
                                $evt = @()
                                if($Events.Event){
                                    foreach ($eventXml in $Events.Event) {
                                        $evt = @()
                                        $evt += "$([DateTime]$eventXml.System.TimeCreated.SystemTime)"
                                        $evt += "$($eventXml.System.Provider.Name)"
                                        $evt += "$($eventXml.System.EventID)"
                                        $evt += "$(($eventXml.EventData.Data | Where-Object {$_}).'#text')"
                                        $result += $evt -join ";"
                                        }
                                    }
                                else {$result += "No recent Netlogon events found."}
                                $result += '--------------------------------------------------------------------------------------------------------'
                                $result += "Checking Last Group Policy Refresh Time:"
                                $result += "Date Time : $(Get-Date)"
                                $result += 'Command:'
                                $result += 'gpresult /S \\' + "$compFQDN" +' /r | findstr "Last time Group Policy was applied"'
                                $result += '---------------------------------------------------------------------------------'
                                $GPResult = gpresult /S \\$compFQDN /r | findstr "Last time Group Policy was applied"
                                if ($GPResult) {$result += $GPResult[1]}
                                else {$result += "Could not determine last Group Policy refresh time."}
                                $result += '---------------------------------------------------------------------------------'
                                }
                                else {$result += "This server is not joined to a domain or Unavailable" }
                            }
                            else{
                                $result += 'Command: Get-WmiObject Win32_ComputerSystem'
                                $result += '---------------------------------------------------'
                                $ComputerInfo = Get-WmiObject Win32_ComputerSystem
                                if ($ComputerInfo.PartOfDomain) {
                                $DomainName = $ComputerInfo.Domain
                                $result += "Domain Membership: $DomainName"
                                $result += '---------------------------------------------------'
                                $result += "Get the current domain controller:"
                                $result += "Date Time : $(Get-Date)"
                                $result += "Command: nltest /dsgetdc:$DomainName"
                                $result += '---------------------------------------------------'
                                $DomainController = nltest /dsgetdc:$DomainName
                                $DomainController = $DomainController | ?{$_} | %{$_.Trim()} 
                                $result += "Connected Domain Controller:"
                                $null = $DomainController | %{$result += $_}
                                $result += '---------------------------------------------------'
                                $result += "Checking Secure Channel Verification:"
                                $result += "Date Time : $(Get-Date)"
                                $result += "Command: nltest /sc_verify:$DomainName"
                                $result += '---------------------------------------------------'
                                $SecureChannel = nltest /sc_verify:$DomainName
                                $SecureChannel = $SecureChannel | ?{$_} | %{$_.Trim()} 
                                $result += "Secure Channel Details:"
                                $null = $SecureChannel | %{$result += $_}
                                $result += '---------------------------------------------------'
                                $result += "Recent Domain Connectivity Events:"
                                $result += "Date Time : $(Get-Date)"
                                $result += "Command: Get-EventLog -LogName System -Source NETLOGON -Newest 10"
                                $result += '-------------------------------------------------------------------'
                                $Events = Get-EventLog -LogName System -Source NETLOGON -Newest 10 | `
                                            ForEach-Object {
                                                "$($_.TimeGenerated) - $($_.EntryType): $($_.Message)"
                                                }
                                if ($Events) {$Events | ForEach-Object { $result += $_ }}
                                else {$result += "No recent Netlogon events found."}
                                $result += '-------------------------------------------------------------------'
                                $result += "Checking Last Group Policy Refresh Time:"
                                $result += "Date Time : $(Get-Date)"
                                $result += 'Command:'
                                $result += 'gpresult /r | Select-String "Last time Group Policy was applied"'
                                $result += '---------------------------------------------------'
                                $GPResult = gpresult /r | Select-String "Last time Group Policy was applied"
                                if ($GPResult) {$result += $GPResult}
                                else {$result += "Could not determine last Group Policy refresh time."}
                                $result += '---------------------------------------------------'
                                }
                                else {$result += "This server is not joined to a domain." }
                                }
                            $tempObj.Result =  $result
                            $ResultData += $tempObj
                            }
        {($_ -eq "TS.SC-OS.06 Test C")} {#Write-Warning "Control: $_"
                    $tempObj = [pscustomobject][ordered]@{
                                    ServerName = $($comp)
                                    OnlineStatus = "ONLINE"
                                    OperatingSystem = "$($svrDetails.OperatingSystem)"
                                    ControlNumber = "TS.SC-OS.06 Test C"
                                    Details = "None"
                                    Result = "None"
                                    }
                    $tHead = @"
                    <table>
                    <thead><tr>
                    <th>UserName</th>
                    <th>Enabled</th>
                    <th>InAdminGroup</th>
                    <th>InRDPGroup</th>
                    <th>RDP_Access</th>
                    <th>InteractiveLogon</th></tr>
                    </thead>
                    <tbody>
"@
                    $ExcludedUsers = @("osadmin", "memberadmin-a","WDAGUtilityAccount")
                    $ExcludedUserPatterns = @("-S", "-X", "-B", "-A")  # Exclude usernames ending with these
                    $ExcludedGroupPatterns = @("FGR","FGS","fSys") # Exclude groups starting with these
                    $compFQDN = $Comp
                    $Details = @("i. Local Accounts RDP is disabled")
                    $Details += "ii. Local Accounts Interactive Logon is disabled"
                    $tempObj.Details = $Details
                    $result = @("Local Accounts with RDP and Interactive Logon Status")
                    $result += "Date Time : $(Get-Date)"
                    if($Manual){
                        $result += 'Command: [ADSI]"WinNT://' + $compFQDN + '").Children'
                        $result += "$tHead"
                        #$result += '----------------------------------------------------------------------------'
                        #$result += "UserName,Enabled,InAdminGroup,InRDPGroup,RDP_Access,InteractiveLogon"
                        #$result += '----------------------------------------------------------------------------'
                        $userSIDHash = @{}
                        $userStatusHash = @{}
                        [ADSI]$lADSI = "WinNT://$compFQDN"
                        $LocalAccounts = $null
                        $lacctStatus = $null
                        $ADS_UF_ACCOUNTDISABLE = 0x0002
                        #$LocalAccounts = ($lADSI.Children | Where-Object { $_.SchemaClassName -eq "User" })
                        $LocalAccounts = ($lADSI.Children |
                                            Where-Object {
                                                $eUser = $_.psbase.properties.name.value
                                                $_.SchemaClassName -eq "User" -and 
                                                ($ExcludedUsers -notcontains $eUser)# -and `
                                                #($ExcludedUserPatterns | ForEach-Object {$eUser -Match ".*\$_$" })
                                                })
                        $null = $LocalAccounts | %{$_.psbase.properties.name.value}
                        if($LocalAccounts){
                            $LocalAccounts | 
                                Foreach{
                                    $lUname = $_.psbase.properties.name.value
                                    $enabled = if($_.psbase.properties.item("userflags").value -band $ADS_UF_ACCOUNTDISABLE) {$False}`
                                               else{$True}
                                    $userStatusHash.Add($lUname,$enabled)
                                    }
                            $(($LocalAccounts | Select Name).Name) |
                                Foreach{
                                    $uSID = & cmd /c "wmic /node:""$compFQDN"" useraccount where name=""$($_)"" get SID /format:value" | ?{$_}
                                    $userSIDHash.Add($uSID.Split('=')[-1],$_)
                                }
                            $lAdmingroup =[ADSI]"WinNT://$compFQDN/Administrators,group"
                            $adminMembers = @($lAdmingroup.Invoke("Members")) |
                                            ForEach {$_.GetType().InvokeMember("Name", "GetProperty", $null, $_, $null)}
                            #Write-Output "Admin group"
                            #$adminMembers
                            $lRDPgroup =[ADSI]"WinNT://$compFQDN/Remote Desktop Users,group"
                            $rdpMembers = @($lRDPgroup.Invoke("Members")) |
                                            ForEach {$_.GetType().InvokeMember("Name", "GetProperty", $null, $_, $null)}
                            $null = & cmd /c "$psexec -accepteula -s \\$compFQDN C:\Windows\System32\secedit.exe /export /areas USER_RIGHTS /cfg C:\Temp\UserRights.inf"
                            Start-Sleep 2
                            $UserRightsFile = Get-content -Path "\\$compFQDN\c$\Temp\UserRights.inf"
                            # Extract and convert logon rights policies
                            $RDPUsers = ($UserRightsFile | Where-Object { $_ -match "SeRemoteInteractiveLogonRight" }) -replace ".*=","" -split "," | 
                                            ForEach-Object { if($userSIDHash.ContainsKey($_.Trim())){$userSIDHash[$_.Trim()]}
                                                }
                            $InteractiveLogonUsers = ($UserRightsFile | Where-Object { $_ -match "SeInteractiveLogonRight" }) -replace ".*=","" -split "," | 
                                            ForEach-Object { if($userSIDHash.ContainsKey($_.Trim())){$userSIDHash[$_.Trim()]}}
                            #$LocalAccounts 
                            $null = $LocalAccounts | Select Name | 
                                ForEach-Object {
                                    $Username = $_.Name
                                    $uStatus = if($userStatusHash.ContainsKey($Username)){$userStatusHash[$Username]}else{"StatusUnknown"}
                                    $InAdminGroup = if($adminMembers -contains $Username){$True}else{$False}
                                    $InRDPGroup = if($rdpMembers -contains $Username){$True}else{$False}
                                    # Set RDP and Interactive Logon access based on group membership or explicit policy
                                    $RDPAccess = ($RDPUsers -contains $Username) -or $InAdminGroup -or $InRDPGroup
                                    $InteractiveLogonAccess = ($InteractiveLogonUsers -contains $Username) -or $InAdminGroup -or $InRDPGroup
                                    $inAdmGrp = if ($InAdminGroup) { "Yes" } else { "No" }
                                    $inRDPGrp = if ($InRDPGroup) { "Yes" } else { "No" }
                                    $rdpAccess = if ($RDPAccess) { "Yes" } else { "No" }
                                    $intrLogin = if ($InteractiveLogonAccess) { "Yes" } else { "No" }
                                    $result += "<tr><td>$Username</td><td>$uStatus</td><td>$inAdmGrp</td><td>$inRDPGrp</td><td>$rdpAccess</td><td>$intrLogin</td></tr>"
                                    }
                            }##IF END
                        else{$result += '<td colspan="6">Local User Accounts Empty/Not Found</td>'}
                        }
                    else{
                        $result += 'Command:'
                        $result += "secedit /export /areas USER_RIGHTS /cfg $env:TEMP\UserRights.inf"
                        $result += "$tHead"
                        $fLocalUsers = @()
                        $usrList = @()
                        $RDPUsers = @()
                        $InteractiveLogonUsers = @()
                        $userStatusHash = @{}
                        # Get local users, excluding specific ones
                        $LocalUsers = Get-WmiObject -Query "SELECT * FROM Win32_UserAccount WHERE LocalAccount=true"
                        #Write-Warning "$(($LocalUsers | Select Name).Name)"
                        if($LocalUsers){
                            Foreach($lUser in $LocalUsers) {
                                $fLocalUsers += if(($luser.Name -notin $ExcludedUsers)){`
                                                    $luser.Name; `
                                                    if($luser.Disabled -eq $true){$userStatusHash.Add($luser.Name,$false)}
                                                    else{$userStatusHash.Add($luser.Name,$true)}
                                                    }
                                #$ePattern = $($ExcludedUserPatterns | ForEach-Object {$eUser -Match ".*\$_$" })
                                #if($eUser -and !($ePattern)){$fLocalUsers += $lUser}
                                #if($eUser){$fLocalUsers += $lUser}
                                }
                            #Write-Warning "FLocal Users: $($fLocalUsers)"
                            if($fLocalUsers){
                                $SecEditPath = "$env:TEMP\UserRights.inf"
                                $null = & cmd /c "secedit /export /areas USER_RIGHTS /cfg $SecEditPath"
                                $UserRightsFile = Get-Content $SecEditPath
                                # Extract and convert logon rights policies
                                $rdpSID = $UserRightsFile | Where-Object { $_ -match "SeRemoteInteractiveLogonRight" }
                                $rdpSID = $rdpSID -split "\*" | %{$_ -replace ",",""} | select -Skip 1
                                $RDPUsers = $rdpSID | ForEach-Object { #Convert-SIDToUser $_.Trim()
                                                    #Write-Warning "SID: $($_.Trim())"
                                                    if($_.Length -le 15){
                                                        $objSID = New-Object System.Security.Principal.SecurityIdentifier($_.Trim())
                                                        $objUser = $objSID.Translate([System.Security.Principal.NTAccount])
                                                        $objUser.Value.Split("\")[-1]  # Get only the username
                                                        }
                                                    else{GetDomainUserSID $_}
                                                    }
                                $intrLoginSID = ($UserRightsFile | Where-Object { $_ -match "SeInteractiveLogonRight" })
                                $intrLoginSID = $intrLoginSID -split "\*" | %{$_ -replace ",",""} | select -Skip 1
                                $InteractiveLogonUsers = $intrLoginSID | ForEach-Object { #Convert-SIDToUser $_.Trim()
                                                        if($_.Length -le 15){
                                                            $objSID = New-Object System.Security.Principal.SecurityIdentifier($_.Trim()) -ErrorAction SilentlyContinue
                                                            $objUser = $objSID.Translate([System.Security.Principal.NTAccount])
                                                            $objUser.Value.Split("\")[-1]  # Get only the username
                                                            }
                                                        else{GetDomainUserSID $_}
                                                        }
                                $admnGRP = Get-LocalGroupMember -Group "Administrators" | Select-Object -ExpandProperty Name
                                $rdpGRP = Get-LocalGroupMember -Group "Remote Desktop Users" | Select-Object -ExpandProperty Name
                                $null = $fLocalUsers | `
                                        ForEach-Object {
                                            $Username = $_
                                            #Write-Warning "$($_.Name)"
                                            $uStatus = if($userStatusHash.ContainsKey($Username)){$userStatusHash[$Username]}else{"StatusUnknown"}
                                            $InAdminGroup = if($admnGRP -contains $Username){$True}else{$False}
                                            $InRDPGroup = if($rdpGRP -contains $Username){$True}else{$False}
                                            # Set RDP and Interactive Logon access based on group membership or explicit policy
                                            $RDPAccess = ($RDPUsers -contains $Username) -or $InAdminGroup -or $InRDPGroup
                                            $InteractiveLogonAccess = ($InteractiveLogonUsers -contains $Username) -or $InAdminGroup -or $InRDPGroup
                                            $inAdmGrp = if ($InAdminGroup) { "Yes" } else { "No" }
                                            $inRDPGrp = if ($InRDPGroup) { "Yes" } else { "No" }
                                            $rdpAccess = if ($RDPAccess) { "Yes" } else { "No" }
                                            $intrLogin = if ($InteractiveLogonAccess) { "Yes" } else { "No" }
                                            $result += "<tr><td>$Username</td><td>$uStatus</td><td>$inAdmGrp</td><td>$inRDPGrp</td><td>$rdpAccess</td><td>$intrLogin</td></tr>"
                                            }
                                }
                            else{$result += '<td colspan="6">Local User Accounts Empty/Not Found</td>'}
                            }
                        else{$result += '<td colspan="6">Local User Accounts Empty/Not Found</td>'}
                        }#Else END
$tbody = @"
</tbody></table>
"@
                    $result += $tbody
                    $tempObj.Result =  $result
                    $ResultData += $tempObj
                    }
        {($_ -eq "TS.SC-LOG.01 (DS13.SOA.02) - Test B")} {#Write-Warning "Control: $_"
                    $tempObj = [pscustomobject][ordered]@{
                                    ServerName = $($comp)
                                    OnlineStatus = "ONLINE"
                                    OperatingSystem = "$($svrDetails.OperatingSystem)"
                                    ControlNumber = "TS.SC-LOG.01 (DS13.SOA.02) - Test B"
                                    Details = "None"
                                    Result = "None"
                                    }                    
                    $compFQDN = "$($svrDetails.FQDN)"
                    $Details = @("i. Local Event Log Status")
                    $Details += "ii. Local Archive Event Log Status"
                    $Details += "iii. Central Archive Event Log  Status"
                    $tempObj.Details = $Details
                    $result = @('Local Log Status:"%SystemRoot%\System32\winevt\Logs"')
                    #Getting Event Logs Availablity Status
                    $result += "Date Time : $(Get-Date)"
                    $result += "Server FQDN : $compFQDN"
                    $result += 'Command:'
                    $result += 'gci "\\' + $compFQDN + '\C$\Windows\System32\winevt\Logs"'
                    $result += '--------------------------------------------------------------------------'
                    $result +=  "EventLog;FileName;LastWriteTime;CreationTime;Remarks"
                    $result +=  "----------------------------------------------------------"
                    $result +=  $lEvtLogData
                    #Getting Archive Event Logs Path : E:\Data\Elogdump
                    $result +=  "----------------------------------------------------------"
                    $result +=  "Archive Event Logs Path : E:\Data\Elogdump"
                    $result +=  "Date Time : $(Get-Date)"
                    $result +=  'EventLogs from Local Event Log Archive Location'
                    $result +=  "Server FQDN : $compFQDN"
                    $result += 'Command:'
                    $result += 'gci "\\' + $compFQDN + '\E$\Data\Elogdump"'
                    $result +=  "----------------------------------------------------------"
                    $result +=  "EventLog;FileName;LastWriteTime;CreationTime;Remarks"
                    $result +=  "----------------------------------------------------------"
                    $result +=  $laEvtLogData
                    $result += '----------------------------------------------------------------------------------------------------------------------'
                    $result += "Central Archived Event Log Status:"
                    $result += "Date Time : $(Get-Date)"
                    $result += 'EventLogs from Central Event Log Archive Servers'
                    $result += "Server FQDN : $compFQDN"
                    $result += '----------------------------------------------------------------------------------------------------------------------'
                    $result +=  $caEvtLogData
                    $tempObj.Result =  $result
                    $ResultData += $tempObj
                    }
        {($_ -eq "TS.OS-MON.03 B")} {
                            $tempObj = [pscustomobject][ordered]@{
                                            ServerName = $($comp)
                                            OnlineStatus = "ONLINE"
                                            OperatingSystem = "$($svrDetails.OperatingSystem)"
                                            ControlNumber = "TS.OS-MON.03 B"
                                            Details = "None"
                                            Result = "None"
                                            }
                            $tempObj.Details = @("i. NTP Settings")
                            $tempObj.Details += "ii. NTP Service Status"
                            if($Manual){
                                $cmdResult = $null
                                $result = @("NTP Settings")
                                $result += "Date Time : $(Get-Date)"
                                $result += "Command:"
                                $result += '& cmd /c "$psexec -accepteula -s \\' + $comp + 'w32tm /query /peers'
                                $result += '-------------------------------------------------------------------------------------------------'
                                $cmdResult = & cmd /c "$psexec -accepteula -s \\$comp w32tm /query /peers"
                                if($cmdResult -match "PsExec"){
                                    $cmdResult = $cmdResult | select -Skip 4
                                    $cmdResult = $cmdResult | ?{$_}
                                    }
                                $result += $cmdResult
                                #sc query w32time
                                $result += "NTP Service Status"
                                $result += "Date Time : $(Get-Date)"
                                $result += "Command:"
                                $result += '& cmd /c "$psexec -accepteula -s \\' + $comp + 'sc query w32time'
                                $result += '-------------------------------------------------------------------------------------------------'
                                $cmdResult = & cmd /c "$psexec -accepteula -s \\$comp sc query w32time"
                                if($cmdResult -match "PsExec"){
                                    $cmdResult = $cmdResult | select -Skip 4
                                    $cmdResult = $cmdResult | ?{$_}
                                    }
                                $result += $cmdResult
                                $tempObj.Result = $($result)
                                }
                            else{
                                    $result = @("NTP Settings")
                                    $result += "Date Time : $(Get-Date)"
                                    $result += "Command:"
                                    $result += '& cmd /c "w32tm /query /peers'
                                    $result += '-------------------------------------------------------------------------------------------------'
                                    $result += & cmd /c "w32tm /query /peers"
                                    $result += "NTP Service Status"
                                    $result += "Date Time : $(Get-Date)"
                                    $result += "Command:"
                                    $result += '& cmd /c "sc query w32time'
                                    $result += '-------------------------------------------------------------------------------------------------'
                                    $result += & cmd /c "sc query w32time"
                                    $tempObj.Result = $($result)
                                    }
                            $ResultData += $tempObj
                            }
        {($_ -eq "TS.SC-UAM.22 B")} {#Write-Warning "Control: $_"
                            $tempObj = [pscustomobject][ordered]@{
                                            ServerName = $($comp)
                                            OnlineStatus = "ONLINE"
                                            OperatingSystem = "$($svrDetails.OperatingSystem)"
                                            ControlNumber = "TS.SC-UAM.22 B"
                                            Details = "None"
                                            Result = "None"
                                            }
                            $cmdResult = $null
                            $tempObj.Details = @("List of Local Administrator Users and Groups")
                            $result = @("List of Local Administrator Users and Groups")
                            $result += "Date Time : $(Get-Date)"
                            $result += "Command:"
                            if($Manual){
                                $result += '& cmd /c "$psexec -accepteula -s \\' + $comp + ' NET LOCALGROUP Administrators'
                                $result += '-------------------------------------------------------------------------------------------------'
                                $cmdResult = & cmd /c "$psexec -accepteula -s \\$comp NET LOCALGROUP Administrators"
                                if($cmdResult -match "PsExec"){
                                    $cmdResult = $cmdResult | select -Skip 4
                                    $cmdResult = $cmdResult | ?{$_}
                                    }
                                $result += $cmdResult
                                $tempObj.Result = $($result)
                                }
                            else{
                                $result += '& cmd /c "NET LOCALGROUP Administrators'
                                $result += '-------------------------------------------------------------------------------------------------'
                                $result += & cmd /c "NET LOCALGROUP Administrators"
                                $tempObj.Result = $($result)
                                }
                            $ResultData += $tempObj
                            }
        }
    $ResultData
    }
if($bulk){
	$svrList = Get-Content ($ScriptDir+"Server.txt")
    if($svrList.Length -eq 0){
        Write-Output "Server List Empty. try Again"
        Exit 1
        }
    }
elseif($ServerList -match ","){
    $svrList = $ServerList -split (",")
    If($svrList.Count -eq 0){
        Write-Output "Server List Empty, Run the script with the correct Server List and try again."
        Exit 1
        }
    }
elseIf($ServerList -match "_"){
    $svrList = $ServerList -split ("_")
    If($ServerList.Count -eq 0){
        Write-Output "Server List Empty, Run the script with the correct Server List and try again."
        Exit 1
        }
    }
else{
    Write-Output 'Server List not in correct format, Try with the correct format "Servername1,Servername2,servernname3.."'
    Exit 1
    }
$svrList = $svrList |  ? { $_ } | sort-object -Unique
If($svrList.Count -eq 0){
	Write-Output "Server List Empty, Run the script switgh the correct Server List and try again."
	Exit 1
	}
if(!(Test-Path -Path ($ScriptDir+"Output"))){
	New-Item -Path ($ScriptDir) -Name "Output" -ItemType Directory | out-null
    }
$cDT = Get-Date -Format "yyyyMMdd_HHmmss"
$evtKeyHash = @{}
$evtKeyHash.Add('0x8020000000000000',"Audit Success")
$evtKeyHash.Add('0x8010000000000000',"Audit Failure")
$htmlOutputFile = $ScriptDir + "Output\$($ENV:USERNAME)-Wintel_Audit_Evidence_Report-$cDT.html"
$HashFile = $ScriptDir + "Output\$($ENV:USERNAME)-Wintel_Audit_Evidence_Report-$cDT.txt"
$ServerErrorFile = $ScriptDir + "Output\$($ENV:USERNAME)-Wintel_Audit_Evidence_Report_Errors-$cDT.log"
$zipDir = $ScriptDir + "Output\$($ENV:USERNAME)-Wintel_Audit_Evidence_Report_$cDT"
$zipFile =  $ScriptDir + "Output\$($ENV:USERNAME)-Wintel_Audit_Evidence_Report_$cDT.zip"
Write-Output "ServerName : LogType : Message"  | Out-File -FilePath $ServerErrorFile -Force -Append
$svrDataList = @()
$selectAll = $false
Foreach($Server in $svrList){
    $svrData = [pscustomobject][ordered]@{
        ServerName = $($Server)
        OnlineStatus = "OFFLINE"
        OperatingSystem = "None"
        ControlNumber = "None"
        Details = "None"
        Result = "None"
        }
    if(!(Test-Connection $Server -Quiet -Count 1)){
        $svrData.Result = "Server Not Reachable"
        $svrDataList += $svrData
        }
    else{
        if($ctrlNum -eq "ALL"){
            $selectAll = $true
            $ctrlOption = ("TS.PE-PAT.01 B2",
                "TS.PE-PAT.01 E",
                "TS.PE-SACM.01 C",
                "TS.SC-OS.02 - B",
                "TS.SC-OS.02 Audit policy",
                "TS.SC-OS.03-B",
                "TS.SC-OS.02 (DS5.SOA.05) - Test C",
                "TS.SC-OS.06 Test B",
                "TS.SC-OS.06 Test C",
                "TS.PE-CHM.01 B",
                "TS.OP-MON.01 (DS13.SOA.01) - Test B",
                "TS.SC-LOG.01 (DS13.SOA.02) - Test B",
                "TS.OS-MON.03 B",
                "TS.SC-UAM.22 B")
                }
        else{$ctrlOption = $ctrlNum}
        $testCaseResult = GetControlNum $ctrlOption $Server $Manual $selectAll
        $svrDataList += $testCaseResult
        }
    }
$auditULData = @()
#Write-output $svrDataList  ## Donot Remove Remove for testing Purpose only
Foreach($repData in $svrDataList){
    $hrData = @()
    Foreach($dList in $repData.Details){$hDetails = $dList -join "<br>" }
    $hDetails = $($repData.Details) -join "<br><br>"
    $hResultType = ($repData.Result).GetType().BaseType.Name
    if($hResultType -eq "Array"){
        $hResult = $($repData.Result) | ?{$_}
        Foreach($rData in $hResult){
            if($rData -match "<"){$hrData += $rData}
            else{$hrData += $rData + "<br>"}
            }
        $hResult = $hrData
        }
    else{$hResult = $($repData.Result)}
    $htmlData = @"
    <tr>
        <td class="ControlNumber">$($repData.ControlNumber)</td>
        <td class="ServerName">$($repData.ServerName)</td>
        <td>$($repData.ONLINESTATUS)</td>
        <td class="OperatingSystem">$($repData.OperatingSystem)</td>
        <td>$hDetails</td>
        <td>$hResult</td>
    </tr>
"@

    $auditULData += $htmlData
}
If($Manual){
    $header = @"
        <style>
            h1 {
                font-family: Arial, Helvetica, sans-serif;
                background-color: #E20074;
                color: white;
                font-size: 28px;
                text-align: center;
                }
            h2 {
                font-family: Arial, Helvetica, sans-serif;
                color: #000099;
                font-size: 24px;
                }
           table {
		        font-size: 12px;
		        border: 0px;
		        font-family: Arial, Helvetica, sans-serif;
	            }
            td {
		        padding: 4px;
		        margin: 0px;
		        border: 0;
                white-space:nowrap;
	            }
            th {
                background: #E20074;
                background: linear-gradient(#E20074, #E20074);
                color: #fff;
                font-size: 10px;
                text-transform: uppercase;
                padding: 10px 15px;
                vertical-align: middle;
                font-weight: bold;
	            }
            tbody tr:nth-child(even) {
                background: #f0f0f2;
                }
            #CreationDate {
                font-family: Arial, Helvetica, sans-serif;
                background-color: #E20074;
                color: white;
                font-size: 16px;
                text-align: right;
                }
            * {
              box-sizing: border-box;
            }
            #myInput {
              background-image: url('/css/searchicon.png');
              background-position: 10px 12px;
              background-repeat: no-repeat;
              width: 100%;
              font-size: 16px;
              padding: 12px 20px 12px 40px;
              border: 1px solid #ddd;
              margin-bottom: 12px;
            }
            .divTable {
				display: table;
			}
			.divTableFlex {
				display: flex;
			}
			.divColumnHeader {
				background: linear-gradient(#E20074, #E20074);
				margin-bottom: 1em;
				font-weight: bold;
				color: #fff;			
			}
			.divRow {
				border: 1px white solid;
				height: 2em;
				margin: auto;
			}
			.Heading
			{
				display: table-row;
				font-weight: bold;
				text-align: center;
			}
			.Row
			{
				display: table-row;
			}
			.divCellHeader {
				background: linear-gradient(#E20074, #E20074);
				margin-bottom: 1em;
				font-weight: bold;
				color: #fff;
				display: table-cell;				
			}
			.Cell
			{
				display: table-cell;
			}
			.divRowSpan
			{
				background: #f0f0f2;
				color: black;
			}
            .divColSpan
			{
				background: #f0f0f2;
				color: black;
			}
        </style>

"@
    $bodyStart = @"
       <h1> Wintel Audit Evidence Report $(Get-Date -f 'MM-dd-yyyy HH:mm:ss')</h1><br>
        <br>
        <table id="myTable">
        <thead>
            <tr>
                <th>
                    <input type="text" id="myInputCN" onkeyup="myFunctionCN()" placeholder="Search for Control Number...">
                </th>
                <th>
                    <input type="text" id="myInputSN" onkeyup="myFunctionSN()" placeholder="Search for Server Names...">
                </th>
                <th>
                    <input type="text" id="myInputON" onkeyup="myFunctionON()" placeholder="Search for Online Status...">
                </th>
                <th>
                    <input type="text" id="myInputOS" onkeyup="myFunctionOS()" placeholder="Search for Operating System...">
                </th>
            </tr>
            <tr>
            <th>Control Number</th>
            <th>Server Name</th>
            <th>Online Status</th>
            <th>Operating System</th>
            <th>Details</th>
            <th>Result</th>
            </tr>
        </thead>
        <tbody>
"@
    $bodyEnd = @"
    </tbody>
    </table>
    <script>
        function myFunctionCN() {
          // Declare variables
          var input, filter, table, tr, td, i, txtValue;
          input = document.getElementById("myInputCN");
          filter = input.value.toUpperCase();
          table = document.getElementById("myTable");
          tr = table.getElementsByTagName("tr");

          // Loop through all table rows, and hide those who don't match the search query
          for (i = 0; i < tr.length; i++) {
            td = tr[i].getElementsByTagName("td")[0];
            if (td) {
              txtValue = td.textContent || td.innerText;
              if (txtValue.toUpperCase().indexOf(filter) > -1) {
                tr[i].style.display = "";
              } else {
                tr[i].style.display = "none";
              }
            }
          }
        }
        function myFunctionSN() {
          // Declare variables
          var input, filter, table, tr, td, i, txtValue;
          input = document.getElementById("myInputSN");
          filter = input.value.toUpperCase();
          table = document.getElementById("myTable");
          tr = table.getElementsByTagName("tr");

          // Loop through all table rows, and hide those who don't match the search query
          for (i = 0; i < tr.length; i++) {
            td = tr[i].getElementsByTagName("td")[1];
            if (td) {
              txtValue = td.textContent || td.innerText;
              if (txtValue.toUpperCase().indexOf(filter) > -1) {
                tr[i].style.display = "";
              } else {
                tr[i].style.display = "none";
              }
            }
          }
        }
        function myFunctionON() {
          // Declare variables
          var input, filter, table, tr, td, i, txtValue;
          input = document.getElementById("myInputON");
          filter = input.value.toUpperCase();
          table = document.getElementById("myTable");
          tr = table.getElementsByTagName("tr");

          // Loop through all table rows, and hide those who don't match the search query
          for (i = 0; i < tr.length; i++) {
            td = tr[i].getElementsByTagName("td")[2];
            if (td) {
              txtValue = td.textContent || td.innerText;
              if (txtValue.toUpperCase().indexOf(filter) > -1) {
                tr[i].style.display = "";
              } else {
                tr[i].style.display = "none";
              }
            }
          }
        }
        function myFunctionOS() {
          // Declare variables
          var input, filter, table, tr, td, i, txtValue;
          input = document.getElementById("myInputOS");
          filter = input.value.toUpperCase();
          table = document.getElementById("myTable");
          tr = table.getElementsByTagName("tr");

          // Loop through all table rows, and hide those who don't match the search query
          for (i = 0; i < tr.length; i++) {
            td = tr[i].getElementsByTagName("td")[3];
            if (td) {
              txtValue = td.textContent || td.innerText;
              if (txtValue.toUpperCase().indexOf(filter) > -1) {
                tr[i].style.display = "";
              } else {
                tr[i].style.display = "none";
              }
            }
          }
        }
    </script>

"@
    $body = $bodyStart + "`n" + $auditULData + "`n" + $bodyEnd
    #Write-Output "Creating HTMl File.."
    $Report = ConvertTo-HTML -Body "$body" -Title "Wintel Audit Evidence Report" -Head $header -PostContent "<p id='CreationDate'>Script : Wintel_Audit_Evidence_Report_v1.06.ps1 &nbsp&nbsp&nbsp&nbsp&nbsp Creation Date: $(Get-Date)<p>"
    $Report | Out-File $htmlOutputFile
    #Write-Output "Output HTML : $htmlOutputFile"

    #Hash and send email

    "{0},{1}" -f "HTML Report Generated on",$(Get-Date) | add-content -path $HashFile -Force
    $hashAlgorithm = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = [System.IO.File]::ReadAllBytes($htmlOutputFile)
    $hashValue = [BitConverter]::ToString($hashAlgorithm.ComputeHash($hashBytes)) -replace '-', ''
    "$htmlOutputFile : $hashValue" | add-content -path $HashFile -Force
    If(!(Test-Path $zipDir)){
        New-Item -ItemType Directory -Path $zipDir -Force | Out-Null
        if(Test-Path $htmlOutputFile){Copy-Item $htmlOutputFile -Destination $zipDir}
        if(Test-Path $HashFile){Copy-Item $HashFile -Destination $zipDir}
        if(Test-Path $ServerErrorFile){Copy-Item $ServerErrorFile -Destination $zipDir}
        }
    Add-Type -assembly "system.io.compression.filesystem"
    [io.compression.zipfile]::CreateFromDirectory($zipDir, $zipFile)
    Write-Output "HTML File Hash Value: $hashValue"
    Write-Output "HTML File : $htmlOutputFile"
    Write-Output "ZIP File : $zipFile"
    #Send Email
    $bodydata = "WINTEL - Audit Evidence Report : $cDT `n" +`
                    $htmlOutputFile + "`n" +`
                    $zipFile + "`n" +`
                    $hashValue + "`n" + `
				    "Servers List: `n" + `
				    $($svrList -join "`n")
    Send-MailMessage -From $from -To $toList -Cc $ccList -Body $($bodydata) -SmtpServer $SMTP -Port $port -Subject "WINTEL - Audit Evidence Report : $cDT" -Attachments $zipFile
   #Send-MailMessage -From $from -To $toList -Cc $ccList -Body $($bodydata) -SmtpServer $SMTP -Port $port -Subject "WINTEL - Audit Evidence Report : $cDT" -Attachments $zipFile
    Write-Output "Script Completed:$(Get-Date -f 'yyyyMmdd_HHmmss')"# | Out-File $LogFile -Append
    }
Else{$auditULData}