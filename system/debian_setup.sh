#!/usr/bin/env bash

# debian_setup.sh
 # Author: Daniel Pellegrino
 # Date Created: 12/18/2023
 # Last Modified: 12/18/2023
 # Description: This script will install debian using debootstrap.

# Variables
HOSTNAME="debian"
USERNAME="daniel"
NAME="Daniel Pellegrino"

main ()
{
  # Check if user is root
  if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
  fi

  # Setup disk
  echo "Which disk do you want to setup?"
  lsblk
  read -p "Enter your choice: " choice
  disk="/dev/$choice"
  echo "Setting up $disk"
  echo "Creating partition table..."
  parted -s "$disk" mklabel gpt
  echo "Creating partition..."
  # Create a EFI partition
  parted -s "$disk" mkpart primary fat32 1MiB 512MiB
  # Create a boot partition
  parted -s "$disk" mkpart primary ext4 512MiB 1536MiB
  # Create an encrypted btrfs partition
  parted -s "$disk" mkpart primary btrfs 1536MiB 100%
  echo "Setting boot flag..."
  parted -s "$disk" set 2 boot on

  # Grab the new partition names
  # EFI partition (could be sda1, sdb1, nvme0n1p1, etc.)
  # Boot partition (could be sda2, sdb2, nvme0n1p2, etc.)
  # Encrypted partition (could be sda3, sdb3, nvme0n1p3, etc.)
  lsblk "$disk"
  # Verify partition names
  while true; do
    read -p "Enter the EFI partition name: " efi
    read -p "Enter the boot partition name: " boot
    read -p "Enter the encrypted partition name: " crypt
    read -p "Are these the correct partition names? (y/n): " yn
    case $yn in
      [Yy]* ) break;;
      [Nn]* ) continue;;
      * ) echo "Please answer yes or no.";;
    esac
  done

  # Format the partitions
  echo "Formatting partitions..."
  mkfs.fat -F32 "/dev/$efi"
  mkfs.ext4 "/dev/$boot"
  cryptsetup luksFormat "/dev/$crypt" # This will prompt the user to enter a password
  cryptsetup open "/dev/$crypt" cryptroot # This will prompt the user to enter a password
  mkfs.btrfs /dev/mapper/cryptroot

  # Mount to create subvolumes
  mount /dev/mapper/cryptroot /mnt

  # Create the subvolumes
  echo "Creating subvolumes..."
  btrfs subvolume create /mnt/@
  btrfs subvolume create /mnt/@snapshots
  btrfs subvolume create /mnt/@home
  btrfs subvolume create /mnt/@root
  btrfs subvolume create /mnt/@log
  btrfs subvolume create /mnt/@AccountsService
  btrfs subvolume create /mnt/@gdm
  btrfs subvolume create /mnt/@tmp
  btrfs subvolume create /mnt/@opt
  btrfs subvolume create /mnt/@images
  btrfs subvolume create /mnt/@containers

  # Mount the subvolumes
  umount /mnt
  mount -o subvol=@,noatime,compress=zstd:1 /dev/mapper/cryptroot /mnt
  mkdir -p /mnt/{boot,.snapshots,home,root,var/log,var/lib/AccountsService,var/lib/gdm3,tmp,opt,var/lib/libvirt/images,var/lib/containers}

  # Mount the boot partition
  echo "Mounting boot partition..."
  mount "/dev/$boot" /mnt/boot
  mkdir -p /mnt/boot/efi
  mount "/dev/$efi" /mnt/boot/efi

  # Mount the subvolumes
  echo "Mounting subvolumes..."
  mount -o subvol=@snapshots,noatime,compress=zstd:1 /dev/mapper/cryptroot /mnt/.snapshots
  mount -o subvol=@home,noatime,compress=zstd:1 /dev/mapper/cryptroot /mnt/home
  mount -o subvol=@root,noatime,compress=zstd:1 /dev/mapper/cryptroot /mnt/root
  mount -o subvol=@log,noatime,compress=zstd:1 /dev/mapper/cryptroot /mnt/var/log
  mount -o subvol=@AccountsService,noatime,compress=zstd:1 /dev/mapper/cryptroot /mnt/var/lib/AccountsService
  mount -o subvol=@gdm,noatime,compress=zstd:1 /dev/mapper/cryptroot /mnt/var/lib/gdm3
  mount -o subvol=@tmp,noatime,compress=zstd:1 /dev/mapper/cryptroot /mnt/tmp
  mount -o subvol=@opt,noatime,compress=zstd:1 /dev/mapper/cryptroot /mnt/opt
  mount -o subvol=@images,noatime,compress=zstd:1 /dev/mapper/cryptroot /mnt/var/lib/libvirt/images
  mount -o subvol=@containers,noatime,compress=zstd:1 /dev/mapper/cryptroot /mnt/var/lib/containers

  apt update

  # Install debian
  apt install debootstrap -y
  debootstrap --include linux-image-amd64,grub-efi,locales --arch amd64 bookworm /mnt

  # Copy the mounted file systems into the new system
  echo "Copying mounted file systems into the new system..."
  cp /etc/mtab /mnt/etc/mtab

  # Bind the virtual filesystems to the new system
  echo "Binding virtual filesystems to the new system..."
  mount --bind /dev /mnt/dev
  mount --bind /dev/pts /mnt/dev/pts
  mount --bind /proc /mnt/proc
  mount --bind /sys /mnt/sys
  
  # Install arch-install-scripts
  apt install arch-install-scripts -y

  # Generate fstab
  echo "Generating fstab..."
  genfstab -U /mnt >> /mnt/etc/fstab

  # Chroot into the new system
  echo "Chrooting into the new system..."
