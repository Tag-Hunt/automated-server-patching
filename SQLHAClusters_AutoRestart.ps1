#requires -Modules FailoverClusters

<#
.SYNOPSIS
    Restarts SQL HA cluster nodes one at a time for a supplied cluster set.

.DESCRIPTION
    This script automates a SQL HA patch/restart workflow for any cluster names supplied
    through -ClusterName. For each cluster, the script discovers the current cluster nodes
    and SQL HA role ownership at runtime. Nodes that do not currently own SQL HA roles are
    handled first. If a target node owns a SQL Server or SQL Server Availability Group
    cluster role, the role is moved to another Up node before the target node is
    suspended, drained, and restarted.

    The script uses a high availability strategy:

    - Validate cluster SQL HA resource health before each disruptive action.
    - Prefer the current secondary/passive node as the first restart target.
    - Move SQL HA roles away from a node before rebooting that node.
    - Suspend and drain one cluster node at a time.
    - Wait for the restarted computer to stay online for 3 consecutive minutes by default.
    - Resume the node and confirm it returns to the Up cluster state.
    - Validate AG/resource health after the reboot before moving to the next node.
    - If AG/database health does not recover, recycle MSSQLSERVER and SQLSERVERAGENT on
    the restarted node, then validate health again.

    The script writes timestamped progress logs to the console and to a log file. Each
    node restart workflow logs "Step X/12" so the operator can see exactly where the
    automation is in the process.

    Run with -WhatIf first. The script supports ShouldProcess, so disruptive actions
    such as Move-ClusterGroup, Suspend-ClusterNode, Restart-Computer, Resume-ClusterNode,
    and service starts/stops are skipped during -WhatIf.

.PARAMETER ClusterName
    One or more clusters to process. This parameter is mandatory so the operator must
    explicitly provide the cluster group for each run.

.PARAMETER StableOnlineSeconds
    Number of consecutive seconds the restarted server must respond to ping before the
    script considers it stable. Default is 180 seconds.

.PARAMETER CheckIntervalSeconds
    Number of seconds between polling attempts for server, cluster, service, and HA
    health checks.

.PARAMETER NodeOnlineTimeoutSeconds
    Maximum time to wait for a restarted node to return and stay online.

.PARAMETER ClusterHealthTimeoutSeconds
    Maximum time to wait for cluster SQL HA resource and AG database health checks.

.PARAMETER SqlQueryTimeoutSeconds
    SQL connection and command timeout used for AG DMV checks.

.PARAMETER LogPath
    Full path to the log file. A timestamped log under .\Logs is used by default.

.PARAMETER SkipSqlDatabaseSyncCheck
    Skips SQL DMV database sync validation and only validates cluster SQL HA resource
    health. This is useful when SQL connectivity is unavailable from the operator host,
    but it provides a weaker AG health signal.

.EXAMPLE
    .\SQLHAClusters_AutoRestart.ps1 -ClusterName '<ClusterName1>', '<ClusterName2>' -WhatIf

    Dry-run the workflow for the supplied clusters. This shows the steps and planned
    disruptive actions without moving roles, restarting servers, or changing services.

.EXAMPLE
    .\SQLHAClusters_AutoRestart.ps1 -ClusterName '<ClusterName>'

    Run the workflow against one supplied cluster.

.EXAMPLE
    .\SQLHAClusters_AutoRestart.ps1 -ClusterName '<ClusterName>' -SkipSqlDatabaseSyncCheck

    Run one cluster while checking only cluster SQL HA resource state, similar to the
    AG_state_check.ps1 style of validation.

.NOTES
    Requirements:
    - Run from an elevated PowerShell session.
    - FailoverClusters module must be available.
    - Operator must have rights to query/move cluster roles, suspend/resume nodes,
    restart target computers, manage remote SQL services, and query SQL AG DMVs
    unless -SkipSqlDatabaseSyncCheck is used.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    # The operator must explicitly provide the cluster list for each maintenance run.
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]] $ClusterName,

    # A node must be reachable for this many consecutive seconds after reboot.
    [Parameter()]
    [int] $StableOnlineSeconds = 180,

    # Polling interval for waits. Keep this modest so logs are useful without being noisy.
    [Parameter()]
    [int] $CheckIntervalSeconds = 15,

    # Overall timeout for a rebooted host to come back and pass the stable-online test.
    [Parameter()]
    [int] $NodeOnlineTimeoutSeconds = 1800,

    # Overall timeout for SQL HA resources and AG database state to become healthy.
    [Parameter()]
    [int] $ClusterHealthTimeoutSeconds = 1800,

    # Timeout for each SQL DMV query used to validate AG database state.
    [Parameter()]
    [int] $SqlQueryTimeoutSeconds = 15,

    # Default log file is per-run and timestamped so maintenance windows do not overwrite each other.
    [Parameter()]
    [string] $LogPath = (Join-Path $PSScriptRoot ("Logs\SQLHAClusters_AutoRestart_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))),

    # Use this when the operator workstation can query cluster state but cannot connect to SQL.
    [Parameter()]
    [switch] $SkipSqlDatabaseSyncCheck
)

# Stop on unhandled errors so a failed HA check or failed reboot does not silently
# continue to the next node.
$ErrorActionPreference = 'Stop'

# Store these script-scoped values so helper functions can write to the same log and
# honor -WhatIf/-Confirm through the script-level CmdletBinding.
$script:CommandRuntime = $PSCmdlet
$script:LogPath = $LogPath

function Initialize-Log {
    # Create the log directory on demand. The log file captures the same progress
    # messages shown in the console.
    $logDirectory = Split-Path -Parent $script:LogPath

    if ($logDirectory -and -not (Test-Path -LiteralPath $logDirectory)) {
        New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
    }

    "Log started: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') |
        Set-Content -LiteralPath $script:LogPath
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Message,

        [Parameter()]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string] $Level = 'INFO'
    )

    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $script:LogPath -Value $line
    Write-Host $line
}

