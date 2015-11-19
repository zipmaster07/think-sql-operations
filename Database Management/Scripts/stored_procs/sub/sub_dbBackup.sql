/*
**	This stored procedure takes a backup of an MSSQL database on any instance.  It is capable of taking a native MSSQL backup or a Litespeed backup (provided that Litespeed
**	is installed on the SQL server).  This sp is a sub stored procedure.  It is not meant to be called directly but through a user stored procedure.  The sp can take full,
**	differential, and transaction log backups.  it also creates a backup name according to several values provided by the user using a consistent naming convention.  It
**	takes several parameters as input.  It requires the name of the database to backup, the type of backup desired (full, diff, tran log), the method to backup (native,
**	or Litespeed), a client name, if applicable, the user backing up the database for audit purposes, the THINK Enterprise version of the database, if applicable, a backup
**	type designator (production, test, conversion, staging, etc), etc.  It can also create the backup name to indicate if the backup contains PCI sensitive data or not, and
**	can also be linked to a specific problem number.  Finally it is possible to indicate how long the backup should be kept.  If set, then this field only indicates how long
**	the backup should be kept, it does not actually enforce any file deletion or cleanup.
**
**	NOTE: the majority of this script was created by Digital River, but standarized, modified, and commented by THINK Subscription.
*/

USE [dbAdmin]
GO

IF EXISTS (SELECT 1 FROM sys.procedures WHERE name = 'sub_backupDatabase')
	DROP PROCEDURE [dbo].[sub_backupDatabase];
GO

CREATE PROCEDURE [dbo].[sub_backupDatabase](
	@backupDbName		nvarchar(128)		--Required:	The name of the database that is going to be backed up.
	,@backupType		nvarchar(4)			--Required:	The backup type to take (full, differential, transaction log).
	,@method			varchar(16)			--Required:	The driver to use to backup the database (native MSSQL or Litespeed).
	,@client			nvarchar(128)		--Required:	The client that this backup belongs to.  Although @client is required it can be set to NULL.
	,@user				nvarchar(64)		--Required:	The user that is performing the backup (a.k.a. who is running the script).
	,@backupThkVersion	nvarchar(32)		--Required:	The THINK Enterprise version of the database being backed up.
	,@backupDbType		char(1)				--Required:	The purpose of the database being backup up (production, testing, conversion, staging, QA, dev, etc).
	,@cleanStatus		char(5)				--Required:	Indicates if the backup has been sanatized of PCI sensitive data.
	,@probNbr			nvarchar(16) = null	--Optional:	A Customer First problem number that this backup is associated to.  This is used as part of the actual filename.
	,@backupRetention	int					--Required:	How long the backup should be kept.  0 indicates it should be kept indefinitely.
	,@backupDebug		nchar(1) = 'n'		--Optional: When set, returns additional debugging information to diagnose errors.
)
AS

DECLARE @fileext			nvarchar(16)	--The file extension that the backup should have.
		,@filepath			nvarchar(1024)	--The full path to the actual backup file, this includes the actual filename.
		,@timestamp			varchar(16)		--The time the backup is taken in server time.  This is included in the filename.
		,@datestamp			varchar(16)		--The date the backup is taken in server time.  This is included in the filename.
		,@count				tinyint			--Counter for any arbitrary number of operations.
		,@countMessage		nvarchar(32)	--Creates a string based on the current backup number over the total backups and puts the string in the actual filename (Ex: "_1_of_2").
		,@backupStmt		nvarchar(2000)	--A portion of the T-SQL backup statement.  This portion executes the actual backup command.
		,@backupFileStmt	nvarchar(4000)	--A portion of the T-SQL backup statement.  This portion points to where the backup will be stored.
		,@backupCommand		nvarchar(4000)	--The entire backup statement.  This is pieced together from other variables.
		,@threshold			decimal(18,1)	--The size (in GB) when another backup file should be created.
		,@result			int				--Used to store the results of the backup operation.
		,@backupPath		nvarchar(1024)	--The path where the backup file will be kept, this does not include the filename.  Pulled from the meta database.
		,@fileCount			tinyint			--The total number of backup files that will be created for the database.
		,@debug				char(1) = 'n'	--Turn on debugging.
		,@auditBackupType	char(1)			--Specifies what should be audited and logged during this backup.
		,@stmt				nvarchar(4000)
		,@printMessage		nvarchar(4000)
		,@errorMessage		varchar(max)
		,@errorSeverity		int
		,@errorNumber		int
		,@errorLine			int
		,@errorState		int;

