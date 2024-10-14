# dbatools MODULE NEEDED

if (!(Get-Module -ListAvailable -Name dbatools)) {
    Write-Host "dbatools module not found. Installing module..."
    
    # Install the dbatools module
    Install-Module -Name dbatools -Force -AllowClobber
    Write-Host "dbatools module installed successfully."
} else {
    Write-Host "dbatools module is already installed."
}


# Prompt for input
$sourceDB = Read-Host "Enter the source database name (e.g., AutoPilotDev)"
$projectDir = Read-Host "Enter the AutoPilot Project path (e.g., C:\WorkingFolders\FWD\AutoPilot)" #maybe do just project
$backupDir = $projectDir + "\backups"
$serverName = Read-Host "Enter the SQL Server name"
$backupFileName = "AutoBackup_$sourceDB.bak"  # Backup file naming convention
$backupPath = Join-Path $backupDir $backupFileName


do {
    $trustCert = Read-Host "Do we need to trust the Server Certificate [Y] or [N]?"
    $trustCert = $trustCert.ToUpper()  # Convert the input to uppercase
}
until ($trustCert -eq 'Y' -or $trustCert -eq 'N')  # Proper comparison

do {
    $encryptConnection = Read-Host "Do we need to enycrpt the connection [Y] or [N]?"
    $encryptConnection = $trustCert.ToUpper()  # Convert the input to uppercase
}
until ($trustCert -eq 'Y' -or $trustCert -eq 'N')  # Proper comparison

#Block to generate connection string
if ($trustCert -eq 'Y' -and $encryptConnection -eq 'Y')
{ 
$SqlConnection = Connect-DbaInstance -SqlInstance $serverName -TrustServerCertificate -EncryptConnection
}
if ($trustCert -eq 'Y' -and $encryptConnection -eq 'N')
{ 
$SqlConnection = Connect-DbaInstance -SqlInstance $serverName -TrustServerCertificate
}
if ($trustCert -eq 'N' -and $encryptConnection -eq 'Y')
{ 
$SqlConnection = Connect-DbaInstance -SqlInstance $serverName -EncryptConnection
}
if ($trustCert -eq 'N' -and $encryptConnection -eq 'N')
{ 
$SqlConnection = Connect-DbaInstance -SqlInstance $serverName -TrustServerCertificate -EncryptConnection
}

# Step 1: Run the first script to create the schema backup
$sqlCreateBackup = @"
DECLARE @SourceDB NVARCHAR(128) = N'$sourceDB';
DECLARE @BackupDB NVARCHAR(128) = @SourceDB + N'_Schema';
DECLARE @BackupPath NVARCHAR(256) = N'$backupPath';

DBCC CLONEDATABASE (@SourceDB, @BackupDB) WITH NO_STATISTICS, NO_QUERYSTORE, VERIFY_CLONEDB;

DECLARE @BackupCommand NVARCHAR(MAX) = 
N'BACKUP DATABASE [' + @BackupDB + N'] TO DISK = ''' + @BackupPath + N''' WITH INIT, FORMAT, MEDIANAME = ''SQLServerBackups'', NAME = ''Full Backup of ' + @BackupDB + N''';';

EXEC sp_executesql @BackupCommand;

-- Drop Schema Database If Exists
DECLARE @drop NVARCHAR(100); -- Declare a variable to hold the drop database command
DECLARE @Result NVARCHAR(200); -- Declare a variable to hold the full drop database command with the database name
SET @drop = 'DROP DATABASE IF EXISTS'; -- Set the drop command
SET @Result = (@drop + ' ' + @BackupDB); -- Combine the drop command with the cloned database name
EXEC sp_executesql @Result; -- Execute the drop database command

"@

Invoke-DbaQuery -Query $sqlCreateBackup -SqlInstance $sqlConnection

# Step 2: Find the logical file paths of the original database
$sqlFindPaths = @"
USE $sourceDB;

DECLARE @LogicalDataFileName NVARCHAR(128);
DECLARE @LogicalLogFileName NVARCHAR(128);

-- Get logical file names
SELECT @LogicalDataFileName = df.name
FROM sys.database_files df
WHERE type_desc = 'ROWS';

SELECT @LogicalLogFileName = df.name
FROM sys.database_files df
WHERE type_desc = 'LOG';

-- Return the logical file names
SELECT @LogicalDataFileName AS Column1, @LogicalLogFileName AS Column2;
"@

$paths = Invoke-DbaQuery -Query $sqlFindPaths -SqlInstance $sqlConnection

# Reference Column1 and Column2 for the file names
$logicalDataFileName = $paths[0]
$logicalLogFileName = $paths[1]

# Output the results to verify
Write-Host "Logical Data File Name: $logicalDataFileName"
Write-Host "Logical Log File Name: $logicalLogFileName"

# Step 3: Prompt for the names of databases to restore to

$sqlRestore = @"

