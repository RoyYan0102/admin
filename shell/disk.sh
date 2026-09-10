# check all disk
lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS

# check whether azure
ls -l /dev/disk/azure/scsi1/

# check whether formatted
sudo blkid /dev/sda

# create partition
sudo fdisk /dev/sda

# format as ext4
sudo mkfs.ext4 /dev/sda1

# create mount point
sudo mkdir -p /data

# get UUID
sudo blkid /dev/sda1

# add the UUID to /etc/fstab

# mount it
sudo mount -a

# verify
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS
df -h /data
