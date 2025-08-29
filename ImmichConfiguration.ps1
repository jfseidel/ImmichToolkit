# Requires the Windows Presentation Foundation (WPF) and Windows Forms assemblies for GUI support.
Add-Type -AssemblyName PresentationFramework, System.Windows.Forms, PresentationCore, System.Xaml

# --- File Paths and Variables ---

# Get the directory where the script is located. This assumes all three files are in the same folder, which is TOOLKIT_LOCATION.
$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Define the full path to the configuration file.
$ConfigFile = Join-Path -Path $ScriptPath -ChildPath "Immich.cfg"

# Define the full path to the backup file.
$BackupFile = Join-Path -Path $ScriptPath -ChildPath "Immich.cfg.bak"

# Store the initial configuration loaded from the file.
$initialConfig = $null

# --- Functions ---

function Load-Config {
    # Check if the configuration file exists.
    if (-not (Test-Path -Path $ConfigFile)) {
        Write-Error "Configuration file not found at $ConfigFile. Please ensure 'Immich.cfg' is in the same directory."
        return $null
    }

    try {
        # Read the JSON content from the file.
        $jsonContent = Get-Content -Path $ConfigFile -Raw -Encoding UTF8

        # Convert the JSON content to a PowerShell object.
        $config = ConvertFrom-Json -InputObject $jsonContent

        # Dynamically set the IP_ADDRESS field.
        $config.IMMICH_SERVER.IP_ADDRESS = (Test-Connection -ComputerName (hostname) -Count 1 | Select-Object -ExpandProperty Ipv4Address).IPAddressToString

        return $config
    }
    catch {
        Write-Error "Failed to load or process configuration file: $_"
        return $null
    }
}

function Move-ImmichFolders {
    param (
        [Parameter(Mandatory=$true)]
        [string]$oldPath,
        [Parameter(Mandatory=$true)]
        [string]$newPath
    )

    $subfoldersToCount = @("library", "postgres")
    $subfoldersToMove = @("library", "postgres", "Backup", "ImmichToolkit")
    $totalFiles = 0
    $movedFiles = 0
    $progressStep = 0

    # Step 1: Count total files to be moved for accurate progress.
    $StatusTextBlock.Text = "Calculating files to move..."
    foreach ($folder in $subfoldersToCount) {
        $folderPath = Join-Path -Path $oldPath -ChildPath $folder
        if (Test-Path -Path $folderPath) {
            $totalFiles += (Get-ChildItem -Path $folderPath -Recurse | Measure-Object).Count
        }
    }

    # Step 2: Perform the move operation with progress updates.
    try {
        # Create the new root directory if it doesn't exist.
        if (-not (Test-Path -Path $newPath)) {
            New-Item -Path $newPath -ItemType Directory | Out-Null
        }

        foreach ($folder in $subfoldersToMove) {
            $oldFolderPath = Join-Path -Path $oldPath -ChildPath $folder
            $newFolderPath = Join-Path -Path $newPath -ChildPath $folder

            if (Test-Path -Path $oldFolderPath) {
                $StatusTextBlock.Text = "Moving '$folder'..."
                
                if ($folder -in $subfoldersToCount) {
                    # Move items with progress for large folders.
                    Get-ChildItem -Path $oldFolderPath -Recurse | ForEach-Object {
                        $destinationPath = $_.FullName -replace [regex]::Escape($oldFolderPath), $newFolderPath
                        Move-Item -Path $_.FullName -Destination $destinationPath -Force
                        $movedFiles++
                        $progressStep = ($movedFiles / $totalFiles) * 100
                        $MainProgressBar.Value = [math]::Min(100, $progressStep)
                        [System.Windows.Forms.Application]::DoEvents()
                    }
                } else {
                    # Move smaller or non-data folders without granular progress.
                    Move-Item -Path "$oldFolderPath" -Destination "$newFolderPath" -Force -Recurse
                    $progressStep += (100 / $subfoldersToMove.Count)
                    $MainProgressBar.Value = [math]::Min(100, $progressStep)
                    [System.Windows.Forms.Application]::DoEvents()
                }
            }
        }

        $StatusTextBlock.Text = "File relocation complete."
        $MainProgressBar.Value = 100
        return $true
    }
    catch {
        $StatusTextBlock.Text = "Failed to move files."
        return $false
    }
}

