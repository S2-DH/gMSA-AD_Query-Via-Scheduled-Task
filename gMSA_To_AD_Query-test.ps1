# ============================================================
#  gMSA_To_AD_Query-test.ps1
#  Tests whether a gMSA can run an AD query via a scheduled task.
#
#  CONFIG FILES (same folder as this script):
#    AD_query.txt      - set $Account and $AD_Query here
#    gMSA_settings.txt - gMSA source, service name, DC target, task name
#
#  OUTPUT:
#    gmsa_test_log.txt - full run log (same folder as script)
# ============================================================

#Requires -RunAsAdministrator

param(
    # Override DC_Target from gMSA_settings.txt at the command line:
    # .\gMSA_To_AD_Query-test.ps1 -Server DC01.states.local
    [string]$Server = "",

    # Override gMSA identity at the command line (bypasses service lookup):
    # .\gMSA_To_AD_Query-test.ps1 -GMSA 'states\t0_SomeOther_gMSA$'
    [string]$GMSA = ""
)

# ============================================================
# RESOLVE SCRIPT ROOT
# ============================================================
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$OutputFile = Join-Path $ScriptDir "gmsa_test_output.txt"
$LogFile    = Join-Path $ScriptDir "gmsa_test_log.txt"

# ============================================================
# LOGGING FUNCTION
# ============================================================
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","SUCCESS","SECTION")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $colour = switch ($Level) {
        "INFO"    { "Cyan"    }
        "WARN"    { "Yellow"  }
        "ERROR"   { "Red"     }
        "SUCCESS" { "Green"   }
        "SECTION" { "Magenta" }
    }
    $line = "[$timestamp][$Level] $Message"
    Write-Host $line -ForegroundColor $colour
    Add-Content -Path $LogFile -Value $line
}

New-Item -ItemType Directory -Force -Path $ScriptDir | Out-Null
"" | Out-File $LogFile -Force

Write-Log "================================================" -Level SECTION
Write-Log " gMSA Permissions Test Starting" -Level SECTION
Write-Log "================================================" -Level SECTION
Write-Log "Script folder : $ScriptDir" -Level INFO

# ============================================================
# LOAD CONFIG FILES
# Uses Invoke-Expression + Get-Content -Raw to avoid PS5.1
# issues with LF line endings in dot-sourced .txt files.
# ============================================================
$QueryConfig    = Join-Path $ScriptDir "AD_query.txt"
$SettingsConfig = Join-Path $ScriptDir "gMSA_settings.txt"

foreach ($cfg in @($QueryConfig, $SettingsConfig)) {
    if (-not (Test-Path $cfg)) {
        Write-Log "MISSING config file: $cfg" -Level ERROR
        Write-Log "Create it in the same folder as this script and re-run." -Level ERROR
        exit 1
    }
    Write-Log "Loading : $cfg" -Level INFO
    try {
        $cfgContent = Get-Content -Path $cfg -Raw -Encoding UTF8
        Invoke-Expression $cfgContent
    } catch {
        Write-Log "Failed to load config file $cfg : $_" -Level ERROR
        exit 1
    }
}

# ============================================================
# POST-LOAD CONFIG DUMP
# ============================================================
Write-Log "------------------------------------------------" -Level SECTION
Write-Log "CONFIG LOADED - values read from files:" -Level SECTION
Write-Log "  gMSA_Source      = '$gMSA_Source'"      -Level INFO
Write-Log "  gMSA_ServiceName = '$gMSA_ServiceName'" -Level INFO
Write-Log "  gMSA_Manual      = '$gMSA_Manual'"      -Level INFO
Write-Log "  DC_Target        = '$DC_Target'"         -Level INFO
Write-Log "  TaskName         = '$TaskName'"          -Level INFO
Write-Log "  SleepSecs        = '$SleepSecs'"         -Level INFO
Write-Log "  Account          = '$Account'"           -Level INFO
Write-Log "  AD_Query         = '$AD_Query'"          -Level INFO

