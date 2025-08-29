

param (
    [switch]$RunBackup
)

# Set the location of the script to the current directory (TOOLKIT_LOCATION)
$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Define the file names
$ConfigFile = "Immich.cfg"
$GuiFile = "ImmichMaintenance.xaml"

# Build the full paths
$ConfigPath = Join-Path -Path $ScriptDirectory -ChildPath $ConfigFile
$GuiPath = Join-Path -Path $ScriptDirectory -ChildPath $GuiFile

# Test for Docker Connection at script start
function Test-DockerConnection {
    try {
        # Check if docker is running and accessible
        docker info | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Docker is not running or not accessible. Please start Docker and try again."
        }
        return $true
    } catch {
        [System.Windows.MessageBox]::Show("Error: $_", "Docker Error", "OK", "Error") | Out-Null
        return $false
    }
}

if (-not (Test-DockerConnection)) {
    exit
}

# Helper function to create a new temporary directory
function New-TempDirectory {
    param (
        [string]$Name
    )
    $tempDir = Join-Path (Get-Item -Path $env:TEMP).FullName $Name
    if (Test-Path -Path $tempDir) {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    return $tempDir
}

# Helper function to add new status text and scroll to the end
function Add-StatusText {
    param (
        [Parameter(Mandatory=$true)]
        [PSObject]$StatusTextControl,
        [Parameter(Mandatory=$true)]
        [string]$Message
    )
    $StatusTextControl.Text += "`n$Message"
    $StatusTextControl.ScrollToEnd()
}

# Helper function to clear status and progress bar
function Clear-Status {
    param (
        [Parameter(Mandatory=$true)]
        [PSObject]$StatusTextControl,
        [Parameter(Mandatory=$true)]
        [PSObject]$ProgressBarControl
    )
    $StatusTextControl.Text = "Ready."
    $ProgressBarControl.Value = 0
}

# Load the configuration from the Immich.cfg file
function Load-ImmichConfig {
    try {
        if (Test-Path -Path $ConfigPath) {
            $configContent = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
            return $configContent
        } else {
            Add-StatusText -StatusTextControl $StatusText -Message "Configuration file not found: $ConfigPath"
            return $null
        }
    } catch {
        Add-StatusText -StatusTextControl $StatusText -Message "Failed to load configuration file: $_"
        return $null
    }
}

# Save the configuration back to the Immich.cfg file
function Save-ImmichConfig {
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$ConfigObject
    )
    try {
        $ConfigObject | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigPath
    } catch {
        Add-StatusText -StatusTextControl $StatusText -Message "Failed to save configuration file: $_"
    }
}

# --- Core Maintenance Functions ---