function Save-Config {
    param (
        [Parameter(Mandatory=$true)]
        [psobject]$configObject
    )
    $saveButton.IsEnabled = $false
    $undoButton.IsEnabled = $false
    $browseImmichRootButton.IsEnabled = $false
    $browseExternalLibraryButton.IsEnabled = $false
    $StatusTextBlock.Text = "Saving configuration..."
    $MainProgressBar.Value = 0

    # Overwrite the old backup file.
    if (Test-Path -Path $ConfigFile) {
        try {
            Copy-Item -Path $ConfigFile -Destination $BackupFile -Force
            Write-Host "Backup of Immich.cfg created at $BackupFile."
        }
        catch {
            Write-Error "Failed to create backup file: $_"
        }
    }

    # Check if the IMMICH_ROOT path has changed and perform the move operation.
    $oldRootPath = $initialConfig.DEFAULT_PATHS.IMMICH_ROOT
    $newRootPath = $configObject.DEFAULT_PATHS.IMMICH_ROOT
    if ($oldRootPath -ne $newRootPath) {
        $dockerSuccess = $false
        # Prompt the user to stop Immich before the move.
        $moveConfirmation = [System.Windows.MessageBox]::Show(
            "WARNING: The Immich root path has changed. This script can now attempt to stop Immich automatically, but it requires administrator privileges and assumes you are using Docker Compose. Do you want to try and stop Immich automatically?`n`nClick 'Yes' to try, or 'No' to cancel the move.",
            "Confirm Immich Stop",
            "YesNo",
            "Warning"
        )
        
        if ($moveConfirmation -eq "Yes") {
            # Attempt to stop Immich services.
            $dockerComposePath = $oldRootPath
            if (Test-Path -Path (Join-Path -Path $dockerComposePath -ChildPath "docker-compose.yml")) {
                $StatusTextBlock.Text = "Stopping Immich services..."
                $originalLocation = Get-Location
                Set-Location -Path $dockerComposePath
                try {
                    docker-compose down
                    $dockerSuccess = $true
                }
                catch {
                    $StatusTextBlock.Text = "Failed to stop Immich."
                    [System.Windows.MessageBox]::Show("Failed to run 'docker-compose down'. Please ensure Docker is running and you have the necessary permissions. The move will be canceled.", "Error", "OK", "Error")
                    return
                }
                finally {
                    Set-Location -Path $originalLocation
                }
            } else {
                [System.Windows.MessageBox]::Show("docker-compose.yml not found at the old root path. Please stop Immich manually.", "Warning", "OK", "Warning")
                return
            }
        } else {
            [System.Windows.MessageBox]::Show("Operation canceled. Please stop Immich and try again.", "Canceled", "OK", "Information")
            return
        }
        
        # Perform the file move.
        if (Move-ImmichFolders -oldPath $oldRootPath -newPath $newRootPath) {
            # Update the configuration file with the new path.
            $rootPath = $configObject.DEFAULT_PATHS.IMMICH_ROOT
            $toolkitPath = Join-Path -Path $rootPath -ChildPath "ImmichToolkit"
            $configObject.DEFAULT_PATHS.UPLOAD_LOCATION = Join-Path -Path $rootPath -ChildPath "library"
            $configObject.DEFAULT_PATHS.DB_DATA_LOCATION = Join-Path -Path $rootPath -ChildPath "postgres"
            $configObject.DEFAULT_PATHS.IMMICH_BACKUP = Join-Path -Path $rootPath -ChildPath "Backup"
            $configObject.DEFAULT_PATHS.TOOLKIT_LOCATION = $toolkitPath
            $configObject.DEFAULT_FILES.IMMICH_JSON = Join-Path -Path $toolkitPath -ChildPath "Immich.cfg"
            $configObject.DEFAULT_FILES.IMMICH_LOG = Join-Path -Path $toolkitPath -ChildPath "Immich.log"

            try {
                $jsonContent = $configObject | ConvertTo-Json -Depth 5 -Compress:$false
                Set-Content -Path $ConfigFile -Value $jsonContent -Encoding UTF8
                $StatusTextBlock.Text = "Configuration saved successfully."
            }
            catch {
                $StatusTextBlock.Text = "Failed to save configuration."
            }

            if ($dockerSuccess) {
                # Automatically bring Immich back up after a successful move.
                $result = [System.Windows.MessageBox]::Show("File relocation complete. Do you want to start Immich now?", "Start Immich", "YesNo", "Question")
                if ($result -eq "Yes") {
                    $StatusTextBlock.Text = "Starting Immich services..."
                    try {
                        Set-Location -Path $newRootPath
                        docker-compose up -d
                        [System.Windows.MessageBox]::Show("Immich services started successfully!", "Success", "OK", "Information")
                    }
                    catch {
                        [System.Windows.MessageBox]::Show("Failed to start Immich. Please start it manually.", "Error", "OK", "Error")
                    }
                    finally {
                        Set-Location -Path $originalLocation
                    }
                }
            }
        } else {
            $StatusTextBlock.Text = "Failed to relocate Immich folders."
            [System.Windows.MessageBox]::Show("Failed to relocate Immich folders. Configuration was not changed.", "Error", "OK", "Error")
        }
    } else {
        # If the path has not changed, just save the config.
        $rootPath = $configObject.DEFAULT_PATHS.IMMICH_ROOT
        $toolkitPath = Join-Path -Path $rootPath -ChildPath "ImmichToolkit"
        $configObject.DEFAULT_PATHS.UPLOAD_LOCATION = Join-Path -Path $rootPath -ChildPath "library"
        $configObject.DEFAULT_PATHS.DB_DATA_LOCATION = Join-Path -Path $rootPath -ChildPath "postgres"
        $configObject.DEFAULT_PATHS.IMMICH_BACKUP = Join-Path -Path $rootPath -ChildPath "Backup"
        $configObject.DEFAULT_PATHS.TOOLKIT_LOCATION = $toolkitPath
        $configObject.DEFAULT_FILES.IMMICH_JSON = Join-Path -Path $toolkitPath -ChildPath "Immich.cfg"
        $configObject.DEFAULT_FILES.IMMICH_LOG = Join-Path -Path $toolkitPath -ChildPath "Immich.log"
        try {
            $jsonContent = $configObject | ConvertTo-Json -Depth 5 -Compress:$false
            Set-Content -Path $ConfigFile -Value $jsonContent -Encoding UTF8
            $StatusTextBlock.Text = "Configuration saved successfully."
        }
        catch {
            $StatusTextBlock.Text = "Failed to save configuration."
        }
    }
    
    $MainProgressBar.Value = 100
    $saveButton.IsEnabled = $true
    $undoButton.IsEnabled = $true
    $browseImmichRootButton.IsEnabled = $true
    $browseExternalLibraryButton.IsEnabled = $true
    $StatusTextBlock.Text = "Ready"
}