$configOk = $true
if ([string]::IsNullOrWhiteSpace($gMSA_Source))     { Write-Log "gMSA_Source not set in gMSA_settings.txt"     -Level ERROR; $configOk = $false }
if ([string]::IsNullOrWhiteSpace($gMSA_ServiceName)){ Write-Log "gMSA_ServiceName not set in gMSA_settings.txt" -Level ERROR; $configOk = $false }
if ([string]::IsNullOrWhiteSpace($TaskName))         { Write-Log "TaskName not set in gMSA_settings.txt"         -Level ERROR; $configOk = $false }
if ([string]::IsNullOrWhiteSpace($Account))          { Write-Log "Account not set in AD_query.txt"               -Level ERROR; $configOk = $false }
if ([string]::IsNullOrWhiteSpace($AD_Query))         { Write-Log "AD_Query not set in AD_query.txt"              -Level ERROR; $configOk = $false }
if (-not $configOk) {
    Write-Log "One or more required config values are missing. Fix the files above and re-run." -Level ERROR
    exit 1
}

if ($Account -match "^<.*>$" -or $Account -eq "user@domain.com") {
    Write-Log "WARNING: Account still contains placeholder value '$Account'" -Level WARN
    Write-Log "         Edit AD_query.txt with a real account before testing." -Level WARN
}

# Command-line -Server overrides DC_Target from settings file
if (-not [string]::IsNullOrWhiteSpace($Server)) {
    Write-Log "Command-line -Server '$Server' overrides DC_Target setting." -Level INFO
    $DC_Target = $Server
}

# Command-line -GMSA overrides gMSA_Source/gMSA_Manual from settings file
if (-not [string]::IsNullOrWhiteSpace($GMSA)) {
    Write-Log "Command-line -GMSA '$GMSA' overrides gMSA settings." -Level INFO
    $gMSA_Source = "manual"
    $gMSA_Manual = $GMSA
}

# Inject -Server into query if DC_Target is set
if (-not [string]::IsNullOrWhiteSpace($DC_Target)) {
    Write-Log "DC_Target specified - injecting -Server '$DC_Target' into query." -Level INFO
    $AD_Query = $AD_Query -replace '(Get-AD\S+)', "`$1 -Server '$DC_Target'"
    Write-Log "  Updated query: $AD_Query" -Level INFO
}

Write-Log "Config validation passed." -Level SUCCESS

# ============================================================
# STEP 0 - RESOLVE gMSA IDENTITY
# ============================================================
Write-Log "------------------------------------------------" -Level SECTION
Write-Log "STEP 0 : Resolving gMSA Identity" -Level SECTION

if ($gMSA_Source -eq "auto") {
    Write-Log "gMSA Source : AUTO - detecting from service '$gMSA_ServiceName'" -Level INFO
    try {
        $svc = Get-WmiObject Win32_Service -Filter "Name='$gMSA_ServiceName'" -ErrorAction Stop
        if ($svc) {
            $gMSA = $svc.StartName
            Write-Log "Service '$gMSA_ServiceName' found." -Level SUCCESS
            Write-Log "Service runs as : $gMSA" -Level SUCCESS
            if ([string]::IsNullOrWhiteSpace($gMSA) -or
                $gMSA -match "^(LocalSystem|NT AUTHORITY\\.*|LOCAL SERVICE|NETWORK SERVICE)$") {
                Write-Log "StartName '$gMSA' is not a domain gMSA. Falling back to manual." -Level WARN
                $gMSA = $gMSA_Manual
                Write-Log "Using manual gMSA : $gMSA" -Level WARN
            }
        } else {
            Write-Log "Service '$gMSA_ServiceName' NOT found on this machine." -Level ERROR
            Write-Log "Tip: run Get-Service | Where-Object { $_.DisplayName -like '*Sharp*' } | Select Name, DisplayName" -Level WARN
            Write-Log "     Use the 'Name' column value (not DisplayName) in gMSA_settings.txt" -Level WARN
            Write-Log "Falling back to manual gMSA value." -Level WARN
            $gMSA = $gMSA_Manual
        }
    } catch {
        Write-Log "Failed to query service '$gMSA_ServiceName': $_" -Level ERROR
        Write-Log "Falling back to manual gMSA value." -Level WARN
        $gMSA = $gMSA_Manual
    }
} else {
    $gMSA = $gMSA_Manual
    Write-Log "gMSA Source : MANUAL - using '$gMSA'" -Level INFO
}

