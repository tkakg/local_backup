#!/bin/bash
set -euo pipefail

# =========================
# Config (CUSTOMIZED)
# =========================
HOST_IDENTIFIER="HOSTNAME"

# Backup destination (local)
BACKUP_BASE_DIR="/backup"
DIR_NAME="${HOST_IDENTIFIER}"
GEN=7

DATE_SUFFIX="$(date +%Y%m%d)"
BACKUP_DIR="${BACKUP_BASE_DIR}/${DIR_NAME}/${DATE_SUFFIX}"

# Disk check target: backup destination filesystem
CHECK_TARGET_DISK="${BACKUP_BASE_DIR}"
ERRONEOUS_DISK_USAGE_IN_PERCENTAGE=99

# Temporary work directory
TEMP_DIR="/tmp"
WORK_DIR="${TEMP_DIR}/${DATE_SUFFIX}"

# SNS
SNS_PROFILE="server-sns"
SNS_TOPIC_ARN='arn:aws:sns:ap-northeast-1:xxxxx'  # manual publish succeeded one
AWSCLI_CMD="/usr/local/bin/aws"

# Optional: disk-full specific message
SNS_MSG_SUBJECT="${HOST_IDENTIFIER} DiskSpaceUsage FULL from local-backup"
SNS_MSG_BODY="[ ${HOST_IDENTIFIER} ] backup failed because ${CHECK_TARGET_DISK} partition is full"

# MySQL
DBUSER="DBUSER_NAME"
DBPASS="DBPASSWORD"
DBHOST="127.0.0.1"

# =========================
# State
# =========================
FAILED_STEP="(unknown)"
SNS_ALREADY_SENT=0

# =========================
# Helpers
# =========================
log() {
  echo "[$(date '+%Y/%m/%d %H:%M:%S')] $*"
}

sns_publish() {
  local subject="$1"
  local message="$2"

  if [ -x "${AWSCLI_CMD}" ]; then
    "${AWSCLI_CMD}" sns --profile "${SNS_PROFILE}" publish \
      --topic-arn "${SNS_TOPIC_ARN}" \
      --subject "${subject}" \
      --message "${message}" || true
  else
    log "WARN: aws cli not found at ${AWSCLI_CMD}, skip SNS"
  fi
}

# EXIT trap: notify on both success and failure (final result)
on_exit() {
  local rc=$?

  # avoid double notify (e.g., disk-full already notified)
  if [ "${SNS_ALREADY_SENT}" -eq 1 ]; then
    exit "${rc}"
  fi

  if [ "${rc}" -eq 0 ]; then
    sns_publish \
      "${HOST_IDENTIFIER} local-backup OK" \
      "[${HOST_IDENTIFIER}] local backup OK
date: ${DATE_SUFFIX}
backup_dir: ${BACKUP_DIR}"
    exit 0
  fi

  sns_publish \
    "${HOST_IDENTIFIER} local-backup FAILED" \
    "[${HOST_IDENTIFIER}] local backup FAILED
date: ${DATE_SUFFIX}
exit_code: ${rc}
last_step: ${FAILED_STEP}
backup_dir: ${BACKUP_DIR}
work_dir: ${WORK_DIR}"

  exit "${rc}"
}

trap 'on_exit' EXIT

# =========================
# Functions
# =========================
prepare_dirs() {
  FAILED_STEP="prepare_dirs"
  mkdir -p "${WORK_DIR}"
  ( cd "${TEMP_DIR}" && [ -d "${DATE_SUFFIX}" ] && chmod o-rwx "${DATE_SUFFIX}" ) || true

  mkdir -p "${BACKUP_BASE_DIR}/${DIR_NAME}"
  chmod o-rwx "${BACKUP_BASE_DIR}/${DIR_NAME}" || true
}

validateDiskCapacity() {
  FAILED_STEP="validateDiskCapacity"
  local usage
  usage="$(df -P "${CHECK_TARGET_DISK}" | tail -n1 | awk '{print $5}' | sed 's/%//')"

  if ! [[ "${usage}" =~ ^[0-9]+$ ]]; then
    log "backup failure: failed to parse disk usage"
    exit 1
  fi

  if [ "${usage}" -ge "${ERRONEOUS_DISK_USAGE_IN_PERCENTAGE}" ]; then
    # Send disk-full notification immediately (optional), and mark as already sent
    SNS_ALREADY_SENT=1
    sns_publish "${SNS_MSG_SUBJECT}" "${SNS_MSG_BODY}"

    log "backup failure: disk full (${usage}%)"
    exit 1
  fi
}