function Write-NodeStep {
    # Every node workflow uses the same 12-step structure. These messages are the
    # operator-facing progress markers during a maintenance window.
    param(
        [Parameter(Mandatory = $true)]
        [string] $ClusterName,

        [Parameter(Mandatory = $true)]
        [string] $NodeName,

        [Parameter(Mandatory = $true)]
        [int] $StepNumber,

        [Parameter(Mandatory = $true)]
        [int] $TotalSteps,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    Write-Log -Message ("Cluster {0} | Node {1} | Step {2}/{3}: {4}" -f $ClusterName, $NodeName, $StepNumber, $TotalSteps, $Message)
}

function Invoke-Change {
    # All disruptive actions go through this wrapper so -WhatIf and -Confirm are
    # honored consistently throughout the script.
    param(
        [Parameter(Mandatory = $true)]
        [string] $Target,

        [Parameter(Mandatory = $true)]
        [string] $Action,

        [Parameter(Mandatory = $true)]
        [scriptblock] $ScriptBlock
    )

    if ($script:CommandRuntime.ShouldProcess($Target, $Action)) {
        & $ScriptBlock
    }
    else {
        Write-Log -Message ("WhatIf: skipped action '{0}' on '{1}'." -f $Action, $Target)
    }
}

function Get-ObjectName {
    # Cluster cmdlets sometimes return a rich object and sometimes a string-like value.
    # This normalizes either shape to the actual name used in comparisons and logs.
    param(
        [Parameter()]
        $InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject.PSObject.Properties.Name -contains 'Name') {
        return [string] $InputObject.Name
    }

    return [string] $InputObject
}

function Test-ComputerOnline {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ComputerName
    )

    try {
        return [bool] (Test-Connection -ComputerName $ComputerName -Count 1 -Quiet -ErrorAction SilentlyContinue)
    }
    catch {
        return $false
    }
}

function Wait-ComputerOffline {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ComputerName,

        [Parameter(Mandatory = $true)]
        [int] $TimeoutSeconds,

        [Parameter(Mandatory = $true)]
        [int] $IntervalSeconds
    )

    if ($WhatIfPreference) {
        Write-Log -Message ("WhatIf: skipped waiting for {0} to go offline." -f $ComputerName)
        return
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        if (-not (Test-ComputerOnline -ComputerName $ComputerName)) {
            Write-Log -Message ("{0} is offline." -f $ComputerName)
            return
        }

        Start-Sleep -Seconds $IntervalSeconds
    }

    Write-Log -Level WARN -Message ("{0} was not observed offline within {1} seconds. Continuing to online stability check." -f $ComputerName, $TimeoutSeconds)
}

function Wait-ComputerOnlineStable {
    # A single successful ping is not enough after a reboot. This requires uninterrupted
    # reachability for the configured stability window before cluster operations continue.
    param(
        [Parameter(Mandatory = $true)]
        [string] $ComputerName,

        [Parameter(Mandatory = $true)]
        [int] $StableSeconds,

        [Parameter(Mandatory = $true)]
        [int] $TimeoutSeconds,

        [Parameter(Mandatory = $true)]
        [int] $IntervalSeconds
    )

    if ($WhatIfPreference) {
        Write-Log -Message ("WhatIf: skipped waiting for {0} to remain online for {1} seconds." -f $ComputerName, $StableSeconds)
        return
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $stableStart = $null

    while ((Get-Date) -lt $deadline) {
        if (Test-ComputerOnline -ComputerName $ComputerName) {
            if ($null -eq $stableStart) {
                $stableStart = Get-Date
                Write-Log -Message ("{0} is online. Starting {1}-second stability timer." -f $ComputerName, $StableSeconds)
            }

            $stableDuration = ((Get-Date) - $stableStart).TotalSeconds
            if ($stableDuration -ge $StableSeconds) {
                Write-Log -Message ("{0} stayed online for {1} consecutive seconds." -f $ComputerName, [int] $stableDuration)
                return
            }
        }
        else {
            if ($null -ne $stableStart) {
                Write-Log -Level WARN -Message ("{0} went offline before the stability timer completed. Restarting stability timer." -f $ComputerName)
            }

            $stableStart = $null
        }

        Start-Sleep -Seconds $IntervalSeconds
    }

    throw ("{0} did not stay online for {1} consecutive seconds within {2} seconds." -f $ComputerName, $StableSeconds, $TimeoutSeconds)
}

function Wait-ClusterNodeState {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ClusterName,

        [Parameter(Mandatory = $true)]
        [string] $NodeName,

        [Parameter(Mandatory = $true)]
        [string] $DesiredState,

        [Parameter(Mandatory = $true)]
        [int] $TimeoutSeconds,

        [Parameter(Mandatory = $true)]
        [int] $IntervalSeconds
    )

    if ($WhatIfPreference) {
        Write-Log -Message ("WhatIf: skipped waiting for cluster node {0} to reach state {1}." -f $NodeName, $DesiredState)
        return
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $node = Get-ClusterNode -Cluster $ClusterName -Name $NodeName -ErrorAction Stop

        if ([string] $node.State -eq $DesiredState) {
            Write-Log -Message ("Cluster node {0} is {1}." -f $NodeName, $DesiredState)
            return
        }

        Start-Sleep -Seconds $IntervalSeconds
    }

    throw ("Cluster node {0} did not reach state {1} within {2} seconds." -f $NodeName, $DesiredState, $TimeoutSeconds)
}

