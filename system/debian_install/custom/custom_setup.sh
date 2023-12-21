#!/usr/bin/env bash

# custom_setup.sh
 # Author: Daniel Pellegrino
 # Date Created: 12/20/2023
 # Last Modified: 12/20/2023
 # Description: This does everything post initial install script to setup it up as my personal system.

main ()
{
  # Check if the script is being run by the install.sh script.
  if [[ $RUN != 1 ]]; then
    echo "Please run the script with the install.sh script."
    exit 1
  fi

  # Update the system
  chroot /mnt apt update 

  install_packages

  zsh_setup

  secureboot
}

install_packages ()
{
  # Install the packages
  while read -r line; do
    # The first field is the package name and the second field is the description
    # The description is ignored
    package=$(echo "$line" | cut -d , -f 1)
    chroot /mnt sudo -E DEBIAN_FRONTEND=noninteractive apt install -y "$package"
  done < custom/pkglist.csv
}

zsh_setup ()
{
  # Install oh-my-zsh
  chroot /mnt sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
}

# Functions
secureboot ()
{
  # Prompt the user that Secure Boot keys will be created
  zenity --info --text="You will now be asked to create Secure Boot keys."

  # Ask the user to create a password for the PEM key pair
  touch /tmp/password
  touch /tmp/verify
  chmod 600 /tmp/password
  chmod 600 /tmp/verify

  while true; do
    zenity --password --title="Enter PEM Password" \
    --timeout=60 > /tmp/password
    # Verify the password will meet the minimum requirements
    # If it doesnt, ask the user to try again
    if [ "$(cat /tmp/password | wc -c)" -lt 8 ]; then
      zenity --error --text="Password must be at least 8 characters long. Please try again."
      continue
    fi
    # Verify the password is correct
    zenity --password --title="Verify PEM Password" \
    --timeout=60 > /tmp/verify
    # Compare the passwords
    # If they match, break out of the loop
    if [ "$(cat /tmp/password)" = "$(cat /tmp/verify)" ]; then
      rm /tmp/verify
      break
    fi
    zenity --error --text="Passwords do not match. Please try again."
  done

  KBUILD_SIGN_PIN=$(cat /tmp/password)
  rm /tmp/password
  export KBUILD_SIGN_PIN

  # Create a key pair
  mkdir -p /mnt/var/lib/shim-signed/mok

  chroot /mnt openssl req -new -x509 -newkey rsa:2048 -subj "/CN=Nvidia/" -keyout /var/lib/shim-signed/mok/MOK.priv -outform DER -out /var/lib/shim-signed/mok/MOK.der -days 36500 -passout pass:"$KBUILD_SIGN_PIN"

  chroot /mnt openssl x509 -inform der -in /var/lib/shim-signed/mok/MOK.der -out /var/lib/shim-signed/mok/MOK.pem

  # Make sure the keys are read only by root
  chmod 400 /mnt/var/lib/shim-signed/mok/MOK.*

  apt update && apt install whois -y

  # Prompt user that they'll be creating a MOK key pair
  zenity --info --text="You will now be asked to create a MOK key pair."

  # Ask the user to create a password for the MOK key pair
  touch /tmp/password
  touch /tmp/verify
  chmod 600 /tmp/password
  chmod 600 /tmp/verify

  while true; do
    zenity --password --title="Enter MOK Password" \
    --timeout=60 > /tmp/password
    # Verify the password will meet the minimum requirements
    # If it doesnt, ask the user to try again
    if [ "$(cat /tmp/password | wc -c)" -lt 8 ]; then
      zenity --error --text="Password must be at least 8 characters long. Please try again."
      continue
    fi
    # Verify the password is correct
    zenity --password --title="Verify MOK Password" \
    --timeout=60 > /tmp/verify
    # Compare the passwords
    # If they match, break out of the loop
    if [ "$(cat /tmp/password)" = "$(cat /tmp/verify)" ]; then
      rm /tmp/verify
      break
    fi
    zenity --error --text="Passwords do not match. Please try again."
  done

  touch /mnt/var/lib/shim-signed/mok/mok_password
  chmod 600 /mnt/var/lib/shim-signed/mok/mok_password
  mkpasswd -m sha512crypt --stdin <<< "$(cat /tmp/password)" > /mnt/var/lib/shim-signed/mok/mok_password
  rm /tmp/password
  chmod 400 /mnt/var/lib/shim-signed/mok/mok_password

  zenity --info --text="You will now be asked to enter the MOK password again.\nYou will also be asked to enter a MOK password at next boot.\nGo to Enroll MOK in the boot menu and enter the password you created."

  # Import the key
  chroot /mnt mokutil --hash-file /var/lib/shim-signed/mok/mok_password --import /var/lib/shim-signed/mok/MOK.der
  # Delete the password file
  rm /mnt/var/lib/shim-signed/mok/mok_password

  # Adding key to DKMS (/etc/dkms/framework.conf)
  echo "mok_signing_key=/var/lib/shim-signed/mok/MOK.priv" >> /mnt/etc/dkms/framework.conf
  echo "mok_certificate=/var/lib/shim-signed/mok/MOK.der" >> /mnt/etc/dkms/framework.conf
  echo "sign_tool=/etc/dkms/sign_helper.sh" >> /mnt/etc/dkms/framework.conf

  echo "/lib/modules/"$1"/build/scripts/sign-file sha512 /root/.mok/client.priv /root/.mok/client.der "$2"" > /mnt/etc/dkms/sign_helper.sh
  chroot /mnt chmod +x /etc/dkms/sign_helper.sh

  # Get the kernel version
  VERSION=$(ls /mnt/lib/modules | head -n 1)
  # Get the short version
  if [ "$DEBIAN_TARGET" = "bookworm" ]; then
    SHORT_VERSION=$(echo "$VERSION" | cut -d . -f 1-2)
  else
    # For trixie, the formatting is different
    SHORT_VERSION=$(echo "$VERSION" | cut -d - -f 1-2)
  fi
  # Get the modules directory
  MODULES_DIR="/lib/modules/$VERSION"
  # Get the kernel build directory
  KBUILD_DIR="/usr/lib/linux-kbuild-$SHORT_VERSION"

  # Sign the modules
  find /mnt/"$MODULES_DIR/updates/dkms"/*.ko | while read i; do sudo --preserve-env=KBUILD_SIGN_PIN /mnt/"$KBUILD_DIR"/scripts/sign-file sha256 /mnt/var/lib/shim-signed/mok/MOK.priv /mnt/var/lib/shim-signed/mok/MOK.der "$i" || break; done

  unset KBUILD_SIGN_PIN

  chroot /mnt update-initramfs -k all -u
}

# Main
main "$@"
