---
name: ninjaone-scripts
description: How to write, configure, run, and test PowerShell scripts for NinjaOne (NinjaRMM) in this repository. Use whenever creating or changing a script meant to run through NinjaOne, adding options/parameters to one, explaining how to run one from NinjaOne (ad hoc, scheduled, policy), mapping options to NinjaOne Script Variables, writing NinjaOne custom fields, or testing a script the way NinjaOne runs it. Key rule - options must be readable from NinjaOne Script Variables (environment variables), never only from command-line switches such as -ScanOnly.
---

# NinjaOne scripts (Peak Networks)

## The one rule that matters most

**Peak does not pass command-line parameters from NinjaOne.** A script that only supports
`-ScanOnly` cannot be run in scan-only mode from NinjaOne. Every option a technician might
want must also be readable from a **NinjaOne Script Variable**, which NinjaOne exposes to the
script as an **environment variable**.

So, for every option:

| Layer | Purpose |
|---|---|
| `param()` switch/parameter | Local/manual runs and testing (`.\Script.ps1 -ScanOnly`) |
| NinjaOne Script Variable → `$env:<name>` | **How it is actually run in production** |
| Default value | What happens when neither is set |

Precedence: explicitly passed parameter > NinjaOne variable > default.

When telling the user how to run something "with -ScanOnly" etc., **always answer in terms of
the Script Variable** (e.g. "tick the *Scan Only* checkbox when running the script"), not a
command-line switch.

## How NinjaOne runs a script

- Windows PowerShell 5.1 (`powershell.exe`), started by the NinjaOne agent. Must be 5.1-compatible.
- **Run As** is chosen per script/run: normally **System**. No user session, no desktop, no
  prompts: anything interactive (Read-Host, GUI, uninstallers with dialogs) hangs until timeout.
- The script **Architecture** setting may start 32-bit PowerShell on 64-bit Windows. That redirects
  registry (WOW6432Node), `System32`, and breaks AppX cmdlets. Scripts here relaunch themselves
  in 64-bit (see `Peak-HP-Debloat.ps1` / `Peak-HP-Update.ps1` entry point) - copy that block.
- **Output**: stdout (and stderr) is shown in the device's Activity. Use `Write-Output` for
  status lines and end with a short, readable summary block.
- **Exit code**: 0 = success in NinjaOne; non-zero = failure (shows red, can drive conditions/alerts).
- **Timeout** is set when the script is run or scheduled. It must be longer than the script's own
  internal timeouts (e.g. `Peak-HP-Update.ps1` needs ≥ 150 minutes).
- The agent's custom-field CLI (`Ninja-Property-Set`, `Ninja-Property-Get`) exists only inside a
  NinjaOne-launched session - never assume it.

## Script Variables (how options reach the script)

Created in **Administration → Library → Automation → (script) → Script Variables**. Each variable
has a display **Name**, a **type**, optional **default value**, and optionally **mandatory**.
Values are filled in when a technician runs the script ad hoc, and when the script is added to a
scheduled task or policy.

How values arrive in the script:

- NinjaOne derives the environment-variable name from the variable's display name as **camelCase**:
  "Scan Only" → `$env:scanOnly`, "Excluded SoftPaq IDs" → `$env:excludedSoftPaqIds`.
  Windows environment variables are **case-insensitive**, so `$env:excludedSoftPaqIDs` reads the
  same variable. **Spelling must match; case does not.** The calculated name is shown next to the
  variable in NinjaOne - check it against the script's README table.
- **Everything is a string.** Checkbox → `"true"` / `"false"`. Integer → `"60"`. Drop-down → the
  selected option's text. Treat dates as strings and parse defensively.
- An unused optional variable may be **absent, empty, or the literal string `"null"`**. Treat all
  three as "not set".
- `[ValidateSet]` / `[ValidateRange]` on `param()` do **not** apply to environment variables.
  Re-validate env values yourself; on an invalid value, log it and exit 2 rather than guessing.

### Standard pattern (copy this)

```powershell
[CmdletBinding()]
param(
    [switch]$ScanOnly,
    [ValidateRange(5, 240)][int]$TimeoutMinutes = 60
)

function Get-EnvSetting {
    param([string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    $value = $value.Trim()
    if ($value -eq 'null') { return $null }   # empty NinjaOne variable
    return $value
}
function ConvertTo-Bool { param([string]$Value) $Value -match '^(?i)(1|true|yes|y|on|checked)$' }

# Parameter wins, then NinjaOne variable, then default.
$scan = [bool]$ScanOnly
if (-not $PSBoundParameters.ContainsKey('ScanOnly')) {
    $v = Get-EnvSetting 'scanOnly'
    if ($null -ne $v) { $scan = ConvertTo-Bool $v }
}
$timeout = $TimeoutMinutes
if (-not $PSBoundParameters.ContainsKey('TimeoutMinutes')) {
    $v = Get-EnvSetting 'timeoutMinutes'
    if ($v -match '^\d+$' -and [int]$v -ge 5 -and [int]$v -le 240) { $timeout = [int]$v }
}
```

`-WhatIf` cannot be passed either: map it to a **Preview Only** checkbox (`$env:previewOnly`) and set
`$WhatIfPreference = $true` before the main function runs (see `Peak-HP-Debloat.ps1`). Remember
`-WhatIf:$false` on log writes / temp-folder creation so preview mode still logs.

Resolve settings at script level, **not inside functions** - `$PSBoundParameters` inside a
function is that function's own (empty) table.

## Output and logging conventions in this repo

