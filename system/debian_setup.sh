#!/usr/bin/env bash

# debian_setup.sh
 # Author: Daniel Pellegrino
 # Date Created: 12/18/2023
 # Last Modified: 12/18/2023
 # Description: This script will install debian using debootstrap.

main ()
{
  # Check if user is root
  if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
  fi

  # Verify the user has all the scripts needed
  if [ ! -f environment_variables.sh ]; then
    echo "environment_variables.sh not found. Exiting."
    exit 1
  else
    chmod +x environment_variables.sh
    source environment_variables.sh
  fi
  if [ ! -f custom_setup.sh ]; then
    echo "custom_setup.sh not found. Exiting."
    exit 1
  else
    chmod +x custom_setup.sh
  fi
  if [ ! -f debian_setup_pkglist ]; then
    echo "debian_setup_pkglist not found. Exiting."
    exit 1
  fi

  partition_setup

  format_and_mount

  install_base_system

  setup_base_system

  setup_network

  setup_root

  setup_user

  install_packages

  extra_packages_prompt
}

partition_setup ()
{
  apt update && apt install zenity -y

  # Have the user select the disk (only include real disks)
  while true; do
    # List the size of the disks
    zenity --info --text="Select the disk you want to install Debian on. Only real disks will be shown."
    # Get a list of available disks using lsblk and store the output in a variable
    disks=$(lsblk -d -n -p -o NAME,SIZE | awk '{print $1 " (" $2 ")"}' | grep -v -e "loop" -e "sr")

    # Create an array to store individual disk entries
    disk_list=()
    while read -r line; do
      disk_list+=("$line")
    done <<< "$disks"
    # Show a dialog with a list of disks and ask the user to select one
    selected_disk=$(zenity --list --title="Select Disk for Debian Installation" --column="Disks" "${disk_list[@]}" --width=300 --height=300)

    if [ -z "$selected_disk" ]; then
      zenity --error --text="No disk selected."
      continue
    fi

    # Get the disk name from the selected disk
    DISK=$(echo "$selected_disk" | awk '{print $1}')
    zenity --question --text="Is $DISK the correct disk?"
    if [ $? -eq 0 ]; then
      zenity --warning --text="All data on $DISK will be erased. This cannot be undone."
      zenity --question --title="ALL DATA ON $DISK WILL BE ERASED" --text="Are you sure you want to continue?"
      if [ $? -eq 0 ]; then
        break
      fi
    fi
  done

  # Tell the user that the installation will begin and warn them not to stop the script
  zenity --info --text="The installation will now begin."
  zenity --warning --text="Do not stop the script until the installation is complete."

  # Create a partition table
  parted -s "$DISK" mklabel gpt

  # Create a EFI partition
  parted -s "$DISK" mkpart primary fat32 1MiB 512MiB

  # Create a boot partition
  parted -s "$DISK" mkpart primary ext4 512MiB 1536MiB

  # Create an encrypted btrfs partition
  parted -s "$DISK" mkpart primary btrfs 1536MiB 100%

  # Set the boot flag
  parted -s "$DISK" set 2 boot on

  # Check to see if the disk ends in a number
  # If it does, add a p to the end
  if [[ "$DISK" =~ [0-9]$ ]]; then
    EFI="$DISK""p""1"
    BOOT="$DISK""p""2"
    CRYPT="$DISK""p""3"
  else
    EFI="$DISK""1"
    BOOT="$DISK""2"
    CRYPT="$DISK""3"
  fi

}

