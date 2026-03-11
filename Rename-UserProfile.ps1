<#
.SYNOPSIS
Automates a safe local Windows profile folder rename across three phases.

.DESCRIPTION
This script prepares a temporary administrator account, renames the target
profile folder while the target user is logged off, updates the profile path in
HKLM, and repairs the target user's shell-folder registry values inside
NTUSER.DAT so applications do not keep using the old profile path.

Windows still requires a second account for the actual rename because the
profile being renamed cannot be in use. The script therefore runs in:
1. Setup phase as the original account.
2. Rename phase as the temporary admin account.
3. Finalize phase as the renamed account.

The dedicated cleanup script Remove-TempAdminArtifacts.ps1 is copied to the
Public Desktop and can also be run directly from C:\Tools.
#>

[CmdletBinding()]
param(
    [string]$AccountName = 'Example.LocalUser',
    [string]$OldFolder = 'old.profile',
    [string]$NewFolder = 'new.profile',
    [string]$TempAdmin = 'TempAdmin',
    [string]$TempPass = '',
    [string]$ToolsRoot = '',
    [switch]$CreateCompatibilityJunction
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ToolsRoot)) {
    $ToolsRoot = Split-Path -Parent $PSCommandPath
}

$OldPath = "C:\Users\$OldFolder"
$NewPath = "C:\Users\$NewFolder"
$BackupDir = Join-Path $ToolsRoot 'ProfileBackup'
$CleanupScriptPath = Join-Path $ToolsRoot 'Remove-TempAdminArtifacts.ps1'
$PublicDesktop = 'C:\Users\Public\Desktop'
$PublicRenameScript = Join-Path $PublicDesktop 'Rename-UserProfile.ps1'
$PublicCleanupScript = Join-Path $PublicDesktop 'Remove-TempAdminArtifacts.ps1'
$StateFile = Join-Path $BackupDir 'RenameUserProfile_State.json'
$ScriptPath = $PSCommandPath
$TargetHiveName = 'RenameTargetProfile'
$TargetHiveRoot = "Registry::HKEY_USERS\$TargetHiveName"
$WinlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$UserSwitchPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\UserSwitch'

function Write-Section {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Test-IsAdministrator {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Invoke-RegExport {
    param(
        [string]$Key,
        [string]$Destination
    )

    $null = & reg.exe export $Key $Destination /y 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Backed up $Key to $Destination" -ForegroundColor DarkGray
    } else {
        Write-Host "Warning: could not back up $Key" -ForegroundColor Yellow
    }
}

function New-RandomTemporaryPassword {
    param([int]$Length = 20)

    $characters = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%^&*()-_=+[]{}'
    $bytes = New-Object byte[] $Length
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }

    $passwordChars = for ($i = 0; $i -lt $Length; $i++) {
        $characters[$bytes[$i] % $characters.Length]
    }

    return -join $passwordChars
}

function Get-TargetUserSid {
    try {
        return (New-Object System.Security.Principal.NTAccount($AccountName)).Translate(
            [System.Security.Principal.SecurityIdentifier]
        ).Value
    } catch {
        throw "Could not resolve SID for account '$AccountName'."
    }
}

function Test-ProfileRenameComplete {
    param([string]$Sid)

    $profileListPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid"
    $profileImagePath = Get-ItemPropertyValue -Path $profileListPath -Name 'ProfileImagePath' -ErrorAction SilentlyContinue
    return ($profileImagePath -eq $NewPath) -and (Test-Path -LiteralPath $NewPath)
}

function Convert-ProfilePathValue {
    param(
        [AllowNull()][string]$Value,
        [string]$SourcePath,
        [string]$DestinationPath
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }

    $pattern = '^{0}(?=\\|$)' -f [regex]::Escape($SourcePath)
    if ($Value -imatch $pattern) {
        return [regex]::Replace($Value, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $DestinationPath
        }, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }

    return $Value
}

function Update-RegistryValues {
    param(
        [string]$RegistryPath,
        [string]$SourcePath,
        [string]$DestinationPath
    )

    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        return 0
    }

    $item = Get-ItemProperty -Path $RegistryPath
    $updated = 0

    foreach ($property in $item.PSObject.Properties) {
        if ($property.Name -in 'PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider') {
            continue
        }

        if ($property.Value -isnot [string]) {
            continue
        }

        $newValue = Convert-ProfilePathValue -Value $property.Value -SourcePath $SourcePath -DestinationPath $DestinationPath
        if ($newValue -ne $property.Value) {
            Set-ItemProperty -Path $RegistryPath -Name $property.Name -Value $newValue
            Write-Host "Updated $RegistryPath -> $($property.Name)" -ForegroundColor Green
            $updated++
        }
    }

    return $updated
}

