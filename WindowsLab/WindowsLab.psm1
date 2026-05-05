#Requires -RunAsAdministrator
<#
.SYNOPSIS
    WindowsLab, tools to admin a Windows based Lab
#>

# -- Init Module Vars ---

# Get this script name without extension
$thisModuleName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Path)

# Set path to $HOME\AppData\Roaming\<module name>\config.json

# Create module directory if not exist
New-Item -Path $env:APPDATA -Name "$thisModuleName" -ItemType Directory -ErrorAction SilentlyContinue
$configPath = Join-Path -Path $env:APPDATA -ChildPath $thisModuleName 'config.json'
$selectedIconPath = Join-Path -Path $PSScriptRoot -ChildPath "selectedTab.ico"

if (Test-Path -Path $configPath -PathType Leaf) {
    # Import config.json
    $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
    $currentLab = $config.Labs[$config.LastSelectedLab]
}
else {
    $currentLab = $null
}

# -- End Init Vars --

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

        # Print final string with padding
        Write-Host "${prefix}${padding}${outputString}${suffix}"
    }
}

function Test-NoLabPcName {
    <#
    .SYNOPSIS
        [Private] Test if LabPc names are not set in config.json
    #>
    param ()
    Write-Terminal -Text "Lab name: $($currentLab.Name)" -ForegroundColor DarkCyan
    Write-Terminal
    if ($currentlab.PcNames.Length -eq 0) {
        Write-Terminal -Text "LabPc names not found" -ForegroundColor Red
        Write-Terminal -Text "Run Set-LabPcName to set LabPc names`n" -ForegroundColor DarkYellow
        break
    }
}