if ([string]::IsNullOrWhiteSpace($gMSA)) {
    Write-Log "gMSA identity could not be resolved." -Level ERROR
    Write-Log "Set gMSA_Manual in gMSA_settings.txt or ensure '$gMSA_ServiceName' is running." -Level ERROR
    exit 1
}

# ============================================================
# PRE-FLIGHT SUMMARY + CONFIRMATION PROMPT
# Detect query type and surface relevant tips before committing.
# ============================================================
Write-Log "------------------------------------------------" -Level SECTION
Write-Log "PRE-FLIGHT SUMMARY" -Level SECTION

# Resolve DC display - check DC_Target first, then scan the query for -Server
if (-not [string]::IsNullOrWhiteSpace($DC_Target)) {
    $dcDisplay = $DC_Target
    $dcSource  = "gMSA_settings.txt (DC_Target)"
} elseif ($AD_Query -match '-Server\s+([\w\.\-]+)') {
    $dcDisplay = $Matches[1]
    $dcSource  = "AD_query.txt (-Server in query)"
} else {
    $dcDisplay = "(auto - nearest DC)"
    $dcSource  = "auto"
}

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor White
Write-Host "   PRE-FLIGHT CHECK - Please confirm before the task is created" -ForegroundColor White
Write-Host "  ============================================================" -ForegroundColor White
Write-Host ""
Write-Host "   Query    : " -NoNewline -ForegroundColor Gray
Write-Host $AD_Query -ForegroundColor Cyan
Write-Host "   gMSA     : " -NoNewline -ForegroundColor Gray
Write-Host $gMSA -ForegroundColor Cyan
Write-Host "   DC       : " -NoNewline -ForegroundColor Gray
Write-Host $dcDisplay -ForegroundColor Cyan
Write-Host "   Account  : " -NoNewline -ForegroundColor Gray
Write-Host $Account -ForegroundColor Cyan
Write-Host ""

# Detect query type and show relevant tips
$queryType = "unknown"
if ($AD_Query -match "Get-GPO|groupPolicyContainer")         { $queryType = "gpo" }
elseif ($AD_Query -match "Get-ADOrganizationalUnit")          { $queryType = "ou" }
elseif ($AD_Query -match "Get-ADGroupMember")                 { $queryType = "groupmember" }
elseif ($AD_Query -match "Get-ADGroup")                       { $queryType = "group" }
elseif ($AD_Query -match "Get-ADComputer|Get-ADDomainController") { $queryType = "computer" }
elseif ($AD_Query -match "Get-ADServiceAccount")              { $queryType = "gmsa" }
elseif ($AD_Query -match "Get-ADUser")                        { $queryType = "user" }
elseif ($AD_Query -match "Get-ADObject")                      { $queryType = "object" }

