#!/bin/env bash

# environment_variables.sh
 # Author: Daniel Pellegrino
 # Date Created: 12/20/2023
 # Last Modified: 12/20/2023
 # Description: Creates environment variables used accross the scripts.

# Check if the script is being run by the install.sh script.
if [[ $RUN != 1 ]]; then
  echo "Please run the script with the install.sh script."
  exit 1
fi

# Variables
export HOSTNAME="debian"
export USERNAME="daniel"
export NAME="Daniel"
export LUKS_NAME="cryptroot"
export TIMEZONE="America/New_York"
export DEBIAN_TARGET="trixie"

