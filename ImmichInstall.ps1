# Check if Docker is running
function Check-Docker {
    while ($true) {
        try {
            docker info | Out-Null
            Write-Host "Docker Desktop is running. Proceeding with the configuration."
            return $true
        } catch {
            $result = [System.Windows.MessageBox]::Show("Error: Docker Desktop is not running. Please start it now and click 'Retry'.", "Docker Not Running", "RetryCancel", "Error")
            if ($result -ne [System.Windows.MessageBoxResult]::Retry) {
                Write-Host "Exiting. Please start Docker Desktop and run the script again."
                return $false
            }
        }
    }
}

if (-not (Check-Docker)) {
    Read-Host "Press Enter to exit..."
    exit
}

# Define the path to the configuration file
$configFile = Join-Path -Path $PSScriptRoot -ChildPath "Immich.cfg"
$configBackupFile = Join-Path -Path $PSScriptRoot -ChildPath "Immich.cfg.bak"

# Define the path to the XAML GUI file
$xamlFile = Join-Path -Path $PSScriptRoot -ChildPath "ImmichInstall.xaml"

# Check if the configuration file exists
if (-not (Test-Path $configFile)) {
    Write-Host "Immich.cfg not found in the same directory. Please make sure it's there."
    Read-Host "Press Enter to exit..."
    exit
}

# Load the required assemblies for WPF and the folder browser
try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms
}
catch {
    Write-Host "Error: Could not load required .NET assemblies. This script requires PowerShell 5.1 or later with WPF support."
    Write-Host "Please ensure you are running a compatible version of PowerShell."
    Read-Host "Press Enter to exit..."
    exit
}

# Read the XAML file
[xml]$xaml = Get-Content $xamlFile -Raw