# --- GUI Logic ---

# Define the full path to the XAML file.
$XamlFile = Join-Path -Path $ScriptPath -ChildPath "ImmichConfiguration.xaml"
if (-not (Test-Path -Path $XamlFile)) {
    Write-Error "XAML file not found at $XamlFile. Please ensure 'ImmichConfiguration.xaml' is in the same directory."
    exit
}

# Create a splash screen window.
$splashWindow = [System.Windows.Window]@{
    Title = "Loading..."
    Width = 250
    Height = 100
    WindowStyle = 'None'
    AllowsTransparency = $true
    Background = [System.Windows.Media.Brushes]::Transparent
    WindowStartupLocation = 'CenterScreen'
}
$splashContent = [System.Windows.Controls.StackPanel]@{
    HorizontalAlignment = 'Center'
    VerticalAlignment = 'Center'
}
$splashText = [System.Windows.Controls.TextBlock]@{
    Text = "Loading GUI..."
    FontSize = 16
    FontWeight = 'Bold'
    Foreground = [System.Windows.Media.Brushes]::Black
    Margin = '5'
}
$splashProgressBar = [System.Windows.Controls.ProgressBar]@{
    IsIndeterminate = $true
    Width = 200
    Height = 20
    Margin = '5'
}

$splashContent.Children.Add($splashText)
$splashContent.Children.Add($splashProgressBar)
$splashWindow.Content = $splashContent
$splashWindow.Show()

