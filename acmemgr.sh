#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# ACMEMGR.SH : an ACME.SH manager using DNS-01 protocol
#
# acmemgr.sh - main program
#-------------------------------------------------------------------------------
#
# See README.md for documentation, versions and history
#
# Author(s)
#
# Stephane Riviere - stef[@|.]genesix.org for https://soweb.io SARL - FRANCE
# Léa Gris - lea(at)noiraude.net
#
# This program is licenced GPLv3 or greater.
#
#-------------------------------------------------------------------------------
#
# Variables names should be consistent and understandable
#
# ..._DIR  : contains ready to use directory path
# ..._ROOT : contains the base of a path to build
# ..._FILE : contains fully qualified file name (with path)
#
#-------------------------------------------------------------------------------

#-------------------------------------------------------------------------------
# Initialize
#-------------------------------------------------------------------------------

#MANAGER_DEBUG='false'
MANAGER_DEBUG='false'
MANAGER_VERSION='1.3'
MANAGER_NAME='acmemgr'
ACME_NAME='acme'
ACME_COMMAND="${ACME_NAME}.sh"

ETC_DIR="/etc/${ACME_NAME}"
DB_FILE="${ETC_DIR}/${MANAGER_NAME}.db"
LOG_ACME_ROOT="/var/log/${ACME_NAME}"
LOG_MANAGER_FILE="${LOG_ACME_ROOT}/${MANAGER_NAME}.log"

#-------------------------------------------------------------------------------
# Service functions
#-------------------------------------------------------------------------------

#-------------------------------------------------------------------------------
function pause()
#-------------------------------------------------------------------------------
# Description : Pause with message "Press a key to continue..."
# Arguments   :
# Return      :
#-------------------------------------------------------------------------------
{
  read -n1 -r -p 'Press a key to continue...' _
}

#-------------------------------------------------------------------------------
function log_msg()
#-------------------------------------------------------------------------------
# Description : Display and log message
# Arguments   : ${1} message
#               ${2} message class (default: MESSAGE)
# Return      :
#-------------------------------------------------------------------------------
{
  local LOG_MSG_STRING
  LOG_MSG_STRING="[$(date "${LOG_TIMESTAMP[@]}")] - ${TASK_NAME} - ${2:-MESSAGE} - ${1}"
  echo "${LOG_MSG_STRING}"
  echo "${LOG_MSG_STRING}" >>"${LOG_MANAGER_FILE}"
}

#-------------------------------------------------------------------------------
function log_dbg() {
  #-------------------------------------------------------------------------------
  # Description : Display and log debug message
  # Arguments   : ${1} message
  # Return      :
  #-------------------------------------------------------------------------------
  [[ ${MANAGER_DEBUG} == 'true' ]] && log_msg "${1}" 'DEBUG'
}

#-------------------------------------------------------------------------------
function log_err()
#-------------------------------------------------------------------------------
# Description : Display and log error message
# Arguments   : ${1} message
# Return      :
#-------------------------------------------------------------------------------
{
  log_msg "${1}" 'ERROR'
}

#-------------------------------------------------------------------------------
function mail_msg()
#-------------------------------------------------------------------------------
# Description : log & mail message
# Arguments   : ${1} : msg class, example: ${HOST_NAME}
#               ${2} : subject, example: "Certificate ${DOMAIN_NAME} has been created"
#               ${3} : body, example: "Expire :${CERT_EXPIRE}"
# Return      :
#-------------------------------------------------------------------------------
{
  log_msg "${1} - ${2//[[:space:]]/ } ${3//[[:space:]]/ }"

  echo -e "${3}\\n" \
    | mail \
      -a 'Content-Type: text/plain; charset=UTF-8' \
      -s "[${MANAGER_NAME}] ${1} - Message : ${2}" "${ACCOUNT_EMAIL}"
  log_msg "${LOCAL_HOST} - Wait 2 s for mail sorting in MUA."
  sleep 2
}

#-------------------------------------------------------------------------------
function mail_err()
#-------------------------------------------------------------------------------
# Description : log & mail error message
# Arguments   : ${1} : class, example: ${HOST_NAME}
#               ${2} : subject, example: "Certificate ${DOMAIN_NAME} has not been created"
#               ${3} : body, example: "Error code : ${ACME_RETURN_CODE}."
# Return      :
#-------------------------------------------------------------------------------
{
  log_err "${1} - ${2//[[:space:]]/ } ${3//[[:space:]]/ }"

  echo -e "${3}\\n" \
    | mail \
      -a 'Content-Type: text/plain; charset=UTF-8' \
      -s "[${MANAGER_NAME}] ${1} - Error : ${2}" \
      "${ACCOUNT_EMAIL}"
  log_msg "${LOCAL_HOST} - Wait 2 s for mail sorting in MUA."
  sleep 2
}

#-------------------------------------------------------------------------------
function pad_string()
#-------------------------------------------------------------------------------
# Description : Display status
# Arguments   : ${1] : String to pad
#               ${2] : Pad width
# Return      : Padded string
#-------------------------------------------------------------------------------
{
  printf "%${2}s%s" ' ' "${1}"
}