format_and_mount ()
{
  # Ask the user to create a password for the encrypted partition
  touch /tmp/password
  touch /tmp/verify
  chmod 600 /tmp/password
  chmod 600 /tmp/verify
  while true; do
    zenity --password --title="Enter Encryption Password" \
    --timeout=60 > /tmp/password
    # Verify the password will meet the minimum requirements
    # If it doesnt, ask the user to try again
    if [ "$(cat /tmp/password | wc -c)" -lt 8 ]; then
      zenity --error --text="Password must be at least 8 characters long. Please try again."
      continue
    fi
    # Verify the password is correct
    zenity --password --title="Verify Encryption Password" \
    --timeout=60 > /tmp/verify
    # Compare the passwords
    # If they match, break out of the loop
    if [ "$(cat /tmp/password)" = "$(cat /tmp/verify)" ]; then
      rm /tmp/verify
      break
    fi
    zenity --error --text="Passwords do not match. Please try again."
  done

  # Format the partitions
  mkfs.fat -F32 "$EFI"

  # This will give a warning if an existing filesystem is found
  # To suppress the warning, add -F to the command
  mkfs.ext4 -F "$BOOT"

  printf '%s' "$(cat /tmp/password)" | cryptsetup luksFormat --type luks2 "$CRYPT" -
  printf '%s' "$(cat /tmp/password)" | cryptsetup open "$CRYPT" "$LUKS_NAME" -
  rm /tmp/password
  mkfs.btrfs /dev/mapper/"$LUKS_NAME"

   # Mount to create subvolumes
  mount /dev/mapper/"$LUKS_NAME" /mnt

  # Create the subvolumes
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
  mount -o subvol=@,noatime,compress=zstd:1 /dev/mapper/"$LUKS_NAME" /mnt
  mkdir -p /mnt/{boot,.snapshots,home,root,var/log,var/lib/AccountsService,var/lib/gdm3,tmp,opt,var/lib/libvirt/images,var/lib/containers}

  mount -o subvol=@snapshots,noatime,compress=zstd:1       /dev/mapper/"$LUKS_NAME" /mnt/.snapshots
  mount -o subvol=@home,noatime,compress=zstd:1            /dev/mapper/"$LUKS_NAME" /mnt/home
  mount -o subvol=@root,noatime,compress=zstd:1            /dev/mapper/"$LUKS_NAME" /mnt/root
  mount -o subvol=@log,noatime,compress=zstd:1             /dev/mapper/"$LUKS_NAME" /mnt/var/log
  mount -o subvol=@AccountsService,noatime,compress=zstd:1 /dev/mapper/"$LUKS_NAME" /mnt/var/lib/AccountsService
  mount -o subvol=@gdm,noatime,compress=zstd:1             /dev/mapper/"$LUKS_NAME" /mnt/var/lib/gdm3
  mount -o subvol=@tmp,noatime,compress=zstd:1             /dev/mapper/"$LUKS_NAME" /mnt/tmp
  mount -o subvol=@opt,noatime,compress=zstd:1             /dev/mapper/"$LUKS_NAME" /mnt/opt
  mount -o subvol=@images,noatime,compress=zstd:1          /dev/mapper/"$LUKS_NAME" /mnt/var/lib/libvirt/images
  mount -o subvol=@containers,noatime,compress=zstd:1      /dev/mapper/"$LUKS_NAME" /mnt/var/lib/containers

  # Mount the boot partition
  mount "$BOOT" /mnt/boot
  mkdir -p /mnt/boot/efi
  mount "$EFI" /mnt/boot/efi
}

install_base_system ()
{
  # Install debootstrap
  apt update && apt install debootstrap -y

  # Install the base system
  debootstrap --arch amd64 $DEBIAN_TARGET /mnt http://deb.debian.org/debian/

  # Set the apt sources
  echo "deb http://deb.debian.org/debian/ $DEBIAN_TARGET main contrib non-free non-free-firmware" > /mnt/etc/apt/sources.list
  echo "deb http://security.debian.org/debian-security $DEBIAN_TARGET-security main contrib non-free non-free-firmware" >> /mnt/etc/apt/sources.list
  # Add the updates and backports repositories (only available for stable)
  if [ "$DEBIAN_TARGET" = "bookworm" ]; then
    echo "deb http://deb.debian.org/debian/ $DEBIAN_TARGET-updates main contrib non-free non-free-firmware" >> /mnt/etc/apt/sources.list
    echo "deb http://deb.debian.org/debian/ $DEBIAN_TARGET-backports main contrib non-free non-free-firmware" >> /mnt/etc/apt/sources.list
  fi

  # Install arch-install-scripts and generate fstab
  apt update && apt install arch-install-scripts -y
  genfstab -U /mnt >> /mnt/etc/fstab

  # Set up encryption parameters
  echo "$LUKS_NAME UUID=$(blkid -s UUID -o value $CRYPT) none luks,discard" > /mnt/etc/crypttab

  # Mount virtual filesystems
  for dir in dev proc sys run; do
    mount --rbind /$dir /mnt/$dir && mount --make-rslave /mnt/$dir
  done
  cp /etc/resolv.conf /mnt/etc/resolv.conf
}