function Wait-ServiceState {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ComputerName,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $DesiredState,

        [Parameter(Mandatory = $true)]
        [int] $TimeoutSeconds,

        [Parameter(Mandatory = $true)]
        [int] $IntervalSeconds
    )

    if ($WhatIfPreference) {
        Write-Log -Message ("WhatIf: skipped waiting for service {0} on {1} to reach {2}." -f $Name, $ComputerName, $DesiredState)
        return
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $service = Get-Service -ComputerName $ComputerName -Name $Name -ErrorAction Stop

        if ([string] $service.Status -eq $DesiredState) {
            Write-Log -Message ("Service {0} on {1} is {2}." -f $Name, $ComputerName, $DesiredState)
            return
        }

        Start-Sleep -Seconds $IntervalSeconds
    }

    throw ("Service {0} on {1} did not reach {2} within {3} seconds." -f $Name, $ComputerName, $DesiredState, $TimeoutSeconds)
}

function Stop-RemoteServiceIfRunning {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ComputerName,

        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $service = Get-Service -ComputerName $ComputerName -Name $Name -ErrorAction Stop

    if ([string] $service.Status -eq 'Stopped') {
        Write-Log -Message ("Service {0} on {1} is already stopped." -f $Name, $ComputerName)
        return
    }

    Invoke-Change -Target "$ComputerName\$Name" -Action 'Stop service' -ScriptBlock {
        $service.Stop()
    }

    Wait-ServiceState -ComputerName $ComputerName -Name $Name -DesiredState 'Stopped' -TimeoutSeconds 600 -IntervalSeconds $CheckIntervalSeconds
}

function Start-RemoteServiceIfStopped {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ComputerName,

        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $service = Get-Service -ComputerName $ComputerName -Name $Name -ErrorAction Stop

    if ([string] $service.Status -eq 'Running') {
        Write-Log -Message ("Service {0} on {1} is already running." -f $Name, $ComputerName)
        return
    }

    Invoke-Change -Target "$ComputerName\$Name" -Action 'Start service' -ScriptBlock {
        $service.Start()
    }

    Wait-ServiceState -ComputerName $ComputerName -Name $Name -DesiredState 'Running' -TimeoutSeconds 900 -IntervalSeconds $CheckIntervalSeconds
}

function Restart-SqlServices {
    # This recovery path is used only after the rebooted node is back and HA/database
    # health did not recover on its own.
    param(
        [Parameter(Mandatory = $true)]
        [string] $ComputerName
    )

    Write-Log -Message ("Recycling SQL services on {0}." -f $ComputerName)
    Stop-RemoteServiceIfRunning -ComputerName $ComputerName -Name 'SQLSERVERAGENT'
    Stop-RemoteServiceIfRunning -ComputerName $ComputerName -Name 'MSSQLSERVER'
    Start-RemoteServiceIfStopped -ComputerName $ComputerName -Name 'MSSQLSERVER'
    Start-RemoteServiceIfStopped -ComputerName $ComputerName -Name 'SQLSERVERAGENT'
}

function Get-SqlHaRoleGroup {
    # This is the runtime replacement for hardcoding primary/secondary nodes. Any
    # group containing SQL Server or SQL Server Availability Group resources is treated
    # as a SQL HA role, and its OwnerNode is considered the current primary/owner.
    param(
        [Parameter(Mandatory = $true)]
        [string] $ClusterName
    )

    $roleResourceTypes = @('SQL Server', 'SQL Server Availability Group')
    $healthResourceTypes = @('SQL Server', 'SQL Server Agent', 'SQL Server Availability Group', 'Network Name', 'IP Address')
    $groups = @(Get-ClusterGroup -Cluster $ClusterName -ErrorAction Stop)
    $resources = @(Get-ClusterResource -Cluster $ClusterName -ErrorAction Stop)

    foreach ($group in $groups) {
        $groupResources = @($resources | Where-Object { (Get-ObjectName -InputObject $_.OwnerGroup) -eq $group.Name })
        $roleResources = @($groupResources | Where-Object { [string] $_.ResourceType -in $roleResourceTypes })

        if ($roleResources.Count -eq 0) {
            continue
        }

        [PSCustomObject]@{
            Name            = [string] $group.Name
            OwnerNode       = (Get-ObjectName -InputObject $group.OwnerNode)
            State           = [string] $group.State
            RoleResources   = $roleResources
            HealthResources = @($groupResources | Where-Object { [string] $_.ResourceType -in $healthResourceTypes })
        }
    }
}

