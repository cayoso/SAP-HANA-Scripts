<#
.Notes
NAME: New-StorageSnapshot
AUTHOR: Andrew Sillifant
Website: https://www.purestorage.com/
Version: 0.2
CREATED: 2020/07/04
LASTEDIT: 2020/30/05

 .Synopsis
Provides and easy to use single command for the creating of application consistent 
storage snapshots between SAP HANA and Pure Storage Flash Array

.Description
Create an application consistent storage snapshot for an SAP HANA Scale Up System

.Parameter HostAddress
The IPv4 or V6 address of the SAP HANA host 

.Parameter InstanceNumber
The instance number of the SAP HANA deployment

.Parameter DatabaseName
The database name of the SAP HANA deployment 

.Parameter DatabaseUser
A database user with permissions to either SYSTEMDB or the ability to create storage snapshots 
and view the SAP HANA global.ini file

.Parameter DatabasePassword
The database password that matches to DatabaseUser

.Parameter DatabasePort
The Port of the SAP HANA database , in MDC environments 

.Parameter OperatingSystemUser
An operating system user with permissions to freeze and unfreeze the SAP HANA Data volume

.Parameter OperatingSystemPassword
The password for the user specified in OperatingSystemUser

.Parameter PureFlashArrayAddress
The Pure storage FlashArray which the SAP HANA deployment resides on

.Parameter PureFlashArrayUser
A user for the Pure storage FlashArray with permissions to create snapshots and view volumes

.Parameter PureFlashArrayPassword
The password for the user specified in PureFlashArrayUser

.Parameter CrashConsistentSnapshot
If this parameter is specified then the a snapshot of both the 
log and data volume will be created without preparing the database
If this is not wspecified the snapshot will be created as application consistent

.Example
New-StorageSnapshot -HostAddress <IP address of host> -InstanceNumber <Instance Number (00)> 
-DatabaseName <Database Name (HN1)> -DatabaseUser <DBUser> 
-OperatingSystemUser <OS-User> -PureFlashArrayAddress <Pure FlashArray IP or hostname> 
-PureFlashArrayUser <pure FA User> -DatabasePort <Port>
Create an application consistent snapshot without entering information for the password fields

.Example
New-StorageSnapshot -HostAddress <IP address of host> -InstanceNumber <Instance Number (00)> 
-DatabaseName <Database Name (HN1)> -DatabaseUser <DBUser> -DatabasePassword <DBPassword> 
-OperatingSystemUser <OS-User> -OperatingSystemPassword <OSPassword>
-PureFlashArrayAddress <Pure FlashArray IP or hostname> -PureFlashArrayUser <pure FA User>
-PureFlashArrayPassword <Pure FA Password>
-DatabasePort <Port>
Create an application consistent snapshot with all of the password fields being shown as plaintext 

.Example
New-StorageSnapshot -HostAddress <IP address of host> -InstanceNumber <Instance Number (00)> 
-DatabaseName <Database Name (HN1)> -DatabaseUser <DBUser> 
-OperatingSystemUser <OS-User> -PureFlashArrayAddress <Pure FlashArray IP or hostname> 
-PureFlashArrayUser <pure FA User> -DatabasePort <Port> -CrashConsistentSnapshot
Create a crash consistent snapshot without entering information for the password fields

#>

################################
#           Parameters         #
################################

Param(
    [parameter(Mandatory=$True)]
    [string]$HostAddress,
    [parameter(,Mandatory=$True)]
    [string]$InstanceNumber,
    [parameter(Mandatory=$False)]
    [string]$DatabaseName,
    [parameter(Mandatory=$True)]
    [string]$DatabaseUser,
    [Parameter(Mandatory=$False)]
    $DatabasePassword,
    [Parameter(Mandatory=$True)]
    $DatabasePort,
    [parameter(Mandatory=$True)]
    [string]$OperatingSystemUser,
    [Parameter(Mandatory=$False)]
    $OperatingSystemPassword,
    [parameter(Mandatory=$True)]
    [string]$PureFlashArrayAddress,
    [parameter(Mandatory=$True)]
    [string]$PureFlashArrayUser,
    [Parameter(Mandatory=$False)]
    $PureFlashArrayPassword,
    [Parameter(Mandatory=$False)]
    [switch]$CrashConsistentSnapshot
)