create_mysql_dumps() {
  FAILED_STEP="create_mysql_dumps"
  log "mysqldump start"

  local dblist
  dblist="$(mysql -u"${DBUSER}" -p"${DBPASS}" -h"${DBHOST}" -e 'show databases;' )"
  dblist="$(echo "${dblist}" | egrep -v "^(Database|information_schema|performance_schema|innodb|mysql|tmp|sys)$")"

  # JSON Column Check
  local json_count=0
  json_count="$(mysql -u"${DBUSER}" -p"${DBPASS}" -h"${DBHOST}" -BN -e \
    "SELECT COUNT(TABLE_CATALOG) FROM information_schema.COLUMNS WHERE DATA_TYPE = 'json' AND TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys');")"

  if [ "${json_count}" -ge 1 ]; then
    log "json column found !! please customize this script."
    exit 1
  fi

  IFS=$'\n'
  for db in ${dblist}; do
    local myisam_count=0
    myisam_count="$(mysql -u"${DBUSER}" -p"${DBPASS}" -h"${DBHOST}" -BN -e \
      "SELECT COUNT(TABLE_NAME) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '${db}' AND ENGINE = 'MyISAM' ;")"

    if [ "${myisam_count}" -ge 1 ]; then
      log "DB: ${db} has MyISAM tables."
      ionice -c 2 nice -n 19 mysqldump -u"${DBUSER}" -p"${DBPASS}" -h"${DBHOST}" \
        --lock-all-tables --default-character-set=binary --add-drop-database --no-data --databases "${db}" \
        > "${WORK_DIR}/mysql_${db}_schema.dump"
      ionice -c 2 nice -n 19 mysqldump -u"${DBUSER}" -p"${DBPASS}" -h"${DBHOST}" \
        --lock-all-tables --default-character-set=binary "${db}" \
        > "${WORK_DIR}/mysql_${db}.dump"
    else
      log "DB: ${db} has no MyISAM table."
      ionice -c 2 nice -n 19 mysqldump -u"${DBUSER}" -p"${DBPASS}" -h"${DBHOST}" \
        --single-transaction --default-character-set=binary --add-drop-database --no-data --databases "${db}" \
        > "${WORK_DIR}/mysql_${db}_schema.dump"
      ionice -c 2 nice -n 19 mysqldump -u"${DBUSER}" -p"${DBPASS}" -h"${DBHOST}" \
        --single-transaction --default-character-set=binary "${db}" \
        > "${WORK_DIR}/mysql_${db}.dump"
    fi
  done
  unset IFS

  log "mysqldump end"
}

create_archives() {
  FAILED_STEP="create_archives"
  log "essential file archive start"

  if [ -d /root/scripts ]; then
    ( cd /root && ionice -c 2 nice -n 19 tar -zcf "${WORK_DIR}/root_scripts.tgz" scripts )
  fi

  ( cd / && ionice -c 2 nice -n 19 tar -zcf "${WORK_DIR}/etc.tgz" etc )

  if [ -d /var/spool/cron ]; then
    ( cd /var/spool && ionice -c 2 nice -n 19 tar -zcf "${WORK_DIR}/crontab.tgz" cron )
  fi

  log "essential file archive end"

  log "web data archive start"
  if [ -d /var/www ]; then
    ( cd /var && ionice -c 2 nice -n 19 tar -zcf "${WORK_DIR}/www.tgz" www )
  fi
  log "web data archive end"
}

finalize_backup() {
  FAILED_STEP="finalize_backup"
  mkdir -p "${BACKUP_DIR}"
  chmod o-rwx "${BACKUP_DIR}" || true

  shopt -s nullglob
  mv "${WORK_DIR}/"* "${BACKUP_DIR}/"
  shopt -u nullglob
}

cleanup_workdir() {
  FAILED_STEP="cleanup_workdir"
  rm -rf "${WORK_DIR}"
}

delete_old_generations() {
  FAILED_STEP="delete_old_generations"
  local base="${BACKUP_BASE_DIR}/${DIR_NAME}"

  local old
  old="$(ls -1 "${base}" 2>/dev/null | egrep '^[0-9]{8}$' | sort -r | tail -n +$((GEN+1)) || true)"
  if [ -n "${old}" ]; then
    while read -r d; do
      [ -n "${d}" ] || continue
      rm -rf "${base}/${d}"
      log "deleted old backup: ${base}/${d}"
    done <<< "${old}"
  fi
}

# =========================
# Main
# =========================
log "local backup start"

prepare_dirs
validateDiskCapacity
create_mysql_dumps
create_archives
validateDiskCapacity
finalize_backup
cleanup_workdir
delete_old_generations

log "local backup success"
exit 0

