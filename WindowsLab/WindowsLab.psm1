#Requires -RunAsAdministrator
<#
.SYNOPSIS
    WindowsLab, tools to admin a Windows based Lab
#>

# ----------------
# Init Module Vars
# ----------------

# Get this script name without extension
$thisModuleName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Path)

# Create module directory if not exist
New-Item -Path $env:APPDATA -Name "$thisModuleName" -ItemType Directory -ErrorAction SilentlyContinue

# Set path to $HOME\AppData\Roaming\<module name>\config.json
$configPath = Join-Path -Path $env:APPDATA -ChildPath $thisModuleName 'new_config.json'

if (Test-Path -Path $configPath -PathType Leaf) {
    # Import config.json
    $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
    $selectedLab = $config.Labs[$config.SelectedLab]
}
else {
    $config = @{
        SelectedLab = 0
        Labs = @()
    }
    $selectedLab = $null
}

# -----------------
# Private functions
# -----------------

function Write-Terminal {
    <#
    .SYNOPSIS
        [Private] multicolor line writing to terminal
    #>
    [CmdletBinding()]
    param (
        [Parameter(Position=0, ValueFromPipeline=$true)]
        [string[]]$Text,

        [Parameter(Position=1)]
        [ValidateSet('Black', 'DarkBlue', 'DarkGreen', 'DarkCyan', 'DarkRed', 'DarkMagenta', 'DarkYellow', 'Gray', 'DarkGray', 'Blue', 'Green', 'Cyan', 'Red', 'Magenta', 'Yellow', 'White')]
        [string[]]$ForegroundColor,

        [Parameter(Position=2)]
        [ValidateSet('Black', 'DarkBlue', 'DarkGreen', 'DarkCyan', 'DarkRed', 'DarkMagenta', 'DarkYellow', 'Gray', 'DarkGray', 'Blue', 'Green', 'Cyan', 'Red', 'Magenta', 'Yellow', 'White')]
        [string[]]$BackgroundColor,

        [switch]$Italic,
        [switch]$Underline,
        
        [switch]$NoWrap
    )

    begin {
        $esc = [char]27
        $fgMap = @{
            'Black'='30'; 'DarkRed'='31'; 'DarkGreen'='32'; 'DarkYellow'='33'
            'DarkBlue'='34'; 'DarkMagenta'='35'; 'DarkCyan'='36'; 'Gray'='37'
            'DarkGray'='90'; 'Red'='91'; 'Green'='92'; 'Yellow'='93'
            'Blue'='94'; 'Magenta'='95'; 'Cyan'='96'; 'White'='97'
        }
        $bgMap = @{
            'Black'='40'; 'DarkRed'='41'; 'DarkGreen'='42'; 'DarkYellow'='43'
            'DarkBlue'='44'; 'DarkMagenta'='45'; 'DarkCyan'='46'; 'Gray'='47'
            'DarkGray'='100'; 'Red'='101'; 'Green'='102'; 'Yellow'='103'
            'Blue'='104'; 'Magenta'='105'; 'Cyan'='106'; 'White'='107'
        }
    }

    process {
        if ($null -eq $Text -or $Text.Count -eq 0 -or ($Text.Count -eq 1 -and $Text[0] -eq '')) {
            Write-Host ""
            return
        }

        $outputString = ""
        $visibleLength = 0
        $styleCodes = @()
        if ($Italic)    { $styleCodes += '3' }
        if ($Underline) { $styleCodes += '4' }

        for ($i = 0; $i -lt $Text.Count; $i++) {
            $ansiCodes = @($styleCodes)

            if ($ForegroundColor -and $ForegroundColor.Count -gt 0) {
                $fgName = $ForegroundColor[$i % $ForegroundColor.Count]
                $ansiCodes += $fgMap[$fgName]
            }

            if ($BackgroundColor -and $BackgroundColor.Count -gt 0) {
                $bgName = $BackgroundColor[$i % $BackgroundColor.Count]
                $ansiCodes += $bgMap[$bgName]
            }

            $sequence = ""
            if ($ansiCodes.Count -gt 0) {
                $joinedCodes = $ansiCodes -join ';'
                $sequence = "$esc[$($joinedCodes)m"
            }

            $reset = "$esc[0m"

            # Add space separator for multiple array elements
            if ($i -gt 0) { 
                $outputString += " " 
                $visibleLength += 1
            }

            $outputString += "${sequence}$($Text[$i])${reset}"
            $visibleLength += $Text[$i].Length
        }

        # Handle -NoWrap (Truncation)
        $prefix = if ($NoWrap) { "$esc[?7l" } else { "" }
        $suffix = if ($NoWrap) { "$esc[?7h" } else { "" }

        # Print final string
        Write-Host "${prefix}${outputString}${suffix}"
    }
}