################################
#       Default Values for     #
#       optional parameters    #
#       and prompt functions   #
################################

function AskSecureQ ([String]$Question, [String]$Foreground="Yellow", [String]$Background="Blue") {
    Write-Host $Question -ForegroundColor $Foreground -BackgroundColor $Background -NoNewLine
    Return (Read-Host -AsSecureString)
}

function AskInSecureQ ([String]$Question, [String]$Foreground="Yellow", [String]$Background="Blue") {
    Write-Host $Question -ForegroundColor $Foreground -BackgroundColor $Background -NoNewLine
    $plainTextEncrypted = Read-Host -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($plainTextEncrypted)
    $plaintext = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    return $plaintext
}

function Check-Arguments()
{
    if ($DatabasePassword -ne $null) 
    {
        $script:DatabasePassword = $DatabasePassword 
    } 
    else 
    {
        $script:DatabasePassword = AskInSecureQ "Type in Database password "
    }
    if ($OperatingSystemPassword -ne $null)
    {
        $script:OperatingSystemPassword =  ConvertTo-SecureString -String $OperatingSystemPassword `
        -AsPlainText -Force
    } 
    else 
    {
        $script:OperatingSystemPassword = AskSecureQ "Type in Operating System password"
    }
    if ($PureFlashArrayPassword -ne $null) 
    {
        $script:PureFlashArrayPassword = ConvertTo-SecureString -String $PureFlashArrayPassword `
        -AsPlainText -Force
    } 
    else 
    {
        $script:PureFlashArrayPassword = AskSecureQ "Type in FlashArray password"
    }
}

################################
#   Static non-public values   #
################################

$SnapshotTime = "{0:yyyy-MM-dd HH:mm:ss}" -f (get-date)
$GetSAPAHANASystemType = "SELECT VALUE FROM M_INIFILE_CONTENTS WHERE FILE_NAME = 'global.ini' `
AND SECTION = 'multidb' AND KEY = 'mode'"
$GetSAPHANAInstanceID = "SELECT VALUE from SYS.M_SYSTEM_OVERVIEW WHERE NAME = 'Instance ID'"
$GetDataVolumeLocation = "SELECT VALUE FROM M_INIFILE_CONTENTS WHERE FILE_NAME = 'global.ini' `
AND SECTION = 'persistence' AND KEY = 'basepath_datavolumes'  AND VALUE NOT LIKE '$%'"
$GetPersistenceVolumesLocation = "SELECT VALUE,KEY FROM M_INIFILE_CONTENTS WHERE FILE_NAME = 'global.ini'
AND SECTION = 'persistence' AND (KEY = 'basepath_datavolumes' OR KEY = 'basepath_logvolumes') AND VALUE NOT LIKE '$%'"
$CreateHDBStorageSnapshot = "BACKUP DATA FOR FULL SYSTEM CREATE SNAPSHOT COMMENT 'SNAPSHOT-" + `
$SnapshotTime +"';"
$RetrieveHDBSnapshotID = "SELECT BACKUP_ID, COMMENT FROM M_BACKUP_CATALOG WHERE ENTRY_TYPE_NAME `
= 'data snapshot' AND STATE_NAME = 'prepared' AND COMMENT = 'SNAPSHOT-" + $SnapshotTime +"';"
$multiDB = $false

  
function Check-ForPrerequisites()
{
    $hdbODBCCheck =  Get-OdbcDriver | Where-Object Name -EQ 'HDBODBC'
    if($hdbODBCCheck -eq $null)
    {
        Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
        Write-host "`t`t|       Please install the SAP HANA client       |" -ForegroundColor White
        Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
        return $false
    }
    else
    {
        if( $PSVersiontable.PSVersion.Major -lt 3) {
            Write-Host "`t`t ------------------------------------------------ " -ForegroundColor Red
            Write-host "`t`t|This script requires minimum of PowerShell v3.0 |" -ForegroundColor Red
            Write-Host "`t`t ------------------------------------------------ " -ForegroundColor Red
            return $false
        }
        else
        {
            ##Check for required libraries for SSH and Pure Storage SDK
            Check-ForPOSH-SSH
            Check-ForPureStorageSDK
            return $true
        }
    }
}
  
