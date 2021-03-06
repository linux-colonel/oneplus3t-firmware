#!/system/xbin/bash

# global vars
unpack_dir="updater_unpacked"
zip_updater_script="META-INF/com/google/android/updater-script"
declare -A firmware_partition_map


function checkroot()
{
    uid=$(id -u)
    if [ $uid -ne 0 ]; then
            echo "This script must be run as root." >&2
            exit 1
    fi
}

function usage()
{
        echo "This script can flash, backup, and restore firmware to an Android device running LineageOS."
        echo "Warning: This script can brick your device.  Use at your own risk!"
        echo
	echo "Usage: $0 -f [-n] <updater-zip.zip>"
	echo "       $0 -b [-n] <backup-dir> <updater-zip.zip>"
	echo "       $0 -r [-n] <backup-dir> <updater-zip.zip>"
        echo "       $0 -h"
        echo
        echo "-f Flash mode:  Flashes the firmware from the updater zip to the device."
        echo
        echo "-b Backup mode: Backs up the firmware currently on the device to the backup directory."
        echo "    The updater zip is needed for the mapping of partitions to firmware images."
        echo
        echo "-r Restore mode: Restores the firmware from the backup directory to the device."
        echo "    The updater zip is needed for the mapping of partitions to firmware images."
        echo
        echo "-n NO-OP mode: This can be combined with the above modes to print what will be done without actually doing it.  This mode does not need root.  Use this first for extra safety."
        echo
        exit 1
}

function cleanup()
{
    echo "Cleaning up."
    rm -rf $unpack_dir
}

function process_updater()
{
    unzip -l $updater_zip 2>/dev/null |grep $zip_updater_script >/dev/null 2>&1
    ret=$?
    if [ $ret -ne 0 ]; then
        echo "This does not appear to be an android updater file." >&2
        cleanup
        exit 1
    fi
    mkdir $unpack_dir
    pushd $unpack_dir >/dev/null
    echo "Unzipping update file."
    unzip $updater_zip >/dev/null 2>&1
    ret=$?
    popd >/dev/null
    if [ $ret -ne 0 ]; then
        echo "Failed to unzip updater." >&2
        exit 1
    fi
}

# read the script that would do the flashing to find
# the firmware files to flash and the partitions they go on.
function parse_firmware_partition_mapping(){

    lines=$(grep package_extract_file ${unpack_dir}/${zip_updater_script} | \
        # don't flash boot, recovery, etc
        grep -E 'firmware-update|RADIO' | \
        # don't flash backup partitions
        grep -v bak | \
        # format into comma-separated list.
        sed 's/package_extract_file//g;s/[()"; ]//g')
    for line in $lines; do
        filename=$(echo $line | awk -F ',' '{print $1}')
        partition=$(echo $line | awk -F ',' '{print $2}')
        firmware_partition_map[$filename]=$partition
    done
}

