# ─────────────────────────────────────────────────────────────
# 1. Configuration & IP Address Management
# ─────────────────────────────────────────────────────────────

function Update-ImmichConfig {
    param (
        [string]$ConfigPath,
        [string]$NewIpAddress,
        [int]$Port,
        [string]$ApiKey
    )
    try {
        $configData = Get-Content -Path $ConfigPath | Out-String | ConvertFrom-Json
        $configData.IMMICH_SERVER.IP_ADDRESS = $NewIpAddress
        $configData.IMMICH_SERVER.PORT = $Port
        $configData.IMMICH_SERVER.API_KEY = $ApiKey
        $configData | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigPath
    }
    catch {
        Write-Log -Message "Failed to save configuration: $_" -Level Error
        [System.Windows.MessageBox]::Show("Failed to save configuration.", "Error", "OK", "Error")
        throw "Failed to save configuration: $_"
    }
}

# --- Initial Setup on Script Start ---
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.IO.Compression.FileSystem

# Get script directory
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configFilePath = Join-Path -Path $scriptDir -ChildPath "Immich.cfg"

# Function to write to log file
function Write-Log {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [string]$Level = "Info"
    )
    $timestamp = Get-Date -Format "HH:mm:ss"
    $statusText.Text = "$timestamp [$Level]: $Message"
    [System.Windows.Forms.Application]::DoEvents()
}

# Check for and create default config file if not found
if (-not (Test-Path $configFilePath)) {
    [System.Windows.Forms.Application]::DoEvents()
    $defaultConfig = @{
        "DEFAULT_PATHS" = @{
            "IMMICH_ROOT" = "C:\Immich"
            "UPLOAD_LOCATION" = "C:\Immich\library"
            "DB_DATA_LOCATION" = "C:\Immich\postgres"
            "IMMICH_BACKUP" = "C:\Immich\Backup"
            "TOOLKIT_LOCATION" = "C:\Immich\ImmichToolkit"
            "EXTERNAL_LIBRARY" = "C:\Users\Johann\Pictures"
            "MYLIO_INBOX" = ""
        }
        "DEFAULT_FILES" = @{
            "IMMICH_JSON" = "C:\Immich\ImmichToolkit\Immich.cfg"
        }
        "IMMICH_SERVER" = @{
            "IP_ADDRESS" = "0.0.0.0"
            "PORT" = 2283
            "API_KEY" = $null
            "DATABASE_PASSWORD" = "postgres"
        }
        "GENERAL_SETTINGS" = @{
            "DRY_RUN" = $true
            "BACKUP_NUMBER" = 3
            "LAST_SYNC" = ""
        }
    }
    try {
        $defaultConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $configFilePath -Encoding UTF8
        [System.Windows.MessageBox]::Show("A default 'Immich.cfg' has been created. Please open it to configure your paths and API Key.", "Configuration File Created", "OK", "Information")
        exit
    }
    catch {
        [System.Windows.MessageBox]::Show("Failed to create the Immich.cfg file. Please check permissions.", "Configuration Error", "OK", "Error")
        exit
    }
}

# Load configuration file
try {
    $config = Get-Content -Path $configFilePath | Out-String | ConvertFrom-Json
    $toolkitLocation = $config.DEFAULT_PATHS.TOOLKIT_LOCATION
}
catch {
    [System.Windows.MessageBox]::Show("Could not read or parse the Immich.cfg file. Please check its format.", "Configuration Error", "OK", "Error")
    exit
}

# ─────────────────────────────────────────────────────────────
# 2. GUI Setup & Event Handlers
# ─────────────────────────────────────────────────────────────
$xaml = Get-Content -Path "$toolkitLocation\MylioToImmich.xaml" | Out-String
$reader = [System.Xml.XmlNodeReader]::new([System.Xml.XmlDocument]::new())
$reader.LoadXml($xaml)

$window = [Windows.Markup.XamlReader]::Load($reader)
$createImmichXMPsButton = $window.FindName("CreateImmichXMPsButton")
$deleteImmichXMPsButton = $window.FindName("DeleteImmichXMPsButton")
$retryButton = $window.FindName("RetryButton")
$serverIpText = $window.FindName("ServerIpText")
$portText = $window.FindName("PortText")
$apiKeyTextBox = $window.FindName("ApiKeyTextBox")
$saveApiKeyButton = $window.FindName("SaveApiKeyButton")
$discoverLibrariesButton = $window.FindName("DiscoverLibrariesButton")
$libraryComboBox = $window.FindName("LibraryComboBox")
$rescanButton = $window.FindName("RescanButton")
$statusText = $window.FindName("StatusText")
$progressBar = $window.FindName("ProgressBar")