function Test-Lab {
    <#
    .SYNOPSIS
        [Private] Test if at least one Lab exists
    #>
    param()
    if ($null -eq $selectedLab) {
        Write-Terminal -Text "Lab not found" -ForegroundColor DarkRed
        Write-Terminal -Text "Run New-Lab to create a lab" -ForegroundColor DarkYellow
        break
    }
}

function Backup-LabUserDesktop {
    <#
    .SYNOPSIS
        [Private] Backup LabUser desktop into ROOT:\LabPc folder

    .DESCRIPTION
        This cmdlet copies LabUser desktop files and folders into into ROOT:|LabPc folder and deletes any previous item.

    .EXAMPLE
        Backup-LabUserDesktop -UserName Alunno
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$True, HelpMessage="Enter LabUser name")]
        [string]$UserName
    )
    Invoke-Command -ComputerName $selectedLab.PcNames -ScriptBlock {
        ${function:Write-Terminal} = ${using:function:Write-Terminal}
        try {
            # get specified Lab user
            $localUser = Get-LocalUser -Name $Using:UserName -ErrorAction Stop

            # get Lab user USERPROFILE path
            $userProfilePath = (Get-CimInstance -Class Win32_UserProfile | Where-Object { $_.SID -eq $localUser.SID.Value }).LocalPath
            # Test-Path -Path $userProfilePath -ErrorAction Stop | Out-Null

            $userDesktopPath = Join-Path -Path $userprofilePath -ChildPath 'Desktop'

            # create LabPc folder if not exist
            $labPcPath = Join-Path -Path $env:SystemDrive -ChildPath 'LabPc'
            New-Item -Path $labPcPath -ItemType "directory" -ErrorAction SilentlyContinue

            # copy labuser desktop
            Remove-Item -Path $labPcPath -Force -Recurse -ErrorAction SilentlyContinue # delete any previous saved desktop
            Copy-Item -Path "$userDesktopPath\" -Destination $labPcPath -Recurse -Force

            Write-Terminal -Text "$Using:Username Desktop saved for $env:computername" -ForegroundColor Green
        }
        catch [Microsoft.PowerShell.Commands.UserNotFoundException] {
            Write-Terminal -Text "$Using:UserName @ $env:computername does NOT exist" -ForegroundColor Yellow
            Write-Terminal -Text "$Using:Username Desktop save failed for $env:computername" -ForegroundColor Red
        }
        catch [System.Management.Automation.ParameterBindingException] {
            # user exist USERPROFILE path no
            Write-Terminal -Text "$Using:UserName exist but never signed-in on $env:computername" -ForegroundColor Yellow
            Write-Terminal -Text "$Using:Username Desktop save failed for $env:computername" -ForegroundColor Red
        }
    }
}

function Restore-LabUserDesktop {
    <#
    .SYNOPSIS
        [Private] Restore LabUser desktop backup from ROOT:\LabPc

    .DESCRIPTION
        This cmdlet copies back the LabUser desktop backup from ROOT:\LabPc folder, overwrite any existing items.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$True, HelpMessage="Enter LabUser name")]
        [string]$UserName
    )
    Invoke-Command -ComputerName $selectedLab.PcNames -ScriptBlock {
        ${function:Write-Terminal} = ${using:function:Write-Terminal}
        try {
            # get specified Lab user
            $localUser = Get-LocalUser -Name $Using:UserName -ErrorAction Stop

            # get Lab user USERPROFILE path
            $userProfilePath = (Get-CimInstance -Class Win32_UserProfile | Where-Object { $_.SID -eq $localUser.SID.Value }).LocalPath
            Test-Path -Path $userProfilePath -ErrorAction Stop | Out-Null

            $userDesktopPath = Join-Path -Path $userprofilePath -ChildPath 'Desktop'

            # copy lab user desktop back
            $sourcePath = Join-Path -Path $env:SystemDrive -ChildPath "LabPc"
            Copy-Item -Path "$sourcePath\*" -Destination $userDesktopPath -Recurse -Force

            Write-Terminal -Text "$Using:Username Desktop restored for $env:computername" -ForegroundColor Green
        }
        catch [Microsoft.PowerShell.Commands.UserNotFoundException] {
            Write-Terminal -Text "$Using:UserName @ $env:computername does NOT exist" -ForegroundColor Yellow
            Write-Terminal -Text "$Using:Username Desktop restore failed for $env:computername" -ForegroundColor Red
        }
        catch [System.Management.Automation.ParameterBindingException] {
            Write-Terminal -Text "$Using:UserName exist but never signed-in on $env:computername" -ForegroundColor Yellow
            Write-Terminal -Text "$Using:Username Desktop restore failed for $env:computername" -ForegroundColor Red
        }
    }
}


