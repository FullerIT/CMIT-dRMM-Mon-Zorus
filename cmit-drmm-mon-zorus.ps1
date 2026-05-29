<# Mon-ZorusAgent.ps1
pellis@cmitsolutions.com
2026-02-10-001

Zorus Archon Agent Endpoint Monitor
Changelog: Fixed things, typo and status field. Adapted to dRMM better.

#>


# Monitor Options
$AlertOnUserDisable=$true # Default
$AlertOnServiceMissing=$true # Default
$AlertOnUserDisable=$Env:AlertOnUserDisable
$AlertOnServiceMissing=$Env:AlertOnServiceMissing

# Set default states
$alert=$false
$status="OK"

# Zorus Registry Key Paths
$ZorusRegKeyPath="HKLM:\SOFTWARE\Zorus Inc."
$AgentRegKeyPath="HKLM:\SOFTWARE\Zorus Inc.\Archon Agent"
$AgentInfoRegKeyPath="HKLM:\SOFTWARE\Zorus Inc.\Archon Agent\AgentInfo"
$AgentReg=(Get-ItemProperty -path $AgentRegKeyPath -ErrorAction SilentlyContinue)
$AgentInfoReg=(Get-ItemProperty -path $AgentInfoRegKeyPath -ErrorAction SilentlyContinue)

# Required formatting for Datto RMM monitor component
write-host "<-Start Diagnostic->"