function Check-ForPOSH-SSH()
{
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    $poshSSHCHeck = Get-Module -Name Posh-SSH
    if($poshSSHCHeck -eq $null)
    {
        Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
        Write-host "`t`t|              Installing POSH-SSH               |" -ForegroundColor White
        Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
        Install-Module -Name Posh-SSH   
    }
    else
    {
        Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
        Write-host "`t`t|           POSH-SSH already installed           |" -ForegroundColor White
        Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White

    }
    Import-Module Posh-SSH
}
  
function Check-ForPureStorageSDK()
{
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    $pureSTorageSDKCheck = Get-Module -Name PureStoragePowerShellSDK
    if($pureSTorageSDKCheck -eq $null)
    {
        Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
        Write-host "`t`t|     Installing Pure Storage Powershell SDK     |" -ForegroundColor White
        Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
        Install-Module PureStoragePowerShellSDK
    }
    else
    {
        Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
        Write-host "`t`t|  Pure Storage Powershell SDK already installed |" -ForegroundColor White
        Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
    }
    Import-Module PureStoragePowerShellSDK
}
  
function Get-ODBCData() 
{
    Param($hanaConnectionString,
    $hdbsql)
  
    $Conn = New-Object System.Data.Odbc.OdbcConnection($hanaCOnnectionString)
    $Conn.open()
    $readcmd = New-Object System.Data.Odbc.OdbcCommand($hdbsql,$Conn)
    $readcmd.CommandTimeout = '300'
    $da = New-Object System.Data.Odbc.OdbcDataAdapter($readcmd)
    $dt = New-Object System.Data.DataTable
    [void]$da.fill($dt)
    $Conn.close()
    return $dt
}
  
function Check-SAPHANASystemType()
{
    $systemtype = Get-ODBCData -hanaConnectionString $hdbConnectionString -hdbsql $GetSAPAHANASystemType
    return $systemtype
}
  
function Get-VolumeSerialNumber()
{
    Param(
        $HostAddress,
        $DataVolumeMountPoint,
        $OSUser,
        $OSPassword
    )
    $Cred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $OSUser, $OSPassword
          
    $sessionval = New-SSHSession -ComputerName $HostAddress -Credential $Cred -AcceptKey:$True -ConnectionTimeout 600
    $session = Get-SSHSession -SessionId $sessionval.SessionId
    $stream = $session.Session.CreateShellStream("dumb", 0, 0, 0, 0, 1000)
    Start-Sleep -Seconds 1
    $output = $stream.Read()
    $stream.WriteLine("df -h | grep " + $DataVolumeMountPoint)
    $output = $stream.Readline()
    $dfToParse = $stream.ReadLine()
    $ParsedVolumeDevLocation = [regex]::Match($dfToParse, '(\S+)').Groups[1].Value
    $udevADMQuery = "udevadm info --query=all --name=" + $ParsedVolumeDevLocation + " | grep DM_SERIAL"
    $stream.WriteLine($udevADMQuery)
    $output = $stream.ReadLine()
    $queryResponse = $stream.ReadLine()
    $volSerialNumber = ($queryResponse.split('='))[1]
    $output =  Remove-SSHSession -SessionId $sessionval.SessionId
    return $volSerialNumber
}
  