# ----------------
# Public functions
# ----------------

function Show-Lab {
    <#
    .SYNOPSIS
        List all available labs and highlight which one is the current lab

    .EXAMPLE
        Show-Lab        
    #>
    [CmdletBinding()]
    param()

    Test-Lab

    foreach ($i in 0..($script:config.Labs.Count - 1)) {
        if ($i -eq $script:config.SelectedLab) {
            Write-Terminal -Text "$($script:config.Labs[$i].Name)", "(current lab)" -ForegroundColor DarkCyan, Yellow
        } else {
            Write-Terminal -Text "$($script:config.Labs[$i].Name)" -ForegroundColor DarkCyan
        }
    }
}

function Show-LabPc {
    <#
    .SYNOPSIS
        List all available LabPCs

    .EXAMPLE
        Show-LabPcNames
    #>
    [CmdletBinding()]
    param ()

    Test-Lab

    Write-Terminal -Text "Lab name:", "$($script:selectedLab.Name)" -ForegroundColor DarkYellow, DarkCyan
    for ($i = 0; $i -lt $script:selectedLab.PcNames.Count; $i++) {
        if ([bool]$script:selectedLab.PcMacs[$i]) {
            Write-Terminal -Text "$($script:selectedLab.PcNames[$i])", $script:selectedLab.PcMacs[$i] -ForegroundColor DarkYellow, DarkGreen
        }
        else {
            Write-Terminal -Text "$($script:selectedLab.PcNames[$i])", "MAC address missing" -ForegroundColor DarkYellow, DarkRed
        }
    }
}

function Select-Lab {
    <#
    .SYNOPSIS
        Select  the current lab
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, HelpMessage="Enter the lab index number")]
        [string]$LabName
    )

    Test-Lab

    # Find LabIndex for LabName
    $labIndex = -1
    foreach ($i in 0..($script:config.Labs.Count - 1)) {
        if ($script:config.Labs[$i].Name -eq $LabName) {
            $labIndex = $i
            break
        }
    }    

    # Check lab exists
    if (-not [bool]($Script:config.Labs | Where-Object { $_.Name -eq $LabName })) {
        Write-Terminal "Lab does not exist" -ForegroundColor DarkRed
    } else {
        # Update module vars (non-persistent memory)
        $script:config.SelectedLab = $labIndex
        $script:selectedLab = $script:config.Labs[$labIndex]

        # Update config JSON file (persistent memory)
        $script:config | ConvertTo-Json -Depth 3 | Set-Content -Path $configPath -Encoding UTF8

        Write-Terminal "Lab", "$($script:selectedLab.Name)", "selected" -ForegroundColor Yellow, DarkCyan, Yellow
    }
}

function New-Lab {
    <#
    .SYNOPSIS
        Create a new lab
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, HelpMessage="Enter lab name")]
        [string]$LabName,
        [Parameter(Mandatory=$true, HelpMessage="Enter comma separated LabPc Names")]
        [string[]]$LabPcNames
    )

    # Check if lab already exists
    if ([bool]($script:config.Labs | Where-Object { $_.Name -eq $LabName })) {
        Write-Terminal "Lab already exists" -ForegroundColor DarkRed
    } 
    else {
        # Split up names to an array
        $pcNames = $LabPcNames -split ",\s*"

        # Remove empty values
        $pcNames = $pcNames | Where-Object {$_ -ne ""}

        # Force PS treating a single name as an array
        $pcNames = $pcNames -as [System.Array]    
        
        # Update module var (non-persistent memory)
        $script:config.Labs += @{
            Name = $LabName
            PcNames = $pcNames
            PcMacs = @()
        }

        if ($null -eq $script:selectedLab) {
            $script:selectedLab = $script:config.Labs[0]
        }

        
        # Update config JSON file (persistent memory)
        $script:config | ConvertTo-Json -Depth 3 | Set-Content -Path $configPath -Encoding UTF8

        Write-Terminal "Lab", "$LabName", "created" -ForegroundColor Yellow, DarkCyan, Yellow
    }
}

