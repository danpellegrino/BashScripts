#!/usr/bin/env bash

# debian_chroot.sh
 # Author: Daniel Pellegrino
 # Date Created: 12/20/2023
 # Last Modified: 12/20/2023
 # Description: This script will chroot into my btrfs root partition.


# Variables

LUKS_NAME="cryptroot"

main ()
{
  # Check if user is root
  if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
  fi

  find_partitions

  unlock_luks

  mount_partitions

  completion_message
}

# Functions

find_partitions ()
{
  apt update && apt install zenity -y

  # Have the user select the disk (only include real disks)
  while true; do
    # List the size of the disks
    zenity --info --text="Select the disk you want to chroot into."
    # Get a list of available disks using lsblk and store the output in a variable
    disks=$(lsblk -d -n -p -o NAME,SIZE | awk '{print $1 " (" $2 ")"}' | grep -v -e "loop" -e "sr")

    # Create an array to store individual disk entries
    disk_list=()
    while read -r line; do
      disk_list+=("$line")
    done <<< "$disks"
    # Show a dialog with a list of disks and ask the user to select one
    selected_disk=$(zenity --list --title="Select Chroot Disk" --column="Disks" "${disk_list[@]}" --width=300 --height=300)

    if [ -z "$selected_disk" ]; then
      zenity --error --text="No disk selected."
      continue
    fi

    # Get the disk name from the selected disk
    DISK=$(echo "$selected_disk" | awk '{print $1}')
    zenity --question --text="Is $DISK the correct disk?"
    if [ $? -eq 0 ]; then
      break
    fi
  done

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

unlock_luks ()
{
  cryptsetup open "$CRYPT" "$LUKS_NAME"
}

mount_partitions ()
{
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

  # Mount virtual filesystems
  for dir in dev proc sys run; do
    mount --rbind /$dir /mnt/$dir && mount --make-rslave /mnt/$dir
  done
  cp /etc/resolv.conf /mnt/etc/resolv.conf
}

completion_message ()
{
  zenity --info --text="You can now chroot into /mnt"
  zenity --info --text="To chroot into /mnt, run the following command: chroot /mnt"
}

main "$@"
