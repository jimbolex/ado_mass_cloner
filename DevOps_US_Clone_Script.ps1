# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------

# Reading Config XML

$configPath = Join-Path $PSScriptRoot "config.xml"

if (-not (Test-Path $configPath)) {
    Write-Host "ERROR: config.xml was not found." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

[xml]$config = Get-Content $configPath


# Reading Input folder

$inputFolderName = $config.Configuration.UserStories.InputFolder
$inputFolder = Join-Path $PSScriptRoot $inputFolderName

if (-not (Test-Path $inputFolder)) {
    throw "User Story input folder was not found: $inputFolder"
}

$inputFiles = @(
    Get-ChildItem `
        -Path $inputFolder `
        -Filter "*.txt" `
        -File
)

if ($inputFiles.Count -eq 0) {
    throw "No .txt files were found in: $inputFolder"
}

# ------------------------------------------------------------
# AUTHENTICATION
# ------------------------------------------------------------

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

# ------------------------------------------------------------
# GET ORIGINAL USER STORIES
# ------------------------------------------------------------

# Azure DevOps
$organizationUrl = $config.Configuration.AzureDevOps.OrganizationUrl
$project = $config.Configuration.AzureDevOps.Project


# Destination
$areaPath = $config.Configuration.Destination.AreaPath
$iterationPath = $config.Configuration.Destination.IterationPath

# US(s) to clone
$workItemIds = @()

foreach ($file in $inputFiles) {

    Write-Host "Reading: $($file.Name)"

    $lines = Get-Content $file.FullName

    foreach ($line in $lines) {

        $value = $line.Trim()

        # Ignore blank lines
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        # Validate Azure DevOps Work I*em ID
        $parsedId = 0

        if ([int]::TryParse($value, [ref]$parsedId)) {

            $workItemIds += $parsedId

        }
        else {

            Write-Warning "Invalid User Story ID '$value' is $($file.Name)"
        }
    }
}

# Remove duplicates if any

$workItemIds = @(
    $workItemIds |
        Sort-Object -Unique
)

if ($workItemIds.Count -eq 0){ 
    throw "No valid User Story ID* were found in the input files."
}

Write-Host ""
Write-Host "==========================================="
Write-Host "USER STORIES TO CLONE"
Write-Host "==========================================="

$workItemIds | ForEach-Object {
    Write-Host $_
}

Write-Host ""
Write-Host "Total unique User Stories: $($workItemIds.Count)"
Write-Host ""


# Cloning starts
$cloneResults = @()

foreach ($workItemId in $workItemIds) {

    try {

        Write-Host ""
        Write-Host "============================================"
        Write-Host "CLONING USER STORY $workItemId"
        Write-Host "============================================"

        $url = "$organizationUrl/$project/_apis/wit/workitems/$($workItemId)?`$expand=relations&api-version=7.1"

        $workItem = Invoke-RestMethod `
            -Uri $url `
            -Method Get `
            -Headers $headers

        Write-Host ""
        Write-Host "Original User Story:"
        Write-Host "ID:    $($workItem.id)"
        Write-Host "Title: $($workItem.fields.'System.Title')"

        # ------------------------------------------------------------
        # BUILD NEW USER STORY
        # ------------------------------------------------------------

        $body = @()

        # Add a title marker so the clone is easy to identify.
        $cloneTitle = "$($workItem.fields.'System.Title') - Copy"

        # Title
        $body += @{
            op    = "add"
            path  = "/fields/System.Title"
            value = $cloneTitle
        }

        # Area Path
        $body += @{
            op    = "add"
            path  = "/fields/System.AreaPath"
            value = $areaPath
        }

        # Iteration Path
        $body += @{
            op    = "add"
            path  = "/fields/System.IterationPath"
            value = $iterationPath
        }

        # Description
        if ($null -ne $workItem.fields.'System.Description') {

            $body += @{
                op    = "add"
                path  = "/fields/System.Description"
                value = $workItem.fields.'System.Description'
            }
        }

        # Acceptance Criteria
        if ($null -ne $workItem.fields.'Microsoft.VSTS.Common.AcceptanceCriteria') {

            $body += @{
                op    = "add"
                path  = "/fields/Microsoft.VSTS.Common.AcceptanceCriteria"
                value = $workItem.fields.'Microsoft.VSTS.Common.AcceptanceCriteria'
            }
        }

        # Tags
        if ($null -ne $workItem.fields.'System.Tags') {

            $body += @{
                op    = "add"
                path  = "/fields/System.Tags"
                value = $workItem.fields.'System.Tags'
            }
        }

        # ------------------------------------------------------------
        # COPY PARENT RELATION
        # ------------------------------------------------------------

        $parentRelation = $workItem.relations |
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

        Write-Host "Related: $($workItem.url)"

        $body += @{
            op   = "add"
            path = "/relations/-"
            value = @{
                rel = "System.LinkTypes.Related"
                url = $workItem.url
            }
        }


        # ------------------------------------------------------------
        # CREATE CLONE
        # ------------------------------------------------------------

        $encodedWorkItemType = [Uri]::EscapeDataString("User Story")

        $createUrl = "$organizationUrl/$project/_apis/wit/workitems/`$$encodedWorkItemType"+"?api-version=7.1"

        $jsonBody = $body | ConvertTo-Json -Depth 10

        $newWorkItem = Invoke-RestMethod `
            -Uri $createUrl `
            -Method Post `
            -Headers $headers `
            -ContentType "application/json-patch+json" `
            -Body $jsonBody


        # ------------------------------------------------------------
        # Find only attachment relations
        # ------------------------------------------------------------
        
        $copyAttachments =
            [System.Convert]::ToBoolean(
                $config.Configuration.CloneOptions.CopyAttachments
            )

        if ($copyAttachments) {
            
            $attachmentRelations = @(
                $workItem.relations |
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
 
                $comment = $attachmentRelation.attributes.comment
 
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
                        -Headers $headers `
                        -OutFile $tempFilePath

                    # Verify downloaded file
                    if (-not (Test-Path $tempFilePath)) {
                        throw "Downloaded attachment was not found: $tempFilePath"
                    }

                    $fileInfo = Get-Item $tempFilePath

                    Write-Host "Downloaded successfully."
                    Write-Host "Temporary file: $($fileInfo.FullName)"
                    Write-Host "File size: $($fileInfo.Length) bytes"

                    # ----------------------------------------------------
                    # Upload attachment as a NEW attachment
                    # ----------------------------------------------------

                    $encodedFileName = [Uri]::EscapeDataString($fileName)

                    $uploadUrl = "$organizationUrl/$project/_apis/wit/attachments?fileName=$encodedFileName&api-version=7.1"

                    $fileBytes = [System.IO.File]::ReadAllBytes($tempFilePath)

                    Write-Host ""
                    Write-Host "Uploading attachment..."
                    Write-Host "Upload URL: $uploadUrl"

                    $uploadedAttachment = Invoke-RestMethod `
                        -Uri $uploadUrl `
                        -Method Post `
                        -Headers $headers `
                        -ContentType "application/octet-stream" `
                        -Body $fileBytes
        
                    Write-Host ""
                    Write-Host "Upload successful." -ForegroundColor Green
                    Write-Host ""
                    Write-Host "Attachment ID: $($uploadedAttachment.id)"
                    Write-Host "Attachment URL: $($uploadedAttachment.url)"

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

                    $updateUrl = "$organizationUrl/$project/_apis/wit/workitems/$($newWorkItem.id)?api-version=7.1"

                    # ----------------------------------------------------
                    # TEST / DIAGNOSTIC OUTPUT
                    # ----------------------------------------------------

                    Write-Host ""
                    Write-Host "Linking attachment to cloned User Story..."
                    Write-Host "Clone ID: $($newWorkItem.id)"
                    Write-Host "PATCH URL: $updateUrl"
                    Write-Host "Attachment URL: $($uploadedAttachment.url)"
                    Write-Host "PATCH body length: $($attachmentPatch.Length) characters"
                    Write-Host ""

                    $updatedWorkItem = Invoke-RestMethod `
                        -Uri $updateUrl `
                        -Method Patch `
                        -Headers $headers `
                        -ContentType "application/json-patch+json" `
                        -Body ([System.Text.Encoding]::UTF8.GetBytes($attachmentPatch))

                    Write-Host "Attachment linked successfully." -ForegroundColor Green

                    # ----------------------------------------------------
                    # Verify relation returned by Azure DevOps
                    # ----------------------------------------------------

                    # ----------------------------------------------------
                    # Retrieve the cloned work item with expanded relations
                    # ----------------------------------------------------

                    $verificationUrl = "$organizationUrl/$project/_apis/wit/workitems/$($newWorkItem.id)?`$expand=relations&api-version=7.1"

                    Write-Host ""
                    Write-Host "Verifying attachment..."
                    Write-Host "Verification URL: $verificationUrl"

                    $verifiedWorkItem = Invoke-RestMethod `
                        -Uri $verificationUrl `
                        -Method Get `
                        -Headers $headers

                    # ----------------------------------------------------
                    # Validate uploaded attachment
                    # ----------------------------------------------------

                    $uploadedAttachmentId = [string]$uploadedAttachment.id

                    $linkedAttachment = @(
                        $verifiedWorkItem.relations |
                            Where-Object {
                                $_.rel -eq "AttachedFile" -and
                                $_.url -like "*$uploadedAttachmentId*"
                            }
                    )

                    if ($linkedAttachment.Count -gt 0) {

                        Write-Host ""
                        Write-Host "Verified: attachment exists on cloned User Story." -ForegroundColor Green
                        Write-Host ""

                        foreach ($verifiedAttachment in $linkedAttachment) {
                            Write-Host "Name: $($verifiedAttachment.attributes.name)"
                            Write-Host "URL:  $($verifiedAttachment.url)"
                        }
                    }
                    else {

                        Write-Host ""
                        Write-Warning "The PATCH succeeded, but the uploaded attachment was not found during verification."
                        Write-Host ""
                        Write-Host "Attachment relations returned by Azure DevOps:"

                        $verifiedWorkItem.relations |
                            Where-Object {
                                $_.rel -eq "AttachedFile"
                            } |
                            Select-Object `
                                rel,
                                url,
                                @{
                                    Name       = "AttachmentName"
                                    Expression = { $_.attributes.name }
                                } | Format-Table -AutoSize
                    }

                    $attachmentResults += [PSCustomObject]@{
                        FileName = $fileName
                        Status   = "Copied"
                        Error    = $null
                    }
                }
                catch {

                    Write-Host ""
                    Write-Warning "Attachment could not be copied: $fileName"

                    Write-Host "Exception:" -ForegroundColor Red
                    Write-Host $_.Exception.Message -ForegroundColor Red

                    # Azure DevOps often puts the important error here
                    if ($_.ErrorDetails.Message) {

                        Write-Host ""
                        Write-Host "Azure DevOps response:" -ForegroundColor Yellow
                        Write-Host $_.ErrorDetails.Message -ForegroundColor Yellow
                    }

                    Write-Host ""

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

                $cloneResults += [PSCustomObject]@{
                    SourceId          = $workItemId
                    CloneId           = $newWorkItem.id
                    Title             = $cloneTitle
                    AttachmentsFound  = $attachmentRelations.Count
                    AttachmentsCopied = @(
                        $attachmentResults |
                        Where-Object { $_.Status -eq "Copied" }
                    ).Count
                    Status            = "Success"
                    Error             = $null
                }
            }
        
        }
    catch {

        Write-Host ""
        Write-Warning "User Story $workItemId could not be cloned."
        Write-Warning $_.Exception.Message

        $cloneResults += [PSCustomObject]@{
            SourceId          = $workItemId
            CloneId           = $null
            Title             = $null
            AttachmentsFound  = $null
            AttachmentsCopied = $null
            Status            = "Failed"
            Error             = $_.Exception.Message
        }

        # IMPORTANT:
        # Continue processing the next User Story
        continue
    }
}

 
# ------------------------------------------------------------
# Display results
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