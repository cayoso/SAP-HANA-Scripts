import sys
import argparse
import paramiko
import re
import purestorage
from hdbcli import dbapi
from datetime import datetime

#Arguments
parser = argparse.ArgumentParser(description='Process the creation of an SAP \
    HANA application consistent storage snapshot')
parser.add_argument('--hostaddresss', help='Host address (hostname) of an SAP \
    HANA Scale Out worker')
parser.add_argument('--domainname', help='Domain name of domain where SAP \
    HANA scale out nodes are located')
parser.add_argument('--instancenumber', help='SAP HANA instance number , \
    typically in the form 00',  default=00)
parser.add_argument('--databasename', help='SAP HANA database or tenant name')
parser.add_argument('--port', help='SAP HANA port number , typically in \
    the form 15,41 taken from the final two digits of the port number', default=15)
parser.add_argument('--databaseuser', help='SAP HANA database user with \
    the correct permissions to create a storage snapshot')
parser.add_argument('--databasepassword', help='SAP HANA database \
    password with the correct permissions to create a storage snapshot')
parser.add_argument('--operatingsystemuser', help='A user with the \
    permissions to freeze the SAP HANA data volume')
parser.add_argument('--operatingsystempassword', help='Password for \
    the user with permissions to freeze the SAP HANA data volume')
parser.add_argument('--flasharray', help='The IP address or hostname \
    of a Pure Storage FlashArray with the SAP HANA systems volumes on it ')
parser.add_argument('--flasharrayuser', help='A user on the FlashArray \
    with permissions to create a volume snapshot')
parser.add_argument('--flasharraypassword', help='Password for the user \
    with permissions to create a volume snapshot on FlashArray')

args = parser.parse_args()

# hostaddresses = args.hostaddresss
# instancenumber = args.instancenumber
# databasename = args.databasename
# port = args.port
# databaseuser = args.databaseuser
# databasepassword = args.databasepassword
# operatingsystemuser = args.operatingsystemuser
# operatingsystempassword = args.operatingsystempassword
# flasharray = args.flasharray
# flasharrayuser = args.flasharrayuser
# flasharraypassword = args.flasharraypassword

hostaddress = "SHN2.puredoes.local"
domainname = "puredoes.local"
instancenumber = "00"
databasename = "SH1"
port = "15"
databaseuser = "SYSTEM"
databasepassword = "Osmium76"
operatingsystemuser = "root"
operatingsystempassword = "Osmium76"
flasharray = "10.21.227.24"
flasharrayuser = "pureuser"
flasharraypassword = "pureuser"


def check_pythonversion():
    if sys.version_info[0] < 3:
        print("Minimum version of python required to run this script is python 3")
        return False
    else:
        return True

def execute_saphana_command(command, port_number):
    portvalue = "3" + str(instancenumber) + str(port_number)
    connection = dbapi.connect(address=hostaddress,
                port=portvalue,
                user=databaseuser,
                password=databasepassword)
    if(connection.isconnected):
        cursor = connection.cursor()
        cursor.execute(command)
        responses = list()
        if cursor.description is not None:
            for row in cursor:
                responses.append(row)
            return responses
        else:
            pass
    else:
            print("Database connection not possible")



def check_saphana_system_type():
    hdbsqlCheckSAPHANASystemType = "SELECT VALUE FROM M_INIFILE_CONTENTS WHERE \
        FILE_NAME = 'global.ini' AND SECTION = 'multidb' AND KEY = 'mode'"
    systemtype = execute_saphana_command(hdbsqlCheckSAPHANASystemType, port)
    if "multidb" in systemtype[0]:
        multidb = True
        return multidb
    else:
        multidb = False
        return multidb

def prepare_ssh_connection(host):
    sshclient = paramiko.SSHClient()
    sshclient.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    sshclient.connect(
        host,
        port=22,
        username=operatingsystemuser,
        password=operatingsystempassword
    )
    return sshclient

    
def get_volume_serialno(host,datavolume_mount):
    sshclient = prepare_ssh_connection(host)
    get_volumemountpoint_command = "df -h | grep " + str(datavolume_mount)
    stdin, stdout, stderr = sshclient.exec_command(get_volumemountpoint_command)
    opt = stdout.readlines()
    parsedvolume_location = re.search("([^[']\S+)",str(opt))
    get_volumeserialno_command = "udevadm info --query=all --name=" + \
    str(parsedvolume_location.group()) + " | grep DM_SERIAL"
    stdin, stdout, stderr = sshclient.exec_command(get_volumeserialno_command)
    opt = stdout.readlines()
    volumeserial_toparse = opt
    sshclient.close()
    volumeserial_toparse = re.split("=",str(volumeserial_toparse))
    volumeserial_toparse = volumeserial_toparse[1]
    volumeserial_toparse = re.split("\\\\",str(volumeserial_toparse))
    volumeserial = volumeserial_toparse[0]
    return volumeserial

def freeze_filesystem(host,datavolume_mount):
    sshclient = prepare_ssh_connection(host)
    get_volumemountpoint_command = "/sbin/fsfreeze --freeze" + str(datavolume_mount)
    stdin, stdout, stderr = sshclient.exec_command(get_volumemountpoint_command)
    opt = stdout.readlines()
    sshclient.close()

def unfreeze_filesystem(host,datavolume_mount):
    sshclient = prepare_ssh_connection(host)
    get_volumemountpoint_command = "/sbin/fsfreeze --unfreeze" + str(datavolume_mount)
    stdin, stdout, stderr = sshclient.exec_command(get_volumemountpoint_command)
    opt = stdout.readlines()
    sshclient.close()