#-------------------------------------------------------------------------------
function remove_local_cert()
#-------------------------------------------------------------------------------
# Description : Remove a certificates in local repository
# Arguments   :
# Return      :
#-------------------------------------------------------------------------------
{
  if  find "${CERT_DIR}" \
    -type f \
    \( \
      -regextype posix-extended \
      -regex "${CERT_DIR}/${DOMAIN_NAME}.(cer|conf|csr|csr.conf|key)" \
      -or -name "${CERT_CA}" \
      -or -name "${CERT_FULLCHAIN}" \
    \) \
    -delete  \
    && rmdir -- "${CERT_DIR}"; then
    mail_msg \
      "${LOCAL_HOST}" \
      "Certificate ${DOMAIN_NAME} has been locally deleted." \
      "Success"
  else
    mail_err \
      "${LOCAL_HOST}" \
      "Certificate ${DOMAIN_NAME} has not been locally deleted." \
      "Error code : ${?}."
  fi
}

#-------------------------------------------------------------------------------
function certops_exec()
#-------------------------------------------------------------------------------
# Description : Exec certops (Certificate files operations)
# Arguments   :
# Return      : Error code (0=success)
#-------------------------------------------------------------------------------
{
  IFS="§" # Set internal shell variable $IFS (Internal Field Separator) to avoid space trimming
  # shellcheck source=/dev/null
  source "${CERTOPS_FILE}"
  echo "${?}"
  unset IFS # Restore IFS to default space, tab & newline
}

#-------------------------------------------------------------------------------
function create_process()
#-------------------------------------------------------------------------------
# Description : Issue a certificate
# Arguments   :
# Return      :
#-------------------------------------------------------------------------------
{
  local DOMAIN_CERT_EXPIRE=''
  local -a ACME_PARAMS=()
  local -i ACME_RETURN_CODE=''
  local -i CERTOPS_RETURN_CODE=''
  local DB_UPDATE_DATE=''
  local DB_UPDATE_COMMAND=''
  local DB_UPDATE_RETURN_CODE=''

  # Test if DOMAIN_STATUS is not RENEWED, DELETING or DELETED
  if [[ ${DOMAIN_STATUS} == "${NULL_VALUE}" ]]; then

    # Test if "/etc/acme/certs/DOMAIN_NAME/DOMAIN_NAME.cer" file does not exist (consistency check - if script was interrupted, the directory could exist with some others files)
    if [[ ! -f "${CERT_DIR}/${DOMAIN_NAME}.cer" ]]; then

      # Test if "/etc/acme/certs/DOMAIN_NAME" directory exist (consistency check - if script was interrupted, the directory must be deleted for resync)
      if [[ -d ${CERT_DIR} ]]; then
        remove_local_cert
      fi

      # /usr/local/bin/acme.sh --server letsencrypt --home /etc/acme/<account_name> --config-home /etc/acme/<account_name> --cert-home <cert_home> --dns <account_dns01> --issue --domain <domain_name>
      ACME_PARAMS=(
        --server letsencrypt
        --home "${HOME_DIR}"
        --config-home "${HOME_DIR}"
        --cert-home "${CERT_HOME}"
        --log "${LOG_ACME_ROOT}/${ACCOUNT_NAME}.log"
        --dns "${ACCOUNT_DNS01}"
        --issue
        --domain "${DOMAIN_NAME}"
      )

      # A domain name beginning by "[www.]domain.tld" gets an extra "domain.tld" in certificate.
      if [[ ${DOMAIN_NAME:0:4} == 'www.' ]]; then
        ACME_PARAMS+=(--domain "${DOMAIN_NAME:4}")
      fi

      #--------------------------:
      log_dbg "ACME_COMMAND      : ${ACME_COMMAND} $(
        for param in "${ACME_PARAMS[@]}"; do
          printf ' %q' "${param}"
        done
      )"

      "${ACME_COMMAND}" "${ACME_PARAMS[@]}"
      ACME_RETURN_CODE="${?}"

      if [[ ${ACME_RETURN_CODE} -eq 0 ]]; then

        DOMAIN_CERT_EXPIRE="$(
          openssl \
            x509 \
            -dates \
            -noout \
            -in "${DOMAIN_CERT}"
        )"
        mail_msg \
          "${HOST_NAME}" \
          "Certificate ${DOMAIN_NAME} has been created." \
          "\\nValidity period:\\n${DOMAIN_CERT_EXPIRE}"

        # Copy certificates - Execution of /etc/acme/<host>.certops content

        CERTOPS_RETURN_CODE="$(certops_exec)"

        if [[ ${CERTOPS_RETURN_CODE} -eq 0 ]]; then
          mail_msg \
            "${HOST_NAME}" \
            "Certificate ${DOMAIN_NAME} has been successfuly copied." \
            "Host is now tagged to service reload."

          # Reload the server configuration
          SERVICE_RESTART='true'

          IFS="§" # Set internal shell variable $IFS (Internal Field Separator) to avoid space trimming

          DB_UPDATE_DATE="$(date "${LOG_TIMESTAMP[@]}")"

          # Before : "DOM_UNAME;HOST_LOGIN;HOST_FQDN,HOST_PORT;ACCOUNT_NAME;SERVICE_NAME;DOMAIN_NAME"
          # After  : "DOM_UNAME;HOST_LOGIN;HOST_FQDN,HOST_PORT;ACCOUNT_NAME;SERVICE_NAME;DOMAIN_NAME;CREATED - lundi 12 février 2018, 11:47:46 (UTC+0100)"
          DB_UPDATE_COMMAND="s/${DOMAIN_NAME}/${DOMAIN_NAME};${DOMAIN_STATUS_CREATED} - ${DB_UPDATE_DATE}/"

          #--------------------------:
          log_dbg "DB_FILE_REP._CMD. : ${DB_UPDATE_COMMAND}"

          # When sed launched in bash, must use double quote instead of single quote
          sed \
            -i.bak \
            "${DB_UPDATE_COMMAND}" \
            "${DB_FILE}"
          DB_UPDATE_RETURN_CODE="${?}"

          unset IFS # Restore IFS to default space, tab & newline

          if [[ ${DB_UPDATE_RETURN_CODE} -eq 0 ]]; then
            mail_msg \
              "${HOST_NAME}" \
              "Domain ${DOMAIN_NAME} has been tagged CREATED." \
              "Success"
          else
            mail_err \
              "${HOST_NAME}" \
              "Domain ${DOMAIN_NAME} has not been tagged CREATED." \
              "Error code : ${DB_UPDATE_RETURN_CODE}."
          fi

        else
          mail_err \
            "${HOST_NAME}" \
            "Certificate ${DOMAIN_NAME} has not been copyied." \
            "Error code : ${CERTOPS_RETURN_CODE}."
        fi

      else
        mail_err \
          "${HOST_NAME}" \
          "Certificate ${DOMAIN_NAME} has not been created." \
          "Error code : ${ACME_RETURN_CODE}."
      fi
    else
      log_dbg "Certificate ${DOMAIN_NAME} already exists"
    fi
  fi
}