function Write-SqlHaClusterState {
    # This mirrors the intent of AG_state_check.ps1, but writes structured status lines
    # into the same automation log instead of only displaying tables in the console.
    param(
        [Parameter(Mandatory = $true)]
        [string] $ClusterName
    )

    $roleGroups = @(Get-SqlHaRoleGroup -ClusterName $ClusterName)

    foreach ($group in $roleGroups) {
        Write-Log -Message ("Cluster {0} | SQL HA group '{1}' | OwnerNode={2} | State={3}" -f $ClusterName, $group.Name, $group.OwnerNode, $group.State)

        foreach ($resource in $group.HealthResources) {
            Write-Log -Message ("Cluster {0} |   Resource '{1}' | Type={2} | State={3}" -f $ClusterName, $resource.Name, $resource.ResourceType, $resource.State)
        }
    }
}

function Test-SqlHaClusterResourceHealth {
    # Cluster-level health check: SQL-related role groups and their key resources must
    # be Online before the script moves on to the next disruptive step.
    param(
        [Parameter(Mandatory = $true)]
        [string] $ClusterName
    )

    $issues = New-Object 'System.Collections.Generic.List[string]'
    $roleGroups = @(Get-SqlHaRoleGroup -ClusterName $ClusterName)

    if ($roleGroups.Count -eq 0) {
        $issues.Add(("Cluster {0} has no SQL Server or SQL Server Availability Group cluster role groups." -f $ClusterName))
    }

    foreach ($group in $roleGroups) {
        if ($group.State -ne 'Online') {
            $issues.Add(("Cluster {0} group '{1}' is {2}." -f $ClusterName, $group.Name, $group.State))
        }

        foreach ($resource in $group.HealthResources) {
            if ([string] $resource.State -ne 'Online') {
                $issues.Add(("Cluster {0} resource '{1}' in group '{2}' is {3}." -f $ClusterName, $resource.Name, $group.Name, $resource.State))
            }
        }
    }

    [PSCustomObject]@{
        IsHealthy  = ($issues.Count -eq 0)
        Issues     = @($issues)
        RoleGroups = $roleGroups
    }
}

function Invoke-SqlQuery {
    # Uses .NET SqlClient instead of requiring the SqlServer PowerShell module on the
    # operator host.
    param(
        [Parameter(Mandatory = $true)]
        [string] $ServerName,

        [Parameter(Mandatory = $true)]
        [string] $Query,

        [Parameter(Mandatory = $true)]
        [int] $TimeoutSeconds
    )

    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = "Data Source=$ServerName;Initial Catalog=master;Integrated Security=SSPI;Connect Timeout=$TimeoutSeconds;Application Name=SqlHaAutoRestart"

    $command = $connection.CreateCommand()
    $command.CommandText = $Query
    $command.CommandTimeout = $TimeoutSeconds

    $table = New-Object System.Data.DataTable

    try {
        $connection.Open()
        $reader = $command.ExecuteReader()
        $table.Load($reader)
    }
    finally {
        if ($reader) {
            $reader.Dispose()
        }

        $command.Dispose()
        $connection.Dispose()
    }

    return @($table.Rows)
}

