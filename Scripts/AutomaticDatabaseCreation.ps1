# dbatools MODULE NEEDED
if (!(Get-Module -ListAvailable -Name dbatools)) {
    Write-Host "dbatools module not found. Installing module..."
    Install-Module -Name dbatools -Force -AllowClobber
    Write-Host "dbatools module installed successfully."
} else {
    Write-Host "dbatools module is already installed."
}

# Helper function for validating non-empty inputs
function Get-ValidatedInput {
    param (
        [string]$PromptMessage,
        [ValidateScript({$_ -ne ''})] # Ensure input is not empty
        [string]$ErrorMessage
    )
    do {
        $inputValue = Read-Host $PromptMessage
        if ([string]::IsNullOrWhiteSpace($inputValue)) {
            Write-Host $ErrorMessage -ForegroundColor Red
        }
    } until (![string]::IsNullOrWhiteSpace($inputValue))
    return $inputValue
}

Write-Host "Flyway AutoPilot Backup & Running Setup - To get up and running, it's necessary to create a Schema Only backup of a chosen database. This will then be used to create your AutoPilot project databases."
Write-Host "Step 1: Provide the connection details for your preferred PoC database"
Write-Host "Tip - Restore your preferred database into a non-production SQL Server Instance. This will help to create our PoC sandbox, where the AutoPilot databases will also exist."

# Prompt for inputs with validation
$sourceDB = Get-ValidatedInput -PromptMessage "Enter the Source Database Name to be Schema Backed Up (e.g., MyDatabaseName)" `
    -ErrorMessage "Database name cannot be empty. Please provide a valid database name."

$projectDir = Get-ValidatedInput -PromptMessage "Enter the AutoPilot Root Project path (e.g., C:\WorkingFolders\FWD\AutoPilot)" `
    -ErrorMessage "Project path cannot be empty. Please provide a valid directory."

# Validate project directory exists
if (!(Test-Path -Path $projectDir)) {
    Write-Host "The specified project directory does not exist. Please check the path." -ForegroundColor Red
    exit
}

$backupDir = Join-Path $projectDir "backups"