#-------------------------------------------------------------------------------
function renew_process()
#-------------------------------------------------------------------------------
# Description : Renew a certificate
# Arguments   :
# Return      :
#-------------------------------------------------------------------------------
{
  local DOMAIN_CHECK_4M=''
  local DOMAIN_CHECK_1M=''
  local -a DOMAIN_CHECK_PARAMS=()
  local DOMAIN_CHECK_RETURN_CODE=''
  local DOMAIN_CERT_EXPIRE=''
  local CERTOPS_RETURN_CODE=''
  local DB_UPDATE_DATE=''
  local DB_UPDATE_COMMAND=''
  local DB_UPDATE_RETURN_CODE=''
  local -a ACME_PARAMS=()
  local ACME_RETURN_CODE=''

  # Test if DOMAIN_STATUS is CREATED or RENEWED
  if [[ ${DOMAIN_STATUS:0:7} == "${DOMAIN_STATUS_CREATED:0:7}" || ${DOMAIN_STATUS:0:7} == "${DOMAIN_STATUS_RENEWED:0:7}" ]]; then

    # Test if certificate directory exist
    if [[ -d ${CERT_DIR} ]]; then

      # Force renew for tests purposes > Invert commented lines :
      # - DOMAIN_CHECK_COMMAND
      # - ACME_COMMAND
      # shellcheck disable=SC2034
      local -ri DOMAIN_CHECK_4M=10368000 # Four monthes test (for else debugging)
      local -ri DOMAIN_CHECK_1M=2592000  # One month test

      # NORMAL OPERATION
      DOMAIN_CHECK_PARAMS=(
        x509
        -checkend "${DOMAIN_CHECK_1M}"
        -noout
        -in "${DOMAIN_CERT}"
      )

      # FORCE RENEW FOR TESTS PURPOSES
      #DOMAIN_CHECK_COMMAND="openssl x509 -checkend ${DOMAIN_CHECK_4M} -noout -in ${DOMAIN_CERT}"

      #--------------------------:
      log_dbg "DOMAIN_CHECK_CMD. : openssl $(
        for param in "${DOMAIN_CHECK_PARAMS[@]}"; do
          printf ' %q' "${param}"
        done
      )"

      openssl "${DOMAIN_CHECK_PARAMS[@]}"
      DOMAIN_CHECK_RETURN_CODE="${?}"

      if [[ ${DOMAIN_CHECK_RETURN_CODE} -eq 0 ]]; then

        DOMAIN_CERT_EXPIRE="$(
          openssl \
            x509 \
            -dates \
            -noout \
            -in "${DOMAIN_CERT}"
        )"

        if [[ ${EMAIL_EVEN_NOT_RENEWED} -eq '1' ]]; then

          mail_msg \
            "${HOST_NAME}" \
            "Certificate ${DOMAIN_NAME} is not to be renewed." \
            "\\nValidity period:\\n${DOMAIN_CERT_EXPIRE}"
        fi

      else

        DOMAIN_CERT_EXPIRE="$(
          openssl \
            x509 \
            -dates \
            -noout \
            -in "${DOMAIN_CERT}"
        )"
        mail_msg \
          "${HOST_NAME}" \
          "Certificate ${DOMAIN_NAME} has to be renewed." \
          "\\nValidity period:\\n${DOMAIN_CERT_EXPIRE}"

        # /usr/local/bin/acme.sh --server letsencrypt --home /etc/acme/<account_name> --config-home /etc/acme/<account_name> --cert-home <cert_home> --dns <account_dns01> --renew --domain <domain_name>

        # NORMAL OPERATION
        ACME_PARAMS=(--server letsencrypt --home "${HOME_DIR}" --config-home "${HOME_DIR}" --cert-home "${CERT_HOME}" --log "${LOG_ACME_ROOT}/${ACCOUNT_NAME}.log" --dns "${ACCOUNT_DNS01}" --renew --domain "${DOMAIN_NAME}")

        # FORCE RENEW FOR TESTS PURPOSES
        # ACME_PARAMS=(--server letsencrypt --home "${HOME_DIR}" --config-home "${HOME_DIR}" --cert-home "${CERT_HOME}" --log "${LOG_ACME_ROOT}/${ACCOUNT_NAME}.log" --dns "${ACCOUNT_DNS01}" --force --renew --domain "${DOMAIN_NAME}")

        #--------------------------:
        log_dbg "ACME_COMMAND      : ${ACME_COMMAND} $(
          for param in "${ACME_PARAMS[@]}"; do
            printf ' %q' "${param}"
          done
        )"

        "${ACME_COMMAND}" "${ACME_PARAMS[@]}"
        ACME_RETURN_CODE="${?}"

        if [[ ${ACME_RETURN_CODE} -eq 0 ]]; then

          DOMAIN_CERT_EXPIRE="$(
                  openssl \
                  x509 \
                  -dates \
                  -noout \
                  -in "${DOMAIN_CERT}"
          )"
          mail_msg \
            "${HOST_NAME}" \
            "Certificate ${DOMAIN_NAME} has been renewed." \
            "\\nValidity period:\\n${DOMAIN_CERT_EXPIRE}"

          # Copy certificates - Execution of /etc/acme/<host>.certops content

          CERTOPS_RETURN_CODE="$(certops_exec)"

          if [[ ${CERTOPS_RETURN_CODE} -eq 0 ]]; then
            mail_msg \
              "${HOST_NAME}" \
              "Certificate ${DOMAIN_NAME} has been successfuly copied." \
              "Host is now tagged to service reload."

            # Reload the server configuration
            SERVICE_RESTART='true'

            IFS="§" # Set internal shell variable $IFS (Internal Field Separator) to avoid space trimming

            DB_UPDATE_DATE="$(date "${LOG_TIMESTAMP[@]}")"

            # Before : "DOM_UNAME;HOST_LOGIN;HOST_FQDN,HOST_PORT;ACCOUNT_NAME;SERVICE_NAME;DOMAIN_NAME;CREATED || RENEWED"
            # After  : "DOM_UNAME;HOST_LOGIN;HOST_FQDN,HOST_PORT;ACCOUNT_NAME;SERVICE_NAME;DOMAIN_NAME;RENEWED - lundi 12 février 2018, 11:47:46 (UTC+0100)"
            DB_UPDATE_COMMAND="s/${DOMAIN_NAME};${DOMAIN_STATUS}/${DOMAIN_NAME};${DOMAIN_STATUS_RENEWED} - ${DB_UPDATE_DATE}/"

            #--------------------------:
            log_dbg "DB_FILE_REP._CMD. : ${DB_UPDATE_COMMAND}"

            # When sed launched in bash, must use double quote instead of single quote
            sed \
              -i.bak \
              "${DB_UPDATE_COMMAND}" \
              "${DB_FILE}"
            DB_UPDATE_RETURN_CODE="${?}"

            unset IFS # Restore IFS to default space, tab & newline

            if [[ ${DB_UPDATE_RETURN_CODE} -eq 0 ]]; then
              mail_msg \
                "${HOST_NAME}" \
                "Domain ${DOMAIN_NAME} has been tagged RENEWED." \
                "Success"
            else
              mail_err \
                "${HOST_NAME}" \
                "Domain ${DOMAIN_NAME} has not been tagged RENEWED." \
                "Error code : ${DB_UPDATE_RETURN_CODE}."
            fi

          else
            mail_err \
              "${HOST_NAME}" \
              "Certificate ${DOMAIN_NAME} has not been copyied." \
              "Error code : ${CERTOPS_RETURN_CODE}."
          fi

        else
          mail_err \
            "${HOST_NAME}" \
            "Certificate ${DOMAIN_NAME} has not been renewed." \
            "Error code : ${ACME_RETURN_CODE}."
        fi

      fi

    else
      log_dbg "Certificate ${DOMAIN_NAME} do not exists"
    fi

  fi
}