setup_base_system ()
{
  # Set the hostname
  echo $HOSTNAME > /mnt/etc/hostname
}

setup_network ()
{
  echo "127.0.0.1 localhost" > /mnt/etc/hosts
  echo "127.0.1.1 $HOSTNAME" >> /mnt/etc/hosts
  echo "" >> /mnt/etc/hosts
  echo "# The following lines are desirable for IPv6 capable hosts" >> /mnt/etc/hosts
  echo "::1 localhost ip6-localhost ip6-loopback" >> /mnt/etc/hosts
  echo "ff02::1 ip6-allnodes" >> /mnt/etc/hosts
  echo "ff02::2 ip6-allrouters" >> /mnt/etc/hosts

  # Configure the network
  echo "# This file describes the network interfaces available on your system" > /mnt/etc/network/interfaces
  echo "# and how to activate them. For more information, see interfaces(5)." >> /mnt/etc/network/interfaces
  echo "" >> /mnt/etc/network/interfaces
  echo "source /etc/network/interfaces.d/*" >> /mnt/etc/network/interfaces
  echo "" >> /mnt/etc/network/interfaces
  echo "# The loopback network interface" >> /mnt/etc/network/interfaces
  echo "auto lo" >> /mnt/etc/network/interfaces
  echo "iface lo inet dhcp" >> /mnt/etc/network/interfaces
}

setup_root ()
{
  # Ask the user if they want to be able to login as root
  ROOT_LOGIN=$(zenity --question --text="Do you want to be able to login as root?")
  if [ $? -eq 0 ]; then
    # Set the root password
    touch /tmp/password
    touch /tmp/verify
    chmod 600 /tmp/password
    chmod 600 /tmp/verify
    while true; do
      zenity --password --title="Enter Root Password" \
      --timeout=60 > /tmp/password
      # Verify the password will meet the minimum requirements
      # If it doesnt, ask the user to try again
      if [ "$(cat /tmp/password | wc -c)" -lt 8 ]; then
        zenity --error --text="Password must be at least 8 characters long. Please try again."
        continue
      fi
      # Verify the password is correct
      zenity --password --title="Verify Root Password" \
      --timeout=60 > /tmp/verify
      # Compare the passwords
      # If they match, break out of the loop
      if [ "$(cat /tmp/password)" = "$(cat /tmp/verify)" ]; then
        rm /tmp/verify
        break
      fi
      zenity --error --text="Passwords do not match. Please try again."
    done
    echo "root:$(cat /tmp/password)" | chroot /mnt chpasswd
    rm /tmp/password
    # Unlock the root account
    chroot /mnt passwd -u root
  else
    # Lock the root account
    chroot /mnt passwd -l root
  fi
}