SET NOCOUNT ON;

BEGIN	

	/*
	**	Convert the case of certain variables so they are always consistent across backups.
	*/
	SET @backupType = LOWER(@backupType);
	SET @method = LOWER(@method);
	SET @debug = LOWER(@debug);
	SET @backupDbType = UPPER(@backupDbType);
	SET @cleanStatus = LOWER(@cleanStatus);

	IF @probNbr is null
		SET @probNbr = '00000'; --If no problem number is provided than set it to a string of zeros.
	
	RAISERROR('Starting database backup:', 10, 1) WITH NOWAIT;

	SET @backupPath = COALESCE(@backupPath, (SELECT p_value FROM dbo.params WHERE p_key = 'DefaultBackupDirectory')); --Pull the backup directory from the meta database.

	IF @backupPath is null
	   RAISERROR('The @backupPath parameter has not been specified and the DefaultBackupDirectory parameter has not been found in dbAdmin.dbo.params.', 16, 1) WITH LOG;

	SET @printMessage = '	Using backup path at: ' + @backupPath;
	RAISERROR(@printMessage, 10, 1) WITH NOWAIT;

	IF (RIGHT(@backupPath, 1) <> '\')
		SET @backupPath = @backupPath + '\'; --Append a backslash to the backup path if it does not already exists

	IF @backupDbName in ('master', 'model', 'msdb')
		SET @method = 'native'; --If backing up a system database than always create a native MSSQL backup.

	SET @timestamp = LEFT(REPLACE(CONVERT(VARCHAR, GETDATE(), 108), ':', ''), 4) + 'MST';
	SET @datestamp = CONVERT(VARCHAR, GETDATE(), 112);

	/*
	**	This portion determines the number of files to use for the backup (a.k.a. multi-file backups).  It creates two temporary tables and determines how many backup files
	**	to create based on how large the actual database is.  For every byte over 100GB of database size the system creates a backup file.  It pulls data using system
	**	functions and places the results in the temp tables.
	*/
	SET @printMessage = '	Determining number of files to use for ' + @backupDbName;
	RAISERROR(@printMessage, 10, 1) WITH NOWAIT;

	SET @threshold = COALESCE( ( SELECT p_value FROM dbo.params WHERE p_key = 'FileCountThreshold' ), 100 ); --Specifies when new backup files should be created based on the database size.

	CREATE TABLE #spaceused(DataGB INT, LogGB INT);
	CREATE TABLE #XpResult(xpresult INT, err INT);

	/*
	**	This statement pulls file property information from the database.  It specifically pulls how large the data and log files are.
	*/
	SET @stmt = N'USE ' + QUOTENAME( @backupDbName ) + N';
				SELECT
				--   db_name() AS DBName, 
				   CEILING( SUM( CASE FILEPROPERTY( name, ''IsLogFile'') WHEN 1 THEN 0 ELSE FILEPROPERTY( name, ''SpaceUsed'' ) END ) / ( 131072.0 ) ) AS [Data_UsedGB], 
				   CEILING( SUM( CASE FILEPROPERTY( name, ''IsLogFile'') WHEN 1 THEN FILEPROPERTY( name, ''SpaceUsed'' ) ELSE 0 END ) / ( 131072.0 ) ) AS [Log_UsedGB]
				FROM dbo.sysfiles'

	INSERT #spaceused
	EXECUTE(@stmt);

	SELECT @fileCount = COALESCE(@fileCount,
								  CASE WHEN @backupType = N'full' THEN CEILING(dataGB/@threshold) --For full backups: determine how many files should be created by taking the data file size divided by the threshold provided.
									   WHEN @backupType = N'log' THEN CEILING(logGB/@threshold) --For transaction log backups: determines how many files to create by taking log file sized dividied by the threshold provided.
									   ELSE 1
								  END, 1)
	FROM #spaceused

	If @fileCount > 64 BEGIN
		SET @fileCount = 64; --SQL Server only handles a maximum of 64 files.  If the data/log size is larger than 64TB (Damn!) than this comes into affect.
	END;

	IF @debug = 'y' BEGIN
		SELECT @method AS 'Method';
	END;

	/*
	**	The the file extension based on how the database is being backed up.
	*/
	IF @method = 'native' 
		SET @fileext  = N'.bak';
	ELSE
		SET @fileext  = N'.sls';

	/*
	**	Create a record in the backup_history table for audit purposes.
	*/
	BEGIN TRAN

		SET @printMessage = '	Recording initial backup information and statistics'
		RAISERROR(@printMessage, 10, 1) WITH NOWAIT;

		SET @auditBackupType = SUBSTRING(@backupType, 1, 1);
		EXEC dbo.sub_auditTrail @auditDbName = @backupDbName, @operationType = 1, @backupType = @auditBackupType

		/*
		**	For each file to create, build the backup filename and backup statement.
		*/
		SET @count = 1;
		WHILE @count <= @fileCount --While there are still filenames and statements to be created.
		BEGIN

			IF @fileCount = 1 
				SET @countMessage = N''; --For the first file in the backup.
			ELSE
				SET @countMessage = N'_' + cast(@count AS NVARCHAR(3)) + N'_of_' + CAST(@fileCount AS NVARCHAR(3) ); --For all others.

			/*
			**	This is the actual filename (including the backup directory).  It is pieced together from other variables.
			*/
			SET @filepath = @backupPath + LOWER(@client) + '_' + LOWER(@user) + '_' + @datestamp + '_' + @timestamp + '_' + @backupThkVersion + '_' + UPPER(@backupDbType) + '_' + LOWER(@cleanStatus) + '_' + @probNbr + @countMessage + @fileext;

			/*
			**	Creates the first part of the backup statement depending on how the database is supposed to be backed up.
			*/
			IF @count = 1 --For the first file in the backup.
			  SET @backupFileStmt =
				CASE
					WHEN @method='native'
						THEN 'TO DISK = ''' + @filepath + ''''
					WHEN @method='litespeed'
						THEN ',@filename = ''' + @filepath + ''''
				END
			ELSE --For all others.
				SET @backupFileStmt = @backupFileStmt + CHAR(10) + 
											CASE
												WHEN @method='native'
													THEN '  ,DISK = ''' + @filepath + ''''
												WHEN @method='litespeed'
													THEN ',@filename = ''' + @filepath + ''''
											END;
			
			SET @printMessage = '	Recording backup file information for backup file number: ' + CAST(@count AS varchar(16))
			RAISERROR(@printMessage, 10, 1) WITH NOWAIT;

			EXEC dbo.sub_auditTrail @auditDbName = @backupDbName, @operationFile = @filepath, @operationType = 3, @backupCounter = @count; --Record the backup settings for audit purposes.
	   
			SELECT @errorNumber = @@error; --This is the old way of detecting errors, you should now use a TRY...CATCH block.
				
			IF @errorNumber <> 0
				GOTO history_tran;

			IF @count = 255 --If, for some reason, @count is absurdly high then just quit to avoid an infinite loop.
				BREAK;

			SET @count = @count + 1;
		END;

	history_tran:
	IF @errorNumber = 0 
	   COMMIT TRANSACTION;
	ELSE
	BEGIN
	   ROLLBACK TRANSACTION;
	   RETURN -1;
	END;

	SET @printMessage = '	Configuring backup statement';
	RAISERROR(@printMessage, 10, 1) WITH NOWAIT;

	/*
	**	Finish creating the backup statement for native backups.
	*/
	IF @method = 'native' 
	BEGIN
		SET @backupStmt =
			CASE
				WHEN @backupType = N'full'
					THEN 'BACKUP DATABASE ' + QUOTENAME(@backupDbName)
				WHEN @backupType = N'diff'
					THEN 'BACKUP DATABASE ' + QUOTENAME(@backupDbName)
				WHEN @backupType = N'log'
					THEN 'BACKUP LOG ' + QUOTENAME(@backupDbName)
			END;
		SET @backupFileStmt = @backupFileStmt + CHAR(10) +
									CASE
										WHEN @backupType = N'diff'
											THEN 'WITH DIFFERENTIAL, CHECKSUM'
										ELSE 'WITH CHECKSUM, STATS = 5'
									END;
	END;

	/*
	**	Finish creating the backup statement for Litespeed backups.
	*/
	IF @method = 'litespeed' 
	BEGIN
		IF (@backupType <> N'log')
			SET @backupStmt = 'declare @result int;exec @result = [master].[dbo].[xp_backup_database]' + CHAR(10) +
								' @database = ' + QUOTENAME(@backupDbName);             
		ELSE
			SET @backupStmt = 'declare @result int;exec @result = [master].[dbo].[xp_backup_log]' + CHAR(10) +
								' @database = ' + QUOTENAME(@backupDbName);
	
		SET @backupFileStmt = @backupFileStmt + CHAR( 10 ) + 
									CASE
										WHEN @backupType = N'diff'
											THEN ',@with = ''CHECKSUM, DIFFERENTIAL''' 
										ELSE ',@with = ''CHECKSUM'''
									END + CHAR(10) + ';' + CHAR(10) + 'INSERT INTO #XpResult VALUES( @result, @@error )';
	END;

	/*
	**	Form the T-SQL backup command and execute.
	*/
	SET @backupCommand = @backupStmt + @backupFileStmt; --Piece together the T-SQL backup command.

	SET @printMessage = '	Backing up the "' + @backupDbName + '" database' + char(13) + char(10) + char(13) + char(10);
	RAISERROR(@printMessage, 10, 1) WITH NOWAIT;

	SET @errorNumber = 0;
	SET @errorMessage = 0;
	BEGIN TRY
	   EXEC(@backupCommand); --Actually runs the backup.
	END TRY
	BEGIN CATCH
		SET @errorNumber = ERROR_NUMBER();
		SET @errorMessage =	'Error: ' + CONVERT( VARCHAR( 50 ), ERROR_NUMBER() ) + CHAR( 13 ) +
						'Description:  ' + ERROR_MESSAGE() + CHAR( 13 ) +
						'Severity: ' + CONVERT( VARCHAR( 5 ), ERROR_SEVERITY() ) + CHAR( 13 ) +
						'State: ' + CONVERT( VARCHAR( 5 ), ERROR_STATE() ) + CHAR( 13 ) +
						'Procedure: ' + COALESCE( ERROR_PROCEDURE(), '-') + CHAR( 13 ) +
						'Line: ' + CONVERT( VARCHAR( 5 ), ERROR_LINE() )  + CHAR( 13 );
	END CATCH;


	SET @printMessage = '';
	RAISERROR(@printMessage, 10, 1) WITH NOWAIT;

	SELECT @result = COALESCE(xpresult, 0) + COALESCE(err, 0) FROM #XpResult;
	RETURN COALESCE(@result, @errorNumber, 0);
END
GO