function Test-SqlDatabaseSyncHealth {
    # SQL-level health check: query each Up node's local AG DMV state. This catches
    # cases where cluster resources are Online but AG databases are suspended, unhealthy,
    # offline, or not moving data.
    param(
        [Parameter(Mandatory = $true)]
        [string] $ClusterName
    )

    $issues = New-Object 'System.Collections.Generic.List[string]'
    $query = @"
IF CONVERT(int, SERVERPROPERTY('IsHadrEnabled')) = 1
BEGIN
    SELECT
        @@SERVERNAME AS ServerName,
        ag.name AS AvailabilityGroupName,
        ar.replica_server_name AS ReplicaServerName,
        adc.database_name AS DatabaseName,
        ISNULL(ars.role_desc, 'UNKNOWN') AS ReplicaRole,
        drs.synchronization_state_desc AS SynchronizationState,
        drs.synchronization_health_desc AS SynchronizationHealth,
        drs.database_state_desc AS DatabaseState,
        drs.is_suspended AS IsSuspended
    FROM sys.dm_hadr_database_replica_states AS drs
    INNER JOIN sys.availability_groups AS ag
        ON ag.group_id = drs.group_id
    INNER JOIN sys.availability_replicas AS ar
        ON ar.group_id = drs.group_id
        AND ar.replica_id = drs.replica_id
    LEFT JOIN sys.dm_hadr_availability_replica_states AS ars
        ON ars.group_id = drs.group_id
        AND ars.replica_id = drs.replica_id
    LEFT JOIN sys.availability_databases_cluster AS adc
        ON adc.group_id = drs.group_id
        AND adc.group_database_id = drs.group_database_id
    WHERE drs.is_local = 1;
END
"@

    $nodes = @(Get-ClusterNode -Cluster $ClusterName -ErrorAction Stop | Where-Object { [string] $_.State -eq 'Up' })
    $checkedAnyDatabase = $false

    foreach ($node in $nodes) {
        $nodeName = [string] $node.Name

        try {
            $sqlService = Get-Service -ComputerName $nodeName -Name 'MSSQLSERVER' -ErrorAction Stop

            if ([string] $sqlService.Status -ne 'Running') {
                $issues.Add(("MSSQLSERVER on {0} is {1}." -f $nodeName, $sqlService.Status))
                continue
            }

            $rows = @(Invoke-SqlQuery -ServerName $nodeName -Query $query -TimeoutSeconds $SqlQueryTimeoutSeconds)

            if ($rows.Count -eq 0) {
                $issues.Add(("SQL database sync check on {0} returned no local AG database rows." -f $nodeName))
                continue
            }

            $checkedAnyDatabase = $true

            foreach ($row in $rows) {
                $syncState = [string] $row.SynchronizationState
                $syncHealth = [string] $row.SynchronizationHealth
                $databaseState = [string] $row.DatabaseState
                $isSuspended = [int] $row.IsSuspended

                if ($syncHealth -ne 'HEALTHY' -or
                    $databaseState -ne 'ONLINE' -or
                    $isSuspended -ne 0 -or
                    $syncState -notin @('SYNCHRONIZED', 'SYNCHRONIZING')) {
                    $issues.Add(("SQL AG database state is not healthy. Server={0}; AG={1}; Replica={2}; Database={3}; Role={4}; SyncState={5}; SyncHealth={6}; DatabaseState={7}; IsSuspended={8}" -f `
                        $row.ServerName,
                        $row.AvailabilityGroupName,
                        $row.ReplicaServerName,
                        $row.DatabaseName,
                        $row.ReplicaRole,
                        $syncState,
                        $syncHealth,
                        $databaseState,
                        $isSuspended))
                }
            }
        }
        catch {
            $issues.Add(("SQL database sync check failed on {0}: {1}" -f $nodeName, $_.Exception.Message))
        }
    }

    if (-not $checkedAnyDatabase) {
        $issues.Add(("No AG database sync rows were verified for cluster {0}." -f $ClusterName))
    }

    [PSCustomObject]@{
        IsHealthy = ($issues.Count -eq 0)
        Issues    = @($issues)
    }
}

function Test-HaHealth {
    # Combines the cluster-resource check with the optional SQL DMV database sync check.
    # Both must be clean before HA is considered good.
    param(
        [Parameter(Mandatory = $true)]
        [string] $ClusterName
    )

    $issues = New-Object 'System.Collections.Generic.List[string]'
    $clusterResourceHealth = Test-SqlHaClusterResourceHealth -ClusterName $ClusterName

    foreach ($issue in $clusterResourceHealth.Issues) {
        $issues.Add($issue)
    }

    if (-not $SkipSqlDatabaseSyncCheck) {
        $sqlDatabaseHealth = Test-SqlDatabaseSyncHealth -ClusterName $ClusterName

        foreach ($issue in $sqlDatabaseHealth.Issues) {
            $issues.Add($issue)
        }
    }

    [PSCustomObject]@{
        IsHealthy = ($issues.Count -eq 0)
        Issues    = @($issues)
    }
}

function Wait-HaHealth {
    # HA checks can lag immediately after failover, resume, or reboot. This retries until
    # health is clean or the timeout expires.
    param(
        [Parameter(Mandatory = $true)]
        [string] $ClusterName,

        [Parameter(Mandatory = $true)]
        [string] $Purpose,

        [Parameter(Mandatory = $true)]
        [int] $TimeoutSeconds,

        [Parameter(Mandatory = $true)]
        [int] $IntervalSeconds
    )

    if ($WhatIfPreference) {
        Write-Log -Message ("WhatIf: skipped HA health wait for cluster {0}. Purpose: {1}" -f $ClusterName, $Purpose)
        return $true
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $health = Test-HaHealth -ClusterName $ClusterName

        if ($health.IsHealthy) {
            Write-Log -Message ("Cluster {0} HA health is good. Purpose: {1}" -f $ClusterName, $Purpose)
            Write-SqlHaClusterState -ClusterName $ClusterName
            return $true
        }

        Write-Log -Level WARN -Message ("Cluster {0} HA health is not ready for '{1}'. Issues: {2}" -f $ClusterName, $Purpose, ($health.Issues -join ' | '))
        Start-Sleep -Seconds $IntervalSeconds
    }

    Write-Log -Level ERROR -Message ("Cluster {0} HA health did not become good within {1} seconds. Purpose: {2}" -f $ClusterName, $TimeoutSeconds, $Purpose)
    return $false
}

function Assert-ClusterReady {
    # Initial guardrail before any maintenance starts. If the cluster already has a down
    # node or unhealthy SQL HA resources, the script stops instead of reducing redundancy.
    param(
        [Parameter(Mandatory = $true)]
        [string] $ClusterName
    )

    $nodes = @(Get-ClusterNode -Cluster $ClusterName -ErrorAction Stop)

    if ($nodes.Count -lt 2) {
        throw ("Cluster {0} has fewer than two nodes. Aborting to protect high availability." -f $ClusterName)
    }

    $notUp = @($nodes | Where-Object { [string] $_.State -ne 'Up' })

    if ($notUp.Count -gt 0) {
        throw ("Cluster {0} has nodes that are not Up: {1}. Aborting to protect high availability." -f $ClusterName, (($notUp | ForEach-Object { "{0}={1}" -f $_.Name, $_.State }) -join ', '))
    }

    $health = Test-SqlHaClusterResourceHealth -ClusterName $ClusterName

    if (-not $health.IsHealthy) {
        throw ("Cluster {0} SQL HA cluster resource health is not good before automation starts: {1}" -f $ClusterName, ($health.Issues -join ' | '))
    }
}

function Get-NextTargetNode {
    # Scheduling rule: restart secondary/passive nodes first. If all remaining nodes own
    # SQL HA roles, choose an owner node and move its roles away before rebooting it.
    param(
        [Parameter(Mandatory = $true)]
        [string] $ClusterName,

        [Parameter(Mandatory = $true)]
        [hashtable] $ProcessedNodes
    )

    $nodes = @(Get-ClusterNode -Cluster $ClusterName -ErrorAction Stop | Sort-Object Name)
    $roleGroups = @(Get-SqlHaRoleGroup -ClusterName $ClusterName)
    $ownerNodes = @($roleGroups | ForEach-Object { [string] $_.OwnerNode } | Sort-Object -Unique)
    $remainingNodes = @($nodes | Where-Object { -not $ProcessedNodes.ContainsKey([string] $_.Name) })

    if ($remainingNodes.Count -eq 0) {
        return $null
    }

    $secondaryNodes = @($remainingNodes | Where-Object { [string] $_.Name -notin $ownerNodes })

    if ($secondaryNodes.Count -gt 0) {
        return $secondaryNodes[0]
    }

    return $remainingNodes[0]
}

function Move-SqlRolesOffNode {
    # HA protection before reboot: if the target node owns SQL HA roles, move each role
    # to another Up node and verify the target no longer owns SQL HA roles.
    param(
        [Parameter(Mandatory = $true)]
        [string] $ClusterName,

        [Parameter(Mandatory = $true)]
        [string] $NodeName
    )

    $ownedGroups = @(Get-SqlHaRoleGroup -ClusterName $ClusterName | Where-Object { $_.OwnerNode -eq $NodeName })

    if ($ownedGroups.Count -eq 0) {
        Write-Log -Message ("Node {0} owns no SQL HA groups in cluster {1}; it is currently secondary/passive for SQL HA roles." -f $NodeName, $ClusterName)
        return
    }

    $destination = Get-ClusterNode -Cluster $ClusterName -ErrorAction Stop |
        Where-Object { [string] $_.Name -ne $NodeName -and [string] $_.State -eq 'Up' } |
        Sort-Object Name |
        Select-Object -First 1

    if ($null -eq $destination) {
        throw ("Cluster {0} has no Up destination node available for moving SQL HA roles off {1}." -f $ClusterName, $NodeName)
    }

    foreach ($group in $ownedGroups) {
        Write-Log -Message ("Moving SQL HA group '{0}' from {1} to {2} before node restart." -f $group.Name, $NodeName, $destination.Name)

        Invoke-Change -Target "$ClusterName\$($group.Name)" -Action ("Move cluster group to {0}" -f $destination.Name) -ScriptBlock {
            Move-ClusterGroup -Cluster $ClusterName -Name $group.Name -Node $destination.Name -Wait 300 -ErrorAction Stop | Out-Null
        }
    }

    Wait-SqlRolesOffNode -ClusterName $ClusterName -NodeName $NodeName -TimeoutSeconds $ClusterHealthTimeoutSeconds -IntervalSeconds $CheckIntervalSeconds
}

function Wait-SqlRolesOffNode {
    # Rebooting a node while it still owns SQL HA roles would violate the maintenance
    # strategy. This wait enforces that the target is not the SQL role owner.
    param(
        [Parameter(Mandatory = $true)]
        [string] $ClusterName,

        [Parameter(Mandatory = $true)]
        [string] $NodeName,

        [Parameter(Mandatory = $true)]
        [int] $TimeoutSeconds,

        [Parameter(Mandatory = $true)]
        [int] $IntervalSeconds
    )

    if ($WhatIfPreference) {
        Write-Log -Message ("WhatIf: skipped waiting for SQL HA roles to leave node {0}." -f $NodeName)
        return
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $ownedGroups = @(Get-SqlHaRoleGroup -ClusterName $ClusterName | Where-Object { $_.OwnerNode -eq $NodeName })

        if ($ownedGroups.Count -eq 0) {
            Write-Log -Message ("Node {0} owns no SQL HA groups in cluster {1}." -f $NodeName, $ClusterName)
            return
        }

        Start-Sleep -Seconds $IntervalSeconds
    }

    throw ("SQL HA groups are still owned by {0} after {1} seconds. Aborting before reboot." -f $NodeName, $TimeoutSeconds)
}

function Invoke-NodeRestartWorkflow {
    # One complete node maintenance cycle. The sequence is intentionally conservative:
    # validate, move/drain, reboot, wait for stability, resume, validate again, then
    # recycle SQL services only if health does not recover.
    param(
        [Parameter(Mandatory = $true)]
        [string] $ClusterName,

        [Parameter(Mandatory = $true)]
        [string] $NodeName
    )

    $totalSteps = 12
    $step = 0

    $step++
    Write-NodeStep -ClusterName $ClusterName -NodeName $NodeName -StepNumber $step -TotalSteps $totalSteps -Message 'Refresh role ownership and identify current node role.'
    Write-SqlHaClusterState -ClusterName $ClusterName
    $targetOwnedGroups = @(Get-SqlHaRoleGroup -ClusterName $ClusterName | Where-Object { $_.OwnerNode -eq $NodeName })

    if ($targetOwnedGroups.Count -gt 0) {
        Write-Log -Message ("Node {0} is currently primary/owner for SQL HA groups: {1}" -f $NodeName, (($targetOwnedGroups | ForEach-Object { $_.Name }) -join ', '))
    }
    else {
        Write-Log -Message ("Node {0} is currently secondary/passive for SQL HA cluster roles." -f $NodeName)
    }

    $step++
    Write-NodeStep -ClusterName $ClusterName -NodeName $NodeName -StepNumber $step -TotalSteps $totalSteps -Message 'Verify HA health before making changes.'
    if (-not (Wait-HaHealth -ClusterName $ClusterName -Purpose "pre-restart validation for $NodeName" -TimeoutSeconds $ClusterHealthTimeoutSeconds -IntervalSeconds $CheckIntervalSeconds)) {
        throw ("Cluster {0} is not healthy before restarting {1}. Aborting." -f $ClusterName, $NodeName)
    }

    $step++
    Write-NodeStep -ClusterName $ClusterName -NodeName $NodeName -StepNumber $step -TotalSteps $totalSteps -Message 'Move SQL HA roles away from target node if it owns any.'
    Move-SqlRolesOffNode -ClusterName $ClusterName -NodeName $NodeName

    $step++
    Write-NodeStep -ClusterName $ClusterName -NodeName $NodeName -StepNumber $step -TotalSteps $totalSteps -Message 'Suspend and drain target cluster node.'
    Invoke-Change -Target "$ClusterName\$NodeName" -Action 'Suspend cluster node with drain' -ScriptBlock {
        Suspend-ClusterNode -Cluster $ClusterName -Name $NodeName -Drain -ErrorAction Stop | Out-Null
    }
    Wait-ClusterNodeState -ClusterName $ClusterName -NodeName $NodeName -DesiredState 'Paused' -TimeoutSeconds 600 -IntervalSeconds $CheckIntervalSeconds

    $step++
    Write-NodeStep -ClusterName $ClusterName -NodeName $NodeName -StepNumber $step -TotalSteps $totalSteps -Message 'Confirm target owns no SQL HA roles before reboot.'
    Wait-SqlRolesOffNode -ClusterName $ClusterName -NodeName $NodeName -TimeoutSeconds $ClusterHealthTimeoutSeconds -IntervalSeconds $CheckIntervalSeconds
    if (-not (Wait-HaHealth -ClusterName $ClusterName -Purpose "post-drain validation for $NodeName" -TimeoutSeconds $ClusterHealthTimeoutSeconds -IntervalSeconds $CheckIntervalSeconds)) {
        throw ("Cluster {0} is not healthy after draining {1}. Aborting before reboot." -f $ClusterName, $NodeName)
    }

    $step++
    Write-NodeStep -ClusterName $ClusterName -NodeName $NodeName -StepNumber $step -TotalSteps $totalSteps -Message 'Stop SQL Server services on target node.'
    Stop-RemoteServiceIfRunning -ComputerName $NodeName -Name 'SQLSERVERAGENT'
    Stop-RemoteServiceIfRunning -ComputerName $NodeName -Name 'MSSQLSERVER'

    $step++
    Write-NodeStep -ClusterName $ClusterName -NodeName $NodeName -StepNumber $step -TotalSteps $totalSteps -Message 'Restart target node.'
    Invoke-Change -Target $NodeName -Action 'Restart computer' -ScriptBlock {
        Restart-Computer -ComputerName $NodeName -Force -ErrorAction Stop
    }

    $step++
    Write-NodeStep -ClusterName $ClusterName -NodeName $NodeName -StepNumber $step -TotalSteps $totalSteps -Message 'Wait for reboot outage to begin.'
    Wait-ComputerOffline -ComputerName $NodeName -TimeoutSeconds 600 -IntervalSeconds $CheckIntervalSeconds

    $step++
    Write-NodeStep -ClusterName $ClusterName -NodeName $NodeName -StepNumber $step -TotalSteps $totalSteps -Message ("Wait for target to stay online for {0} consecutive seconds." -f $StableOnlineSeconds)
    Wait-ComputerOnlineStable -ComputerName $NodeName -StableSeconds $StableOnlineSeconds -TimeoutSeconds $NodeOnlineTimeoutSeconds -IntervalSeconds $CheckIntervalSeconds

    $step++
    Write-NodeStep -ClusterName $ClusterName -NodeName $NodeName -StepNumber $step -TotalSteps $totalSteps -Message 'Resume target cluster node and wait for Up state.'
    Invoke-Change -Target "$ClusterName\$NodeName" -Action 'Resume cluster node' -ScriptBlock {
        Resume-ClusterNode -Cluster $ClusterName -Name $NodeName -ErrorAction Stop | Out-Null
    }
    Wait-ClusterNodeState -ClusterName $ClusterName -NodeName $NodeName -DesiredState 'Up' -TimeoutSeconds 900 -IntervalSeconds $CheckIntervalSeconds

    $step++
    Write-NodeStep -ClusterName $ClusterName -NodeName $NodeName -StepNumber $step -TotalSteps $totalSteps -Message 'Start and verify SQL Server services.'
    Start-RemoteServiceIfStopped -ComputerName $NodeName -Name 'MSSQLSERVER'
    Start-RemoteServiceIfStopped -ComputerName $NodeName -Name 'SQLSERVERAGENT'

    $step++
    Write-NodeStep -ClusterName $ClusterName -NodeName $NodeName -StepNumber $step -TotalSteps $totalSteps -Message 'Validate HA health and recover SQL services if AG state is not healthy.'
    if (-not (Wait-HaHealth -ClusterName $ClusterName -Purpose "post-restart validation for $NodeName" -TimeoutSeconds $ClusterHealthTimeoutSeconds -IntervalSeconds $CheckIntervalSeconds)) {
        Write-Log -Level WARN -Message ("Cluster {0} did not report healthy AG/SQL state after restarting {1}. Recycling SQL services on the restarted node." -f $ClusterName, $NodeName)
        Restart-SqlServices -ComputerName $NodeName

        if (-not (Wait-HaHealth -ClusterName $ClusterName -Purpose "post-SQL-service-recycle validation for $NodeName" -TimeoutSeconds $ClusterHealthTimeoutSeconds -IntervalSeconds $CheckIntervalSeconds)) {
            throw ("Cluster {0} is still not healthy after recycling SQL services on {1}. Aborting." -f $ClusterName, $NodeName)
        }
    }

    Write-Log -Message ("Completed restart workflow for node {0} in cluster {1}." -f $NodeName, $ClusterName)
}

function Invoke-ClusterRestartWorkflow {
    # Runs the node workflow for one cluster. The node order is recalculated after each
    # reboot because role ownership can change after failover or resume.
    param(
        [Parameter(Mandatory = $true)]
        [string] $ClusterName
    )

    Write-Log -Message ("Starting automated restart workflow for cluster {0}." -f $ClusterName)
    Assert-ClusterReady -ClusterName $ClusterName

    if (-not (Wait-HaHealth -ClusterName $ClusterName -Purpose 'cluster start validation' -TimeoutSeconds $ClusterHealthTimeoutSeconds -IntervalSeconds $CheckIntervalSeconds)) {
        throw ("Cluster {0} is not healthy at workflow start. Aborting." -f $ClusterName)
    }

    $processedNodes = @{}

    while ($true) {
        $nextNode = Get-NextTargetNode -ClusterName $ClusterName -ProcessedNodes $processedNodes

        if ($null -eq $nextNode) {
            break
        }

        Invoke-NodeRestartWorkflow -ClusterName $ClusterName -NodeName ([string] $nextNode.Name)
        $processedNodes[[string] $nextNode.Name] = $true
    }

    Write-Log -Message ("Completed automated restart workflow for cluster {0}." -f $ClusterName)
}

# Entry point. Everything above this line defines helpers; actual work starts here.
Initialize-Log
Import-Module FailoverClusters -ErrorAction Stop

Write-Log -Message ("SQL HA automated restart started. Clusters: {0}" -f ($ClusterName -join ', '))
Write-Log -Message ("Log path: {0}" -f $script:LogPath)

if ($SkipSqlDatabaseSyncCheck) {
    Write-Log -Level WARN -Message 'SQL DMV database sync validation is disabled. Cluster resource health will still be validated.'
}

foreach ($cluster in $ClusterName) {
    Invoke-ClusterRestartWorkflow -ClusterName $cluster
}

Write-Log -Message 'SQL HA automated restart completed.'
