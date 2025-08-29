# PowerShell script to create/delete XMP files with Immich metadata and copy to Mylio inbox based on Immich.cfg configuration

# Load configuration from Immich.cfg in TOOLKIT_LOCATION
function Get-Config {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $configPath = Join-Path $scriptDir "Immich.cfg"
    if (-not (Test-Path $configPath)) {
        throw "Configuration file Immich.cfg not found in $scriptDir"
    }
    $config = Get-Content $configPath | ConvertFrom-Json

    # Construct paths based on IMMICH_ROOT
    $immichRoot = $config.DEFAULT_PATHS.IMMICH_ROOT
    $config.DEFAULT_PATHS.UPLOAD_LOCATION = Join-Path $immichRoot "library"
    $config.DEFAULT_PATHS.DB_DATA_LOCATION = Join-Path $immichRoot "postgres"
    $config.DEFAULT_PATHS.IMMICH_BACKUP = Join-Path $immichRoot "Backup"
    $config.DEFAULT_PATHS.TOOLKIT_LOCATION = Join-Path $immichRoot "ImmichToolkit"

    # Verify TOOLKIT_LOCATION matches script directory
    if ($scriptDir -ne $config.DEFAULT_PATHS.TOOLKIT_LOCATION) {
        throw "Script is not running from TOOLKIT_LOCATION ($($config.DEFAULT_PATHS.TOOLKIT_LOCATION))"
    }

    # Update config file paths
    $config.DEFAULT_FILES.IMMICH_JSON = Join-Path $config.DEFAULT_PATHS.TOOLKIT_LOCATION "Immich.cfg"
    $config.DEFAULT_FILES.IMMICH_LOG = Join-Path $config.DEFAULT_PATHS.TOOLKIT_LOCATION "Immich.log"

    # Dynamically populate IP_ADDRESS at startup
    $config.IMMICH_SERVER.IP_ADDRESS = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "Loopback*" }).IPAddress | Select-Object -First 1

    return $config
}

# Log function to write to Immich.log
function Write-Log {
    param($Message)
    $config = Get-Config
    $logPath = $config.DEFAULT_FILES.IMMICH_LOG
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $logPath -Append
}

# Save API Key to Immich.cfg
function Save-ApiKey {
    param($ApiKey, $ProgressBar, $LogTextBox, $Buttons)
    try {
        if ($ProgressBar) { $ProgressBar.Value = 0 }
        if ($LogTextBox) { $LogTextBox.Text = "" }
        foreach ($button in $Buttons) { $button.IsEnabled = $false }
        Write-Log "Saving API Key"

        $config = Get-Config
        $config.IMMICH_SERVER.API_KEY = $ApiKey
        $config | ConvertTo-Json -Depth 10 | Set-Content $config.DEFAULT_FILES.IMMICH_JSON
        Write-Log "API Key updated in Immich.cfg"
    }
    catch {
        Write-Log "Error saving API Key: $_"
    }
    finally {
        foreach ($button in $Buttons) { $button.IsEnabled = $true }
    }
}

# Calculate SHA1 checksum of a file in base64
function Get-FileChecksumBase64 {
    param($FilePath)
    try {
        $hasher = [System.Security.Cryptography.SHA1]::Create()
        $fileStream = [System.IO.File]::OpenRead($FilePath)
        $hashBytes = $hasher.ComputeHash($fileStream)
        $fileStream.Close()
        return [System.Convert]::ToBase64String($hashBytes)
    }
    catch {
        Write-Log "Error calculating checksum for $FilePath: $_"
        return $null
    }
}