#-------------------------------------------------------------------------------
function delete_process()
#-------------------------------------------------------------------------------
# Description : Delete a certificate and revoke it
# Arguments   :
# Return      :
#-------------------------------------------------------------------------------
{
  local CERTOPS_RETURN_CODE=''
  local DB_UPDATE_DATE=''
  local DB_UPDATE_COMMAND=''
  local DB_UPDATE_RETURN_CODE=''
  local -a ACME_PARAMS=()
  local ACME_RETURN_CODE=''

  if [[ ${DOMAIN_STATUS:0:7} == "${DOMAIN_STATUS_DELETING:0:7}" ]]; then

    # Check if certificate directory exist
    if [[ -d ${CERT_DIR} ]]; then

      # We don't check if the directory contains the expected files because a previous script interruption could
      # leave this directory in an undefined state. The right way is to erase the directory, whatever its contents.

      CERTOPS_RETURN_CODE="$(certops_exec)"

      if [[ ${CERTOPS_RETURN_CODE} -eq 0 ]]; then
        mail_msg \
          "${HOST_NAME}" \
          "Certificate ${DOMAIN_NAME} has been successfuly deleted." \
          "Host is now tagged to reload."

        # Reload the server configuration
        SERVICE_RESTART='true'

        IFS="§" # Set internal shell variable $IFS (Internal Field Separator) to avoid space trimming

        DB_UPDATE_DATE="$(date "${LOG_TIMESTAMP[@]}")"

        # Before : "DOM_UNAME;HOST_LOGIN;HOST_FQDN,HOST_PORT;ACCOUNT_NAME;SERVICE_NAME;DOMAIN_NAME;DELETING"
        # After  : "DOM_UNAME;HOST_LOGIN;HOST_FQDN,HOST_PORT;ACCOUNT_NAME;SERVICE_NAME;DOMAIN_NAME;DELETED - lundi 12 février 2018, 11:47:46 (UTC+0100)"
        DB_UPDATE_COMMAND="s/${DOMAIN_NAME};${DOMAIN_STATUS}/${DOMAIN_NAME};${DOMAIN_STATUS_DELETED} - ${DB_UPDATE_DATE}/"

        #--------------------------:
        log_dbg "DB_FILE_REP._CMD. : ${DB_UPDATE_COMMAND}"

        # When sed launched in bash, must use double quote instead of single quote
        sed \
          -i.bak \
          "${DB_UPDATE_COMMAND}" \
          "${DB_FILE}"
        DB_UPDATE_RETURN_CODE="${?}"

        unset IFS # Restore IFS to default space, tab & newline

        if [[ ${DB_UPDATE_RETURN_CODE} -eq 0 ]]; then
          mail_msg \
            "${HOST_NAME}" \
            "Domain ${DOMAIN_NAME} tagged DELETING has been updated as DELETED." \
            "Success"

          # Revoking is done inner because the main goal is to delete

          # /usr/local/bin/acme.sh --server letsencrypt --home /etc/acme/<account_name> --config-home /etc/acme/<account_name> --cert-home <cert_home> --dns <account_dns01> --renew --domain <domain_name>
          ACME_PARAMS=(
            --server letsencrypt
            --home "${HOME_DIR}"
            --config-home "${HOME_DIR}"
            --cert-home "${CERT_HOME}"
            --log "${LOG_ACME_ROOT}/${ACCOUNT_NAME}.log"
            --dns "${ACCOUNT_DNS01}"
            --revoke
            --domain "${DOMAIN_NAME}"
          )

          #--------------------------:
          log_dbg "ACME_COMMAND      : ${ACME_COMMAND} $(
            for param in "${ACME_PARAMS[@]}"; do
              printf ' %q' "${param}"
            done
          )"

          "${ACME_COMMAND}" "${ACME_PARAMS[@]}"
          ACME_RETURN_CODE="${?}"

          if [[ ${ACME_RETURN_CODE} -eq 0 ]]; then
            mail_msg \
              "${HOST_NAME}" \
              "Certificate ${DOMAIN_NAME} has been revoked." \
              "Success"

            # Remove local certificate
            remove_local_cert

          else
            mail_err \
              "${HOST_NAME}" \
              "Certificate ${DOMAIN_NAME} has not been revoked." \
              "Error code : ${ACME_RETURN_CODE}."
          fi

        else
          mail_err \
            "${HOST_NAME}" \
            "Domain ${DOMAIN_NAME} tagged DELETING has not been updated as DELETED." \
            "Error code : ${DB_UPDATE_RETURN_CODE}."
        fi

      else
        mail_err \
          "${HOST_NAME}" \
          "Certificate ${DOMAIN_NAME} has not been deleted." \
          "Error code : ${CERTOPS_RETURN_CODE}."
      fi

    else
      mail_err \
        "${HOST_NAME}" \
        "Certificate ${DOMAIN_NAME} do not exists." \
        "Abnormal context, abort deleting"
    fi

  fi
}