function Backup-Database {
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Config,
        [Parameter(Mandatory=$true)]
        [int]$KeepLast,
        [Parameter(Mandatory=$true)]
        [PSObject]$StatusTextControl,
        [Parameter(Mandatory=$true)]
        [PSObject]$ProgressBarControl
    )
    
    $immichRoot = $Config.DEFAULT_PATHS.IMMICH_ROOT
    $backupPath = $Config.DEFAULT_PATHS.IMMICH_BACKUP
    $dbDataLocation = $Config.DEFAULT_PATHS.DB_DATA_LOCATION
    $databasePassword = $Config.IMMICH_SERVER.DATABASE_PASSWORD

    $PostgresContainer = "immich_postgres"
    $PostgresUser = "postgres"
    $Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $BackupDir = Join-Path $backupPath "immich-backup-$Timestamp"
    $DbBackupFile = Join-Path $BackupDir "dump.sql"
    $ZipFile = "$BackupDir.zip"

    try {
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Creating backup directory..."
        $ProgressBarControl.Value = 10
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
        
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Backing up PostgreSQL..."
        $ProgressBarControl.Value = 40
        $command = "pg_dumpall --clean --if-exists --username=$PostgresUser"
        & docker exec -e PGPASSWORD=$databasePassword -t $PostgresContainer bash -c $command | Out-File $DbBackupFile -ErrorAction Stop
        if ($LASTEXITCODE -ne 0) { throw "Docker command failed with exit code $LASTEXITCODE" }
        
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Database backed up to $DbBackupFile"
        $ProgressBarControl.Value = 60

        Add-StatusText -StatusTextControl $StatusTextControl -Message "Compressing backup..."
        $ProgressBarControl.Value = 80
        Compress-Archive -Path $BackupDir -DestinationPath $ZipFile -Force -ErrorAction Stop
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Compressed to $ZipFile. Removing temporary directory."
        Remove-Item -Recurse -Force $BackupDir
        
        if ($KeepLast -gt 0) {
            Add-StatusText -StatusTextControl $StatusTextControl -Message "Cleaning up old backups..."
            $backups = Get-ChildItem -Path $backupPath -Filter "immich-backup-*.zip" | Sort-Object LastWriteTime -Descending
            if ($backups.Count -gt $KeepLast) {
                $toDelete = $backups | Select-Object -Skip $KeepLast
                foreach ($file in $toDelete) {
                    try {
                        Remove-Item -Path $file.FullName -Force -ErrorAction Stop
                        Add-StatusText -StatusTextControl $StatusTextControl -Message "Deleted: $($file.Name)"
                    } catch {
                        Add-StatusText -StatusTextControl $StatusTextControl -Message "Failed to delete: $($file.Name)"
                    }
                }
            } else {
                Add-StatusText -StatusTextControl $StatusTextControl -Message "No old backups found."
            }
        }
        $ProgressBarControl.Value = 100
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Backup complete!"
    } catch {
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Backup failed: $_"
        return $false
    }
    return $true
}

