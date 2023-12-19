#!/usr/bin/env bash

# This script is used to setup secure boot on Debian 12 (Bookworm) when using the proprietary Nvidia drivers.

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
  apt install -y sbsigntools mokutil

  # Check if secure boot is enabled
  if [[ $(mokutil --sb-state) != "SecureBoot enabled" ]]; then
    echo "Secure boot is not enabled."
    echo "Please enable secure boot from your BIOS and run this script again."
    exit 1
  fi

  if [[ -f /var/run/reboot-required ]]; then
    after_reboot
    rm /var/run/reboot-required
    rm /var/lib/shim-signed/mok/password
  else
    before_reboot
    touch /var/run/reboot-required
    sleep 5
    reboot
  fi

}

before_reboot ()
{
  # Verify that a key pair does not already exist
  if [[ -f /var/lib/shim-signed/mok/MOK.priv && -f /var/lib/shim-signed/mok/MOK.der ]]; then
    echo "A key pair already exists."
    echo "Please delete the existing key pair and run this script again."
    exit 1
  fi

  # Create a password for the key pair
  # The password will be used to sign the Nvidia kernel module
  read -s -p "Enter a password for the key pair (MOK PEM pass phrase): " PASSWORD

  # Store the password for later use
  touch /var/lib/shim-signed/mok/password
  chmod 600 /var/lib/shim-signed/mok/password
  echo $PASSWORD > /var/lib/shim-signed/mok/password

  # Free up the password variable
  # This is done to prevent the password from being stored in the shell history
  unset PASSWORD

  # Create a key pair
  openssl req -new -x509 -newkey rsa:2048 -subj "/CN=Nvidia/" -keyout /var/lib/shim-signed/mok/MOK.priv -outform DER -out /var/lib/shim-signed/mok/MOK.der -days 36500 --passout file:/var/lib/shim-signed/mok/password

  openssl x509 -inform der -in /var/lib/shim-signed/mok/MOK.der -out /var/lib/shim-signed/mok/MOK.pem

  mokutil --import /var/lib/shim-signed/mok/MOK.der --pass $(cat /var/lib/shim-signed/mok/password)

  echo "Rebooting the system to enroll the key pair."
  echo "Please follow the instructions on the screen to enroll the key pair."
  echo "The system will reboot after the key pair is enrolled."
  echo
  echo "After the system reboots, run this script again to finalize the installation."
}

after_reboot ()
{
  # Install the Nvidia drivers
  apt-get install nvidia-settings nvidia-kernel-dkms nvidia-cuda-mps nvidia-driver nvidia-cuda-mps vulkan-tools firmware-linux firmware-linux-nonfree firmware-misc-nonfree nvidia-kernel-dkms 

  # Sign the Nvidia kernel module
  VERSION="$(uname -r)"
  SHORT_VERSION="$(uname -r | cut -d . -f 1-2)"
  MODULES_DIR=/lib/modules/$VERSION
  KBUILD_DIR=/usr/lib/linux-kbuild-$SHORT_VERSION

  # Sign the Nvidia kernel module
  for i in $(find $MODULES_DIR/updates/dkms -type f -name '*.ko'); do
    echo "Signing $i"
    sleep 1
    --preserve-environment=$(cat /var/lib/shim-signed/mok/password) \
      "$KBUILD_DIR"/scripts/sign-file sha256 \
      /var/lib/shim-signed/mok/MOK.priv \
      /var/lib/shim-signed/mok/MOK.der "$i"
  done

  # Update the initramfs
  # This is done to ensure that the Nvidia kernel module is signed during boot
  update-initramfs -k all -u
}

main "$@"