try {
    # Read the XAML content from the file.
    [xml]$xaml = Get-Content -Path $XamlFile -Raw
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    # Find the GUI controls by their names.
    $immichRootTextBox = $window.FindName("ImmichRootTextBox")
    $uploadLocationTextBox = $window.FindName("UploadLocationTextBox")
    $dbDataLocationTextBox = $window.FindName("DbDataLocationTextBox")
    $immichBackupTextBox = $window.FindName("ImmichBackupTextBox")
    $toolkitLocationTextBox = $window.FindName("ToolkitLocationTextBox")
    $externalLibraryTextBox = $window.FindName("ExternalLibraryTextBox")
    $mylioInboxTextBox = $window.FindName("MylioInboxTextBox")
    $immichJsonTextBox = $window.FindName("ImmichJsonTextBox")
    $immichLogTextBox = $window.FindName("ImmichLogTextBox")
    $ipAddressTextBox = $window.FindName("IpAddressTextBox")
    $portTextBox = $window.FindName("PortTextBox")
    $apiKeyTextBox = $window.FindName("ApiKeyTextBox")
    $databasePasswordTextBox = $window.FindName("DatabasePasswordTextBox")
    $saveButton = $window.FindName("SaveButton")
    $undoButton = $window.FindName("UndoButton")
    $browseImmichRootButton = $window.FindName("BrowseImmichRootButton")
    $browseExternalLibraryButton = $window.FindName("BrowseExternalLibraryButton")
    $StatusTextBlock = $window.FindName("StatusTextBlock")
    $MainProgressBar = $window.FindName("MainProgressBar")


} catch {
    Write-Error "Failed to load the XAML GUI: $_"
    exit
}

# --- Event Handlers ---

# Function to update the dependent paths and files based on the IMMICH_ROOT.
function Update-DependentPaths {
    param (
        [string]$immichRoot
    )
    if ($immichRoot -ne "") {
        $toolkitPath = Join-Path -Path $immichRoot -ChildPath "ImmichToolkit"
        $uploadLocationTextBox.Text = Join-Path -Path $immichRoot -ChildPath "library"
        $dbDataLocationTextBox.Text = Join-Path -Path $immichRoot -ChildPath "postgres"
        $immichBackupTextBox.Text = Join-Path -Path $immichRoot -ChildPath "Backup"
        $toolkitLocationTextBox.Text = $toolkitPath
        $immichJsonTextBox.Text = Join-Path -Path $toolkitPath -ChildPath "Immich.cfg"
        $immichLogTextBox.Text = Join-Path -Path $toolkitPath -ChildPath "Immich.log"
    } else {
        $uploadLocationTextBox.Text = ""
        $dbDataLocationTextBox.Text = ""
        $immichBackupTextBox.Text = ""
        $toolkitLocationTextBox.Text = ""
        $immichJsonTextBox.Text = ""
        $immichLogTextBox.Text = ""
    }
}

# Event handler for the IMMICH_ROOT text box.
$immichRootTextBox.Add_TextChanged({
    Update-DependentPaths -immichRoot $immichRootTextBox.Text
})

# Event handler for the Save button.
$saveButton.Add_Click({
    # Load the current configuration from the GUI.
    $immichConfig = [pscustomobject]@{
        DEFAULT_PATHS = @{
            IMMICH_ROOT = $immichRootTextBox.Text
            EXTERNAL_LIBRARY = $externalLibraryTextBox.Text
            MYLIO_INBOX = $mylioInboxTextBox.Text
        }
        IMMICH_SERVER = @{
            IP_ADDRESS = $ipAddressTextBox.Text
            PORT = $portTextBox.Text
            API_KEY = $apiKeyTextBox.Text
            DATABASE_PASSWORD = $databasePasswordTextBox.Text
        }
        DEFAULT_FILES = @{
            IMMICH_JSON = $null
            IMMICH_LOG = $null
        }
    }

    # Save the updated configuration to the file.
    Save-Config -configObject $immichConfig
})

