#!/bin/bash
# Stefanie Edgar
# Aug 26 2011 
# A script to automate benchmarking for DRBD volumes. 
# tests with filesystems:    xfs, ext3, ext4
# tests with  programs:      iozone, bonnie++, sysbench
#
# Usage:   ./drbd_bench.bash <device> <resource-name> <mountpoint>
#          Can be used with various protocols like IPoIB, SDP, SSOCKS, and IPv4.
#          Run this script for each one you want to test, once the environment is set up.
#          You can also swap out different disks to see how they perform.
#          Use with 'tee' to save results.
#
# Dependencies:
# yum install e4fsprogs xfsprogs iozone bonnie++ sysbench mysql-server

function drbd_info() {
   echo "--------------------- DRBD Info ---------------------------"
   drbdadm dump $1
   cat /proc/drbd
   echo "-----------------------------------------------------------"
}

function run_bonnie() {
    fs="$1"
    mountpoint="$2"
    echo "Mounting filesystem for bonnie"
    sed "s/FILESYSTEM/$fs/" fstab-iotest > /etc/fstab
    sed "s/FILESYSTEM/$fs/" fstab-iotest
 
    # mount filesystem, checking that it mounted correctly
    # wait for user to correct the issue if it doesnt mount.
    mount $mountpoint
    while [ "$( mount | grep $mountpoint )" == ""  ]; do
        echo "********** ERROR: filesystem $mountpoint not mounted! **********"
        sleep 10s
    done

    mkdir $mountpoint/test 
    chown nobody:nobody $mountpoint/test
    echo "Running bonnie++" 
    bonnie++ -u nobody -d $mountpoint/test > bonnie_results.txt 2>&1
    umount $mountpoint
    echo "done" 
}

function run_iozone() {
    fs="$1"
    mountpoint="$2"
    echo "Setting up fstab for IOzone mount"
    sed "s/FILESYSTEM/$fs/" fstab-iotest > /etc/fstab
    
    mount $mountpoint
    while [ "$( mount | grep $mountpoint )" == ""  ]; do
        echo "********** ERROR: filesystem $mountpoint not mounted! **********"
        sleep 10s
    done
    echo "Running IOzone"
    iozone -az -i 0 -i 1 -I -U $mountpoint -f $mountpoint/testfile -R 
    umount $mountpoint
    echo "done"
}

function run_sysbench() {
    echo "Setting up sysbench fstab"
    
    # mount the filesystem
    sed "s/FILESYSTEM/$1/" fstab-mysql > /etc/fstab
    mount /var/lib/mysql

    # pause on error
    while [ "$( mount | grep '/var/lib/mysql' )" == "" ]; do
        echo "********** ERROR: filesystem /var/lib/mysql not mounted! **********"
        sleep 10s
    done

    echo "Starting mysqld..."
    service mysqld start

    echo "Running sysbench"
    sysbench --test=oltp --db-driver=mysql --mysql-db=test \
       --mysql-host='localhost' --mysql-table-engine=innodb prepare
    sysbench --test=oltp --db-driver=mysql --mysql-db=test \
       --mysql-host='localhost' --mysql-table-engine=innodb run > sysbench_results.txt 2>&1
    
    service mysqld stop
    umount /var/lib/mysql    
    echo "done"
}
    
function make_fs() {
    fs="$1"
    drbd_dev="$2"
    mountpoint="$3"
    
    # ** WARNING: all data on this device will be destroyed! **
    echo "Clearing old data"
    dd if=/dev/zero of=$drbd_dev bs=1M count=8000 2>&1 

    echo "Creating new filesystem $fs"
    
    # if it's running, shut off mysqld. If it's mounted, unmount it.
    ( service mysqld status | grep running ) && service mysqld stop
    ( mount | grep $mountpoint ) && umount $mountpoint
    ( mount | grep /var/lib/mysql ) && umount /var/lib/mysql
 
    # make the filesystem
    time mkfs.$fs $drbd_dev
    echo "done"
} 

# print usage info if used incorrectly
if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ] ;then
    echo
    echo " Usage:   ./drbd_bench.bash <device> <resource-name> <mountpoint>"
    echo "          Can be used with various protocols like IPoIB, SDP, SSOCKS, and IPv4."
    echo "          Run this script for each one you want to test, once the environment is set up."
    echo "          You can also swap out different disks to see how they perform."
    echo "          Use with 'tee' to save results."
    echo
    echo " *** WARNING: ALL DATA WILL BE DESTROYED on the device you choose. *** "
    echo "     These benchmarks reformat and overwrite the given device during testing."
    exit 1
fi

# set params
drbd_dev="$1"
drbd_res="$2"
mountpoint="$3"
my_fstab=""

# generate fstabs based on chosen mountpoint & drbd device
if [ -f fstab.backup ]; then
    my_fstab="fstab.backup"
else 
    my_fstab="/etc/fstab"
    cp /etc/fstab fstab.backup
fi 

echo "Using fstab file: $my_fstab to mount devices"

cp -f $my_fstab fstab-iotest
cp -f $my_fstab fstab-mysql
echo "$drbd_dev    $mountpoint           FILESYSTEM defaults     0 0" >> fstab-iotest
echo "$drbd_dev    /var/lib/mysql        FILESYSTEM defaults     0 0" >> fstab-mysql

# create mountpoint, if it doesnt exist
[ -d $mountpoint ] || mkdir -p $mountpoint

# ------ run tests ------ #
for fs in "ext4" "ext3" "xfs"
do
    echo "******************************** $fs DRBD Benchmarks *************************************"
    drbd_info $drbd_res
    make_fs $fs $drbd_dev $mountpoint
    run_iozone $fs $mountpoint 
    run_sysbench $fs
    run_bonnie $fs $mountpoint 
    echo
    echo
    echo "---- Bonnie Summary: ----"
    bonnie_writes=$(grep -m 1 $HOSTNAME bonnie_results.txt | awk {'print $11'}) 
    bonnie_reads=$(grep -m 1 $HOSTNAME bonnie_results.txt | awk {'print $5'}) 
    bonnie_rewrites=$(grep -m 1 $HOSTNAME bonnie_results.txt | awk {'print $7'}) 
    echo "Block Reads     Block Writes       Re-writes"
    echo "$bonnie_reads         $bonnie_writes          $bonnie_rewrites"
    echo "--------------------------------------------"
    echo
    echo "---- MySQL Performance: ----"
    grep "transactions:" sysbench_results.txt
    grep "read/write requests:" sysbench_results.txt
    grep "total time:" sysbench_results.txt
    echo
    echo
done

# clean up files
mv fstab.backup /etc/fstab
rm -f fstab-iotest
rm -f fstab-mysql

echo "Tests complete!"