# Section 1: Create IMMICH XMP Files
function Create-ImmichXMPFiles {
    param($DryRun = $true, $FileTypes = @("*.jpg", "*.dng", "*.heic", "*.cr2", "*.nef", "*.arw", "*.orf", "*.rw2"), $ProgressBar, $LogTextBox, $Buttons)
    try {
        if ($ProgressBar) { $ProgressBar.Value = 0 }
        if ($LogTextBox) { $LogTextBox.Text = "" }
        foreach ($button in $Buttons) { $button.IsEnabled = $false }
        Write-Log "Section 1: Starting creation of IMMICH XMP files (DryRun: $DryRun, FileTypes: $($FileTypes -join ', '))"

        $config = Get-Config
        if (-not $config.IMMICH_SERVER.API_KEY) {
            Write-Log "Error: API Key is required for Immich API access"
            return
        }

        $server = "http://$($config.IMMICH_SERVER.IP_ADDRESS):$($config.IMMICH_SERVER.PORT)"
        $headers = @{
            "X-Api-Key" = $config.IMMICH_SERVER.API_KEY
            "Accept" = "application/json"
            "Content-Type" = "application/json"
        }

        $sourcePath = $config.DEFAULT_PATHS.UPLOAD_LOCATION
        if (-not (Test-Path $sourcePath)) {
            Write-Log "Error: Source path $sourcePath does not exist"
            return
        }

        # Get image files recursively
        $files = Get-ChildItem -Path $sourcePath -File -Include $FileTypes -Recurse
        $fileCount = $files.Count
        $index = 0

        # Update progress bar
        if ($ProgressBar -and $fileCount -gt 0) {
            $ProgressBar.Maximum = $fileCount
            $ProgressBar.Value = 0
        }

        foreach ($file in $files) {
            $index++
            if ($ProgressBar -and $fileCount -gt 0) {
                $ProgressBar.Value = $index
                [System.Windows.Forms.Application]::DoEvents() # Update UI
            }

            $xmpFile = Join-Path $file.DirectoryName "$($file.BaseName).xmp"
            if (-not (Test-Path $xmpFile)) {
                Write-Log "Processing XMP for $($file.FullName)"

                # Calculate checksum in base64
                $checksum = Get-FileChecksumBase64 -FilePath $file.FullName
                if (-not $checksum) { continue }

                # Check if asset exists
                $body = @{
                    assets = @(
                        @{
                            checksum = $checksum
                            deviceAssetId = "API"
                            deviceId = "API"
                        }
                    )
                } | ConvertTo-Json -Depth 5
                $bulkCheckResponse = Invoke-RestMethod -Uri "$server/api/asset/check-bulk-upload" -Method Post -Body $body -Headers $headers

                $result = $bulkCheckResponse.results[0]
                if ($result.isExist) {
                    $assetId = $result.assetId

                    # Get asset info
                    $assetInfoResponse = Invoke-RestMethod -Uri "$server/api/asset/$assetId" -Method Get -Headers $headers

                    $exifInfo = $assetInfoResponse.exifInfo
                    $metadata = @{
                        Description = if ($exifInfo.description) { $exifInfo.description } else { "" }
                        CreateDate = if ($exifInfo.dateTimeOriginal) { $exifInfo.dateTimeOriginal } else { $file.CreationTime.ToString("yyyy-MM-ddTHH:mm:ss") }
                        Latitude = $exifInfo.latitude
                        Longitude = $exifInfo.longitude
                        Make = if ($exifInfo.make) { $exifInfo.make } else { "" }
                        Model = if ($exifInfo.model) { $exifInfo.model } else { "" }
                        ImageWidth = if ($exifInfo.exifImageWidth) { [int]$exifInfo.exifImageWidth } else { 0 }
                        ImageHeight = if ($exifInfo.exifImageHeight) { [int]$exifImageHeight } else { 0 }
                        Orientation = if ($exifInfo.orientation) { [int]$exifInfo.orientation } else { 1 }
                    }
                    $isFavorite = $assetInfoResponse.isFavorite

                    $faces = @()
                    foreach ($person in $assetInfoResponse.people) {
                        foreach ($face in $person.faces) {
                            $faceWidth = [int]$face.boundingBoxX2 - [int]$face.boundingBoxX1
                            $faceHeight = [int]$face.boundingBoxY2 - [int]$face.boundingBoxY1
                            $faceObj = @{
                                Name = $person.name
                                X = ([int]$face.boundingBoxX1 + ($faceWidth / 2)) / [int]$face.imageWidth
                                Y = ([int]$face.boundingBoxY1 + ($faceHeight / 2)) / [int]$face.imageHeight
                                Width = $faceWidth / [int]$face.imageWidth
                                Height = $faceHeight / [int]$face.imageHeight
                            }
                            $faces += $faceObj
                        }
                    }

                    # Adjust face coordinates based on orientation
                    if ($metadata.Orientation -ne 1) {
                        $adjustedFaces = @()
                        foreach ($face in $faces) {
                            $adjustedFace = $face.Clone()
                            if ($metadata.Orientation -in @(5, 6, 7, 8)) { # Rotated 90° or 270°
                                $tempX = $face.X
                                $adjustedFace.X = $face.Y
                                $adjustedFace.Y = 1 - $tempX
                                $tempW = $face.Width
                                $adjustedFace.Width = $face.Height
                                $adjustedFace.Height = $tempW
                                if ($metadata.Orientation -in @(5, 7)) { # Mirrored
                                    $adjustedFace.X = 1 - $adjustedFace.X
                                }
                            }
                            if ($metadata.Orientation -in @(3, 4)) { # 180° or mirrored 180°
                                $adjustedFace.X = 1 - $face.X
                                $adjustedFace.Y = 1 - $face.Y
                            }
                            if ($metadata.Orientation -in @(2, 4)) { # Mirrored horizontally
                                $adjustedFace.X = 1 - $face.X
                            }
                            $adjustedFaces += $adjustedFace
                        }
                        $faces = $adjustedFaces
                    }

                    # Generate XMP content
                    $xmpContent = @"
<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
    xmlns:exif="http://ns.adobe.com/exif/1.0/"
    xmlns:mwg-rs="http://www.metadataworkinggroup.com/schemas/regions/"
    xmlns:stArea="http://ns.adobe.com/xmp/sType/Area#"
    xmlns:stDim="http://ns.adobe.com/xap/1.0/sType/Dimensions#">
   <dc:title>$($file.Name)</dc:title>
   <dc:description>$($metadata.Description)</dc:description>
   <xmp:CreateDate>$($metadata.CreateDate)</xmp:CreateDate>
"@
                    if ($isFavorite) {
                        $xmpContent += "   <xmp:Rating>5</xmp:Rating>`n"
                    }

                    if ($metadata.Latitude -and $metadata.Longitude) {
                        $lat = [double]$metadata.Latitude
                        $lon = [double]$metadata.Longitude
                        $latRef = if ($lat -ge 0) { "N" } else { "S" }
                        $lonRef = if ($lon -ge 0) { "E" } else { "W" }
                        $latDeg = [math]::Abs($lat)
                        $lonDeg = [math]::Abs($lon)
                        $xmpContent += @"
   <exif:GPSLatitude>$latDeg,0.0$latRef</exif:GPSLatitude>
   <exif:GPSLongitude>$lonDeg,0.0$lonRef</exif:GPSLongitude>
"@
                    }
                    if ($metadata.Make) { $xmpContent += "   <exif:Make>$($metadata.Make)</exif:Make>`n" }
                    if ($metadata.Model) { $xmpContent += "   <exif:Model>$($metadata.Model)</exif:Model>`n" }
                    
                    if ($faces.Count -gt 0) {
                        $xmpContent += @"
   <mwg-rs:RegionInfo>
    <mwg-rs:AppliedToDimensions stDim:w="$($metadata.ImageWidth)" stDim:h="$($metadata.ImageHeight)" stDim:unit="pixel"/>
    <mwg-rs:Regions>
     <rdf:Bag>
"@
                        foreach ($face in $faces) {
                            $xmpContent += @"
      <rdf:li rdf:parseType="Resource">
       <mwg-rs:Name>$($face.Name)</mwg-rs:Name>
       <mwg-rs:Type>Face</mwg-rs:Type>
       <mwg-rs:Description>mylio_face</mwg-rs:Description>
       <mwg-rs:Area stArea:x="$($face.X)" stArea:y="$($face.Y)" stArea:w="$($face.Width)" stArea:h="$($face.Height)" stArea:unit="normalized"/>
      </rdf:li>
"@
                        }
                        $xmpContent += @"
     </rdf:Bag>
    </mwg-rs:Regions>
   </mwg-rs:RegionInfo>
"@
                    }
                    $xmpContent += @"
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
"@
                    if (-not $DryRun) {
                        $xmpContent | Out-File -FilePath $xmpFile -Encoding utf8
                        Write-Log "Created XMP file at $xmpFile"
                    }
                } else {
                    Write-Log "Asset not found in Immich for checksum $checksum"
                }
            }
        }

        if ($ProgressBar) {
            $ProgressBar.Value = 0
        }
        Write-Log "Section 1: XMP file creation completed"
    }
    catch {
        Write-Log "Section 1: Error during XMP file creation: $_"
    }
    finally {
        if ($ProgressBar) {
            $ProgressBar.Value = 0
        }
        foreach ($button in $Buttons) {
            $button.IsEnabled = $true
        }
    }
}