# Get local IP and update config if needed
Write-Log -Message "Checking system IP address..."
$currentIp = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -ne 'Loopback Pseudo-Interface 1' }).IPAddress
if ($currentIp -ne $config.IMMICH_SERVER.IP_ADDRESS) {
    Write-Log -Message "IP address changed. Updating configuration."
    Update-ImmichConfig -ConfigPath $configFilePath -NewIpAddress $currentIp -Port $config.IMMICH_SERVER.PORT -ApiKey $config.IMMICH_SERVER.API_KEY
    $config = Get-Content -Path $configFilePath | Out-String | ConvertFrom-Json
}
Clear-StatusWindow

# ─────────────────────────────────────────────────────────────
# 3. ExifTool Functions
# ─────────────────────────────────────────────────────────────

function Download-ExifTool {
    param(
        [string]$ToolkitPath
    )
    Write-Log -Message "ExifTool not found. Downloading..."
    $zipPath = Join-Path -Path $ToolkitPath -ChildPath "exiftool.zip"
    $exifToolUrl = "https://exiftool.org/exiftool-12.78.zip"
    
    try {
        Invoke-WebRequest -Uri $exifToolUrl -OutFile $zipPath -UseBasicParsing
        Write-Log -Message "Download complete. Extracting files..."
        Expand-Archive -Path $zipPath -DestinationPath $ToolkitPath -Force
        Rename-Item -Path (Join-Path -Path $ToolkitPath -ChildPath "exiftool-12.78\exiftool.exe") -NewName (Join-Path -Path $ToolkitPath -ChildPath "exiftool.exe")
        Remove-Item -Path (Join-Path -Path $ToolkitPath -ChildPath "exiftool-12.78") -Recurse -Force
        Remove-Item -Path $zipPath -Force
        Write-Log -Message "ExifTool installed successfully."
        return $true
    }
    catch {
        Write-Log -Message "Failed to download/install ExifTool." -Level Error
        [System.Windows.MessageBox]::Show("Failed to download or install ExifTool. Please download it manually and place 'exiftool.exe' in the toolkit directory.", "Installation Error", "OK", "Error")
        return $false
    }
}

function Check-ExifTool {
    param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Controls.Button]$CreateButton
    )
    Toggle-Buttons -Enable:$false
    Clear-StatusWindow
    Write-Log -Message "Checking for exiftool.exe..."
    $exifToolPath = Join-Path -Path $toolkitLocation -ChildPath "exiftool.exe"
    
    if (-not (Test-Path $exifToolPath)) {
        if (-not (Download-ExifTool -ToolkitPath $toolkitLocation)) {
            $CreateButton.IsEnabled = $false
            Toggle-Buttons -Enable:$true
            return $false
        }
    }
    
    $CreateButton.IsEnabled = $true
    Write-Log -Message "ExifTool found. You can now create Immich XMPs."
    $progressBar.Value = 100
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Seconds 1
    Clear-StatusWindow
    Toggle-Buttons -Enable:$true
    return $true
}