# Event handler for the Undo button.
$undoButton.Add_Click({
    $saveButton.IsEnabled = $false
    $undoButton.IsEnabled = $false
    $browseImmichRootButton.IsEnabled = $false
    $browseExternalLibraryButton.IsEnabled = $false
    
    $StatusTextBlock.Text = "Restoring from backup..."
    $MainProgressBar.Value = 0
    
    # Check if a backup file exists.
    if (Test-Path -Path $BackupFile) {
        try {
            # Copy the backup file to the original config file.
            Copy-Item -Path $BackupFile -Destination $ConfigFile -Force
            $MainProgressBar.Value = 50

            # Reload the GUI to show the restored settings.
            $immichConfig = Load-Config
            if ($immichConfig) {
                $immichRootTextBox.Text = $immichConfig.DEFAULT_PATHS.IMMICH_ROOT
                $externalLibraryTextBox.Text = $immichConfig.DEFAULT_PATHS.EXTERNAL_LIBRARY
                $mylioInboxTextBox.Text = $immichConfig.DEFAULT_PATHS.MYLIO_INBOX
                $ipAddressTextBox.Text = $immichConfig.IMMICH_SERVER.IP_ADDRESS
                $portTextBox.Text = $immichConfig.IMMICH_SERVER.PORT
                $apiKeyTextBox.Text = $immichConfig.IMMICH_SERVER.API_KEY
                $databasePasswordTextBox.Text = $immichConfig.IMMICH_SERVER.DATABASE_PASSWORD
                Update-DependentPaths -immichRoot $immichConfig.DEFAULT_PATHS.IMMICH_ROOT
            }
            $MainProgressBar.Value = 100
            [System.Windows.MessageBox]::Show("Configuration has been restored from backup.", "Restored", "OK", "Information")
        }
        catch {
            Write-Error "Failed to restore configuration from backup: $_"
            $StatusTextBlock.Text = "Failed to restore backup."
        }
    } else {
        [System.Windows.MessageBox]::Show("No backup file found to restore from.", "Error", "OK", "Error")
        $StatusTextBlock.Text = "No backup found."
    }
    
    $saveButton.IsEnabled = $true
    $undoButton.IsEnabled = $true
    $browseImmichRootButton.IsEnabled = $true
    $browseExternalLibraryButton.IsEnabled = $true
    $MainProgressBar.Value = 0
    $StatusTextBlock.Text = "Ready"
})

# Event handler for the Browse Immich Root button.
$browseImmichRootButton.Add_Click({
    $oldPath = $immichRootTextBox.Text
    $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderBrowser.Description = "Select a new location for Immich"
    $folderBrowser.ShowNewFolderButton = $true

    if ($folderBrowser.ShowDialog() -eq "OK") {
        $newPath = $folderBrowser.SelectedPath
        
        # Display the warning message.
        $result = [System.Windows.MessageBox]::Show(
            "Warning: Changing the 'Immich location' will change the location for all associated subfolders and files (including your images). Do you want to proceed with the relocation and copy all the contents to the new folder? This will happen when you click 'Save Configuration'.",
            "Relocation Warning",
            "YesNo",
            "Warning"
        )

        if ($result -eq "Yes") {
            # Update the text box. The actual file move operation will happen later.
            $immichRootTextBox.Text = $newPath
        }
    }
})

# Event handler for the Browse External Library button.
$browseExternalLibraryButton.Add_Click({
    $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderBrowser.Description = "Select a location for the External Library"
    $folderBrowser.ShowNewFolderButton = $true

    if ($folderBrowser.ShowDialog() -eq "OK") {
        $externalLibraryTextBox.Text = $folderBrowser.SelectedPath
    }
})

# --- Main Logic ---

# Load the initial configuration and populate the GUI fields.
$initialConfig = Load-Config
if ($initialConfig) {
    # Populate the text boxes with values from the loaded config.
    $immichRootTextBox.Text = $initialConfig.DEFAULT_PATHS.IMMICH_ROOT
    $externalLibraryTextBox.Text = $initialConfig.DEFAULT_PATHS.EXTERNAL_LIBRARY
    $mylioInboxTextBox.Text = $initialConfig.DEFAULT_PATHS.MYLIO_INBOX
    
    $ipAddressTextBox.Text = $initialConfig.IMMICH_SERVER.IP_ADDRESS
    $portTextBox.Text = $initialConfig.IMMICH_SERVER.PORT
    $apiKeyTextBox.Text = $initialConfig.IMMICH_SERVER.API_KEY
    $databasePasswordTextBox.Text = $initialConfig.IMMICH_SERVER.DATABASE_PASSWORD

    # Call the update function once to set the initial dependent paths and files.
    Update-DependentPaths -immichRoot $initialConfig.DEFAULT_PATHS.IMMICH_ROOT
}

$splashWindow.Close()
# Show the GUI window.
$window.ShowDialog()