# Section 1: Delete IMMICH XMP Files
function Delete-ImmichXMPFiles {
    param($DryRun = $true, $ProgressBar, $LogTextBox, $Buttons)
    try {
        if ($ProgressBar) { $ProgressBar.Value = 0 }
        if ($LogTextBox) { $LogTextBox.Text = "" }
        foreach ($button in $Buttons) { $button.IsEnabled = $false }
        Write-Log "Section 1: Starting deletion of IMMICH XMP files (DryRun: $DryRun)"

        $config = Get-Config
        $sourcePath = $config.DEFAULT_PATHS.UPLOAD_LOCATION
        if (-not (Test-Path $sourcePath)) {
            Write-Log "Error: Source path $sourcePath does not exist"
            return
        }

        # Get all XMP files recursively, only those matching image filenames
        $imageFiles = Get-ChildItem -Path $sourcePath -File -Include @("*.jpg", "*.dng", "*.heic", "*.cr2", "*.nef", "*.arw", "*.orf", "*.rw2") -Recurse
        $xmpFiles = Get-ChildItem -Path $sourcePath -File -Include "*.xmp" -Recurse
        $imageBaseNames = $imageFiles | ForEach-Object { $_.BaseName }
        $xmpFilesToDelete = $xmpFiles | Where-Object { $imageBaseNames -contains $_.BaseName }

        $fileCount = $xmpFilesToDelete.Count
        $index = 0

        if ($fileCount -eq 0) {
            Write-Log "No matching XMP files found to delete"
            return
        }

        # Update progress bar
        if ($ProgressBar -and $fileCount -gt 0) {
            $ProgressBar.Maximum = $fileCount
            $ProgressBar.Value = 0
        }

        foreach ($xmpFile in $xmpFilesToDelete) {
            $index++
            if ($ProgressBar -and $fileCount -gt 0) {
                $ProgressBar.Value = $index
                [System.Windows.Forms.Application]::DoEvents() # Update UI
            }

            Write-Log "Deleting XMP file $($xmpFile.FullName)"
            if (-not $DryRun) {
                Remove-Item -Path $xmpFile.FullName -Force
            }
        }

        if ($ProgressBar) {
            $ProgressBar.Value = 0
        }
        Write-Log "Section 1: XMP file deletion completed"
    }
    catch {
        Write-Log "Section 1: Error during XMP file deletion: $_"
    }
    finally {
        if ($ProgressBar) {
            $ProgressBar.Value = 0
        }
        foreach ($button in $Buttons) {
            $button.IsEnabled = $true
        }
    }
}

