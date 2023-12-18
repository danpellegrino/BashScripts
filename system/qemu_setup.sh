#!/usr/bin/env bash

# qemu_setup.sh
 # Author: Daniel Pellegrino
 # Date Created: 12/17/2023
 # Last Modified: 12/18/2023
 # Description: This script will install qemu and setup a virtual machine.


# Variables

USER_HOME=$(getent passwd $SUDO_USER | cut -d: -f6)

main ()
{
  # Verify that the script is being run as root.
  if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit
  fi

  # Verify the user has virtualization enabled.
  if [ ! -f /proc/cpuinfo ]; then
    echo "Unable to verify virtualization."
    echo "Please run this script on a physical machine."
    exit
  fi
  if ! grep -q vmx /proc/cpuinfo; then
    echo "Virtualization is not enabled."
    exit
  fi


  # Check what distribution is being used.
  # Source: https://unix.stackexchange.com/questions/6345/how-can-i-get-distribution-name-and-version-number-in-a-simple-shell-script
  if [ -f /etc/os-release ]; then
    # freedesktop.org and systemd
    . /etc/os-release
    OS=$NAME
    VER=$VERSION_ID
  elif type lsb_release >/dev/null 2>&1; then
    # linuxbase.org
    OS=$(lsb_release -si)
    VER=$(lsb_release -sr)
  elif [ -f /etc/lsb-release ]; then
    # For some versions of Debian/Ubuntu without lsb_release command
    . /etc/lsb-release
    OS=$DISTRIB_ID
    VER=$DISTRIB_RELEASE
  elif [ -f /etc/debian_version ]; then
    # Older Debian/Ubuntu/etc.
    OS=Debian
    VER=$(cat /etc/debian_version)
  elif [ -f /etc/SuSe-release ]; then
    # Older SuSE/etc.
    ...
  elif [ -f /etc/redhat-release ]; then
    # Older Red Hat, CentOS, etc.
    ...
  else
    # Fall back to uname, e.g. "Linux <version>", also works for BSD, etc.
    OS=$(uname -s)
    VER=$(uname -r)
  fi

  echo "$OS $VER detected."

  # Install qemu and other required packages.
  if [[ "$OS" = "Debian GNU/Linux" && "$VER" = "12" ]]; then
    apt-get install qemu-kvm qemu-system qemu-utils python3 python3-pip libvirt-clients libvirt-daemon-system bridge-utils virtinst libvirt-daemon virt-manager -y
  else
    echo "Unsupported distribution."
    exit
  fi

  # "libvirtd" is the service that runs the virtual machines.
  libvirtd_service

  # The user needs to be part of the libvirt, libvirt-qemu, kvm, input, and disk groups.
  add_groups
  
  # The default network needs to be started and enabled.
  default_network

  # Give the user ability to run virsh without sudo.
  # Source: https://serverfault.com/questions/803283/how-do-i-list-virsh-networks-without-sudo
  if [ -f /etc/libvirt/libvirt.conf ]; then
    sed -i 's/#uri_default = "qemu:\/\/\/system"/uri_default = "qemu:\/\/\/system"/g' /etc/libvirt/libvirt.conf
    cp /etc/libvirt/libvirt.conf $USER_HOME/.config/libvirt/libvirt.conf
    chown $SUDO_USER:$SUDO_USER $USER_HOME/.config/libvirt/libvirt.conf
    echo "The user $SUDO_USER can now run virsh without sudo."
  else
    echo "Unable to find /etc/libvirt/libvirt.conf"
    exit
  fi

  # Create an ISO directory.
  if [ ! -d /var/lib/libvirt/images/iso ]; then
    mkdir -p /var/lib/libvirt/images/iso
    echo "Created /var/lib/libvirt/images/iso"
    echo "Please copy your ISO files to this directory."
  else
    echo "/var/lib/libvirt/images/iso already exists."
  fi

  # Set up the ISO pool.
  if ! virsh pool-list --all | grep -q "iso"; then
    virsh pool-define-as --name iso --type dir --target /var/lib/libvirt/images/iso
    echo "Created the iso pool."
  else
    echo "The iso pool already exists."
  fi

  # Start the ISO pool.
  if virsh pool-list --all | grep "iso" | grep -q "inactive"; then
    virsh pool-start iso
    echo "Starting the iso pool."
  else
    echo "The iso pool is already running."
  fi

  # Set the ISO pool to autostart.
  if ! virsh pool-list --autostart | grep -q "iso"; then
    virsh pool-autostart iso
    echo "Enabling the iso pool."
  else
    echo "The iso pool is already enabled."
  fi
}