function sanity_check(){
    local firmware_base_dir=$1

    total_num_files=0
    for dir in firmware-update RADIO; do 
        num_files=0
        if [ -d ${firmware_base_dir}/${dir} ]; then
            num_files=$(ls ${firmware_base_dir}/${dir} | wc -w)
            if [ -f ${firmware_base_dir}/${dir}/SHA256SUMS ]; then
                echo "Checking SHA256SUMs."
                pushd ${firmware_base_dir}/${dir} > /dev/null
                sha256sum -c SHA256SUMS
                ret=$?
                popd > /dev/null
                if [ $ret -ne 0 ]; then
                    echo "Failed to check SHA256SUMs." >&2
                    exit 1
                fi
            fi
        fi
        total_num_files=$((total_num_files+num_files))
    done


    if [ $total_num_files -le 0 ]; then
        echo "No firmware update files found." >&2
        cleanup
        exit 1
    fi
    if [ $total_num_files -ne ${#firmware_partition_map[@]} ]; then
        echo "The number of firmware files found ($total_num_files) differs from what was found in the flashing script ($zip_updater_script)." >&2
        echo "Aborting."
        cleanup
        exit 1
    fi
    for filename in ${!firmware_partition_map[@]}; do
        if [ ! -f "${firmware_base_dir}/$filename" ]; then
            echo "Failed to find firmware file ${filename}." >&2
            cleanup
            exit 1
        fi
    done
}

function confirm()
{
    echo "****WARNING****"
    echo "Only run this if you absolutely know what you're doing!"
    echo "Did you run in no-op mode first?"
    echo "THIS COULD BRICK YOUR DEVICE!"
    echo -n "Continue (y/N)"
    read ans

    if [ "$ans" != 'Y' ] && [ "$ans" != 'y' ]; then
            echo "You're not sure.  That's OK.  Quitting."
            exit 1
    fi
}

function do_flash()
{
    echo "Beginning firmware update!"
    echo "***DO NOT INTERRUPT***"

    for firmware_file in "${!firmware_partition_map[@]}"; do
        partition=${firmware_partition_map[$firmware_file]}
        echo "Flashing firmware ${firmware_file} to partition ${partition}."
        $cmd_prefix dd if=$unpack_dir/$firmware_file of=$partition
        ret=$?
        if [ $ret -ne 0 ]; then
            echo "Warning: flash of $partition failed!"
        fi
    done

    echo "Firmware update complete!"
    echo "Reboot your device now."
}

function do_backup()
{
    if [ -e $backup_dir ]; then
        echo "The backup directory ${backup_dir} already exists." >&2
        echo "Please move it somewhere else to continue." >&2
        cleanup
        exit 1
    fi

    echo "Beginning backup!"
    mkdir ${backup_dir}
    mkdir ${backup_dir}/{RADIO,firmware-update}

    for firmware_file in "${!firmware_partition_map[@]}"; do
        partition=${firmware_partition_map[$firmware_file]}
        echo "Backing up firmware ${firmware_file} from partition ${partition}."
        $cmd_prefix dd if=$partition of=$backup_dir/$firmware_file
        ret=$?
        if [ $ret -ne 0 ]; then
            echo "Warning: flash of $partition failed!"
        fi
    done

    echo "Backup completed!"

    echo "Computing SHA256SUMs."
    for dir in ${backup_dir}/RADIO ${backup_dir}/firmware-update; do
        pushd $dir >/dev/null
        sha256sum * > SHA256SUMS
        popd > /dev/null
    done
}

function do_restore()
{
    echo "Beginning restore!"
    echo "***DO NOT INTERRUPT***"
    for firmware_file in "${!firmware_partition_map[@]}"; do
        partition=${firmware_partition_map[$firmware_file]}
        echo "Restoring firmware from ${firmware_file} to partition ${partition}."
        $cmd_prefix dd if=$backup_dir/$firmware_file of=$partition
        ret=$?
        if [ $ret -ne 0 ]; then
            echo "Warning: flash of $partition failed!"
        fi
    done

    echo "Restore complete!"
    echo "Reboot your device now."
}

# main script

OPTIND=1
unset noop flash backup restore
unset updater_zip backup_dir

while getopts "h?fbrn" opt; do
    case "$opt" in
    h)
        usage
        ;;
    f)
        flash=1
        ;;
    b)
        backup=1
        ;;
    r)
        restore=1
        ;;
    n)
        noop=1
        ;;
    *)
        usage
        ;;
    esac
done

shift $((OPTIND-1))

if [ $((flash+backup+restore)) -ne 1 ]; then
    echo "Exactly one of -f, -b, or -r must be specified." >&2
    usage
fi

if [ "$noop" ]; then
    cmd_prefix="echo Would run: "
    echo "NO-OP mode activated!"
else
    unset cmd_prefix
    checkroot
    confirm
fi

if [ "$flash" ]; then
    echo "Running in flash mode."
    updater_zip=$1
    process_updater
    parse_firmware_partition_mapping
    sanity_check $unpack_dir
    do_flash
fi

if [ "$backup" ]; then
    echo "Running in backup mode."
    backup_dir=$1
    updater_zip=$2
    process_updater
    parse_firmware_partition_mapping
    do_backup
fi

if [ "$restore" ]; then
    echo "Running in restore mode."
    backup_dir=$1
    updater_zip=$2
    if [ ! -d "$backup_dir" ]; then
        echo "backup-dir must be a directory" >&2
        exit 1
    fi
    process_updater
    parse_firmware_partition_mapping
    sanity_check $backup_dir
    do_restore
fi

cleanup
exit 0

