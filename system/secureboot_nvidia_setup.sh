#!/usr/bin/env bash

# secureboot_nvidia_setup.sh
 # Author: Daniel Pellegrino
 # Date Created: 12/18/2023
 # Last Modified: 12/18/2023
 # Description: This script is used to setup secure boot on Debian 12 (Bookworm) when using the proprietary Nvidia drivers.


main ()
{
  # Check if the script is being run as root
  if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
  fi

  # Check if the system is running on UEFI
  # If not, exit the script
  if [[ ! -d /sys/firmware/efi ]]; then
    echo "This script only works on UEFI systems"
    exit 1
  fi

  # Install the required packages
  apt install -y sbsigntool mokutil -y

  # Check if secure boot is enabled
  if [[ $(mokutil --sb-state) != "SecureBoot enabled" ]]; then
    echo "Secure boot is not enabled."
    echo "Please enable secure boot from your BIOS and run this script again."
    exit 1
  fi

  if [[ -f /var/lib/shim-signed/mok/reboot-required ]]; then
    after_reboot
    rm /var/lib/shim-signed/mok/reboot-required
  else
    before_reboot
    touch /var/lib/shim-signed/mok/reboot-required
    sleep 10
    reboot
  fi

}

# Functions

# This function is run before the system reboots
before_reboot ()
{
  # Verify that a key pair does not already exist
  if [[ -f /var/lib/shim-signed/mok/MOK.priv && -f /var/lib/shim-signed/mok/MOK.der ]]; then
    echo "A key pair already exists."
    echo "Please delete the existing key pair and run this script again."
    exit 1
  fi

  # Create the directory for the key pair
  mkdir -p /var/lib/shim-signed/mok

  # Create a key pair
  openssl req -new -x509 -newkey rsa:2048 -subj "/CN=Nvidia/" -keyout /var/lib/shim-signed/mok/MOK.priv -outform DER -out /var/lib/shim-signed/mok/MOK.der -days 36500

  openssl x509 -inform der -in /var/lib/shim-signed/mok/MOK.der -out /var/lib/shim-signed/mok/MOK.pem

  mokutil --import /var/lib/shim-signed/mok/MOK.der

  echo "Rebooting the system to enroll the key pair."
  echo "Please follow the instructions on the screen to enroll the key pair."
  echo "The system will reboot after the key pair is enrolled."
  echo
  echo "After the system reboots, run this script again to finalize the installation."
}

# This function is run after the system reboots
after_reboot ()
{
  # Install the Nvidia drivers
  apt-get install nvidia-settings nvidia-kernel-dkms nvidia-cuda-mps nvidia-driver nvidia-cuda-mps vulkan-tools firmware-linux firmware-linux-nonfree firmware-misc-nonfree nvidia-kernel-dkms -y

  # Adding key to DKMS (/etc/dkms/framework.conf)
  echo "mok_signing_key=/var/lib/shim-signed/mok/MOK.priv" >> /etc/dkms/framework.conf
  echo "mok_certificate=/var/lib/shim-signed/mok/MOK.der" >> /etc/dkms/framework.conf
  echo "sign_tool=/etc/dkms/sign_helper.sh" >> /etc/dkms/framework.conf

  echo "/lib/modules/"$1"/build/scripts/sign-file sha512 /root/.mok/client.priv /root/.mok/client.der "$2"" > /etc/dkms/sign_helper.sh
  chmod +x /etc/dkms/sign_helper.sh

  # Sign the Nvidia kernel module
  VERSION="$(uname -r)"
  SHORT_VERSION="$(uname -r | cut -d . -f 1-2)"
  MODULES_DIR=/lib/modules/$VERSION
  KBUILD_DIR=/usr/lib/linux-kbuild-$SHORT_VERSION

  # Sign the Nvidia kernel module
  sbsign --key /var/lib/shim-signed/mok/MOK.priv --cert /var/lib/shim-signed/mok/MOK.pem "/boot/vmlinuz-$VERSION" --output "/boot/vmlinuz-$VERSION.tmp"
  mv "/boot/vmlinuz-$VERSION.tmp" "/boot/vmlinuz-$VERSION"
  
  # Using your key to sign modules (Traditional Way)
  read -s -p "Enter the password for the key pair (MOK PEM pass phrase): " KBUILD_SIGN_PIN

  find "$MODULES_DIR/updates/dkms"/*.ko | while read i; do sudo --preserve-env=KBUILD_SIGN_PIN "$KBUILD_DIR"/scripts/sign-file sha256 /var/lib/shim-signed/mok/MOK.priv /var/lib/shim-signed/mok/MOK.der "$i" || break; done

  unset KBUILD_SIGN_PIN

  update-initramfs -k all -u
}

main "$@"