#-------------------------------------------------------------------------------
function copy_process()
#-------------------------------------------------------------------------------
# Description : Copy valid certificates to hosts
# Arguments   :
# Return      :
#-------------------------------------------------------------------------------
{
  local CERTOPS_RETURN_CODE=''

  # Test if DOMAIN_STATUS is not DELETING or DELETED
  if [[ ${DOMAIN_STATUS:0:7} == "${DOMAIN_STATUS_CREATED:0:7}" || ${DOMAIN_STATUS:0:7} == "${DOMAIN_STATUS_RENEWED:0:7}" ]]; then

    # Test if "/etc/acme/certs/DOMAIN_NAME/DOMAIN_NAME.cer" file exist (consistency check - if script was interrupted, the directory could exist with some others files)
    if [[ -f "${CERT_DIR}/${DOMAIN_NAME}.cer" ]]; then

      # Copy certificates - Execution of /etc/acme/<host>.certops content

      # IFS="§" # Set internal shell variable $IFS (Internal Field Separator) to avoid space trimming
      # source "${CERTOPS_FILE}"
      # CERTOPS_RETURN_CODE="${?}"
      # unset IFS # Restore IFS to default space, tab & newline

      CERTOPS_RETURN_CODE="$(certops_exec)"

      if [[ ${CERTOPS_RETURN_CODE} -eq 0 ]]; then
        mail_msg \
          "${HOST_NAME}" \
          "Certificate ${DOMAIN_NAME} has been successfuly copied." \
          "Host is now tagged to service reload."

        # Reload the server configuration
        SERVICE_RESTART='true'

      else
        mail_err \
          "${HOST_NAME}" \
          "Certificate ${DOMAIN_NAME} has not been copyied." \
          "Error code : ${CERTOPS_RETURN_CODE}."
      fi

    fi

  fi
}

