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
    [int]$PollingInterval = 30
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------
# CONFIGURATION
# ------------------------------------------------

$PAT = $env:ADO_PAT
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

try {

    $RenameResponse = Invoke-RestMethod `
        -Uri $RenameUrl `
        -Method Patch `
        -Headers $Headers `
        -Body $Body

    Write-Success "Project rename request submitted."

    Write-Host "Project ID   : $ProjectId"
    Write-Host "Operation ID : $($RenameResponse.id)"
    Write-Host "Initial Status: $($RenameResponse.status)"

}
catch {

    Write-Failure "Project rename request failed."
    Write-Failure $_.Exception.Message

    throw "Azure DevOps project rename failed."
}

# ------------------------------------------------
# MONITOR RENAME OPERATION
# ------------------------------------------------

Write-Host ""
Write-Info "Waiting for Azure DevOps to complete project rename..."

$OperationId = $RenameResponse.id

if ([string]::IsNullOrWhiteSpace($OperationId)) {
    throw "Rename request did not return a valid operation ID."
}

$OperationUrl = "$BaseUrl/_apis/operations/$OperationId" +
                "?api-version=7.1-preview.1"

$Completed = $false

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
