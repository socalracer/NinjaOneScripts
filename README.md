# Peak Networks – HP Workstation Scripts

Standard HP provisioning and maintenance, matching our Dell process:

| Step | Dell | HP |
|---|---|---|
| Provisioning (once) | Remove Dell OEM bloat | `Peak-HP-Debloat.ps1` – remove unneeded HP OEM software |
| Maintenance (recurring) | Dell Command Update | `Peak-HP-Update.ps1` – HP Image Assistant (HPIA) for BIOS / firmware / drivers |

The two scripts are deliberately separate. Debloat is a one-time provisioning event; the update script is a reusable maintenance automation.

Other scripts in this repository (`Check-NPPIoC.ps1`, `EntraConnect-Install.ps1`, `KeeperExtension-Install.ps1`) are unrelated.

---

## Requirements

- Windows 10/11 on an HP business PC (EliteBook, ProBook, ZBook, Elite/Pro desktops). Non-HP devices are skipped with exit code 0.
- Windows PowerShell 5.1 (works in 7.x too). If NinjaOne starts 32-bit PowerShell, both scripts relaunch themselves as 64-bit.
- Run elevated. In NinjaOne this means **Run As: System**. No logged-on user is needed and no UI is shown.
- `Peak-HP-Update.ps1` needs HTTPS access to HP:
  `hpia.hpcloud.hp.com`, `ftp.hp.com`, `ftp.ext.hp.com`, `*.hp.com`.
  If you use `-HPIASource CMSL`, it also needs `www.powershellgallery.com` and `*.powershellgallery.com`.
- Laptops should be on AC power for BIOS updates. HPIA/HP's BIOS installer refuses to flash on battery; the script logs the power state.

---

## NinjaOne setup

1. **Administration → Library → Automation → Add → New Script**, language **PowerShell**, OS **Windows**, architecture **All**, **Run As: System**.
2. Paste the script contents.
3. Add the **Script Variables** below. **This is how options are chosen in NinjaOne.** We don't pass command-line parameters from NinjaOne, so "run with `-ScanOnly`" means *tick the Scan Only checkbox*.
   - NinjaOne turns each variable's display name into a camelCase environment variable, e.g. "Scan Only" → `scanOnly`. Check that the calculated name NinjaOne shows matches the table. Case doesn't matter; spelling does.
   - A variable left blank, or not created at all, uses the script default.
   - The command-line parameters still work for manual runs on a machine. An explicitly passed parameter wins over a variable.

**Peak-HP-Debloat.ps1 variables**

| Display name | Type | Environment variable | Same as |
|---|---|---|---|
| Preview Only | Checkbox | `previewOnly` | `-WhatIf`: list what would be removed, change nothing |
| Remove Poly Lens | Checkbox | `removePolyLens` | `-RemovePolyLens` |
| Keep Apps | Text | `keepApps` | `-KeepApps` |

**Peak-HP-Update.ps1 variables**

| Display name | Type | Environment variable | Same as |
|---|---|---|---|
| Scan Only | Checkbox | `scanOnly` | `-ScanOnly` |
| Include Optional | Checkbox | `includeOptional` | `-IncludeOptional` |
| Exclude BIOS | Checkbox | `excludeBIOS` | `-ExcludeBIOS` |
| Exclude Firmware | Checkbox | `excludeFirmware` | `-ExcludeFirmware` |
| Excluded SoftPaq IDs | Text | `excludedSoftPaqIDs` | `-ExcludedSoftPaqIDs` |
| Working Directory | Text | `workingDirectory` | `-WorkingDirectory` |
| HPIA Source | Drop-down: Auto, CMSL, Direct | `hpiaSource` | `-HPIASource` |
| Timeout Minutes | Integer | `timeoutMinutes` | `-TimeoutMinutes` |
| Status Field | Text | `statusField` | `-StatusField` |

**Common runs in NinjaOne**

