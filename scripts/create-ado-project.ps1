[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$Organization,

    [Parameter(Mandatory = $true)]
    [string]$ProjectName,

    [Parameter(Mandatory = $false)]
    [string]$ProcessTemplateId = "",

    [Parameter(Mandatory = $false)]
    [string]$ProcessTemplateName = "Agile",

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

# Clean any enclosing quotes passed via command line
$Organization = $Organization.Trim('"').Trim("'").Trim()
$ProjectName = $ProjectName.Trim('"').Trim("'").Trim()
if (-not [string]::IsNullOrWhiteSpace($ProcessTemplateId)) {
    $ProcessTemplateId = $ProcessTemplateId.Trim('"').Trim("'").Trim()
}
if (-not [string]::IsNullOrWhiteSpace($ProcessTemplateName)) {
    $ProcessTemplateName = $ProcessTemplateName.Trim('"').Trim("'").Trim()
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
# RESOLVE PROCESS TEMPLATE
# ------------------------------------------------

function Get-AdoProcessTemplateId {
    param (
        [string]$PreferredTemplateId,
        [string]$PreferredTemplateName
    )

    Write-Info "Resolving process template for organization '$Organization'..."

    $ProcessUrl = "$BaseUrl/_apis/process/processes?api-version=$ApiVersion"

    try {
        $ProcessResponse = Invoke-RestMethod `
            -Uri $ProcessUrl `
            -Method Get `
            -Headers $Headers

        # Response can be an array directly or an object with 'value' property
        $Processes = $null
        if ($ProcessResponse -is [array]) {
            $Processes = $ProcessResponse
        }
        elseif ($ProcessResponse.value) {
            $Processes = $ProcessResponse.value
        }

        if ($Processes -and $Processes.Count -gt 0) {
            # 1. If explicit ID provided and exists in org, use it
            if (-not [string]::IsNullOrWhiteSpace($PreferredTemplateId)) {
                $MatchedById = $Processes | Where-Object { $_.id -eq $PreferredTemplateId -or $_.typeId -eq $PreferredTemplateId } | Select-Object -First 1
                if ($MatchedById) {
                    $SelectedId = if ($MatchedById.id) { $MatchedById.id } else { $MatchedById.typeId }
                    Write-Success "Using specified process template: $($MatchedById.name) ($SelectedId)"
                    return $SelectedId
                }
                Write-WarningMessage "Specified ProcessTemplateId '$PreferredTemplateId' was not found in '$Organization'."
            }

            # 2. If name specified (e.g. 'Agile', 'Scrum', 'Basic'), find matching template
            if (-not [string]::IsNullOrWhiteSpace($PreferredTemplateName)) {
                $MatchedByName = $Processes | Where-Object { $_.name -like "*$PreferredTemplateName*" } | Select-Object -First 1
                if ($MatchedByName) {
                    $SelectedId = if ($MatchedByName.id) { $MatchedByName.id } else { $MatchedByName.typeId }
                    Write-Success "Resolved process template by name '$PreferredTemplateName': $($MatchedByName.name) ($SelectedId)"
                    return $SelectedId
                }
            }

            # 3. Try to find 'Agile' by default
            $AgileProcess = $Processes | Where-Object { $_.name -eq "Agile" } | Select-Object -First 1
            if ($AgileProcess) {
                $SelectedId = if ($AgileProcess.id) { $AgileProcess.id } else { $AgileProcess.typeId }
                Write-Success "Found standard 'Agile' template: $($AgileProcess.name) ($SelectedId)"
                return $SelectedId
            }

            # 4. Fall back to organization's default template (isDefault = true)
            $DefaultProcess = $Processes | Where-Object { $_.isDefault -eq $true } | Select-Object -First 1
            if ($DefaultProcess) {
                $SelectedId = if ($DefaultProcess.id) { $DefaultProcess.id } else { $DefaultProcess.typeId }
                Write-Success "Using organization's default process template: $($DefaultProcess.name) ($SelectedId)"
                return $SelectedId
            }

            # 5. Take first available template
            $FirstProcess = $Processes | Select-Object -First 1
            $SelectedId = if ($FirstProcess.id) { $FirstProcess.id } else { $FirstProcess.typeId }
            Write-Success "Using first available process template: $($FirstProcess.name) ($SelectedId)"
            return $SelectedId
        }
    }
    catch {
        Write-WarningMessage "Could not query organization processes ($($_.Exception.Message)). Falling back to default ID."
    }

    # Final fallback if API call fails
    if (-not [string]::IsNullOrWhiteSpace($PreferredTemplateId)) {
        return $PreferredTemplateId
    }
    return "6b724908-ef14-45cf-84f8-768b5384da45" # Agile GUID
}

# ------------------------------------------------
# CREATE PROJECT
# ------------------------------------------------

Write-Host ""
Write-Info "Starting project creation..."

$ResolvedProcessTemplateId = Get-AdoProcessTemplateId `
    -PreferredTemplateId $ProcessTemplateId `
    -PreferredTemplateName $ProcessTemplateName

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
            templateTypeId = $ResolvedProcessTemplateId
        }
    }
} | ConvertTo-Json -Depth 10

$OperationUrl = $null
$OperationId = $null

try {

    $CreateResponse = Invoke-WebRequest `
        -Uri $CreateUrl `
        -Method Post `
        -Headers $Headers `
        -ContentType "application/json" `
        -Body $Body

    Write-Success "Project creation request submitted (HTTP $($CreateResponse.StatusCode))."

    # Attempt to parse response body if present
    $ResponseBody = $null
    if ($CreateResponse.Content) {
        try {
            $ResponseBody = $CreateResponse.Content | ConvertFrom-Json
        }
        catch {
            Write-Info "Raw response content: $($CreateResponse.Content)"
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
    if ([string]::IsNullOrWhiteSpace($OperationUrl) -and $CreateResponse.Headers) {
        $LocationValue = $null

        # PowerShell Core (.Location on HttpResponseHeaders)
        if ($CreateResponse.Headers.Location) {
            $LocationValue = $CreateResponse.Headers.Location.ToString()
        }
        # Dictionary indexer (Windows PowerShell)
        elseif ($CreateResponse.Headers['Location']) {
            $LocationValue = "$($CreateResponse.Headers['Location'])"
        }
        # Case-insensitive header scan
        else {
            foreach ($k in $CreateResponse.Headers.Keys) {
                if ($k -eq "Location" -or $k -eq "location") {
                    $v = $CreateResponse.Headers[$k]
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

    if (-not [string]::IsNullOrWhiteSpace($OperationId)) {
        Write-Host "Operation ID  : $OperationId"
    }
    if (-not [string]::IsNullOrWhiteSpace($OperationUrl)) {
        Write-Host "Operation URL : $OperationUrl"
    }

}
catch {

    Write-Failure "Project creation request failed."
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

    throw "Azure DevOps project creation failed."
}

# ------------------------------------------------
# WAIT FOR PROJECT CREATION
# ------------------------------------------------

Write-Host ""
Write-Info "Waiting for Azure DevOps to complete project creation..."

$Completed = $false

# If we have a valid Operation URL, poll the operation endpoint
if (-not [string]::IsNullOrWhiteSpace($OperationUrl)) {

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
}
else {
    # Fallback: Poll project existence endpoint directly if no operation reference was returned
    Write-WarningMessage "No operation endpoint returned by Azure DevOps. Polling project directly..."

    for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {

        Write-Host ""
        Write-Info "Checking if project exists. Attempt $Attempt of $MaxAttempts"

        try {
            $ExistingProject = Invoke-RestMethod `
                -Uri $CheckUrl `
                -Method Get `
                -Headers $Headers

            $IsFound = $false
            if ($ExistingProject) {
                if ($ExistingProject.id -or ($ExistingProject.name -and ($ExistingProject.name.Trim() -ieq $ProjectName))) {
                    $IsFound = $true
                }
            }

            if ($IsFound) {
                $Completed = $true
                Write-Success "Azure DevOps project created and verified."
                Write-Host "Project Name : $($ExistingProject.name)"
                Write-Host "Project ID   : $($ExistingProject.id)"
                Write-Host "Project State: $($ExistingProject.state)"
                break
            }
            else {
                $CurrentState = if ($ExistingProject.state) { $ExistingProject.state } else { "Provisioning in progress..." }
                Write-Info "Project status: $CurrentState"
            }
        }
        catch {
            Write-Info "Project is still provisioning (waiting for project to appear)..."
        }

        # Guaranteed sleep between polling attempts
        if (-not $Completed) {
            Write-Info "Waiting $PollingInterval seconds before next check..."
            Start-Sleep -Seconds $PollingInterval
        }
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
