[README.md](https://github.com/user-attachments/files/28143757/README.md)
# gMSA AD Query Tester

Tests whether a gMSA account (e.g. the SharpHound/BHE service account) can successfully
authenticate as a Windows scheduled task and run an AD query against your domain.

---

## Folder Contents

| File | Purpose |
|------|---------|
| `gMSA_To_AD_Query-test.ps1` | Main script — do not edit |
| `AD_query.txt` | **Edit before each run** — set target account and query |
| `gMSA_settings.txt` | **Edit once per environment** — service name, DC target, task name |
| `gmsa_test_log.txt` | Auto-generated on each run — full output including query results |

---

## Quick Start

1. Edit `AD_query.txt` — set `$Account` and uncomment the query type you want.
2. Edit `gMSA_settings.txt` — verify the service name (`SHDelegator`) and optionally set a DC target.
3. Run from an elevated PowerShell prompt:

```powershell
cd C:\path\to\TEST_gMSA-ScheduledTask
.\gMSA_To_AD_Query-test.ps1
```

4. Review the **pre-flight summary** and type `Y` to proceed, or any other key to exit and fix.
5. Check `gmsa_test_log.txt` — **STEP 8** contains the AD query result.

---

## Command-Line Parameters

All parameters are optional. When omitted the script reads from the config files.

| Parameter | Example | Description |
|---|---|---|
| `-GMSA` | `-GMSA "states\t0_SomeOther_gMSA$"` | Override the gMSA identity — bypasses service lookup entirely |
| `-Server` | `-Server DC01.states.local` | Override DC targeting — forces the query to that specific DC |

**Examples:**

```powershell
# Default — uses gMSA from SHDelegator service, auto DC selection
.\gMSA_To_AD_Query-test.ps1

# Test a different gMSA without editing gMSA_settings.txt
.\gMSA_To_AD_Query-test.ps1 -GMSA "states\t0_SomeOther_gMSA$"

# Force query to a specific DC
.\gMSA_To_AD_Query-test.ps1 -Server DC01.states.local

# Test a specific gMSA against a specific DC
.\gMSA_To_AD_Query-test.ps1 -GMSA "states\t0_SomeOther_gMSA$" -Server DC01.states.local
```

Command-line parameters always take priority over values in `gMSA_settings.txt`.

---

## Config Files

### AD_query.txt

Set `$Account` to the identifier of the object you want to query, then uncomment
the matching `$AD_Query` example. Only one `$AD_Query` should be uncommented at a time.

> **Do NOT add `-Server`** to the query — DC targeting is controlled via `-Server` on
> the command line or `$DC_Target` in `gMSA_settings.txt`.
> **Do NOT add `| Out-File`** — the script handles output automatically.

<img width="695" height="780" alt="image" src="https://github.com/user-attachments/assets/d49e04c0-1a18-4143-b92f-132b1514780a" />


---

### gMSA_settings.txt

Edit once per environment. All values can be overridden at the command line without
touching this file.

| Setting | Default | Description |
|---|---|---|
| `$gMSA_Source` | `auto` | `auto` = read gMSA from service; `manual` = use `$gMSA_Manual` |
| `$gMSA_ServiceName` | `SHDelegator` | **Service Name** of the SharpHound service (not Display Name) |
| `$gMSA_Manual` | `states\t0_gMSA_SHSA$` | Used when `$gMSA_Source = "manual"` or service lookup fails |
| `$DC_Target` | *(blank)* | Optional persistent DC override (FQDN or hostname) |
| `$TaskName` | `TestgMSAPermissions` | Name used for the temporary scheduled task |
| `$SleepSecs` | `10` | Seconds to wait after task starts before reading results |

> **Service Name vs Display Name**
> `$gMSA_ServiceName` needs the internal Windows **Service Name**, not the Display Name
> shown in the Services panel:
>
> | Services panel (Display Name) | Use in gMSA_settings.txt (Service Name) |
> |---|---|
> | `SharpHoundDelegator` | `SHDelegator` |
>
> To find the correct value:
> ```powershell
> Get-Service | Where-Object { $_.DisplayName -like "*Sharp*" } | Select-Object Name, DisplayName
> ```
> Use the `Name` column value.

---

## DC Targeting

Three ways to control which DC the query runs against, in priority order:

| Method | How | Priority |
|---|---|---|
| Command-line parameter | `.\gMSA_To_AD_Query-test.ps1 -Server DC01.states.local` | Highest |
| Settings file | `$DC_Target = "DC01.states.local"` in `gMSA_settings.txt` | Persistent default |
| Leave both blank | AD auto-selects the nearest available DC | Lowest |

When a DC is specified the query runs against **that exact DC only** — useful for
verifying replication (checking whether a new object has reached a specific DC yet).

---

## gMSA Targeting

Three ways to control which gMSA is tested, in priority order:

| Method | How | Priority |
|---|---|---|
| Command-line parameter | `.\gMSA_To_AD_Query-test.ps1 -GMSA "states\t0_Other_gMSA$"` | Highest |
| Manual setting | `$gMSA_Source = "manual"` + `$gMSA_Manual = "states\t0_Other_gMSA$"` in `gMSA_settings.txt` | Explicit override |
| Auto (default) | `$gMSA_Source = "auto"` — reads from `SHDelegator` service `StartName` | Default |

The `-GMSA` flag is the quickest way to test a different gMSA without touching any files.
It bypasses the service lookup entirely and goes straight to that account.

---

## Query Types — What to Set and What to Watch Out For

### Users
```powershell
$Account  = "jsmith@states.local"          # UPN or SamAccountName
$AD_Query = "Get-ADUser '$Account' -Properties userAccountControl | Select-Object Name, Enabled, userAccountControl"
```

### Groups
```powershell
$Account  = "Domain Admins"
$AD_Query = "Get-ADGroup '$Account' -Properties Members | Select-Object Name, GroupScope, Members"
# To list members:
$AD_Query = "Get-ADGroupMember '$Account' | Select-Object Name, SamAccountName, objectClass"
# To expand nested groups:
$AD_Query = "Get-ADGroupMember '$Account' -Recursive | Select-Object Name, SamAccountName, objectClass"
```

### Computers and Domain Controllers
```powershell
$Account  = "DC01"                         # Computer name — no trailing $
$AD_Query = "Get-ADComputer '$Account' -Properties * | Select-Object Name, OperatingSystem, Enabled, LastLogonDate"
# All DCs:
$AD_Query = "Get-ADDomainController -Filter * | Select-Object Name, Site, IPv4Address, OperatingSystem"
```

### Organisational Units (OUs)

> **OUs do not have a SamAccountName.** `$Account` must be a full Distinguished Name (DN).
> If it does not start with `OU=` or `CN=` the pre-flight will warn you before anything runs.

```powershell
$Account  = "OU=Tier Zero,OU=STRATA,DC=states,DC=local"
$AD_Query = "Get-ADOrganizationalUnit -Identity '$Account' -Properties * | Select-Object Name, DistinguishedName, ManagedBy, LinkedGroupPolicyObjects"
# List all OUs under a base:
$AD_Query = "Get-ADOrganizationalUnit -Filter * -SearchBase '$Account' | Select-Object Name, DistinguishedName"
```

### Group Policy Objects (GPOs)

Two methods — choose based on what RSAT modules are available:

| Method | Module required | Notes |
|---|---|---|
| `Get-ADObject -Filter {objectClass -eq 'groupPolicyContainer'}` | ActiveDirectory only | **Always safe** — AD module verified in Step 2 |
| `Get-GPO` | GroupPolicy (GPMC RSAT) | Only works if GPMC RSAT is installed on this machine |

**Recommended (AD module only):**
```powershell
$AD_Query = "Get-ADObject -Filter {objectClass -eq 'groupPolicyContainer'} -Properties displayName, gPCFileSysPath | Select-Object Name, displayName, gPCFileSysPath"
```

**Full GPO detail (requires GPMC RSAT):**
```powershell
$Account  = "Default Domain Policy"
$AD_Query = "Get-GPO -Name '$Account' | Select-Object DisplayName, GpoStatus, CreationTime"
```

Install GPMC RSAT if needed:
```powershell
Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0
```

> The script automatically detects `Get-GPO` queries and checks for the GroupPolicy
> module in Step 2, warning you before the task runs if it is missing.

### gMSA / Service Accounts

> **Always include the trailing `$`** in the account name.

```powershell
$AD_Query = "Get-ADServiceAccount 't0_gMSA_SHSA\`$' -Properties * | Select-Object Name, Enabled, PrincipalsAllowedToRetrieveManagedPassword"
```

### Any Object by Distinguished Name
```powershell
$Account  = "CN=t0_gMSA_SHSA,OU=T0_Service-Accounts,OU=Tier Zero,OU=STRATA,DC=states,DC=local"
$AD_Query = "Get-ADObject -Identity '$Account' -Properties * | Select-Object Name, objectClass, DistinguishedName, whenCreated"
```

---

## What the Script Does (Step by Step)

| Step | What happens |
|------|-------------|
| **Config load** | Reads both config files; dumps every loaded value to log so stale files are obvious |
| **Step 0** | Resolves the gMSA identity — auto from service, manual override, or `-GMSA` flag |
| **Pre-flight** | Shows query, gMSA, DC, and query-type-specific tips; prompts Y/N before anything is created |
| **Step 1** | Confirms gMSA exists in AD; checks `SeBatchLogonRight` on this machine |
| **Step 2** | Verifies AD module is installed; also checks GroupPolicy module if a GPO query is active |
| **Step 3** | Removes any leftover scheduled task from a previous failed run |
| **Step 4** | Registers a temporary scheduled task that runs the AD query **as the gMSA** |
| **Step 5** | Confirms the task registered correctly and is running as the right identity |
| **Step 6** | Starts the task and waits for completion |
| **Step 7** | Reads the task result code and pulls Task Scheduler event log entries |
| **Step 8** | **Reads and logs the AD query output — this is the actual test result** |
| **Step 9** | Removes the temporary task and temp output file; leaves only the log |

---

## Running the Script — Pre-Flight Check

When the script runs it resolves all config and shows a pre-flight summary before
creating anything. This is your chance to confirm everything looks right.

<img width="953" height="720" alt="image" src="https://github.com/user-attachments/assets/58bea588-109d-46a8-a73e-735926f9b997" />


The pre-flight detects your query type and surfaces relevant tips automatically:

- **OU queries** — warns if `$Account` does not look like a DN
- **GPO queries using `Get-GPO`** — warns if the GroupPolicy module is not installed
- **gMSA queries** — reminds you to include the trailing `$`
- **Group member queries** — reminds you about `-Recursive` for nested groups

Type `Y` to proceed. Any other key exits cleanly with no task created.

---

## Reading the Results

### In the PowerShell window and log file

The query result appears at **STEP 8** in both the console and `gmsa_test_log.txt`.

<img width="1022" height="250" alt="image" src="https://github.com/user-attachments/assets/dbb45fb3-acb1-4457-9a51-f96c64dfe338" />

**Successful query — gMSA could read the object:**
```
[SECTION] STEP 8 : AD Query Results  *** THIS IS THE TEST RESULT ***
[SUCCESS] Query returned data - gMSA AD read SUCCESSFUL:
[SUCCESS]   Name              : SDH_ACNTEST_User_01
[SUCCESS]   SamAccountName    : SDH_ACNTEST_User_01
[SUCCESS]   objectClass       : user
[SUCCESS]   userAccountControl: 512
```

**Query ran but matched nothing:**
```
[WARN] Output file exists but is EMPTY - query returned no results.
[WARN] The gMSA ran successfully but the object was not found, or the filter matched nothing.
```

**Task failed before writing output:**
```
[ERROR] Output file not found - task likely failed before writing any output.
[ERROR] Check Step 7 error codes.
```

### In the log file

Open `gmsa_test_log.txt` in the script folder and search for `STEP 8`.


<img width="1238" height="384" alt="image" src="https://github.com/user-attachments/assets/c9bcaefd-94b1-49ac-80a2-e4554ce19e42" />


---

## Common Task Error Codes (Step 7)

| Code | Meaning | Fix |
|------|---------|-----|
| `0` | Success | — |
| `0x80070569` | Logon failure — gMSA cannot run as a batch job | Grant `SeBatchLogonRight` (see below) |
| `0x41301` | Task still running when the script checked | Increase `$SleepSecs` in `gMSA_settings.txt` |
| `0x41303` | Task has not run yet | Increase `$SleepSecs` in `gMSA_settings.txt` |

---

## SeBatchLogonRight Warning

If Step 1 warns the gMSA is not explicitly listed in `SeBatchLogonRight`, the task may
still succeed if the gMSA belongs to a group that already has the right (e.g. Administrators).
Only action this if the task fails with code `0x80070569`.

**Single machine (local):**
`secpol.msc` > Local Policies > User Rights Assignment > Log on as a batch job > Add the gMSA

**Domain-wide (GPO):**
Computer Config > Policies > Windows Settings > Security Settings > Local Policies >
User Rights Assignment > Log on as a batch job > Add the gMSA

> When adding via GPO always use **Add** — do not replace existing entries or you will
> strip the right from other accounts.

---

## Requirements

- Must be run as **Administrator**
- Machine must be **domain-joined** and able to reach a DC
- **ActiveDirectory RSAT module** — auto-installed by the script if missing and machine has internet access
- **GroupPolicy RSAT module** — only needed for `Get-GPO` queries; not auto-installed
  ```powershell
  Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0
  ```
- gMSA must **exist in AD and be enabled**