| Goal | Script | Variables |
|---|---|---|
| Preview HP cleanup | Peak-HP-Debloat | Preview Only ✔ |
| Standard HP cleanup | Peak-HP-Debloat | none |
| Cleanup including Poly Lens | Peak-HP-Debloat | Remove Poly Lens ✔ |
| Scan HP updates without installing | Peak-HP-Update | Scan Only ✔ |
| Standard update | Peak-HP-Update | none |
| Drivers and firmware but no BIOS | Peak-HP-Update | Exclude BIOS ✔ |
| Include optional updates | Peak-HP-Update | Include Optional ✔ |

To run one ad hoc, open the device, choose **Run Script**, pick the script, set the variables, and choose Run As **System**. For scheduled tasks and policies, set the variable values on the task. For example, use one weekly task with *Scan Only* ticked for reporting, and one maintenance-window task with it unticked.

4. **Optional custom field.** To show update status on the device, create a device custom field:
   - Type: Text
   - Label: `HP Update Status`
   - Name: `hpUpdateStatus`
   - Scripts: **Read/Write**

   The update script writes it only when `Ninja-Property-Set` exists, so it runs fine without NinjaOne or without the field. Example values:
   `Up to date`, `3 updates installed - reboot required`, `Scan found 2 recommended updates`, `HPIA failed - There is no Internet connection`.
   To use a different field, pass `-StatusField <name>`. Pass `-StatusField ''` to disable it.
5. **Scheduling.** Run debloat once from the onboarding/provisioning policy. Schedule the update script, for example weekly, outside business hours, on an HP-only device group or policy. Neither script reboots. Pair the update script with your normal reboot/maintenance-window policy.

Ninja's script timeout must be longer than the HPIA timeout. Set it to at least **150 minutes** for `Peak-HP-Update.ps1`: HPIA gets 60 minutes per run and 120 minutes in total.

---

## Peak-HP-Debloat.ps1

### What it does
1. Logs computer name, manufacturer, model and Windows version.
2. Exits 0 (skipped) unless the manufacturer is `HP` or `Hewlett-Packard`. HPE servers do not match.
3. For each entry in the explicit `$RemovalTargets` list:
   - **Win32 apps.** The match needs an exact DisplayName and an HP (or Poly) publisher.
   - **AppX apps.** The match needs an exact package name. Each package is removed for all users and also de-provisioned, so it does not return for new profiles.
4. Logs every item found, removed, failed and not found, then prints a summary.
5. Never reboots. If an uninstaller returns 3010/1641 or Windows reports a pending reboot, the summary says `Reboot Required: Yes`.

### Default removal list

These are removed where present:

- **Notifications and support tools:** HP Notifications, HP Connection Optimizer, HP Documentation, HP Support Assistant, HP Support Solutions Framework
- **Wolf Security and Sure-family agents:**
  - HP Wolf Security, plus its "Application Support for …" components
  - HP Wolf Security Console
  - HP Security Update Service
  - HP Sure Run and HP Sure Run Module
  - HP Sure Recover
  - HP Sure Click
  - HP Sure Sense, including the Sure Sense installer and the `AD2F1837.HPSureShieldAI` AppX package
- **Consumer and utility apps (Win32 and/or AppX):** HP QuickDrop / HP Quick Drop, HP Privacy Settings, HP Welcome, HP JumpStarts / JumpStart Apps, HP System Information, HP Power Manager, myHP

The exact names are in the `$RemovalTargets` table at the top of the script. Edit only that table to change the list.

**Poly Lens** (Poly Lens Desktop, Poly Lens Control Service) is removed **only** with `-RemovePolyLens`.

### Never removed
- HP Image Assistant and HP CMSL.
- Any driver: chipset, audio, graphics, network, touchpad, camera, Thunderbolt.
- Hotkey support and system event components.

A protected-name filter refuses anything matching these, even if someone later adds it to the removal list by mistake. Other HP-published software that is not on the list is never touched. In preview mode it is listed so you can review it.

