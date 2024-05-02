#!/usr/bin/env bash
# Make backup my system with restic to Backblaze B2.
# This script is typically run by: /etc/systemd/system/restic-backup.{service,timer}

# Exit on failure, pipe failure
set -e -o pipefail

# Clean up lock if we are killed.
# If killed by systemd, like $(systemctl stop restic), then it kills the whole cgroup and all it's subprocesses.
# However if we kill this script ourselves, we need this trap that kills all subprocesses manually.
exit_hook() {
  echo "In exit_hook(), being killed" >&2
  jobs -p | xargs kill
  restic unlock
}
trap exit_hook INT TERM

# Set run flag
BACKUP_TAG=manual
while getopts "c*" opt; do
  case "$opt" in
  c) # Flag used in cron.d to set tag
    BACKUP_TAG=cron.d
    ;;
  *) # Invalid flag
    echo "Invalid flag."
    ;;
  esac
done

# How many backups to keep.
RETENTION_DAYS=7
RETENTION_WEEKS=8
RETENTION_MONTHS=1
RETENTION_YEARS=1

# What to backup, and what to not
BACKUP_PATHS=
for dir in /srv/rhdwp/www/*; do
  BACKUP_PATHS+="$dir "
done

# Backup mount dirs in /mnt
if [ -d "/mnt" ]; then
    # Loop through each directory in /mnt
    for dir in /mnt/*/; do
        # Check if the path is a directory
        if [ -d "$dir" ]; then
            # Append the directory path to BACKUP_PATHS variable
            BACKUP_PATHS+="$dir"
        fi
    done
fi

BACKUP_EXCLUDES="--exclude-file /etc/restic/backup_exclude"
for dir in /home/*; do
  if [ -f "$dir/.backup_exclude" ]; then
    BACKUP_EXCLUDES+=" --exclude-file $dir/.backup_exclude"
  fi
done

# Set all environment variables like
# B2_ACCOUNT_ID, B2_ACCOUNT_KEY, RESTIC_REPOSITORY etc.
# shellcheck disable=SC1091
# shellcheck source=/etc/restic/b2_env.sh
source /etc/restic/b2_env.sh

# How many network connections to set up to B2. Default is 5.
B2_CONNECTIONS=50

# NOTE start all commands in background and wait for them to finish.
# Reason: bash ignores any signals while child process is executing and thus my trap exit hook is not triggered.
# However if put in subprocesses, wait(1) waits until the process finishes OR signal is received.
# Reference: https://unix.stackexchange.com/questions/146756/forward-sigterm-to-child-in-bash

# Remove locks from other stale processes to keep the automated backup running.
restic unlock &
wait $!

# Do the backup!
# See restic-backup(1) or http://restic.readthedocs.io/en/latest/040_backup.html
# --one-file-system makes sure we only backup exactly those mounted file systems specified in $BACKUP_PATHS, and thus not directories like /dev, /sys etc.
# --tag lets us reference these backups later when doing restic-forget.
# shellcheck disable=SC2086
restic backup \
  --one-file-system \
  --cache-dir /srv/rhdwp/.cache/restic \
  --tag $BACKUP_TAG \
  --option b2.connections=$B2_CONNECTIONS \
  $BACKUP_EXCLUDES \
  $BACKUP_PATHS &
wait $!

# Dereference and delete/prune old backups.
# See restic-forget(1) or http://restic.readthedocs.io/en/latest/060_forget.html
# --group-by only the tag and path, and not by hostname. This is because I create a B2 Bucket per host, and if this hostname accidentially change some time, there would now be multiple backup sets.
restic forget \
  --tag $BACKUP_TAG \
  --option b2.connections=$B2_CONNECTIONS \
  --prune \
  --group-by "paths,tags" \
  --keep-daily $RETENTION_DAYS \
  --keep-weekly $RETENTION_WEEKS \
  --keep-monthly $RETENTION_MONTHS \
  --keep-yearly $RETENTION_YEARS &
wait $!

# Check repository for errors.
# NOTE this takes much time (and data transfer from remote repo?), do this in a separate systemd.timer which is run less often.
#restic check &
#wait $!

echo "Backup & cleaning is done."
