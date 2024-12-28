#!/bin/sh

# Prompt for Configuration Variables
echo "Enter hostname for the system (e.g., freebsd-server):"
read -r HOSTNAME

echo "Enter username for the new user (e.g., developer):"
read -r USERNAME

while true; do
    echo "Enter password for the new user:"
    read -rs PASSWORD1
    echo
    echo "Confirm password:"
    read -rs PASSWORD2
    echo
    if [ "$PASSWORD1" = "$PASSWORD2" ]; then
        PASSWORD=$PASSWORD1
        break
    else
        echo "Passwords do not match. Try again."
    fi
done

# Auto-detect Timezone
TIMEZONE=$(curl --fail --silent https://ipapi.co/timezone)
if [ -z "$TIMEZONE" ]; then
    echo "Could not auto-detect timezone. Enter manually (e.g., UTC):"
    read -r TIMEZONE
else
    echo "Detected timezone: $TIMEZONE"
fi

# Auto-detect available disks
echo "Detecting available disks..."
DISKS=$(sysctl -n kern.disks)
if [ -z "$DISKS" ]; then
    echo "No disks detected. Ensure your hardware is properly connected."
    exit 1
fi

echo "Available disks:"
for DISK in $DISKS; do
    SIZE=$(diskinfo -v $DISK | grep "mediasize in bytes" | awk '{print $4 / (1024*1024*1024) " GB"}')
    echo "$DISK - $SIZE"
done

# Prompt user to select the target disk
echo
echo "Enter the disk you want to install FreeBSD on (e.g., ada0):"
read -r TARGET_DISK

if ! echo "$DISKS" | grep -qw "$TARGET_DISK"; then
    echo "Invalid disk selected. Exiting."
    exit 1
fi

# Confirm selection
echo "You have selected $TARGET_DISK for installation. All data on this disk will be erased. Continue? (yes/no)"
read -r CONFIRMATION
if [ "$CONFIRMATION" != "yes" ]; then
    echo "Installation canceled."
    exit 1
fi

# Partition and format the disk
echo "Partitioning and formatting the disk: $TARGET_DISK..."
gpart destroy -F $TARGET_DISK || true
gpart create -s gpt $TARGET_DISK
gpart add -t efi -s 512M -l efi $TARGET_DISK
gpart add -t freebsd-ufs -l root $TARGET_DISK
gpart add -t freebsd-swap -s 2G -l swap $TARGET_DISK

newfs_msdos /dev/${TARGET_DISK}p1
newfs -U /dev/${TARGET_DISK}p2
swapon /dev/${TARGET_DISK}p3

# Mount the root partition
mount /dev/${TARGET_DISK}p2 /mnt

# Install the base system
echo "Installing the FreeBSD base system..."
bsdinstall distfetch --directory /usr/freebsd-dist
bsdinstall distextract --directory /usr/freebsd-dist /mnt

# Configure the system
echo "Configuring the system..."
echo $HOSTNAME > /mnt/etc/hostname

# Set up fstab
echo "/dev/${TARGET_DISK}p2 / ufs rw 1 1" > /mnt/etc/fstab
echo "/dev/${TARGET_DISK}p3 none swap sw 0 0" >> /mnt/etc/fstab

# Enable essential services
echo "sshd_enable=YES" >> /mnt/etc/rc.conf
echo "hostname=$HOSTNAME" >> /mnt/etc/rc.conf

# Set timezone
ln -sf /usr/share/zoneinfo/$TIMEZONE /mnt/etc/localtime

# Add a user and set passwords
echo "Adding user $USERNAME..."
chroot /mnt pw useradd -n $USERNAME -m -s /bin/sh -G wheel
echo "root:$PASSWORD" | chroot /mnt pw usermod root -h 0
echo "$USERNAME:$PASSWORD" | chroot /mnt pw usermod $USERNAME -h 0

# Configure bootloader
echo "Configuring the bootloader..."
gpart bootcode -b /mnt/boot/boot1.efi /dev/$TARGET_DISK
mkdir -p /mnt/boot/efi
mount -t msdosfs /dev/${TARGET_DISK}p1 /mnt/boot/efi
cp /mnt/boot/loader.efi /mnt/boot/efi/bootx64.efi

# Install additional software
echo "Installing additional software..."
chroot /mnt /bin/sh <<EOF
pkg install -y nano curl git vscode chromium
EOF

# Clean up and reboot
echo "Unmounting and rebooting..."
umount -R /mnt
echo "Installation complete. Rebooting in 5 seconds..."
sleep 5
reboot