function Repair-ProfileRegistryPaths {
    param(
        [string]$RegistryRoot,
        [string]$SourcePath,
        [string]$DestinationPath
    )

    $paths = @(
        (Join-Path $RegistryRoot 'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'),
        (Join-Path $RegistryRoot 'Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'),
        (Join-Path $RegistryRoot 'Environment')
    )

    $total = 0
    foreach ($path in $paths) {
        $total += Update-RegistryValues -RegistryPath $path -SourcePath $SourcePath -DestinationPath $DestinationPath
    }

    return $total
}

function Mount-TargetHive {
    param([string]$ProfileRoot)

    $ntUserPath = Join-Path $ProfileRoot 'NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $ntUserPath)) {
        throw "Cannot find NTUSER.DAT at $ntUserPath"
    }

    & reg.exe unload "HKU\$TargetHiveName" 2>$null | Out-Null
    & reg.exe load "HKU\$TargetHiveName" $ntUserPath | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to load target hive from $ntUserPath"
    }
}

function Dismount-TargetHive {
    & reg.exe unload "HKU\$TargetHiveName" 2>$null | Out-Null
}

function Copy-AutomationScripts {
    Ensure-Directory -Path $PublicDesktop

    if ($ScriptPath -and (Test-Path -LiteralPath $ScriptPath)) {
        Copy-Item -Path $ScriptPath -Destination $PublicRenameScript -Force
        Write-Host "Copied rename script to $PublicRenameScript" -ForegroundColor DarkGray
    }

    if (Test-Path -LiteralPath $CleanupScriptPath) {
        Copy-Item -Path $CleanupScriptPath -Destination $PublicCleanupScript -Force
        Write-Host "Copied cleanup script to $PublicCleanupScript" -ForegroundColor DarkGray
    } else {
        Write-Host "Warning: cleanup script not found at $CleanupScriptPath" -ForegroundColor Yellow
    }
}

$ResolvedTempPass = $TempPass
$TempPassWasGenerated = $false
$TempAdminCreated = $false
if ([string]::IsNullOrWhiteSpace($ResolvedTempPass)) {
    $ResolvedTempPass = New-RandomTemporaryPassword
    $TempPassWasGenerated = $true
}

function Ensure-TempAdminAccount {
    $tempUser = Get-LocalUser -Name $TempAdmin -ErrorAction SilentlyContinue
    if ($tempUser) {
        $script:TempAdminCreated = $false
        Write-Host "Temporary admin '$TempAdmin' already exists." -ForegroundColor DarkGray
        return
    }

    $securePass = ConvertTo-SecureString $ResolvedTempPass -AsPlainText -Force
    New-LocalUser -Name $TempAdmin -Password $securePass -FullName 'Temp Rename Admin' `
        -Description 'Temporary administrator for profile rename automation' -PasswordNeverExpires | Out-Null
    Add-LocalGroupMember -Group 'Administrators' -Member $TempAdmin | Out-Null
    $script:TempAdminCreated = $true
    Write-Host "Created temporary admin '$TempAdmin'." -ForegroundColor Green
}

function Disable-AutoAdminLogon {
    $state = [ordered]@{
        AutoAdminLogon = (Get-ItemProperty -Path $WinlogonPath -Name AutoAdminLogon -ErrorAction SilentlyContinue).AutoAdminLogon
        UserSwitchEnabled = (Get-ItemProperty -Path $UserSwitchPath -Name Enabled -ErrorAction SilentlyContinue).Enabled
    }
    $state | ConvertTo-Json | Set-Content -Path $StateFile -Encoding ASCII

    Set-ItemProperty -Path $WinlogonPath -Name AutoAdminLogon -Value '0' -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $UserSwitchPath -Name Enabled -Value 1 -ErrorAction SilentlyContinue
}

function Restore-AutoAdminLogon {
    if (-not (Test-Path -LiteralPath $StateFile)) {
        return
    }

    $state = Get-Content -Path $StateFile -Raw | ConvertFrom-Json
    if ($null -ne $state.AutoAdminLogon) {
        Set-ItemProperty -Path $WinlogonPath -Name AutoAdminLogon -Value ([string]$state.AutoAdminLogon) -ErrorAction SilentlyContinue
    }
    if ($null -ne $state.UserSwitchEnabled) {
        Set-ItemProperty -Path $UserSwitchPath -Name Enabled -Value ([int]$state.UserSwitchEnabled) -ErrorAction SilentlyContinue
    }
}

function Invoke-CleanupScript {
    if (-not (Test-Path -LiteralPath $CleanupScriptPath)) {
        Write-Host "Cleanup script missing: $CleanupScriptPath" -ForegroundColor Yellow
        return
    }

    Write-Section 'Running TempAdmin cleanup'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $CleanupScriptPath `
        -TempAdmin $TempAdmin
}

if (-not (Test-IsAdministrator)) {
    Write-Host 'This script requires Administrator privileges.' -ForegroundColor Red
    exit 1
}

$targetSid = Get-TargetUserSid
$renameCompleted = Test-ProfileRenameComplete -Sid $targetSid