switch ($queryType) {
    "gpo" {
        Write-Host "  [TIP] GPO Query detected:" -ForegroundColor Yellow
        if ($AD_Query -match "Get-GPO") {
            Write-Host "        You are using Get-GPO which requires the GroupPolicy module." -ForegroundColor Yellow
            Write-Host "        This module is part of GPMC RSAT - it must be installed on this" -ForegroundColor Yellow
            Write-Host "        machine AND available in the gMSA scheduled task context." -ForegroundColor Yellow
            Write-Host "        If the task fails, switch to the Get-ADObject GPO query instead:" -ForegroundColor Yellow
            Write-Host "        Get-ADObject -Filter {objectClass -eq 'groupPolicyContainer'}" -ForegroundColor DarkYellow
        } else {
            Write-Host "        Using Get-ADObject for GPO lookup - no extra modules needed." -ForegroundColor Green
        }
        Write-Host ""
    }
    "ou" {
        Write-Host "  [TIP] OU Query detected:" -ForegroundColor Yellow
        Write-Host "        OUs do not have a SamAccountName." -ForegroundColor Yellow
        Write-Host "        Account must be a full Distinguished Name, e.g.:" -ForegroundColor Yellow
        Write-Host "        OU=Tier Zero,OU=STRATA,DC=states,DC=local" -ForegroundColor DarkYellow
        if ($Account -notmatch "^OU=|^CN=|^DC=") {
            Write-Host "        WARNING: Account '$Account' does not look like a DN." -ForegroundColor Red
            Write-Host "                 Update AD_query.txt before continuing." -ForegroundColor Red
        }
        Write-Host ""
    }
    "group" {
        Write-Host "  [TIP] Group Query detected:" -ForegroundColor Yellow
        Write-Host "        Account should be the group name or DN." -ForegroundColor Yellow
        Write-Host "        To list members use Get-ADGroupMember instead of Get-ADGroup." -ForegroundColor Yellow
        Write-Host ""
    }
    "groupmember" {
        Write-Host "  [TIP] Group Member Query detected:" -ForegroundColor Yellow
        Write-Host "        Account should be the group name or DN." -ForegroundColor Yellow
        Write-Host "        Add -Recursive to expand nested group membership." -ForegroundColor Yellow
        Write-Host ""
    }
    "computer" {
        Write-Host "  [TIP] Computer/DC Query detected:" -ForegroundColor Yellow
        Write-Host "        Account should be the computer name (without the trailing dollar sign)." -ForegroundColor Yellow
        Write-Host ""
    }
    "gmsa" {
        Write-Host "  [TIP] gMSA/Service Account Query detected:" -ForegroundColor Yellow
        Write-Host "        Remember to include the trailing dollar sign in the account name." -ForegroundColor Yellow
        Write-Host "        Example: t0_gMSA_SHSA`$" -ForegroundColor DarkYellow
        Write-Host ""
    }
}

# Log the pre-flight details
Write-Log "Query    : $AD_Query" -Level INFO
Write-Log "gMSA     : $gMSA"    -Level INFO
Write-Log "DC       : $dcDisplay  (source: $dcSource)" -Level INFO
Write-Log "Account  : $Account"  -Level INFO
Write-Log "QueryType detected : $queryType" -Level INFO

# Confirmation prompt
Write-Host "  ============================================================" -ForegroundColor White
Write-Host ""
$confirm = Read-Host "  Is this correct? Type Y to continue or any other key to exit"
Write-Host ""

if ($confirm -ne "Y" -and $confirm -ne "y") {
    Write-Log "User chose to exit at pre-flight check. No task was created." -Level WARN
    Write-Host "  Exiting. Edit your config files and re-run." -ForegroundColor Yellow
    exit 0
}

Write-Log "Pre-flight confirmed by user. Proceeding..." -Level SUCCESS

# ============================================================
# STEP 1 - CHECK gMSA EXISTS IN AD + BATCH LOGON RIGHT
# ============================================================
Write-Log "------------------------------------------------" -Level SECTION
Write-Log "STEP 1 : Checking gMSA account exists in AD" -Level SECTION