# Create a reader for the XAML
$reader = New-Object System.Xml.XmlNodeReader($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

# --- FUNCTIONS ---
function Get-LocalIPAddress {
    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" -and $_.PrefixLength -ne 0}).IPAddress
    return $ip
}

function Load-Config {
    try {
        $jsonContent = Get-Content -Path $configFile | Out-String
        $config = $jsonContent | ConvertFrom-Json
        return $config
    }
    catch {
        $window.FindName("StatusTextBox").AppendText("Error parsing Immich.cfg file. Please check for syntax errors.`n")
        $window.FindName("StatusTextBox").AppendText("Details: $_.Exception.Message`n")
        return $null
    }
}

function Save-Config($config) {
    try {
        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configFile
        Update-Status "Configuration saved successfully!"
        return $true
    }
    catch {
        Update-Status "Error saving configuration to Immich.cfg.`nDetails: $_.Exception.Message"
        return $false
    }
}

function Populate-GUI($config) {
    if ($config) {
        $window.FindName("IMMICH_ROOT_TextBox").Text = $config.DEFAULT_PATHS.IMMICH_ROOT
        $window.FindName("EXTERNAL_LIBRARY_TextBox").Text = $config.DEFAULT_PATHS.EXTERNAL_LIBRARY
        if ([string]::IsNullOrWhiteSpace($config.DEFAULT_PATHS.EXTERNAL_LIBRARY)) {
            $picturesPath = [System.Environment]::GetFolderPath('MyPictures')
            $window.FindName("EXTERNAL_LIBRARY_TextBox").Text = $picturesPath
        }

        $window.FindName("IP_ADDRESS_TextBox").Text = $config.IMMICH_SERVER.IP_ADDRESS
        if ($config.IMMICH_SERVER.IP_ADDRESS -eq "0.0.0.0") {
            $window.FindName("IP_ADDRESS_TextBox").Text = Get-LocalIPAddress
        }
        $window.FindName("PORT_TextBox").Text = $config.IMMICH_SERVER.PORT
        $window.FindName("API_KEY_TextBox").Text = $config.IMMICH_SERVER.API_KEY
        $window.FindName("DATABASE_PASSWORD_TextBox").Text = $config.IMMICH_SERVER.DATABASE_PASSWORD

        $window.FindName("DRY_RUN_CheckBox").IsChecked = $config.GENERAL_SETTINGS.DRY_RUN
        $window.FindName("BACKUP_NUMBER_TextBox").Text = $config.GENERAL_SETTINGS.BACKUP_NUMBER
        $window.FindName("LOG_NUMBER_TextBox").Text = $config.GENERAL_SETTINGS.LOG_NUMBER
        $window.FindName("LAST_SYNC_TextBox").Text = $config.GENERAL_SETTINGS.LAST_SYNC
    }
}

function Update-GUIPaths($rootPath) {
    $window.FindName("UPLOAD_LOCATION_TextBlock").Text = Join-Path -Path $rootPath -ChildPath "library"
    $window.FindName("DB_DATA_LOCATION_TextBlock").Text = Join-Path -Path $rootPath -ChildPath "postgres"
    $window.FindName("IMMICH_BACKUP_TextBlock").Text = Join-Path -Path $rootPath -ChildPath "Backup"
    $window.FindName("TOOLKIT_LOCATION_TextBlock").Text = Join-Path -Path $rootPath -ChildPath "ImmichToolkit"
}

function Update-Config($config) {
    if (-not ([int]::TryParse($window.FindName("PORT_TextBox").Text, [ref]$null))) {
        [System.Windows.MessageBox]::Show("PORT must be a valid number.", "Input Error", "OK", "Error")
        return $null
    }
    if (-not ([int]::TryParse($window.FindName("BACKUP_NUMBER_TextBox").Text, [ref]$null))) {
        [System.Windows.MessageBox]::Show("BACKUP_NUMBER must be a valid number.", "Input Error", "OK", "Error")
        return $null
    }
    if (-not ([int]::TryParse($window.FindName("LOG_NUMBER_TextBox").Text, [ref]$null))) {
        [System.Windows.MessageBox]::Show("LOG_NUMBER must be a valid number.", "Input Error", "OK", "Error")
        return $null
    }

    $config.DEFAULT_PATHS.IMMICH_ROOT = $window.FindName("IMMICH_ROOT_TextBox").Text
    $config.DEFAULT_PATHS.EXTERNAL_LIBRARY = $window.FindName("EXTERNAL_LIBRARY_TextBox").Text
    $config.DEFAULT_PATHS.MYLIO_INBOX = $window.FindName("MYLIO_INBOX_TextBox").Text

    $config.IMMICH_SERVER.IP_ADDRESS = $window.FindName("IP_ADDRESS_TextBox").Text
    $config.IMMICH_SERVER.PORT = [int]$window.FindName("PORT_TextBox").Text
    $config.IMMICH_SERVER.API_KEY = $window.FindName("API_KEY_TextBox").Text
    $config.IMMICH_SERVER.DATABASE_PASSWORD = $window.FindName("DATABASE_PASSWORD_TextBox").Text

    $config.GENERAL_SETTINGS.DRY_RUN = $window.FindName("DRY_RUN_CheckBox").IsChecked
    $config.GENERAL_SETTINGS.BACKUP_NUMBER = [int]$window.FindName("BACKUP_NUMBER_TextBox").Text
    $config.GENERAL_SETTINGS.LOG_NUMBER = [int]$window.FindName("LOG_NUMBER_TextBox").Text

    return $config
}

function Update-Status($message) {
    $window.FindName("StatusTextBox").AppendText("$message`n")
    $window.FindName("StatusTextBox").ScrollToEnd()
    Start-Sleep -Milliseconds 100
}

function Reset-Progress {
    $window.FindName("ProgressBar").Value = 0
    $window.FindName("StatusTextBox").Clear()
}

# --- MAIN EXECUTION ---
$config = Load-Config
if ($null -eq $config) {
    Read-Host "Press Enter to exit..."
    exit
}

Populate-GUI -config $config
Update-GUIPaths -rootPath $config.DEFAULT_PATHS.IMMICH_ROOT

# Handle events
$window.FindName("IMMICH_ROOT_TextBox").Add_TextChanged({
    Update-GUIPaths -rootPath $window.FindName("IMMICH_ROOT_TextBox").Text
})

$window.FindName("IMMICH_ROOT_Button").Add_Click({
    $folderBrowser = New-Object -TypeName System.Windows.Forms.FolderBrowserDialog
    $folderBrowser.RootFolder = "MyComputer"
    $folderBrowser.SelectedPath = $window.FindName("IMMICH_ROOT_TextBox").Text
    
    if ($folderBrowser.ShowDialog() -eq "OK") {
        $window.FindName("IMMICH_ROOT_TextBox").Text = $folderBrowser.SelectedPath
    }
})

$window.FindName("EXTERNAL_LIBRARY_Button").Add_Click({
    $folderBrowser = New-Object -TypeName System.Windows.Forms.FolderBrowserDialog
    $folderBrowser.RootFolder = "MyComputer"
    $folderBrowser.SelectedPath = $window.FindName("EXTERNAL_LIBRARY_TextBox").Text
    
    if ($folderBrowser.ShowDialog() -eq "OK") {
        $window.FindName("EXTERNAL_LIBRARY_TextBox").Text = $folderBrowser.SelectedPath
    }
})

$window.FindName("AddLibraryButton").Add_Click({
    $libraryFile = Join-Path -Path $PSScriptRoot -ChildPath "ExternalLibrary.txt"
    if (-not (Test-Path $libraryFile)) {
        New-Item -Path $libraryFile -ItemType File -Force | Out-Null
    }
    Start-Process -FilePath $libraryFile
})

$window.FindName("OpenFolderButton").Add_Click({
    $immichRootPath = $window.FindName("IMMICH_ROOT_TextBox").Text
    if (Test-Path $immichRootPath) {
        Invoke-Item -Path $immichRootPath
        Update-Status "Opened folder: $immichRootPath"
    } else {
        Update-Status "Error: Immich folder not found at '$immichRootPath'."
    }
})

$window.FindName("InstallButton").Add_Click({
    $window.FindName("InstallButton").IsEnabled = $false
    $window.FindName("OpenFolderButton").IsEnabled = $false
    Reset-Progress
    
    Update-Status "Saving configuration and proceeding with installation..."
    $updatedConfig = Update-Config -config $config
    if ($null -ne $updatedConfig) {
        Copy-Item -Path $configFile -Destination $configBackupFile -Force
        
        if (Save-Config -config $updatedConfig) {
            $window.FindName("ProgressBar").Value = 10
            
            Update-Status "Creating sub-directories..."
            $basePath = $window.FindName("IMMICH_ROOT_TextBox").Text
            New-Item -ItemType Directory -Force -Path (Join-Path -Path $basePath -ChildPath "library")
            $window.FindName("ProgressBar").Value = 15
            New-Item -ItemType Directory -Force -Path (Join-Path -Path $basePath -ChildPath "postgres")
            $window.FindName("ProgressBar").Value = 20
            New-Item -ItemType Directory -Force -Path (Join-Path -Path $basePath -ChildPath "Backup")
            $window.FindName("ProgressBar").Value = 25
            New-Item -ItemType Directory -Force -Path (Join-Path -Path $basePath -ChildPath "ImmichToolkit")
            Update-Status "Sub-directories created successfully."
            
            $window.FindName("ProgressBar").Value = 30
            
            Update-Status "Downloading Immich files..."
            $downloadPath = $basePath
            try {
                Invoke-WebRequest -Uri "https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml" -OutFile (Join-Path -Path $downloadPath -ChildPath "docker-compose.yml")
                $window.FindName("ProgressBar").Value = 40
                Invoke-WebRequest -Uri "https://github.com/immich-app/immich/releases/latest/download/example.env" -OutFile (Join-Path -Path $downloadPath -ChildPath "example.env")
                $window.FindName("ProgressBar").Value = 50
                
                Rename-Item -Path (Join-Path -Path $downloadPath -ChildName "example.env") -NewName ".env" -Force
                $window.FindName("ProgressBar").Value = 60
                
                Update-Status "Immich installation files have been downloaded."
            }
            catch {
                Update-Status "Error: Failed to download one or more Immich files. Please check your internet connection and try again.`nDetails: $_.Exception.Message"
                Read-Host "Press Enter to exit..."
                exit
            }
            
            $window.FindName("ProgressBar").Value = 70
            
            Update-Status "Adding external library to docker-compose.yml..."
            $composeFile = Join-Path -Path $downloadPath -ChildPath "docker-compose.yml"
            $composeContent = Get-Content -Path $composeFile -Raw
            $externalLibraryPath = $updatedConfig.DEFAULT_PATHS.EXTERNAL_LIBRARY
            
            if (-not [string]::IsNullOrWhiteSpace($externalLibraryPath)) {
                $dockerFormattedPath = $externalLibraryPath.Replace("\", "/")
                $newLine = "      - `"$dockerFormattedPath`":/external:ro"
                
                $searchPattern = '      - \$\{UPLOAD_LOCATION\}:/usr/src/app/upload'
                $contentWithNewPath = $composeContent -replace $searchPattern, "`$0`r`n$newLine"
                
                $contentWithNewPath | Set-Content -Path $composeFile
                Update-Status "External library path added successfully to docker-compose.yml."
            }
            else {
                Update-Status "No external library path specified in the configuration. Skipping this step."
            }

            $window.FindName("ProgressBar").Value = 80
            
            Update-Status "Copying all files to ImmichToolkit directory..."
            $toolkitPath = $updatedConfig.DEFAULT_PATHS.TOOLKIT_LOCATION
            try {
                Copy-Item -Path "$PSScriptRoot\*" -Destination "$toolkitPath" -Recurse -Force
                Update-Status "All files have been successfully copied to the ImmichToolkit directory."
            }
            catch {
                Update-Status "Error: Failed to copy files to the ImmichToolkit directory.`nDetails: $_.Exception.Message"
                Read-Host "Press Enter to exit..."
                exit
            }

            $window.FindName("ProgressBar").Value = 90
            
            Update-Status "Starting Immich containers..."
            try {
                Set-Location -Path $toolkitPath
                docker compose up -d
                Update-Status "Immich has started successfully."
            }
            catch {
                Update-Status "Error: Failed to start Immich. Please ensure Docker is running and try again.`nDetails: $_.Exception.Message"
                Read-Host "Press Enter to exit..."
                exit
            }
            
            $window.FindName("ProgressBar").Value = 100
            $window.FindName("InstallButton").IsEnabled = $true
            $window.FindName("OpenFolderButton").IsEnabled = $true
            
            Update-Status "The entire Immich installation process is complete. The application should now be accessible."
            $IP_ADDRESS = $window.FindName("IP_ADDRESS_TextBox").Text
            $PORT = $window.FindName("PORT_TextBox").Text
            $message = "Installation is complete! Immich is running and should be accessible at http://$IP_ADDRESS:$PORT."
            [System.Windows.MessageBox]::Show($message, "Installation Complete", "OK", "Information")
        }
    }
})

$window.FindName("SaveButton").Add_Click({
    Update-Status "Saving configuration..."
    $updatedConfig = Update-Config -config $config
    if ($null -ne $updatedConfig) {
        if (Save-Config -config $updatedConfig) {
            $window.Close()
        }
    }
})

$window.FindName("CloseButton").Add_Click({
    Update-Status "Closing without saving."
    $window.Close()
})

$window.FindName("CancelButton").Add_Click({
    $window.FindName("InstallButton").IsEnabled = $false
    $window.FindName("OpenFolderButton").IsEnabled = $false
    Update-Status "Cancelling installation and rolling back changes..."
    Reset-Progress
    
    $immichRootPath = $window.FindName("IMMICH_ROOT_TextBox").Text
    $toolkitPath = Join-Path -Path $immichRootPath -ChildPath "ImmichToolkit"

    Update-Status "Stopping Immich containers..."
    try {
        if (Test-Path $toolkitPath) {
            Set-Location -Path $toolkitPath
            docker compose down
            Update-Status "Immich containers have been stopped and removed."
        }
    }
    catch {
        Update-Status "Error: Failed to stop Immich containers. The installation directory or Docker may be in an invalid state.`nDetails: $_.Exception.Message"
    }

    Update-Status "Deleting installed files and directories..."
    try {
        if (Test-Path $immichRootPath) {
            Remove-Item -Path $immichRootPath -Recurse -Force
            Update-Status "Installation directory and files have been removed."
        }
        
        if (Test-Path $configBackupFile) {
            Copy-Item -Path $configBackupFile -Destination $configFile -Force
            Remove-Item -Path $configBackupFile
            Update-Status "Configuration file restored to original state."
        }
    }
    catch {
        Update-Status "Error: Failed to delete installation files. You may need to remove them manually.`nDetails: $_.Exception.Message"
    }

    $window.FindName("InstallButton").IsEnabled = $true
    Update-Status "Rollback complete. The installation has been cancelled."
    
    $window.Close()
})

# Show the window
$window.ShowDialog() | Out-Null