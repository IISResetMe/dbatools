function Get-DbaDbExtentDiff {
    <#
        .SYNOPSIS
            What percentage of a database has changed since the last full backup

        .DESCRIPTION
            This is only an implementation of the script created by Paul S. Randal to find what percentage of a database has changed since the last full backup
            https://www.sqlskills.com/blogs/paul/new-script-how-much-of-the-database-has-changed-since-the-last-full-backup/

        .PARAMETER SqlInstance
            The target SQL Server instance

        .PARAMETER SqlCredential
            Allows you to login to servers using SQL Logins as opposed to Windows Auth/Integrated/Trusted. To use:
            $scred = Get-Credential, then pass $scred object to the -SqlCredential parameter.
            To connect as a different Windows user, run PowerShell as that user.

        .PARAMETER Database
            The database(s) to process - this list is auto-populated from the server. If unspecified, all databases will be processed.

        .PARAMETER ExcludeDatabase
            The database(s) to exclude - this list is auto-populated from the server

        .PARAMETER WhatIf
            Shows what would happen if the command were to run. No actions are actually performed.

        .PARAMETER Confirm
            Prompts you for confirmation before executing any changing operations within the command.

        .PARAMETER EnableException
            By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
            This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
            Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

        .NOTES
            Author: Viorel Ciucu, viorel.ciucu@gmail.com, cviorel.com

            Website: https://dbatools.io
            Copyright: (C) Chrissy LeMaire, clemaire@gmail.com
            License: GNU GPL v3 https://opensource.org/licenses/GPL-3.0

        .LINK
            http://dbatools.io/Get-DbaDbExtentDiff

        .EXAMPLE
            Get the changes for the DBA database
            Get-DbaDbExtentDiff -SqlInstance SQL2016 -Database DBA

        .EXAMPLE
            Get the changes for the DB01 database on multiple servers
            Get-DbaDbExtentDiff -SqlInstance $SQL2017N1, $SQL2017N2, $SQL2016 -Database DB01 -SqlCredential $Cred
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
    param (
        [parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [Alias('ServerInstance', 'SqlServer')]
        [DbaInstance[]]$SqlInstance,
        [PSCredential]$SqlCredential,
        [object[]]$Database,
        [object[]]$ExcludeDatabase,
        [switch]$EnableException
    )

    begin {
        $rex = [regex]':(?<extent>[\d]+)\)'
        function Get-DbaExtents ([string[]]$field) {
            $res = 0
            foreach ($f in $field) {
                $extents = $rex.Matches($f)
                if ($extents.Count -eq 1) {
                    $res += 1
                }
                else {
                    $pages = [int]$extents[1].Groups['extent'].Value - [int]$extents[0].Groups['extent'].Value
                    $res += $pages / 8 + 1
                }
            }
            return $res
        }
    }

    process {

        foreach ($instance in $SqlInstance) {
            try {
                Write-Message -Level Verbose -Message "Connecting to $instance"
                $server = Connect-DbaInstance -SqlInstance $instance -SqlCredential $SqlCredential -NonPooled
            }
            catch {
                Stop-Function -Message "Failure" -Category ConnectionError -ErrorRecord $_ -Target $instance -Continue
            }

            $dbs = $server.Databases

            if ($Database) {
                $dbs = $dbs | Where-Object Name -In $Database
            }

            if ($ExcludeDatabase) {
                $dbs = $dbs | Where-Object Name -NotIn $ExcludeDatabase
            }

            $sourcedbs = @()
            foreach ($db in $dbs) {

                if ($db.IsAccessible -ne $true) {
                    Write-Message -Level Verbose -Message "$($db.name) is not accessible on $instance, skipping"
                }
                else {
                    $sourcedbs += $db
                }
            }

            foreach ($db in $sourcedbs) {
                if ($server.VersionMajor -ge 14 ) {
                    $DBCCPageQueryDMV = "
                        SELECT
                        total_page_count / 8 as [ExtentsTotal],
                        modified_extent_page_count / 8 as [ExtentsChanged],
                        (100 * modified_extent_page_count)/total_page_count as [ChangedPerc]
                        FROM sys.dm_db_file_space_usage
                    "

                    #foreach ($db in $MasterFilesGrouped) {
                    #Write-Message -Level Output -Message ":: 2017 - Processing database $db"
                    #foreach ($results in $db.Group) {
                    #$DBCCPageResults = $server.Databases[$($results.dbname)].Query($DBCCPageQueryDMV)
                    $DBCCPageResults = $server.Databases[$($db.Name)].Query($DBCCPageQueryDMV)
                    [pscustomobject]@{
                        ComputerName   = $server.NetName
                        InstanceName   = $server.ServiceName
                        SqlInstance    = $server.DomainInstanceName
                        DatabaseName   = $db.Name
                        ExtentsTotal   = $DBCCPageResults.ExtentsTotal
                        ExtentsChanged = $DBCCPageResults.ExtentsChanged
                        ChangedPerc    = $DBCCPageResults.ChangedPerc
                    }
                    #}
                    #}
                }
                else {
                    $MasterFilesQuery = "
                        SELECT [file_id], [size], database_id, db_name(database_id) as dbname FROM master.sys.master_files
                        WHERE [type_desc] = N'ROWS'
                    "
                    $MasterFiles = $server.Query($MasterFilesQuery)
                    $MasterFiles = $MasterFiles | Where-Object dbname -in $db.Name
                    $MasterFilesGrouped = $MasterFiles | Group-Object -Property dbname

                    foreach ($db in $MasterFilesGrouped) {
                        $sizeTotal = 0
                        foreach ($results in $db.Group) {
                            $extentID = 0
                            $sizeTotal = $sizeTotal + $results.size / 8
                            $dbExtents = @()
                            while ($extentID -lt $results.size) {
                                $pageID = $extentID + 6
                                $DBCCPageQuery = "DBCC PAGE ('$($results.dbname)', $($results.file_id), $pageID, 3)  WITH TABLERESULTS, NO_INFOMSGS"
                                $DBCCPageResults = $server.Query($DBCCPageQuery)
                                $dbExtents += $DBCCPageResults | Where-Object { $_.VALUE -eq '    CHANGED' -And $_.ParentObject -like 'DIFF_MAP*'}
                                $extentID = $extentID + 511232
                            }
                            $extents = Get-DbaExtents $dbExtents.Field
                            [pscustomobject]@{
                                ComputerName   = $server.NetName
                                InstanceName   = $server.ServiceName
                                SqlInstance    = $server.DomainInstanceName
                                DatabaseName   = $db.Name
                                ExtentsTotal   = $sizeTotal
                                ExtentsChanged = $extents
                                ChangedPerc    = [math]::Round(($extents / $sizeTotal * 100), 2)
                            }
                        }
                    }
                }
            }
        }
    }
}