setup_user ()
{
  # Prompt user that they'll be creating the user account
  zenity --info --text="You will now be asked to create a user account."

  # Ask the user to create a password for the user account
  touch /tmp/password
  touch /tmp/verify
  chmod 600 /tmp/password
  chmod 600 /tmp/verify

  while true; do
    zenity --password --title="Enter User Password" \
    --timeout=60 > /tmp/password
    # Verify the password will meet the minimum requirements
    # If it doesnt, ask the user to try again
    if [ "$(cat /tmp/password | wc -c)" -lt 8 ]; then
      zenity --error --text="Password must be at least 8 characters long. Please try again."
      continue
    fi
    # Verify the password is correct
    zenity --password --title="Verify User Password" \
    --timeout=60 > /tmp/verify
    # Compare the passwords
    # If they match, break out of the loop
    if [ "$(cat /tmp/password)" = "$(cat /tmp/verify)" ]; then
      rm /tmp/verify
      break
    fi
    zenity --error --text="Passwords do not match. Please try again."
  done

  chroot /mnt useradd "$USERNAME" -m -c "$NAME" -s /bin/bash
  chroot /mnt usermod -aG sudo "$USERNAME"
  echo "$USERNAME:$(cat /tmp/password)" | chroot /mnt chpasswd
  rm /tmp/password
}

install_packages ()
{
  # Configure locales and timezone
  chroot /mnt apt update
  chroot /mnt apt install dialog locales -y

  echo "$TIMEZONE" > /mnt/etc/timezone
  chroot /mnt ln -sf /usr/share/zoneinfo/$(cat /mnt/etc/timezone) /etc/localtime
  chroot /mnt dpkg-reconfigure -f noninteractive tzdata
  chroot /mnt timedatectl set-timezone $(cat /mnt/etc/timezone)
  sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /mnt/etc/locale.gen
  echo 'LANG="en_US.UTF-8"' > /mnt/etc/default/locale
  chroot /mnt dpkg-reconfigure --frontend=noninteractive locales
  chroot /mnt update-locale LANG=en_US.UTF-8

cat << EOF | chroot /mnt
  set -e
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install keyboard-configuration console-setup -y
EOF
  echo "# KEYBOARD CONFIGURATION FILE" > /mnt/etc/default/keyboard
  echo "" >> /mnt/etc/default/keyboard
  echo "# Consult the keyboard(5) manual page." >> /mnt/etc/default/keyboard
  echo "" >> /mnt/etc/default/keyboard
  echo "XKBMODEL=\"pc105\"" >> /mnt/etc/default/keyboard
  echo "XKBLAYOUT=\"us\"" >> /mnt/etc/default/keyboard
  echo "XKBVARIANT=\"\"" >> /mnt/etc/default/keyboard
  echo "XKBOPTIONS=\"\"" >> /mnt/etc/default/keyboard
  echo "" >> /mnt/etc/default/keyboard
  echo "BACKSPACE=\"guess\"" >> /mnt/etc/default/keyboard
  chroot /mnt dpkg-reconfigure -f noninteractive keyboard-configuration

cat << EOF | chroot /mnt
  set -e
  apt-get update
  apt-get install -y  linux-image-amd64 \
                      linux-headers-amd64 \
                      firmware-linux \
                      grub-efi \
                      efibootmgr \
                      btrfs-progs \
                      os-prober \
                      cryptsetup \
                      cryptsetup-initramfs \
                      ntfs-3g \
                      mtools \
                      dosfstools \
                      zstd \
                      network-manager \
                      wireless-tools \
                      wpasupplicant \
                      sudo
EOF

  # Change GRUB to exlude the nouveau driver
  sed -i -e 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/GRUB_CMDLINE_LINUX_DEFAULT="quiet nouveau.modeset=0"/' /mnt/etc/default/grub

  # Install grub
  chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian
  chroot /mnt update-grub

  chroot /mnt update-initramfs -u -k all
  # Add the nvidia driver repository

  # Start/Disable services
  chroot /mnt systemctl enable NetworkManager
  # networking.service fails to start on trixie
  if [ "$DEBIAN_TARGET" = "trixie" ]; then
    chroot /mnt systemctl disable networking.service
  fi
}

extra_packages_prompt ()
{
  zenity --question --text="The base system has been installed. Anything further is customized towards my setup."
  if [ "$?" -eq 0 ]; then
    source custom_setup.sh
    unmount_base_system
  else 
    unmount_base_system
  fi
}

unmount_base_system ()
{
  umount -R /mnt
  cryptsetup close "$LUKS_NAME"

  zenity --info --text="Installation complete. You can now reboot."
}

# Main
main "$@"
