#!/bin/bash
# Copyright 2020 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# MPI tuning script
# This script applies different system tunings for getting better performance
# for MPI application.
# This script is intended to be used on Google Cloud HPC Image.
# and is validated on GCP CentOS 7 image only.

# catch SIGEXIT and SIGINT
trap 'cleanup' EXIT
trap 'LOG "interrupted, cleaning up..."; cleanup' INT

readonly NIC="eth0"
readonly SYSCTL_CONF="/etc/sysctl.conf"
readonly LIMITS_CONF="/etc/security/limits.conf"
readonly LIMITSD_CONF="/etc/security/limits.d/98-google-hpc-image.conf"
readonly GRUB_DEFAULT="/etc/default/grub"
readonly SELINUX_CONFIG="/etc/selinux/config"
HPC_PROFILE="google-hpc-compute"
HPC_PROFILE_PATH="/usr/lib/tuned/google-hpc-compute/tuned.conf"
VMROOT="vmroot"
GRUB_FILE="/boot/grub2/grub.cfg"
ACTIVE_PROFILE="unknown"

verbose=false

# major and minor versions of Rocky Linux Release
# Current Version : Rocky Linux 8 - 4.18.0-372.9.1.el8.x86_64
rocky_major=0
rocky_minor=0

# el8+ kernel installed
# For Rocky Linux 8.6+, the default kernel (el8) has following options backported:
# Do not know, need to research on this.
# - nosmt: disable HT
# - mitigations=off: disable CPU vulnerability mitigations
new_elkernel=0

# subtask flags
task_all=0 # run all tasks (unsafe)
task_tcpmem=0 # tcpmem
task_limits=0 # limits.conf
task_ht=0 # hyperthreading
task_firewall=0 # firewall
task_selinux=0 # selinux
task_mitigations=0 # CPU mitigations
task_hpcprofile=0 # hpcprofile
task_reboot=0 # reboot system if necessary

need_reboot=0
dryrun=0

LOG() {
  if [[ ${dryrun} = 0 ]]; then
    printf "%s\n" "$*" >&2
  else
    printf "# %s\n" "$*" >&2
  fi
}

# LOGV prints only if verbose is set.
LOGV() {
  ${verbose} && LOG "$*"
}

IN_ERROR=false
# ERROR prints the error and exit.
ERROR() {
  ${IN_ERROR} && return
  IN_ERROR=true
  LOG "Error: $*"
  exit 1
}

# clean up
cleanup() {
  trap - INT EXIT
  if [[ "$need_reboot" = 1 ]]; then
    if [[ "$IN_ERROR" = "true" ]]; then
      echo "Execution aborted, reboot pending"
      exit 1
    fi

    if [[ "$task_reboot" = 1 ]]; then
      LOG "Reboot required"

      if [[ "$dryrun" = 1 ]]; then
        echo "systemctl reboot"
        exit 0
      fi
      echo "Reboot in 10 seconds (^C to cancel) ..."
      sleep 10
      systemctl reboot
    else
      LOG "Reboot required, please manually reboot your system"
    fi
  fi
}

# check if task(s) were selected
check_task() {
  [[ $task_all -gt 0 ]] && LOG "Selecting all tasks." && return

  [[ "$task_tcpmem" = 0 ]] && [[ "$task_limits" = 0 ]] && \
    [[ "$task_ht" = 0 ]] && [[ "$task_firewall" = 0 ]] && \
    [[ "$task_selinux" = 0 ]] && [[ "$task_mitigations" = 0 ]] && \
    [[ "$task_hpcprofile" = 0 ]] && \
    LOG "No task(s) selected." && show_usage && exit 1
}

# check if running as root
check_root() {
  [[ "$EUID" -ne 0 ]] && ERROR "Please run this script as root"
}

# check dependencies
check_bin() {
  local readonly deps="ethtool tuned-adm lscpu"
  fail=false

  for bin in $deps; do
    LOGV "Check dependency: $bin"
    binpath=$(command -v "$bin")
    if [[ -z $binpath ]]; then
      LOG "$bin not found"
      fail=true
    fi
  done

  ${fail} && ERROR "Please install missing dependencies"
}