function Remove-Lab {
    <#
    .SYNOPSIS
        Remove a lab
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, HelpMessage="Enter lab name")]
        [string]$LabName
    )

    Test-Lab

    # Find LabIndex for LabName
    $labIndex = -1
    foreach ($i in 0..($script:config.Labs.Count - 1)) {
        if ($script:config.Labs[$i].Name -eq $LabName) {
            $labIndex = $i
            break
        }
    }

    # Current lab check
    if ($script:config.Labs[$script:config.SelectedLab].Name -eq $LabName) {
         Write-Terminal "Current lab cannot be removed" -ForegroundColor DarkRed
    }
    # Lab existence check
    elseif (-not [bool]($Script:config.Labs | Where-Object { $_.Name -eq $LabName })) {
        Write-Terminal "Lab does not exist" -ForegroundColor DarkRed
    }
    else {
        $script:config.Labs = $script:config.Labs | Where-Object { $_.Name -ne $LabName }
        Write-Terminal "$LabName", "removed" -ForegroundColor DarkCyan, DarkGreen

        # Force treating a single item as an array
        $Script:config.Labs = $Script:config.Labs -as [System.Array]

        # Check SelectedLab index correction
        if ($script:config.SelectedLab -gt $labIndex) {
            $script:config.SelectedLab -= 1
        }

        # Update config JSON file (persistent memory)
        $script:config | ConvertTo-Json -Depth 3 | Set-Content -Path $configPath -Encoding UTF8           
    }   
}

function Get-LabMac {
    <#
    .SYNOPSIS
        Get Ethernet adapter MAC address for each LabPC

    .DESCRIPTION
        Get-LabMac searches for MAC addresses, when a MAC address is 
        found, it is saved to the configuration file.

    .NOTES
        MAC addresses are required for the Start-LabPc cmdlet to use
        Wake-on-LAN (WoL).        
    #>
    [CmdletBinding()]
    param ()

    Test-Lab
    $selectedLab = $script:selectedLab

    $foundMacs = @()
    foreach ($pcName in $selectedLab.PcNames) {
        try {
            # Search for Physical, connected (Up), ethernet (standard 802.3) adapter
            $netAdapter = Get-NetAdapter -Physical -CimSession $pcName -ErrorAction Stop |
            Where-Object {
                $_.Status -eq "Up" -and ($_.PhysicalMediaType -like "*802.3*" -or $_.Name -like "*Ethernet*")
            } | Select-Object MacAddress

            if ($netAdapter.Length -eq 0) {
                # LabPc connected, but not via an Ethernet adapter.
                $foundMacs += $null
                Write-Terminal "$pcName", "not connected via an Ethernet adapter." -ForegroundColor DarkYellow, DarkRed
            }
            elseif ($netAdapter.Length -eq 1) {
                # LabPc connected via an Ethernet adapter.
                $foundMacs += $netAdapter.MacAddress
                Write-Terminal "$pcName", "$($netAdapter.MacAddress)" -ForegroundColor DarkYellow, DarkGreen
            }
            else {
                # LabPc connected via multiple adapters, including Ethernet.
                $foundMacs += $null
                Write-Terminal "$pcName", "connected via multiple adapters, including Ethernet." -ForegroundColor DarkYellow, DarkRed
            }

        }
        catch [Microsoft.PowerShell.Cmdletization.Cim.CimJobException] {
            # LabPC unreachable, either off, disconnected, or not ready.
            $foundMacs += $null
            Write-Terminal "$pcName", "unreachable", "(off, disconnected, or not ready)" -ForegroundColor DarkYellow, DarkRed, Yellow
        }
        catch {
            Write-Terminal $_.exception.GetType().fullname
        }
    }
    # Update module vars (non-persistent memory)
    $script:selectedLab.PcMacs = $foundMacs
    $script:config.Labs[$script:config.SelectedLab] = $selectedLab

    # Update config JSON file (persistent memory)
    $script:config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath
    Write-Terminal "Any found MAC addresses have been saved and are available for Start-LabPc cmdlet." -ForegroundColor DarkYellow

    if ($foundMacs -contains $null) {
        Write-Terminal "To retrieve any missing MAC addresses, resolve the issues above and relaunch Get-LabMac" -ForegroundColor DarkYellow
    }    
   
}