# Check that the service is present on the machine.
$ZorusService=Get-Service -Name ZorusDeploymentService -ErrorAction SilentlyContinue
if ($null -eq $ZorusService){
    write-host "- Zorus service is not present. Software does not appear to be installed."
    $Status="Not installed"
    if ($AlertOnServiceMissing -eq $true){
        $alert=$true
    }
} else {
    # Only run additional checks if the service is present.
    if ($ZorusService.Status -ne "Running"){
        write-host "! Zorus service is present, but not running."
        $Status="Service not running"
        $alert=$true
        $skipchecks=$true
    }
    else {
        write-host "- Zorus service is present and running."
    }

    
    if (!($alert)){
        if (!(Test-Path $AgentRegKeyPath)){
            # Early versions of the Archon Agent did not create the "Archon Agent" key until after software was installed 
            # and the agent sucessfully checked-in to the platform. Essentially, the software would install, but not be connected
            # to the Zorus platform. This left the agent in an invalid state with no real indicators.
            # Current versions of the agent will not install if platform check-in does not occur. This is a legacy agent check.
            write-host "! Zorus registry key, $AgentRegKeyPath, does not exist."
            write-host "  This issue is present on older agent installs where the agent was deployed with an invalid token. Current versions"
            write-host "  of the Zorus Archon Agent will fail the install process if the token is not valid or the agent cannot connect to the platform."
            $status="Not connected"
            $alert=$true
        }
    }

    if (!($alert)) {
        # Check if agent has valid credentials for communicating with the Zorus platform.
        $ValidCredentials=$AgentReg.ValidCredentials
        if ($ValidCredentials -ne 1){
            write-host "! Zorus agent does not have valid credentials to communicate with the platform. Please verify installation."
            write-host "  This can occur if the endpoint is deleted from the platform without uninstalling the agent, or there is a mismatch, remove software and agent in platform and retry."
            $Status='Invalid Credentials'
            $alert=$true
        }
        else {
            write-host "- Credentials for communicating with the Zorus platform are valid."
        }
    }

    if (!($alert)){
        # Check that the agent is enabled in the portal.
        $AgentEnabled=$AgentReg.AgentEnabled
        if ($AgentEnabled -ne 1){
            write-host "! Zorus agent is not enabled in the platform. Check that a license is available and the endpoint is enabled."
            $Status="Not Enabled"
            $alert=$true
        }
    }

    if (!($alert)){
        # Check that version 4.5.0.0 or greater is in use.
        $ServiceEXE=Get-ChildItem "$env:ProgramFiles\Zorus Inc\Archon Agent\Zorus Deployment Agent\ZorusDeploymentService.exe"
        $ProductVersion=$ServiceEXE.versioninfo.ProductVersion
        if ([version]$ProductVersion -lt [version]'4.5.0.0'){
            write-host "! Zorus version is less than 4.5.0.0 and must be updated."
            $Status="Update Required"
            $alert=$true
        }
        else {
            write-host "- Zorus version is greater than 4.5.0.0. Current version is $ProductVersion."
        }
    }

    if (!($alert)){
        # Check Agent Health State
        if ($AgentInfoReg.AgentHealthState -ne 0){
            $ErrorDetails=$AgentInfoReg.ErrorDetails
            if ($ErrorDetails -ne 'Agent disabled locally'){
                # The 'Agent disabled locally' state is not one that will create an alert at this juncture.
                write-host "! Zorus agent health state indicates error. Error message: $ErrorDetails."
                $Status=$ErrorDetails
                $Alert=$true
            }
            else {
                write-host "- Zorus agent health state shows good."
            }
        }
        else {
            write-host "- Zorus agent health state shows good."
        }
    }

    if (!($alert)) {
        # Detect agent removed from portal based on LastSeen vs LastUpdateAttempt
        # If LastUpdateAttempt is newer than LastSeen by more than 30 days, raise an error
        $rawLastSeen = $AgentInfoReg.LastSeen
        $rawLastUpdateAttempt = $AgentInfoReg.LastUpdateAttempt

        $lastSeenOk = $false
        $updateAttemptOk = $false

        try {
            if ($null -ne $rawLastSeen -and $rawLastSeen.ToString().Trim().Length -gt 0) {
                $LastSeen = Get-Date -Date $rawLastSeen -ErrorAction Stop
                $lastSeenOk = $true
            } else {
                write-host "! LastSeen registry value is missing or empty."
            }
        } catch {
            write-host "! Failed to parse LastSeen timestamp: $rawLastSeen"
        }

        try {
            if ($null -ne $rawLastUpdateAttempt -and $rawLastUpdateAttempt.ToString().Trim().Length -gt 0) {
                $LastUpdateAttempt = Get-Date -Date $rawLastUpdateAttempt -ErrorAction Stop
                $updateAttemptOk = $true
            } else {
                write-host "! LastUpdateAttempt registry value is missing or empty."
            }
        } catch {
            write-host "! Failed to parse LastUpdateAttempt timestamp: $rawLastUpdateAttempt"
        }

        if ($lastSeenOk -and $updateAttemptOk) {
            # Calculate difference only if LastUpdateAttempt is newer
            if ($LastUpdateAttempt -gt $LastSeen) {
                $daysApart = [math]::Abs( ($LastUpdateAttempt - $LastSeen).TotalDays )

                write-host "- LastSeen: $LastSeen"
                write-host "- LastUpdateAttempt: $LastUpdateAttempt"
                write-host "- Difference (days): " $daysApart

                if ($daysApart -gt 10) {
                    write-host "! Agent appears removed from portal. LastUpdateAttempt is more than 10 days after LastSeen."
                    $Status = "Removed from portal"
                    $alert = $true
                } else {
                    write-host "- LastSeen and LastUpdateAttempt are within 10 days."
                }
            } else {
                # If LastSeen is equal or newer than LastUpdateAttempt, consider it healthy for this check
                write-host "- LastSeen is equal or more recent than LastUpdateAttempt. No portal removal indicated."
            }
        } else {
            write-host "- Skipping portal removal check due to missing or invalid timestamps."
        }
    }

    if (!($alert)){
        # Check last seen date.
        $LastSeen=Get-Date ($AgentInfoReg.LastSeen) -ErrorAction SilentlyContinue

        # Now
        $Now=Get-Date
        
        # Check if LastSeen time is within the last hour.
        if ($LastSeen.AddHours(48) -gt $Now) {
            write-host "- LastSeen timestamp is within the last 48 hour."
        }
        else{
            # Due to the monitoring having the chance to run at boot/wake times, make sure there has been at least an hour since the last boot or wake 
            # time before alerting. This reduces the chance of false positives.
            
            # Last Boot Time
            $BootTime=Get-Date (Get-CimInstance -ClassName Win32_OperatingSystem | Select-object -Exp LastBootUpTime )
            write-host "- Last boot time: $BootTime"

            # Last Wake Time
            $WakeResult=& wevtutil qe System /rd:true /f:Text /c:1 /q:"<QueryList><Query Id='0' Path='System'><Select Path='System'>*[System[Provider[@Name='Microsoft-Windows-Kernel-Power']]]</Select></Query></QueryList>"
            $WakeTime=Get-Date (($WakeResult | where-object {$_ -match "Date:"}).replace('Date:','').trim()) -ErrorAction SilentlyContinue
            write-host "- Last wake time: $WakeTime"
            # provide a dummy value for the next comparison in case one is missing.
            # There will always be a boot time, but may not have a wake time result if the event logs have been cleared.
            if ($null -eq $WakeTime){
                $WakeTime=$now.AddHours(-2)
            }

            if (($Now -gt $BootTime.AddHours(1)) -and ($Now -gt $WakeTime.AddHours(1))){
                write-host "- At least 1 hour has elapsed since the last Boot and Wake times."
                
                if ($LastSeen.AddHours(1) -lt $Now){
                    write-host "! Agent last communicated with the platform over an hour ago. Agent communication may not be functioning."
                    $Status="Not connected"
                    $alert=$true
                }
                else {
                    write-host "- Agent is successfully communicating with the platform."
                }
            }
            else {
                write-host "- Less than 1 hour has elapsed since the last boot and wake times. Last seen status may be inaccurate. Skipping..."
            }
        }
    }

    # Check for filtering state (platform) 

    # During the roughly 10 seconds it takes to transition the filtering state due to the user enabling or disableing filtering,
    # this result can be incorrect. IsFilteringEnabled is a global value and reflects both the user selection and the platform configuration.
    # Direct access to the user selection is available, but not the platform, so there is a very tiny chance that this result could be invalid.
    if (!($alert)){
        $IsFilteringEnabled=$AgentInfoReg.IsFilteringEnabled
        $UserFilterEnabled=$AgentReg.UserFilterEnabled
        # The UserFilterEnabled key does not exist until the next time the service is started.
        # If the key is missing, assume it has the "enabled" value.
        if ($null -eq $UserFilterEnabled){
            $UserFilterEnabled=1
        }

        if (($IsFilteringEnabled -eq 1) -and ($UserFilterEnabled -eq 1)){
            write-host "- Filtering is enabled."
        }
        elseif (($IsfilteringEnabled -eq 1) -and ($UserFilterEnabled -eq 0)){
            Write-Host "! Filtering disabled by the user."
            $Status="Filtering disabled by user"
            if ($AlertOnUserDisable -eq $true){
                $alert=$true
            }
        }
        elseif (($IsfilteringEnabled -eq 0) -and ($UserFilterEnabled -eq 0)){
            Write-Host "! Filtering disabled by the user."
            $Status="Filtering disabled by user"
            if ($AlertOnUserDisable -eq $true){
                $alert=$true
            }
        } else {
            Write-Host "! Filtering disabled by the portal."
            $Status="Filtering disabled in portal"
            $alert=$true
        }
    }

    write-host "`nEndpoint Details:"
    write-host "`tZorus Customer Name: $($AgentInfoReg.AssignedCustomer)"
    write-host "`tLicense ID: $($AgentInfoReg.LicenseId)`n"
}


write-host '<-End Diagnostic->'
write-host '<-Start Result->'
write-host "STATUS=$Status"
write-host '<-End Result->'
if ($alert){
    exit 1
} else {
    exit 0
}