### How uninstalls run
| Uninstaller type | Command used |
|---|---|
| MSI (WindowsInstaller=1 or `msiexec` uninstall string) | `msiexec.exe /x {ProductCode} /qn /norestart REBOOT=ReallySuppress /l*v <log>`. The `/I` in the registry string is never re-used. |
| HP Connection Optimizer (InstallShield) | `setup.exe /s /f1"<generated .iss>"` (response file) |
| Vendor `QuietUninstallString` | used as provided, with quoted paths parsed correctly |
| Inno Setup (`unins000.exe`) | `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` |
| `.cmd`/`.bat` uninstall script, bare or already wrapped as `CMD /C "…\script.cmd"` (e.g. HP Documentation) | run through `cmd.exe /c` from a temp folder, output captured to a log. Success is judged by the Apps & Features entry disappearing, not the exit code, because a script that deletes its own folder exits 1. |
| EXE whose uninstall string already has a silent switch | used as provided |
| **Any other EXE** | **not run.** It is logged as failed ("no known silent uninstall method") so we never start an interactive uninstaller as SYSTEM. |

Every uninstaller has a timeout (default 15 minutes) and is killed if it hangs. After an uninstaller exits 0, the script checks that the Uninstall registry entry is actually gone.

### Parameters
| Parameter | Default | Description |
|---|---|---|
| `-WhatIf` | off | Preview. Lists exactly what would be removed and changes nothing. |
| `-RemovePolyLens` | off | Also remove Poly Lens Desktop and Poly Lens Control Service. |
| `-KeepApps` | empty | Comma-separated target names to skip, e.g. `"HP Power Manager,myHP"`. |
| `-UninstallTimeoutMinutes` | 15 | Per-uninstaller timeout. |

### Examples
```powershell
# Preview HP cleanup
.\Peak-HP-Debloat.ps1 -WhatIf

# Standard HP cleanup
.\Peak-HP-Debloat.ps1

# Cleanup including Poly Lens
.\Peak-HP-Debloat.ps1 -RemovePolyLens
```

### Exit codes
| Code | Meaning |
|---|---|
| 0 | Success, partial success, nothing to remove, preview, or non-HP device skipped |
| 1 | Cleanup fundamentally failed: two or more removals were attempted and none succeeded, or an unhandled error occurred |
| 2 | Prerequisite problem: not elevated, or installed software could not be enumerated |

Individual optional removals that fail do **not** fail the script, even if that one app was the only thing left to remove. They appear under `Failed:` in the summary and the result is `Partial success`.

---

## Peak-HP-Update.ps1

### What it does
1. Verifies HP hardware and elevation, and refuses to start if HPIA is already running.
2. Enables TLS 1.2 for this process only.
3. **Gets the current HPIA** into `<WorkingDirectory>\bin`:
   - It reads HP's HPIA release manifest (`HPIAMsg.cab`, the feed HPIA itself uses), so no version is hard-coded. 5.3.7 is current today; newer releases are picked up automatically.
   - It compares that version with the installed `HPImageAssistant.exe` and downloads only when the installed copy is missing or older.
   - With `-HPIASource Auto` (the default), HP CMSL's `Install-HPImageAssistant` is used if CMSL is already installed. Otherwise the script uses the HP download URL from the manifest.
   - If both of those fail and HPIA is missing or outdated, Auto installs the `HPCMSL` module and uses it. This is the only case where Auto changes PowerShell modules.
   - A failed manifest download is reported with its size and first bytes, and a failed extraction lists the extracted file names. This shows whether a proxy or web filter replaced the download.
   - With `-HPIASource CMSL`, the script installs the `HPCMSL` module if it is missing. It installs the NuGet provider only if that is missing, does not change PSGallery trust, and does not upgrade PowerShellGet.
   - Every downloaded package and the final `HPImageAssistant.exe` must carry a valid **HP Inc.** Authenticode signature, or they are not run.
   - The new copy replaces the old one only after it has been fully extracted and verified.
