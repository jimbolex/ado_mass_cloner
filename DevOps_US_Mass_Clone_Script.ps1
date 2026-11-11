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
# AUTHENTICATION
# ============================================================

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

# ============================================================
# FUNCTIONS
# ============================================================


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
    
        if ([System.IO.Path]::IsPathRooted($inputFolderName)) {

            # Absolute path provided
            $inputFolder = $inputFolderName

        }
        else {

            # Relative path provided
            $inputFolder = Join-Path `
                -Path $PSScriptRoot `
                -ChildPath $inputFolderName
        }

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

function Get-WorkItemIdsFromFiles { 

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

    # US(s) to clone
    $workItemIds = @()

    foreach ($file in $inputFiles) {

        Write-Host "Reading: $($file.Name)"

        $lines = Get-Content $file.FullName

        foreach ($line in $lines) {

            $line = $line.Trim()

            # Ignore blank lines
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            # Ignore comments starting with #
            if ($line.StartsWith("#")) {
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
        [hashtable]$Headers
    ) 

    $url = "$OrganizationUrl/$Project/_apis/wit/workitems/$($WorkItemId)?`$expand=relations&api-version=7.1"

    return Invoke-RestMethod `
        -Uri $url `
        -Method Get `
        -Headers $headers

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
        [hashtable]$Headers
    )  

    # ------------------------------------------------------------
    # Retrieve cloned work item with relations
    # ------------------------------------------------------------

    $verificationUrl =
        "$OrganizationUrl/$Project/_apis/wit/workitems/$($WorkItemId)?`$expand=relations&api-version=7.1"

    $verifiedWorkItem = Invoke-RestMethod `
        -Uri $verificationUrl `
        -Method Get `
        -Headers $Headers

    # ------------------------------------------------------------
    # Look for the newly uploaded attachment
    # ------------------------------------------------------------

    $linkedAttachment = @(
        $verifiedWorkItem.relations |
            Where-Object {
                $_.rel -eq "AttachedFile" -and
                $_.url -like "*$AttachmentId*"
            }
    )

    # ------------------------------------------------------------
    # Return verification result
    # ------------------------------------------------------------

    if ($linkedAttachment.Count -gt 0) {

        return $true
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
        [hashtable]$Headers
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

            # ----------------------------------------------------
            # TEST / DIAGNOSTIC OUTPUT
            # ----------------------------------------------------

            Write-Host "Linking attachment to cloned User Story..."

            $updatedWorkItem = Invoke-RestMethod `
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
                -Headers $Headers

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

    # ------------------------------------------------------------
    # Get source User Story
    # ------------------------------------------------------------

    $workItem = Get-AdoWorkItem `
        -WorkItemId $WorkItemId `
        -OrganizationUrl $organizationUrl `
        -Project $project `
        -Headers $Headers

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
            -Headers $Headers
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

# Checks for the right input file and for User Story ID's
$workItemIds = Get-WorkItemIdsFromFiles -InputFolder $inputFolder

Write-Host ""
Write-Host "Total unique User Stories found to clone: $($workItemIds.Count)"
Write-Host ""

# Cloning starts
$cloneResults = @()

foreach ($workItemId in $workItemIds) {


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
            Status            = "Failed"
            Error             = $_.Exception.Message
        }

        # IMPORTANT:
        # Continue processing the next User Story
        continue
    }


    # Delay between stories

    if ($delayBetweenStoriesSeconds -gt 0) {

        Write-Host ""
        Write-Host "Waiting $delayBetweenStoriesSeconds second(s) before next User Story..."
        Write-Host ""

        Start-Sleep -Seconds $delayBetweenStoriesSeconds
    }
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
        Status `
        -AutoSize