# Section 2: Copy to Mylio Inbox
function Copy-ToMylio {
    param($DryRun = $true, $FileTypes = @("*.jpg", "*.dng", "*.heic", "*.cr2", "*.nef", "*.arw", "*.orf", "*.rw2"), $LastRunDate, $ProgressBar, $LogTextBox, $Buttons)
    try {
        if ($ProgressBar) { $ProgressBar.Value = 0 }
        if ($LogTextBox) { $LogTextBox.Text = "" }
        foreach ($button in $Buttons) { $button.IsEnabled = $false }
        Write-Log "Section 2: Starting copy to Mylio inbox (DryRun: $DryRun, FileTypes: $($FileTypes -join ', '), LastRunDate: $LastRunDate)"

        $config = Get-Config
        $sourcePath = $config.DEFAULT_PATHS.UPLOAD_LOCATION
        $destPath = $config.DEFAULT_PATHS.MYLIO_INBOX
        if (-not $destPath) {
            Write-Log "Error: MYLIO_INBOX path not specified in configuration"
            return
        }
        if (-not $LastRunDate) {
            Write-Log "Error: LastRunDate not specified"
            return
        }

        if (-not (Test-Path $sourcePath)) {
            Write-Log "Error: Source path $sourcePath does not exist"
            return
        }
        if (-not (Test-Path $destPath)) {
            Write-Log "Warning: Destination path $destPath does not exist. Creating..."
            if (-not $DryRun) {
                New-Item -Path $destPath -ItemType Directory -Force | Out-Null
            }
        }

        # Process files in batches to optimize for large datasets
        $batchSize = 100
        $files = Get-ChildItem -Path $sourcePath -File -Include $FileTypes -Recurse | Where-Object { $_.CreationTime -gt $LastRunDate }
        $fileCount = $files.Count
        $index = 0

        # Update progress bar
        if ($ProgressBar -and $fileCount -gt 0) {
            $ProgressBar.Maximum = $fileCount
            $ProgressBar.Value = 0
        }

        while ($index -lt $fileCount) {
            $batch = $files | Select-Object -Skip $index -First $batchSize
            foreach ($file in $batch) {
                $index++
                if ($ProgressBar -and $fileCount -gt 0) {
                    $ProgressBar.Value = $index
                    [System.Windows.Forms.Application]::DoEvents() # Update UI
                }

                $destFile = Join-Path $destPath $file.Name
                if (-not (Test-Path $destFile)) {
                    Write-Log "Copying $($file.FullName) to $destFile (CreationTime: $($file.CreationTime))"
                    if (-not $DryRun) {
                        Copy-Item -Path $file.FullName -Destination $destFile -Force
                    }
                } else {
                    Write-Log "Skipping $($file.FullName) as it already exists in $destPath"
                }

                # Copy corresponding XMP file if it exists
                $xmpFile = Join-Path $file.DirectoryName "$($file.BaseName).xmp"
                if (Test-Path $xmpFile) {
                    $destXmpFile = Join-Path $destPath "$($file.BaseName).xmp"
                    if (-not (Test-Path $destXmpFile)) {
                        Write-Log "Copying XMP $($xmpFile) to $destXmpFile"
                        if (-not $DryRun) {
                            Copy-Item -Path $xmpFile -Destination $destXmpFile -Force
                        }
                    } else {
                        Write-Log "Skipping XMP $($xmpFile) as it already exists in $destPath"
                    }
                }
            }
            $index += $batchSize
        }

        # Update LAST_SYNC timestamp in Immich.cfg with completion date and time if not dry run
        if (-not $DryRun) {
            $completionTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $config.GENERAL_SETTINGS.LAST_SYNC = $completionTime
            $config | ConvertTo-Json -Depth 10 | Set-Content $config.DEFAULT_FILES.IMMICH_JSON
            Write-Log "Updated LAST_SYNC to $completionTime in Immich.cfg"
        }

        if ($ProgressBar) {
            $ProgressBar.Value = 0
        }
        Write-Log "Section 2: Copy to Mylio inbox completed"
    }
    catch {
        Write-Log "Section 2: Error during copy to Mylio inbox: $_"
    }
    finally {
        if ($ProgressBar) {
            $ProgressBar.Value = 0
        }
        foreach ($button in $Buttons) {
            $button.IsEnabled = $true
        }
    }
}