function Create-PureStorageVolumeSnapshot()
{
    Param(
        $FlashArrayAddress, 
        $User, 
        $Password,
        $SerialNumber, 
        $SnapshotSuffix
    )
  
    $Array = New-PfaArray -EndPoint $FlashArrayAddress -username $User -Password $Password -IgnoreCertificateError
    $Volumes = Get-PfaVolumes -Array $Array 
  
    foreach($vol in $Volumes)
    {
        if($serialNumber.Contains($vol.serial.tolower()))
        {
            Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
            Write-host "`t`t|        Volume located , creating snapshot      |" -ForegroundColor White
            Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
            $VolumeSnapshot = New-PfaVolumeSnapshots -Array $Array -Sources $vol.name -Suffix $SnapshotSuffix
            if(!($VolumeSnapshot.name -eq $null))
            {
                Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
                Write-host "`t`t|                   Snapshot name :              |" -ForegroundColor White
                Write-host "`t`t      "           $VolumeSnapshot.name                  -ForegroundColor White
                Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White

                return $VolumeSnapshot.serial
            }
            else
            {
                Write-Host "`t`t ------------------------------------------------ " -ForegroundColor Red
                Write-host "`t`t|           Volume has not been found            |" -ForegroundColor Red
                Write-Host "`t`t ------------------------------------------------ " -ForegroundColor Red
                return $null
            }
        }
    }
}

function Create-PureStoragePGSnapshot()
{
    Param(
        $FlashArrayAddress, 
        $User, 
        $Password,
        $PGName
    )
  
    $Array = New-PfaArray -EndPoint $FlashArrayAddress -username $User -Password $Password -IgnoreCertificateError
    New-PfaProtectionGroupSnapshot -Array $Array -Protectiongroupname $PGName
}

function Check-PureStoragePG()
{
    Param(
        $FlashArrayAddress, 
        $User, 
        $Password,
        $PersistenceInfo,
        $PGName
    )

    $Array = New-PfaArray -EndPoint $FlashArrayAddress -username $User -Password $Password -IgnoreCertificateError
    
    $ProtectionGroups = Get-PfaProtectionGroup -Array $Array -Name $PGName -ErrorAction SilentlyContinue
    if($ProtectionGroups -eq $null)
    {
        $Output = New-PfaProtectionGroup -Array $Array -Name $PGName
    }

    $Volumes = Get-PfaVolumes -Array $Array

    $PersistenceInfoWithVolNames = @()
    foreach($device in $PersistenceInfo)
    {
        foreach($vol in $Volumes)
        {
            if($device.SerialNumber.Contains($vol.serial.tolower()))
            {
               $PFAPG = Get-PfaVolumeProtectionGroups -Array $Array -VolumeName $vol.name 
               [int]$PGcount = 0
               if($PFSAPG -ne "")
               {
                    
                    foreach($pg in $PFAPG)
                    {
                        if($pg.name -eq $PGName)
                        {
                            $PGcount++
                        }
                    }    
                }
                $device | Add-Member -MemberType NoteProperty -Name VolumeName -Value $vol.name 
                if(!$PGcount -gt 0)
                {
                    $Output = Add-PfaVolumesToProtectionGroup -Array $Array -Name $PGName -VolumesToAdd $device.VolumeName
                }
                $PersistenceInfoWithVolNames += $device       
            }
        }
    }

    return $PersistenceInfoWithVolNames
}
  
function Create-SAPHANADatabaseSnapshot()
{
    $output = Get-ODBCData -hanaConnectionString $hdbConnectionString -hdbsql $CreateHDBStorageSnapshot
    $hdbSnapshot = Get-ODBCData -hanaConnectionString $hdbConnectionString -hdbsql $RetrieveHDBSnapshotID
    return $hdbSnapshot
}
  
function FreezeFileSystem()
{
    param(
        $HostAddress, 
        $OSUser,
        $OSPassword,
        $FilesystemMount
    )
    $Cred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $OSUser, $OSPassword
    $sessionval = New-SSHSession -ComputerName $HostAddress -Credential $Cred -AcceptKey:$True -ConnectionTimeout 600
    $session = Get-SSHSession -SessionId $sessionval.SessionId
    $stream = $session.Session.CreateShellStream("dumb", 0, 0, 0, 0, 1000)
    Start-Sleep -Seconds 1
    $output = $stream.Read()
    $stream.WriteLine(" /sbin/fsfreeze -f " + $FilesystemMount)
    Start-Sleep -Milliseconds 250
    $output =  Remove-SSHSession -SessionId $sessionval.SessionId
}
  
