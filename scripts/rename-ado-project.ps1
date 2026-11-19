[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$Organization,

    [Parameter(Mandatory = $true)]
    [string]$ExistingProjectName,

    [Parameter(Mandatory = $true)]
    [string]$NewProjectName,

    [Parameter(Mandatory = $false)]
    [string]$ApiVersion = "7.1",

    [Parameter(Mandatory = $false)]
    [int]$MaxAttempts = 60,

    [Parameter(Mandatory = $false)]
    [int]$PollingInterval = 10
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------
# CONFIGURATION
# ------------------------------------------------

$PAT = $env:ADO_PAT
if ([string]::IsNullOrWhiteSpace($PAT) -or $PAT -like "`$(*") {
    if (-not [string]::IsNullOrWhiteSpace($env:ADO_PAT_FALLBACK) -and -not ($env:ADO_PAT_FALLBACK -like "`$(*")) {
        $PAT = $env:ADO_PAT_FALLBACK
    }
}
$BaseUrl = "https://dev.azure.com/$Organization"

# ------------------------------------------------
# LOGGING FUNCTIONS
# ------------------------------------------------

function Write-Info($Message) {
    Write-Host "##[section]INFO: $Message"
}

function Write-Success($Message) {
    Write-Host "##[section]SUCCESS: $Message"
}

function Write-WarningMessage($Message) {
    Write-Host "##[warning]WARNING: $Message"
}

function Write-Failure($Message) {
    Write-Host "##[error]ERROR: $Message"
}

# ------------------------------------------------
# HEADER
# ------------------------------------------------

Write-Host ""
Write-Host "=================================================="
Write-Host "        AZURE DEVOPS PROJECT RENAME"
Write-Host "=================================================="

Write-Info "Starting project rename process."

# ------------------------------------------------
# INPUT VALIDATION
# ------------------------------------------------

if ([string]::IsNullOrWhiteSpace($Organization)) {
    throw "Azure DevOps organization name is empty."
}

if ([string]::IsNullOrWhiteSpace($ExistingProjectName)) {
    throw "Existing project name is empty."
}

if ([string]::IsNullOrWhiteSpace($NewProjectName)) {
    throw "New project name is empty."
}

if ([string]::IsNullOrWhiteSpace($PAT)) {
    throw "ADO PAT is missing. Check ADO-Secrets Variable Group."
}

# Clean any enclosing quotes passed via command line
$Organization = $Organization.Trim('"').Trim("'").Trim()
$ExistingProjectName = $ExistingProjectName.Trim('"').Trim("'").Trim()
$NewProjectName = $NewProjectName.Trim('"').Trim("'").Trim()

if ($ExistingProjectName -eq $NewProjectName) {
    Write-WarningMessage "Existing and new project names are identical."
    Write-WarningMessage "No rename operation is required."

    Write-Host "##vso[task.setvariable variable=ProjectRenameStatus]NoChange"

    exit 0
}

Write-Info "Organization       : $Organization"
Write-Info "Existing Project   : $ExistingProjectName"
Write-Info "New Project Name   : $NewProjectName"
Write-Info "API Version        : $ApiVersion"

# ------------------------------------------------
# AUTHENTICATION
# ------------------------------------------------

Write-Info "Preparing Azure DevOps authentication."

$EncodedPAT = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes(":$PAT")
)

$Headers = @{
    Authorization = "Basic $EncodedPAT"
    "Content-Type" = "application/json"
    Accept = "application/json"
}

Write-Success "Authentication headers prepared."

# ------------------------------------------------
# VERIFY PAT AUTHENTICATION
# ------------------------------------------------

Write-Host ""
Write-Info "Verifying PAT token access for organization '$Organization'..."

$ConnectionUrl = "$BaseUrl/_apis/connectionData?api-version=$ApiVersion"

try {
    $ConnResponse = Invoke-WebRequest `
        -Uri $ConnectionUrl `
        -Method Get `
        -Headers $Headers `
        -UseBasicParsing

    if ($ConnResponse.Content -match "<html|SPS\.Authentication|signin") {
        Write-Failure "AUTHENTICATION FAILED: Azure DevOps returned an HTML sign-in page instead of JSON."
        Write-Failure "The Personal Access Token (PAT) is invalid, expired, or not authorized for '$Organization'."
        throw "Authentication rejected for organization '$Organization'. Check that the PAT is created in this org with 'Project: Read, write & manage' scope."
    }

    $ConnData = $ConnResponse.Content | ConvertFrom-Json
    $UserName = if ($ConnData.authenticatedUser.providerDisplayName) { $ConnData.authenticatedUser.providerDisplayName } else { $ConnData.authenticatedUser.customDisplayName }
    Write-Success "Authentication verified! Authenticated as: $UserName"
}
catch {
    Write-Failure "Authentication check failed: $($_.Exception.Message)"
    throw "Azure DevOps rejected the PAT token for organization '$Organization'. Check your secret variable in ADO-Secrets."
}

# ------------------------------------------------
# FUNCTION: GET PROJECT
# ------------------------------------------------

