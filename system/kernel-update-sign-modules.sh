#!/bin/sh

# REF: https://wiki.debian.org/SecureBoot

# Verify the user is running this as sudo/root
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root. Use 'sudo' to run this script."
    exit 1
fi

# Remove previous Linux kernel
apt autoremove

# Set Linux kernel info variables
VERSION="$(uname -r)"
SHORT_VERSION="$(uname -r | cut -d . -f 1-2)"
MODULES_DIR=/lib/modules/$VERSION
KBUILD_DIR=/usr/lib/linux-kbuild-$SHORT_VERSION

# Using your key to sign your kernel
sbsign --key /var/lib/shim-signed/mok/MOK.priv --cert /var/lib/shim-signed/mok/MOK.pem "/boot/vmlinuz-$VERSION" --output "/boot/vmlinuz-$VERSION.tmp"
mv "/boot/vmlinuz-$VERSION.tmp" "/boot/vmlinuz-$VERSION"

# Using your key to sign modules (Traditional Way)
echo -n "Passphrase for the private key: "
read KBUILD_SIGN_PIN
export KBUILD_SIGN_PIN

find "$MODULES_DIR/updates/dkms"/*.ko | while read i; do sudo --preserve-env=KBUILD_SIGN_PIN "$KBUILD_DIR"/scripts/sign-file sha256 /var/lib/shim-signed/mok/MOK.priv /var/lib/shim-signed/mok/MOK.der "$i" || break; done
update-initramfs -k all -u

# Update GRUB
update-grub2