- `Write-Output` for anything the technician should see in the NinjaOne Activity.
- Functions that print with `Write-Output` must **not also return data** - the caller would capture
  the text. Use pure helper functions that return data, and a main function that only prints and
  sets `$script:ExitCode`. Call it without assignment, then `exit $script:ExitCode`.
- Persistent logs: `C:\ProgramData\Peak Networks\Logs\<Name>-yyyyMMdd-HHmmss.log`, lines
  `yyyy-MM-dd HH:mm:ss [INFO|WARNING|ERROR] message`, prune after 30 days (only our own files).
- Finish with a summary block and a `Result:` line.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | Success, nothing to do, preview/scan done, or device not applicable (e.g. non-HP) - also when a reboot is pending |
| 1 | The action failed |
| 2 | Unsupported / prerequisite problem (not elevated, tool unobtainable, invalid variable value) |

## Custom fields

- Create under **Administration → Devices → Global/Role Custom Fields**; set **Scripts: Read/Write**
  or the script cannot write it. The script uses the field's machine name (camelCase), e.g.
  `hpUpdateStatus`.
- Always guard:
  ```powershell
  if (Get-Command Ninja-Property-Set -ErrorAction SilentlyContinue) {
      try { Ninja-Property-Set hpUpdateStatus $text | Out-Null } catch { }
  }
  ```
- Keep it to the fields the user asked for (v1 policy: one status field per script). Keep text
  values short; a plain Text field is meant for one line.

## Running scripts in NinjaOne (what to tell the user)

- **Ad hoc**: device → **Run** (Run Script) → pick the script → fill in the Script Variables
  (e.g. tick *Scan Only*) → set Run As **System** and a timeout → Run. Result appears under the
  device's Activities.
- **Scheduled / policy**: add the script to a scheduled task or policy and set the variable
  values there (e.g. *Scan Only* ticked for a weekly report-only task, unticked for the
  maintenance-window install task). Two tasks with different variable values = two "modes"
  without duplicating the script.
- **Preset parameters** exist in NinjaOne, but Peak does not use them. Do not design or document
  around them.

## Testing like NinjaOne

`scripts/Invoke-AsNinja.ps1` runs a script the way NinjaOne does: no command-line parameters,
options only as environment variables, 64-bit Windows PowerShell, and the exit code reported.

```powershell
# Elevated prompt on a test machine
.\.claude\skills\ninjaone-scripts\scripts\Invoke-AsNinja.ps1 -ScriptPath .\Peak-HP-Update.ps1 -Variables @{ scanOnly = 'true' }
.\.claude\skills\ninjaone-scripts\scripts\Invoke-AsNinja.ps1 -ScriptPath .\Peak-HP-Debloat.ps1 -Variables @{ previewOnly = 'true'; removePolyLens = 'false' }
```

To reproduce the SYSTEM context exactly, run that command under `psexec -s -i powershell.exe`.

In a non-Windows sandbox (this repo's cloud sessions), parse-check with
`[System.Management.Automation.Language.Parser]::ParseFile`, lint with PSScriptAnalyzer, and
exercise logic by stubbing Windows-only calls (CIM, registry, AppX, the external tool) - set
options via environment variables, not parameters, so the NinjaOne path is what gets tested.

## Variables for the scripts in this repo

Create these Script Variables in NinjaOne (display name → environment variable):

**Peak-HP-Debloat.ps1**

| Display name | Type | Env var | Effect |
|---|---|---|---|
| Preview Only | Checkbox | `previewOnly` | `-WhatIf`: list what would be removed, change nothing |
| Remove Poly Lens | Checkbox | `removePolyLens` | Also remove Poly Lens Desktop / Control Service |
| Keep Apps | Text | `keepApps` | Comma-separated target names to skip |

**Peak-HP-Update.ps1**

| Display name | Type | Env var | Effect |
|---|---|---|---|
| Scan Only | Checkbox | `scanOnly` | Analyze and report only |
| Include Optional | Checkbox | `includeOptional` | Also install Routine/optional updates |
| Exclude BIOS | Checkbox | `excludeBIOS` | Skip BIOS category |
| Exclude Firmware | Checkbox | `excludeFirmware` | Skip Firmware category |
| Excluded SoftPaq IDs | Text | `excludedSoftPaqIDs` | e.g. `sp123456,sp654321` |
| Working Directory | Text | `workingDirectory` | Default `C:\ProgramData\Peak Networks\HPIA` |
| HPIA Source | Drop-down: Auto, CMSL, Direct | `hpiaSource` | How HPIA is obtained |
| Timeout Minutes | Integer | `timeoutMinutes` | Per-HPIA-run limit (5-240, default 60) |
| Status Field | Text | `statusField` | Custom field name (default `hpUpdateStatus`) |

Leaving a variable off (or blank) uses the script default. Run As: **System**. NinjaOne timeout:
debloat ≥ 30 minutes, update ≥ 150 minutes.

## Checklist for a new or changed NinjaOne script

1. Every option has a `param()` entry **and** an env-variable fallback (camelCase name), with the
   precedence above and validation of env values.
2. Documented in the script's comment help (`.NOTES`) and the README variables table, with display
   name, type and env var.
3. Runs as SYSTEM with no prompts; 64-bit relaunch block present if it touches registry/AppX/System32.
4. All waits on external processes have timeouts.
5. `Write-Output` summary + `Result:` line; logs under `C:\ProgramData\Peak Networks\Logs`.
6. Exit codes 0/1/2 as above.
7. `Ninja-Property-Set` guarded by `Get-Command`.
8. Tested via `Invoke-AsNinja.ps1` (variables only, no parameters) - preview/scan mode first.