if ($renameCompleted -and $env:USERNAME -ieq $AccountName) {
    Write-Section 'Phase 3 - Finalize'
    Write-Host "Profile folder already points to $NewPath" -ForegroundColor Green

    $fixedCount = Repair-ProfileRegistryPaths -RegistryRoot 'HKCU:' -SourcePath $OldPath -DestinationPath $NewPath
    Write-Host "Final registry normalization updated $fixedCount values in HKCU." -ForegroundColor Green

    if ($CreateCompatibilityJunction -and -not (Test-Path -LiteralPath $OldPath)) {
        cmd.exe /c "mklink /J `"$OldPath`" `"$NewPath`"" | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Created compatibility junction $OldPath -> $NewPath" -ForegroundColor Green
        }
    }

    Invoke-CleanupScript

    Restore-AutoAdminLogon
    if (Test-Path -LiteralPath $PublicRenameScript) {
        Remove-Item -Path $PublicRenameScript -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $StateFile) {
        Remove-Item -Path $StateFile -Force -ErrorAction SilentlyContinue
    }

    Write-Host 'Finalize phase complete.' -ForegroundColor Green
    exit 0
}

if ($env:USERNAME -ieq $AccountName) {
    Write-Section 'Phase 1 - Setup'
    Ensure-Directory -Path $BackupDir

    Write-Host 'Creating restore point (best effort)...' -ForegroundColor DarkGray
    Checkpoint-Computer -Description "Pre_UserFolderRename_$AccountName" -RestorePointType 'MODIFY_SETTINGS' -ErrorAction SilentlyContinue

    Invoke-RegExport -Key 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -Destination (Join-Path $BackupDir 'ProfileList_Backup.reg')
    Invoke-RegExport -Key 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -Destination (Join-Path $BackupDir 'UserShellFolders_Backup.reg')
    Invoke-RegExport -Key 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders' -Destination (Join-Path $BackupDir 'ShellFolders_Backup.reg')

    Ensure-TempAdminAccount
    Disable-AutoAdminLogon
    Copy-AutomationScripts

    Write-Host ''
    Write-Host 'Temporary administrator credentials:' -ForegroundColor Yellow
    Write-Host "  Username: $TempAdmin" -ForegroundColor Yellow
    if (-not $TempAdminCreated) {
        Write-Host '  Existing TempAdmin account reused. Use its current password.' -ForegroundColor Yellow
    } elseif ($TempPassWasGenerated) {
        Write-Host "  Generated password: $ResolvedTempPass" -ForegroundColor Yellow
        Write-Host '  Save it securely. It is generated at runtime and not stored in the script.' -ForegroundColor Yellow
    } else {
        Write-Host '  Password: use the value supplied with -TempPass.' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host "Next step: sign out, log in as '$TempAdmin', and run $PublicRenameScript" -ForegroundColor Yellow
    exit 0
}

if ($env:USERNAME -ieq $TempAdmin) {
    Write-Section 'Phase 2 - Rename'

    $profileListPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$targetSid"

    if (Test-Path -LiteralPath $OldPath) {
        Write-Host "Renaming $OldPath to $NewPath" -ForegroundColor DarkGray
        Rename-Item -Path $OldPath -NewName $NewFolder
        Write-Host 'Profile folder renamed successfully.' -ForegroundColor Green
    } elseif (Test-Path -LiteralPath $NewPath) {
        Write-Host "Profile folder already exists at $NewPath" -ForegroundColor Yellow
    } else {
        throw "Neither $OldPath nor $NewPath exists."
    }

    Set-ItemProperty -Path $profileListPath -Name 'ProfileImagePath' -Value $NewPath
    Write-Host 'Updated ProfileImagePath in HKLM ProfileList.' -ForegroundColor Green

    $updatedCount = 0
    try {
        Mount-TargetHive -ProfileRoot $NewPath
        $updatedCount = Repair-ProfileRegistryPaths -RegistryRoot $TargetHiveRoot -SourcePath $OldPath -DestinationPath $NewPath
    } finally {
        Dismount-TargetHive
    }

    Write-Host "Normalized $updatedCount registry values inside NTUSER.DAT." -ForegroundColor Green

    Copy-AutomationScripts

    Write-Host ''
    Write-Host 'Rename phase complete.' -ForegroundColor Green
    Write-Host "Next step: sign out, log back in as '$AccountName', and run $PublicRenameScript" -ForegroundColor Yellow
    Write-Host 'That final run will normalize HKCU one more time and launch the TempAdmin cleanup script.' -ForegroundColor Yellow
    exit 0
}

Write-Host "Unexpected state. Current user: $env:USERNAME" -ForegroundColor Red
Write-Host "Run this script as '$AccountName' for setup/finalize or as '$TempAdmin' for the rename phase." -ForegroundColor Yellow
exit 1