try {
    $gmsaName = $gMSA.Split("\")[1]
    $gmsaObj  = Get-ADServiceAccount -Identity $gmsaName -Properties * -ErrorAction Stop
    Write-Log "gMSA found       : $($gmsaObj.DistinguishedName)" -Level SUCCESS
    Write-Log "gMSA Enabled     : $($gmsaObj.Enabled)"
    Write-Log "gMSA objectClass : $($gmsaObj.objectClass)"
} catch {
    Write-Log "Could not find gMSA '$gMSA' in AD. Error: $_" -Level ERROR
    Write-Log "Ensure the gMSA exists and this script is run with sufficient AD read rights." -Level WARN
}

Write-Log "Checking 'Log on as a batch job' right for $gMSA ..."
try {
    & secedit /export /cfg "$env:TEMP\secedit_export.cfg" /quiet
    $batchRight = Select-String -Path "$env:TEMP\secedit_export.cfg" -Pattern "SeBatchLogonRight"
    if ($batchRight) {
        Write-Log "SeBatchLogonRight entry: $($batchRight.Line)" -Level INFO
        if ($batchRight.Line -match [regex]::Escape($gmsaName)) {
            Write-Log "gMSA has 'Log on as a batch job' right." -Level SUCCESS
        } else {
            Write-Log "gMSA not explicitly listed in SeBatchLogonRight." -Level WARN
            Write-Log "May still run if a group it belongs to has the right (e.g. Administrators)." -Level WARN
        }
    } else {
        Write-Log "Could not determine SeBatchLogonRight from secedit export." -Level WARN
    }
} catch {
    Write-Log "secedit check failed: $_" -Level WARN
}

# ============================================================
# STEP 2 - CHECK MODULES
# ============================================================
Write-Log "------------------------------------------------" -Level SECTION
Write-Log "STEP 2 : Checking required modules" -Level SECTION

$adModule = Get-Module -ListAvailable -Name ActiveDirectory
if ($adModule) {
    Write-Log "ActiveDirectory module found : Version $($adModule.Version)" -Level SUCCESS
} else {
    Write-Log "ActiveDirectory module NOT found. Attempting RSAT install..." -Level WARN
    try {
        Add-WindowsCapability -Online -Name "Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0" -ErrorAction Stop
        Write-Log "RSAT AD module installed successfully." -Level SUCCESS
    } catch {
        Write-Log "Failed to install RSAT AD module: $_" -Level ERROR
        Write-Log "Install manually: Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0" -Level WARN
    }
}

# Check GroupPolicy module only if the query needs it
if ($queryType -eq "gpo" -and $AD_Query -match "Get-GPO") {
    $gpModule = Get-Module -ListAvailable -Name GroupPolicy
    if ($gpModule) {
        Write-Log "GroupPolicy module found : Version $($gpModule.Version)" -Level SUCCESS
    } else {
        Write-Log "GroupPolicy module NOT found - your GPO query uses Get-GPO which requires it." -Level ERROR
        Write-Log "Install GPMC RSAT: Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0" -Level WARN
        Write-Log "Or switch to the Get-ADObject GPO query in AD_query.txt which needs no extra modules." -Level WARN
    }
}

# ============================================================
# STEP 3 - CLEAN UP ANY EXISTING TASK
# ============================================================
Write-Log "------------------------------------------------" -Level SECTION
Write-Log "STEP 3 : Cleaning up any existing task named '$TaskName'" -Level SECTION

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Log "Existing task removed." -Level WARN
} else {
    Write-Log "No existing task found - OK to proceed." -Level INFO
}

# ============================================================
# STEP 4 - REGISTER SCHEDULED TASK
# ============================================================
Write-Log "------------------------------------------------" -Level SECTION
Write-Log "STEP 4 : Registering Scheduled Task as $gMSA" -Level SECTION

$psCommand = @"
try {
    Import-Module ActiveDirectory -ErrorAction Stop
    `$result = $AD_Query -ErrorAction Stop
    if (`$result) {
        `$result | Out-File '$OutputFile'
    } else {
        "Query returned no results. Query was: $AD_Query" | Out-File '$OutputFile'
    }
} catch {
    "ERROR: `$_`nQuery was: $AD_Query" | Out-File '$OutputFile'
}
"@

$encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($psCommand))

try {
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -EncodedCommand $encodedCommand"
    $principal = New-ScheduledTaskPrincipal -UserId $gMSA -LogonType Password
    Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null
    Write-Log "Scheduled task '$TaskName' registered successfully." -Level SUCCESS
} catch {
    Write-Log "Failed to register scheduled task: $_" -Level ERROR
    exit 1
}

# ============================================================
# STEP 5 - VERIFY TASK
# ============================================================
Write-Log "------------------------------------------------" -Level SECTION
Write-Log "STEP 5 : Verifying task registration" -Level SECTION

$taskCheck = Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName, State, @{Name="UserId";Expression={$_.Principal.UserId}}
Write-Log "Task Name  : $($taskCheck.TaskName)"
Write-Log "Task State : $($taskCheck.State)"
Write-Log "Runs As    : $($taskCheck.UserId)"

# ============================================================
# STEP 6 - RUN THE TASK
# ============================================================
Write-Log "------------------------------------------------" -Level SECTION
Write-Log "STEP 6 : Starting task..." -Level SECTION

try {
    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    Write-Log "Task started. Waiting $SleepSecs seconds for completion..." -Level INFO
} catch {
    Write-Log "Failed to start task: $_" -Level ERROR
    exit 1
}

for ($i = $SleepSecs; $i -gt 0; $i--) {
    Write-Host "`r  Waiting... $i seconds remaining   " -NoNewline -ForegroundColor DarkCyan
    Start-Sleep -Seconds 1
}
Write-Host ""