function UnFreezeFileSystem()
{
    param(
        $HostAddress, 
        $OSUser,
        $OSPassword,
        $FilesystemMount
    )
    $Cred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $OSUser, $OSPassword
    $sessionval = New-SSHSession -ComputerName $HostAddress -Credential $Cred -AcceptKey:$True -ConnectionTimeout 600
    $session = Get-SSHSession -SessionId $sessionval.SessionId
    $stream = $session.Session.CreateShellStream("dumb", 0, 0, 0, 0, 1000)
    Start-Sleep -Seconds 1
    $output = $stream.Read()
    $stream.WriteLine(" /sbin/fsfreeze -u " + $FilesystemMount)
    Start-Sleep -Milliseconds 250
    $output =  Remove-SSHSession -SessionId $sessionval.SessionId
}
  
function Abandon-SAPHANADatabaseSnapshot()
{
    Param(
        $BackupID, 
        $EBID
    )
    $AbandonHDBSnapshot = "BACKUP DATA FOR FULL SYSTEM CLOSE SNAPSHOT BACKUP_ID " + $BackupID `
+ " UNSUCCESSFUL '" + $EBID + "';"
    Get-ODBCData -hanaConnectionString $hdbConnectionString -hdbsql $AbandonHDBSnapshot
}
  
function Confirm-SAPHANADatabaseSnapshot()
{
    Param(
        $BackupID,
        $EBID
    )
    $ConfirmHDBSnapshot = "BACKUP DATA FOR FULL SYSTEM CLOSE SNAPSHOT BACKUP_ID " + $BackupID `
+ " SUCCESSFUL '" + $EBID + "';"
    Get-ODBCData -hanaConnectionString $hdbConnectionString -hdbsql $ConfirmHDBSnapshot
}

