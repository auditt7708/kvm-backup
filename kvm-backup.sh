#!/bin/bash
#set -eu
#
# Perform efficient live disk backups using "active blockcommit".
# ShellCheck'ed by Tomas Nevar (tomas@lisenet.com).
# Tested on CentOS 7.
#
######################################################
#
# Script requires an updated QEMU package from CentOS Virt repository.
#
#  [virt-kvm-common]
#  name=CentOS-$releasever - Virt kvm-common
#  baseurl=http://mirror.centos.org/centos/7/virt/x86_64/kvm-common/
#  enabled=1
#  gpgcheck=0
#
#  sudo yum clean all && yum repolist
#  sudo yum update qemu-kvm-ev qemu-img-ev
#
######################################################
#
# For more info on live snapshots, see here:
# https://wiki.libvirt.org/page/Live-disk-backup-with-active-blockcommit
#
# VERSION: 1.0
#
######################################################

# Who to email in case of a problem
MAIL_TO="root@localhost";

# Define the script name, this is used with systemd-cat to
# identify this script in the journald output
SCRIPT_NAME="kvm-backup-script";
TMP_FILE_DOMAINS="/tmp/${SCRIPT_NAME}.domains.txt";
TMP_FILE_DOMAIN_DETAILS="/tmp/${SCRIPT_NAME}.details.txt";
MAIL_FROM="${SCRIPT_NAME}@${HOSTNAME}";

# The path to create date-stamped backup folders
IMAGES_PATH="/mnt/storage/libvirt";
BACKUP_PATH="/mnt/storage/backups";

##
## Sanity tests
##

if ! [ -d "${IMAGES_PATH}" ];then
  echo "ERROR: directory ${IMAGES_PATH} does not exist.";
  exit 1;
fi

if ! [ -d "${BACKUP_PATH}" ];then
  mkdir -p "${BACKUP_PATH}";
fi

if ! type systemd-cat >/dev/null 2>&1; then
  echo "ERROR: systemd-cat is not installed.";
  exit 1;
elif ! type virsh >/dev/null 2>&1; then
  echo "ERROR: virsh is not installed.";
  exit 1;
else
  # List running domains and write to a temp file
  virsh list --state-running --name|sed '/^$/d' > "${TMP_FILE_DOMAINS}";
  echo "Deleting all previous date-stampted backup folders from:";
  echo "${BACKUP_PATH}/";
  rm -rvf "${BACKUP_PATH:-fallback}/*";
fi

# Calculate free and used disk space
FREE_DISK_SPACE="$(df -B M --output=avail ${BACKUP_PATH}|grep M|cut -d"M" -f1|sed 's/ //g')";
DISK_USED_BY_IMAGES="$(du -c -B M ${IMAGES_PATH}/*.qcow2|grep total|cut -d"M" -f1)";

if ! [ "${FREE_DISK_SPACE}" -gt "${DISK_USED_BY_IMAGES}" ]; then
  echo "ERROR: not enough free disk space available to create snapshots."
  echo "Not enough free disk space available to create snapshots" | mailx \
    -s "[KVM] Backup Errors Found" -r "${MAIL_FROM}" "${MAIL_TO}";
  exit 1;
else
  echo "******************************************";
  echo "Free disk space on ${BACKUP_PATH}: ${FREE_DISK_SPACE} MB";
  echo "Disk space required for snapshots: ${DISK_USED_BY_IMAGES} MB";
  echo "******************************************";
fi

if ! [ -e "${TMP_FILE_DOMAINS}" ] || ! [ -s "${TMP_FILE_DOMAINS}" ];then
  echo "No running KVM domains were found.";
  exit 0;
fi

##
## Snapshot routine
##