function Remove-MylioTags {
    param (
        [string]$MylioXmpPath,
        [string]$TempImmichXmpPath
    )
    $exifToolPath = Join-Path -Path $toolkitLocation -ChildPath "exiftool.exe"
    $command = "`"$exifToolPath`" -o `"$TempImmichXmpPath`" -overwrite_original -tagsfromfile `"$MylioXmpPath`" -all:all -Mylio:all -ext xmp `"$MylioXmpPath`""
    try {
        Invoke-Expression $command -ErrorAction Stop
    }
    catch {
        Write-Log -Message "Error executing ExifTool: $_" -Level Error
        throw
    }
}

function Create-ImmichXmpFiles {
    param (
        [string]$ExternalLibraryPath
    )
    Toggle-Buttons -Enable:$false
    Clear-StatusWindow
    Write-Log -Message "Starting process to create Immich XMP files..."
    $progressBar.Value = 0
    [System.Windows.Forms.Application]::DoEvents()

    $allFiles = Get-ChildItem -Path $ExternalLibraryPath -Recurse -File
    $mylioXmps = @{}
    $images = @{}
    $immichXmpFiles = @()

    $totalFiles = $allFiles.Count
    $processedCount = 0

    foreach ($file in $allFiles) {
        $baseName = [System.IO.Path]::Combine($file.DirectoryName, [System.IO.Path]::GetFileNameWithoutExtension($file.FullName))
        if ($file.Extension -eq '.xmp') {
            $matchingImage = Get-Item -Path ($baseName + ".*") -ErrorAction SilentlyContinue
            if ($matchingImage) { $mylioXmps[$baseName] = $file.FullName }
        }
        $imageExtensions = @('.jpg', '.jpeg', '.tiff', '.tif', '.png', '.heic', '.dng', '.raf', '.cr2', '.nef', '.arw')
        if ($imageExtensions -contains $file.Extension.ToLower()) {
            $images[$baseName] = $file.FullName
            $immichXmpPath = "$baseName$($file.Extension).xmp"
            if (Test-Path $immichXmpPath) { $immichXmpFiles += $immichXmpPath }
        }
    }

    $processedImmichXmps = @{}
    $totalImages = $images.Keys.Count
    $imagesProcessed = 0

    foreach ($imagePathWithoutExt in $images.Keys) {
        if ($mylioXmps.ContainsKey($imagePathWithoutExt)) {
            $mylioXmpPath = $mylioXmps[$imagePathWithoutExt]
            $imageFullPath = $images[$imagePathWithoutExt]
            $imageName, $imageExt = [System.IO.Path]::GetFileNameWithoutExtension($imageFullPath), [System.IO.Path]::GetExtension($imageFullPath)
            $immichXmpPath = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($imageFullPath), "$imageName$imageExt.xmp")
            $mylioModTime = (Get-Item -Path $mylioXmpPath).LastWriteTime
            
            if (Test-Path $immichXmpPath) {
                $immichModTime = (Get-Item -Path $immichXmpPath).LastWriteTime
                if ($mylioModTime -le $immichModTime) {
                    Write-Log -Message "Skipping $([System.IO.Path]::GetFileName($immichXmpPath)): Mylio XMP is not newer."
                    $processedImmichXmps[$immichXmpPath] = $true
                    $imagesProcessed++
                    $progressBar.Value = [Math]::Round(($imagesProcessed / $totalImages) * 100)
                    [System.Windows.Forms.Application]::DoEvents()
                    continue
                }
            }
            
            Write-Log -Message "Creating/updating for $([System.IO.Path]::GetFileName($imageFullPath))..."
            [System.Windows.Forms.Application]::DoEvents()
            try {
                $tempXmpPath = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($imageFullPath), ".temp_$([System.IO.Path]::GetFileName($immichXmpPath))")
                Remove-MylioTags -MylioXmpPath $mylioXmpPath -TempImmichXmpPath $tempXmpPath
                Move-Item -Path $tempXmpPath -Destination $immichXmpPath -Force
                Write-Log -Message "Successfully created $($immichXmpPath)"
                $processedImmichXmps[$immichXmpPath] = $true
            }
            catch { Write-Log -Message "Failed to create Immich XMP for $($imageFullPath): $_" -Level Error }
        }
        $imagesProcessed++
        $progressBar.Value = [Math]::Round(($imagesProcessed / $totalImages) * 100)
        [System.Windows.Forms.Application]::DoEvents()
    }

    Write-Log -Message "Deleting orphaned XMP files..."
    [System.Windows.Forms.Application]::DoEvents()
    $orphanedXmps = $immichXmpFiles | Where-Object { -not $processedImmichXmps.ContainsKey($_) }
    foreach ($orphanedXmp in $orphanedXmps) {
        Write-Log -Message "Deleting orphaned Immich XMP file: $($orphanedXmp)"
        try { Remove-Item -Path $orphanedXmp -Force }
        catch { Write-Log -Message "Error deleting orphaned file $($orphanedXmp): $_" -Level Error }
    }

    Write-Log -Message "Immich XMP creation process completed."
    $progressBar.Value = 100
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Seconds 1
    Clear-StatusWindow
    Toggle-Buttons -Enable:$true
}

function Delete-ImmichXmpFiles {
    param (
        [string]$ExternalLibraryPath
    )
    Toggle-Buttons -Enable:$false
    Clear-StatusWindow
    Write-Log -Message "Starting process to delete Immich XMP files..."
    $progressBar.Value = 0
    [System.Windows.Forms.Application]::DoEvents()
    
    $immichXmpFiles = Get-ChildItem -Path $ExternalLibraryPath -Recurse -File -Filter "*.xmp" | Where-Object { 
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($_.BaseName)
        $fileExt = [System.IO.Path]::GetExtension($_.BaseName)
        $imageExtensions = @('.jpg', '.jpeg', '.tiff', '.tif', '.png', '.heic', '.dng', '.raf', '.cr2', '.nef', '.arw')
        $imageExtensions -contains $fileExt.ToLower()
    }
    
    if ($immichXmpFiles.Count -eq 0) {
        [System.Windows.MessageBox]::Show("No Immich XMP files found to delete.", "Deletion Complete", "OK", "Information")
        Write-Log -Message "No Immich XMP files found to delete."
        $progressBar.Value = 100
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Seconds 1
        Clear-StatusWindow
        Toggle-Buttons -Enable:$true
        return
    }

    $dialogResult = [System.Windows.Forms.MessageBox]::Show("This will permanently delete $($immichXmpFiles.Count) Immich XMP files. Do you want to continue?", "Confirm Deletion", "YesNo", "Warning")
    if ($dialogResult -ne "Yes") {
        Write-Log -Message "Deletion cancelled by user."
        $progressBar.Value = 0
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Seconds 1
        Clear-StatusWindow
        Toggle-Buttons -Enable:$true
        return
    }
    
    $totalFiles = $immichXmpFiles.Count
    $deletedCount = 0

    foreach ($file in $immichXmpFiles) {
        Write-Log -Message "Deleting file: $($file.Name)..."
        [System.Windows.Forms.Application]::DoEvents()
        try {
            Remove-Item -Path $file.FullName -Force
            $deletedCount++
            $progressBar.Value = [Math]::Round(($deletedCount / $totalFiles) * 100)
            [System.Windows.Forms.Application]::DoEvents()
            Write-Log -Message "Successfully deleted $($file.FullName)"
        }
        catch { 
            Write-Log -Message "Error deleting file $($file.FullName): $_" -Level Error 
        }
    }

    Write-Log -Message "Immich XMP deletion process completed. $deletedCount files deleted."
    $progressBar.Value = 100
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Seconds 1
    Clear-StatusWindow
    Toggle-Buttons -Enable:$true
}

# ─────────────────────────────────────────────────────────────
# 4. Rescan Immich Functions
# ─────────────────────────────────────────────────────────────

function Get-ExternalLibraries {
    param ($IP, $Port, $ApiKey)
    $uri = "http://$IP`:$Port/api/external-libraries"
    try {
        Write-Log -Message "Retrieving external libraries from server..."
        $progressBar.Value = 50
        [System.Windows.Forms.Application]::DoEvents()
        $headers = @{ "x-api-key" = $ApiKey }
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
        Write-Log -Message "Successfully retrieved external libraries."
        $progressBar.Value = 100
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Seconds 1
        return $response
    }
    catch {
        Write-Log -Message "Failed to retrieve external libraries." -Level Error
        if ($_.Exception.Response) {
            $errorBody = $_.Exception.Response.GetResponseStream() | Out-String
            Write-Log -Message "Server returned error: $errorBody" -Level Error
        }
        $progressBar.Value = 0
        [System.Windows.Forms.Application]::DoEvents()
        Write-Error "Failed to retrieve external libraries: $_"
        return $null
    }
}