# check if the ancillary scripts exist
check_vmroot() {
  # Ancillary scripts in current folder (from hpc-tools repo)
  local gitpath="$(pwd)/vmroot"
  # Ancillary scripts in _datadir (from google-hpc-compute package)
  local rpmpath="$(rpm --eval "%{_datadir}")/google-hpc-compute/mpi-tuning"
  if [ -d $gitpath ]; then
    VMROOT=$gitpath
    LOGV "Using ancillary scripts at $VMROOT"
  elif [ -d $rpmpath ]; then
    VMROOT=$rpmpath
    LOGV "Using ancillary scripts at $VMROOT"
  else
    ERROR "Cannot find ancillary scripts"
  fi
}

# check rocky linux release version
# allow --dryrun for non-rocky 8 system
check_rocky() {
  rocky_major=$(rpm --eval %{rocky_ver})

  if [[ $rocky_major -ne 8 ]]; then
    if [[ "$dryrun" = 1 ]]; then
      LOG "This script is only validated on Rocky Linux 8."
    else
      ERROR "This script is only validated on Rocky Linux 8."
    fi
  fi

  local rocky_ver=$(rpm --query rocky-release)
  local rocky_sub=${rocky_ver#"rocky-release-"}
  rocky_minor=$(echo $rocky_sub | awk -F'[.-]' '{print $2}')

  LOGV "Rocky Linux version: ${rocky_major}.${rocky_minor}"
}

# check if current kernel is Rocky Linux 8.6+ default
check_new_elkernel() {
  local uname=$(uname -r)
  if [[ "$rocky_major" -eq 8 ]] && [[ "$rocky_minor" -ge 8 ]] && \
    [[ "$uname" =~ "el8" ]]; then
    new_elkernel=1
    LOGV "Found el8+ kernel"
  fi
}

# check active tuned profile
get_active_profile() {
  ACTIVE_PROFILE=$(tuned-adm active | awk {'print $4'})
  LOGV "Current tuned profile ${ACTIVE_PROFILE}"
}

run() {
  if [[ "$dryrun" = 1 ]]; then
    echo "$*"
  else
    eval "$*"
  fi
}

update_sysctl() {
  local key=$1
  shift
  local value=$*
  LOGV "Updating sysctl key=$key, value=$value"
  touch $SYSCTL_CONF
  local regex="'s/^\s*$key\s*=.*$/$key = $value/g'"
  run sed -i "$regex" "$SYSCTL_CONF"
  if ! grep -Fq "$key" "$SYSCTL_CONF"; then
    LOGV "sysctl $key not found, appending to $SYSCTL_CONF"
    run echo "$key = $value" ">>" $SYSCTL_CONF
  fi
}

update_grub_default() {
  local key=$1
  shift
  local value=$*
  if grep -Eq '^GRUB_CMDLINE_LINUX.*'"$key" $GRUB_DEFAULT; then
    LOGV "Found boot parameter: $key"
    return 1
  else
    LOGV "Adding boot parameter: $key"
    local regex="'s/GRUB_CMDLINE_LINUX=\"[^\"]*/& '$key'/'"
    run sed -i "$regex" $GRUB_DEFAULT
  fi
}

update_grub_config() {
  LOGV "Updating grub config"
  run grub2-mkconfig -o $GRUB_FILE
}

update_limits() {
  local item=$1
  local value=$2
  LOGV "Updating limits item=$item, value=$value"
  local line="\*    -    $item    $value"
  local regex="'/^\s*\*.+'$item'.*$/d'"
  run sed -Ei "$regex" $LIMITS_CONF
  run echo "$line" ">>" $LIMITS_CONF
}

test_reboot() {
  [[ -n "$need_reboot" ]] && return
}

show_usage() {
  cat <<EOF
  Usage:
    Verify tuning steps: $(basename "$0") [options] --dryrun
    Apply tunings: $(basename "$0") [options]

  Options:
    --hpcprofile       Install and apply google-hpc-compute tuned profile
                       Also applies: --tcpmem, --limits
    --hpcthroughput    Install and apply google-hpc-compute-throughput profile
                       Also applies: --tcpmem, --limits
    --tcpmem           Increase memory for TCP
    --limits           Change the system ulimits
    --nosmt            Disable simultaneous multi threading
    --nofirewalld      Disable firewalld
    --noselinux        Disable SE Linux (reboot required)
    --nomitigation     Disable CPU vulnerabilities mitigations (reboot required)
    --reboot           Reboot system after tunings if required
    --dryrun           Do not execute commands
    --verbose          Print verbose messages
    --help             Show help message
EOF
}

get_phy_cpus() {
  # get physical core count
  nr_cpus=$(lscpu -p | grep -v '^#' | sort -t, -k 2,4 -u | wc -l)
  LOGV "Found $nr_cpus physical cores"
}

# Update GRUB_FILE for UEFI systems (require check_root)
get_grub_cfg() {
  local grubconf

  # verify if boot in UEFI mode
  if [[ -d /sys/firmware/efi ]]; then
    LOGV "System booted in UEFI mode"
    grubconf=$(readlink -e /etc/grub2-efi.cfg)
  else
    LOGV "System booted in BIOS mode"
    grubconf=$(readlink -e /etc/grub2.cfg)
  fi

  if [[ ! -z "$grubconf" ]]; then
    LOGV "Location of grub.cfg: $grubconf"
    GRUB_FILE=$grubconf
  fi
}

tune_tcpmem() {
  if [[ ${ACTIVE_PROFILE} == ${HPC_PROFILE} ]]; then
    LOG "Skip tcpmem tuning: applied in ${HPC_PROFILE} tuned profile"
  else
    LOG "Updating sysctl: TCP memory"
    update_sysctl net.ipv4.tcp_rmem 4096 87380 16777216
    update_sysctl net.ipv4.tcp_wmem 4096 16384 16777216
    sysctl -p
  fi
}

tune_limits() {
  if [[ -d "$(dirname "${LIMITSD_CONF}")" ]]; then
    LOG "Installing 98-google-hpc-image.conf"
    run cp ${VMROOT}/${LIMITSD_CONF} ${LIMITSD_CONF}
    # limits.d changes require rebooting
    need_reboot=1
  else
    # If limits.d is not supported
    LOG "Applying limits.conf"
    update_limits nproc unlimited
    update_limits memlock unlimited
    update_limits stack unlimited
    update_limits nofile 1048576
    update_limits cpu unlimited
    update_limits rtprio unlimited
  fi
  run ulimit -a
}

disable_ht_online() {
  if [[ -f /sys/devices/system/cpu/cpu0/topology/thread_siblings_list ]]; then
    for vcpu in $(cat /sys/devices/system/cpu/cpu*/topology/thread_siblings_list | awk -F '[^0-9]' '{ print $2 }'| uniq); do
      echo 0 > /sys/devices/system/cpu/cpu${vcpu}/online
    done
  fi
}

tune_ht() {
  LOG "Disabling hyperthreading"
  local grub_updated=0
  if [[ "$new_elkernel" -eq 1 ]]; then
    update_grub_default nosmt && grub_updated=1
  else
    update_grub_default nosmt && grub_updated=1
    update_grub_default nr_cpus="$nr_cpus" && grub_updated=1
  fi
  if [[ "$grub_updated" -eq 1 ]]; then
    update_grub_config
  fi
  # Hot-unplug HT CPU thread siblings
  disable_ht_online
}

tune_selinux() {
  LOG "Disabling SELinux"
  run sed -i 's/^SELINUX=.*$/SELINUX=disabled/g' $SELINUX_CONFIG
  need_reboot=1
}

tune_firewall() {
  LOG "Disabling firewall"
  run "systemctl stop firewalld > /dev/null"
  run "systemctl disable firewalld > /dev/null"
  run "systemctl mask --now firewalld > /dev/null"
}

tune_mitigations() {
  LOG "Disabling CPU mitigations"
  local grub_updated=0
  if [[ "$new_elkernel" -eq 1 ]]; then
    update_grub_default mitigations=off && grub_updated=1
  else
    update_grub_default spectre_v2=off
    update_grub_default nopti
    update_grub_default spec_store_bypass_disable=off
    grub_updated=1
  fi
  if [[ "$grub_updated" -eq 1 ]]; then
    update_grub_config
    need_reboot=1
  fi
}

tune_hpcprofile() {
  LOG "Installing ${HPC_PROFILE} profile"
  run mkdir -p "$(dirname "${HPC_PROFILE_PATH}")"
  run cp ${VMROOT}/${HPC_PROFILE_PATH} ${HPC_PROFILE_PATH}
  run tuned-adm profile ${HPC_PROFILE}
  get_active_profile
  need_reboot=1
}

# main routine
while [[ "$1" =~ "--" ]]; do
  if [[ "$1" = "--verbose" ]]; then
    verbose=true
    shift
    continue
  elif [[ "$1" = "--help" ]] || [[ "$1" = "-h" ]]; then
    show_usage
    exit 0
  elif [[ "$1" = "--tcpmem" ]]; then
    task_tcpmem=1
    shift
    continue
  elif [[ "$1" = "--limits" ]]; then
    task_limits=1
    shift
    continue
  elif [[ "$1" = "--nosmt" ]]; then
    task_ht=1
    shift
    continue
  elif [[ "$1" = "--nofirewalld" ]]; then
    task_firewall=1
    shift
    continue
  elif [[ "$1" = "--noselinux" ]]; then
    task_selinux=1
    shift
    continue
  elif [[ "$1" = "--nomitigation" ]]; then
    task_mitigations=1
    shift
    continue
  elif [[ "$1" = "--hpcprofile" ]]; then
    HPC_PROFILE="google-hpc-compute"
    HPC_PROFILE_PATH="/usr/lib/tuned/google-hpc-compute/tuned.conf"
    task_hpcprofile=1
    shift
    continue
  elif [[ "$1" = "--hpcthroughput" ]]; then
    HPC_PROFILE="google-hpc-compute-throughput"
    HPC_PROFILE_PATH="/usr/lib/tuned/google-hpc-compute-throughput/tuned.conf"
    task_hpcprofile=1
    shift
    continue
  elif [[ "$1" = "--reboot" ]]; then
    task_reboot=1
    shift
    continue
  elif [[ "$1" = "--dryrun" ]]; then
    dryrun=1
    shift
    continue
  else
    LOG "Unrecognized option $1"
    show_usage
    exit 0
  fi
done
LOG "checking something: Godzilla"
# common
check_task
# common
check_bin
# common functionality, modify access
check_vmroot
# functionality changes to check_os_from list
check_rocky
# functionality changes to check_el based on OS - May be combined as single check with previous function
check_new_elkernel
# common
get_active_profile
# common
get_phy_cpus
# common
check_root
# ! not sure if common or separate !
get_grub_cfg

# all the following will functions:
# common functionality, access would be separated.
[[ "$task_all" = 1 || "$task_hpcprofile" = 1 ]] && tune_hpcprofile
[[ "$task_all" = 1 || "$task_tcpmem" = 1 ]] && tune_tcpmem
[[ "$task_all" = 1 || "$task_limits" = 1 ]] && tune_limits
[[ "$task_all" = 1 || "$task_ht" = 1 ]] && tune_ht
[[ "$task_all" = 1 || "$task_selinux" = 1 ]] && tune_selinux
[[ "$task_all" = 1 || "$task_firewall" = 1 ]] && tune_firewall
[[ "$task_all" = 1 || "$task_mitigations" = 1 ]] && tune_mitigations
# common functionality, access would be separated.
# Can have common file cleanup implementation with an external call for os-based cleanup as well.
cleanup