##Check for necessary prerequisites
if(Check-ForPrerequisites)
{
    Check-Arguments
    $hdbConnectionString = "Driver={HDBODBC};ServerNode=" + $HostAddress + ":3" + $InstanceNumber `
    + $DatabasePort + ";UID=" + $DatabaseUser + ";PWD=" + $script:DatabasePassword +";"
    ##Check the SAP HANA system type for multiDB or single tenant DB
    $SystemType = Check-SAPHANASystemType
    if($SystemType.VALUE -eq 'multidb')
    {
        $hdbConnectionString = "Driver={HDBODBC};ServerNode=" + $HostAddress + ":3" + `
        $InstanceNumber + "13;UID=" + $DatabaseUser + ";PWD=" + $script:DatabasePassword +";"
        $multiDB = $true
    }
    if(!$CrashConsistentSnapshot)
    {
        ##Get the volume serial number 
        $instanceID =  Get-ODBCData -hanaConnectionString $hdbConnectionString -hdbsql $GetSAPHANAInstanceID
        $ShortMountPath = ((Get-ODBCData -hanaConnectionString $hdbConnectionString -hdbsql `
        $GetDataVolumeLocation).VALUE).Replace("/" + $instanceID.VALUE,"")
        $SerialNumber =  Get-VolumeSerialNumber -HostAddress $HostAddress -OSUser $OperatingSystemUser `
        -OSPassword $script:OperatingSystemPassword -DataVolumeMountPoint $ShortMountPath

        ##Prepare HANA Storage Snapshot
        Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
        Write-host "`t`t|          Preparing SAP HANA Data Snapshot      |" -ForegroundColor White
        Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
        $HANASnapshot = Create-SAPHANADatabaseSnapshot 

        ##Freeze the filesystem
        Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
        Write-host "`t`t|                Freezing filesystem             |" -ForegroundColor White
        Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
        FreezeFileSystem -HostAddress $HostAddress -OSUser $OperatingSystemUser -OSPassword `
        $script:OperatingSystemPassword -FilesystemMount $ShortMountPath


        ##Create Pure Volume Snapshot
        $SnapshotSuffix = "SAPHANA-" + $HANASnapshot.BACKUP_ID.ToString()
        $EBID = Create-PureStorageVolumeSnapshot -FlashArrayAddress $PureFlashArrayAddress -User `
        $PureFlashArrayUser -Password $script:PureFlashArrayPassword -SerialNumber $serialNumber -SnapshotSuffix $SnapshotSuffix
        ##Unfreeze the filesystem
        Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
        Write-host "`t`t|              UnFreezing filesystem             |" -ForegroundColor White
        Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
        UnFreezeFileSystem -HostAddress $HostAddress -OSUser $OperatingSystemUser -OSPassword `
        $script:OperatingSystemPassword -FilesystemMount $ShortMountPath
        if(!($EBID -eq $null))
        {
            Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
            Write-host "`t`t|              Confirming Snapshot               |" -ForegroundColor White
            Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
            Confirm-SAPHANADatabaseSnapshot -BackupID $HANASnapshot.BACKUP_ID.ToString() -EBID $EBID
        }
        else
        {
            Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
            Write-host "`t`t|              Abandoning Snapshot               |" -ForegroundColor White
            Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
            Abandon-SAPHANADatabaseSnapshot -BackupID $HANASnapshot.BACKUP_ID.ToString() -EBID $EBID
        }
    }
    else
    {
        $devices = (Get-ODBCData -hanaConnectionString $hdbConnectionString -hdbsql $GetPersistenceVolumesLocation)
        $instanceID =  Get-ODBCData -hanaConnectionString $hdbConnectionString -hdbsql $GetSAPHANAInstanceID
        $Persistence = @()
        foreach($d in  $devices)
        {
            $persistenceObj = New-Object -TypeName PSObject

            $ShortMountPath = ($d.VALUE).Replace("/" + $instanceID.VALUE,"")
            $SerialNumber =  Get-VolumeSerialNumber -HostAddress $HostAddress -OSUser $OperatingSystemUser `
            -OSPassword $script:OperatingSystemPassword -DataVolumeMountPoint $ShortMountPath
            $persistenceObj | Add-Member -MemberType NoteProperty -Name MountPoint -Value $ShortMountPath
            $persistenceObj | Add-Member -MemberType NoteProperty -Name SerialNumber -Value $SerialNumber
            $Persistence += $persistenceObj
 
        }

        #Check if the log and data volumes are already apart of a protection group 

        $PGName = "SAPHANA-" + $DatabaseName + "-CrashConsistency"

        $Persistence = Check-PureStoragePG -FlashArrayAddress $PureFlashArrayAddress -User $PureFlashArrayUser `
        -Password $script:PureFlashArrayPassword -PersistenceInfo $Persistence -PGName $PGName


        ##Freeze the filesystem
        foreach($p in $Persistence)
        {
            
            Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
            Write-host "`t`t|     Freezing filesystem for " $p.MountPoint"       " -ForegroundColor White
            Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
            FreezeFileSystem -HostAddress $HostAddress -OSUser $OperatingSystemUser -OSPassword `
            $script:OperatingSystemPassword -FilesystemMount $p.MountPoint
        }

        Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
        Write-host "`t`t|        Creating Crash Consistent Snapshot      |" -ForegroundColor White
        Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
        $PGSnap = Create-PureStoragePGSnapshot -FlashArrayAddress $PureFlashArrayAddress -User $PureFlashArrayUser `
        -Password $script:PureFlashArrayPassword -PGName $PGName
        Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
        Write-host "`t`t| "$PGSnap.name " created              " -ForegroundColor White
        Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
        foreach($p in $Persistence)
        {
            Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
            Write-host "`t`t|     UnFreezing filesystem for " $p.MountPoint"  " -ForegroundColor White
            Write-Host "`t`t ------------------------------------------------ " -ForegroundColor White
            UnFreezeFileSystem -HostAddress $HostAddress -OSUser $OperatingSystemUser -OSPassword `
            $script:OperatingSystemPassword -FilesystemMount $p.MountPoint
        }
    }
}

