# gMSA AD Query Tester

Tests whether a gMSA account (e.g. the SharpHound/BHE service account) can successfully
authenticate as a scheduled task and run an AD query against your domain.

---

## Folder Contents

| File | Purpose |
|------|---------|
| `gMSA_To_AD_Query-test.ps1` | Main script — do not edit |
| `AD_query.txt` | **Edit before each run** — set account and query |
| `gMSA_settings.txt` | **Edit once per environment** — service name, DC target, task name |
| `gmsa_test_log.txt` | Auto-generated — full run output including query results |

---

## Quick Start

1. Edit `AD_query.txt` — set `$Account` to a real UPN/SamAccountName in your domain.
2. Optionally edit `gMSA_settings.txt` — verify service name and DC target.
3. Run the script from an elevated PowerShell prompt:

```powershell
cd C:\path\to\TEST_gMSA-ScheduledTask
.\gMSA_To_AD_Query-test.ps1
```

4. Check the log for results — **STEP 8** contains the AD query output.

---

## Config Files

### AD_query.txt

Edit this file before every test run.

```powershell
# Account to query - UPN, SamAccountName, or DN
$Account = "someuser@states.local"

# The AD query to run as the gMSA (one uncommented at a time)
# Do NOT add -Server here  - controlled by DC_Target in gMSA_settings.txt
# Do NOT add | Out-File    - handled automatically
$AD_Query = "Get-ADObject -Filter {UserPrincipalName -eq '$Account'} ..."
```

Example queries (uncomment in the file):

| What to test | Query |
|---|---|
| User by UPN | `Get-ADObject -Filter {UserPrincipalName -eq '$Account'} -Properties userAccountControl, objectClass` |
| User directly | `Get-ADUser '$Account' -Properties userAccountControl` |
| gMSA itself | `Get-ADServiceAccount 't0_gMSA_SHSA$' -Properties *` |
| Group members | `Get-ADGroup 'Domain Admins' -Properties Members` |
| Computer/DC | `Get-ADComputer 'DC01' -Properties *` |


### gMSA_settings.txt

Edit once per environment. Settings:

| Setting | Default | Description |
|---|---|---|
| `$gMSA_Source` | `auto` | `auto` = read gMSA from service; `manual` = use `$gMSA_Manual` |
| `$gMSA_ServiceName` | `SharpHoundDelegator` | Windows service name whose `StartName` is the gMSA |
| `$gMSA_Manual` | `states\t0_gMSA_SHSA$` | Fallback if auto-detect fails or source is manual |
| `$DC_Target` | *(blank)* | Optional: force query to a specific DC (FQDN or hostname) |
| `$TaskName` | `TestgMSAPermissions` | Name used for the temporary scheduled task |
| `$SleepSecs` | `10` | Seconds to wait after starting the task before reading results |

**DC targeting example** — to force the query to `DC01.states.local`:

```powershell
$DC_Target = "DC01.states.local"
```

Leave `$DC_Target = ""` to let AD auto-select the nearest DC.

---

## What the Script Does (Step by Step)

| Step | What happens |
|------|-------------|
| **Config load** | Reads both config files; dumps all values to log so stale files are obvious |
| **Step 0** | Resolves the gMSA identity — auto from service or manual fallback |
| **Step 1** | Confirms gMSA exists in AD; checks `SeBatchLogonRight` on this machine |
| **Step 2** | Verifies the ActiveDirectory RSAT module is installed; installs if missing |
| **Step 3** | Removes any leftover scheduled task from a previous failed run |
| **Step 4** | Registers a new scheduled task that runs the AD query **as the gMSA** |
| **Step 5** | Confirms the task registered correctly and is set to run as the right identity |
| **Step 6** | Starts the task and waits for it to complete |
| **Step 7** | Reads the task result code and pulls Task Scheduler event log entries |
| **Step 8** | **Reads and logs the AD query output — this is the actual test result** |
| **Step 9** | Removes the temporary task and output file; leaves only the log |

---

## Reading the Log — Where is the Test Result?

Open `gmsa_test_log.txt` and search for **STEP 8**.

**Successful query:**
```
[SUCCESS] STEP 8 : AD Query Results  *** THIS IS THE TEST RESULT ***
[SUCCESS] Query returned data - gMSA AD read SUCCESSFUL:
[SUCCESS]   Name              : SDH_ACNTEST_User_01
[SUCCESS]   SamAccountName    : SDH_ACNTEST_User_01
[SUCCESS]   objectClass       : user
[SUCCESS]   userAccountControl: 512
```

**Query ran but returned nothing (account not found / filter matched nothing):**
```
[WARN] Output file exists but is EMPTY - query returned no results.
[WARN] The gMSA ran successfully but the object was not found, or the query matched nothing.
```

**Task failed before completing:**
```
[ERROR] Output file not found - task likely failed before writing any output.
```
Check Step 7 for the error code. Common codes:

| Code | Meaning |
|------|---------|
| `0` | Success |
| `0x80070569` | Logon failure — gMSA not allowed to run as a batch job on this machine |
| `0x41301` | Task is still running — increase `$SleepSecs` in `gMSA_settings.txt` |
| `0x41303` | Task has not run yet |

---

## SeBatchLogonRight Warning

If Step 1 warns the gMSA is not listed in `SeBatchLogonRight`, the task may still succeed
if the gMSA belongs to a group that has the right (e.g. Administrators, S-1-5-32-544).
If the task fails with code `0x80070569`, apply the right via:

- **Local:** `secpol.msc` > Local Policies > User Rights Assignment > Log on as a batch job
- **Domain GPO:** Computer Config > Policies > Windows Settings > Security Settings > Local Policies > User Rights Assignment

---

## Requirements

- Must be run as Administrator
- ActiveDirectory RSAT module (auto-installed if missing and machine has internet access)
- gMSA must exist in AD and be enabled
- Machine must be domain-joined and able to reach a DC