function Get-AdoProject {

    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectName
    )

    $EncodedName = [uri]::EscapeDataString($ProjectName)

    $Url = "$BaseUrl/_apis/projects/$EncodedName" +
           "?api-version=$ApiVersion"

    $HttpStatus = 0

    $Response = Invoke-RestMethod `
        -Uri $Url `
        -Method Get `
        -Headers $Headers `
        -SkipHttpErrorCheck `
        -StatusCodeVariable HttpStatus

    if ([int]$HttpStatus -eq 200) {
        return $Response
    }

    if ([int]$HttpStatus -eq 404) {
        return $null
    }

    throw "Project lookup failed for '$ProjectName'. HTTP Status: $HttpStatus"
}

# ------------------------------------------------
# CHECK EXISTING PROJECT
# ------------------------------------------------

Write-Host ""
Write-Info "Checking whether the existing project exists..."

try {

    $ExistingProject = Get-AdoProject `
        -ProjectName $ExistingProjectName

    if ($null -eq $ExistingProject) {

        Write-Failure "EXISTING PROJECT NOT FOUND!"

        Write-Failure "Project Name: $ExistingProjectName"

        throw "Cannot rename a project that does not exist."
    }

    Write-Success "Existing project found."

    Write-Host "--------------------------------------------------"
    Write-Host "Project Name : $($ExistingProject.name)"
    Write-Host "Project ID   : $($ExistingProject.id)"
    Write-Host "Project State: $($ExistingProject.state)"
    Write-Host "--------------------------------------------------"

    if ($ExistingProject.state -ne "wellFormed") {
        throw "Project is not in a ready state. Current state: $($ExistingProject.state)"
    }

}
catch {

    Write-Failure "Existing project validation failed."
    Write-Failure $_.Exception.Message

    throw
}

# ------------------------------------------------
# CHECK WHETHER NEW PROJECT NAME ALREADY EXISTS
# ------------------------------------------------

Write-Host ""
Write-Info "Checking whether the requested new project name is available..."

try {

    $TargetProject = Get-AdoProject `
        -ProjectName $NewProjectName

    if ($null -ne $TargetProject) {

        Write-Failure "NEW PROJECT NAME ALREADY EXISTS!"

        Write-Host "--------------------------------------------------"
        Write-Host "Requested Name : $NewProjectName"
        Write-Host "Existing ID    : $($TargetProject.id)"
        Write-Host "--------------------------------------------------"

        throw "Rename cancelled. Another project already uses the requested name."
    }

    Write-Success "Requested new project name is available."

}
catch {

    Write-Failure "New project name validation failed."
    Write-Failure $_.Exception.Message

    throw
}

# ------------------------------------------------
# RENAME PROJECT
# ------------------------------------------------

Write-Host ""
Write-Info "Submitting project rename request..."

$ProjectId = $ExistingProject.id

$RenameUrl = "$BaseUrl/_apis/projects/$ProjectId" +
             "?api-version=$ApiVersion"

$Body = @{
    name = $NewProjectName
} | ConvertTo-Json -Depth 5

$OperationUrl = $null
$OperationId = $null

try {

    $RenameResponse = Invoke-WebRequest `
        -Uri $RenameUrl `
        -Method Patch `
        -Headers $Headers `
        -ContentType "application/json" `
        -Body $Body

    Write-Success "Project rename request submitted (HTTP $($RenameResponse.StatusCode))."

    # Attempt to parse response body if present
    $ResponseBody = $null
    if ($RenameResponse.Content) {
        try {
            $ResponseBody = $RenameResponse.Content | ConvertFrom-Json
        }
        catch {
            Write-Info "Raw response content: $($RenameResponse.Content)"
        }
    }

    # Extract Operation URL / ID from JSON body
    if ($ResponseBody) {
        if ($ResponseBody.url) {
            $OperationUrl = $ResponseBody.url
        }
        if ($ResponseBody.id) {
            $OperationId = $ResponseBody.id
        }
        if ($ResponseBody.status) {
            Write-Host "Initial Status: $($ResponseBody.status)"
        }
    }

    # Extract from HTTP Location header if body did not contain the URL
    if ([string]::IsNullOrWhiteSpace($OperationUrl) -and $RenameResponse.Headers) {
        $LocationValue = $null

        # PowerShell Core (.Location on HttpResponseHeaders)
        if ($RenameResponse.Headers.Location) {
            $LocationValue = $RenameResponse.Headers.Location.ToString()
        }
        # Dictionary indexer (Windows PowerShell)
        elseif ($RenameResponse.Headers['Location']) {
            $LocationValue = "$($RenameResponse.Headers['Location'])"
        }
        # Case-insensitive header scan
        else {
            foreach ($k in $RenameResponse.Headers.Keys) {
                if ($k -eq "Location" -or $k -eq "location") {
                    $v = $RenameResponse.Headers[$k]
                    if ($v -is [array]) { $v = $v[0] }
                    $LocationValue = "$v"
                    break
                }
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($LocationValue)) {
            $OperationUrl = $LocationValue
        }
    }

    # Extract Operation ID from Operation URL if ID is still blank
    if ([string]::IsNullOrWhiteSpace($OperationId) -and -not [string]::IsNullOrWhiteSpace($OperationUrl)) {
        if ($OperationUrl -match '/_apis/operations/([a-f0-9\-]+)') {
            $OperationId = $matches[1]
        }
    }

    # If we have an ID but no URL, construct it
    if ([string]::IsNullOrWhiteSpace($OperationUrl) -and -not [string]::IsNullOrWhiteSpace($OperationId)) {
        $OperationUrl = "$BaseUrl/_apis/operations/$OperationId`?api-version=7.1-preview.1"
    }

    Write-Host "Project ID    : $ProjectId"
    if (-not [string]::IsNullOrWhiteSpace($OperationId)) {
        Write-Host "Operation ID  : $OperationId"
    }
    if (-not [string]::IsNullOrWhiteSpace($OperationUrl)) {
        Write-Host "Operation URL : $OperationUrl"
    }

}
catch {

    Write-Failure "Project rename request failed."
    Write-Failure $_.Exception.Message

    if ($_.Exception.Response) {
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $errorDetails = $reader.ReadToEnd()
            Write-Failure "Details: $errorDetails"
        }
        catch {}
    }

    throw "Azure DevOps project rename failed."
}