$serverName = Get-ValidatedInput -PromptMessage "Enter the SQL Server Name (Source Database should reside here)" `
    -ErrorMessage "Server name cannot be empty. Please provide a valid server name."

$backupFileName = "AutoBackup_$sourceDB.bak"
$backupPath = Join-Path $backupDir $backupFileName

# Ensure the backup directory exists
if (!(Test-Path -Path $backupDir)) {
    New-Item -Path $backupDir -ItemType Directory | Out-Null
}

# Prompt for server certificate and encryption settings
do {
    $trustCert = Read-Host "Do you need to trust the Server Certificate? (Y/N)"
    $trustCert = $trustCert.ToUpper()
} until ($trustCert -match "^(Y|N)$")

do {
    $encryptConnection = Read-Host "Do you need to encrypt the connection? (Y/N)"
    $encryptConnection = $encryptConnection.ToUpper()
} until ($encryptConnection -match "^(Y|N)$")

# Generate the SQL Server connection based on user preferences
if ($trustCert -eq 'Y' -and $encryptConnection -eq 'Y') {
    $SqlConnection = Connect-DbaInstance -SqlInstance $serverName -TrustServerCertificate -EncryptConnection
} elseif ($trustCert -eq 'Y' -and $encryptConnection -eq 'N') {
    $SqlConnection = Connect-DbaInstance -SqlInstance $serverName -TrustServerCertificate
} elseif ($trustCert -eq 'N' -and $encryptConnection -eq 'Y') {
    $SqlConnection = Connect-DbaInstance -SqlInstance $serverName -EncryptConnection
} else {
    $SqlConnection = Connect-DbaInstance -SqlInstance $serverName
}

# Step 1: Create the schema backup
Write-Host "Creating a schema backup for $sourceDB..."
$sqlCreateBackup = @"
DECLARE @SourceDB NVARCHAR(128) = N'$sourceDB';
DECLARE @BackupDB NVARCHAR(128) = @SourceDB + N'_Schema';
DECLARE @BackupPath NVARCHAR(256) = N'$backupPath';

DBCC CLONEDATABASE (@SourceDB, @BackupDB) WITH NO_STATISTICS, NO_QUERYSTORE, VERIFY_CLONEDB;

DECLARE @BackupCommand NVARCHAR(MAX) = 
N'BACKUP DATABASE [' + @BackupDB + N'] TO DISK = ''' + @BackupPath + N''' WITH INIT, FORMAT, MEDIANAME = ''SQLServerBackups'', NAME = ''Full Backup of ' + @BackupDB + N''';';

EXEC sp_executesql @BackupCommand;

-- Drop the temporary schema database
IF DB_ID(@BackupDB) IS NOT NULL
    EXEC('DROP DATABASE ' + @BackupDB);
"@

Invoke-DbaQuery -Query $sqlCreateBackup -SqlInstance $SqlConnection

# Step 2: Retrieve logical file names from the source database
Write-Host "Retrieving logical file names from $sourceDB..."
$sqlFindPaths = @"
USE $sourceDB;

SELECT name AS LogicalFileName, type_desc
FROM sys.database_files;
"@

$paths = Invoke-DbaQuery -Query $sqlFindPaths -SqlInstance $SqlConnection
$logicalDataFileName = $paths | Where-Object { $_.type_desc -eq 'ROWS' } | Select-Object -ExpandProperty LogicalFileName
$logicalLogFileName = $paths | Where-Object { $_.type_desc -eq 'LOG' } | Select-Object -ExpandProperty LogicalFileName

Write-Host "Logical Data File Name: $logicalDataFileName"
Write-Host "Logical Log File Name: $logicalLogFileName"

# Step 3: Restore the backup to multiple environments
Write-Host "Creating AutoPilot databases using provided backup..."
$sqlRestore = @"
DECLARE @BackupFilePath NVARCHAR(128) = N'$backupPath';  -- Step 1. Change me to the backup location!
DECLARE @LogicalDataFileName NVARCHAR(128) = N'$logicalDataFileName';  -- Logical Data File Name
DECLARE @LogicalLogFileName NVARCHAR(128) = N'$logicalLogFileName';  -- Logical Log File Name
DECLARE @DataFilePath NVARCHAR(260);  -- Data file path
DECLARE @LogFilePath NVARCHAR(260);  -- Log file path
DECLARE @DatabaseName NVARCHAR(128);  -- Current database name

-- Attempts to Auto Find the Paths to the logical files!
DECLARE @mdfLocation NVARCHAR(256) = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS NVARCHAR(200));
DECLARE @ldfLocation NVARCHAR(256) = CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS NVARCHAR(200));

DECLARE @mySQL NVARCHAR(MAX);

DECLARE @DatabaseList TABLE (DatabaseName NVARCHAR(128)); -- Table of databases to restore
INSERT INTO @DatabaseList (DatabaseName)
VALUES ('AutoPilotDev'), ('AutoPilotTest'), ('AutoPilotProd'), ('AutoPilotShadow'), ('AutoPilotBuild'), ('AutoPilotCheck');

DECLARE @Counter INT = 1;
DECLARE @TotalCount INT = (SELECT COUNT(*) FROM @DatabaseList);

WHILE @Counter <= @TotalCount
BEGIN
    SET @DatabaseName = (SELECT DatabaseName FROM (
        SELECT ROW_NUMBER() OVER (ORDER BY DatabaseName) AS RowNum, DatabaseName 
        FROM @DatabaseList
    ) AS TempDB
    WHERE TempDB.RowNum = @Counter);

    SET @DataFilePath = @mdfLocation + @DatabaseName + '_Data.mdf';
    SET @LogFilePath = @ldfLocation + @DatabaseName + '_Log.ldf';

    -- Use master database
    USE [master];

    IF EXISTS (SELECT name FROM sys.databases WHERE name = @DatabaseName)
    BEGIN
        BEGIN TRY
            SET @mySQL = N'ALTER DATABASE [' + @DatabaseName + '] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;';
            EXEC sp_executesql @mySQL;
            SET @mySQL = N'DROP DATABASE [' + @DatabaseName + '];';
            EXEC sp_executesql @mySQL;
        END TRY
        BEGIN CATCH
            PRINT 'Error occurred while altering or dropping the existing database ' + @DatabaseName;
            PRINT ERROR_MESSAGE();
            RETURN;
        END CATCH
    END

    BEGIN TRY
        SET @mySQL = N'RESTORE DATABASE [' + @DatabaseName + ']
        FROM DISK = ''' + @BackupFilePath + '''
        WITH REPLACE,
        MOVE ''' + @LogicalDataFileName + ''' TO ''' + @DataFilePath + ''',
        MOVE ''' + @LogicalLogFileName + ''' TO ''' + @LogFilePath + ''';';
        EXEC sp_executesql @mySQL;

        -- Set database to READ_WRITE mode and MULTI_USER
        SET @mySQL = N'ALTER DATABASE [' + @DatabaseName + '] SET MULTI_USER;';
        EXEC sp_executesql @mySQL;
        SET @mySQL = N'ALTER DATABASE [' + @DatabaseName + '] SET READ_WRITE;';
        EXEC sp_executesql @mySQL;
    END TRY
    BEGIN CATCH
        PRINT 'Error occurred during the restore operation for database ' + @DatabaseName;
        PRINT ERROR_MESSAGE();
        RETURN;
    END CATCH

    SET @Counter = @Counter + 1;
END
"@

# Execute the SQL restore script
try {
    Invoke-DbaQuery -Query $sqlRestore -SqlInstance $SqlConnection
    Write-Host "Databases restored successfully and set to READ_WRITE mode."
} catch {
    Write-Host "An error occurred during the restoration process." -ForegroundColor Red
    exit
}

# Step 4: Update baseline script with actual paths
Write-Host "Updating baseline script with logical paths..."
$baselineFilePath = Join-Path $projectDir "scripts\temp\baselineTemplate.sql"
$updatedBaselinePath = Join-Path $projectDir "migrations\B001__Baseline.sql"

Get-Content $baselineFilePath | ForEach-Object {
    $_ -replace "TEMPORARYBACKUP", $backupFileName `
       -replace "TEMPORARYDATAFILENAME", $logicalDataFileName `
       -replace "TEMPORARYLOGFILENAME", $logicalLogFileName
} | Set-Content $updatedBaselinePath

Write-Host "Baseline script updated successfully."
