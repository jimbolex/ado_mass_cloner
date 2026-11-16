# ============================================================
# CONFIGURATION / CONTANTS
# ============================================================

# Reading Config XML

$configPath = Join-Path $PSScriptRoot "config.xml"

if (-not (Test-Path $configPath)) {
    Write-Host "ERROR: config.xml was not found." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

[xml]$config = Get-Content $configPath


$delayBetweenStoriesSeconds = [int](
    $config.Configuration.CloneOptions.DelayBetweenStoriesSeconds
)


# ============================================================
# FUNCTIONS
# ============================================================

function Resolve-FolderPath {

    param(
        [Parameter(Mandatory)]
        [string]$FolderPath,

        [switch]$AllowMissing
    )


    # ------------------------------------------------------------
    # Resolve template directory
    # ------------------------------------------------------------

    if ([System.IO.Path]::IsPathRooted($FolderPath)) {

        $resolvedFolder = $FolderPath
    }
    else {

        $resolvedFolder = Join-Path `
            -Path $PSScriptRoot `
            -ChildPath $FolderPath
    }

     if (-not $AllowMissing -and -not (Test-Path $resolvedFolder -PathType Container)) {
      
        throw "The folder $resolvedFolder was not found."
    }

    return $resolvedFolder

}

function Invoke-AdoRestMethodWithRetry {

    param (
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [string]$Method,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [string]$ContentType,

        [object]$Body,

        [Parameter(Mandatory)]
        [int]$MaxAttempts,

        [Parameter(Mandatory)]
        [int]$RetryDelaySeconds
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {

        try {

            $invokeParams = @{
                Uri     = $Uri
                Method  = $Method
                Headers = $Headers
            }

            if (-not [string]::IsNullOrWhiteSpace($ContentType)) {
                $invokeParams.ContentType = $ContentType
            }

            if ($null -ne $Body) {
                $invokeParams.Body = $Body
            }

            $response = Invoke-RestMethod @invokeParams

            return $response
        }
        catch {

            $statusCode = $null

            if ($null -ne $_.Exception.Response) {

                try {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                }
                catch {
                    $statusCode = $null
                }
            }

            # ----------------------------------------------------
            # Determine whether failure is transient/retryable
            # ----------------------------------------------------

            $retryableStatusCodes = @(
                408, # Request Timeout
                429, # Too Many Requests
                500, # Internal Server Error
                502, # Bad Gateway
                503, # Service Unavailable
                504  # Gateway Timeout
            )

            $isRetryable = $false

            # ----------------------------------------------------
            # Retry known transient HTTP errors
            # ----------------------------------------------------

            if ($statusCode -in $retryableStatusCodes) {
              
                $isRetryable = $true
            }

            # ----------------------------------------------------
            # Retry recognized network/connectivity failures
            # ----------------------------------------------------
            elseif ($null -eq $statusCode) {

                $exception = $_.Exception

                while ($null -ne $exception) {

                    if (
                        $exception -is [System.Net.Http.HttpRequestException] -or
                        $exception -is [System.Net.Sockets.SocketException] -or
                        $exception -is [System.Net.WebException] -or
                        $exception -is [System.TimeoutException]
                    ) {

                        $isRetryable = $true
                        break
                    }

                    $exception = $exception.InnerException
                }
            }

            # ----------------------------------------------------
            # Do not retry permanent failures
            # ----------------------------------------------------

            if (-not $isRetryable) {

                throw
            }

            # ----------------------------------------------------
            # No attempts remaining
            # ----------------------------------------------------

            if ($attempt -ge $MaxAttempts) {

                throw
            }

            # ----------------------------------------------------
            # Exponential backoff
            # ----------------------------------------------------

            $delaySeconds = $RetryDelaySeconds * [Math]::Pow(2, $attempt - 1)

            Write-Warning `
                "Azure DevOps request failed. Retrying in $delaySeconds second(s) (attempt $($attempt + 1) of $MaxAttempts)..."

            Start-Sleep -Seconds $delaySeconds
        }
    }
}

function Get-UserStoryInputFolder { 

    param (
        [Parameter(Mandatory)]
        [xml]$Config
    )

    $useLocalFolder = [System.Convert]::ToBoolean(
        $Config.Configuration.UserStoriesSource.UseLocalFolder
    )

    # Reading Input folder

    if($useLocalFolder){

        $inputFolderName = $Config.Configuration.UserStoriesSource.LocalFolder.InputFolder

        $inputFolder = Resolve-FolderPath -FolderPath $inputFolderName
    
    }
    else {

        $inputFolderName = $Config.Configuration.UserStoriesSource.OneDrive.InputFolder
        $oneDriveRoot = $env:OneDriveCommercial

        if ([string]::IsNullOrWhiteSpace($oneDriveRoot)) {
            throw "Conduent OneDrive could not be detected."
        }

        $inputFolder = Join-Path `
            -Path $oneDriveRoot `
            -ChildPath $inputFolderName 

    }


    if (-not (Test-Path $inputFolder -PathType Container)) {
        throw "User Story input folder was not found: $inputFolder"
    }

    return $inputFolder
}

function Get-UserStoryDoneFolder {

    param (
        [Parameter(Mandatory)]
        [xml]$Config
    )

    $useLocalFolder = [System.Convert]::ToBoolean(
        $Config.Configuration.UserStoriesSource.UseLocalFolder
    )

    if ($useLocalFolder) {

        $doneFolderName = $Config.Configuration.UserStoriesSource.LocalFolder.DoneFolder

        $doneFolder = Resolve-FolderPath -FolderPath $doneFolderName -AllowMissing
    }
    else {

        $doneFolderName = $Config.Configuration.UserStoriesSource.OneDrive.DoneFolder
        $oneDriveRoot = $env:OneDriveCommercial

        if ([string]::IsNullOrWhiteSpace($oneDriveRoot)) {
            throw "Conduent OneDrive could not be detected."
        }

        $doneFolder = Join-Path `
            -Path $oneDriveRoot `
            -ChildPath $doneFolderName
    }

    if (-not (Test-Path $doneFolder -PathType Container)) {

        New-Item -ItemType Directory -Path $doneFolder -Force | Out-Null
    }

    return $doneFolder
}

function Write-UserStoryArchive {

    param (
        [Parameter(Mandatory)]
        [string]$DoneFolder,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$CloneResults
    )

    $archiveName = (Get-Date).ToString("yyyyMMdd_HHmmss") + ".txt"

    $archivePath = Join-Path -Path $DoneFolder -ChildPath $archiveName

    if (Test-Path -LiteralPath $archivePath) {
        throw "Archive file already exists: $archivePath"
    }

     $archiveTable = $CloneResults |
        Format-Table `
            SourceId,
            CloneId,
            AttachmentsFound,
            AttachmentsCopied,
            AttachmentsFailed,
            Status `
            -AutoSize |
        Out-String

    Set-Content -LiteralPath $archivePath -Value $archiveTable.TrimEnd() -Encoding UTF8

    return $archivePath
}

function Get-UserStoryTemplate {

    param (
        [Parameter(Mandatory)]
        [xml]$Config
    )

    $useTemplate = [System.Convert]::ToBoolean(
        $Config.Configuration.UserStoriesSource.UseTemplate
    )

    # Template functionality disabled
    if (-not $useTemplate) {

        return $null
    }

    $templateFolder = $Config.Configuration.UserStoriesSource.Template.Folder

    $templateFileName = $Config.Configuration.UserStoriesSource.Template.FileName

    # ------------------------------------------------------------
    # Resolve template directory
    # ------------------------------------------------------------

    $resolvedTemplateFolder = Resolve-FolderPath -FolderPath $templateFolder
 
    # ------------------------------------------------------------
    # Build complete template filename
    # ------------------------------------------------------------

    $templatePath = Join-Path `
        -Path $resolvedTemplateFolder `
        -ChildPath $templateFileName

    # ------------------------------------------------------------
    # Validate template
    # ------------------------------------------------------------

    if (-not (Test-Path -Path $templatePath -PathType Leaf)) {

        throw "User Story template file was not found: $templatePath"
    }

    return $templatePath
}

function Get-InputTextFiles {

    param (
        [Parameter(Mandatory)]
        [string]$InputFolder
    )

    $inputFiles = @(
    Get-ChildItem `
        -Path $InputFolder `
        -Filter "*.txt" `
        -File
    )

    if ($inputFiles.Count -eq 0) {
        throw "No .txt files were found in: $InputFolder"
    }

    return $inputFiles
}

function Get-WorkItemIdsFromFiles { 

    param (
        [Parameter(Mandatory)]
        [System.IO.FileInfo[]]$InputFiles
    )

    # US(s) to clone
    $workItemIds = @()

    foreach ($file in $InputFiles) {

        Write-Host ""
        Write-Host "Reading: $($file.Name)"

        $lines = Get-Content $file.FullName

        foreach ($line in $lines) {

            $line = $line.Trim()

            # Strip comments: full-line (# ...) or inline (12345 # FAILED: ...)
            $commentIndex = $line.IndexOf("#")

            if ($commentIndex -ge 0) {
                $line = $line.Substring(0, $commentIndex).Trim()
            }

            # Ignore blank lines
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            # Split line by comma
            $values = $line -split ","

            foreach ($value in $values) {

                $value = $value.Trim()

                # Ignore empty values
                if ([string]::IsNullOrWhiteSpace($value)) {
                    continue
                }

                $parsedId = 0

                if ([int]::TryParse($value, [ref]$parsedId)) {

                    $workItemIds += $parsedId

                }
                else {

                    Write-Warning "Invalid User Story ID '$value' in $($file.Name)"
                }

            }
        }
    }

    # Remove duplicates if any

    return @(
        $workItemIds |
            Sort-Object -Unique
    )

}

function Get-AdoWorkItem {

   param (
        [Parameter(Mandatory)]
        [int]$WorkItemId,

        [Parameter(Mandatory)]
        [string]$OrganizationUrl,

        [Parameter(Mandatory)]
        [string]$Project,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [Parameter(Mandatory)]
        [int]$MaxAttempts,

        [Parameter(Mandatory)]
        [int]$RetryDelaySeconds
    ) 

    $url = "$OrganizationUrl/$Project/_apis/wit/workitems/$($WorkItemId)?`$expand=relations&api-version=7.1"

    return Invoke-RestMethod `
        -Uri $url `
        -Method Get `
        -Headers $Headers

}

function Get-CloneTitleAndDescription {

    param (
        [Parameter(Mandatory)]
        [string]$SourceTitle,

        [AllowNull()]
        [string]$SourceDescription,

        [Parameter(Mandatory)]
        [bool]$ReplaceQAWithUAT
    )

    # Defaults
    $cloneTitle = $SourceTitle
    
    if (-not [string]::IsNullOrWhiteSpace($SourceDescription)) {
        $cloneDescription = $SourceDescription
    }
    else{
        $cloneDescription = "<p><strong>WARNING:</strong> No description was found on the original User Story. You must add it manually to this clone.</p>"
    }

    # Text replacements or incrementing the clone parts

    if ($ReplaceQAWithUAT -and $SourceTitle -match '\bQA\b') {

        # Replace QA with UAT
        $cloneTitle = $cloneTitle -replace '\bQA\b', 'UAT'

        if ($cloneDescription -match '\bQA\b') {
            $cloneDescription = $cloneDescription -replace '\bQA\b', 'UAT'
        }

    }
    elseif ($SourceTitle -match '\s*-\s*\[Part\s+(\d+)\]\s*$') {

        # Existing Part number found at the end of the title
        $currentPart = [int]$Matches[1]
        $nextPart = $currentPart + 1

        $cloneTitle = $cloneTitle -replace `
            '\s*-\s*\[Part\s+\d+\]\s*$',
            " - [Part $nextPart]"

    }
    else {

        # No QA replacement and no existing Part number
        $cloneTitle = "$cloneTitle - [Part 2]"

    }

    return [PSCustomObject]@{
        Title       = $cloneTitle
        Description = $cloneDescription
    }

} 

function New-AdoUserStoryClone {

    param (
        [Parameter(Mandatory)]
        [object]$SourceWorkItem,

        [Parameter(Mandatory)]
        [string]$CloneTitle,

        [Parameter(Mandatory)]
        [string]$CloneDescription,

        [Parameter(Mandatory)]
        [string]$AreaPath,

        [Parameter(Mandatory)]
        [string]$IterationPath,

        [Parameter(Mandatory)]
        [string]$OrganizationUrl,

        [Parameter(Mandatory)]
        [string]$Project,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    # ------------------------------------------------------------
    # BUILDING MAIN BODY ARRAY
    # ------------------------------------------------------------

    $body = @()


    # Title
    $body += @{
        op    = "add"
        path  = "/fields/System.Title"
        value = $CloneTitle
    }

    # Area Path
    $body += @{
        op    = "add"
        path  = "/fields/System.AreaPath"
        value = $AreaPath
    }

    # Iteration Path
    $body += @{
        op    = "add"
        path  = "/fields/System.IterationPath"
        value = $IterationPath
    }

    # Description
    if (-not [string]::IsNullOrWhiteSpace($CloneDescription)) {

        $body += @{
            op    = "add"
            path  = "/fields/System.Description"
            value = $CloneDescription
        }
    }

    # Acceptance Criteria

    $acceptanceCriteria = $SourceWorkItem.fields.'Microsoft.VSTS.Common.AcceptanceCriteria'

    if (-not [string]::IsNullOrWhiteSpace($acceptanceCriteria)) {

        $body += @{
            op    = "add"
            path  = "/fields/Microsoft.VSTS.Common.AcceptanceCriteria"
            value = $acceptanceCriteria
        }
    }

    # Tags

    $tags = $SourceWorkItem.fields.'System.Tags'

    if (-not [string]::IsNullOrWhiteSpace($tags)) {

        $body += @{
            op    = "add"
            path  = "/fields/System.Tags"
            value = $tags
        }
    }

    # ------------------------------------------------------------
    # COPY PARENT RELATION
    # ------------------------------------------------------------

    $parentRelation = $SourceWorkItem.relations |
        Where-Object {
            $_.rel -eq "System.LinkTypes.Hierarchy-Reverse"
        } |
        Select-Object -First 1

    if ($null -ne $parentRelation) {

        Write-Host "Parent: $($parentRelation.url)"

        $body += @{
            op   = "add"
            path = "/relations/-"
            value = @{
                rel = "System.LinkTypes.Hierarchy-Reverse"
                url = $parentRelation.url
            }
        }
    }
    else {

        Write-Host "Parent: None"
    }

    # ------------------------------------------------------------
    # COPY RELATED RELATION
    # ------------------------------------------------------------

    Write-Host "Related: $($SourceWorkItem.url)"

    $body += @{
        op   = "add"
        path = "/relations/-"
        value = @{
            rel = "System.LinkTypes.Related"
            url = $SourceWorkItem.url
        }
    }

    
    # ------------------------------------------------------------
    # VALIDATE PATCH DOCUMENT
    # ------------------------------------------------------------

    foreach ($operation in $body) {

        if ($null -eq $operation.value) {

            throw "Invalid clone payload for User Story $($SourceWorkItem.id). '$($operation.path)' contains a null value."
        }
    }


    # ------------------------------------------------------------
    # CREATE CLONE
    # ------------------------------------------------------------

    $encodedWorkItemType = [Uri]::EscapeDataString("User Story")

    $createUrl = "$OrganizationUrl/$Project/_apis/wit/workitems/`$$encodedWorkItemType"+"?api-version=7.1"

       
    $jsonBody = $body | ConvertTo-Json -Depth 10

    Write-Host ""
    Write-Host "Creating cloned User Story..."

    $newWorkItem = Invoke-RestMethod `
        -Uri $createUrl `
        -Method Post `
        -Headers $Headers  `
        -ContentType "application/json-patch+json" `
        -Body $jsonBody

    return $newWorkItem

}

function Test-AdoAttachment {

   param (
        [Parameter(Mandatory)]
        [int]$WorkItemId,

        [Parameter(Mandatory)]
        [string]$AttachmentId,

        [Parameter(Mandatory)]
        [string]$OrganizationUrl,

        [Parameter(Mandatory)]
        [string]$Project,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [Parameter(Mandatory)]
        [int]$MaxAttempts,

        [Parameter(Mandatory)]
        [int]$RetryDelaySeconds
    )  
   
    # ------------------------------------------------------------
    # Retrieve cloned work item with relations
    # ------------------------------------------------------------

    $verificationUrl = "$OrganizationUrl/$Project/_apis/wit/workitems/$($WorkItemId)?`$expand=relations&api-version=7.1"

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {

        $verifiedWorkItem = Invoke-AdoRestMethodWithRetry `
            -Uri $verificationUrl `
            -Method Get `
            -Headers $Headers `
            -MaxAttempts $MaxAttempts `
            -RetryDelaySeconds $RetryDelaySeconds

        $linkedAttachment = @(
            $verifiedWorkItem.relations |
                Where-Object {
                    $_.rel -eq "AttachedFile" -and
                    $_.url -like "*$AttachmentId*"
                }
        )

        if ($linkedAttachment.Count -gt 0) {
            return $true
        }

        if ($attempt -lt $MaxAttempts) {

            Write-Host `
                "Attachment not visible yet. Retrying verification in $RetryDelaySeconds second(s)..."

            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    return $false

}

function Copy-AdoAttachments {

     param (
        [Parameter(Mandatory)]
        [object]$SourceWorkItem,

        [Parameter(Mandatory)]
        [int]$DestinationWorkItemId,

        [Parameter(Mandatory)]
        [string]$OrganizationUrl,

        [Parameter(Mandatory)]
        [string]$Project,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [Parameter(Mandatory)]
        [int]$MaxAttempts,

        [Parameter(Mandatory)]
        [int]$RetryDelaySeconds
    )

    # ------------------------------------------------------------
    # Find attachment relations on source User Story
    # ------------------------------------------------------------

    $attachmentRelations = @(
        $SourceWorkItem.relations |
        Where-Object {
            $_.rel -eq "AttachedFile"
        }
    )
 
    Write-Host ""
    Write-Host "Attachments found: $($attachmentRelations.Count)"
 
    # ------------------------------------------------------------
    # Download, reupload, and link each attachment
    # ------------------------------------------------------------
 
    $attachmentResults = @()
 
    foreach ($attachmentRelation in $attachmentRelations) {
 
        $fileName = $attachmentRelation.attributes.name
 
        if ([string]::IsNullOrWhiteSpace($fileName)) {
            $fileName = "attachment-$([Guid]::NewGuid().ToString()).bin"
        }
         
 
        # Create a temporary local file path.

        $tempFilePath = Join-Path `
        -Path ([System.IO.Path]::GetTempPath()) `
        -ChildPath "$([Guid]::NewGuid())-$fileName"
 
        try {

            Write-Host ""
            Write-Host "Processing attachment: $fileName"

            # ----------------------------------------------------
            # Download original attachment
            # ----------------------------------------------------

            Invoke-WebRequest `
                -Uri $attachmentRelation.url `
                -Method Get `
                -Headers $Headers  `
                -OutFile $tempFilePath

            # Verify downloaded file

            if (-not (Test-Path $tempFilePath)) {
                throw "Downloaded attachment was not found: $tempFilePath"
            }

            $fileInfo = Get-Item $tempFilePath

            Write-Host "Downloaded successfully."
            Write-Host "File size: $($fileInfo.Length) bytes"

            # ----------------------------------------------------
            # Upload attachment as a NEW attachment
            # ----------------------------------------------------

            $encodedFileName = [Uri]::EscapeDataString($fileName)

            $uploadUrl = "$OrganizationUrl/$Project/_apis/wit/attachments?fileName=$encodedFileName&api-version=7.1"

            $fileBytes = [System.IO.File]::ReadAllBytes($tempFilePath)

            Write-Host "Uploading attachment..."

            $uploadedAttachment = Invoke-RestMethod `
                -Uri $uploadUrl `
                -Method Post `
                -Headers $Headers  `
                -ContentType "application/octet-stream" `
                -Body $fileBytes
                  
            Write-Host "Upload successful." -ForegroundColor Green
            Write-Host "Attachment ID: $($uploadedAttachment.id)"

            # ----------------------------------------------------
            # Link uploaded attachment to cloned work item
            # ----------------------------------------------------

            $attachmentPatch = ConvertTo-Json -InputObject @(
                @{
                    op   = "add"
                    path = "/relations/-"
                    value = @{
                        rel = "AttachedFile"
                        url = [string]$uploadedAttachment.url
                        attributes = @{
                            name = [string]$fileName
                        }
                    }
                }
            ) -Depth 10 -Compress

            # Validate the JSON before calling Azure DevOps

            if ([string]::IsNullOrWhiteSpace($attachmentPatch)) {
                throw "The attachment JSON Patch body is empty."
            }

            # Optional validation: this throws an error if JSON is malformed

            $null = $attachmentPatch | ConvertFrom-Json

            # ----------------------------------------------------
            # Link uploaded attachment to cloned work item
            # ----------------------------------------------------

            $updateUrl = "$OrganizationUrl/$Project/_apis/wit/workitems/"+"$DestinationWorkItemId"+"?api-version=7.1"

            Write-Host "Linking attachment to cloned User Story..."

            $null = Invoke-RestMethod `
                -Uri $updateUrl `
                -Method Patch `
                -Headers $Headers `
                -ContentType "application/json-patch+json" `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($attachmentPatch))

            Write-Host "Attachment linked successfully." -ForegroundColor Green

            # ----------------------------------------------------
            # Verify relation returned by Azure DevOps
            # ----------------------------------------------------

            $uploadedAttachmentId = [string]$uploadedAttachment.id
         
            $attachmentVerified = Test-AdoAttachment `
                -WorkItemId $DestinationWorkItemId `
                -AttachmentId $uploadedAttachmentId `
                -OrganizationUrl $OrganizationUrl `
                -Project $Project `
                -Headers $Headers `
                -MaxAttempts $MaxAttempts `
                -RetryDelaySeconds $RetryDelaySeconds

            # ----------------------------------------------------
            # Validate uploaded attachment
            # ----------------------------------------------------

            
            if($attachmentVerified){
            
                
                Write-Host "Attachment verified successfully." -ForegroundColor Green
                
                $attachmentResults += [PSCustomObject]@{
                    FileName = $fileName
                    Status   = "Copied"
                    Error    = $null
                }

            }
            else{
            
                Write-Warning `
                    "Attachment was linked but could not be verified: $fileName"

                $attachmentResults += [PSCustomObject]@{
                    FileName = $fileName
                    Status   = "VerificationFailed"
                    Error    = "Attachment could not be verified on cloned User Story."
            
                }
            }
        }
        catch {

            Write-Warning "Attachment could not be copied: $fileName"
            Write-Host "Exception:" -ForegroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor Red

            # Azure DevOps often puts the important error here

            if ($_.ErrorDetails.Message) {

                Write-Host ""
                Write-Host "Azure DevOps response:" -ForegroundColor Yellow
                Write-Host $_.ErrorDetails.Message -ForegroundColor Yellow
            }


            $attachmentResults += [PSCustomObject]@{
                FileName = $fileName
                Status   = "Failed"
                Error    = $_.Exception.Message
            }
        }
        finally {

            if (Test-Path $tempFilePath) {
                Remove-Item $tempFilePath -Force
                      
            }
        }
    }

    # ------------------------------------------------------------
    # Return attachment summary
    # ------------------------------------------------------------

    return [PSCustomObject]@{
        Found = $attachmentRelations.Count

        Copied = @(
            $attachmentResults |
                Where-Object {
                    $_.Status -eq "Copied"
                }
        ).Count

        Failed = @(
            $attachmentResults |
                Where-Object {
                    $_.Status -ne "Copied"
                }
        ).Count

        Results = $attachmentResults
    }
}

function Invoke-UserStoryClone {

     param (
        [Parameter(Mandatory)]
        [int]$WorkItemId,

        [Parameter(Mandatory)]
        [xml]$Config,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    # ------------------------------------------------------------
    # Read configuration
    # ------------------------------------------------------------

    $organizationUrl = $Config.Configuration.AzureDevOps.OrganizationUrl

    $project = $Config.Configuration.AzureDevOps.Project

    $areaPath = $Config.Configuration.Destination.AreaPath

    $iterationPath = $Config.Configuration.Destination.IterationPath

    $replaceQAWithUAT = [System.Convert]::ToBoolean(
        $Config.Configuration.CloneOptions.ReplaceQAWithUAT
    )

    $copyAttachments = [System.Convert]::ToBoolean(
        $Config.Configuration.CloneOptions.CopyAttachments
    )

    $maxAttempts = [int](
        $Config.Configuration.Retry.RetryAttempts
    )

    $retryDelaySeconds = [int](
        $Config.Configuration.Retry.RetryDelaySeconds
    )

    # ------------------------------------------------------------
    # Get source User Story
    # ------------------------------------------------------------

    $workItem = Get-AdoWorkItem `
        -WorkItemId $WorkItemId `
        -OrganizationUrl $organizationUrl `
        -Project $project `
        -Headers $Headers `
        -MaxAttempts $maxAttempts `
        -RetryDelaySeconds $retryDelaySeconds

    $sourceTitle = $workItem.fields.'System.Title'

    $sourceDescription = $workItem.fields.'System.Description'

    Write-Host ""
    Write-Host "Original User Story:"
    Write-Host "ID:    $($workItem.id)"
    Write-Host "Title: $sourceTitle"

    # ------------------------------------------------------------
    # Build clone Title and Description
    # ------------------------------------------------------------

    $cloneText = Get-CloneTitleAndDescription `
        -SourceTitle $sourceTitle `
        -SourceDescription $sourceDescription `
        -ReplaceQAWithUAT $replaceQAWithUAT

    $cloneTitle = $cloneText.Title

    $cloneDescription = $cloneText.Description

    # ------------------------------------------------------------
    # Create cloned User Story
    # ------------------------------------------------------------

    $newWorkItem = New-AdoUserStoryClone `
        -SourceWorkItem $workItem `
        -CloneTitle $cloneTitle `
        -CloneDescription $cloneDescription `
        -AreaPath $areaPath `
        -IterationPath $iterationPath `
        -OrganizationUrl $organizationUrl `
        -Project $project `
        -Headers $Headers

    Write-Host ""
    Write-Host "Clone created successfully." -ForegroundColor Green

    Write-Host "Clone ID: $($newWorkItem.id)"

    # ------------------------------------------------------------
    # Default attachment summary
    # ------------------------------------------------------------

    $attachmentSummary = [PSCustomObject]@{
        Found   = 0
        Copied  = 0
        Failed  = 0
        Results = @()
    }

    # ------------------------------------------------------------
    # Copy attachments when enabled
    # ------------------------------------------------------------

    if ($copyAttachments) {

        $attachmentSummary = Copy-AdoAttachments `
            -SourceWorkItem $workItem `
            -DestinationWorkItemId $newWorkItem.id `
            -OrganizationUrl $organizationUrl `
            -Project $project `
            -Headers $Headers `
            -MaxAttempts $maxAttempts `
            -RetryDelaySeconds $retryDelaySeconds
    }

    # ------------------------------------------------------------
    # Return result
    # ------------------------------------------------------------

    return [PSCustomObject]@{
        SourceId          = $WorkItemId
        CloneId           = $newWorkItem.id
        Title             = $cloneTitle
        AttachmentsFound  = $attachmentSummary.Found
        AttachmentsCopied = $attachmentSummary.Copied
        AttachmentsFailed = $attachmentSummary.Failed
        Status            = "Success"
        Error             = $null
    }

}

# ============================================================
# MAIN
# ============================================================

# Obtains the input folder
$inputFolder = Get-UserStoryInputFolder -Config $config

# Resolved before cloning so a missing or invalid path fails before anything is cloned
$doneFolder = Get-UserStoryDoneFolder -Config $config

$templatePath = Get-UserStoryTemplate -Config $config

# Checks for the right input files and for User Story ID's
$inputFiles = Get-InputTextFiles -InputFolder $inputFolder

$workItemIds = Get-WorkItemIdsFromFiles -InputFiles $inputFiles

Write-Host ""
Write-Host "Total unique User Stories found to clone: $($workItemIds.Count)"
Write-Host ""

# AUTHENTICATION =============================================================
if ($workItemIds.Count -gt 0) {
    $patSecure = Read-Host "Enter your Azure DevOps PAT" -AsSecureString

    $credential = New-Object `
        System.Management.Automation.PSCredential("PAT", $patSecure)

    $pat = $credential.GetNetworkCredential().Password

    $base64AuthInfo = [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes(":$pat")
    )

    $headers = @{
        Authorization = "Basic $base64AuthInfo"
    }
}
# ============================================================================

# Cloning starts
$cloneResults = @()
$currentStoryNumber = 0

foreach ($workItemId in $workItemIds) {

    $currentStoryNumber++
    $cloneTitle = $null
    $newWorkItem = $null
    $attachmentRelations = @()
    $attachmentResults = @()

    try {

        Write-Host "============================================"
        Write-Host "CLONING USER STORY $workItemId"
        Write-Host "============================================"

        $result = Invoke-UserStoryClone `
            -WorkItemId $workItemId `
            -Config $config `
            -Headers $headers

        $cloneResults += $result
        
    }
    catch {

        Write-Host ""
        Write-Warning "User Story $workItemId could not be cloned."
        Write-Warning $_.Exception.Message

        if ($_.ErrorDetails.Message) {

            Write-Host ""
            Write-Host "Azure DevOps response:" -ForegroundColor Yellow
            Write-Host $_.ErrorDetails.Message -ForegroundColor Yellow
        }



        $cloneResults += [PSCustomObject]@{
            SourceId          = $workItemId
            CloneId           = $null
            Title             = $cloneTitle
            AttachmentsFound  = $null
            AttachmentsCopied = $null
            AttachmentsFailed = $null
            Status            = "Failed"
            Error             = $_.Exception.Message
        }
    }


    # Delay between stories

    if ($delayBetweenStoriesSeconds -gt 0 -and
        $currentStoryNumber -lt $workItemIds.Count) {

        Write-Host ""
        Write-Host "Waiting $delayBetweenStoriesSeconds second(s) before next User Story..."
        Write-Host ""

        Start-Sleep -Seconds $delayBetweenStoriesSeconds
    }
}


# ------------------------------------------------------------
# ARCHIVE INPUT
# Only reached when the run completes, so an interrupted run
# leaves the input files in place for the next run.
# ------------------------------------------------------------

if ($workItemIds.Count -gt 0) {

    $archivePath = Write-UserStoryArchive `
        -DoneFolder $doneFolder `
        -CloneResults $cloneResults

    foreach ($inputFile in $inputFiles) {

        Remove-Item -LiteralPath $inputFile.FullName -Force
    }


    # ------------------------------------------------------------
    # DISPLAY RESULTS
    # ------------------------------------------------------------
     
    Write-Host ""
    Write-Host "============================================"
    Write-Host "MASS CLONING COMPLETED"
    Write-Host "============================================"
    Write-Host ""

    $cloneResults |
        Format-Table `
            SourceId,
            CloneId,
            AttachmentsFound,
            AttachmentsCopied,
            AttachmentsFailed,
            Status `
            -AutoSize
    Write-Host "Processed User Stories archived to: $archivePath"

    if ($null -ne $templatePath) {

        Copy-Item `
            -LiteralPath $templatePath `
            -Destination (Join-Path -Path $inputFolder -ChildPath "US To Clone.txt") `
            -Force
    }
}
else {

    Write-Host "No User Stories found in input; input files left unchanged."
    Write-Host ""
}