function Trigger-Rescan {
    param ($IP, $Port, $ApiKey, $LibraryId)
    Toggle-Buttons -Enable:$false
    Clear-StatusWindow
    Write-Log -Message "Triggering rescan for library ID: $LibraryId..."
    $progressBar.Value = 50
    [System.Windows.Forms.Application]::DoEvents()
    $uri = "http://$IP`:$Port/api/external-libraries/$LibraryId/scan"
    try {
        $headers = @{ "x-api-key" = $ApiKey }
        Invoke-RestMethod -Uri $uri -Headers $headers -Method Post
        Write-Log -Message "Rescan command sent."
        $progressBar.Value = 100
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Seconds 1
    }
    catch {
        Write-Log -Message "Failed to trigger rescan." -Level Error
        if ($_.Exception.Response) {
            $errorBody = $_.Exception.Response.GetResponseStream() | Out-String
            Write-Log -Message "Server returned error: $errorBody" -Level Error
        }
        $progressBar.Value = 0
        [System.Windows.Forms.Application]::DoEvents()
        Write-Error "Failed to trigger rescan: $_"
    }
    Clear-StatusWindow
    Toggle-Buttons -Enable:$true
}

function Clear-StatusWindow {
    $statusText.Text = ""
    $progressBar.Value = 0
}