def create_flasharray_volume_snapshot(serialnumber,snapshot_suffix):
    array = purestorage.FlashArray(flasharray,flasharrayuser, flasharraypassword,verify_https=False)
    volumes =  array.list_volumes()
    for key in volumes:
        volname = key.get("name")
        volserial = str(key.get("serial")).lower()
        found = volserial in serialnumber
        if found:
           snapshot_id = array.create_snapshot(volname, suffix=snapshot_suffix)
           snapserial = str(snapshot_id.get("serial"))
           return snapserial


def prepare_saphana_storage_snapshot():
    now = datetime.now()
    dt_string = now.strftime("%d/%m/%Y %H:%M:%S")
    hdbPrepareStorageSnapshot = "BACKUP DATA FOR FULL SYSTEM CREATE SNAPSHOT COMMENT 'SNAPSHOT-" 
    + dt_string +"';"
    hdbRetrieveStorageSnapshotID = "SELECT BACKUP_ID, COMMENT FROM M_BACKUP_CATALOG WHERE \
        ENTRY_TYPE_NAME = 'data snapshot' AND STATE_NAME = 'prepared' AND COMMENT = 'SNAPSHOT-" + dt_string +"';"
    multidb = check_saphana_system_type()
    if multidb:
        execute_saphana_command(hdbPrepareStorageSnapshot, 13)
        saphana_snapshot_id = execute_saphana_command(hdbRetrieveStorageSnapshotID, 13)
    else:
        execute_saphana_command(hdbPrepareStorageSnapshot, port)
    saphana_snapshot_id = saphana_snapshot_id[0].column_values[0]
    return saphana_snapshot_id


def confirm_saphana_storage_snapshot(BackupID, EBID):
    hdbConfirmStorageSnapshot = "BACKUP DATA FOR FULL SYSTEM CLOSE SNAPSHOT BACKUP_ID " 
    + str(BackupID) + " SUCCESSFUL '" + "FlashArray Snapshot ID :" + str(EBID) + "';"
    multidb = check_saphana_system_type()
    if multidb:
        execute_saphana_command(hdbConfirmStorageSnapshot, 13)

    else:
        execute_saphana_command(hdbConfirmStorageSnapshot, port)


def abandon_saphana_storage_snapshot(BackupID, EBID):
    hdbAbandonStorageSnapshot = "BACKUP DATA FOR FULL SYSTEM CLOSE SNAPSHOT BACKUP_ID " 
    + str(BackupID) + " UNSUCCESSFUL '" + str(EBID) + "';"
    multidb = check_saphana_system_type()
    if multidb:
        execute_saphana_command(hdbAbandonStorageSnapshot, 13)

    else:
        execute_saphana_command(hdbAbandonStorageSnapshot, port)

def get_saphana_data_volume_and_hosts():
    hdbGetHANADataVolumeAndHosts = "SELECT HOST, STORAGE_ID, PATH, KEY, VALUE FROM SYS.M_ATTACHED_STORAGES WHERE KEY = \
    'WWID' AND PATH LIKE (SELECT CONCAT(VALUE,'%') FROM M_INIFILE_CONTENTS WHERE FILE_NAME = 'global.ini' AND SECTION = \
    'persistence' AND KEY = 'basepath_datavolumes' AND VALUE NOT LIKE '$%')"
    multidb = check_saphana_system_type()
    if multidb:
        global hostaddress 
        hostaddress = get_saphana_nameserver_host() + "." +  domainname
        hosts_data_volumes = execute_saphana_command(hdbGetHANADataVolumeAndHosts,13)
    else:
        hosts_data_volumes = execute_saphana_command(hdbGetHANADataVolumeAndHosts, port)
    return hosts_data_volumes

   
def get_saphana_nameserver_host():
    hdbGetNameServerhost = "SELECT HOST FROM SYS.M_SERVICES WHERE DETAIL = 'master' AND SERVICE_NAME = 'nameserver'"
    nameserver_host = execute_saphana_command(hdbGetNameServerhost, port)
    nameserver_host = nameserver_host[0].column_values[0]
    return nameserver_host



try:
    hosts_and_vols = get_saphana_data_volume_and_hosts()
    saphana_backup_id = prepare_saphana_storage_snapshot()
    volume_snapshot_id = ""
    for h_v in hosts_and_vols:
        host = h_v.column_values[0] + domainname
        mount_point = h_v.column_values[2]
        freeze_filesystem(host, mount_point)
        mount_point_parse = mount_point.replace('/',"")
        vol_snap_suffix = "SAPHANA-" + host + "-" + mount_point_parse + "-"  + str(saphana_backup_id)
        print("Creating storage snapshot for mount point : " + mount_point_parse + "on host : " + host)
        volume_snapshot_id = volume_snapshot_id + "-" + vol_snap_suffix + "-" + \
        create_flasharray_volume_snapshot(get_volume_serialno(host, mount_point),vol_snap_suffix)
        unfreeze_filesystem(host, mount_point)
    if saphana_backup_id is not None and volume_snapshot_id is not None:
        print("Confirming storage snapshot with SAP HANA Backup ID : " + str(saphana_backup_id))
        confirm_saphana_storage_snapshot(saphana_backup_id, volume_snapshot_id)
    else:
        print("Abandoning storage snapshot with SAP HANA Backup ID : " + str(saphana_backup_id))
        abandon_saphana_storage_snapshot(saphana_backup_id, "no_value")
except:
    if saphana_backup_id is not None:
        print("Abandoning storage snapshot with SAP HANA Backup ID : " + str(saphana_backup_id))
        abandon_saphana_storage_snapshot(saphana_backup_id, "no_value")
    