function Test-LabPcPrompt {
    <#
    .SYNOPSIS
        Tests for each LabPC if the WinRM service is running.

    .DESCRIPTION
        This cmdlet shows which LabPCs are ready to accept remote cmdlets.

    .EXAMPLE
        Test-LabPcPrompt
    #>
    [CmdletBinding()]
    param ()

    Test-Lab
    foreach ($pc in $selectedLab.PcNames) {
        try {
            Test-WSMan -ComputerName $pc -ErrorAction Stop | Out-Null
            Write-Terminal -Text "$pc", "ready" -ForegroundColor DarkYellow, DarkGreen
        }
        catch [System.InvalidOperationException] {
            Write-Terminal -Text "$pc", "unreachable", "(off, disconnected, or not ready)" -ForegroundColor DarkYellow, DarkRed, Yellow
        }
    }
}

function Sync-LabPcDate {
    <#
    .SYNOPSIS
        Sync Main Computer date with NTP time and then sync each LabPC date

        .EXAMPLE
        Sync-LabPcDate

    .NOTES
        The NtpTime module is required on Main Computer (https://www.powershellgallery.com/packages/NtpTime/1.1);
        Set-Date requires admin privilege to run;
    #>
    [CmdletBinding()]
    param ()

    Test-Lab

    # check if NtpTime module is installed
    if ($null -eq (Get-Module -ListAvailable -Name NtpTime)) {
        Write-Terminal -Text "`nNtpTime Module missing. Install the module with:" -ForegroundColor Yellow
        Write-Terminal -Text "    Install-Module -Name NtpTime`n"
        Break
    }

    try {
        # get datetime from default NTP server
        $currentDate = (Get-NtpTime -MaxOffset 60000 -ErrorAction Stop).NtpTime
        
        Set-Date -Date $currentDate | Out-Null
        Write-Terminal -Text "Main ", "synced", "with NTP time: $currentDate" -ForegroundColor DarkYellow, DarkGreen, Yellow

        $results = Invoke-Command -ComputerName $selectedLab.PcNames -ScriptBlock {
            # progress line
            Write-Host "=" -NoNewline -ForegroundColor Yellow
            Set-Date -Date $Using:currentDate
            [PSCustomObject]@{
                ComputerName = $env:COMPUTERNAME
            }                
        } -ErrorAction SilentlyContinue

        # delete progress line 
        $esc = [char]27
        Write-Host "$($Esc)[1K$($ESC)[G" -NoNewline

        # Show results
        foreach ($pc in $selectedLab.PcNames) {
            if ($pc -in $results.ComputerName) {
                Write-Terminal -Text "$pc", "synced" -ForegroundColor DarkYellow, DarkGreen
            } else {
                Write-Terminal -Text "$pc", "not synced", "(off or not ready)" -ForegroundColor DarkYellow, DarkRed, Yellow
            }
        }
    }
    catch {
        Write-Terminal "Sync-LabPcdate:", "$($_.Exception.Message)", "(Try again later)" -ForegroundColor DarkYellow, Red, Yellow
    }        
}

function Start-LabPc {
    <#
    .SYNOPSIS
        Turn on each computers if WoL setting is present and enabled in BIOS/UEFI

    .EXAMPLE
        Start-LabPc

    .NOTES
        https://www.pdq.com/blog/wake-on-lan-wol-magic-packet-powershell/
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param ()

    Test-Lab
    Write-Terminal -Text "Remember, Start-LabPc works only if the LabPCs support WoL (Wake-on-LAN)." -ForegroundColor DarkYellow

    # Send Magic Packet over LAN
    for ($i = 0; $i -lt $selectedLab.PcNames.Count; $i++) {
        $PcName = $selectedLab.PcNames[$i]
        $Mac = $selectedLab.PcMacs[$i]
        if ($Mac) {
            $MacByteArray = $Mac -split "[:-]" | ForEach-Object { [Byte] "0x$_"}
            [Byte[]] $MagicPacket = (,0xFF * 6) + ($MacByteArray * 16)
            $UdpClient = New-Object System.Net.Sockets.UdpClient
            $UdpClient.Connect(([System.Net.IPAddress]::Broadcast),7)
            $UdpClient.Send($MagicPacket,$MagicPacket.Length) | Out-Null
            $UdpClient.Close()
            Write-Terminal -Text $PcName, "Started" -ForegroundColor DarkYellow, Green
        }
        else {
            Write-Terminal -Text $PcName, "is missing MAC Address." -ForegroundColor Red
            Write-Terminal -Text "(Run Set-LabPcNames and press [Get MACs] button for more information.)" -ForegroundColor Gray
        }
    }

}

function Stop-LabPc {
    <#
    .SYNOPSIS
        Force an immediate shut down of each computer

        Stop-LabPc
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Test-Lab
    $results = Invoke-command -ComputerName $selectedLab.PcNames -ScriptBlock {
        Stop-Computer  -ComputerName $env:COMPUTERNAME -Force -ErrorAction SilentlyContinue
        [PSCustomObject]@{
            ComputerName = $env:COMPUTERNAME
        }
    } -ErrorAction SilentlyContinue

    # Show results
    foreach ($pc in $selectedLab.PcNames) {
        if ($pc -in $results.ComputerName) {
            Write-Terminal -Text "$pc", "shutting down" -ForegroundColor DarkYellow, DarkGreen
        } else {
            Write-Terminal -Text "$pc", "already off" -ForegroundColor DarkYellow, DarkRed
        }
        
    }    
}

function Restart-LabPc {
    <#
    .SYNOPSIS
        Force an immediate restart of each computer

        Restart-LabPc
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Test-Lab
    $results = Invoke-Command -ComputerName $selectedLab.PcNames -ScriptBlock {
        Restart-Computer -ComputerName $env:COMPUTERNAME -Force -ErrorAction SilentlyContinue
        [PSCustomObject]@{
            ComputerName = $env:COMPUTERNAME
        }
    } -ErrorAction SilentlyContinue

    # Show results
    foreach ($pc in $selectedLab.PcNames) {
        if ($pc -in $results.ComputerName) {
            Write-Terminal -Text "$pc", "restarting" -ForegroundColor DarkYellow, DarkGreen
        } else {
            Write-Terminal -Text "$pc", "is off" -ForegroundColor DarkYellow, DarkRed
        }   
    }
}

function Disconnect-User {
    <#
    .SYNOPSIS
        Disconnect any connected user from each LabPC

    .EXAMPLE
        Disconnect-User

    .NOTES
        Windows Home edition doesn't include query.exe (https://superuser.com/a/1646775)

        Quser.exe emit a non-terminating error in case of no user logged-in,
        to catch the error force PS to raise an exception, set $ErrorActionPreference = 'Stop'
        because quser, being not a cmdlet, has not -ErrorAction parameter.
    #>
    [CmdletBinding()]
    param()

    Test-Lab
    $results = Invoke-Command -ComputerName $selectedLab.PcNames -ScriptBlock {
        $ErrorActionPreference = 'Stop' # NOTE: function scope valid
        # progress line
        Write-Host "=" -NoNewline -ForegroundColor Yellow        
        try {
            # check if quser command exist
            Get-Command -Name quser -ErrorAction Stop | Out-Null

            # get array of logged-in users, skip 1st row (the head)
            quser | Select-Object -Skip 1 |
            ForEach-Object {
                # logoff by session ID
                logoff ($_ -split "\s+")[2]
                [PSCustomObject]@{
                    ComputerName = $env:COMPUTERNAME
                    UserName = ($_ -split "\s+")[1]
                    quserExisted = $true
                }
            }
        }
        catch [System.Management.Automation.CommandNotFoundException] {
            [PSCustomObject]@{
                ComputerName = $env:COMPUTERNAME
                quserExisted = $false
            }
        }
        catch {
            [PSCustomObject]@{
                ComputerName = $env:COMPUTERNAME
                UserName = $null
                quserExisted = $true
            }
        }
    } -ErrorAction SilentlyContinue

    # Delete progress line 
    $esc = [char]27
    Write-Host "$($Esc)[1K$($ESC)[G" -NoNewline

    # Show results
    foreach ($pc in $results) {
        if ($pc.quserExisted -eq $false) {
            Write-Terminal "$($pc.ComputerName)", "quser command not found", "(is it a windows Home edition?)" -ForegroundColor DarkYellow, DarkRed, Yellow
        } else {
            if ($null -eq $pc.UserName) {
                Write-Terminal "$($pc.ComputerName)", "no user logged in" -ForegroundColor DarkYellow, yellow
            } else {
                Write-Terminal "$($pc.ComputerName)", "$($pc.UserName)", "logged out" -ForegroundColor DarkYellow, Yellow, DarkGreen
            }
        }
    }

    foreach ($pc in $selectedLab.PcNames) {
        if ($pc -notin $results.ComputerName) {
            Write-Terminal -Text "$pc", "unreachable", "(off, disconnected, or not ready)" -ForegroundColor DarkYellow, DarkRed, Yellow
        }
    }

}

function New-LabUser {
    <#
    .SYNOPSIS
        Create a Standard Lab user with a blank never-expiring password

    .EXAMPLE
        New-LabUser -UserName "Alunno"

    .NOTES
        I just want to clarify the usage of the New-LocalUser cmdlet's switch parameters
        -NoPassword and -UserMayNotChangePassword. According to Microsoft, the -NoPassword
        parameter indicates that the user account doesn't have a password. However, in my
        tests, the user was prompted to provide a password when signing in for the first time.
        This indicates that -NoPassword is different from a blank password. Consequently, using
        -NoPassword along with -UserMayNotChangePassword results in a deadlock.

        Windows Groups' description: https://ss64.com/nt/syntax-security_groups.html
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param (
      [Parameter(Mandatory=$True, HelpMessage="Enter username for Lab User")]
      [string]$UserName
    )

    Test-Lab
    Invoke-Command -ComputerName $selectedLab.PcNames -ScriptBlock {
        ${function:Write-Terminal} = ${using:function:Write-Terminal}
        try {
            $blankPassword = [securestring]::new()
            New-LocalUser -Name $Using:UserName -Password $blankPassword -PasswordNeverExpires `
            -UserMayNotChangePassword -AccountNeverExpires -ErrorAction Stop | Out-Null

            Add-LocalGroupMember -Group "Users" -Member $Using:UserName

            Write-Terminal -Text "$Using:UserName created on $env:computername" -ForegroundColor Green
        }
        catch [Microsoft.PowerShell.Commands.UserExistsException] {
            Write-Terminal -Text "$Using:UserName already exist on $env:computername" -ForegroundColor Yellow
        }
    }
}

function Remove-LabUser {
    <#
    .SYNOPSIS
        Remove specified Lab User, also remove registry entry and user profile folder if they exist

    .DESCRIPTION
        This cmdlet log out the lab user if he is logged in and completely remove it

    .EXAMPLE
        Remove-LabUser -Username "Alunno"

    .NOTES
        Inspiration: https://adamtheautomator.com/powershell-delete-user-profile/
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param (
      [Parameter(Mandatory=$True, HelpMessage="Enter username for Lab User")]
      [string]$UserName
    )

    Test-Lab
    Invoke-Command -ComputerName $selectedLab.PcNames -ScriptBlock {
        ${function:Write-Terminal} = ${using:function:Write-Terminal}
        try {
            # check if quser command exist
            Get-Command -Name quser -ErrorAction Stop | Out-Null

            # log out if logged in otherwise silently continue
            $ErrorActionPreference = 'SilentlyContinue'
            quser $Using:UserName | Select-Object -Skip 1 |
            ForEach-Object {
                # logoff by session ID
                logoff ($_ -split "\s+")[2]
                Write-Terminal -Text "User", ($_ -split "\s+")[1], "logged out $($env:COMPUTERNAME)" -ForegroundColor Green
            }
            $ErrorActionPreference = 'Continue'
        }
        catch [System.Management.Automation.CommandNotFoundException] {
            Write-Terminal -Text "quser command not found on $env:computername" -ForegroundColor Red
            Write-Terminal -Text "is it a windows Home edition? I'll try to remove $using:UserName anyway ...`n"
        }

        try {
            $localUser = Get-LocalUser -Name $Using:UserName -ErrorAction Stop

            # Remove the sign-in entry in Windows
            Remove-LocalUser -SID $localUser.SID.Value

            # Remove %USERPROFILE% folder and registry entry if exist
            Get-CimInstance -Class Win32_UserProfile | Where-Object { $_.SID -eq $localUser.SID.Value } | Remove-CimInstance

            Write-Terminal -Text "$Using:UserName removed on $env:computername" -ForegroundColor Green
        }
        catch [Microsoft.PowerShell.Commands.UserNotFoundException] {
            <#Do this if a terminating exception happens#>
            Write-Terminal -Text "$Using:UserName NOT exist on $env:computername" -ForegroundColor Yellow
        }
    }
}

function Set-LabUser {
    <#
    .SYNOPSIS
        Set password and account type for the LabUser specified

    .EXAMPLE
        Set-LabUser -UserName "Alunno"
        Set-LabUser -UserName "Alunno" -SetPassword
        Set-LabUser -UserName "Alunno" -SetPassword -AccountType Administrator

    .NOTES
        LabUser Administrators can't change the password like standard users

        Windows Groups description: https://ss64.com/nt/syntax-security_groups.html
    #>
    [CmdletBinding(DefaultParameterSetName = 'Set0', SupportsShouldProcess = $True)]
    param (
        [Parameter(Mandatory=$True, HelpMessage="Enter the username for Lab User")]
        [string]$UserName,
        [switch]$SetPassword,
        [validateSet('StandardUser', 'Administrator')]
        [string]$AccountType,
        [Parameter(ParameterSetName = 'Set1')]
        [switch]$BackupDesktop,
        [Parameter(ParameterSetName = 'Set2')]
        [switch]$RestoreDesktop
    )

    Test-Lab
    switch ($PSCmdlet.ParameterSetName) {
        'Set0' {$password = $null
                if ($SetPassword.IsPresent) {
                    # Prompt and read new password
                    $password = Read-Host -Prompt 'Enter the new password' -AsSecureString
                }
                Invoke-Command -ComputerName $selectedLab.PcNames  -ScriptBlock {
                    ${function:Write-Terminal} = ${using:function:Write-Terminal}
                    try {
                        if ($Using:SetPassword.IsPresent) {
                            # change password
                            Set-LocalUser -Name $Using:UserName -Password $Using:Password -PasswordNeverExpires $True `
                            -UserMayChangePassword $False -ErrorAction Stop
                            Write-Terminal -Text "$Using:UserName on $env:computername password changed" -ForegroundColor Green
                        }
                        if ($Using:AccountType -eq 'Administrator') {
                            # change to an Administrator
                            Add-LocalGroupMember -Group "Administrators" -Member $Using:UserName -ErrorAction Stop
                            Write-Terminal -Text "$Using:UserName on $env:computername is now an Administrator" -ForegroundColor Green
                        }
                        if ($Using:AccountType -eq 'StandardUser') {
                            # change to a Standard User
                            Remove-LocalGroupMember -Group "Administrators" -Member $Using:UserName -ErrorAction Stop
                            Write-Terminal -Text "$Using:UserName on $env:computername is now a Standard User" -ForegroundColor Green
                        }
                    }
                    catch [Microsoft.PowerShell.Commands.UserNotFoundException] {
                        Write-Terminal -Text "$Using:UserName NOT exist on $env:computername" -ForegroundColor Yellow
                    }
                    catch [Microsoft.PowerShell.Commands.MemberExistsException] {
                        Write-Terminal -Text "$Using:UserName on $env:computername is already an Administrator" -ForegroundColor Yellow
                    }
                    catch [Microsoft.PowerShell.Commands.MemberNotFoundException] {
                        Write-Terminal -Text "$Using:UserName on $env:computername is already a Standard User" -ForegroundColor Yellow
                    }
                    catch {
                        $_.exception.GetType().fullname
                    }
                }
        }
        'Set1' {Backup-LabUserDesktop -UserName $UserName} # -BackupDesktop provided
        'Set2' {Restore-LabUserDesktop -UserName $UserName} # -RestoreDesktop provided
    }
}