function Toggle-Buttons {
    param(
        [Parameter(Mandatory=$true)]
        [switch]$Enable
    )
    $createImmichXMPsButton.IsEnabled = $Enable
    $deleteImmichXMPsButton.IsEnabled = $Enable
    $retryButton.IsEnabled = $Enable
    $saveApiKeyButton.IsEnabled = $Enable
    $discoverLibrariesButton.IsEnabled = $Enable
    $rescanButton.IsEnabled = $Enable
}

# Event handlers
$createImmichXMPsButton.Add_Click({
    Create-ImmichXmpFiles -ExternalLibraryPath $config.DEFAULT_PATHS.EXTERNAL_LIBRARY
})

$deleteImmichXMPsButton.Add_Click({
    Delete-ImmichXmpFiles -ExternalLibraryPath $config.DEFAULT_PATHS.EXTERNAL_LIBRARY
})

$retryButton.Add_Click({
    Check-ExifTool -CreateButton $createImmichXMPsButton
})

$saveApiKeyButton.Add_Click({
    Update-ImmichConfig -ConfigPath $configFilePath -NewIpAddress $config.IMMICH_SERVER.IP_ADDRESS -Port $config.IMMICH_SERVER.PORT -ApiKey $apiKeyTextBox.Text
    [System.Windows.MessageBox]::Show("API Key saved to Immich.cfg", "Success", "OK", "Information")
})

$discoverLibrariesButton.Add_Click({
    Toggle-Buttons -Enable:$false
    Clear-StatusWindow
    if ([string]::IsNullOrEmpty($apiKeyTextBox.Text)) {
        [System.Windows.MessageBox]::Show("API Key cannot be empty.", "Error", "OK", "Error")
        Toggle-Buttons -Enable:$true
        return
    }
    try {
        $libraries = Get-ExternalLibraries -IP $serverIpText.Text -Port $portText.Text -ApiKey $apiKeyTextBox.Text
        $libraryComboBox.Items.Clear()
        if ($libraries) {
            foreach ($lib in $libraries) {
                $libraryComboBox.Items.Add("$($lib.id): $($lib.name)")
            }
            $rescanButton.IsEnabled = $true
            [System.Windows.MessageBox]::Show("Libraries discovered successfully.", "Success", "OK", "Information")
        } else {
            $rescanButton.IsEnabled = $false
            [System.Windows.MessageBox]::Show("Failed to discover libraries. Please check your IP, Port, and API Key.", "Error", "OK", "Error")
        }
    }
    finally {
        Toggle-Buttons -Enable:$true
    }
})

$rescanButton.Add_Click({
    if ([string]::IsNullOrEmpty($apiKeyTextBox.Text)) {
        [System.Windows.MessageBox]::Show("API Key cannot be empty.", "Error", "OK", "Error")
        return
    }
    if ($libraryComboBox.SelectedItem) {
        $libraryId = ($libraryComboBox.SelectedItem.Split(':'))[0].Trim()
        Trigger-Rescan -IP $serverIpText.Text -Port $portText.Text -ApiKey $apiKeyTextBox.Text -LibraryId $libraryId
    } else {
        [System.Windows.MessageBox]::Show("Please select a library to rescan.", "No Library Selected", "OK", "Warning")
    }
})

# Initial checks and GUI population
$serverIpText.Text = $config.IMMICH_SERVER.IP_ADDRESS
$portText.Text = $config.IMMICH_SERVER.PORT
$apiKeyTextBox.Text = $config.IMMICH_SERVER.API_KEY
Check-ExifTool -CreateButton $createImmichXMPsButton

$window.ShowDialog()