# ------------------------------------------------
# MONITOR RENAME OPERATION
# ------------------------------------------------

Write-Host ""
Write-Info "Waiting for Azure DevOps to complete project rename..."

$Completed = $false

if (-not [string]::IsNullOrWhiteSpace($OperationUrl)) {

    for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {

        Write-Host ""
        Write-Info "Checking rename status. Attempt $Attempt of $MaxAttempts"

        try {

            $Operation = Invoke-RestMethod `
                -Uri $OperationUrl `
                -Method Get `
                -Headers $Headers

            $Status = $Operation.status

            Write-Host "Current Operation Status: $Status"

            switch ($Status) {

                "succeeded" {
                    $Completed = $true
                    Write-Success "Project rename operation completed."
                    break
                }

                "failed" {
                    Write-Failure "Azure DevOps reported rename failure."
                    Write-Host ($Operation | ConvertTo-Json -Depth 10)
                    throw "Project rename operation failed."
                }

                "cancelled" {
                    Write-Failure "Project rename operation was cancelled."
                    throw "Project rename was cancelled."
                }

                default {
                    Write-Info "Project rename is still in progress."
                    Start-Sleep -Seconds $PollingInterval
                }
            }

            if ($Completed) {
                break
            }

        }
        catch {
            Write-Failure "Error while monitoring rename operation."
            Write-Failure $_.Exception.Message
            throw
        }
    }
}
else {
    # Fallback: Poll new project name directly
    Write-WarningMessage "No operation endpoint returned by Azure DevOps. Polling project directly..."

    for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {

        Write-Host ""
        Write-Info "Checking if renamed project is available. Attempt $Attempt of $MaxAttempts"

        $RenamedProj = Get-AdoProject -ProjectName $NewProjectName
        if ($null -ne $RenamedProj -and $RenamedProj.id -eq $ProjectId) {
            $Completed = $true
            Write-Success "Project rename verified directly."
            break
        }

        Start-Sleep -Seconds $PollingInterval
    }
}

if (-not $Completed) {

    Write-Failure "Project rename operation timed out."

    throw "Project rename did not complete within the configured timeout."
}

# ------------------------------------------------
# VERIFY RENAMED PROJECT
# ------------------------------------------------

Write-Host ""
Write-Info "Verifying the renamed project..."

try {

    $RenamedProject = Get-AdoProject `
        -ProjectName $NewProjectName

    if ($null -eq $RenamedProject) {
        throw "Rename operation succeeded, but the new project name could not be verified."
    }

    if ($RenamedProject.id -ne $ProjectId) {
        throw "Project verification failed. Project ID does not match."
    }

    if ($RenamedProject.name -ne $NewProjectName) {
        throw "Project verification failed. Expected '$NewProjectName', found '$($RenamedProject.name)'."
    }

    Write-Success "Project rename verified successfully."

}
catch {

    Write-Failure "Final project verification failed."
    Write-Failure $_.Exception.Message

    throw
}

# ------------------------------------------------
# FINAL RESULT
# ------------------------------------------------

Write-Host ""
Write-Host "=================================================="
Write-Success "AZURE DEVOPS PROJECT RENAMED SUCCESSFULLY!"
Write-Host "=================================================="

Write-Host "Organization     : $Organization"
Write-Host "Previous Name    : $ExistingProjectName"
Write-Host "New Project Name : $NewProjectName"
Write-Host "Project ID       : $ProjectId"
Write-Host "Project URL      : $BaseUrl/$([uri]::EscapeDataString($NewProjectName))"

Write-Host "=================================================="

Write-Host "##vso[task.setvariable variable=ProjectRenameStatus]Renamed"

Write-Success "Pipeline execution completed successfully."