# ============================================================
# STEP 7 - CHECK TASK RESULT + EVENT LOG
# ============================================================
Write-Log "------------------------------------------------" -Level SECTION
Write-Log "STEP 7 : Checking task result and event log" -Level SECTION

$taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName
Write-Log "Last Run Time   : $($taskInfo.LastRunTime)"
Write-Log "Last Run Result : $($taskInfo.LastTaskResult)"

if ($taskInfo.LastTaskResult -eq 0) {
    Write-Log "Task completed successfully (return code 0)." -Level SUCCESS
} else {
    $hexCode = "0x{0:X8}" -f $taskInfo.LastTaskResult
    Write-Log "Task returned non-zero code: $($taskInfo.LastTaskResult) ($hexCode)" -Level ERROR
}

Write-Log "Pulling Task Scheduler events for '$TaskName'..." -Level INFO
try {
    $events = Get-WinEvent -LogName "Microsoft-Windows-TaskScheduler/Operational" -ErrorAction Stop |
              Where-Object { $_.Message -match $TaskName } |
              Select-Object -Last 10
    if ($events) {
        foreach ($evt in $events) {
            $evtLevel = if ($evt.LevelDisplayName) { $evt.LevelDisplayName } else { "Info" }
            Write-Log "  [Event $($evt.Id)][$evtLevel] $($evt.TimeCreated) - $($evt.Message.Split([Environment]::NewLine)[0])" -Level INFO
        }
    } else {
        Write-Log "No Task Scheduler events found for '$TaskName'." -Level WARN
    }
} catch {
    Write-Log "Could not read Task Scheduler event log: $_" -Level WARN
}

# ============================================================
# STEP 8 - *** QUERY RESULTS ***
# ============================================================
Write-Log "------------------------------------------------" -Level SECTION
Write-Log "STEP 8 : AD Query Results  *** THIS IS THE TEST RESULT ***" -Level SECTION

if (Test-Path $OutputFile) {
    $content = Get-Content $OutputFile
    if ($content) {
        Write-Log "Query returned data - gMSA AD read SUCCESSFUL:" -Level SUCCESS
        $content | ForEach-Object { Write-Log "  $_" -Level SUCCESS }
    } else {
        Write-Log "Output file exists but is EMPTY - query returned no results." -Level WARN
        Write-Log "The gMSA ran successfully but the object was not found, or the filter matched nothing." -Level WARN
    }
} else {
    Write-Log "Output file not found at '$OutputFile'." -Level ERROR
    Write-Log "The task likely failed before writing any output. Check Step 7 error codes." -Level ERROR
}

# ============================================================
# STEP 9 - CLEANUP
# ============================================================
Write-Log "------------------------------------------------" -Level SECTION
Write-Log "STEP 9 : Cleanup" -Level SECTION

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Log "Scheduled task '$TaskName' removed." -Level INFO

if (Test-Path $OutputFile) {
    Remove-Item $OutputFile -Force
    Write-Log "Temporary output file removed." -Level INFO
}

Write-Log "================================================" -Level SECTION
Write-Log " Test Complete. Full log: $LogFile" -Level SECTION
Write-Log "================================================" -Level SECTION