while IFS= read -r DOMAIN || [[ -n "${DOMAIN}" ]]; do

  echo "Starting backup for ${DOMAIN} on $(date +'%Y-%m-%d %H:%M:%S')" | systemd-cat -t "${SCRIPT_NAME}";
  virsh domblklist "${DOMAIN}" --details | grep disk | awk '{print $3":"$4}' > "${TMP_FILE_DOMAIN_DETAILS}";

  # Get the target disk
  TARGETS="$(cut -d":" -f1 ${TMP_FILE_DOMAIN_DETAILS})";
  echo "${DOMAIN} targets: ${TARGETS}";

  # Get the image file
  IMAGES="$(cut -d":" -f2 ${TMP_FILE_DOMAIN_DETAILS})";
  echo "${DOMAIN} images: ${IMAGES}";

  # Create the snapshot/disk specification
  DISKSPEC=""

  # Since we don't know how many disks a guest has,
  # we loop and append the string
  for TARGET in ${TARGETS}; do
    DISKSPEC="${DISKSPEC} --diskspec ${TARGET},snapshot=external";
  done

  echo "Attempting to create a snapshot for ${DOMAIN}";
  virsh snapshot-create-as --domain "${DOMAIN}" --name "kvm-backup-of-${DOMAIN}" --no-metadata --atomic --disk-only "${DISKSPEC}";

  if [ ${?} -ne 0 ]; then
    echo "ERROR: failed to create snapshot for ${DOMAIN}" | systemd-cat -t "${SCRIPT_NAME}";
    echo -e "ERROR: failed to create snapshot for ${DOMAIN}\n";
  else
    # Create a backup folder
    BACKUP_FOLDER="${BACKUP_PATH}/${DOMAIN}/$(date +%Y-%m-%d)";
    mkdir -pv "${BACKUP_FOLDER}";

    # Copy disk image
    echo "Copying disk image for ${DOMAIN}";
    for IMAGE in ${IMAGES}; do
      IMAGE_NAME="$(basename "${IMAGE}")";
      cp -vp --sparse=always "${IMAGE}" "${BACKUP_FOLDER}/${IMAGE_NAME}";
    done

    # Merge changes back
    echo "Perform active blockcommit by live merging contents of qcow2 overlay into base.";
    for TARGET in ${TARGETS}; do
      BACKUP_IMAGE=$(virsh domblklist "${DOMAIN}" --details | grep disk | grep "${TARGET}" | awk '{print $4}');
      echo "${DOMAIN} backup image: ${BACKUP_IMAGE}";

      virsh blockcommit "${DOMAIN}" "${TARGET}" --active --pivot;
      if [ ${?} -ne 0 ]; then
        echo "ERROR: could not merge changes for disk of ${TARGET} of ${DOMAIN}. VM may be in invalid state." | systemd-cat -t "${SCRIPT_NAME}";
        echo "ERROR: could not merge changes for disk of ${TARGET} of ${DOMAIN}. VM may be in invalid state.";
      else
        echo "The blockcommit operation has completed, the live QEMU was pivoted to the base image.";
        # Cleanup no longer required backup files
        echo "Removing left over backup for ${DOMAIN}";
        rm -vf "${BACKUP_IMAGE}";
        # Dump the configuration information.
        echo "Dumping configuration information for ${DOMAIN}";
        virsh dumpxml "${DOMAIN}" > "${BACKUP_FOLDER}/${DOMAIN}.xml";
        echo "Finished backup of ${DOMAIN} at $(date +'%d-%m-%Y %H:%M:%S')" | systemd-cat -t "${SCRIPT_NAME}";
        echo "Finished backup of ${DOMAIN} at $(date +'%d-%m-%Y %H:%M:%S')" | mailx -s "${SCRIPT_NAME}" -r "${MAIL_FROM}" "${MAIL_TO}";
        echo -e "All done for ${DOMAIN}\n";
      fi
    done
  fi
done < "${TMP_FILE_DOMAINS}";

rm -f "${TMP_FILE_DOMAINS}" "${TMP_FILE_DOMAIN_DETAILS}";

exit 0