4. **Runs a fresh analysis on every run.** Each HPIA run gets a new report folder, so old recommendation files are never reused. It runs `HPImageAssistant.exe /Operation:Analyze /Category:BIOS,Drivers,Firmware /Selection:All /Action:List /Silent /ReportFolder:"…"`.
5. **Filters the recommendations:**
   - Only the `BIOS`, `Drivers` and `Firmware` categories are scanned. `-ExcludeBIOS` and `-ExcludeFirmware` remove a category.
   - Critical and Recommended updates are installed. Routine (HP's "optional") updates are installed only with `-IncludeOptional`, and are otherwise counted as `Optional ignored`.
   - SoftPaqs listed in `-ExcludedSoftPaqIDs` are removed from the counts and from installation.
   - HP applications such as Support Assistant, Wolf Security, myHP and HP Notifications are never installed, even when HPIA offers them inside an allowed category. This list mirrors the debloat removal list, so maintenance does not re-add what provisioning removed.
6. **Installs exactly the approved list** (see *Install safety* below). Each HPIA run has a hard timeout of 60 minutes by default, and total HPIA time is capped at twice that. On timeout the HPIA process tree is killed, the timeout is logged, and the script exits 1.
7. **Parses the results** from HPIA's JSON/XML report: each SoftPaq is reported as installed or failed, with HP's return code.
8. **Detects a required reboot** from these signals:
   - HPIA exit code 3010
   - Per-SoftPaq return codes 3010/1641
   - Any installed BIOS or firmware update
   - The Component Based Servicing `RebootPending` key
   - The Windows Update `RebootRequired` key

   `PendingFileRenameOperations` is logged but does not count on its own; it is often left over from unrelated software.
9. Cleans up downloaded SoftPaqs and temporary files. It keeps the HPIA binaries, the HPIA reports (30 days) and the logs.

### Install safety (how exclusions are enforced)
HPIA's command line filters by category and selection, but it has no "exclude this SoftPaq" switch. The script therefore uses two methods:

1. **Preferred method: an exact SoftPaq list.** The script writes the approved SoftPaq numbers to a file and passes it with `/SPList`.
   - First it runs a *List* pass with that file. It continues only if HPIA's output contains nothing outside the approved list.
   - It then runs the install with the same list.
2. **Fallback: per-group installs.** Used if that check does not confirm `/SPList` filtering, for example because an HPIA build does not support it.
   - The script installs one category and selection pair at a time, such as `Drivers / Recommended`, using HPIA's own `/Category` and `/Selection` filters.
   - Before each group it runs a List pass. A group is installed only if HPIA's list for it contains no excluded or blocked SoftPaq.
   - A group that does contain one is **deferred** and reported under `Not installed / unverified`. It is not partly installed.

After installation, if HPIA's report shows anything installed that was not on the approved list, the script logs an error and the run is marked **Failed**.

### BitLocker and BIOS updates
The script never suspends, disables or otherwise changes BitLocker, Secure Boot or BIOS settings.

- **How BitLocker is handled:** BIOS flashing is done by HP's own BIOS SoftPaq installer, which HPIA launches. HP's installer suspends BitLocker for the flash reboot as part of HP's supported process. Windows resumes protection automatically after that restart.
- **What the script logs:** BitLocker protection status for the OS volume, before and after the run. It does not change it.
- **What to check during pilot testing:**
  - After a BIOS update, the log should show `Protection Off / suspended`.
  - After the manual reboot, BitLocker should show `Protection On`.
  - The device must not prompt for the recovery key.
- **BIOS setup password:** HPIA cannot flash the BIOS without the password file (`/BIOSPwdFile`). v1 does not handle BIOS passwords, so the BIOS SoftPaq is reported as failed on those devices. Use `-ExcludeBIOS` for those clients until we add password-file support.

### Parameters
| Parameter | Default | Description |
|---|---|---|
| `-ScanOnly` | false | Analyze and report only. |
| `-IncludeOptional` | false | Also install Routine/optional updates. |
| `-ExcludeBIOS` | false | Skip the BIOS category. |
| `-ExcludeFirmware` | false | Skip the Firmware category. |
| `-ExcludedSoftPaqIDs` | empty | e.g. `sp123456,sp654321`. Commas, semicolons or spaces; the `sp` prefix is optional. Invalid values stop the script with exit 2 before anything runs. |
| `-WorkingDirectory` | `C:\ProgramData\Peak Networks\HPIA` | HPIA binaries (`bin`), reports (`Reports`), and temporary downloads (`Temp`, `SoftPaqs`; removed after each run). |
| `-HPIASource` | `Auto` | `Auto`, `CMSL` or `Direct` (see step 3 above). |
| `-TimeoutMinutes` | 60 | Hard limit per HPIA run; total HPIA time is capped at twice this. |
| `-StatusField` | `hpUpdateStatus` | NinjaOne custom field to update. Use `''` to disable. |

### Examples
```powershell
# Scan HP updates without installing
.\Peak-HP-Update.ps1 -ScanOnly

# Standard update
.\Peak-HP-Update.ps1

# Drivers and firmware but no BIOS
.\Peak-HP-Update.ps1 -ExcludeBIOS

# Include optional updates
.\Peak-HP-Update.ps1 -IncludeOptional

# Exclude a known-problem SoftPaq
.\Peak-HP-Update.ps1 -ExcludedSoftPaqIDs "sp123456,sp654321"
```

### Example output
```
Peak HP Update
Model: HP EliteBook 860 G11
HPIA: 5.3.7

Updates detected: 6
Critical: 1
Recommended: 5
Optional ignored: 2

Installed:
SP15xxxx - Intel Graphics Driver
SP15xxxx - HP Notebook System BIOS Update
SP15xxxx - Thunderbolt Firmware

Failed:
None

Reboot Required: Yes
Result: Success
```

### Exit codes
| Code | Meaning |
|---|---|
| 0 | Success, nothing to install, scan complete, or non-HP device skipped. **A pending reboot is still 0.** |
| 1 | Update failure: a SoftPaq failed to install, HPIA returned an error, HPIA timed out, HPIA was already running, or an unhandled script error occurred |
| 2 | Unsupported or prerequisite problem: not elevated, HPIA could not be obtained or verified, HPIA does not support the platform/OS (4096/16386/16387), or invalid `ExcludedSoftPaqIDs` |

"Success with warnings" (exit 0) means nothing failed, but some approved updates were deferred or HPIA did not report on them. The details are under `Not installed / unverified`.

---

## Log locations

| What | Where | Retention |
|---|---|---|
| Debloat log | `C:\ProgramData\Peak Networks\Logs\HP-Debloat-yyyyMMdd-HHmmss.log` | 30 days |
| Failed uninstall log (MSI verbose log, or uninstall-script output) | `C:\ProgramData\Peak Networks\Logs\HP-Debloat-Uninstall-<app>-<timestamp>.log` (kept only on failure) | manual |
| Update log | `C:\ProgramData\Peak Networks\Logs\HP-Update-yyyyMMdd-HHmmss.log` | 30 days |
| HPIA reports (JSON/XML/HTML per HPIA run) | `C:\ProgramData\Peak Networks\HPIA\Reports\<timestamp>\<step>\` | 30 days |
| HPIA binaries | `C:\ProgramData\Peak Networks\HPIA\bin\` | replaced when HP releases a newer HPIA |

Log lines have the form `yyyy-MM-dd HH:mm:ss [INFO|WARNING|ERROR] message`. The NinjaOne activity output shows the important lines and the summary; the log file has the full detail, including exact HPIA command lines and report paths.

---

## How to test safely

Test on a **freshly provisioned HP machine** first, ideally one model per hardware generation we support.

To test outside NinjaOne exactly as NinjaOne runs a script (variables only, no parameters, 64-bit), use the helper from an elevated prompt:

```powershell
.\.claude\skills\ninjaone-scripts\scripts\Invoke-AsNinja.ps1 -ScriptPath .\Peak-HP-Update.ps1 -Variables @{ scanOnly = 'true' }
.\.claude\skills\ninjaone-scripts\scripts\Invoke-AsNinja.ps1 -ScriptPath .\Peak-HP-Debloat.ps1 -Variables @{ previewOnly = 'true' }
```

### Debloat checklist
- [ ] Run `.\Peak-HP-Debloat.ps1 -WhatIf`.
- [ ] Compare the `FOUND` / `WOULD REMOVE` lines with **Settings → Apps → Installed apps**. Confirm nothing unexpected is targeted.
- [ ] Review the "Other HP-published software left in place" list. Decide whether anything there should be added to `$RemovalTargets` by exact name.
- [ ] Note any item reported as "no known silent uninstall method". Investigate it before relying on the script for that app.
- [ ] Run `.\Peak-HP-Debloat.ps1` (standard cleanup).
- [ ] Review the summary and the log: Removed / Failed / Not found.
- [ ] Reboot manually.
- [ ] Verify the targeted applications are gone from Apps & Features and the Start menu.
- [ ] Create a **new local user profile** and confirm the removed AppX apps (myHP, HP Support Assistant, etc.) do not appear.
- [ ] Device Manager has no unknown devices and no new yellow bangs.
- [ ] Audio: speakers, headset jack, microphone.
- [ ] Wi-Fi.
- [ ] Bluetooth.
- [ ] Webcam, including the privacy shutter/key if present.
- [ ] Function keys and hotkeys: brightness, volume, mute, mic mute, airplane mode.
- [ ] USB-C / Thunderbolt: dock, display output, charging.
- [ ] Windows Hello: face and/or fingerprint.
- [ ] Re-run `-WhatIf` and confirm it reports nothing left to remove.

### HPIA checklist
- [ ] Run `.\Peak-HP-Update.ps1 -ScanOnly`.
- [ ] Run HPIA interactively on the same machine (Analyze → Drivers/BIOS/Firmware) and compare the results with the scan output.
  - Every Critical/Recommended item should match.
  - Software items should show as "HP apps not deployed" or be absent.
- [ ] Check the scan log for `Skipped (HPIA did not classify…)` or `report parse problem` warnings. Either one means the HPIA report format differs from what the script expects; report it before rolling out.
- [ ] Note the BIOS version (`Get-CimInstance Win32_BIOS`) and the BitLocker status (`manage-bde -status C:`).
- [ ] Laptop on AC power; run the standard install `.\Peak-HP-Update.ps1`.
- [ ] In the log, check which install method was used: `2-Verify-SPList` followed by `3-Install`, or the `2-Probe-*` fallback.
- [ ] Confirm the log shows no `NOT in the approved list` errors.
- [ ] Reboot manually when `Reboot Required: Yes`. Watch the BIOS flash complete. Confirm no BitLocker recovery prompt and that BitLocker returns to `Protection On`.
- [ ] Re-run `.\Peak-HP-Update.ps1 -ScanOnly`. Critical/Recommended should be zero. Explain anything remaining: excluded IDs, deferred groups, or items HPIA re-offers.
- [ ] Verify the new BIOS version.
- [ ] Verify firmware versions (Thunderbolt/dock firmware in HPIA or the device's own utility).
- [ ] Device Manager: no unknown devices and no new errors.
- [ ] Test `-ExcludeBIOS`, `-ExcludedSoftPaqIDs` (pick one SoftPaq from the scan) and `-IncludeOptional` once each.
- [ ] If the `hpUpdateStatus` field is configured, confirm it updates in NinjaOne.

---

## How to roll out

1. **Lab:** complete both checklists on one device of each HP model family we manage.
2. **Pilot:** 5–10 internal or friendly-client devices.
   - Debloat runs on new provisions only.
   - The update script runs in `-ScanOnly` for a week, then in install mode during a maintenance window.
3. **Review:** go through the logs and `hpUpdateStatus` values. Add any problem SoftPaqs to `excludedSoftPaqIDs` at the policy level.
4. **General availability:**
   - Add debloat to the HP onboarding/provisioning automation.
   - Schedule the update script on HP device policies, weekly, after hours, with reboots handled by the existing maintenance-window policy.
5. **Clients with Poly hardware:** leave `removePolyLens` unchecked (the default).
6. **Clients with BIOS setup passwords:** run with `excludeBIOS` until password-file support is added.

---

## Design decisions and deviations from the reference scripts

The reference scripts were treated as examples, not as known-good code. These are the places this implementation deliberately differs.

### Compared with the homotechsual `HP.ps1` debloat reference
- **No `AD2F1837*` publisher wildcard.** The reference removes every AppX package whose name starts with HP's Store publisher ID. That would also remove HP Audio Control, HP Display Center, HP Programmable Key, HP Command Center and similar companion apps for hardware features. This script removes only AppX packages named exactly in the target list.
- **No unrequested or ambiguous targets.** These reference targets were dropped:
  - `ICS`: a three-letter DisplayName that could match non-HP software.
  - `HP MAC Address Manager`: used for MAC pass-through on docks.
  - `HP System Default Settings`.
  - `HP PC Hardware Diagnostics`, `HP WorkWell`, `HP Easy Clean`, `HP Desktop Support Utilities`.

  None of these were on our list. Add them to `$RemovalTargets` by exact name if wanted.
- **No `Get-Package | Uninstall-Package` second pass.** It depends on PackageManagement providers, can launch interactive uninstallers, and duplicates the registry pass.
- **No unbounded `do { } while` retry loops.** The reference loops until nothing matches. An app that cannot be removed would make it loop forever. This script makes one attempt per item with a timeout, then checks the registry.
- **Correct MSI handling.** The reference turns `/I` into `/X` with string replacement and adds conflicting switches (`/qn … /quiet`). This script builds `msiexec /x {ProductCode} /qn /norestart` from the product code and writes a verbose log on failure.
- **No guessing at silent switches.** The reference runs any `UninstallString` through `cmd /c`. As SYSTEM, an interactive EXE uninstaller hangs with no one to click. This script runs only the known-silent methods in the table above.
- **Publisher check and protected-name filter.** Neither exists in the reference.
- **No removal of `C:\ProgramData\HP\TCO` etc.** File-system cleanup of offers/shortcuts was not requested and is not reversible.
- **HP Connection Optimizer response-file approach kept.** It is the one reference technique that addresses a real problem: a non-MSI InstallShield uninstaller with no silent switch. It is preserved, but the original `-runfromtemp` switches are dropped so the uninstaller does not hand off and exit early.
- **Manufacturer check, `-WhatIf`, `-RemovePolyLens`, structured logging and exit codes** were added, as specified in the brief.

### Compared with the bf-ryanalexander `Update-HPDrivers.ps1` reference
- **No scraping of the HPIA web page and no hard-coded fallback URL.** The reference scrapes `HPIA.html` and falls back to a fixed `hp-hpia-5.3.4.exe` URL. This script reads HP's HPIA manifest, prefers CMSL, and checks HP's signature before running anything.
- **HPIA is updated when outdated.** The reference never updates an existing copy; it has a `TODO`.
- **Installs Critical + Recommended only.** The reference passes `/Selection:All /Action:Install`, which also installs Routine/optional updates. This script uses Critical + Recommended by default, with an exact allow-list.
- **Bounded waits.** The reference uses `while (-not (Test-Path *.xml)) { Start-Sleep 60 }`, which loops forever if HPIA fails before writing a report. Every wait here has a timeout, and the process tree is killed on timeout.
- **Fresh report folder every run.** The reference reads `*.xml` from a shared folder, so it can report a previous run's results.
- **Reports outcomes and sets exit codes.** The reference lists recommendations but does not report success or failure, reboot state, or a meaningful exit code.
- **Paths.** Files go under `C:\ProgramData\Peak Networks\…` rather than `C:\temp`, which standard users can write to.

### Compared with the larger NinjaOne-oriented reference script (Arjen Fiechter, v0.2 pre-production)

**Adopted from it:**
- **Report field names.** It reads `Severity` from HPIA's JSON, with values such as `RELEASE_TYPE_CRITICAL` and `RECOMMENDED`, plus `Comments` (e.g. `HP_UPDATE_RECOMMENDED`). It reads `SoftPaqNumber` from the XML. The parser here now checks those fields first.
- **CMSL parameter names.** It confirms the `Install-HPImageAssistant -Extract -DestinationPath -Quiet` parameters this script uses.
- **HPIA version string.** It confirms that HPIA's `ProductVersion` can carry a `+build` suffix; the version comparison here only uses major.minor.build.

**Deliberately not adopted:**
- **Prerequisite churn on every run.** Every run it installs or upgrades the NuGet provider, PackageManagement and PowerShellGet. It also sets PSGallery to *Trusted* machine-wide and upgrades HPCMSL. That is exactly the endpoint churn the brief asks to avoid. Here, the default `Auto` mode changes no modules unless HPIA cannot be obtained any other way. Even then it installs only HPCMSL, plus the NuGet provider if missing.
- **Seven custom fields.** It writes seven fields, including a WYSIWYG HTML table, with `Ninja-Property-Set` calls that are not guarded, so it fails outside NinjaOne. Here there is one optional field, written only if the command exists.
- **Waits with no timeout.** It runs `while (Get-Process HPImageAssistant) { Start-Sleep 5 }` after every HPIA call. That loop has no limit and also waits on any unrelated HPIA instance. `$LASTEXITCODE` is read after that loop, so the exit code it acts on is not reliably HPIA's. Here every HPIA run has a hard timeout and its exit code is captured from the process itself.
- **Exclusions through `/ReferenceFile`.** It deletes excluded `<Recommendation>` nodes from HPIA's *analysis report* and passes that file back as `/ReferenceFile`. An HPIA reference file is HP's platform catalog, a different format from the analysis report. HPIA will likely reject the edited report or ignore the removed nodes. Because the script never checks HPIA's exit code or what was actually installed, the exclusion can fail silently. Here the approved list is verified before install, and the results are checked against it afterwards.
- **Installs too broadly.** Its install modes use `/Category:All` or `Drivers,Software,Accessories` with `/Selection:All`. That installs Optional/Routine updates and HP Software-category apps. Here only Critical and Recommended BIOS, driver and firmware updates are installed.
- **Report-folder mix-ups.** It reads `*.json` and `*.xml` from a reports folder shared by every run. If an older report is still there it can parse the wrong file, and with several files `Get-Content` receives an array of paths. Here every HPIA run gets its own fresh report folder.
- **Weak HP check.** It tests `Win32_BIOS.Manufacturer -like '*HP*'`, which also matches HPE servers. Here the system manufacturer is matched exactly to HP or Hewlett-Packard.
- **Misleading results.** It reports the number of updates *found* as the number installed. It writes "Reboot required to complete a previous operation" after its own installs. It exits 0 when no mode is selected. Here each SoftPaq's own result is reported, and exit codes follow the table above.

### Other choices
- **`Write-Output` for NinjaOne visibility.** Functions that print status return no data, so that output is never captured by mistake.
- **HPIA stays the authority.** The script never decides on its own which driver applies. It only narrows HPIA's own recommendations, and every install is done by HPIA.
- **BIOS and firmware updates are treated as needing a reboot,** even when HPIA reports exit 0. Firmware and BIOS updates apply on restart, so reporting "No" would be misleading.

---

## Known items to confirm during pilot

These depend on HP behavior that could not be run against real hardware while building the scripts. The scripts are written to fail safe if any of them differ.

1. **HPIA JSON report field names.** The script reads these fields:
   - `SoftPaqId`, `Name` and `Remediation.ReturnCode`.
   - For the release type: `Severity`, then `RecommendationValue`, then `HP_*` codes in `Comments`.
   - XML fallbacks: `Solution/Softpaq/Id` or `SoftPaqNumber`.

   If HPIA's real output differs:
   - It runs per-selection scans to classify updates.
   - It logs `Skipped (HPIA did not classify…)` rather than guessing.
2. **`/SPList` with `/Action:Install`.** This is verified at runtime. If HPIA ignores the list, the script switches to per-group installs.
3. **AppX package names.** The script targets exact names; a name that does not exist is simply reported as not found.
   - `AD2F1837.HPWelcome` in particular should be checked against a real device.
   - Run `Get-AppxProvisionedPackage -Online | ? DisplayName -like 'AD2F1837*'` on a fresh unit and compare.
4. **Exact Win32 DisplayNames.** If HP has renamed a product on newer models, the `-WhatIf` run lists the current name under "Other HP-published software". Add it to the target list by exact name.
