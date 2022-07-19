#!/usr/bin/env bash

# ---
# staytus-simplecheck 0.1.0
# simple status checker for staytus as bash script
# --
# (c) 2022 mplx <developer@mplx.eu>
# MIT License (see enclosed LICENSE file)
# --
# Docs and latest download at
# https://github.com/mplx/staytus-simplecheck
# --
# Usage:
# [set env variables] ./staytuscheck.sh [/path/to/config.file]
# Example: RESET=1 VERBOSE=1 ./staytuscheck.sh ./sample.cfg
# Requirements: bash, ncat, curl, jq, coreutils
# ---

# declare arrays for check configuration
declare -A staytus_ssh
declare -A staytus_http
declare -A staytus_https
declare -A staytus_websites
declare -A staytus_smtp
declare -A staytus_smtp_alt
declare -A staytus_smtps
declare -A staytus_imap
declare -A staytus_imaps
declare -A staytus_static
declare -A staytus_dns
declare -A staytus_mysql

# load config
if [[ $# -gt 1 && -f "$1" ]]; then
  source $1
else
  if [ -f "/etc/staytuscheck.cfg" ]; then
    source /etc/staytuscheck.cfg
  fi
  if [ -f "./staytuscheck.cfg" ]; then
    source ./staytuscheck.cfg
  fi
fi

# env: VERBOSE: enable verbose output; 0-disable, 1-basic output, 2-enhanced output
VERBOSEMODE=${VERBOSE:-0}
# env: PERMALINK_OK: staytus permalink slug for 'test successfull'
SLUGOK=${PERMALINK_OK:-"operational"}
# env: PERMALINK_ERR: staytus permalink slug for 'test failed'
SLUGERR=${PERMALINK_ERR:-"major-outage"}
# env: PERMALINK_ERR: staytus permalink slug for resetting services before checks
SLUGRESET=${PERMALINK_RESET:-"maintenance"}
# env: USERAGENT: useragent for curl requests
USERAGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/103.0.0.0 Safari/537.36"
# env: TIMEOUT: timeout for curl and ncat in seconds
TIMEOUTSEC=${TIMEOUT:-5}

# env: ANSI_ERR: enable ansi colors for staytus api errors
ANSIERR=${ANSI:-0}
RED='\033[0;31m'
NC='\033[0m'

# fun: show_array arr
# txt: debugging helper - output an array
# opt: arr: array for output
# use: show_array checklist
function show_array() {
  local -n arr=$1
  for i in "${!arr[@]}"; do
    printf "%s\t%s\n" "$i" "${arr[$i]}"
  done
}

# fun: staytus_setstatus service-permalink status-permalink
# txt: sets staytus status for specified service
# opt: service: permalink-slug for service
# opt: status: permalink-slug for status
# use: staytus_setstatus service status
function staytus_setstatus() {
  local service=$1
  local status=$2

  response=$(curl -s --connect-timeout "${TIMEOUTSEC}" -A "${USERAGENT}" -X POST -H "X-Auth-Token: ${TOKEN}" -H "X-Auth-Secret: ${SECRET}" -H "Content-Type: application/json" "${STAYTUS_URL}/api/v1/services/set_status" -d "{\"service\":\"${service}\",\"status\":\"${status}\"}" | jq -r '.status')
  if [ "${VERBOSEMODE}" -gt 0 ]; then
    if [ "${response}" == "success" ]; then
      echo "$(date +'%Y-%m-%dT%H:%M:%S%z')" "=> $service => $status => $response"
    else
      [ "${ANSI}" -gt 0 ] && echo -e "${RED}"
      echo "$(date +'%Y-%m-%dT%H:%M:%S%z')" "=> $service => $status => $response" >&2;
      [ "${ANSI}" -gt 0 ] && echo -e "${NC}"
    fi
  fi
}

# fun: staytus_reset
# txt: fetches list of all existing services and set their status to default value (env: PERMALINK_RESET)
# use: staytus_reset
function staytus_reset() {
  checklist=$(curl -s --connect-timeout "${TIMEOUTSEC}" -A "${USERAGENT}" -X POST -H "X-Auth-Token: ${TOKEN}" -H "X-Auth-Secret: ${SECRET}" -H "Content-Type: application/json" "${STAYTUS_URL}/api/v1/services/all" -d '{}' | jq -r .data[].permalink)
  for service in $checklist; do
    staytus_setstatus "${service}" "${SLUGRESET}"
  done
}

# fun: check_portservice port checklist
# txt: tests tcp port with ncat and set service status (ok/nok)
# opt: port: tcp port to test
# opt: checklist: assoc array with service-permalink (key) and ip address or fqdn (value)
# use: check_portservice 22 checklist
function check_portservice() {
  local port=$1
  shift
  local -n checklist=$1

  for service in "${!checklist[@]}"; do
    ip=${checklist[$service]}
    ncat -z -w "${TIMEOUTSEC}" "${ip}" "${port}"
    rc=$?
    if [ $rc -ne 0 ]; then
      status="${SLUGERR}"
    else
      status="${SLUGOK}"
    fi
    staytus_setstatus "${service}" "${status}"
  done
}

# fun: check_webservice checklist
# txt: retrieve status of http/https url
# opt: checklist: assoc array with service-permalink (key) and url (value)
# use: check_webservice checklist
function check_webservice() {
  local -n checklist=$1

  for service in "${!checklist[@]}"; do
    website=${checklist[$service]}
    response=$(curl --connect-timeout "${TIMEOUTSEC}" --write-out '%{http_code}' --silent --output /dev/null "${website}")
    responseClass=${response:0:1}
    if [ "${responseClass}" == "2" ] || [ "${responseClass}" == "3" ] || [ "${response}" == "401" ]; then
      status="${SLUGOK}"
    else
      status="${SLUGERR}"
    fi
    if [ "${VERBOSEMODE}" -gt 1 ]; then
      echo "$(date +'%Y-%m-%dT%H:%M:%S%z')" "=> $service => $website => $response => $responseClass => $status"
    fi
    staytus_setstatus "${service}" "${status}"
  done
}

# fun: process_static checklist
# txt: set specified status for staytus service, no checks
# opt: checklist: assoc array with service-permalink (key) and status-permalink (value)
# use: process_static checklist
function process_static() {
  local -n checklist=$1

  for service in "${!checklist[@]}"; do
    status=${checklist[$service]}
    staytus_setstatus "${service}" "${status}"
  done
}

# staytus_reset
if [ "${RESET:-0}" -gt 0 ]; then
  staytus_reset
fi

# process_unused (or reset used ones)
if [ ${#staytus_static[@]} -gt 0 ]; then
  process_static staytus_static
fi

# check ssh ports
if [ ${#staytus_ssh[@]} -gt 0 ]; then
  check_portservice 22 staytus_ssh        # ssh
fi
if [ ${#staytus_http[@]} -gt 0 ]; then
  check_portservice 80 staytus_http       # http
fi
if [ ${#staytus_https[@]} -gt 0 ]; then
  check_portservice 443 staytus_https     # https
fi
if [ ${#staytus_dns[@]} -gt 0 ]; then
  check_portservice 53 staytus_dns        # dns/tcp
fi

# check webservices
if [ ${#staytus_websites[@]} -gt 0 ]; then
  check_webservice staytus_websites       # http/https
fi

# check mysql/mariadb/galera
if [ ${#staytus_mysql[@]} -gt 0 ]; then
  check_portservice 3306 staytus_mysql    # mysql/mariadb/galera
fi

# check mail service ports
if [ ${#staytus_smtp[@]} -gt 0 ]; then
  check_portservice 25 staytus_smtp       # smtp
fi
if [ ${#staytus_smtps[@]} -gt 0 ]; then
  check_portservice 465 staytus_smtps     # smtps
fi
if [ ${#staytus_smtp_alt[@]} -gt 0 ]; then
  check_portservice 587 staytus_smtp_alt  # alt-smtp
fi
if [ ${#staytus_imap[@]} -gt 0 ]; then
  check_portservice 110 staytus_imap      # imap
fi
if [ ${#staytus_imaps[@]} -gt 0 ]; then
  check_portservice 995 staytus_imaps     # imaps
fi