function Get-LabPcMac {
    <#
    .SYNOPSIS
        [Private] Show info into GUI console about Ethernet PcLab MAC addresses.

    .DESCRIPTION
        Get-LabPcMac searches for LabPC Ethernet MAC addresses. When
        a MAC address is found, it is saved to the configuration file.
        MAC addresses are required for the Start-LabPc cmdlet to use
        Wake-on-LAN (WoL).

    .NOTES
        This cmdlet uses Write-Output to send messages to the pipeline,
        allowing them to be displayed in the GUI console.
    #>

    Update-Config
    $foundMacs = @()
    $currentlab.PcNames | ForEach-Object {
        try {
            Write-Output "`n$_"
            $pcNameLen = $_.Length

            # Search for Physical, connected (Up), ethernet (standard 802.3) adapter
            $netAdapter = Get-NetAdapter -Physical -CimSession $_ -ErrorAction Stop |
            Where-Object {
                $_.Status -eq "Up" -and ($_.PhysicalMediaType -like "*802.3*" -or $_.Name -like "*Ethernet*")
            } | Select-Object MacAddress

            if ($netAdapter.Length -eq 0) {
                # Connected, but not via an Ethernet adapter.
                $foundMacs += $null
                Write-Output "is not connected via an Ethernet adapter. Please connect.`n$('-' * $pcNameLen)"
            }
            elseif ($netAdapter.Length -eq 1) {
                # Connected via an Ethernet adapter.
                $foundMacs += $netAdapter.MacAddress
                Write-Output "$($netAdapter.MacAddress)`n$('-' * $pcNameLen)"
            }
            else {
                # Connected via multiple adapters, including Ethernet.
                $foundMacs += $null
                Write-Output "appears to have $($netAdapter.MacAddress.count) Ethernet adapters. Disconnect all but one.`n$('-' * $pcNameLen)"
            }

        }
        catch [Microsoft.PowerShell.Cmdletization.Cim.CimJobException] {
            # LabPC is unreachable because it is either off, not connected, or not ready.
            $foundMacs += $null
            Write-Output "is unreachable because it is either off, not connected, or not ready.`n$('-' * $pcNameLen)"
        }
        catch {
            Write-Output $_.exception.GetType().fullname
        }
    }

    $script:currentLab.PcMacs = $foundMacs
    $script:config.Labs[$config.LastSelectedLab] = $currentLab

    # Save to JSON file
    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath
    Write-Output "`n`nAny found MAC addresses have been saved and are available for Start-LabPc cmdlet."
    if ($foundMacs -contains $null) {
        Write-Output "`nTo retrieve any missing MAC addresses, resolve the issues above and press again [Get MACs] button."
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
    Invoke-Command -ComputerName $currentLab.PcNames -ScriptBlock {
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
    Invoke-Command -ComputerName $currentLab.PcNames -ScriptBlock {
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
function Set-LabPcName {
    <#
    .SYNOPSIS
        GUI to manage LabPcs names

    .DESCRIPTION
        Allows to set/update config.json file through a GUI
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    # Load the Windows Forms assembly
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # Create the form
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "WindowsLab - Lab Settings"
    $form.Size = New-Object System.Drawing.Size(800, 600)
    $form.StartPosition = "CenterScreen"

    # Create TabControl
    $tabControl = New-Object System.Windows.Forms.TabControl
    $tabControl.Location = New-Object System.Drawing.Point(10, 10)
    $tabControl.Size = New-Object System.Drawing.Size(765, 500)
    $form.Controls.Add($tabControl)

    # Create an ImageList, set icon size, and load an icon
    $imageList = New-Object System.Windows.Forms.ImageList
    $imageList.ImageSize = New-Object System.Drawing.Size(10, 10)
    $imageList.Images.Add([System.Drawing.Image]::FromFile($selectedIconPath))

    # Assign the ImageList to the TabControl
    $tabControl.ImageList = $imageList

    # Create "Add Lab" button
    $addLabButton = New-Object System.Windows.Forms.Button
    $addLabButton.Location = New-Object System.Drawing.Point(10, 520)
    $addLabButton.Size = New-Object System.Drawing.Size(100, 30)
    $addLabButton.Text = "Add Lab"
    $form.Controls.Add($addLabButton)

    # Create "Remove Lab" button
    $removeLabButton = New-Object System.Windows.Forms.Button
    $removeLabButton.Location = New-Object System.Drawing.Point(120, 520)
    $removeLabButton.Size = New-Object System.Drawing.Size(100, 30)
    $removeLabButton.Text = "Remove Lab"
    $form.Controls.Add($removeLabButton)

    # Add Save button
    $saveNamesButton = New-Object System.Windows.Forms.Button
    $saveNamesButton.Location = New-Object System.Drawing.Point(230, 520)
    $saveNamesButton.Size = New-Object System.Drawing.Size(100, 30)
    $saveNamesButton.Text = "Save"
    $form.Controls.Add($saveNamesButton)

    # Function to create embedded PowerShell console
    function New-EmbeddedConsole {
        param (
            [System.Windows.Forms.Control]$parent,
            [int]$x,
            [int]$y,
            [int]$width,
            [int]$height
        )

        $richTextBox = New-Object System.Windows.Forms.RichTextBox
        $richTextBox.Location = New-Object System.Drawing.Point($x, $y)
        $richTextBox.Size = New-Object System.Drawing.Size($width, $height)
        $richTextBox.BackColor = [System.Drawing.Color]::Black
        $richTextBox.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#45C4B0")
        $richTextBox.Font = New-Object System.Drawing.Font("Consolas", 11)
        $richTextBox.ReadOnly = $true
        $richTextBox.Multiline = $true
        $richTextBox.ScrollBars = "Vertical"
        $richTextBox.WordWrap = $true

        $parent.Controls.Add($richTextBox)
        return $richTextBox
    }

    function Update-Config {
        <#
        Update config module var (non-persistent memory)
        #>

        $cfg = @{
            Labs = @()
            LastSelectedLab = $tabControl.SelectedIndex
        }

        foreach ($tab in $tabControl.TabPages) {
            $textField = $tab.Controls | Where-Object { $_ -is [System.Windows.Forms.TextBox] }
            if ($textField.Text -eq "Enter comma separated LabPc Names") { $pcNames = @() }
            else {
                # Split up names to an array
                $pcNames = $textField.Text -split ",\s*"

                # Remove empty values
                $pcNames = $pcNames | Where-Object {$_ -ne ""}

                # Force PS treating a single name as an array
                $pcNames = $pcNames -as [System.Array]
            }

            $pcMacs = $config.Labs[$tab.TabIndex].PcMacs
            if ($pcMacs) {
                # Force PS treating a single MAC as an array
                $pcMacs = $pcMacs -as [System.Array]
            }
            else {$pcMacs = @()}


            $cfg.Labs += @{
                # Take values from GUI
                Name = $tab.Text
                PcNames = $pcNames
                # Keep saved MACs
                PcMacs = $pcMacs
            }
        }

        $Script:config = $cfg
        $script:currentLab = $config.Labs[$config.LastSelectedLab]
    }

    # Function to create a new tab
    function Add-NewTab {
        param(
            [string]$tabName = "",
            [string]$textContent = ""
        )

        # LabName mini input form
        if ([string]::IsNullOrWhiteSpace($tabName)) {
            $labNameForm = New-Object System.Windows.Forms.Form
            $labNameForm.Text = "Enter Lab Name"
            $labNameForm.Size = New-Object System.Drawing.Size(300, 150)
            $labNameForm.StartPosition = "CenterScreen"

            $labNameField = New-Object System.Windows.Forms.TextBox
            $labNameField.Location = New-Object System.Drawing.Point(10, 20)
            $labNameField.Size = New-Object System.Drawing.Size(260, 20)
            $labNameForm.Controls.Add($labNameField)

            $okButton = New-Object System.Windows.Forms.Button
            $okButton.Location = New-Object System.Drawing.Point(100, 70)
            $okButton.Size = New-Object System.Drawing.Size(75, 23)
            $okButton.Text = "OK"
            $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $labNameForm.Controls.Add($okButton)
            $labNameForm.AcceptButton = $okButton

            $result = $labNameForm.ShowDialog()

            if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
                $tabName = $labNameField.Text
                if ([string]::IsNullOrWhiteSpace($tabName)) {
                    $randomLabName = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 3 | ForEach-Object { [char]$_ })
                    $tabName = $randomLabName
                }
            } else {
                return
            }
        }

        # Create new TabPage
        $tabPage = New-Object System.Windows.Forms.TabPage
        $tabPage.Text = $tabName

        # Add (single line) TextField to the tab
        $textField = New-Object System.Windows.Forms.TextBox
        $textField.Multiline = $false
        $textField.Location = New-Object System.Drawing.Point(10, 10)
        $textField.Size = New-Object System.Drawing.Size(730, 20)
        $textField.Text = $textContent

        # Add placeholder text to single-line field
        if ([string]::IsNullOrWhiteSpace($textContent)) {
            $textField.ForeColor = [System.Drawing.Color]::Gray
            $textField.Text = "Enter comma separated LabPc Names"

            $textField.Add_GotFocus({
                if ($this.Text -eq "Enter comma separated LabPc Names") {
                    $this.Text = ""
                    $this.ForeColor = [System.Drawing.Color]::Black
                }
            })

            $textField.Add_LostFocus({
                if ([string]::IsNullOrWhiteSpace($this.Text)) {
                    $this.Text = "Enter comma separated LabPc Names"
                    $this.ForeColor = [System.Drawing.Color]::Gray
                }
            })
        }

        $tabPage.Controls.Add($textField)

        # Add [Get MAcs] button to the tab
        $showMacsButton = New-Object System.Windows.Forms.Button
        $showMacsButton.Location = New-Object System.Drawing.Point(10, 40)
        $showMacsButton.Text = "Get MACs"
        $w = ($showMacsButton.Text.Length + 4)*6
        $showMacsButton.Size = New-Object System.Drawing.Size($w, 25)
        $tabPage.Controls.Add($showMacsButton)

        # Add embedded console to the tab
        $console = New-EmbeddedConsole -parent $tabPage -x 10 -y 72 -width 730 -height 378

        # Get [MAcs button] click event
        $showMacsButton.Add_Click({
            if ($tabControl.TabCount -gt 0) {

                $currentTab = $tabControl.SelectedTab
                $console = $currentTab.Controls | Where-Object { $_ -is [System.Windows.Forms.RichTextBox] }

                # Clear previous output
                $console.Clear()

                # Add new output
                $console.AppendText("Lab $($currentLab.Name)")
                if ($currentLab.PcNames) {
                    $console.AppendText("`n`nSearching for MAC addresses of physically connected Ethernet adapters")
                    $console.AppendText("`n`nWait ...`n")

                    # Display Get-LabPcMac output to console
                    $output = Get-LabPcMac
                    $console.AppendText($output)
                }
                else {
                    $console.AppendText("`n`nFirst, enter the LabPC names, then press the [Get MACs] button again.")
                }
            }
        })

        # Add the new tab to TabControl
        $tabControl.TabPages.Add($tabPage)
    }

    # Add Lab button click event
    $addLabButton.Add_Click({
        Add-NewTab
        $tabControl.SelectedIndex = $tabControl.TabCount - 1
        $tabControl.Focus() # move focus out of single-line field to see the placeholder text
        Update-Config
    })

    # Delete Lab button click event
    $removeLabButton.Add_Click({
        if ($tabControl.TabCount -gt 0) {
            $currentTabName = $tabControl.SelectedTab.Text
            $result = [System.Windows.Forms.MessageBox]::Show(
                "Are you sure you want to remove '$currentTabName'?",
                "Confirm Remove",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question)

            if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
                $tabControl.TabPages.RemoveAt($tabControl.SelectedIndex)
                Update-Config
            }
        }
    })

    # Save button click event
    $saveNamesButton.Add_Click({
        Update-Config
        $config | ConvertTo-Json -Depth 3 | Set-Content -Path $configPath -Encoding UTF8
        [System.Windows.Forms.MessageBox]::Show(
            "LabPc Names saved!",
            "Success",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information)
    })

    # Tab selection change event
    $tabControl.Add_Selected({ # fires after tab change
        # Remove Icon from the previuos selected tab if exist
        if ($tabControl.TabPages[[Int32]$config.LastSelectedLab]) {
            $tabControl.TabPages[[Int32]$config.LastSelectedLab].ImageIndex = -1
        }

        # Add the icon for the new selected tab
        if ($tabControl.SelectedTab) {
            $tabControl.SelectedTab.ImageIndex = 0
        }

        Update-Config
    })

    # Form closing event - save configuration
    $form.Add_FormClosing({
        Update-Config
        $config | ConvertTo-Json -Depth 3 | Set-Content -Path $configPath -Encoding UTF8
    })

    # Display tabs saved in config
    if ($config -and $config.Labs) {
        foreach ($tab in $config.Labs) {
            Add-NewTab -tabName $tab.Name -textContent ($tab.PcNames -join ', ')
        }

        # Restore last selected tab
        $tabControl.SelectedIndex = $config.LastSelectedLab

        # Add the icon for the new selected tab
        $tabControl.TabPages[[Int32]$config.LastSelectedLab].ImageIndex = 0
    }

    # Show the form
    $form.ShowDialog()
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

    Test-NoLabPcName
    foreach ($pc in $currentlab.PcNames) {
        try {
            Test-WSMan -ComputerName $pc -ErrorAction Stop | Out-Null
            Write-Terminal -Text "$pc", "ready" -ForegroundColor DarkYellow, DarkGreen
        }
        catch [System.InvalidOperationException] {
            Write-Terminal -Text "$pc", "off or not ready" -ForegroundColor DarkYellow, DarkRed 
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

    Test-NoLabPcName

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

        $results = Invoke-Command -ComputerName $currentLab.PcNames -ScriptBlock {
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
        foreach ($pc in $currentlab.PcNames) {
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

    Test-NoLabPcName
    Write-Terminal -Text "Remember, Start-LabPc works only if the LabPCs support WoL (Wake-on-LAN)." -ForegroundColor DarkYellow

    # Send Magic Packet over LAN
    for ($i = 0; $i -lt $currentlab.PcNames.Count; $i++) {
        $PcName = $currentlab.PcNames[$i]
        $Mac = $currentlab.PcMacs[$i]
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

    Test-NoLabPcName
    $results = Invoke-command -ComputerName $currentlab.PcNames -ScriptBlock {
        Stop-Computer  -ComputerName $env:COMPUTERNAME -Force -ErrorAction SilentlyContinue
        [PSCustomObject]@{
            ComputerName = $env:COMPUTERNAME
        }
    } -ErrorAction SilentlyContinue

    # Show results
    foreach ($pc in $currentlab.PcNames) {
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

    Test-NoLabPcName
    $results = Invoke-Command -ComputerName $currentLab.PcNames -ScriptBlock {
        Restart-Computer -ComputerName $env:COMPUTERNAME -Force -ErrorAction SilentlyContinue
        [PSCustomObject]@{
            ComputerName = $env:COMPUTERNAME
        }
    } -ErrorAction SilentlyContinue

    # Show results
    foreach ($pc in $currentLab.PcNames) {
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

    Test-NoLabPcName
    $results = Invoke-Command -ComputerName $currentLab.PcNames -ScriptBlock {
        $ErrorActionPreference = 'Stop' # NOTE: it is valid only for this function scope
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
                # Write-Host -Text "User", ($_ -split "\s+")[1], "logged out $($env:COMPUTERNAME)" -ForegroundColor Green
                [PSCustomObject]@{
                    ComputerName = $env:COMPUTERNAME
                    UserName = ($_ -split "\s+")[1]
                    quserExisted = $true
                }
            }
        }
        catch [System.Management.Automation.CommandNotFoundException] {
            # Write-Host -Text "Cannot disconnect any user: quser command not found on $env:computername" -ForegroundColor Red
            # Write-Host -Text "is it a windows Home edition?"
            [PSCustomObject]@{
                ComputerName = $env:COMPUTERNAME
                quserExisted = $false
            }
        }
        catch {
            # Write-Host -Text "No user logged in $($env:COMPUTERNAME)" -ForegroundColor Yellow
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

    foreach ($pc in $currentlab.PcNames) {
        if ($pc -notin $results.ComputerName) {
            Write-Terminal -Text "$pc", "offline", "(off or not ready)" -ForegroundColor DarkYellow, DarkRed, Yellow
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

    Test-NoLabPcName
    Invoke-Command -ComputerName $currentLab.PcNames -ScriptBlock {
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

    Test-NoLabPcName
    Invoke-Command -ComputerName $currentLab.PcNames -ScriptBlock {
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

    Test-NoLabPcName
    switch ($PSCmdlet.ParameterSetName) {
        'Set0' {$password = $null
                if ($SetPassword.IsPresent) {
                    # Prompt and read new password
                    $password = Read-Host -Prompt 'Enter the new password' -AsSecureString
                }
                Invoke-Command -ComputerName $currentlab.PcNames  -ScriptBlock {
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