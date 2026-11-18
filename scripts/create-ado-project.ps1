[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$Organization,

    [Parameter(Mandatory = $true)]
    [string]$ProjectName,

    [Parameter(Mandatory = $false)]
    [string]$ProcessTemplateId = "6b724908-ef14-45cf-84f8-768b5384da45",

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
# VALIDATION
# ------------------------------------------------

Write-Host ""
Write-Host "=================================================="
Write-Host "       AZURE DEVOPS PROJECT PROVISIONING"
Write-Host "=================================================="

Write-Info "Starting project provisioning process."

if ([string]::IsNullOrWhiteSpace($Organization)) {
    throw "Azure DevOps organization name is empty."
}

if ([string]::IsNullOrWhiteSpace($ProjectName)) {
    throw "Project name is empty."
}

if ([string]::IsNullOrWhiteSpace($PAT)) {
    throw "ADO PAT is missing. Configure secret variable ADO_PAT."
}

Write-Info "Organization : $Organization"
Write-Info "Project Name : $ProjectName"
Write-Info "API Version  : $ApiVersion"

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
# CHECK WHETHER PROJECT EXISTS
# ------------------------------------------------

Write-Host ""
Write-Info "Checking whether project already exists..."

$EncodedProjectName = [uri]::EscapeDataString($ProjectName)

$CheckUrl = "$BaseUrl/_apis/projects/$EncodedProjectName" +
            "?api-version=$ApiVersion"

$ProjectExists = $false

try {

    $ExistingProject = Invoke-RestMethod `
        -Uri $CheckUrl `
        -Method Get `
        -Headers $Headers

    if ($ExistingProject.name -eq $ProjectName) {

        $ProjectExists = $true

        Write-Host ""
        Write-WarningMessage "PROJECT ALREADY EXISTS!"
        Write-Host "--------------------------------------------------"
        Write-Host "Project Name : $($ExistingProject.name)"
        Write-Host "Project ID   : $($ExistingProject.id)"
        Write-Host "Project State: $($ExistingProject.state)"
        Write-Host "--------------------------------------------------"

        Write-WarningMessage "Project creation skipped. No changes were made."

        Write-Host "##vso[task.setvariable variable=ProjectCreationStatus]AlreadyExists"

        Write-Success "Pipeline completed. Project is already available."

        exit 0
    }

}
catch {

    $StatusCode = 0

    if ($_.Exception.Response) {
        $StatusCode = [int]$_.Exception.Response.StatusCode
    }

    if ($StatusCode -eq 404) {

        Write-Info "Project does not exist. Creation can proceed."

    }
    else {

        Write-Failure "Unable to verify project existence."

        Write-Failure "HTTP Status Code: $StatusCode"

        Write-Failure $_.Exception.Message

        throw "Project existence validation failed. Check PAT permissions and organization access."
    }
}

# ------------------------------------------------
# CREATE PROJECT
# ------------------------------------------------

Write-Host ""
Write-Info "Starting project creation..."

$CreateUrl = "$BaseUrl/_apis/projects?api-version=$ApiVersion"

$Body = @{
    name = $ProjectName
    description = "Project created through Azure DevOps YAML pipeline."
    visibility = "private"

    capabilities = @{
        versioncontrol = @{
            sourceControlType = "Git"
        }

        processTemplate = @{
            templateTypeId = $ProcessTemplateId
        }
    }
} | ConvertTo-Json -Depth 10

try {

    $CreateResponse = Invoke-RestMethod `
        -Uri $CreateUrl `
        -Method Post `
        -Headers $Headers `
        -Body $Body

    Write-Success "Project creation request submitted."

    Write-Host "Operation ID : $($CreateResponse.id)"
    Write-Host "Initial Status: $($CreateResponse.status)"

}
catch {

    Write-Failure "Project creation request failed."

    Write-Failure $_.Exception.Message

    throw "Azure DevOps project creation failed."
}

# ------------------------------------------------
# WAIT FOR PROJECT CREATION
# ------------------------------------------------

Write-Host ""
Write-Info "Waiting for Azure DevOps to complete project creation..."

$OperationUrl = "$BaseUrl/_apis/operations/$($CreateResponse.id)?api-version=7.1-preview.1"

$Completed = $false

for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {

    Write-Host ""
    Write-Info "Checking operation status. Attempt $Attempt of $MaxAttempts"

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

                Write-Success "Azure DevOps project creation completed."

                break
            }

            "failed" {

                Write-Failure "Azure DevOps reported project creation failure."

                Write-Host ($Operation | ConvertTo-Json -Depth 10)

                throw "Project creation operation failed."
            }

            "cancelled" {

                Write-Failure "Project creation operation was cancelled."

                throw "Project creation was cancelled."
            }

            default {

                Write-Info "Project creation is still in progress."

                Start-Sleep -Seconds $PollingInterval
            }
        }

        if ($Completed) {
            break
        }

    }
    catch {

        Write-Failure "Error while checking project creation status."

        Write-Failure $_.Exception.Message

        throw
    }
}

if (-not $Completed) {

    Write-Failure "Project creation timed out."

    throw "Project creation did not complete within the configured timeout."
}

# ------------------------------------------------
# FINAL RESULT
# ------------------------------------------------

Write-Host ""
Write-Host "=================================================="
Write-Success "AZURE DEVOPS PROJECT CREATED SUCCESSFULLY!"
Write-Host "=================================================="

Write-Host "Project Name : $ProjectName"
Write-Host "Organization : $Organization"
Write-Host "Project URL  : $BaseUrl/$EncodedProjectName"

Write-Host "=================================================="

Write-Host "##vso[task.setvariable variable=ProjectCreationStatus]Created"

Write-Success "Pipeline execution completed successfully."