function Restore-Database {
    param (
        [Parameter(Mandatory=$true)]
        [string]$BackupName,
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Config,
        [Parameter(Mandatory=$true)]
        [PSObject]$StatusTextControl,
        [Parameter(Mandatory=$true)]
        [PSObject]$ProgressBarControl
    )
    
    $backupPath = $Config.DEFAULT_PATHS.IMMICH_BACKUP
    $databasePassword = $Config.IMMICH_SERVER.DATABASE_PASSWORD
    $PostgresContainer = "immich_postgres"
    $PostgresUser = "postgres"
    
    $tempDir = New-TempDirectory -Name "ImmichRestoreTemp"
    
    $BackupZipFile = Join-Path $backupPath "$BackupName.zip"
    $RestoreFile = Join-Path $tempDir "$BackupName\dump.sql"

    try {
        if (-not (Test-Path -Path $BackupZipFile)) {
            Add-StatusText -StatusTextControl $StatusTextControl -Message "Error: The selected backup file was not found."
            return $false
        }
        
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Stopping Immich containers..."
        $ProgressBarControl.Value = 20
        & docker compose down -ErrorAction Stop
        if ($LASTEXITCODE -ne 0) { throw "Docker command failed with exit code $LASTEXITCODE" }

        Add-StatusText -StatusTextControl $StatusTextControl -Message "Extracting backup file..."
        $ProgressBarControl.Value = 30
        Expand-Archive -Path $BackupZipFile -DestinationPath $tempDir -Force -ErrorAction Stop
        
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Restoring database from $BackupName..."
        $ProgressBarControl.Value = 40
        
        # Drop and recreate the immich database to ensure a clean state before restore
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Dropping and recreating the database..."
        & docker exec -e PGPASSWORD=$databasePassword $PostgresContainer psql -U $PostgresUser -c "DROP DATABASE IF EXISTS immich;" -ErrorAction Stop
        if ($LASTEXITCODE -ne 0) { throw "Docker command failed with exit code $LASTEXITCODE" }
        & docker exec -e PGPASSWORD=$databasePassword $PostgresContainer psql -U $PostgresUser -c "CREATE DATABASE immich WITH OWNER postgres;" -ErrorAction Stop
        if ($LASTEXITCODE -ne 0) { throw "Docker command failed with exit code $LASTEXITCODE" }
        
        # Restore the database from the extracted SQL file
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Restoring from SQL dump file..."
        $ProgressBarControl.Value = 70
        Get-Content -Path $RestoreFile | & docker exec -i $PostgresContainer psql -U $PostgresUser -d immich -ErrorAction Stop
        if ($LASTEXITCODE -ne 0) { throw "Docker command failed with exit code $LASTEXITCODE" }
        
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Starting Immich containers..."
        $ProgressBarControl.Value = 90
        & docker compose up -d -ErrorAction Stop
        if ($LASTEXITCODE -ne 0) { throw "Docker command failed with exit code $LASTEXITCODE" }

        $ProgressBarControl.Value = 100
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Database restore complete!"
        return $true
    } catch {
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Restore failed: $_"
        return $false
    } finally {
        if (Test-Path -Path $tempDir) {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Schedule-BackupTask {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Interval,
        [Parameter(Mandatory=$false)]
        [string]$Day,
        [Parameter(Mandatory=$true)]
        [string]$Time,
        [Parameter(Mandatory=$true)]
        [PSObject]$StatusTextControl,
        [Parameter(Mandatory=$true)]
        [PSObject]$ProgressBarControl
    )
    
    $scriptPath = $MyInvocation.MyCommand.Definition
    $taskName = "ImmichBackupScheduled"
    
    # Remove existing task before adding a new one
    try {
        $ProgressBarControl.Value = 25
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        }
    } catch {
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Failed to remove previous task: $_"
    }

    try {
        $ProgressBarControl.Value = 50
        $timeParts = $Time.Split(':')
        $hour = [int]$timeParts[0]
        $minute = [int]$timeParts[1]
        $atTime = (Get-Date).Date.AddHours($hour).AddMinutes($minute)

        switch ($Interval) {
            "Daily" { 
                $trigger = New-ScheduledTaskTrigger -Daily -At $atTime
                $scheduleDescription = "Daily at $Time"
            }
            "Weekly" {
                $dayOfWeek = [System.DayOfWeek]$Day
                $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $dayOfWeek -At $atTime
                $scheduleDescription = "Weekly on $Day at $Time"
            }
            "Monthly" {
                $dayOfMonth = [int]$Day
                $trigger = New-ScheduledTaskTrigger -Monthly -DaysOfMonth $dayOfMonth -At $atTime
                $scheduleDescription = "Monthly on day $Day at $Time"
            }
        }
        
        $ProgressBarControl.Value = 75
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`" -RunBackup"
        Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $action -RunLevel Highest -Force -ErrorAction Stop
        $ProgressBarControl.Value = 100
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Task scheduled: $scheduleDescription"
    } catch {
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Failed to schedule task: $_"
    }
}

function Remove-ScheduledTask {
    param(
        [Parameter(Mandatory=$true)]
        [PSObject]$StatusTextControl,
        [Parameter(Mandatory=$true)]
        [PSObject]$ProgressBarControl
    )
    
    $taskName = "ImmichBackupScheduled"
    try {
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            $ProgressBarControl.Value = 50
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
            $ProgressBarControl.Value = 100
            Add-StatusText -StatusTextControl $StatusTextControl -Message "Task '$taskName' removed."
        } else {
            $ProgressBarControl.Value = 100
            Add-StatusText -StatusTextControl $StatusTextControl -Message "No scheduled task found."
        }
    } catch {
        $ProgressBarControl.Value = 100
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Failed to remove task: $_"
    }
}

# Function to get the list of backup files
function Get-BackupFiles {
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Config
    )
    $backupPath = $Config.DEFAULT_PATHS.IMMICH_BACKUP
    $backupFiles = Get-ChildItem -Path $backupPath -Filter "*.zip" | Sort-Object CreationTime -Descending
    $fileNames = $backupFiles | ForEach-Object { $_.BaseName }
    return $fileNames
}

function Create-UpdateSnapshot {
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Config,
        [Parameter(Mandatory=$true)]
        [PSObject]$StatusTextControl,
        [Parameter(Mandatory=$true)]
        [PSObject]$ProgressBarControl
    )

    $immichRoot = $Config.DEFAULT_PATHS.IMMICH_ROOT
    $dbDataLocation = $Config.DEFAULT_PATHS.DB_DATA_LOCATION
    $snapshotZipPath = Join-Path $immichRoot "UpdateSnapshot.zip"
    $tempDir = New-TempDirectory -Name "ImmichUpdateSnapshotTemp"
    
    try {
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Creating update snapshot..."
        $ProgressBarControl.Value = 10
        
        # Copy immich root contents to temp dir, excluding snapshot
        $ProgressBarControl.Value = 30
        Get-ChildItem -Path $immichRoot -Exclude "UpdateSnapshot.zip" | Copy-Item -Destination $tempDir -Recurse -Force -ErrorAction Stop
        
        # Copy database folder to temp dir
        $ProgressBarControl.Value = 60
        Copy-Item -Path $dbDataLocation -Destination $tempDir -Recurse -Force -ErrorAction Stop
        
        # Compress temp directory to snapshot file
        $ProgressBarControl.Value = 80
        if (Test-Path -Path $snapshotZipPath) {
            Remove-Item -Path $snapshotZipPath -Force -ErrorAction Stop
        }
        Compress-Archive -Path (Join-Path $tempDir "*") -DestinationPath $snapshotZipPath -Force -ErrorAction Stop
        
        $ProgressBarControl.Value = 100
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Update snapshot created successfully."
        return $true
    } catch {
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Failed to create update snapshot: $_"
        return $false
    } finally {
        if (Test-Path -Path $tempDir) {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Update-Immich {
    param(
        [Parameter(Mandatory=$true)]
        [PSObject]$StatusTextControl,
        [Parameter(Mandatory=$true)]
        [PSObject]$ProgressBarControl
    )
    
    try {
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Pulling latest Immich Docker images..."
        $ProgressBarControl.Value = 10
        & docker compose pull -ErrorAction Stop | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Docker command failed with exit code $LASTEXITCODE" }
        
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Stopping current Immich containers..."
        $ProgressBarControl.Value = 40
        & docker compose down -ErrorAction Stop | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Docker command failed with exit code $LASTEXITCODE" }
        
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Starting Immich with updated containers..."
        $ProgressBarControl.Value = 70
        & docker compose up -d -ErrorAction Stop | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Docker command failed with exit code $LASTEXITCODE" }
        
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Pruning unused Docker resources..."
        $ProgressBarControl.Value = 90
        & docker image prune -f -ErrorAction Stop | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Docker command failed with exit code $LASTEXITCODE" }
        
        $ProgressBarControl.Value = 100
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Immich update and prune complete!"
        return $true
    } catch {
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Update failed: $_"
        return $false
    }
}

function Rollback-Update {
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Config,
        [Parameter(Mandatory=$true)]
        [PSObject]$StatusTextControl,
        [Parameter(Mandatory=$true)]
        [PSObject]$ProgressBarControl
    )
    $immichRoot = $Config.DEFAULT_PATHS.IMMICH_ROOT
    $snapshotZipPath = Join-Path $immichRoot "UpdateSnapshot.zip"
    $tempRollbackDir = New-TempDirectory -Name "ImmichRollbackTemp"
    
    try {
        if (-not (Test-Path -Path $snapshotZipPath)) {
            Add-StatusText -StatusTextControl $StatusTextControl -Message "Error: UpdateSnapshot.zip not found. No previous update to rollback."
            return $false
        }
        
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Stopping Immich containers..."
        $ProgressBarControl.Value = 10
        & docker compose down -ErrorAction Stop | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Docker command failed with exit code $LASTEXITCODE" }
        
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Extracting rollback snapshot..."
        $ProgressBarControl.Value = 40
        Expand-Archive -Path $snapshotZipPath -DestinationPath $tempRollbackDir -Force -ErrorAction Stop
        
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Restoring from snapshot..."
        $ProgressBarControl.Value = 60
        # Remove existing files and directories except the snapshot itself
        Get-ChildItem -Path $immichRoot -Exclude "UpdateSnapshot.zip" | Remove-Item -Recurse -Force -ErrorAction Stop
        # Copy files from temp directory back to immich root
        Copy-Item -Path (Join-Path $tempRollbackDir "*") -Destination $immichRoot -Recurse -Force -ErrorAction Stop
        
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Starting Immich containers..."
        $ProgressBarControl.Value = 90
        & docker compose up -d -ErrorAction Stop | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Docker command failed with exit code $LASTEXITCODE" }
        
        $ProgressBarControl.Value = 100
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Rollback complete!"
        return $true
    } catch {
        Add-StatusText -StatusTextControl $StatusTextControl -Message "Rollback failed: $_"
        return $false
    } finally {
        if (Test-Path -Path $tempRollbackDir) {
            Remove-Item -Path $tempRollbackDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# Load the GUI from the XAML file
[xml]$xaml = Get-Content -Path $GuiPath
$reader = New-Object System.Xml.XmlNodeReader($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

# Get UI elements
$BackupButton = $window.FindName("BackupButton")
$RestoreButton = $window.FindName("RestoreButton")
$UpdateButton = $window.FindName("UpdateButton")
$RollbackButton = $window.FindName("RollbackButton")
$BackupNumberTextBox = $window.FindName("BackupNumberTextBox")
$IntervalDropdown = $window.FindName("IntervalDropdown")
$DayOfWeekDropdown = $window.FindName("DayOfWeekDropdown")
$DayOfMonthDropdown = $window.FindName("DayOfMonthDropdown")
$TimeTextBox = $window.FindName("TimeTextBox")
$AddScheduleButton = $window.FindName("AddScheduleButton")
$RemoveScheduleButton = $window.FindName("RemoveScheduleButton")
$RestoreFileDropdown = $window.FindName("RestoreFileDropdown")
$StatusText = $window.FindName("StatusText")
$ProgressBar = $window.FindName("ProgressBar")
$WeeklyControls = $window.FindName("WeeklyControls")
$MonthlyControls = $window.FindName("MonthlyControls")
$BackupGroupBox = $window.FindName("BackupGroupBox")
$ScheduledBackupGroupBox = $window.FindName("ScheduledBackupGroupBox")
$RestoreGroupBox = $window.FindName("RestoreGroupBox")
$UpdateRollbackPanel = $window.FindName("UpdateRollbackPanel")

# Set initial values and event handlers
Clear-Status -StatusTextControl $StatusText -ProgressBarControl $ProgressBar
$config = Load-ImmichConfig
if ($config) {
    $BackupNumberTextBox.Text = $config.GENERAL_SETTINGS.BACKUP_NUMBER
    # Populate the restore dropdown
    $backupFiles = Get-BackupFiles -Config $config
    foreach ($file in $backupFiles) {
        $RestoreFileDropdown.Items.Add($file)
    }
    if ($RestoreFileDropdown.Items.Count -gt 0) {
        $RestoreFileDropdown.SelectedIndex = 0
    }
}
$IntervalDropdown.Add_SelectionChanged({
    if ($IntervalDropdown.Text -eq "Weekly") {
        $WeeklyControls.Visibility = "Visible"
        $MonthlyControls.Visibility = "Collapsed"
    } elseif ($IntervalDropdown.Text -eq "Monthly") {
        $WeeklyControls.Visibility = "Collapsed"
        $MonthlyControls.Visibility = "Visible"
    } else {
        $WeeklyControls.Visibility = "Collapsed"
        $MonthlyControls.Visibility = "Collapsed"
    }
})

# Populate DayOfMonthDropdown
for ($i = 1; $i -le 31; $i++) {
    $DayOfMonthDropdown.Items.Add($i)
}
$DayOfMonthDropdown.SelectedIndex = 0

# --- Event Handlers ---

$BackupButton.Add_Click({
    Clear-Status -StatusTextControl $StatusText -ProgressBarControl $ProgressBar
    $BackupGroupBox.IsEnabled = $false
    $ScheduledBackupGroupBox.IsEnabled = $false
    $RestoreGroupBox.IsEnabled = $false
    $UpdateRollbackPanel.IsEnabled = $false
    
    try {
        $config = Load-ImmichConfig
        if ($config) {
            # Validate and update backup number from GUI
            $newBackupNumber = 0
            if ($BackupNumberTextBox.Text -match '^\d+$') {
                $newBackupNumber = [int]$BackupNumberTextBox.Text
                $config.GENERAL_SETTINGS.BACKUP_NUMBER = $newBackupNumber
                Save-ImmichConfig -ConfigObject $config
            } else {
                Add-StatusText -StatusTextControl $StatusText -Message "Please enter a valid number for backups to keep."
                return
            }
            
            $backupSuccess = Backup-Database -Config $config -KeepLast $newBackupNumber -StatusTextControl $StatusText -ProgressBarControl $ProgressBar
            
            if ($backupSuccess) {
                $currentDateTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
                $config.GENERAL_SETTINGS.LAST_SYNC = $currentDateTime
                Save-ImmichConfig -ConfigObject $config
                Add-StatusText -StatusTextControl $StatusText -Message "Last Sync: $currentDateTime"
                
                # Repopulate the restore dropdown
                $RestoreFileDropdown.Items.Clear()
                $backupFiles = Get-BackupFiles -Config $config
                foreach ($file in $backupFiles) {
                    $RestoreFileDropdown.Items.Add($file)
                }
                if ($RestoreFileDropdown.Items.Count -gt 0) {
                    $RestoreFileDropdown.SelectedIndex = 0
                }
            }
        } else {
            Add-StatusText -StatusTextControl $StatusText -Message "Failed to load configuration."
        }
    } finally {
        $BackupGroupBox.IsEnabled = $true
        $ScheduledBackupGroupBox.IsEnabled = $true
        $RestoreGroupBox.IsEnabled = $true
        $UpdateRollbackPanel.IsEnabled = $true
    }
})

$AddScheduleButton.Add_Click({
    Clear-Status -StatusTextControl $StatusText -ProgressBarControl $ProgressBar
    $BackupGroupBox.IsEnabled = $false
    $ScheduledBackupGroupBox.IsEnabled = $false
    $RestoreGroupBox.IsEnabled = $false
    $UpdateRollbackPanel.IsEnabled = $false
    
    try {
        $interval = $IntervalDropdown.Text
        $time = $TimeTextBox.Text
        
        $day = $null
        if ($interval -eq "Weekly") {
            $day = $DayOfWeekDropdown.Text
        } elseif ($interval -eq "Monthly") {
            $day = $DayOfMonthDropdown.Text
        }

        Schedule-BackupTask -Interval $interval -Day $day -Time $time -StatusTextControl $StatusText -ProgressBarControl $ProgressBar
    } finally {
        $BackupGroupBox.IsEnabled = $true
        $ScheduledBackupGroupBox.IsEnabled = $true
        $RestoreGroupBox.IsEnabled = $true
        $UpdateRollbackPanel.IsEnabled = $true
    }
})

$RemoveScheduleButton.Add_Click({
    Clear-Status -StatusTextControl $StatusText -ProgressBarControl $ProgressBar
    $BackupGroupBox.IsEnabled = $false
    $ScheduledBackupGroupBox.IsEnabled = $false
    $RestoreGroupBox.IsEnabled = $false
    $UpdateRollbackPanel.IsEnabled = $false
    
    try {
        Remove-ScheduledTask -StatusTextControl $StatusText -ProgressBarControl $ProgressBar
    } finally {
        $BackupGroupBox.IsEnabled = $true
        $ScheduledBackupGroupBox.IsEnabled = $true
        $RestoreGroupBox.IsEnabled = $true
        $UpdateRollbackPanel.IsEnabled = $true
    }
})

$RestoreButton.Add_Click({
    Clear-Status -StatusTextControl $StatusText -ProgressBarControl $ProgressBar
    $BackupGroupBox.IsEnabled = $false
    $ScheduledBackupGroupBox.IsEnabled = $false
    $RestoreGroupBox.IsEnabled = $false
    $UpdateRollbackPanel.IsEnabled = $false
    
    try {
        $config = Load-ImmichConfig
        if ($config) {
            $selectedBackup = $RestoreFileDropdown.SelectedItem
            if (-not $selectedBackup) {
                Add-StatusText -StatusTextControl $StatusText -Message "Please select a backup file to restore."
                return
            }
            
            $restoreSuccess = Restore-Database -BackupName $selectedBackup -Config $config -StatusTextControl $StatusText -ProgressBarControl $ProgressBar
            if ($restoreSuccess) {
                Add-StatusText -StatusTextControl $StatusText -Message "Successfully restored database from $($selectedBackup)."
            }
        } else {
            Add-StatusText -StatusTextControl $StatusText -Message "Failed to load configuration."
        }
    } finally {
        $BackupGroupBox.IsEnabled = $true
        $ScheduledBackupGroupBox.IsEnabled = $true
        $RestoreGroupBox.IsEnabled = $true
        $UpdateRollbackPanel.IsEnabled = $true
    }
})

$UpdateButton.Add_Click({
    Clear-Status -StatusTextControl $StatusText -ProgressBarControl $ProgressBar
    $BackupGroupBox.IsEnabled = $false
    $ScheduledBackupGroupBox.IsEnabled = $false
    $RestoreGroupBox.IsEnabled = $false
    $UpdateRollbackPanel.IsEnabled = $false
    
    try {
        $config = Load-ImmichConfig
        if ($config) {
            if (Create-UpdateSnapshot -Config $config -StatusTextControl $StatusText -ProgressBarControl $ProgressBar) {
                Update-Immich -StatusTextControl $StatusText -ProgressBarControl $ProgressBar
            }
        } else {
            Add-StatusText -StatusTextControl $StatusText -Message "Failed to load configuration."
        }
    } finally {
        $BackupGroupBox.IsEnabled = $true
        $ScheduledBackupGroupBox.IsEnabled = $true
        $RestoreGroupBox.IsEnabled = $true
        $UpdateRollbackPanel.IsEnabled = $true
    }
})

$RollbackButton.Add_Click({
    Clear-Status -StatusTextControl $StatusText -ProgressBarControl $ProgressBar
    $BackupGroupBox.IsEnabled = $false
    $ScheduledBackupGroupBox.IsEnabled = $false
    $RestoreGroupBox.IsEnabled = $false
    $UpdateRollbackPanel.IsEnabled = $false
    
    try {
        $config = Load-ImmichConfig
        if ($config) {
            Rollback-Update -Config $config -StatusTextControl $StatusText -ProgressBarControl $ProgressBar
        } else {
            Add-StatusText -StatusTextControl $StatusText -Message "Failed to load configuration."
        }
    } finally {
        $BackupGroupBox.IsEnabled = $true
        $ScheduledBackupGroupBox.IsEnabled = $true
        $RestoreGroupBox.IsEnabled = $true
        $UpdateRollbackPanel.IsEnabled = $true
    }
})

# Display the window
$window.ShowDialog() | Out-Null