#-------------------------------------------------------------------------------
function status_process()
#-------------------------------------------------------------------------------
# Description : Display status
# Arguments   :
# Return      :
#-------------------------------------------------------------------------------
{
  local DOMAIN_CERT_EXPIRE=''
  local FORMATTED_DOMAIN_NAME=''
  local FORMATTED_DOMAIN_STATUS=''

  if [[ ${TASK_NAME} == 'STATUS' ]]; then
    FORMATTED_DOMAIN_STATUS="${DOMAIN_STATUS:0:8}"
  else
    FORMATTED_DOMAIN_STATUS="${DOMAIN_STATUS}"
  fi

  FORMATTED_DOMAIN_NAME="$(pad_string "${DOMAIN_NAME}" 40)"

  if [[ ${DOMAIN_STATUS:0:7} == "${DOMAIN_STATUS_CREATED:0:7}" || ${DOMAIN_STATUS:0:7} == "${DOMAIN_STATUS_RENEWED:0:7}" ]]; then

    DOMAIN_CERT_EXPIRE="$(
                openssl \
                x509 \
                -dates \
                -noout \
                -in "${DOMAIN_CERT}"
    )"

    echo -e "${FORMATTED_DOMAIN_NAME} ${FORMATTED_DOMAIN_STATUS}\\t ${DOMAIN_CERT_EXPIRE//[[:space:]]/ }"

  elif [[ ${DOMAIN_STATUS} == "${NULL_VALUE}" ]]; then

    echo -e "${FORMATTED_DOMAIN_NAME} CREATION (in progress)"

  else

    echo -e "${FORMATTED_DOMAIN_NAME} ${FORMATTED_DOMAIN_STATUS}"

  fi
}

#-------------------------------------------------------------------------------
function main_process()
#-------------------------------------------------------------------------------
# Description : Read domains names database and dispatch processes
# Arguments   :
# Return      :
#-------------------------------------------------------------------------------
{
  HOST_NAME_MEM="${NULL_VALUE}"
  TASK_NAME="${1}"

  case "${TASK_NAME}" in
    STATUS | VERBOSE)
      echo ''
      ;;
    HELP)
      cat <<EOF
Usage: acmecrt.sh command
Command (one at a time):
  --create  - Create non-existent certificate (according to ${DB_FILE} database)
  --renew   - Renew certificates (from a month before they expire)
  --update  - Update certificates (create and delete according to ${DB_FILE} database)
  --delete  - Delete certificates (according to ${DB_FILE} database)
  --copy    - Distribute certificates on hosts (dedicated or virtuals)
  --status  - Status of certificates (with validy dates)
  --verbose - Status of certificates (with last operation dates and validity dates)
  --help    - Command line help
Return codes:
  0 - No fatal error, read ${LOG_MANAGER_FILE} for process related errors
  1 - Command error
  2 - Domains names database ${DB_FILE} not found.
  3 - File ${ETC_DIR}/ACCOUNT_NAME/myaccount.conf not found.
  4 - File ${ETC_DIR}/HOST_NAME.certops not found.
  5 - File ${ETC_DIR}/HOST_NAME.reload not found.
