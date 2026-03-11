# User Profile Rename Automation

This folder contains PowerShell automation for renaming a local Windows user
profile folder and cleaning up the temporary administrator account used during
the process.

## Files

- `Rename-UserProfile.ps1`
  Three-phase workflow for preparing the rename, performing the folder rename
  from a temporary admin account, and finalizing the renamed profile.
- `Remove-TempAdminArtifacts.ps1`
  Cleanup script for removing the temporary admin account, its profile data, and
  common registry leftovers such as `ProfileList`, Group Policy cache, and
  Windows Search references.
- `ProfileBackup\`
  Backup output created by the scripts during execution.

## What the rename script fixes

The rename workflow does more than update `ProfileImagePath`. It also repairs
profile path references that commonly break installers after a manual rename:

- `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\<SID>`
- `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders`
- `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders`
- Equivalent values inside the target profile's `NTUSER.DAT` while the profile
  is offline

This avoids stale paths like `C:\Users\oldname\AppData\Roaming`.

## Requirements

- Run from an elevated PowerShell window
- Use only for local user accounts
- The target user must be able to sign out completely
- Keep a recovery path available before changing the profile folder

## Standard workflow

### Phase 1: setup as the original user

Run:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Tools\UserProfileRename\Rename-UserProfile.ps1 `
  -AccountName 'Example.LocalUser' `
  -OldFolder 'old.profile' `
  -NewFolder 'new.profile'
```

What it does:

- Validates administrator access
- Creates backups under `ProfileBackup`
- Creates the temporary admin account
- Copies the automation scripts to `C:\Users\Public\Desktop`
- Prepares Windows to show account selection on next sign-in
- Generates a one-time temporary admin password if `-TempPass` is omitted

Then sign out.

### Phase 2: rename as TempAdmin

Sign in as `TempAdmin`, open an elevated PowerShell window, and run:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\Public\Desktop\Rename-UserProfile.ps1 `
  -AccountName 'Example.LocalUser' `
  -OldFolder 'old.profile' `
  -NewFolder 'new.profile'
```

What it does:

- Renames `C:\Users\old.profile` to `C:\Users\new.profile`
- Updates `ProfileImagePath`
- Loads the renamed profile's `NTUSER.DAT`
- Repairs stale shell-folder and environment values while the profile is offline

Then sign out again.

### Phase 3: finalize as the renamed user

Sign in as the renamed user, open an elevated PowerShell window, and run:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\Public\Desktop\Rename-UserProfile.ps1 `
  -AccountName 'Example.LocalUser' `
  -OldFolder 'old.profile' `
  -NewFolder 'new.profile'
```

What it does:

- Re-checks the rename state
- Normalizes the current user's `HKCU` profile-path registry values
- Restores the original logon-related registry settings
- Launches `Remove-TempAdminArtifacts.ps1`

## Cleanup script only

If you need to run cleanup separately:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Tools\UserProfileRename\Remove-TempAdminArtifacts.ps1 `
  -TempAdmin 'TempAdmin'
```

Run it from an elevated PowerShell window while logged in as the renamed user,
not as `TempAdmin`.

## Optional compatibility junction

If you want the old path to continue resolving temporarily for legacy software,
you can enable junction creation during the final phase:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Tools\UserProfileRename\Rename-UserProfile.ps1 `
  -AccountName 'Example.LocalUser' `
  -OldFolder 'old.profile' `
  -NewFolder 'new.profile' `
  -CreateCompatibilityJunction
```

This creates:

```text
C:\Users\old.profile -> C:\Users\new.profile
```

Only use that if you intentionally want backward compatibility for hardcoded old
paths.

## Verification

After the workflow finishes, validate:

```powershell
whoami
echo $env:USERPROFILE
echo $env:APPDATA
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"
reg query HKLM\SOFTWARE /f TempAdmin /s
Get-CimInstance Win32_UserProfile | Where-Object { $_.LocalPath -like '*TempAdmin*' }
```

Expected outcome:

- `USERPROFILE`, `APPDATA`, and `Shell Folders` point to the new path
- no `TempAdmin` profile remains
- no `TempAdmin` registry references remain, or only protected system-generated
  entries that require separate elevated cleanup

## Notes

- The scripts do not support Microsoft account profile migrations or domain
  profile migrations.
- Use explicit values for `-AccountName`, `-OldFolder`, and `-NewFolder` rather
  than editing the script body.
- Pass `-TempPass` explicitly if you do not want a generated password.
- Backups are best effort. Confirm they exist before proceeding if rollback
  matters.