# Functions

# libvirtd_service: This function will start and enable the libvirtd service.
libvirtd_service ()
{
  # Verify that Libvirt is running.
  if ! systemctl is-active --quiet libvirtd; then
   systemctl start libvirtd
   echo "Starting libvirtd."
  fi

  # Verify that Libvirt is enabled.
  if ! systemctl is-enabled --quiet libvirtd; then
    systemctl enable libvirtd
    echo "Enabling libvirtd."
  fi

  # Check for any errors.
  if ! systemctl status libvirtd | grep -q "Active: active (running)"; then
    echo "There was an error starting libvirtd."
    exit
  fi
}

# add_groups: This function will add the user to the libvirt, libvirt-qemu, kvm, input, and disk groups.
add_groups ()
{
  # Verify that the user is in the libvirt group.
  if ! groups $SUDO_USER | grep -q libvirt; then
    echo "Adding $SUDO_USER to the libvirt group."
    usermod -a -G libvirt "$SUDO_USER"
    sleep 1
    # Check for any errors.
    if ! groups $SUDO_USER | grep -q libvirt; then
      echo "There was an error adding $SUDO_USER to the libvirt group."
      exit
    fi
  else
    echo "$SUDO_USER is already in the libvirt group."
  fi

  # Verify that the user is in the libvirt-qemu group.
  if ! groups $SUDO_USER | grep -q libvirt-qemu; then
    echo "Adding $SUDO_USER to the libvirt-qemu group."
    usermod -a -G libvirt-qemu $SUDO_USER
    sleep 1
    # Check for any errors.
    if ! groups $SUDO_USER | grep -q libvirt-qemu; then
      echo "There was an error adding $SUDO_USER to the libvirt-qemu group."
      exit
    fi
  else
    echo "$SUDO_USER is already in the libvirt-qemu group."
  fi

  # Verify that the user is in the kvm group.
  if ! groups $SUDO_USER | grep -q kvm; then
    echo "Adding $SUDO_USER to the kvm group."
    usermod -a -G kvm $SUDO_USER
    sleep 1
    # Check for any errors.
    if ! groups $SUDO_USER | grep -q kvm; then
      echo "There was an error adding $SUDO_USER to the kvm group."
      exit
    fi
  else
    echo "$SUDO_USER is already in the kvm group."
  fi

  # Verify that the user is in the input group.
  if ! groups $SUDO_USER | grep -q input; then
    echo "Adding $SUDO_USER to the input group."
    usermod -a -G input $SUDO_USER
    sleep 1
    # Check for any errors.
    if ! groups $SUDO_USER | grep -q input; then
      echo "There was an error adding $SUDO_USER to the input group."
      exit
    fi
  else
    echo "$SUDO_USER is already in the input group."
  fi

  # Verify that the user is in the disk group.
  if ! groups $SUDO_USER | grep -q disk; then
    echo "Adding $SUDO_USER to the disk group."
    usermod -a -G disk $SUDO_USER
    sleep 1
    # Check for any errors.
    if ! groups $SUDO_USER | grep -q disk; then
      echo "There was an error adding $SUDO_USER to the disk group."
      exit
    fi
  else
    echo "$SUDO_USER is already in the disk group."
  fi

}

# default_network: This function will start and enable the default network.
default_network ()
{
  # Start the default network.
  if virsh net-list --all | grep -q "inactive"; then
    virsh net-start default
    echo "Starting the default network."
  else 
    echo "The default network is already running."
  fi

  # Enable the default network.
  if ! virsh net-list --autostart | grep -q "default"; then
    virsh net-autostart default
    echo "Enabling the default network."
  else
    echo "The default network is already enabled."
  fi

  # Check for any errors.
  if ! virsh net-list --all | grep -q "default"; then
    echo "There was an error starting the default network."
    exit
  fi
}

main "$@"