EOF
      return
      ;;
    *)
      log_msg "${TASK_NAME} - START ---------------------------------------------------------"
      ;;
  esac

  for DOMAINS_NAMES_RECORDS in "${DOMAINS_NAMES_LIST[@]}"; do

    # Read a record from acmemgr.db
    IFS=";" read -ra CURRENT_RECORD <<<"${DOMAINS_NAMES_RECORDS}"
    unset IFS

    # Initial reading of HOST_NAME
    HOST_NAME_TMP="${CURRENT_RECORD[0]}"

    #--------------------------:
    log_dbg "HOST_NAME_MEM     : ${HOST_NAME_MEM}"
    log_dbg "HOST_NAME_TMP     : ${HOST_NAME_TMP}"

    # If first loop iteration
    if [[ ${HOST_NAME_MEM} == "${NULL_VALUE}" ]]; then

      log_dbg 'Initialize HOST_NAME_MEM'
      HOST_NAME_MEM="${HOST_NAME_TMP}"

      # If new host in list (<host_name> break)
    elif [[ ${HOST_NAME_MEM} != "${HOST_NAME_TMP}" ]]; then

      log_dbg 'Host name break'
      #--------------------------:
      log_dbg "SERVICE_RESTART   : ${SERVICE_RESTART}"

      # See if previous host needed to be restarted
      if [[ ${SERVICE_RESTART} == 'true' ]]; then

        SERVICE_RESTART='false'

        log_dbg 'Service restart'

        # At this point all vars for previous domain are still available, so the host to reload

        # Reload service - Execution of /etc/acme/<host>.reload content
        RELOAD_FILE="${ETC_DIR}/${HOST_NAME}.reload"

        #--------------------------:
        log_dbg "RELOAD_COMMAND    : ${RELOAD_COMMAND}"

        # ssh -p <host_port> <host_login>@<host_fqdn> bash < /etc/acme/<host>.reload content
        if ssh \
          -p "${HOST_PORT}" \
          "${HOST_LOGIN}@${HOST_FQDN}" \
          bash <"${RELOAD_FILE}"; then
          mail_msg \
            "${HOST_NAME}" \
            "Service has been reloaded." \
            'Success'
        else
          mail_err \
            "${HOST_NAME}" \
            "Service has not been reloaded." \
            "Error code : ${?}."
        fi
      fi
    fi

    # Update vars for current host
    HOST_NAME_MEM="${HOST_NAME_TMP}"

    #--------------------------:
    log_dbg "HOST_NAME_MEM     : ${HOST_NAME_MEM}"

    if [[ ${HOST_NAME_MEM} != "${NULL_VALUE}" ]]; then

      # Record : "DOM_UNAME;HOST_LOGIN;HOST_FQDN,HOST_PORT;ACCOUNT_NAME;SERVICE_NAME;DOMAIN_NAME;[DOMAIN_STATUS]"

      HOST_NAME=${CURRENT_RECORD[0]}    # HOST_NAME       : Host name for scripting, mailing and filtering purposes (only a-z,0-9,'-','_')
      HOST_LOGIN=${CURRENT_RECORD[1]}   # HOST_LOGIN      : Host login
      HOST_FQDN=${CURRENT_RECORD[2]}    # HOST_FQDN       : Host url (qualified form or "domuNNNv1" for local HOST)
      HOST_PORT=${CURRENT_RECORD[3]}    # HOST_PORT       : Host port
      ACCOUNT_NAME=${CURRENT_RECORD[4]} # ACCOUNT_NAME    : Registrar DNS-01 API account to which the domain name belongs
      DOMAIN_NAME=${CURRENT_RECORD[5]}  # DOMAIN_NAME     : Domain name hosted

      # Check if CURRENT_RECORD[6] is defined

      if [[ -n ${CURRENT_RECORD[6]+set} ]]; then
        log_dbg 'CURRENT-RECORD-6 was SET'
        DOMAIN_STATUS="${CURRENT_RECORD[6]}" # CURRENT_RECORD[6] is defined
      else
        log_dbg 'CURRENT-RECORD-6 was UNSET'
        DOMAIN_STATUS="${NULL_VALUE}" # CURRENT_RECORD[6] is not defined
      fi

      HOME_DIR="${ETC_DIR}/${ACCOUNT_NAME}"

      ACCOUNT_FILE="${HOME_DIR}/myaccount.conf"
      CERTOPS_FILE="${ETC_DIR}/${HOST_NAME}.certops"
      RELOAD_FILE="${ETC_DIR}/${HOST_NAME}.reload"

      # Check files

      if [[ -f ${ACCOUNT_FILE} ]]; then
        # shellcheck source=/dev/null
        source "${ACCOUNT_FILE}" # Loading ACCOUNT_FILE then read ACCOUNT_DNS01, CERT_HOME & ACCOUNT_EMAIL values
      else
        mail_err \
          "${HOST_NAME}" \
          "File ${ACCOUNT_FILE} not found." \
          'Error'
        exit 3
      fi

      if [[ ! -f ${CERTOPS_FILE} ]]; then
        mail_err \
          "${HOST_NAME}" \
          "File : ${CERTOPS_FILE} not found." \
          'Error'
        exit 4
      fi

      if [[ ! -f ${RELOAD_FILE} ]]; then
        mail_err \
          "${HOST_NAME}" \
          "File : ${RELOAD_FILE} not found." \
          'Error'
        exit 5
      fi

      CERT_DIR="${CERT_HOME}/${DOMAIN_NAME}"      # /etc/acme/certs/<domain_name>
      DOMAIN_KEY="${CERT_DIR}/${DOMAIN_NAME}.key" # /etc/acme/certs/<domain_name>/www.domain.tld.key
      DOMAIN_CERT="${CERT_DIR}/${CERT_FULLCHAIN}" # /etc/acme/certs/<domain_name>/fullchain.cer

      # Debug display
      #--------------------------:
      log_dbg "HOST_NAME         : ${HOST_NAME}"
      log_dbg "HOST_LOGIN        : ${HOST_LOGIN}"
      log_dbg "HOST_FQDN         : ${HOST_FQDN}"
      log_dbg "HOST_PORT         : ${HOST_PORT}"
      log_dbg "ACCOUNT_NAME      : ${ACCOUNT_NAME}"
      log_dbg "DOMAIN_NAME       : ${DOMAIN_NAME}"
      log_dbg "DOMAIN_STATUS     : ${DOMAIN_STATUS}"
      log_dbg "CERT_DIR          : ${CERT_DIR}"
      log_dbg "DOMAIN_KEY        : ${DOMAIN_KEY}"
      log_dbg "DOMAIN_CERT       : ${DOMAIN_CERT}"
      log_dbg "HOME_DIR          : ${HOME_DIR}"
      log_dbg "ACCOUNT_FILE      : ${ACCOUNT_FILE}"
      log_dbg "CERTOPS_FILE      : ${CERTOPS_FILE}"
      log_dbg "RELOAD_FILE       : ${RELOAD_FILE}"
      log_dbg "ACCOUNT_DNS01     : ${ACCOUNT_DNS01}"

      case "${TASK_NAME}" in
        CREATE)
          create_process
          ;;
        RENEW)
          renew_process
          ;;
        UPDATE)
          delete_process
          create_process
          ;;
        DELETE)
          delete_process
          ;;
        COPY)
          copy_process
          ;;
        STATUS | VERBOSE)
          status_process
          ;;
      esac

    else
      if [[ ${TASK_NAME} == 'STATUS' || ${TASK_NAME} == 'VERBOSE' ]]; then
        echo ''
      else
        log_msg "${TASK_NAME} - END -----------------------------------------------------------"
      fi
    fi
  done
}

