<#
.SYNOPSIS
    This script partitions the disk and applies a WIM or SWM files and sets recovery.

    // *************
    // *  CAUTION  *
    // *************

    Please review this script THOROUGHLY before applying, and disable changes below as necessary to suit your current environment.

    This script is provided AS-IS - usage of this source assumes that you are at the very least familiar with PowerShell, and the
    tools used to create and debug this script.

    In other words, if you break it, you get to keep the pieces.
    
.NOTES
    Author:       Microsoft
    Last Update:  6th May 2020
    Version:      1.1.0

    Version 1.1.0
    - Added support for running in a VM
    - Added support for running from an ISO or other read-only media

    Version 1.0.0
    - Initial release
#>


cls

Function New-RegKey
{
    param($key)
  
    $key = $key -replace ':',''
    $parts = $key -split '\\'
  
    $tempkey = ''
    $parts | ForEach-Object {
        $tempkey += ($_ + "\")
        if ( (Test-Path "Registry::$tempkey") -eq $false)  {
        New-Item "Registry::$tempkey" | Out-Null
        }
    }
}



Function ClearTPM
{
    $TPM = Get-WmiObject -Class "Win32_Tpm" -Namespace "ROOT\CIMV2\Security\MicrosoftTpm"

    Write-Output "Clearing TPM ownership....."
    $ClearRequest = $TPM.SetPhysicalPresenceRequest(14) | Out-Null
    If ($ClearRequest.ReturnValue -eq 0)
    {
        Write-Output "Successfully cleared the TPM chip. A reboot is required."
        Write-Output ""
    }
    Else
    {
        Write-Warning "Failed to clear TPM ownership..."
        Write-Output ""
    }
}



Function EnableBitlocker
{
    # Configure Bitlocker for XTS-AES 256Bit Encryption
    $FVERegKey = "HKLM:\SOFTWARE\Policies\Microsoft\FVE"
    New-RegKey $FVERegKey

    $EncryptionMethodWithXtsOsRegValue = Get-ItemProperty $FVERegKey EncryptionMethodWithXtsOs -ErrorAction SilentlyContinue
    $EncryptionMethodWithXtsFdvRegValue = Get-ItemProperty $FVERegKey EncryptionMethodWithXtsFdv -ErrorAction SilentlyContinue
    $OSEncryptionTypeRegValue = Get-ItemProperty $FVERegKey OSEncryptionType -ErrorAction SilentlyContinue

    If ($EncryptionMethodWithXtsOsRegValue -eq $null)
    {
        New-ItemProperty -Path $FVERegKey -Name EncryptionMethodWithXtsOs -PropertyType DWORD -Value 7 | Out-Null
    }
    Else
    {
        Set-ItemProperty -Path $FVERegKey -Name EncryptionMethodWithXtsOs -Value 7
    }

    If ($EncryptionMethodWithXtsFdvRegValue -eq $null)
    {
        New-ItemProperty -Path $FVERegKey -Name EncryptionMethodWithXtsFdv -PropertyType DWORD -Value 7 | Out-Null
    }
    Else
    {
        Set-ItemProperty -Path $FVERegKey -Name EncryptionMethodWithXtsFdv -Value 7
    }

    If ($OSEncryptionTypeRegValue -eq $null)
    {
        New-ItemProperty -Path $FVERegKey -Name OSEncryptionType -PropertyType DWORD -Value 1 | Out-Null
    }
    Else
    {
        Set-ItemProperty -Path $FVERegKey -Name OSEncryptionType -Value 1
    }
}



Function Clear-StoragePool
{
    $Pools = Get-StoragePool -IsPrimordial $false -ErrorAction SilentlyContinue
    If ($Pools)
    {
        Write-Output "Clearing storage pool: $($Pools.FriendlyName)"
        $Pools | Get-VirtualDisk | Remove-VirtualDisk -Confirm:$false
        $Pools | Remove-StoragePool -Confirm:$false
    }
}



Function Enable-SpacesBootSimple
{
    param(
        [Parameter (Mandatory=$false, Position=0)]
        [string] $DiskNumber
    )
    try
    {
        $PhysicalDisks = @(Get-PhysicalDisk | Where-Object { $_.BusType -ne "USB" -and $_.CanPool -eq $true })

        Write-Output "Creating Storage Pool with $($PhysicalDisks.Count) disks"
        $Pool = New-StoragePool -FriendlyName "Boot" -StorageSubsystemFriendlyName * -PhysicalDisks $PhysicalDisks
        
        Write-Output "Creating Virtual Disk"
        $VirtualDisk = New-VirtualDisk -FriendlyName Boot -StoragePoolFriendlyName $Pool.FriendlyName -UseMaximumSize -ResiliencySettingName Simple -WriteCacheSize 0

        Write-Output "Boot Storage Space created"
        
        $Disks = Get-Disk | Where-Object { $_.BusType -ne "USB" }
        ForEach ($Disk in $Disks)
        {
            If ($Disk.Model -eq "Storage Space")
            {
                $Size = $Disk.Size /1GB
                $Index = $Disk.Number
                $Name = $Disk.FriendlyName
                $Type = $Disk.BusType
                $Serial = $Disk.SerialNumber

                Write-Output "Chosen installation disk:"
                Write-Output "Disk Index:  $Index"
                Write-Output "Disk Name:   $Name"
                Write-Output "Disk Serial: $Serial"
                Write-Output "Disk Type:   $Type"
                Write-Output "Disk Size:   $Size"

                $DiskIndex = "$Index"
            }
        }
    }
    catch
    {
        $_ | Format-List -Force
        "ERROR enabling Storage Space!!!"
        Clear-StoragePool
        Exit
    }
}



Function Get-DiskIndex
{
    # Set Disk to image to
    Update-StorageProviderCache -DiscoveryLevel Full | Out-Null

    $SystemInformation = Get-WmiObject -Namespace root\wmi -Class MS_SystemInformation
    $Product = $SystemInformation.SystemSKU
    $Disks = Get-Disk | Where-Object { $_.BusType -ne "USB"}

    If ($Disks.Length -gt 1)
    {
        $Disks = Get-Disk | Where-Object { $_.BusType -ne "USB" -and $_.CanPool -eq $true }
        If ($Disks.Length -gt 1)
        {
            Enable-SpacesBootSimple
        }
    }

    If ($Product -like "Surface_Studio*")
    {
        ForEach ($Disk in $Disks)
        {
            # Everything seems ok here, even if RST is broken...
            If (($Disk.BusType -eq "RAID") -and ($Disk.Number -eq "0"))
            {
                $Size = $Disk.Size /1GB
                $Index = $Disk.Number
                $Name = $Disk.FriendlyName
                $Type = $Disk.BusType
                $Serial = $Disk.SerialNumber

                $DiskIndex = $Index

            }
        
            # Perhaps booted from disk 0 where it's not the RST - find the non-cache drive (will be >64 or 128GB depending on SKU)
            # No USB drives, and no drives smaller than 128GB should give us the proper RST mechanical disk:
            ElseIf (($Disk.BusType -ne "USB") -and ($Disk.Size -gt "130000000000"))
            {
                $Size = $Disk.Size /1GB
                $Index = $Disk.Number
                $Name = $Disk.FriendlyName
                $Type = $Disk.BusType
                $Serial = $Disk.SerialNumber

                $DiskIndex = $Index
            }
        }
    }
    ElseIf (($Product -like "Surface_Pro*") -or ($Product -like "Surface_Laptop*"))
    {
        ForEach ($Disk in $Disks)
        {
            If ($Disk.Model -like "*Storage Space*")
            {
                $Size = $Disk.Size /1GB
                $Index = $Disk.Number
                $Name = $Disk.FriendlyName
                $Type = $Disk.BusType
                $Serial = $Disk.SerialNumber

                $DiskIndex = $Index
            }
        }
    }
    Else
    {
        $DiskIndex = $Disks.Number
    }


    If (!($DiskIndex))
    {
        $DiskIndex = "0"
    }

    Return $DiskIndex
}

Function Rename-Computer-From-XML
{
    Param(
        $serialNumber,
		$XMLDeviceList
    )
	
	$pathToUnattendXML = "W:\Windows\System32\Sysprep\unattend.xml"
	If ($XMLDeviceList -ne "NoList")
	{
		$xml = New-Object XML
		$xml = [xml](Get-Content $XMLDeviceList)
		$getNameFromXML = $xml.Surface.device
		
		$newName =""
		foreach($device in $getNameFromXML)
		{
			if($serialNumber -eq $device.serial )
			{
				$newName = $device.name
				Write-Output "Found matching serial in XML!"
				Break
			}
		}
		
		if($newName -ne "")
		{
			Write-Output "Renaming machine to: $newName"
			(Get-Content  $pathToUnattendXML | ForEach { $_ -replace "%MACHINENAME%", $newName }) | out-file $pathToUnattendXML -Encoding Default
			Rename-Computer -NewName $newName -force
		}
		
		Else
		{
			(Get-Content  $pathToUnattendXML | ForEach { $_ -replace "%MACHINENAME%", "" }) | out-file $pathToUnattendXML -Encoding Default
			Write-Output "Did not find $serialNumber in XML-file. No rename"
		}
	}
	Else
	{
		(Get-Content  $pathToUnattendXML | ForEach { $_ -replace "%MACHINENAME%", "" }) | out-file $pathToUnattendXML -Encoding Default
		Write-Output "Did not find XML-file. Getting random name."
	}

}

Function Get-Which-Surface
{
	$SystemInformation = Get-WmiObject -Namespace root\wmi -Class MS_SystemInformation
    $Product = $SystemInformation.SystemSKU
	
	If ($Product -eq "Surface_Pro_4")
	{
		$ProductSKU = "SurfacePro4"
	}
	ElseIf (($Product -eq "Surface_Pro_1796") -or ($Product -eq "Surface_Pro_1807"))
	{
		$ProductSKU = "SurfacePro5"
	}
	
	ElseIf ($Product -like "Surface_Pro_6_*")
	{
		$ProductSKU = "SurfacePro6"
	}
	ElseIf ($Product -like "Surface_3")
	{
		$ProductSKU = "SurfacePro3"
	}
	Else
	{
		$ProductSKU = "Generic"
	}
	
	return $ProductSKU
}

###########################
# Begin script processing #
###########################

If ($ENV:PROCESSOR_ARCHITECTURE -eq 'ARM64')
{
    try
    {
        # Replace with a custom Get-Volume for use with pwsh.exe
        Import-Module X:\windows\System32\WindowsPowershell\v1.0\Modules\Storage\Storage.psd1
    }
    catch {}
}

If ($ExecutionContext.SessionState.LanguageMode -eq "FullLanguage")
{
    # This can probably be reverted as new devices come along, but red on DarkBlue is unreadable on current devices
    $host.UI.RawUI.BackgroundColor = "Black"
    $Host.UI.RawUI.ForegroundColor = "White"
    $host.UI.RawUI.WindowTitle = "$(Get-Location)"
}

$scriptPath = Split-Path -parent $MyInvocation.MyCommand.Definition



Write-Output "********************"
Write-Output "  OS IMAGE INSTALL  "
Write-Output "********************"

$UEFIVer = ($(& wmic bios get SMBIOSBIOSVersion /format:table)[2])
Write-Output "- UEFI Information: $UEFIVer"
Write-Output ""
Write-Output "- WinPE Information"
$RegPath = "Registry::HKEY_LOCAL_MACHINE\Software"
$WinPEVersion = ""

$CurrentVersion = Get-ItemProperty -Path "$RegPath\Microsoft\Surface\OSImage" -ErrorAction SilentlyContinue
If ($CurrentVersion)
{
    try
    {
        Write-Output "   - ImageName        $($CurrentVersion.ImageName)"
        $WinPEVersion = $($CurrentVersion.ImageName)
    }
    catch {}
    try
    {
        Write-Output "   - RebasedImageName $($CurrentVersion.RebasedImageName)"
    }
    catch {}
}

$NTCurrentVersion = Get-ItemProperty -Path "$RegPath\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue
If ($NTCurrentVersion)
{
    try
    {
        Write-Output "   - BuildLab         $($NTCurrentVersion.BuildLab)"
        Write-Output "   - BuildLabEx       $($NTCurrentVersion.BuildLabEx)"
        Write-Output "   - ProductName      $($NTCurrentVersion.ProductName)"
    }
    catch {}
}

Write-Output ""
Write-Output "- Hardware Information"
$SystemInformation = (Get-WmiObject -Namespace root\wmi -Class MS_SystemInformation)
$Serialnumber	= (Get-WmiObject -Query "Select * from Win32_Bios")
$ProductSKU = Get-Which-Surface

If ($SystemInformation)
{
    try
    {
        Write-Output "   - Manufacturer     $($SystemInformation.BaseBoardManufacturer)"
        Write-Output "   - Product          $($SystemInformation.BaseBoardProduct)"
        Write-Output "   - SystemSKU        $($SystemInformation.SystemSKU)"
        Write-Output "   - Model            $ProductSKU"
        Write-Output "   - SerialNumber     $($Serialnumber.SerialNumber)"
    }
    catch {}
}


Write-Output ""
Write-Output ""



# Make sure we have valid diskpart scripts and installation WIM/SWMs located before we go further
$diskpart = "$env:windir\System32\diskpart.exe"
$managebde = "$env:windir\System32\manage-bde.exe"
$bcdboot = "$env:windir\System32\bcdboot.exe"

$RamDrive = (Get-Location).Drive.Name
$DriveLetter = $RamDrive + ":\"
$SourceDrive = Get-ChildItem -Path "$DriveLetter" -Recurse | Where-Object { $_.Name -eq "Imaging.ps1" }

If ($SourceDrive)
{
    $Folder = Get-ChildItem -Path "$DriveLetter" -Recurse | Where-Object { $_.PSIsContainer -and $_.Name -like "Sources*" }
    $DiskPartScript = Get-ChildItem -Path "X:\" -Recurse | Where-Object { $_.Name -eq "CreatePartitions-UEFI.txt" }
    $DiskPartScriptSource = Get-ChildItem -Path "X:\" -Recurse | Where-Object { $_.Name -eq "CreatePartitions-UEFI_Source.txt" }
    If ($DiskPartScript)
    {
        $DiskPartScriptPath = $DiskPartScript.FullName
        $DiskPartScriptSourcePath = $DiskPartScriptSource.FullName
    }
}

Write-Output "Finding all attached drives with recognized filesystems..."
Write-Output ""
$Drives = Get-PSDrive | Where-Object { $_.Provider -like "*FileSystem*" }
If (!($Drives))
{
    Write-Output "No drives found, exiting."
    Write-Output ""
    Exit
}
Else
{
    Write-Output "Drives Found:"
    $Drives
    Write-Output ""
    Write-Output ""
    $WIMFound = $false
}

ForEach ($Drive in $Drives)
{
    $TempDrive = $Drive.Root
    Write-Output "Checking drive $TempDrive for XML with names..."
	$XMLDeviceList = Get-ChildItem -Path $TempDrive -Recurse | Where-Object { $_.Name -like "*surface_devices*.xml" }
	If ($XMLDeviceList)
    {
		$XMLDeviceList = $XMLDeviceList.FullName
        Write-Output "Found file $XMLDeviceList"
        Write-Output ""
		Break
	}
	Else 
	{
		Write-Output "Could not find any interesting XML files in $TempDrive, continuing..."
	}
}

ForEach ($Drive in $Drives)
{
    $TempDrive = $Drive.Root
    Write-Output "Checking drive $TempDrive for WIM/SWM files..."

    $WIMFile = Get-ChildItem -Path $TempDrive -Recurse | Where-Object { $_.Name -like "*$ProductSKU*install*.wim" }
    $SWMFile = Get-ChildItem -Path $TempDrive -Recurse | Where-Object { $_.Name -like "*$ProductSKU*install*--Split.swm" }
	
    If ($WIMFile)
    {
        $WIMFound = $true
        $WIMFilePath = $WIMFile.FullName
        Write-Output "Found file $WIMFilePath"
        Write-Output ""
        Break
    }
    ElseIf ($SWMFile)
    {
        $WIMFound = $true
        $SplitWIM = $true
        $SWMFilePath = $SWMFile.FullName
        Write-Output "Found file $SWMFilePath"
        Write-Output ""
        $SWMFilePattern = $SWMFile.DirectoryName + "\" + $SWMFile.BaseName + '*.swm'
        Break
    }
    Else
    {
        Write-Output "Could not find any WIM files in $TempDrive, continuing..."
        Write-Output ""
    }
}

If ($WIMFound -eq $false)
{
    Write-Output "WIM/SWM file(s) not found.  Exiting..."
    Write-Output ""
    Write-Output "WIMFound:  $WIMFound"
    Write-Output ""
    Exit
}


# Configure installation disk
$Result = Get-DiskIndex
Write-Output "Configuring disk $Result for imaging..."
Clear-Content -Path $DiskPartScriptPath
Add-Content -Path $DiskPartScriptPath -Value "select disk $Result"
Get-Content -Path $DiskPartScriptSourcePath | Add-Content -Path $DiskPartScriptPath
& $diskpart /s $DiskPartScriptPath


# Enable Bitlocker
If ("$($SystemInformation.Family)" -like "*Virtual*")
{
    # VM, don't try to clear TPM
}
Else
{
    ClearTpm
    Start-Sleep 2
    Write-Output "Enabling XTS-AES 256Bit Bitlocker encryption"
    EnableBitlocker
    & $managebde -on W: -UsedSpaceOnly
    Write-Output ""
    Write-Output ""
}


# Apply image
If ($SplitWIM -eq $true)
{
    Write-Output "Applying WIM $SWMFilePath using pattern $SWMFilePattern to W: ..."
    Expand-WindowsImage -ImagePath $SWMFilePath -SplitImageFilePattern $SWMFilePattern -ApplyPath "W:" -Index 1
    Write-Output ""
}
Else
{
    Write-Output "Applying WIM $WIMFilePath to W: ..."
    Expand-WindowsImage -ImagePath $WIMFilePath -ApplyPath "W:" -Index 1
    Write-Output ""
}


# Set System partition bootable
Write-Output "Marking system partition bootable..."
& $bcdboot W:\Windows /s S:
Write-Output ""


# Configure recovery
Write-Output "Configuring recovery..."
$RecoveryPath = "T:\Recovery"
$WinREPath = "T:\Recovery\WindowsRE"
$WinREWIM = "T:\Recovery\WindowsRE\WinRE.wim"
If (!(Test-Path "$RecoveryPath"))
{
    New-Item -Path "$RecoveryPath" -ItemType "directory" | Out-Null
}

If (!(Test-Path "$WinREPath"))
{
    New-Item -Path "$WinREPath" -ItemType "directory" | Out-Null
}

Write-Output "Copying W:\Windows\System32\Recovery\WinRE.WIM to $WinREPath..."
Copy-Item -Path "W:\Windows\System32\Recovery\WinRE.wim" -Destination $WinREPath
$reagentc = "W:\Windows\System32\reagentc.exe"
& $reagentc /setreimage /path $WinREWIM /target W:\Windows
Write-Output ""
Sleep 2

If ($XMLDeviceList)
{
	Rename-Computer-From-XML $Serialnumber.SerialNumber $XMLDeviceList
}

Else
{
	$XMLDeviceList = "NoList"
	Rename-Computer-From-XML $Serialnumber.SerialNumber $XMLDeviceList
}

Start-Sleep -s 30
Restart-Computer -Force
Exit