chroot /mnt /bin/bash -x <<'EOF'
  # Set the apt sources
  echo "deb http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware" > /etc/apt/sources.list
  echo "deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware" >> /etc/apt/sources.list
  echo "deb http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware" >> /etc/apt/sources.list
  echo "deb http://deb.debian.org/debian/ bookworm-backports main contrib non-free non-free-firmware" >> /etc/apt/sources.list

  # Update the package database
  apt update

  # Install the core packages
  apt install firmware-linux firmware-linux-nonfree sudo vim git -y

  # Set the timezone
  ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
  hwclock --systohc

  # Set the locale
  sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
  locale-gen
  echo "LANG=en_US.UTF-8" > /etc/locale.conf

  # Set the hostname
  echo "$HOSTNAME" > /etc/hostname

  # Set the hosts file
  echo "127.0.0.1 localhost" > /etc/hosts
  echo "127.0.1.1 $HOSTNAME.lan $HOSTNAME" >> /etc/hosts
  echo "::1 localhost ip6-localhost ip6-loopback" >> /etc/hosts
  echo "ff02::1 ip6-allnodes" >> /etc/hosts
  echo "ff02::2 ip6-allrouters" >> /etc/hosts

  # Detect the network interface
  net_interface=$(ip link | awk '/state UP/ {print $2}' | sed 's/://')

  # Configure the network
  echo "auto lo" > /etc/network/interfaces
  echo "iface lo inet loopback" >> /etc/network/interfaces
  echo "" >> /etc/network/interfaces
  echo "auto $net_interface" >> /etc/network/interfaces
  echo "iface $net_interface inet dhcp" >> /etc/network/interfaces

  # Set up network tools
  apt install dhcpcd5 network-manager wireless-tools wpasupplicant dialog -y

  # Set the root password
  echo "Enter the root password:"
  passwd

  # Create a user
  echo "Creating $USERNAME user..."
  useradd "$USERNAME" -m -c "$NAME" -s /bin/bash
  echo "Enter the user password:"
  passwd "$USERNAME"

  # Add the user to the sudo group
  usermod -aG sudo "$USERNAME"
  # Add the user to the wheel group
  usermod -aG wheel "$USERNAME"

  # Installing boot loader utilities
  apt install efibootmgr btrfs-progs os-prober cryptsetup ntfs-3g mtools dosfstools zstd -y

  # Set up encryption parameters
  echo "Setting up encryption parameters..."
  echo "cryptroot UUID=$(blkid -s UUID -o value /dev/$crypt) none luks" > /etc/crypttab

  # Update grub
  echo "Updating grub..."
  sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/GRUB_CMDLINE_LINUX_DEFAULT="quiet cryptdevice=UUID=$(blkid -s UUID -o value /dev/$crypt):cryptroot"/' /etc/default/grub
  sed -i 's/GRUB_CMDLINE_LINUX=""/GRUB_CMDLINE_LINUX="cryptdevice=UUID=$(blkid -s UUID -o value /dev/$crypt):cryptroot"/' /etc/default/grub
  echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub

  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=DEBIAN

  update-grub

  update-initramfs -u -k all
EOF
    umount -a

    reboot
}

main "$@"