#-------------------------------------------------------------------------------
# main_program
#-------------------------------------------------------------------------------

COMMAND_NAME="${1}"

NULL_VALUE='null'
SERVICE_RESTART='false'
TASK_NAME='INIT  '

DOMAIN_STATUS_DELETING='DELETING'
DOMAIN_STATUS_DELETED='DELETED'
DOMAIN_STATUS_CREATED='CREATED'
DOMAIN_STATUS_RENEWED='RENEWED'

CERT_FULLCHAIN='fullchain.cer'
CERT_CA='ca.cer'

LOG_TIMESTAMP=() # To be acme.sh log compliant (same format). Replace LOG_TIMESTAMP=("+%Y%m%d - %H%M%S")

LOCAL_HOST="$(hostname --short)"

# Create log file if nonexistent
if [[ ! -f ${LOG_MANAGER_FILE} ]]; then
  install -D /dev/null "${LOG_MANAGER_FILE}"
fi

cat <<EOF

Sowebio SARL (R) An acme.sh manager using DNS-01 protocol. Version ${MANAGER_VERSION}.
Copyright    (C) Sowebio SARL & all listed authors 2017-2019, according to GPLv3 or greater.

EOF

#--------------------------:
log_dbg "DB_FILE           : ${DB_FILE}"

if [[ -f ${DB_FILE} ]]; then
  # shellcheck source=/dev/null
  source "${DB_FILE}"

  # acmemgr.sh renamed acmemgr.create is eq to acmemgr.sh --create (useful for /etc/cron.hourly jobs)
  if [[ $0 == *.update* ]]; then
    COMMAND_NAME='--update'
  fi

  # acmemgr.sh renamed acmemgr.renew is eq to acmemgr.sh --renew (useful for /etc/cron.weekly jobs)
  if [[ ${0} == *.renew* ]]; then
    COMMAND_NAME='--renew'
  fi

  case "${COMMAND_NAME}" in
    --create)
      main_process 'CREATE'
      ;;
    --renew)
      main_process 'RENEW'
      ;;
    --update)
      main_process 'UPDATE'
      ;;
    --copy)
      main_process 'COPY'
      ;;
    --delete)
      main_process 'DELETE'
      ;;
    --status)
      main_process 'STATUS'
      ;;
    --verbose)
      main_process 'VERBOSE'
      ;;
    --help)
      main_process 'HELP'
      ;;
    *)
      main_process 'HELP'
      exit 1
      ;;
  esac
  exit 0

else
  mail_err 'INIT' "File ${DB_FILE} not found." 'Error'
  exit 2
fi

#----------------------------------------------------------------------------
# EOF
#----------------------------------------------------------------------------