DECLARE @BackupFilePath NVARCHAR(128) = N'$backupPath';  -- Step 1. Change me to the backup location!
DECLARE @LogicalDataFileName NVARCHAR(128) = N'$logicalDataFileName';  -- Step 2. Make these match the original DB! Psst, you can use 2.FindLogicalPaths.sql
DECLARE @LogicalLogFileName NVARCHAR(128) = N'$logicalLogFileName';  -- Step 2. Make these match the original DB! Psst, you can use 2.FindLogicalPaths.sql
DECLARE @DataFilePath NVARCHAR(260);  -- Declare a variable to hold the data file path
DECLARE @LogFilePath NVARCHAR(260);  -- Declare a variable to hold the log file path
DECLARE @DatabaseName NVARCHAR(128);  -- Declare a variable to hold the current database name

-- Attempts to Auto Find the Paths to the logical files!
DECLARE @mdfLocation NVARCHAR(256) = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS NVARCHAR(200));  -- Get the default data file path
DECLARE @ldfLocation NVARCHAR(256) = CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS NVARCHAR(200));  -- Get the default log file path

DECLARE @mySQL NVARCHAR(MAX);  -- Declare a variable to hold SQL commands

DECLARE @DatabaseList TABLE (  -- Create a table variable to hold the list of databases
    DatabaseName NVARCHAR(128)
);

-- Insert the database names into the table variable
INSERT INTO @DatabaseList (DatabaseName)
VALUES ('AutoPilotDev'), ('AutoPilotTest'), ('AutoPilotProd'), ('AutoPilotShadow'), ('AutoPilotBuild'), ('AutoPilotCheck');

DECLARE @Counter INT = 1;  -- Initialize a counter for the loop
DECLARE @TotalCount INT = (SELECT COUNT(*) FROM @DatabaseList);  -- Get the total count of databases

-- Loop through each database in the list
WHILE @Counter <= @TotalCount
BEGIN
    -- Get the current database name based on the counter
    SET @DatabaseName = (SELECT DatabaseName FROM (
        SELECT ROW_NUMBER() OVER (ORDER BY DatabaseName) AS RowNum, DatabaseName 
        FROM @DatabaseList
    ) AS TempDB
    WHERE TempDB.RowNum = @Counter);

    -- Define file paths for the current database
    SET @DataFilePath = @mdfLocation + @DatabaseName + '_Data.mdf';
    SET @LogFilePath = @ldfLocation + @DatabaseName + '_Log.ldf';

    -- Use master database
    USE [master];

    -- Check if the database already exists, and if it does, drop it
    IF EXISTS (SELECT name FROM sys.databases WHERE name = @DatabaseName)
    BEGIN
        -- Try to set the database to single-user mode and drop it
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

    -- Restore the database from the backup with unique logical file names
    BEGIN TRY
        SET @mySQL = N'RESTORE DATABASE [' + @DatabaseName + ']
        FROM DISK = ''' + @BackupFilePath + '''
        WITH REPLACE,
        MOVE ''' + @LogicalDataFileName + ''' TO ''' + @DataFilePath + ''',
        MOVE ''' + @LogicalLogFileName + ''' TO ''' + @LogFilePath + ''';';
        EXEC sp_executesql @mySQL;

        -- Put the database back in multi-user mode and set it to READ_WRITE
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

    SET @Counter = @Counter + 1;  -- Increment the counter
END

"@


Invoke-DbaQuery -Query $sqlRestore -SqlInstance $sqlConnection

Write-Host "Succesfully Created AutoPilot Testing Databases from: $sourceDB"


# Step 4: Update the B001__baseline.sql script with the correct logical data and log file paths
Get-ChildItem -Filter B001* -Path $projectDir\migrations -Recurse | Move-Item -Destination $projectDir\scripts\temp\

$baselineFilePath = "$projectDir\scripts\temp\baselineTemplate.sql"
$confFilePath = "$projectDir\scripts\temp\baselineconf.sql.conf"

$baselineContent = Get-Content $baselineFilePath
$confContent = Get-Content $confFilePath

# Replace placeholders with actual logical data and log file names
$updatedBaselineContent = $baselineContent `
    -replace "TEMPORARYBACKUP", $backupFileName `
    -replace "TEMPORARYDATAFILENAME", $logicalDataFileName `
    -replace "TEMPORARYLOGFILENAME", $logicalLogFileName `

$updatedConfContent = $confContent

# Write the updated content back to the file
$currentDate = Get-Date -Format("yyyyMMddhhmmss")


$newBaselinePath = "$projectDir\migrations\B001__$currentDate.sql" 
$newConfPath = "$projectDir\migrations\B001__$currentDate.sql.conf" 

$newBaselineFile = New-Item -Path $newBaselinePath -ItemType File
$newConfFile = New-Item -Path $newConfPath -ItemType File

$updatedBaselineContent | Set-Content $newBaselineFile.FullName
$updatedConfContent | Set-Content $newConfFile.FullName


Write-Host "Baseline script updated successfully with logical paths."