# Load and show GUI
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
function Show-GUI {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $xamlPath = Join-Path $scriptDir "ImmichToMylioSync.xaml"
    $xaml = [System.IO.File]::ReadAllText($xamlPath)
    $reader = (New-Object System.Xml.XmlNodeReader $xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)

    # Get controls
    $createXmpButton = $window.FindName("CreateXmpButton")
    $deleteXmpButton = $window.FindName("DeleteXmpButton")
    $copyToMylioButton = $window.FindName("CopyToMylioButton")
    $dryRunCheckBox = $window.FindName("DryRunCheckBox")
    $logTextBox = $window.FindName("LogTextBox")
    $uploadFolderTextBox = $window.FindName("UploadFolderTextBox")
    $fileTypesTextBox = $window.FindName("FileTypesTextBox")
    $ipAddressTextBox = $window.FindName("IpAddressTextBox")
    $portTextBox = $window.FindName("PortTextBox")
    $apiKeyTextBox = $window.FindName("ApiKeyTextBox")
    $saveApiKeyButton = $window.FindName("SaveApiKeyButton")
    $mylioInboxTextBox = $window.FindName("MylioInboxTextBox")
    $lastRunDatePicker = $window.FindName("LastRunDatePicker")
    $progressBar = $window.FindName("ProgressBar")

    # List of buttons to enable/disable
    $buttons = @($createXmpButton, $deleteXmpButton, $copyToMylioButton, $saveApiKeyButton)

    # Load config for display
    $config = Get-Config
    $uploadFolderTextBox.Text = $config.DEFAULT_PATHS.UPLOAD_LOCATION
    $fileTypesTextBox.Text = ".jpg,.dng,.heic,.cr2,.nef,.arw,.orf,.rw2"
    $ipAddressTextBox.Text = $config.IMMICH_SERVER.IP_ADDRESS
    $portTextBox.Text = $config.IMMICH_SERVER.PORT
    $apiKeyTextBox.Text = $config.IMMICH_SERVER.API_KEY
    $mylioInboxTextBox.Text = $config.DEFAULT_PATHS.MYLIO_INBOX
    if ($config.GENERAL_SETTINGS.LAST_SYNC) {
        try {
            $lastRunDatePicker.SelectedDate = [DateTime]::Parse($config.GENERAL_SETTINGS.LAST_SYNC)
        }
        catch {
            Write-Log "Error parsing LAST_SYNC: $_"
            $lastRunDatePicker.SelectedDate = $null
        }
    }

    # Button click events
    $createXmpButton.Add_Click({
        $dryRun = $dryRunCheckBox.IsChecked
        $fileTypes = $fileTypesTextBox.Text.Split(",") | ForEach-Object { "*$_" }
        Create-ImmichXMPFiles -DryRun $dryRun -FileTypes $fileTypes -ProgressBar $progressBar -LogTextBox $logTextBox -Buttons $buttons
        $logContent = Get-Content $config.DEFAULT_FILES.IMMICH_LOG -Tail 10
        $logTextBox.Text = ($logContent -join "`n") + "`n"
    })

    $deleteXmpButton.Add_Click({
        $dryRun = $dryRunCheckBox.IsChecked
        $result = [System.Windows.MessageBox]::Show("Are you sure you want to delete all XMP files in UPLOAD_LOCATION and subfolders?", "Confirm Deletion", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
            Delete-ImmichXMPFiles -DryRun $dryRun -ProgressBar $progressBar -LogTextBox $logTextBox -Buttons $buttons
            $logContent = Get-Content $config.DEFAULT_FILES.IMMICH_LOG -Tail 10
            $logTextBox.Text = ($logContent -join "`n") + "`n"
        } else {
            $logTextBox.Text = "Deletion cancelled by user`n"
        }
    })

    $copyToMylioButton.Add_Click({
        $dryRun = $dryRunCheckBox.IsChecked
        $fileTypes = $fileTypesTextBox.Text.Split(",") | ForEach-Object { "*$_" }
        $lastRunDate = $lastRunDatePicker.SelectedDate
        if (-not $lastRunDate) {
            $logTextBox.Text = "Error: Please select a valid Last Run date`n"
            return
        }
        $result = [System.Windows.MessageBox]::Show("Are you sure you want to copy files to MYLIO_INBOX?", "Confirm Copy", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
            Copy-ToMylio -DryRun $dryRun -FileTypes $fileTypes -LastRunDate $lastRunDate -ProgressBar $progressBar -LogTextBox $logTextBox -Buttons $buttons
            $logContent = Get-Content $config.DEFAULT_FILES.IMMICH_LOG -Tail 10
            $logTextBox.Text = ($logContent -join "`n") + "`n"
            # Update LastRunDatePicker after successful copy (non-dry run)
            if (-not $dryRun) {
                $config = Get-Config # Reload config to get updated LAST_SYNC
                try {
                    $lastRunDatePicker.SelectedDate = [DateTime]::Parse($config.GENERAL_SETTINGS.LAST_SYNC)
                }
                catch {
                    Write-Log "Error parsing updated LAST_SYNC: $_"
                    $lastRunDatePicker.SelectedDate = $null
                }
            }
        } else {
            $logTextBox.Text = "Copy cancelled by user`n"
        }
    })

    $saveApiKeyButton.Add_Click({
        Save-ApiKey -ApiKey $apiKeyTextBox.Text -ProgressBar $progressBar -LogTextBox $logTextBox -Buttons $buttons
        $logContent = Get-Content $config.DEFAULT_FILES.IMMICH_LOG -Tail 10
        $logTextBox.Text = ($logContent -join "`n") + "`n"
    })

    $window.ShowDialog() | Out-Null
}

# Start the script
Show-GUI