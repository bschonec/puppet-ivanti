#!/bin/sh
# **********************************************************
# Copyright 2020 Ivanti. All rights reserved.
# **********************************************************
#
# Currently two environment variables can be set:
#   cronperiod - Defines the time period between inventory scans: daily, weekly, monthly - default daily
#   corelanguage - Placed in the ${INSTALL_PREFIX}/etc/landesk.conf file if defined.
#

# Ensure commands in this script run in the C locale
export LANGUAGE=C
export LC_ALL=C

#
# Define Constants
#
ERROR=0
WARN=1
INFO=2
DEBUG=3
ALL_COMP_PKGS="ivanti-cba8 ivanti-base-agent ivanti-pds2 ivanti-inventory ivanti-software-distribution ivanti-vulnerability ivanti-schedule" # Note: Install order (on Linux ivanti-pds2 will be inserted into list)
ALL_PKGS="cba8 ldiscan sdclient vulscan" # Note: Install order (on Linux pds2 will be inserted into list)
LEGACY_PKGS="cba8 ldiscan sdclient vulscan ldsmmonitor lsm-server lsm-admin lsm-client lsm-common Lbridge megalib mgmtutilsSuSE mgmtutils ldipmi ldnaSuSEldna ldsmbios smbase alertsync lddeppkg"
INI_ENTRIES="CBA SD VS"
LEGACY_PREFIX="/usr/LANDesk"
INSTALL_PREFIX="/opt/landesk"
GLOBAL_UID_FILE="${INSTALL_PREFIX}/etc/guid"
CERT_PREFIX="${INSTALL_PREFIX}/var/cbaroot/certs"
LDMS_USER="landesk"
LDMS_GROUP="landesk"
SCRIPT=`basename $0`
WD=`echo $0 | sed "s/\(.*\)\/${SCRIPT}$/\1/"`
[ "${WD}" = "${SCRIPT}" ] && WD="." # Assume local directory if not provided.
STD_SEARCH_PATH="/usr/sbin:/sbin:/usr/sfw/bin:/usr/sfw/sbin:/opt/csw/bin:/opt/csw/sbin:/etc/init.d:${WD}:."

readonly ERROR
readonly WARN
readonly INFO
readonly DEBUG
readonly ALL_PKGS
readonly ALL_COMP_PKGS
readonly LEGACY_PKGS
readonly INI_ENTRIES
readonly LEGACY_PREFIX
readonly GLOBAL_UID_FILE
readonly INSTALL_PREFIX
readonly CERT_PREFIX
readonly LDMS_USER
readonly LDMS_GROUP
readonly SCRIPT
readonly WD
readonly STD_SEARCH_PATH

#
# Global Variables
#
VERBOSE=$INFO

####################################
#     Utility Functions            #
####################################
#
# Write a message to the console if the verbose level is greater or equal
# to the parameter level.
#
# Param $1 - Logging level
# Param $2 - Text to write to console
#
log() {
    prefix="`date`"
    [ $1 -eq $ERROR ] && prefix="`date`: ERROR"
    [ $1 -eq $WARN ] && prefix="`date`: Warning"
    [ $1 -eq $DEBUG ] && prefix="`date`: Debug"
    if [ -z "${LOGFILE:-}" ]; then
        [ $1 -le $VERBOSE ] && echo "${prefix}: ${2}"
    else
        [ $1 -eq $ERROR ] && echo "${prefix}: ${2}" 1>&2
        [ $1 -le $VERBOSE ] && echo "${prefix}: ${2}" >> "${LOGFILE}"
    fi
}

#
# Flip a string of words
#
reverse_string() {
    str="$1"
    local_result=
    for word in $str; do
        local_result="$word $local_result"
    done
    eval $2='"${local_result}"'
}

#
# Remove the installation files when not in DEBUG mode.
#
cleanup_tmp_files() {
    if [ -n "${LOGFILE:-}" ]; then
        ${ED} "${LOGFILE}" >/dev/null 2>&1 << EOF_COPY
w ${INSTALL_PREFIX}/log/install.log
q
EOF_COPY
    fi

    if [ ${DEBUG} -ne ${VERBOSE} ]; then
        rm -f /tmp/ldinvperiod.tmp
        for cert in ${CERT_FILES}; do
            rm -f ${cert}
        done

        if [ ${LEGACY_INSTALL} -ne 0 ]; then
            rm -f baseclient64.tar.gz
            rm -f vulscan64.tar.gz
            rm -f setup.sh
        fi

        for pkg in ${ALL_PKGS} ${ALL_COMP_PKGS}; do
            rm -f ${pkg}*
            if [ "${OS_TYPE}" = "linux" -a "${pkg}" = "cba8" ]; then
                rm -f pds2*
            fi
        done

        if [ ${INSTALL_MISSING} -ne 0 ]; then
            [ "${OS_TYPE}" = "aix" -o "${OS_TYPE}" = "linux" ] && rm -f *.rpm
            [ "${OS_TYPE}" = "hpux" ] && rm -f *.depot
            [ "${OS_TYPE}" = "sunos" ] && rm -f *.pkg
        fi
    fi
}

#
# Standard way to print error message and clean up installation when the script fails.
# Clean up only occurs if the 3rd argument is passed in as a non-zero value.
#
# Param $1 - Error message to print to console
# Param $2 - Return code indicating failure
# Param $3 - Whether or not to cleanup files.
#
abort() {
    msg="$1"
    rv="${2:-1}"
    clean="${3:-0}"

    if [ ${clean} -ne 0 ]; then
        cleanup_tmp_files
    fi
    log $ERROR "${msg} -- aborting"
    log $INFO "${SCRIPT} done."
    exit $rv
}

#
# Fetch a file from a remote location either wget or curl.  Wget is the preferred method of download.
# No wildcards are allowed.
#
# Param $1 - Base URL to pull the file from (URL: $1/$2)
# Param $2 - Filename to pull
#
fetch_file_exact() {
    base_url="$1"
    filename="$2"

    local_file=`ls -q ${filename} 2>/dev/null | sed -n '$p'`
    if [ -z "$local_file" ]; then
    	if [ "${USE_CSA}" -eq 1 ]; then
    		log $ERROR "File ${filename} must be local if using CSA tunnel, cannot fetch from core"
    		return 1
    	fi
        log $INFO "Fetch requested file: ${base_url}/${filename}"
        if [ -n "${WGET}" ]; then
            log $DEBUG "Using wget for file fetch request: ${base_url}/${filename}"
            ${WGET} -t 1 -T 120 -q "${base_url}/${filename}"
        elif [ -n "${CURL}" ]; then
            log $DEBUG "Using curl for file fetch request: ${base_url}/${filename}"
            ${CURL} --connect-timeout 120 -f -s -O "${base_url}/${filename}" > /dev/null
        fi

        if [ $? -ne 0 ]; then
            log $WARN "Failed to fetch file: ${base_url}/${filename}"
            return 1
        else
            log $INFO "Successfully fetched file: ${filename}"
        fi
    else
        log $INFO "Local file exists with same name (canceled fetch): ${filename} == ${local_file}."
    fi
    return 0
}

#
# Fetch a file from a remote location either wget or curl.  Wget is the preferred method of download.
#
# Param $1 - Base URL to pull the file from (URL: $1/$2)
# Param $2 - Filename to pull
#
fetch_file() {
    base_url="$1"
    filename="$2"

    local_file=`ls -q ${filename} 2>/dev/null | sed -n '$p'`
    if [ -z "$local_file" ]; then
        if [ "${USE_CSA}" -eq 1 ]; then
    		log $ERROR "File ${filename} must be local if using CSA tunnel, cannot fetch from core"
    		return 1
    	fi
        log $INFO "Filename or pattern to search for on Core: ${filename}."
        if [ -n "${WGET}" ]; then
            file_list=`${WGET} -q -O - ${base_url}/ | tr '<' '\n' | grep HREF | sed -n -e '2,$s/A HREF=".*\/\([^"]*\).*/\1/p' | paste -s -d" " -`
        elif [ -n "${CURL}" ]; then
            file_list=`${CURL} -f -s --list-only ${base_url}/ | tr '<' '\n' | grep HREF | sed -n -e '2,$s/A HREF=".*\/\([^"]*\).*/\1/p' | paste -s -d" " -`
        fi
        log $DEBUG "Files available on server: ${file_list}"

        file_not_found=0
        for file in ${file_list}; do
            log $DEBUG "Attempting to match ${file}"
            contains "${file}" "${filename}"
            if [ $? -eq 0 ]; then
                log $INFO "Server file matched: ${filename} == ${file}"
                file_not_found=1
                filename="${file}"
                break
            fi
        done

        # Error out if the regular expression was not matched by an entry in
        # the Core file list.
        if [ $file_not_found -eq 0 ]; then
            log $WARN "Core does not have a file match for regex: ${filename}"
            return 1
        fi

        log $INFO "Fetch requested file: ${base_url}/${filename}"
        if [ -n "${WGET}" ]; then
            log $DEBUG "Using wget for file fetch request: ${base_url}/${filename}"
            ${WGET} -t 1 -T 120 -q "${base_url}/${filename}"
        elif [ -n "${CURL}" ]; then
            log $DEBUG "Using curl for file fetch request: ${base_url}/${filename}"
            ${CURL} --connect-timeout 120 -f -s -O "${base_url}/${filename}" > /dev/null
        fi

        if [ $? -ne 0 ]; then
            log $WARN "Failed to fetch file: ${base_url}/${filename}"
            return 1
        else
            log $INFO "Successfully fetched file: ${filename}"
        fi
    else
        log $INFO "Local file exists with same name (canceled fetch): ${filename} == ${local_file}."
    fi
    return 0
}

#
# Test a connection to host based on URL using wget or cURL.
#
# Param $1 - URL for testing purposes.
#
test_connection() {
    url="$1"

    log $INFO "Testing connection to: ${url}"
    if [ -n "${WGET}" ]; then
        log $DEBUG "Using wget for connection test: ${url}"
        ${WGET} -t 1 -T 120 -Sq -O- "${url}" > /dev/null 2>&1
    elif [ -n "${CURL}" ]; then
        log $DEBUG "Using curl for connection test: ${url}"
        ${CURL} --connect-timeout 120 -f -s "${url}" > /dev/null 2>&1
    fi

    return $?
}

#
# Take the known OS type and vendor and determine the old package abbreviated name.
#
# Param $1 - OS Type normalized
# Param $2 - OS Vendor normalized
# Out $3 - OS abbreviation (aix, hpux, sol, cent, rh, sles)
#
os_type_abbreviation() {
    os_type="$1"
    os_abr_vendor="$2"
    abr="$3"

    log $DEBUG "Call os_type_abbreviation(${os_type}, ${os_abr_vendor}, ${abr})"

    [ "${os_type}" = "aix" ] && eval ${abr}="${os_type}"
    [ "${os_type}" = "hpux" ] && eval ${abr}="${os_type}"
    [ "${os_type}" = "sunos" ] && eval ${abr}="sol"
    if [ "${os_type}" = "linux" ]; then
        log $DEBUG "Linux type found - eval for ${os_abr_vendor}"
        [ "${os_abr_vendor}" = "centos" ] && eval ${abr}="cent"
        [ "${os_abr_vendor}" = "redhat" ] && eval ${abr}="rh"
        [ "${os_abr_vendor}" = "sles" ] && eval ${abr}="sles"
        [ "${os_abr_vendor}" = "debian" ] && eval ${abr}="$DEBIAN_SUB_VENDOR"
    fi
    log $DEBUG "Returning abbreviation: ${abr}"
}

#
# Get a list of process ids based on a search term (command name or pid).
#
# Param $1 - OS Type normalized
# Param $2 - Search terms which are either command name or pid
# Out $3 - List of process ids space seperated
#
get_pids() {
    os_type="$1"
    search="$2"

    ps_options="pid,command"
    [ "${os_type}" = "hpux" -o "${os_type}" = "sunos" ] && ps_options="pid,comm"

    # When searching for a PID to process, remove the grep/ps commands and the current PID if reported.
    eval $3='"`UNIX95=\"\" ps -eo ${ps_options} | grep ${search} | grep -v grep | grep -v ps | grep -v \"$0 \" | sed \"s/^[^0-9]*\([0-9]*\).*/\1/\" | paste -s -d\" \" -`"'
}

#
# Get a list of landesk specific process ids based on command names. Duplicate
# executable names are reduced to the newest architecture that contains the
# same name.
#
# Param $1 - OS Type normalized (passed down to get_pids()
# Param $2 - List of process ids space seperated
#
get_landesk_pids() {
    os_type="$1"
    map_agent_execs="ldiscan map-cpuscan map-envvarscan map-fetch map-filescan map-memscan map-mountscan  \
                     map-networkconfiguration map-osscan map-packagescan map-phydrivescan map-reporter    \
                     map-scheduler map-scraper sdclient map-sender map-systemscan map-versionscan vulscan \
                     schedule"
    legacy_agent_execs="alertsync sendstatus"
    cba_execs="cba pds2 proxyhost"
    landesk_execs="${cba_execs} ${map_agent_execs} ${legacy_agent_execs}"
    ld_pid_list=""

    for exec in ${landesk_execs}; do
        log $DEBUG "Testing for running LANDesk executable: ${exec}"
        get_pids "${os_type}" "${exec}" ld_pid
        if [ -n "${ld_pid}" ]; then
            log $DEBUG "LANDesk running pid: ${ld_pid}"
            [ -n "${ld_pid_list}" ] && ld_pid_list="${ld_pid_list} ${ld_pid}"
            [ -z "${ld_pid_list}" ] && ld_pid_list="${ld_pid}"
        fi
    done
    eval $2='"${ld_pid_list}"'
}

#
# Terminate a list of processes based on their process id.  Initially a TERM signal is sent to the process
# which is checked after a second. If the signal did not shutdown the process, the process is
# terminated with a KILL signal.
#
# Param $1 - OS Type normalized
# Param $2 - Process id list space seperated (note: a single process id is also allowed)
#
kill_process() {
    os_type="$1"
    pids="$2"
    for pid in ${pids}; do
        # If our pid is passed in, ignore it because committing suicide would be bad.
        if [ $pid -eq $$ ]; then
            log $DEBUG "Script pid passed in - not terminating pid: ${pid}"
            continue
        fi

        log $DEBUG "Forcefully terminating ${pid}"
        ${KILL} -TERM $pid 2>/dev/null
        sleep 1
        get_pids "${os_type}" "${pid}" pid
        if [ -n "${pid}" ]; then
            log $DEBUG "Process not terminated, attempting SIGKILL: ${pid}"
            ${KILL} -KILL $pid 2>/dev/null
            sleep 1
            get_pids "${os_type}" "${pid}" pid
            [ -n "${pid}" ] && log $ERROR "Process not terminating: ${pid}"
        fi
    done
}

#
# Search a given string for a substring.  Returns 0 if the substring occurs within the string.
#
# Param $1 - The string to search for a given substring.
# Param $2 - The substring (needle)
#
contains() {
    haystack="$1"
    needle="$2"

    case "$haystack" in
        *$needle*) return 0 ;;
    esac
    return 1
}

#
# Search a given string for a string.  Returns 0 if the string occurs within the string.
#
# Param $1 - The string to search for a given substring.
# Param $2 - The substring (needle)
#
contains_match() {
    haystack="$1"
    needle="$2"

    for thing in ${haystack}; do
        if [ "${thing}" = "${needle}" ]; then
            return 0
        fi
    done
    return 1
}
#
# Determine if a character is part of the alphabetic set: [A-Za-z].
#
# Param $1 - The character to test against the alphabetic set.
#
# Return 0 - Character is part of the alphabetic set.
#        1 - Character is not alphabetic.
#
isalpha() {
    alpha_char="$1"
    case "${alpha_char}" in
        [A-Za-z]) return 0 ;;
        *) return 1 ;;
    esac
}

#
# Determine if a character is part of the numeric set: [0-9].
#
# Param $1 - The character to test against the numeric set.
#
# Return 0 - Character is part of the numeric set.
#        1 - Character is not numeric.
#
isdigit() {
    digit_char="$1"
    case "${digit_char}" in
        [0-9]) return 0 ;;
        *) return 1 ;;
    esac
}

#
# Determine if a character is part of the alphanumeric set: [A-Za-z0-9].
#
# Param $1 - The character to test against the alphanumeric set.
#
# Return 0 - Character is part of the alphanumeric set.
#        1 - Character is not alphanumeric.
#
isalnum() {
    alnum_char="$1"

    isalpha "${alnum_char}"
    if [ $? -ne 0 ]; then
        isdigit "${alnum_char}"
        return $?
    fi
    return 1
}

#
# Compare two strings
#
# Param $1 - First string for comparison
# Param $2 - Second string for comparison
#
# Return 0 - Strings match
#        1 - $1 sorts lexicographically after $2
#        2 - $1 sorts lexicographically before $2
#
strcmp() {
    str1="$1"
    str2="$2"

    log $DEBUG "strcmp - String comparison: ${str1} == ${str2}"

    # Determine the longest string for the loop control
    loop_len=${#str2}
    [ ${#str1} -gt ${#str2} ] && loop_len=${#str1}
    log $DEBUG "strcmp - Loop length: ${loop_len}"

    # Loop through the individual characters of each string and determine
    # the type of characters.  If they are both of the same type, they will
    # be compared otherwise they are skipped.
    idx=0
    while [ ${idx} -lt ${loop_len} ]; do
        idx=`expr $idx + 1`

        char1=`echo ${str1} | cut -c ${idx}-${idx}`
        char2=`echo ${str2} | cut -c ${idx}-${idx}`

        log $DEBUG "strcmp - char1: ${char1}   char2: ${char2}"
        isdigit "${char1}"
        is_char1_digit=$?
        isdigit "${char2}"
        is_char2_digit=$?

        if [ ${is_char1_digit} -eq 0 -a ${is_char2_digit} -eq 0 ]; then
            log $DEBUG "strcmp - Comparing two digits"
            if [ ${char1} -eq ${char2} ]; then
                log $DEBUG "strcmp - ${char1} == ${char2} -- continue"
                continue;
            elif [ ${char1} -gt ${char2} ]; then
                log $DEBUG "strcmp - ${char1} > ${char2} -- return 1"
                return 1
            else
                log $DEBUG "strcmp - ${char2} > ${char1} -- return 2"
                return 2
            fi
        elif [ ${is_char1_digit} -eq 1 -a ${is_char2_digit} -eq 1 ]; then
             log $DEBUG "strcmp - Comparing two alphas"
            if [ "${char1}" == "${char2}" ]; then
                log $DEBUG "strcmp - ${char1} == ${char2} -- continue"
                continue;
            elif [ "${char1}" > "${char2}" ]; then
                log $DEBUG "strcmp - ${char1} > ${char2} -- return 1"
                return 1
            else
                log $DEBUG "strcmp - ${char2} > ${char1} -- return 2"
                return 2
            fi
        fi

        # Get out of look the end of any string is hit prior to the other.
        [ ${idx} -ge ${#str1} -a ${idx} -ge ${#str2} ] && break
    done

    # Strings that are equal in length and get to here are considered matches.
    [ ${#str1} -eq ${#str2} ] && return 0

    # If strings aren't equal length, the longest is considered the winner.
    if [ ${#str1} -gt ${#str2} ]; then
        log $DEBUG "strcmp - Length comparison: ${#str1} > ${#str2} -- return 1"
        return 1
    else
        log $DEBUG "strcmp - Length comparison: ${#str2} > ${#str1} -- return 2"
        return 2
    fi
}

#
# This algorithm is taken from the C API for RPM and converted to shell.
#
# Compare alphanumeric segments of two RPM versions.
# Note: version and release should be fed into this function separately.
#
# Param $1 - First version segment for comparison
# Param $2 - Second version segment for comparison
#
# Return 0 - a and b are the same version
#        1 - a is newer than b
#        2 - b is newer than a
#
rpmvercmp() {
    version_a="${1}"
    version_b="${2}"
    cmp=0 # assume the versions match
    log $DEBUG "RPM version comparison: ${version_a} ? ${version_b}"

    # Easy comparison to see if versions are identical
    if [ "${version_a}" = "${version_b}" ]; then
        return ${cmp}
    fi

    # Loop through each segment of version_a and version_b and compare them
    index_a=0
    index_b=0
    while [ $index_a -lt ${#version_a} -o $index_b -lt ${#version_b} ]; do
        index_a=`expr $index_a + 1`
        index_b=`expr $index_b + 1`

        # Get the characters 1 at a time for comparison.
        ch_a=`echo ${version_a} | cut -c ${index_a}-${index_a}`
        ch_b=`echo ${version_b} | cut -c ${index_b}-${index_b}`
        log $DEBUG "rpmvercmp - ch_a: ${ch_a}   tc_two: ${ch_b}"

        # Walk through each version string until an alphanumeric or tilde is found.
        while [ ${index_a} -lt ${#version_a} -a "${ch_a}" != "~" ]; do
            isalnum "${ch_a}"
            [ $? -eq 0 ] && break
            index_a=`expr $index_a + 1`
            ch_a=`echo ${version_a} | cut -c ${index_a}-${index_a}`
            log $DEBUG "rpmvercmp - Grabbing next character: ${ch_a}"
        done
        while [ ${index_b} -lt ${#version_b} -a "${ch_b}" != "~" ]; do
            isalnum "${ch_b}"
            [ $? -eq 0 ] && break
            index_b=`expr $index_b + 1`
            ch_b=`echo ${version_b} | cut -c ${index_b}-${index_b}`
            log $DEBUG "rpmvercmp - Grabbing next character: ${ch_b}"
        done

        # Handle the tilde separator, the string without tilde is newer
        if [ "${ch_a}" = "~" -o "${ch_b}" = "~" ]; then
            log $DEBUG "rpmvercmp - Tilde separator detected, string without tilde is newer."
            if [ "${ch_a}" != "~" ]; then
                log $DEBUG "rpmvercmp - ${ch_a} != '~' && return 1 (${version_a} newer than ${version_b})"
                cmp=1
                break
            elif [ "${ch_b}" != "~" ]; then
                log $DEBUG "rpmvercmp - ${ch_b} != '~' && return 2 (${version_b} newer than ${version_a})"
                cmp=2
                break
            fi

            # Else both have tilde so move past this character.
            log $DEBUG "rpmvercmp - Both strings contain tilde, continuing."
            #index_a=`expr $index_a + 1`
            #index_b=`expr $index_b + 1`
            continue
        fi

        # If we ran to the end of either, we are finished with the loop
        if [ ${index_a} -gt ${#version_a} -o ${index_b} -gt ${#version_b} ]; then
            log $DEBUG "rpmvercmp - Ran to the end of a string: ${index_a} > ${#version_a} || ${index_b} > ${#version_b}"
            break
        fi

        # Grab first completely alpha or completely numeric segment and store the type
        # of characters stored in segment in ver_isnum (1 - digit, 2 - alpha).
        seg_a=""
        seg_b=""
        ver_isnum=0
        isdigit "${ch_a}"
        if [ $? -eq 0 ]; then
            log $DEBUG "rpmvercmp - Digit Segment detected."
            index_seqa=$index_a
            index_seqb=$index_b

            while [ ${index_a} -le ${#version_a} ]; do
                sc_one=`echo ${version_a} | cut -c ${index_a}-${index_a}`
                isdigit "${sc_one}"
                if [ $? -eq 1 ]; then
                    # Since character is not digit, back up one.
                    index_a=`expr $index_a - 1`
                    break
                fi
                seg_a="${seg_a}${sc_one}"
                index_a=`expr $index_a + 1`
            done
            log $DEBUG "rpmvercmp - Version A Segment: ${seg_a}"

            while [ ${index_b} -le ${#version_b} ]; do
                sc_two=`echo ${version_b} | cut -c ${index_b}-${index_b}`
                isdigit "${sc_two}"
                if [ $? -eq 1 ]; then
                    # Since character is not digit, back up one.
                    index_b=`expr $index_b - 1`
                    break
                fi
                seg_b="${seg_b}${sc_two}"
                index_b=`expr $index_b + 1`
            done
            log $DEBUG "rpmvercmp - Version B Segment: ${seg_b}"
            ver_isnum=1
        else
            log $DEBUG "rpmvercmp - Alpha Segment detected."
            index_seqa=$index_a
            index_seqb=$index_b

            while [ ${index_a} -le ${#version_a} ]; do
                sc_one=`echo ${version_a} | cut -c ${index_a}-${index_a}`
                isalpha "${sc_one}"
                if [ $? -eq 1 ]; then
                    # Since character is not alpha, back up one.
                    index_a=`expr $index_a - 1`
                    break
                fi
                seg_a="${seg_a}${sc_one}"
                index_a=`expr $index_a + 1`
            done
            log $DEBUG "rpmvercmp - Version A Segment: ${seg_a}"

            while [ ${index_b} -le ${#version_b} ]; do
                sc_two=`echo ${version_b} | cut -c ${index_b}-${index_b}`
                isalpha "${sc_two}"
                if [ $? -eq 1 ]; then
                    # Since character is not alpha, back up one.
                    index_b=`expr $index_b - 1`
                    break
                fi
                seg_b="${seg_b}${sc_two}"
                index_b=`expr $index_b + 1`
            done
            log $DEBUG "rpmvercmp - Version B Segment: ${seg_b}"
            ver_isnum=2
        fi

        # If Segment A is empty, Version B is newer because it has more characters.
        if [ ${#seg_a} -eq 0 ]; then
            log $DEBUG "rpmvercmp - Version A Segment is empty."
            cmp=2
            break
        fi

        # If the Segments are of different types (e.g. digit vs alpha), the determination
        # is based on what type the Version A Segment is (digits = 1, alphas = 2).
        if [ ${#seg_b} -eq 0 ]; then
            log $DEBUG "rpmvercmp - Version segments are of differing types: ${ver_isnum}"
            cmp=${ver_isnum}
            break
        fi

        # If the Version segments are numeric, remove any leading 0's
        if [ ${ver_isnum} -eq 1 ]; then
            index_seqa=0
            index_seqb=0

            # Throw away any leading zeros
            while [ ${index_seqa} -le ${#seg_a} ]; do
                index_seqa=`expr $index_seqa + 1`
                sc_one=`echo ${seg_a} | cut -c ${index_seqa}-${index_seqa}`
                if [ "${sc_one}" = "0" ]; then
                    continue
                else
                    break
                fi
            done
            while [ ${index_seqb} -le ${#seg_b} ]; do
                index_seqb=`expr $index_seqb + 1`
                sc_two=`echo ${seg_b} | cut -c ${index_seqb}-${index_seqb}`
                if [ "${sc_two}" = "0" ]; then
                    continue
                else
                    break
                fi
            done

            if [ ${index_seqa} -le ${#seg_a} ]; then
                seg_a=`echo ${seg_a} | cut -c ${index_seqa}-${#seg_a}`
            else
                seg_a=""
            fi

            if [ ${index_seqb} -le ${#seg_b} ]; then
                seg_b=`echo ${seg_b} | cut -c ${index_seqb}-${#seg_b}`
            else
                seg_b=""
            fi

            log $DEBUG "rpmvercmp - Remove leading 0's Version A Segment: ${seg_a}"
            log $DEBUG "rpmvercmp - Remove leading 0's Version B Segment: ${seg_b}"

            # The longer segment of digits is newer (e.g. 10 > 2, 100 > 10)
            if [ ${#seg_a} -gt ${#seg_b} ]; then
                cmp=1
                break
            fi

            if [ ${#seg_b} -gt ${#seg_a} ]; then
                cmp=2
                break
            fi
        fi

        strcmp "${seg_a}" "${seg_b}"
        rv_strcmp=$?
        log $DEBUG "rpmvercmp - Strings compared: ${seg_a} ? ${seg_b} returned: ${rv_strcmp}"

        if [ ${rv_strcmp} -ne 0 ]; then
            cmp=${rv_strcmp}
            break
        fi
    done

    # If the comparisons above have not determined which version string is newer, continue into
    # the final logic block.
    if [ ${cmp} -eq 0 ]; then
        # If the index values for both version strings are greater than the version string length,
        # the numeric and alpha segments have compared identically but the segment separators are different.
        if [ ${index_a} -gt ${#version_a} -a ${index_b} -gt ${#version_b} ]; then
            log $DEBUG "rpmvercmp - Strings compare identically but the segments have different separators"
            cmp=0
        # Else the version string which still has characters left over is newer than the other string.
        elif [ ${index_a} -le ${#version_a} ]; then
            cmp=1
        else
            cmp=2
        fi
    fi
    return ${cmp}
}

#
# Create the agent_settings.status file which is consumed by the agent to
# determine what Core configuration options are currently set for the client.
#
# Param $1 - Distribution settings Core guid.
# Param $2 - Inventory settings Core guid.
# Param $3 - Client Connectivity settings Core guid.
#
create_agent_settings_file() {
    distribution_guid="${1}"
    inventory_guid="${2}"
    clientconnect_guid="${3}"
    separator=""

    ${ED} -s <<__JSON_CONFIG__
\$a
{
    "agentSettings" : [
.
w ${INSTALL_PREFIX}/etc/agent_settings.status
q
__JSON_CONFIG__

    [ -n "${inventory_guid}" ] && separator=","

    if [ -n "${distribution_guid}" ]; then
     ${ED} -s ${INSTALL_PREFIX}/etc/agent_settings.status <<__JSON_CONFIG__
\$a
            {
                "type" : "AgentBehavior",
                "guid" : "${distribution_guid}",
                "status" : "not downloaded"
            }${separator}
.
w
q
__JSON_CONFIG__
    fi

    if [ -n "${inventory_guid}" ]; then
        ${ED} -s ${INSTALL_PREFIX}/etc/agent_settings.status <<__JSON_CONFIG__
\$a
            {
                "type" : "Inventory",
                "guid" : "${inventory_guid}",
                "status" : "not downloaded"
            }
.
w
q
__JSON_CONFIG__
    fi

    if [ -n "${clientconnect_guid}" ]; then
        ${ED} -s ${INSTALL_PREFIX}/etc/agent_settings.status >/dev/null <<__JSON_CONFIG__
-
\$a
${separator}
            {
                "type" : "ClientConnectivity",
                "guid" : "${clientconnect_guid}",
                "status" : "not downloaded"
            }
.
w
q
__JSON_CONFIG__
    fi

    ${ED} -s ${INSTALL_PREFIX}/etc/agent_settings.status <<__JSON_CONFIG__
\$a
        ]
    }
.
w
q
__JSON_CONFIG__

    ${CHMOD} 640 "${INSTALL_PREFIX}/etc/agent_settings.status"
}

#
# Create the broker.conf.xml file which is consumed by proxy to
# determine what Core configuration options are currently set for the client.
#
# Param $1 - CSA hostname
# Param $2 - CSA IP address
create_broker_conf_file() {
    csa_hostname="${1}"
    csa_ip="${2}"

	${ED} -s <<__BROKER_CONFIG__
\$a
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<broker>
<proxyCredentials></proxyCredentials>
<proxy/>
<csa_lastfailedtimestamp/>
<csa_lastfailed/>
<host>${csa_hostname}</host>
<ipaddress>${csa_ip}</ipaddress>
<csa_usagepolicy>1</csa_usagepolicy>
<order>1</order>
<enabled>true</enabled>
</broker>
.
w ${INSTALL_PREFIX}/var/cbaroot/broker/broker.conf.xml
q
__BROKER_CONFIG__

${CHMOD} 664 "${INSTALL_PREFIX}/var/cbaroot/broker/broker.conf.xml"
${CHOWN} -R landesk:landesk "${INSTALL_PREFIX}/var/cbaroot/broker/broker.conf.xml"

}


#
# Verify package signatures and digests
#
# Assumes the necessary key(s) have already been imported.
#
# Param $1 - Key management tool to verify signatures and digests
# Param $2 - package file to check
#
# Return 0 - Required signatures and digests are present and valid
#        1 - One or more signatures and/or digests aren't present or are invalid
#
verify_pkg() {
   key_mgmt="$1"
   pkg_file="$2"
   VP_RV=0
   VP_HDR="Header V4 DSA\(/SHA1\|\) \(S\|s\)ignature"
   VP_KEYOK="\(OK, \|\)key ID 5c344736\(\|: OK\)"
   VP="V4 DSA\(/SHA1\|\) \(S\|s\)ignature"
   VP_MD5="MD5 digest: OK"
   VP_SHA1="Header SHA1 digest: OK"
   VP_H256="Header SHA256 digest: "
   VP_P256="Payload SHA256 digest: "

   log $DEBUG "verify_pkg - Check for signatures and digests: ${key_mgmt} -Kv \"${pkg_file}\""

   VP_RPM_KV=`${key_mgmt} -Kv "${pkg_file}"`
   log $DEBUG "${VP_RPM_KV}"

   # Is the package header signed by the Ivanti RPM public key?
   echo "${VP_RPM_KV}" | grep "${VP_HDR}" | grep "${VP_KEYOK}" >/dev/null 2>&1
   if [ $? -ne 0 ]; then
       log $ERROR "Package '${pkg_file}' failed the Header Ivanti RPM public key verification"
       VP_RV=1
   fi

   # Is the package signed by the Ivanti RPM public key?
   echo "${VP_RPM_KV}" | grep "${VP}" | grep "${VP_KEYOK}" >/dev/null 2>&1
   if [ $? -ne 0 ]; then
       log $ERROR "Package '${pkg_file}' failed the Ivanti RPM public key verification"
       VP_RV=1
   fi

   # Is the MD5 digest OK?
   echo "${VP_RPM_KV}" | grep "${VP_MD5}" >/dev/null 2>&1
   if [ $? -ne 0 ]; then
       log $ERROR "Package '${pkg_file}' failed the MD5 digest check"
       VP_RV=1
   fi

   # Is the Header SHA1 digest OK?
   echo "${VP_RPM_KV}" | grep "${VP_SHA1}" >/dev/null 2>&1
   if [ $? -ne 0 ]; then
       log $ERROR "Package '${pkg_file}' failed the Header SHA1 digest check"
       VP_RV=1
   fi

   # Is the Header SHA256 digest OK, if present?
   echo "${VP_RPM_KV}" | grep "${VP_H256}" >/dev/null 2>&1
   if [ $? -eq 0 ]; then
       echo "${VP_RPM_KV}" | grep "${VP_H256}OK" >/dev/null 2>&1
       if [ $? -ne 0 ]; then
           log $ERROR "Package '${pkg_file}' failed the Header SHA256 digest check"
           VP_RV=1
       fi
   fi

   # Is the Payload SHA256 digest OK, if present?
   echo "${VP_RPM_KV}" | grep "${VP_P256}" >/dev/null 2>&1
   if [ $? -eq 0 ]; then
       echo "${VP_RPM_KV}" | grep "${VP_P256}OK" >/dev/null 2>&1
       if [ $? -ne 0 ]; then
           log $ERROR "Package '${pkg_file}' failed the Payload SHA256 digest check"
           VP_RV=1
       fi
   fi

   if [ ${VP_RV} -eq 0 ]; then
       log $DEBUG "verify_pkg - Verified '${pkg_file}'"
   fi
   return ${VP_RV}
}


###################################
#    Discovery Functions          #
###################################
#
# Check privilege escalation for a given command.
#
# Param $1 - OS Type normalized
# Out $2   - Global variable to hold command text
# Param $3 - Command to test for privilege escalation
# Param $4 - (Optional) PATH to use instead of global SEARCH_PATH
#
check_priv_escalation() {
    os_type="${1}"

    # Clear out anything coming in and it will get reset below if successful
    eval $2=""
    tool=""

    # Find the complete path for the requested tool
    if [ -n "${3}" ]; then
        base_tool=`basename ${3}`
        find_tool tool "${base_tool}" "${4}"
        if [ $? -ne 0 -a "${USER}" = "root" ]; then
            log $WARN "Could not determine complete path for required tool: ${3}"
            return
        fi
    fi

    # Check for escalation if the current user is not root
    if [ "${USER}" != "root" ]; then
        if [ ${DISABLE_PRIV_ESCALATION_CHECK} -eq 1 ]; then
            log $DEBUG "Escalation checks disabled"
            if [ -z "${tool}" ]; then
                log $WARN "Could not determine path for required tool with escalation checks disabled: ${3}"
                return
            fi

            if [ "${os_type}" = "sunos" ]; then
                eval $2="${tool}"
                log $DEBUG "Solaris without escalation check uses cmd: ${tool}"
            else
                [ -z "${SUDO}" ] && return
                eval $2='"${SUDO} -E "${tool}""'
                log $DEBUG "Linux without escalation check uses cmd: ${SUDO} -E ${tool}"
            fi
        elif [ "${os_type}" = "sunos" ]; then
            log $DEBUG "Running Solaris command escalation check: ${tool} (${base_tool})"
            if [ "${tool}" = "/*" ]; then
                profiles -l | grep "${tool} " >/dev/null 2>&1
            else
                profiles -l | grep "/${tool} " >/dev/null 2>&1
            fi

            if [ $? -ne 0 ]; then
                # Get out of here if SUDO is not defined - error reported later
                [ -z "${SUDO}" ] && return

                cmd=`${SUDO} -nl "${tool}" 2>/dev/null`
                if [ -n "${cmd}" ]; then
                    log $DEBUG "Escalation granted via sudo based on path: ${tool}"
                    eval $2='"${SUDO} -E "${cmd}""'
                else
                    cmd=`${SUDO} -nl "${base_tool}" 2>/dev/null`
                    if [ -n "${cmd}" ]; then
                        log $DEBUG "Escalation granted via sudo based on command: ${base_tool}"
                        eval $2='"${SUDO} -E "${cmd}""'
                    fi
                fi
            else
                log $DEBUG "Escalation granted via RBAC: ${tool}"
                eval $2="${tool}"
            fi
        else
            # Get out of here if SUDO is not defined - error reported later
            [ -z "${SUDO}" ] && return

            log $DEBUG "Running non-Solaris command escalation check: ${tool} (${base_tool})"
            cmd=`${SUDO} -nl "${tool}" 2>/dev/null`
            if [ -n "${cmd}" ]; then
                log $DEBUG "Escalation granted via sudo based on path: ${tool}"
                eval $2='"${SUDO} -E "${cmd}""'
            else
                cmd=`${SUDO} -nl "${base_tool}" 2>/dev/null`
                if [ -n "${cmd}" ]; then
                    log $DEBUG "Escalation granted via sudo based on command: ${base_tool}"
                    eval $2='"${SUDO} -E "${cmd}""'
                fi
            fi
        fi
    else
        eval $2="${tool}"
    fi
}


#
# Determine the vendor, os type and os release information based on information
# available through standard methods.
#
# Out $1 - OS Type normalized: aix, hp-ux, linux, sunos
# Out $2 - OS Vendor normalized: centos, hewlett-packard, ibm, oracle, redhat, sles, debian (ubuntu, raspbian, etc..)
# Out $3 - OS Release
# Out $4 - Architecture
#
find_os_info()
{
    os_vendor=
    # OS Type: AIX, HP-UX, Linux, SunOS
    os_type=`uname -s | tr '[A-Z]' '[a-z]'`
    eval ${1}="${os_type}"

    # Determine vendor and release by OS type.
    if [ "${os_type}" = "aix" ]; then
        eval ${2}="ibm"
        eval ${3}="`uname -v`"
        eval ${4}="ppc"
    elif [ "${os_type}" = "hp-ux" ]; then
        eval ${1}="hpux"
        eval ${2}="hewlett-packard"
        eval ${3}="`uname -r | cut -d . -f 2,3`"
        eval ${4}="`uname -m | sed 's/.*[78]00/pa-risc/'`"
    elif [ "${os_type}" = "linux" ]; then
        if [ -f /etc/os-release ]; then
            eval ${3}='`grep VERSION_ID /etc/os-release | tr -d \" | cut -d = -f 2 | cut -d . -f 1`'
            os_vendor=`grep ^ID= /etc/os-release | tr -d \" | cut -d = -f 2`
            eval ${2}=${os_vendor}
        elif [ -f /etc/centos-release ]; then
            eval ${2}="centos"
            eval ${3}="`grep 'release' /etc/centos-release | sed -e 's/.*release[[:space:]]*\([[:digit:]]*\).*/\1/'`"
        elif [ -f /etc/redhat-release ]; then
            # RedHat and CentOS version 5 cannot be differentiated by release file, so verify contents.
            # This also requires a breadcrumb in the install_agent_packages method.
            grep -i centos /etc/redhat-release > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                eval ${2}="centos"
            else
                eval ${2}="redhat"
            fi
            eval ${3}="`grep 'release' /etc/redhat-release | sed -e 's/.*release[[:space:]]*\([[:digit:]]*\).*/\1/'`"
        elif [ -f /etc/SuSE-release ]; then
            eval ${2}="sles"
            eval ${3}="`grep 'Server' /etc/SuSE-release | sed -e 's/.*Server[[:space:]]*\([[:digit:]]*\).*/\1/'`"
        else
            eval ${2}="unkown"
        fi
        os_arch="`uname -p | sed 's/i.\?86/i386/'`"

        if [ "${os_arch}" = "unknown" ]; then
            os_arch="`uname -m | sed 's/i.\?86/i386/'`"
        fi


        eval ${4}="${os_arch}"

        # normalize 'IDs' to vendor(s)
        if [ "${os_vendor}" = "rhel" ]; then
            eval ${2}="redhat"
        fi

        # UBUNTU and RASPBIAN OS archiecture are fixed based on vendor
        if [ "${os_vendor}" = "debian" ]; then
            DEBIAN_SUB_VENDOR="debian"
        fi
        if [ "${os_vendor}" = "ubuntu" ]; then
            eval ${2}="debian"
            DEBIAN_SUB_VENDOR="ubuntu"
            if [ "${os_arch}" = "x86_64" ]; then
                os_arch="amd64"
            fi
        fi

        if [ "${os_vendor}" = "raspbian" ]; then
            eval ${2}="debian"
            DEBIAN_SUB_VENDOR="raspbian"
            os_arch="armhf"
        fi

        eval ${4}="${os_arch}"

    elif [ "${os_type}" = "sunos" ]; then
        eval ${2}="oracle"
        eval ${3}="`uname -r | cut -d . -f 2,3`"
        if [ `uname -p` = "i386" ]; then
            eval ${4}="x86_64"
        else
            eval ${4}="`uname -p`"
        fi
    else
        eval ${1}="unkown"
        return 1
    fi
    return 0
}

#
# Search the existing $PATH environment for a given tool and set the given
# variable to point to the path if found.
#
# Out $1 - Variable to store tool path
# Param $2 - Tool name
# Param $3 - Optional search path
#
find_tool() {
    search_path="${3:-$SEARCH_PATH}"
    log $DEBUG "Searching for: ${2}"
    for dir in `echo "${PATH}:${search_path}" | tr ':' ' '`; do
        log $DEBUG "Searching: $dir"
        if [ ${DISABLE_PRIV_ESCALATION_CHECK} -eq 0 -a -x "${dir}/${2}" ] || [ -f "${dir}/${2}" ]; then
            eval ${1}="${dir}/${2}"
            log $DEBUG "Found: ${dir}/${2}"
            return 0
        fi
    done
    return 1
}

#
# Determines which package management tool to use for querying, removing
# and installing packages.
#
# Param $1 - OS Type normalized to lowercase
# Out $2 - Package management tool for query
# Out $3 - Package management tool for install
# Out $4 - Package management tool for removal
# Out $5 - Package management tool for adding/enabling custom repository (Linux)
# Out $6 - Key management tool for importing keys
# Out $7 - Package management tool for alternate installing
#
find_package_mgmt_tool() {
    os_type="$1"

    log $INFO "Determining package management tool."
    if [ "${os_type}" = "aix" ]; then
        find_tool pkg_mgmt rpm
        if [ $? -eq 0 ]; then
            eval ${2}="${pkg_mgmt}"
            eval ${3}="${pkg_mgmt}"
            eval ${4}="${pkg_mgmt}"
        fi
    elif [ "${os_type}" = "hpux" ]; then
        find_tool pkg_mgmt swlist
        if [ $? -eq 0 ]; then
            eval ${2}="${pkg_mgmt}"
        fi
        find_tool pkg_mgmt swinstall
        if [ $? -eq 0 ]; then
            eval ${3}="${pkg_mgmt}"
        fi
        find_tool pkg_mgmt swremove
        if [ $? -eq 0 ]; then
            eval ${4}="${pkg_mgmt}"
        fi
    elif [ "${os_type}" = "linux" ]; then
        find_tool pkg_mgmt rpm
        if [ $? -eq 0 ]; then
            eval ${2}="${pkg_mgmt}"
            eval ${4}="${pkg_mgmt}"
            # For linux platforms we use RPM to do key imports
            eval ${6}="${pkg_mgmt}"
            if [ ${DARK_INST} -eq 1 ]; then
                eval ${3}="${pkg_mgmt}"
            fi
        fi
        find_tool repo_mgmt yum-config-manager
        [ $? -eq 0 ] && eval ${5}="${repo_mgmt}"
        find_tool pkg_mgmt yum
        if [ $? -eq 0 -a ${DARK_INST} -eq 0 ]; then
            eval ${3}="${pkg_mgmt}"
        fi
        find_tool pkg_mgmt zypper
        if [ $? -eq 0 -a ${DARK_INST} -eq 0 ]; then
            eval ${3}="${pkg_mgmt}"
            eval ${5}="${pkg_mgmt}"
        fi
        find_tool pkg_mgmt dpkg
        if [ $? -eq 0 ]; then
            eval ${3}="${pkg_mgmt}"
            eval ${4}="${pkg_mgmt}"
            eval ${7}="${pkg_mgmt}"
        fi
        find_tool pkg_mgmt dpkg-query
        if [ $? -eq 0 ]; then
            eval ${2}="${pkg_mgmt}"
        fi
        find_tool pkg_mgmt apt-get
        if [ $? -eq 0 -a ${DARK_INST} -eq 0 ]; then
            eval ${3}="${pkg_mgmt}"
        fi

    elif [ "${os_type}" = "sunos" ]; then
        find_tool pkg_mgmt pkginfo
        if [ $? -eq 0 ]; then
            eval ${2}="${pkg_mgmt}"
        fi
        find_tool pkg_mgmt pkgadd
        if [ $? -eq 0 ]; then
            eval ${3}="${pkg_mgmt}"
        fi
        find_tool pkg_mgmt pkgrm
        if [ $? -eq 0 ]; then
            eval ${4}="${pkg_mgmt}"
        fi
    else
        return 1
    fi

    return 0
}

#
# Searches the known package list for all previous installations and generates a list
# of currently installed packages.  These packages will be removed if the script is run
# with installation packages of the same name or if the installation removal option is
# specified.
#
# Param $1 - OS Type
# Param $2 - Query Package command
# Out $3 - List of previously installed agent packages which need to be removed.
#
find_previously_installed_agent() {
    os_type="$1"
    pkg_info="$2"
    agent_pkgs="$3"
    pkgs="vulscan sdclient ldsmmonitor megalib mgmtutils ldipmi ldsmbios smbase alertsync ldiscan lddeppkg pds2 pds2g6 cba8 ivanti-base-agent ivanti-cba8 ivanti-pds2 ivanti-inventory ivanti-software-distribution ivanti-schedule ivanti-vulnerability"

    installed_pkgs=""

    for pkg in $pkgs; do
        query_pkg_${os_type} ${pkg_info} ${pkg}

        if [ $? -eq 0 ]; then
            [ -n "${installed_pkgs}" ] && installed_pkgs="${installed_pkgs} ${pkg}"
            [ -z "${installed_pkgs}" ] && installed_pkgs="${pkg}"
        fi
    done

    # Set the out parameter to the gathered list of packages.
    eval ${agent_pkgs}='"${installed_pkgs}"'
}

#
# Determine if prerequisite list is satisfied on AIX.
#
# Param $1 - Package management query tool: rpm
#
analyze_prerequisites_aix() {
    pkg_info="$1"
    prerequisites="bash libgcc libxml2 libstdc++ openssl zlib"
    MISSING=""

    log $INFO "Verifying prerequisite installations: ${prerequisites}"
    for pkg in $prerequisites; do
        log $DEBUG "Testing for ${pkg}"
        query_pkg_aix ${pkg_info} ${pkg}
        if [ $? -ne 0 ]; then
            log $DEBUG "Missing ${pkg}"
            [ -n "${MISSING}" ] && MISSING="${MISSING} ${pkg}"
            [ -z "${MISSING}" ] && MISSING="${pkg}"
        fi
    done
}

#
# Determine if prerequisite list is satisfied on HP-UX.
#
# Param $1 - Package management query tool: swlist
#
analyze_prerequisites_hpux() {
     pkginfo="$1"
     prerequisites="bash ixLibxml2 ixCurl ixZlib libgcc openssl"
     MISSING=""

     log $INFO "Verifying prerequisite installations: ${prerequisites}"
     for pkg in $prerequisites; do
        log $DEBUG "Testing for ${pkg}"
        query_pkg_hpux ${pkg_info} ${pkg}
        if [ $? -ne 0 ]; then
            log $DEBUG "Missing ${pkg}"
            [ -n "${MISSING}" ] && MISSING="${MISSING} ${pkg}"
            [ -z "${MISSING}" ] && MISSING="${pkg}"
        fi
    done
}

#
# Determine if prerequisite list is satisfied on Linux. Currently supported
# vendors have different package names between vendor and sometimes between releases.
#
# Param $1 - Package management query tool: rpm
# Param $2 - OS Vendor normalized to lowercase
# Param $3 - OS Release
#
analyze_prerequisites_linux() {
    pkg_info="$1"
    os_vendor=$2
    os_release=$3
    prerequisites_redhat_5="glibc:2.5 pam:0.99 xinetd libgcc:4.1 libstdc++:4.1 libxml2:2.6 zlib:1.2 curl:7.15"
    prerequisites_redhat_6="glibc:2.12 pam:1.1 xinetd libgcc:4.4 libxml2:2.7 zlib:1.2 openssl:1.0.1 libtool-ltdl"
    prerequisites_redhat_7="glibc:2.17 pam:1.1 libgcc:4.8 libxml2:2.9 zlib:1.2 openssl:1.0.1 libtool-ltdl"
    prerequisites_redhat_8="glibc:2.28 pam:1.3 libgcc libxml2:2.9 zlib:1.2 openssl:1.1.1 libtool-ltdl tar"

    prerequisites_sles_11="glibc:2.11 pam xinetd libgcc46 libxml2 zlib util-linux libtool"
    prerequisites_sles_12="glibc:2.19 pam libgcc_s1 libxml2-2 libz1 openssl:1.0.1 util-linux libtool"
    prerequisites_sles_15="glibc:2.26 pam libgcc_s1 libxml2-2 libz1 openssl:1.1 util-linux libtool"

    prerequisites_centos_5="${prerequisites_redhat_5}"
    prerequisites_centos_6="${prerequisites_redhat_6}"
    prerequisites_centos_7="${prerequisites_redhat_7}"
    prerequisites_centos_8="${prerequisites_redhat_8}"

    prerequisites_raspbian_7="libpam-runtime openssl:1.0.1 xinetd libxml2:2.6 zlib1g:1.1.2 libltdl7"
    prerequisites_raspbian_8="libpam-runtime openssl:1.0.1 libxml2:2.6 zlib1g:1.1.2 libltdl7"
    prerequisites_raspbian_9="libpam-runtime openssl:1.0.1 libxml2:2.6 zlib1g:1.1.2 libltdl7"
    prerequisites_raspbian_10="libpam-runtime openssl:1.1 libxml2:2.6 zlib1g:1.1.2 libltdl7 uuid-runtime"

    prerequisites_ubuntu_14="libpam-runtime openssl:1.0.1 xinetd libxml2:2.6 zlib1g:1.1.2 libltdl7"
    prerequisites_ubuntu_16="libpam-runtime openssl:1.0.1 libxml2:2.6 zlib1g:1.1.2 libltdl7"
    prerequisites_ubuntu_18="libpam-runtime openssl:1.1 libxml2:2.6 zlib1g:1.1.2 libltdl7"
    prerequisites_ubuntu_20="libpam-runtime openssl:1.1 libxml2:2.6 zlib1g:1.1.2 libltdl7"

    MISSING=""

    eval prerequisites="\${prerequisites_${os_vendor}_${os_release}}"
    if [ "${os_vendor}" = "debian" ]; then
       eval prerequisites="\${prerequisites_${DEBIAN_SUB_VENDOR}_${os_release}}"
    fi

    log_prerequisites=`echo ${prerequisites} | tr ':' '-'`
    log $INFO "Verifying prerequisite installations: ${log_prerequisites}"
    for pkg in ${prerequisites}; do
        pkg_version=""
        log $DEBUG "Testing for ${pkg}"

        # If the package has a version specifier, pull out the pkg_version for testing.
        contains "${pkg}" ":"
        [ $? -eq 0 ] && pkg_version=`echo $pkg | cut -d ':' -f 2`
        pkg=`echo $pkg | cut -d ':' -f 1`

        # Test the package and any version specified for existence.
        query_pkg_linux "${pkg_info}" "${pkg}" "${pkg_version}"
        if [ $? -ne 0 ]; then
            [ -n "${pkg_version}" ] && log $DEBUG "Missing ${pkg}-${pkg_version}"
            [ -z "${pkg_version}" ] && log $DEBUG "Missing ${pkg}"
            [ -n "${MISSING}" ] && MISSING="${MISSING} ${pkg}:${pkg_version}"
            [ -z "${MISSING}" ] && MISSING="${pkg}:${pkg_version}"
        fi
    done
}

#
# Determine if prerequisite list is satisfied on Solaris.
#
# Param $1 - Package management query tool: pkginfo
# Param $2 - Not Used
# Param $3 - OS Release
#
analyze_prerequisites_sunos() {
    pkg_info="$1"
    prerequisites="CSWlibssl1-0-0 CSWlibgcc-s1 CSWlibcurl4 CSWlibstdc++6"
    MISSING=""

    log $INFO "Verifying prerequisite installations: ${prerequisites}"
    for pkg in $prerequisites; do
        log $DEBUG "Testing for ${pkg}"
        query_pkg_sunos ${pkg_info} ${pkg}
        if [ $? -ne 0 ]; then
            log $DEBUG "Missing ${pkg}"
            [ -n "${MISSING}" ] && MISSING="${MISSING} ${pkg}"
            [ -z "${MISSING}" ] && MISSING="${pkg}"
        fi
    done
}

#
# Determine if prerequisite list is satisfied on current system.
#
# Param $1 - OS Type normalized to lowercase
# Param $2 - OS Vendor normalized to lowercase
# Param $3 - OS Release
# Param $4 - Package management query tool: pkginfo, rpm, swlist
#
analyze_prerequisites() {
    os_type="$1"
    os_vendor="$2"
    os_release="$3"
    pkg_info="$4"

    # Create prerequisite list which changes between os, vendor and release.
    analyze_prerequisites_${os_type} ${pkg_info} ${os_vendor} ${os_release}

    # MISSING is generated in the specific OS type
    if [ -n "$MISSING" ]; then
        log_MISSING=`echo ${MISSING} | tr ':' '-'`
        log $WARN "Missing packages: ${log_MISSING}"
        return 1
    fi
    return 0
}

####################################
#     Package Management Functions #
####################################
#
# Determine if a package is installed on an AIX system using the provided package management
# tool and package name.
#
# Param $1 - Package management tool (assumes RPM)
# Param $2 - Package name
#
query_pkg_aix() {
    pkg_info="$1"
    package="$2"
    $pkg_info -q $package >/dev/null 2>&1
}

#
# Remove a package from an AIX system using the provided package management tool and package name.
#
# Param $1 - Package management tool (assumes RPM)
# Param $2 - Package name
#
remove_pkg_aix() {
    pkg_rm="$1"
    package="$2"

    log $INFO "Removing package: ${package}"
    if [ -n "$REDIRECT_OUTPUT" ]; then
        $pkg_rm -e $package >> $REDIRECT_OUTPUT 2>&1
    else
        $pkg_rm -e $package
    fi

    if [ $? -ne 0 ]; then
        log $WARN "Package removal failed, forcably removing package: ${package}"
        if [ -n "$REDIRECT_OUTPUT" ]; then
            $pkg_rm -e --nopostun $package >> $REDIRECT_OUTPUT 2>&1
        else
            $pkg_rm -e --nopostun $package
        fi
    fi
}

#
# Install a package for an AIX system using the provided package management tool and package name.
#
# Param $1 - Package management tool (assumes RPM)
# Param $2 - Package name
#
install_pkg_aix() {
    pkg_add="$1"
    package="$2"

    log $INFO "Installing package: ${package}"
    if [ -n "$REDIRECT_OUTPUT" ]; then
        $pkg_add -i $package >> $REDIRECT_OUTPUT 2>&1
    else
        $pkg_add -i $package
    fi
}

# HP-UX variants (assumes sw<list, remove, install>): query, remove, install
query_pkg_hpux() {
    pkg_info="$1"
    package="$2"
    $pkg_info -x one_liner="name" | grep $package >/dev/null 2>&1
}

remove_pkg_hpux() {
    pkg_rm="$1"
    package="$2"

    log $INFO "Removing package: ${package}"
    if [ -n "$REDIRECT_OUTPUT" ]; then
        $pkg_rm $package >> $REDIRECT_OUTPUT 2>&1
    else
        $pkg_rm $package
    fi

    if [ $? -ne 0 ]; then
        log $WARN "Package removal failed, forcably removing package: ${package}"
        if [ -n "$REDIRECT_OUTPUT" ]; then
            $pkg_rm -x run_scripts=false $package >> $REDIRECT_OUTPUT 2>&1
        else
            $pkg_rm -x run_scripts=false $package
        fi
    fi
}

install_pkg_hpux() {
    pkg_add="$1"
    package="$2"

    log $INFO "Installing package: ${package}"
    if [ -n "$REDIRECT_OUTPUT" ]; then
        ${pkg_add} -x mount_all_filesystems=false -s "${package}" \* >> $REDIRECT_OUTPUT 2>&1
    else
        ${pkg_add} -x mount_all_filesystems=false -s "${package}" \*
    fi
}

# Linux variants (assumes RPM): query, remove, install (yum or zypper)
#
# Add a custom repository and enable it for pulling packages (Linux only).
#
# Param $1 - OS Type normalized
# Param $2 - OS Vendory normalized
# Param $3 - Release version
# Param $4 - Repository add/enable commnad (yum or zypper)
# Param $5 - List of repository URLs to add.
#
add_custom_repository() {
    os_type="$1"
    os_vendor="$2"
    os_release="$3"
    repo_add="$4"
    repositories="$5"
    rv=0

    for repo in ${repositories}; do
        if [ "${os_vendor}" = "redhat" -o "${os_vendor}" = "centos" ]; then
            if [ -n "$REDIRECT_OUTPUT" ]; then
                ${repo_add} --add-repo ${repo} 2>&1| grep "HTTP Error 404" >> $REDIRECT_OUTPUT 2>&1
            else
                ${repo_add} --add-repo ${repo} 2>&1| grep "HTTP Error 404"
            fi
            [ $? -ne 0 ] && ${repo_add} --enable ${repo}
        elif [ "${os_vendor}" = "sles" ]; then
            if [ -n "$REDIRECT_OUTPUT" ]; then
                ${repo_add} ar -f ${repo} >> $REDIRECT_OUTPUT 2>&1
            else
                ${repo_add} ar -f ${repo}
            fi
        fi

        if [ $? -ne 0 ]; then
            log $ERROR "Failed to add custom repository: ${repo}"
            rv=1
        fi
    done
    return $rv
}

query_pkg_linux() {
    pkg_info="$1"
    package="$2"
    package_release="$3"

    if [ ${OS_VENDOR} = "debian" ]; then
        query_release=`$pkg_info -f="\\${VERSION}" --show ${package} 2>/dev/null | cut -d '-' -f 1`
        if [ ! -z "${query_release}" ]; then
            if [ -n "${package_release}" ]; then
                dpkg --compare-versions ${package_release} lt ${query_release}
                if [ $? -eq 0 ]; then
                    return 0
                else
                    return 1
                fi
            fi
            return 0
        fi
    else
        query_release=`$pkg_info --qf '%{VERSION}' -q $package 2>/dev/null`
        if [ $? -eq 0 ]; then
            if [ -n "${package_release}" ]; then
                rpmvercmp "${package_release}" "${query_release}"
                if [ $? -ne 1 ]; then
                    return 0
                else
                    return 1
                fi
            fi
            return 0
        fi
    fi
    return 1
}

remove_pkg_linux() {
    pkg_rm="$1"
    package="$2"

    log $INFO "Removing package: ${package}"
    if [ "${OS_VENDOR}" = "debian" ]; then

        if [ -n "$REDIRECT_OUTPUT" ]; then
            $pkg_rm -r $package >> $REDIRECT_OUTPUT 2>&1
        else
            $pkg_rm -r $package
        fi

    else
        if [ -n "$REDIRECT_OUTPUT" ]; then
            $pkg_rm -e $package >> $REDIRECT_OUTPUT 2>&1
        else
            $pkg_rm -e $package
        fi

        if [ $? -ne 0 ]; then
            log $WARN "Package removal failed, forcably removing package: ${package}"
            if [ -n "$REDIRECT_OUTPUT" ]; then
                $pkg_rm -e --nopostun $package >> $REDIRECT_OUTPUT 2>&1
            else
                $pkg_rm -e --nopostun $package
            fi
        fi
    fi
}

install_pkg_linux() {
    pkg_add="$1"
    package="$2"
    options=""

    log $INFO "Installing package: ${package}"

    contains "${pkg_add}" "dpkg"
    if [ $? -eq 0 ]; then
        options="-i"
    fi

    contains "${pkg_add}" "apt-get"
    if [ $? -eq 0 ]; then
        options="--quiet install -y"
    fi

    contains "${pkg_add}" "yum"
    if [ $? -eq 0 ]; then
        options="--quiet install -y"
    fi

    contains "${pkg_add}" "zypper"
    if [ $? -eq 0 ]; then
        options="--quiet install -y"
    fi

    contains "${pkg_add}" "rpm"
    if [ $? -eq 0 ]; then
        options="-i"
    fi

    localfile=`ls -l ${package} 2>/dev/null`
    if [ -z "${localfile}" -a ${DARK_INST} -eq 1 ]; then
        log $ERROR "Non-network installs require local packages"
    elif [ -n "${localfile}" -a -n "${PKG_ADD_ALT}" ]; then
         if [ -n "$REDIRECT_OUTPUT" ]; then
            ${PKG_ADD_ALT} -i "${package}" >> $REDIRECT_OUTPUT 2>&1
        else
            ${PKG_ADD_ALT} -i "${package}" > /dev/null
        fi
    else
        if [ -n "$REDIRECT_OUTPUT" ]; then
            ${pkg_add} ${options} "${package}" >> $REDIRECT_OUTPUT 2>&1
        else
            ${pkg_add} ${options} "${package}" > /dev/null
        fi
    fi
}

# Solaris variants (assumes SVR4): query, remove, install
query_pkg_sunos() {
    pkg_info=$1
    package=$2
    $pkg_info -q $package
}

remove_pkg_sunos() {
    pkg_rm="$1"
    package="$2"

    log $INFO "Removing package: ${package}"
    if [ -n "$REDIRECT_OUTPUT" ]; then
        yes | $pkg_rm $package >> $REDIRECT_OUTPUT 2>&1
    else
        yes | $pkg_rm $package
    fi
}

# SunOS has an additional parameter (dep_package) because all does not work during
# prerequisite installation.  If dep_package is not specified, it defaults to all.
install_pkg_sunos() {
    pkg_add="$1"
    package="$2"
    dep_package="$3"

    log $INFO "Installing package: ${package} ${dep_package}"
    [ `zonename` = "global" ] && global_option="-G"
    if [ -n "$REDIRECT_OUTPUT" ]; then
        yes | $pkg_add $global_option -d $package ${dep_package:-all} >> $REDIRECT_OUTPUT 2>&1
    else
        yes | $pkg_add $global_option -d $package ${dep_package:-all}
    fi
}

###################################
#    Installation Functions       #
###################################
#
# Install SunOS missing OpenCSW packages.  These are bundled into stand alone packages which are on the
# Core. They must be installed in a given order which is what this function does.
#
# Param $1 - Package management installation command
# Param $2 - Package management query command
# Param $3 - OpenCSW pacakge name
# Param $4 - Filename of the OpenCSW pacakge which will contain the dependent packages
#
install_missing_prerequisites_sunos() {
    pkg_add="$1"
    pkg_info="$2"
    package="$3"
    filename="$4"
    sunos_rv=0

    [ "${package}" = "CSWlibssl1-0-0" ] && pkg_list="CSWcommon CSWlibssl1-0-0"
    [ "${package}" = "CSWlibgcc-s1" ]   && pkg_list="CSWcommon CSWlibgcc-s1"
    [ "${package}" = "CSWlibstdcpp6" ]  && pkg_list="CSWcommon CSWlibgcc-s1 CSWlibstdc++6"
    [ "${package}" = "CSWlibcurl4" ]    && pkg_list="CSWcommon CSWlibiconv2 CSWlibcharset1 CSWlibicudata54 CSWggettext-data \
                                                     CSWiconv CSWcas-preserveconf CSWcas-migrateconf CSWlibicuuc54 CSWlibintl8 \
                                                     CSWcacertificates CSWlibpsl0 CSWlibidn11 CSWlibz1 CSWlibssl1-0-0 CSWlibcurl4"

    for dep_pkg in ${pkg_list}; do
        log $INFO "Attempting installation of dependent package: ${dep_pkg}"
        install_pkg_sunos "${pkg_add}" "${filename}" "${dep_pkg}"

        log $INFO "Verifying dependent package installed: ${pkg}"
        query_pkg_sunos "${pkg_info}" ${dep_pkg}
        if [ $? -eq 0 ]; then
            log $INFO "Successfully installed dependent package: ${dep_pkg}"
        else
            log $ERROR "${package} not installed properly. Failed to install ${dep_pkg}"
            sunos_rv=1
        fi
    done
    return $sunos_rv
}

#
# Attempt to install any missing prerequisites discovered during platform analysis.  If
# this is a Linux distribution, assume the package manager can handle fetching from the
# net.  If this isn't a Linux distribution, attempt to pull the prerequisite from the Core.
# The Core URL would be http://{CORE_ADDR}/ldlogon/unix/{os_type}/<pkg>*<os_type>*<architecture>*.
#
# Param $1 - OS Type normalized
# Param $2 - Package management installation command
# Param $3 - Package management query command
# Param $4 - List of missing dependencies
#
install_missing_prerequisites() {
    os_type="$1"
    pkg_add="$2"
    pkg_info="$3"
    missing="$4"
    rv=0

    for pkg in ${missing}; do
        pkg_version=""

        # If the package has a version specifier, pull out the pkg_version for testing.
        contains "${pkg}" ":"
        [ $? -eq 0 ] && pkg_version=`echo $pkg | cut -d ':' -f 2`
        pkg=`echo $pkg | cut -d ':' -f 1`

        if [ "${os_type}" != "linux" ]; then
            if [ "${os_type}" = "sunos" ]; then
                os_path="solaris"
                [ "${pkg}" = "CSWlibstdc++6" ] && pkg="CSWlibstdcpp6"
            else
                os_path="${os_type}"
            fi
            filename="${pkg}*${os_path}*${ARCHITECTURE}*"

            fetch_file "http://${CORE_ADDR}/ldlogon/unix/${os_path}" "${filename}"
            if [ $? -ne 0 ]; then
                log $ERROR "Failed to download missing prerequisite from Core: $pkg"
                rv=1
            fi
        fi

        if [ ${rv} -eq 0 ]; then
            if [ "${os_type}" != "linux" ]; then
                log $DEBUG "Package name: *${pkg}*"
                filename=`ls -1 "${WD}/${pkg}"* 2>/dev/null | sed -n '$p'`
                if [ -n "${filename}" ]; then
                    log $INFO "Attempting installation of missing prerequisite package: $filename"
                    if [ "${os_type}" = "sunos" ]; then
                        install_missing_prerequisites_sunos "${pkg_add}" "${pkg_info}" "${pkg}" "${filename}"
                    else
                        install_pkg_${os_type} "${pkg_add}" "${filename}"
                    fi
                fi
            else
                install_pkg_${os_type} "${pkg_add}" "${pkg}"
            fi

            # Fix the Solaris prerequisite package name back to the offical name for quering"
            [ "${os_type}" = "sunos" -a "${pkg}" = "CSWlibstdcpp6" ] && pkg="CSWlibstdc++6"
            log $INFO "Verifying prerequisite package installed: ${pkg}"

            # Test the package and any version specified for existence - query_pkg_<os> without
            # pkg_version should ignore parameter
            query_pkg_${os_type} "${pkg_info}" "${pkg}" "${pkg_version}"
            if [ $? -eq 0 ]; then
                log $INFO "Successfully installed prerequisite package: ${pkg}"
            else
                log $ERROR "Failed install of prerequisite package: ${pkg}:${pkg_version}"
                rv=1
            fi
        fi
    done
    return $rv
}

#
# Set a configuration value or modify an existing configuration value.  If the
# incoming value is empty, the configuration option will not be inserted into
# the configuration file.
#
# Param $1 - Filename to modify with key value pair
# Param $2 - Key
# Param $3 - Value - if empty, key not written
#
set_conf_value() {
    file="$1"
    key="$2"
    val="$3"

    if [ -n "${val}" ]; then
        if [ -f "${file}" ]; then
            grep -i "^${key}[\t ]*=" "${file}" >/dev/null 2>&1
            if [ $? -ne 0 ]; then
                log $INFO "Setting configuration: ${key}=${val}"
                ${ED} ${file} >/dev/null 2>&1 << EOF_CONF
$
a
${key}=${val}
.
w
q
EOF_CONF
            else
                log $INFO "Updating configuration: ${key}=${val}"
                ${ED} ${file} >/dev/null 2>&1 << EOF_CONF
/^${key}[\t ]*=/
c
${key}=${val}
.
w
q
EOF_CONF
            fi
        else
            conf_file=`basename $file`
            path=`echo $file | sed "s/\(.*\)\/${conf_file}$/\1/"`
            log $INFO "Creating configuration file: ${file}"
            log $INFO "Setting configuration: ${key}=${val}"
            if [ ! -d "${path}" ]; then
                log $INFO "Creating directory tree: ${path} for ${file}"
                ${MKDIR} -p ${path}
            fi
            ${ED} >/dev/null 2>&1 << EOF_CONF
a
${key}=${val}
.
w ${file}
q
EOF_CONF
            ${CHMOD} 644 "${file}"
        fi
    else
        log $DEBUG "Empty value for ${key} - skipping."
    fi
}

#
# Create the legacy links required by the Core for on-demand functionality.
#
# Param $1 - The basename for the application to create a link (ldiscan, map-sdclient or vulscan)
# Param $2 - The basename for the application to name the link (ldiscan, sdclient or vulscan)
#
create_legacy_links() {
    install_app="$1"
    link_app="$2"

    # Create legacy directory if it doesn't exist.
    if [ ! -d "${LEGACY_PREFIX}" ]; then
        ${MKDIR} -p "${LEGACY_PREFIX}/ldms"
    fi

    # Create legacy link if it doesn't existls
    if [ ! -h "${LEGACY_PREFIX}/ldms/${link_app}" ]; then
        ln -s "${INSTALL_PREFIX}/bin/${install_app}" "${LEGACY_PREFIX}/ldms/${link_app}"
    fi
}

#
# Pre installation steps for the CBA8 package.  GUID needs to be maintained across updates.
#
pre_install_cba8() {
    # If the device ID was captured, replace the old value in the configuration file.
    DEVICE_ID=`grep -i "Device ID=" "${GLOBAL_UID_FILE}" 2>/dev/null | cut -d = -f 2`
    [ -n "${DEVICE_ID}" ] && set_conf_value "${INSTALL_PREFIX}/etc/landesk.conf" "Device ID" "${DEVICE_ID}"
}

#
# Post installation steps for the CBA8 package - need to sleep for 5 seconds so the
# CBA daemon can bind to the ports correctly.
#
# Param $1 - OS Type [not used]
# Param $2 - OS Vendor [not used]
# Param $3 - OS Release [not used]
# Param $4 - OS Architecture [not used]
#
post_install_cba8() {
    # New installs will not have a GUID so save the last on from the landesk.conf file.
    DEVICE_ID=`grep -i "Device ID=" ${INSTALL_PREFIX}/etc/landesk.conf 2>/dev/null | cut -d = -f 2`
    [ -n "${DEVICE_ID}" ] && set_conf_value "${GLOBAL_UID_FILE}" "Device ID" "${DEVICE_ID}"

    log $INFO "Sleeping for 5 seconds to allow CBA to bind to needed ports."
    sleep 5
}

#
# Pre installation steps for the Ivanti CBA8 package.  GUID needs to be maintained across updates.
#
pre_install_ivanti_cba8() {
    tmp="$1"
}

#
# Post installation steps for the Ivanti CBA8 package - CBA requires another package
#     to setup common landesk configuration files (landesk.conf).   Other packages
#     should system start CBA after common landesk configuration files are configured.
#     If a DEVICE_ID does exist in landesk.conf CBA can be stared now.
# Param $1 - OS Type
# Param $2 - OS Vendor [not used]
# Param $3 - OS Release [not used]
# Param $4 - OS Architecture [not used]
#
post_install_ivanti_cba8() {
    local_device_id=`grep -i "DEVICE_ID_=" ${INSTALL_PREFIX}/etc/landesk.conf 2>/dev/null`
    if [ -n "${local_device_id}" ]; then
        if [ "${os_type}" = "linux" ]; then
            type "systemctl" > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                log $INFO "Starting CBA8 Service - systemctl"
                ${SYSTEM_INIT} start cba8 > /dev/null 2>&1
            elif [ -e /etc/init/cba8.conf ]; then
                log $INFO "Starting CBA8 Service - service"
                ${SERVICE_INIT} cba8 start > /dev/null 2>&1
            elif [ -e /etc/init.d/cba8 ]; then
                CBA8_START=/etc/init.d/cba8
                check_priv_escalation CBA8_START ${CBA8_START}
                if [ -n "${CBA8_START}" ]; then
                    log $INFO "Starting CBA8 Service - init.d"
                    ${CBA8_START} start > /dev/null 2>&1
                else
                    log $ERROR "Did not find mechanism to start CBA service install incomplete"
                    return
                fi
            else
                log $ERROR "Did not find mechanism to start CBA service install incomplete"
                return
            fi
        fi
        log $INFO "Sleeping for 5 seconds to allow CBA to bind to needed ports."
        sleep 5
    fi
}

#
# Pre-installation for ldiscan has to export the inventory period which
# controls how often the ldiscan job runs.  This period is based on the
# environment variable cronperiod being set prior to running this script.
#
pre_install_ldiscan() {
    os_type="$1"
    invperiod=24
    case ${cronperiod} in
        daily )
            invperiod=24
            ;;
        weekly )
            invperiod=168
            ;;
        monthly )
            invperiod=720
            ;;
        * )
            log $WARN "Unknown inventory period - valid values: daily, weekly or monthly.  Using daily"
            invperiod=24
            ;;
    esac

    # If this wasn't removed during the previous install, remove it now before
    # recreating it with the new value of this install process.
    [ -f "/tmp/ldinvperiod.tmp" ] && ${RM} -f "/tmp/ldinvperiod.tmp"

    log $INFO "Inventory period set to: ${invperiod} hours"
    echo "$invperiod" > /tmp/ldinvperiod.tmp
    export invperiod
}

#
# Post installation steps for ldiscan which include: creating legacy links, creating
# a common directory, creating a ldiscan script and putting in clean up routines
# into a crontab entry for removing log files and the SQLite DB file.
#
# Param $1 - OS Type normalized
# Param $2 - OS Vendor [not used]
# Param $3 - OS Release [not used]
# Param $4 - OS Architecture [not used]
#
post_install_ldiscan() {
    os_type="$1"

    # Move certificates
    [ ! -d "${CERT_PREFIX}" ] && ${MKDIR} -p "${CERT_PREFIX}"
    for cert in ${CERT_FILES}; do
        ${MV} -f ${cert} "${CERT_PREFIX}"
        ${CHMOD} 444 "${CERT_PREFIX}/${cert}"
    done

    # Links for legacy
    create_legacy_links "ldiscan" "ldiscan"

    # Crontab entries
    if [ "${os_type}" = "linux" ]; then
        # Add crontab entry for removing the logfiles.
        ${CRONTAB} -u landesk -l 2>/dev/null | grep "rm -f ${INSTALL_PREFIX}/logs/*.log" >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            (${CRONTAB} -u landesk -l 2>/dev/null;echo "0 1 * * 0 /bin/rm -f ${INSTALL_PREFIX}/logs/*.log") | ${CRONTAB} -u landesk - >/dev/null 2>&1
        fi
    else
        # Add crontab entry for removing the logfiles.
        ${CRONTAB} -l landesk 2>/dev/null | grep "rm -f ${INSTALL_PREFIX}/logs/*.log" >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            EDITOR=ed ${CRONTAB} -e landesk >/dev/null 2>&1 << EOF_CRONTAB
a
0 1 * * 0 /usr/bin/rm -f ${INSTALL_PREFIX}/logs/*.log
.
w
q
EOF_CRONTAB
        fi
    fi

    set_conf_value "${INSTALL_PREFIX}/etc/landesk.conf" Core "${CORE_ADDR}"
    set_conf_value "${INSTALL_PREFIX}/etc/landesk.conf" User "landesk"
    set_conf_value "${INSTALL_PREFIX}/etc/landesk.conf" Group "landesk"
    set_conf_value "${INSTALL_PREFIX}/etc/landesk.conf" corelanguage "${corelanguage}"
    set_conf_value "${INSTALL_PREFIX}/etc/landesk.conf" ManagedBy "LDMS"
    set_conf_value "${INSTALL_PREFIX}/etc/landesk.conf" Version "LDMS9-0-internal"
    set_conf_value "${INSTALL_PREFIX}/etc/landesk.conf" AgentVersion "${VERSION_INFO}"
}

#
# Pre installation steps for ivanti-base-agent:
#   1.  Save GUI in global file before landesk.conf is recreated
#
pre_install_ivanti_base_agent() {
    # Saving og GUID is done after uninstall but before installs.  No need to save or restore GUID
   tmp="$1"
}

#
#  Post install actions for ivanti-base-agent
#   1.  Add Core to communicate
#   2.  Add uniq ID (if needed generate)a
#   3.  Install cert files if provided
#
# Param $1 - OS Type normalized
# Param $2 - OS Vendor [not used]
# Param $3 - OS Release [not used]
# Param $4 - OS Architecture [not used]
#
post_install_ivanti_base_agent() {
    os_type="$1"

    # Move certificates
    [ ! -d "${CERT_PREFIX}" ] && ${MKDIR} -p "${CERT_PREFIX}"
    for cert in ${CERT_FILES}; do
        ${MV} -f ${cert} "${CERT_PREFIX}"
        ${CHMOD} 444 "${CERT_PREFIX}/${cert}"
    done

    # If common environments are defined on the command line, update the
    # "global" agent configuration.
    set_conf_value "${INSTALL_PREFIX}/etc/landesk.conf" "defaultEnvironment" "${DEFAULT_ENVIRONMENT}"
    set_conf_value "${INSTALL_PREFIX}/etc/landesk.conf" "defaultShell" "${DEFAULT_SHELL}"
    set_conf_value "${INSTALL_PREFIX}/etc/landesk.conf" "privilegeEscalationCommand" "${PRIV_ESCALATION_CMD}"

    # Set core address to communicate with
    set_conf_value "${INSTALL_PREFIX}/etc/landesk.conf" Core "${CORE_ADDR}"

    # Get global GUID or create one if it doesn't exist
    DEVICE_ID=`grep -i "Device ID=" "${GLOBAL_UID_FILE}" 2>/dev/null | cut -d = -f 2`
    if [ -n "${DEVICE_ID}" ]; then
        set_conf_value "${INSTALL_PREFIX}/etc/landesk.conf" "Device ID" "${DEVICE_ID}"
    else
        type "uuidgen" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            DEVICE_ID=`echo "{\`uuidgen\`}"`
        fi

        [ -z "${DEVICE_ID}" ] && log $ERROR "uuidgen not found - No device id generated!"
        [ -n "${DEVICE_ID}" ] && set_conf_value "${INSTALL_PREFIX}/etc/landesk.conf" "Device ID" "${DEVICE_ID}"
    fi
    set_conf_value "${INSTALL_PREFIX}/etc/landesk.conf" "AgentVersion" "${VERSION_INFO}"
    create_agent_settings_file "${DISTRIBUTION_PATCH_SETTINGS}" "${INVENTORY_SETTINGS}" "${CLIENTCONNECT_SETTINGS}"

    # All configuration files are set to 640 but landesk.conf needs to be
    # world readable because cba/pds2 do not currently run as landesk.
    ${CHMOD} 644 "${INSTALL_PREFIX}/etc/landesk.conf"

    if [ -e ${INSTALL_PREFIX}/bin/cba ]; then
        if [ "${os_type}" = "linux" ]; then
            type "systemctl" > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                log $INFO "Starting CBA8 Service - systemctl"
                ${SYSTEM_INIT} start cba8 > /dev/null 2>&1
            elif [ -e /etc/init/cba8.conf ]; then
                log $INFO "Starting CBA8 Service - service"
                ${SERVICE_INIT} cba8 start > /dev/null 2>&1
            elif [ -e /etc/init.d/cba8 ]; then
                CBA8_START=/etc/init.d/cba8
                check_priv_escalation ${OS_TYPE} CBA8_START ${CBA8_START}
                if [ -n "${CBA8_START}" ]; then
                    log $INFO "Starting CBA8 Service - init.d"
                    ${CBA8_START} start > /dev/null 2>&1
                else
                    log $ERROR "Did not find mechanism to start CBA service install incomplete"
                fi
            else
                log $ERROR "Did not find mechanism to start CBA service install incomplete"
            fi
        fi
        log $INFO "Sleeping for 5 seconds to allow CBA to bind to needed ports."
        sleep 5
    fi

}

##
# Pre-installation for ivanti-inventory (ldiscan) has to export the
# inventory period which controls how often the ldiscan job runs.
# This period is based on the environment variable cronperiod being
# set prior to running this script.
pre_install_ivanti_inventory() {
    pre_install_ldiscan $1
}

# Post installation steps for Ivanti Inventory (ldiscan) which include cleanup of previous agents
#  and start of initial inventory scan and configuration of Ivanti (landesk) settings.
#
# Param $1 - OS Type normalized
# Param $2 - OS Vendor [not used]
# Param $3 - OS Release [not used]
# Param $4 - OS Architecture [not used]
#
post_install_ivanti_inventory() {
    os_type="$1"
}

#
# Placeholder: Pre-installation for pds2
#
pre_install_pds2() {
    tmp="$1"
}

#
# Placeholder: Post installation for pds2.
#
# Param $1 - OS Type [not used]
# Param $2 - OS Vendor [not used]
# Param $3 - OS Release [not used]
# Param $4 - OS Architecture [not used]
#
post_install_pds2() {
    tmp="$1"
}

#
# Placeholder: Pre-installation for pds2
#
pre_install_ivanti_pds2() {
    tmp="$1"
}

#
# Placeholder: Post installation for pds2.
#
# Param $1 - OS Type [not used]
# Param $2 - OS Vendor [not used]
# Param $3 - OS Release [not used]
# Param $4 - OS Architecture [not used]
#
post_install_ivanti_pds2() {
    tmp="$1"
}

#
# Placeholder: Pre-installation for pds2g6
#
pre_install_pds2g6() {
    tmp="$1"
}

#
# Placeholder: Post installation for pds2g6.
#
# Param $1 - OS Type [not used]
# Param $2 - OS Vendor [not used]
# Param $3 - OS Release [not used]
# Param $4 - OS Architecture [not used]
#
post_install_pds2g6() {
    tmp="$1"
}

#
# Placeholder: Pre-installation for sdclient
#
pre_install_sdclient() {
    tmp="$1"
}

#
# Post installation for sdclient which simply adds links for the legacy installation.
#
# Param $1 - OS Type [not used]
# Param $2 - OS Vendor [not used]
# Param $3 - OS Release [not used]
# Param $4 - OS Architecture [not used]
#
post_install_sdclient() {
    tmp="$1"

    #links for legacy
    create_legacy_links "map-sdclient" "sdclient"
}

#
# Placeholder: Pre-installation for ivanti-software-distribution (sdclient)
#
pre_install_ivanti_software_distribution() {
    tmp="$1"
}

#
# Post installation for ivanti-software-distribution (sdclient) which simply adds links for the legacy installation.
#
# Param $1 - OS Type [not used]
# Param $2 - OS Vendor [not used]
# Param $3 - OS Release [not used]
# Param $4 - OS Architecture [not used]
#
post_install_ivanti_software_distribution() {
    tmp="$1"
}

#
# Placeholder: Pre-installation for ivanti-schedule
#
pre_install_ivanti_schedule() {
    tmp="$1"
}

#
# Placeholder: Post installation for ivanti-schedule
#
#
post_install_ivanti_schedule() {
    tmp="$1"
}

#
# Placeholder: Pre-installation for vulscan.
#
pre_install_vulscan() {
    tmp="$1"
}

#
# Post installation for vulscan which simply adds links for the legacy installation.
#
# Param $1 - OS Type normalized
# Param $2 - OS Vendor normalized
# Param $3 - OS Release
# Param $4 - OS Architecture (sparc, x86_64, i386, etc.)
#
post_install_vulscan() {
    os_type="$1"
    os_vendor="$2"
    os_release="$3"
    arch="$4"

    platformid="${os_type}${os_release}_${arch}"

    if [ "${os_type}" = "hpux" ]; then
        platformid="HP-UX`uname -r | sed 's/B.//'`"
        case `uname -m` in
            *ia64* )
                platformid="${platformid}:IA"
                ;;
            *700* )
                platformid="${platformid}:S700"
                ;;
            *800* )
                platformid="${platformid}:S800"
                ;;
        esac
    elif [ "${os_type}" = "linux" ]; then
        if [ "${os_vendor}" = "redhat" ]; then
            platformid="rhel${os_release}"
        elif [ "${os_vendor}" = "centos" ]; then
            platformid="${os_vendor}${os_release}"
        elif [ "${os_vendor}" = "sles" ]; then
            platformid="sles${os_release}"
        fi

        [ "${arch}" = "x86_64" ] && platformid="${platformid}_${arch}"
    elif [ "${os_type}" = "sunos" ]; then
        platformid="solaris${os_release}_${arch}"
    fi

    set_conf_value "${INSTALL_PREFIX}/etc/landesk.conf" platformid "${platformid}"

    #links for legacy
    create_legacy_links "vulscan" "vulscan"
}

#
# Placeholder: Pre-installation for ivanti-vulnerability
#
pre_install_ivanti_vulnerability() {
    tmp="$1"
}

#
# Post installation for ivanti-vulnerability
#
# Param $1 - OS Type normalized
# Param $2 - OS Vendor normalized
# Param $3 - OS Release
# Param $4 - OS Architecture (sparc, x86_64, i386, etc.)
#
post_install_ivanti_vulnerability() {
    tmp="$1"

}

#
# Install any files needed for an Agent install: certificates, tarballs or packages, etc. Any
# prerequisites should have been previously installed.
#
# Param $1 - OS Type normalized
# Param $2 - OS Vendor normalized
# Param $3 - OS Release
# Param $4 - OS Architecture (sparc, x86_64, i386, etc.)
# Param $5 - Package management installation command
# Param $6 - List of packages to attempt installation
# Param $7 - Key management tool to install keys and verify signatures
#
install_agent_packages() {
    os_type="$1"
    os_vendor="$2"
    os_release="$3"
    arch="$4"
    pkg_add="$5"
    pkg_list="$6"
    key_mgmt="$7"
    rv=0

    pkgs_to_baseagent="ivanti-cba8 ivanti-pds2 ivanti-base-agent ivanti-inventory ivanti-schedule ivanti-software-distribution cba8 pds2 pds2f6 ldiscan sdclient"
    pkgs_to_vulscan="ivanti-vulnerability vulscan"
    # CentOS 5 packages do not exist - switch to RedHat 5 for download purposes.
    os_effective_vendor="${os_vendor}"
    [ "${os_vendor}" = "centos" -a ${os_release} -eq 5 ] && os_effective_vendor="redhat"
    log $INFO "Effective vendor for package installation: ${os_effective_vendor}"

    os_abr=
    os_type_abbreviation "${os_type}" "${os_effective_vendor}" os_abr
    log $INFO "${os_type} and ${os_vendor} yields OS abbreviation: ${os_abr}"

    if [ $INI_INSTALL -ne 0 ] || [ $RPM_INSTALL -ne 0 -a -n "${CORE_ADDR}" ]; then
        # Fetch the certificate files for installation.
        for cert in ${CERT_FILES}; do
            fetch_file_exact "http://${CORE_ADDR}/ldlogon" "${cert}"
            [ $? -ne 0 ] && log $WARN "Failed to download ${cert} from http://${CORE_ADDR}/ldlogon"
        done

        # Fetch packages - If the packages can't be fetched by name, try the legacy package tarball.
        for pkg in ${pkg_list}; do
            filename="${pkg}*${os_abr}*${os_release}*${arch}*"
            os_path="${os_type}"
            [ "${os_path}" = "sunos" ] && os_path="solaris"

            # If the install type flipped, continue in loop until a package in the
            # list is not part of a given tarball.
            if [ ${LEGACY_INSTALL} -ne 0 ]; then
                ls baseclient64.tar.gz >/dev/null 2>&1
                if [ $? -eq 0 -a "${pkg}" = "ivanti-cba8" -o "${pkg}" = "ivanti-pds2" -o "${pkg}" = "ivanti-base-agent" -o "${pkg}" = "ivanti-inventory" -o "${pkg}" = "ivanti-software-distribution" ]; then
                    continue
                fi
                ls vulscan64.tar.gz >/dev/null 2>&1
                if [ $? -eq 0 -a "${pkg}" = "vulscan" ]; then
                    continue
                fi
            fi

            fetch_file "http://${CORE_ADDR}/ldlogon/unix/${os_path}" "${filename}"

            if [ $? -ne 0 ]; then
                contains "${pkgs_to_baseagent}" "${pkg}"
                if [ $? -eq 0 ]; then
                    filename="baseclient64.tar.gz"
                fi
                contains "${pkgs_to_vulscan}" "${pkg}"
                if [ $? -eq 0 ]; then
                    filename="vulscan64.tar.gz"
                fi
                log $INFO "Attempting to download legacy tarball for ${pkg}: ${filename} : ${pkgs_to_baseagent}"

                fetch_file_exact "http://${CORE_ADDR}/ldlogon/unix/${os_path}" "${filename}"
                if [ $? -ne 0 ]; then
                    log $ERROR "Failed attempt to download legacy tarball for ${pkg} (${filename})"
                    rv=1
                else
                    [ ${LEGACY_INSTALL} -eq 0 ] && log $INFO "Changing install type to: Tarball"
                    LEGACY_INSTALL=1

                    # Tarball installations have all packages - remove any previously downloaded.
                    # This is done in case the Core has both a package and tarball available.
                    log $INFO "Removing any previously downloaded package names."
                    for rmpkg in ${pkg_list}; do
                        rmfilename="${rmpkg}*${os_abr}*${os_release}*${arch}*"
                        if [ -f "${WD}/${rmfilename}" ]; then
                            log $DEBUG "Removing previously downloaded package: ${WD}/${rmfilename}"
                            ${RM} -f ${WD}/${rmfilename}
                        fi
                    done
                fi
            fi
        done
    fi

    # If the download succeeded, continue on trying to install the packages.
    if [ $rv -eq 0 ]; then

        # If tarballs are supposed to be present, the extract them and prepare to install the packages.
        if [ $LEGACY_INSTALL -eq 1 ]; then
            baseagent_file=`ls -1 ${WD}/baseclient64.tar.gz 2>/dev/null`
            vulscan_file=`ls -1 ${WD}/vulscan64.tar.gz 2>/dev/null`

            log $INFO "Base agent tarball filename: ${baseagent_file:-(none)}"
            log $INFO "Vulscan tarball filename: ${vulscan_file:-(none)}"

            if [ -n "${baseagent_file}" ]; then
                gzip -dc "${baseagent_file}" | tar xf -
                [ $? -ne 0 ] && log $WARN "Base agent tarball failed extraction: ${baseagent_file}"
            fi

            if [ -n "${vulscan_file}" ]; then
                gzip -dc "${vulscan_file}" | tar xf -
                [ $? -ne 0 ] && log $WARN "Vulscan tarball failed extraction: ${vulscan_file}"
            fi
        fi

        # If linux (rpms) verify the RPM public sign key exists locally
        if [ "${os_type}" = "linux" ] && [ "${os_vendor}" != "debian" ]; then
            if [ -e "${WD}/RPM-GPG-KEY-Ivanti" ]; then
                ${key_mgmt} --import "${WD}/RPM-GPG-KEY-Ivanti"
                if [ $? -ne 0 ]; then
                    log $ERROR "Failed to install Ivanti RPM public key unable to verify packages"
                    return 1
                fi
            else
                log $ERROR "Failed to find Ivanti RPM public key unable to verify packages"
                return 1
            fi

            # Verify each package being installed has GPG and is properly signed
            # (not all pkg add tools check signatures)
            for pkg in ${pkg_list}; do
                filename=`ls -1 ${WD}/${pkg}*${os_abr}*${os_release}*${arch}*`
                verify_pkg "${key_mgmt}" "${filename}"
                if [ $? -ne 0 ]; then
                    return 1
                fi
            done
        fi

        log $INFO "Checking for LDMS user and group specification"
        type "getent" > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            getent group ${LDMS_GROUP} > /dev/null 2>&1
        else
            grep "^${LDMS_GROUP}:" /etc/group > /dev/null 2>&1
        fi
        if [ $? -ne 0 ]; then
            log $INFO "LDMS group does not exist, creating group: ${LDMS_GROUP}"
            ${GROUPADD} ${LDMS_GROUP}
        fi

        type "getent" > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            ldms_gid=`getent group ${LDMS_GROUP} | cut -d : -f 3`
            getent passwd ${LDMS_USER} > /dev/null 2>&1
        else
            ldms_gid=`grep "^${LDMS_GROUP}:" /etc/group | cut -d : -f 3`
            grep "^${LDMS_USER}:"  /etc/passwd > /dev/null 2>&1
        fi
        if [ $? -ne 0 ]; then
            log $INFO "LDMS user does not exist, creating user: ${LDMS_USER}"
            [ -n "${ldms_gid}" ] && ${USERADD} -d "${INSTALL_PREFIX}" -g ${ldms_gid} ${LDMS_USER} >/dev/null 2>&1
            [ -z "${ldms_gid}" ] && ${USERADD} -d "${INSTALL_PREFIX}" ${LDMS_USER} >/dev/null 2>&1
        fi

        log $DEBUG "Package list for installation: ${pkg_list}"
        # Loop through the package list and install them.
        for pkg in ${pkg_list}; do
            pkg_proc_name=`echo "${pkg}" | sed -e s/-/_/g`
            filename=`ls -1 ${WD}/${pkg}*${os_abr}*${os_release}*${arch}* 2>/dev/null`

            # If there are multiple files with similar names, choose the first
            # one in directory listing, warn the user an issue exists and continue.
            file_count=`ls -1 ${WD}/${pkg}*${os_abr}*${os_release}*${arch}* 2>/dev/null | wc -l`
            log $DEBUG "Searching for: ${WD}/${pkg}*${os_abr}*${os_release}*${arch}*"
            if [ $file_count -gt 1 ]; then
                filename=`echo ${filename} | tr '\n' ' '`
                log $WARN "Multiple packages exist with same name; choosing first package: ${filename}"
                filename=`echo ${filename} | cut -f 1 -d ' '`
            fi

            if [ -n "${filename}" ]; then
                log $INFO "Attempting installation of package: ${filename}"
                pre_install_${pkg_proc_name} ${os_type}
                install_pkg_${os_type} "${pkg_add}" "${filename}"

                log $INFO "Verifying package installed: ${pkg}"
                query_pkg_${os_type} "${pkg_info}" ${pkg}
                if [ $? -eq 0 ]; then
                    post_install_${pkg_proc_name} ${os_type} ${os_vendor} ${os_release} ${arch}
                    log $INFO "Successfully installed package: ${pkg}"
                else
                    log $ERROR "Failed install of package: ${pkg}"
                    rv=1
                fi
            else
                log $WARN "Failed to find package: ${pkg}*${os_abr}*${os_release}*${arch}*"
                rv=1
            fi
        done
    fi

    return $rv
}

###################################
#    Removal Functions            #
###################################
#
# Removes the pieces left over from the installed packages
#
# Param $1 - OS Type normalized to lowercase
#
remove_install_crumbs() {
    os_type="$1"
    log $DEBUG "Cleaning up old install crumbs"

    # Remove the user and home directory if it exists
    for user in landesk cba8nobody; do
        log $DEBUG "Searching for user: ${user}"

        # Remove any existing crontab entries for each user.
        if [ "${os_type}" = "linux" ]; then
            ${CRONTAB} -u ${user} -r 2>/dev/null
        else
            ${CRONTAB} -r ${user} 2>/dev/null
        fi

        entry=`grep ${user} "/etc/passwd" 2>/dev/null`
        if [ $? -eq 0 ]; then
            homedir=`echo ${entry} | cut -d : -f 6`
            if [ -n "${homedir}" -a -d "${homedir}" ]; then
                log $DEBUG "Deleting user ${user} with home directory: ${homedir}"
                ${USERDEL} -r ${user} 2>/dev/null
            else
                log $DEBUG "Deleting user ${user} without home directory."
                ${USERDEL} ${user} 2>/dev/null
            fi
            [ -d "${homedir}" ] && log $WARN "User home directory not removed completely: ${homedir}"
        fi

        grep ${user} "/etc/group" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            ${GROUPDEL} ${user}
        fi
    done

    # Install Directories
    [ "${LEGACY_PREFIX}" != "/" ] && ${RM} -rf "${LEGACY_PREFIX}"
    [ "${INSTALL_PREFIX}" != "/" ] && ${RM} -rf "${INSTALL_PREFIX}"
}

#
# Ensure the cba8 package is ready for removal - if user is root, attempt to stop the CBA
# processes nicely.
#
preremove_cba8() {
    if [ "${USER}" = "root" ]; then
        log $INFO "Stopping the CBA8 daemon."
        [ -f /etc/init.d/cba ] && /etc/init.d/cba stop >/dev/null 2>&1
        [ -f /etc/init.d/cba8 ] && /etc/init.d/cba8 stop >/dev/null 2>&1
        [ -f /etc/rc.d/init.d/cba ] && /etc/rc.d/init.d/cba stop >/dev/null 2>&1
        [ -f /etc/rc.d/init.d/cba8 ] && /etc/rc.d/init.d/cba8 stop >/dev/null 2>&1
    fi
}

#
# After the cba8 package is removed, ensure necessary clean-up is done.
#
postremove_cba8() {
    # Remove PID files if they are still around
    ${RM} -f /var/run/cba.pid
}

#
# Disable systemd setup if the host has systemd.
#
# Note: CBA will be forcefully stopped because the current systemctl stop call
# hangs the Core during reinstall scenarios.
#
preremove_ivanti_cba8() {
    type "systemctl" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        # systemctl stop cba8 > /dev/null 2>&1
        ${SYSTEM_INIT} disable cba8 > /dev/null 2>&1
    fi
}

#
# Reload systemd if the host has systemd.
#
postremove_ivanti_cba8() {
    type "systemctl" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        ${SYSTEM_INIT} daemon-reload > /dev/null 2>&1
    fi
}

#
# Placeholder: Ensure the pds2 package is ready for removal.
#
preremove_pds2() {
    tmp="$1"
}

#
# Placeholder: After the pds2 package is removed, ensure necessary clean-up is done.
#
postremove_pds2() {
    tmp="$1"
}

#
# Placeholder: Ensure the ivanti-pds2 package is ready for removal.
#
preremove_ivanti_pds2() {
    tmp="$1"
}

#
# Placeholder: After the ivanti-pds2 package is removed, ensure necessary clean-up is done.
#
postremove_ivanti_pds2() {
    tmp="$1"
}

#
# Placeholder: Ensure the pds2g6 package is ready for removal.
#
preremove_pds2g6() {
    tmp="$1"
}

#
# Placeholder: After the pds2g6 package is removed, ensure necessary clean-up is done.
#
postremove_pds2g6() {
    tmp="$1"
}

#
# Ensure the ldiscan package is ready for removal.  Shutdown any scraper or scheduler
# instances and if they don't stop nicely, force them to stop.
#
preremove_ldiscan() {
    os_type="$1"

    # Stop the scraper and scheduler processes
    if [ "${USER}" = "root" ]; then
        log $INFO "Stopping the scraper and scheduler daemons."
        if [ -f /var/run/map-scraper.pid ]; then
            [ -f /etc/init.d/map-scraper ] && /etc/init.d/map-scraper stop >/dev/null  2>&1
            [ -f /etc/rc.d/init.d/map-scraper ] && /etc/rc.d/init.d/map-scraper stop >/dev/null 2>&1
        fi
        if [ -f /var/run/map-scheduler.pid ]; then
            [ -f /etc/init.d/map-scheduler ] && /etc/init.d/map-scheduler stop >/dev/null 2>&1
            [ -f /etc/rc.d/init.d/map-scheduler ] && /etc/rc.d/init.d/map-scheduler stop >/dev/null 2>&1
        fi
    fi

    # Remove cleanup of logs
    ${CRONTAB} -u landesk -l 2>/dev/null | grep -v "rm -f ${INSTALL_PREFIX}/logs/*.log" | ${CRONTAB} -u landesk - >/dev/null 2>&1

}

#
# After the ldiscan package is removed, ensure necessary clean-up is done.
#
postremove_ldiscan() {
    # Remove PID files if they are still around
    ${RM} -f /var/run/map-scheduler.pid
    ${RM} -f /var/run/map-scraper.pid

    # Remove legacy links or files
    ${RM} -f "${LEGACY_PREFIX}/ldms/ldiscan"

    # Remove some init files which had issues in the past
    ${RM} -f /etc/rc.d/init.d/map-scheduler
    ${RM} -f /etc/rc.d/init.d/map-scraper
    ${RM} -f /etc/init.d/map-scheduler
    ${RM} -f /etc/init.d/map-scraper
    ${RM} -f /etc/rc.d/rc3.d/S999map-scheduler
    ${RM} -f /etc/rc.d/rc3.d/S999map-scraper
    ${RM} -f /etc/rc.d/rc3.d/S99zcba
    ${RM} -f /etc/rc.d/rc2.d/K001map-scheduler
    ${RM} -f /etc/rc.d/rc2.d/K001map-scraper
    ${RM} -f /etc/rc.d/rc2.d/K001cba
    ${RM} -f /etc/rc.d/rc2.d/S99zcba
    ${RM} -f /etc/rc.d//rc2.d/S99zmap-scheduler
    ${RM} -f /etc/rc.d/rc2.d/S99zmap-scraper
}

#
# Placeholder:  Ensure the inventory package is ready for removal.
#
preremove_ivanti_inventory() {
    os_type="$1"
}

#
# Placeholder: After the inventory package is removed, ensure necessary clean-up is done.
#
postremove_ivanti_inventory() {
    tmp="$1"
}

#
# Placeholder: Ensure the sdclient package is ready for removal.
#
preremove_sdclient() {
    tmp="$1"
}

#
# After the sdclient package is removed, ensure necessary clean-up is done.
#
postremove_sdclient() {
    # Remove legacy links or files
    ${RM} -f "${LEGACY_PREFIX}/ldms/sdclient"
}

#
# Placeholder: Ensure the ivanti-software-distribution package is ready for removal.
#
preremove_ivanti_software_distribution() {
    tmp="$1"
}

#
# After the ivanti-software-distribution package is removed, ensure necessary clean-up is done.
#
postremove_ivanti_software_distribution() {
    tmp="$1"
}

#
# Placeholder: Ensure the ivanti-schedule package is ready for removal.
#
preremove_ivanti_schedule() {
    tmp="$1"
}

#
# Placeholder: After the ivanti-schedule package is removed, ensure necessary clean-up is done.
#
postremove_ivanti_schedule() {
    tmp="$1"
}

#
# Placeholder: Ensure the vulscan package is ready for removal.
#
preremove_vulscan() {
    tmp="$1"
}

#
# After the vulscan package is removed, ensure necessary clean-up is done.
#
postremove_vulscan() {
    # Remove legacy links or files
    ${RM} -f "${LEGACY_PREFIX}/ldms/vulscan"

    # Remove some files which had issues in the past.
    ${RM} -rf "${INSTALL_PREFIX}/var/vuldefs"
    ${RM} -f "$INSTALL_PREFIX/jobs/vulscan_daily.xml"
}

#
# Placeholder: Ensure the ivanti-vulnerability package is ready for removal.
#
preremove_ivanti_vulnerability() {
    tmp="$1"
}

#
# After the ivanti-vulnerability package is removed, ensure necessary clean-up is done.
#
postremove_ivanti_vulnerability() {
    tmp="$1"
}

#
# Ensure the ivanti-base-agent package is ready for removal.
#
preremove_ivanti_base_agent() {
    # Save GUID before landesk.conf gets deleted by the package
#    DEVICE_ID=`grep -i "Device ID=" "${INSTALL_PREFIX}/etc/landesk.conf" 2>/dev/null | cut -d = -f 2`
#    if [ -n "${DEVICE_ID}" ]; then
#        set_conf_value "${GLOBAL_UID_FILE}" "Device ID" "${DEVICE_ID}"
#    fi
    tmp="$1"
}

#
# After the ivanti-vulnerability package is removed, ensure necessary clean-up is done.
#
postremove_ivanti_base_agent() {
    tmp="$1"
}
#
# Remove a list of package using the system package management system.
#
# Param $1 - OS Type normalized
# Param $2 - List of packages to remove
# Param $3 - System package removal command.
#
remove_packages() {
    os_type="$1"
    pkg_list="$2"
    pkg_rm="$3"

    contains_match "${pkg_list}" "cba8"
    if [ $? -eq 0 ]; then
        pkg_list="${pkg_list} pds2"
    fi

    log $DEBUG "remove_packages OS:${os_type} PKGS:${pkg_list} CMD:${pkg_rm}"
    remove_order=

    if [ "${os_type}" = "linux" ]; then
        reverse_string "${ALL_COMP_PKGS}" remove_order
        remove_order="${remove_order} pds2 ${ALL_PKGS}"
    else
        remove_order="${pkg_list}"
    fi
    log $DEBUG "Remove order: ${remove_order}"

    for pkg in $remove_order; do
        contains_match "${pkg_list}" "${pkg}"
        if [ $? -eq 0 ]; then
            pkg_proc_name=`echo "${pkg}" | sed -e s/-/_/g`
            # Do any early special package processing
            preremove_${pkg_proc_name} ${os_type} "${pkg_rm}"

            # Terminate any running processes before the packages are removed which can cause a core dump.
            get_landesk_pids "${os_type}" pids
            if [ -n "${pids}" ]; then
                log $INFO "Some processes failed to stop gracefully...forcefully terminating: ${pids}"
                kill_process "${os_type}" "${pids}"
            fi

            # Remove the package
            remove_pkg_${os_type} "${pkg_rm}" ${pkg}

            # Do any post special package processing
            postremove_${pkg_proc_name} ${os_type}

        fi
    done
}

####################################
#     Option Processing            #
####################################
#
# Print the usage message of this script.
#
usage() {
    echo "Usage: ${0} [OPTION]..."
    echo "LDMS Agent installation, upgrade and removal processing."
    echo
    echo "   -a [core]        FQDN of LDMS core."
    echo "   -c [INI_file]    Uses INI configuration file for installation preferences."
    echo "   -C | --csa       Connect using a CSA tunnel connection"
    echo "   -Ci | --csaip [IP]"
	echo "                    The IP Address for the CSA (if --csa flag is enabled, this is required)"
    echo "   -Ch | --csahost [hostname]"
    echo "                    The fqdn for the CSA"
    echo "   -d               Add debug lines to output."
    echo "   -D               Install assuming no network connection except to core. (May not be specified with -p or -u)."
    echo "   --disable-priv-escalation-check"
    echo "                    Disables the privilege escalation checks so installation may fail due to permission issues."
    echo "   -e [ENV], --env [ENV]"
    echo "                    Set the default environment for the agent [Form: PATH=/bin:/sbin\nSHELL=/bin/sh]."
    echo "   -h, --help       Prints help message."
    echo "   -i [pkg], --install [pkg]"
    echo "                    Installs specified agent packages [all, cba8, ldiscan, sdclient or vulscan]."
    echo "   -l [log_file]    Log file for logging output [default: stdout]."
    echo "   -k [cert_file]   Certificate file."
    echo "   -p               Install prerequisites - pulled from distribution repositories or Core."
    echo "   -P [PATH], --path [PATH]"
    echo "                    Search PATH to find required tools."
    echo "   -r [pkg]         Remove specified agent packages [all, cba8, ldiscan, sdclient or vulscan]."
    echo "   -R               With option -r, ensures the /opt/landesk directory is gone including the GUID file."
    echo "   -s [SHELL], --shell [SHELL]"
    echo "                    Set the default shell used when processing scripts."
    echo "   -u [repo_url]    Custom repository definition (Linux Only)."
    echo
}

# Process command line options supporting both long and short options
# and allowing for options to have arguments.
#
# Note: This function does not take parameters and only works on the existing
#       global parameters and shell built-ins.
#
getOpts()
{
    while [ $# -gt 0 ]; do
        case "$1" in
            -a) CORE_ADDR="${2}"
                shift
                ;;
            -c) INI_FILE="${2}"
                shift
                ;;
            -C | --csa) USE_CSA=1
                ;;
            -Ci | --csaip*)
                contains "$1" "="
                if [ $? -eq 0 ]; then
                    CSA_IP=`echo $1 | cut -c10-`
                else
                    CSA_IP="$2"
                    shift
                fi
                ;;
            -Ch | --csahost*)
                contains "$1" "="
                if [ $? -eq 0 ]; then
                    CSA_HOST=`echo $1 | cut -c12-`
                else
                    CSA_HOST="$2"
                    shift
                fi
                ;;
            -d) VERBOSE=$DEBUG
                ;;
            -D) DARK_INST=1
                ;;
            --disable-priv-escalation-check) DISABLE_PRIV_ESCALATION_CHECK=1
                ;;
            -e | --env*)
                contains "$1" "="
                if [ $? -eq 0 ]; then
                    DEFAULT_ENVIRONMENT=`echo $1 | cut -c7-`
                else
                    DEFAULT_ENVIRONMENT="$2"
                    shift
                fi
                ;;
            -E | --priv-escalation-cmd*)
                contains "$1" "="
                if [ $? -eq 0 ]; then
                    PRIV_ESCALATION_CMD=`echo $1 | cut -c23-`
                else
                    PRIV_ESCALATION_CMD="$2"
                    shift
                fi
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            -i | --install*)
                contains "$1" "="
                if [ $? -eq 0 ]; then
                    value=`echo $1 | cut -c11-`
                    [ -n "${INSTALL_PKGS}" ] && INSTALL_PKGS="${INSTALL_PKGS} ${value}"
                    [ -z "${INSTALL_PKGS}" ] && INSTALL_PKGS="${value}"
                else
                    [ -n "${INSTALL_PKGS}" ] && INSTALL_PKGS="${INSTALL_PKGS} ${2}"
                    [ -z "${INSTALL_PKGS}" ] && INSTALL_PKGS="${2}"
                    shift
                fi
                RPM_INSTALL=1
                ;;
            -l) LOGFILE="${2}"
                if [ -f "${LOGFILE}" ]; then
                    log $INFO "======================================================================="
                    log $INFO "====================== Starting new installation ======================"
                    log $INFO "======================================================================="
                fi
                shift
                ;;
            -k) [ -n "${CERT_FILES}" ] && CERT_FILES="${CERT_FILES} ${2}"
                [ -z "${CERT_FILES}" ] && CERT_FILES="${2}"
                shift
                ;;
            -p) INSTALL_MISSING=1
                ;;
            -P | --path*)
                contains "$1" "="
                if [ $? -eq 0 ]; then
                    SEARCH_PATH=`echo $1 | cut -c8-`
                else
                    SEARCH_PATH="$2"
                    shift
                fi
                ;;
            -r) [ -n "${UNINSTALL_PKGS}" ] && UNINSTALL_PKGS="${UNINSTALL_PKGS} ${2}"
                [ -z "${UNINSTALL_PKGS}" ] && UNINSTALL_PKGS="${2}"
                shift
                ;;
            -R) KEEP_GUID=1
                ;;
            -s | --shell*)
                contains "$1" "="
                if [ $? -eq 0 ]; then
                    DEFAULT_SHELL=`echo $1 | cut -c9-`
                else
                    DEFAULT_SHELL="$2"
                    shift
                fi
                ;;
            -u) [ -n "${CUSTOM_REPO}" ] && CUSTOM_REPO="${CUSTOM_REPO} ${2}"
                [ -z "${CUSTOM_REPO}" ] && CUSTOM_REPO="${2}"
                shift
                ;;
            *) usage
                exit 1
                ;;
        esac
        shift
    done
}

#
# Processes the configuration options for the script. If command line options are present,
# the options given take precedence over any INI file options.  If either install or uninstall
# options are given, only the FQDN core address and certificate files will be used from the INI
# file (but only if not specified on the command line).  If neither command line arguments or INI
# file is present, look for the old style tarball files.
#
# If usage is printed: -h exits as 0, unknown parameter exits as 1.
#
process_configuration_options() {
    getOpts "$@"

    log $INFO "Command line: $0 $*"

    # Look for an ini file in the current directory if one was not provided.
    [ -z "${INI_FILE}" ] && INI_FILE=`ls -1 ${WD}/*.ini 2>/dev/null | paste -s -d" " - | sed 's/ *$//'`

    # If certificate files are local and not defined, pick them up.
    if [ -z "${CERT_FILES}" ]; then
        cert_file=`ls -1 ${WD}/*.0 2>/dev/null | paste -s -d" " -`
        for cert in ${cert_file}; do
            cert=`basename ${cert}`
            [ -n "${CERT_FILES}" ] && CERT_FILES="${CERT_FILES} ${cert}"
            [ -z "${CERT_FILES}" ] && CERT_FILES="${cert}"
        done
    fi

    # If CSA is enabled, ensure an IP address is given.
    if [ "${USE_CSA}" -eq 1 ]; then
		if [ -z "${CSA_IP}" ]; then
			log $ERROR "CSA flag is set but no CSA IP address was provided, required for connection, exiting..."
	    	return 1
	    fi
	fi

    # If install, uninstall and ini file does not exist, look for legacy install.
    if [ -z "${INI_FILE}" -a -z "${INSTALL_PKGS}" -a -z "${UNINSTALL_PKGS}" ]; then
        baseagent_file=`ls -1 ${WD}/baseclient64.tar.gz 2>/dev/null | paste -s -d" " -`
        vulscan_file=`ls -1 ${WD}/vulscan64.tar.gz 2>/dev/null | paste -s -d" " -`

        if [ -n "${baseagent_file}" -o -n "${vulscan_file}" ]; then
            if [ -n "${baseagent_file}" ]; then
                INSTALL_PKGS="cba8 ldiscan sdclient"
                [ -n "${vulscan_file}" ] && INSTALL_PKGS="${INSTALL_PKGS} vulscan"
            else
                [ -n "${vulscan_file}" ] && INSTALL_PKGS="vulscan"
            fi
            LEGACY_INSTALL=1
        fi
    fi

    [ x"${INSTALL_PKGS}" = x"all" ] && INSTALL_PKGS="${ALL_PKGS}"
    [ x"${UNINSTALL_PKGS}" = x"all" ] && UNINSTALL_PKGS="${ALL_PKGS}"

    # Normalize package names to lower case and sort alphabetically
    [ -n "${INSTALL_PKGS}" ] && INSTALL_PKGS=`echo ${INSTALL_PKGS} | tr '[A-Z]' '[a-z]' | tr ' ' '\n' | sort | paste -s -d" " -`
    [ -n "${UNINSTALL_PKGS}" ] && UNINSTALL_PKGS=`echo ${UNINSTALL_PKGS} | tr '[A-Z]' '[a-z]' | tr ' ' '\n' | sort | paste -s -d" " -`

    if [ -n "${INI_FILE}" ]; then
        if [ -f "${INI_FILE}" ]; then
            process_ini_file "${INI_FILE}" CORE_ADDR CERT_FILES VERSION_INFO CUSTOM_REPO INSTALL_PKGS UNINSTALL_PKGS SEARCH_PATH DEFAULT_ENVIRONMENT DEFAULT_SHELL PRIV_ESCALATION_CMD DISTRIBUTION_PATCH_SETTINGS INVENTORY_SETTINGS CLIENTCONNECT_SETTINGS
        else
            process_ini_file "${WD}/${INI_FILE}" CORE_ADDR CERT_FILES VERSION_INFO CUSTOM_REPO INSTALL_PKGS UNINSTALL_PKGS SEARCH_PATH DEFAULT_ENVIRONMENT DEFAULT_SHELL PRIV_ESCALATION_CMD DISTRIBUTION_PATCH_SETTINGS INVENTORY_SETTINGS CLIENTCONNECT_SETTINGS
        fi
    fi

    # If the INI file and command line options did not specify the tool search
    # path, default to the script standard search path.
    [ -z "${SEARCH_PATH}" ] && SEARCH_PATH=${STD_SEARCH_PATH}

    if [ -z "${INSTALL_PKGS}" -a -z "${UNINSTALL_PKGS}" ]; then
        log $ERROR "No configuration options provided via command line, INI or tarball files located in working directory: ${WD:?.}"
        return 1
    fi
}

#
# Translate an INI file entry which is a representation of one or more packages
# into a package list.
#
# Param $1 - The list of INI file entries to translate
# Out $2 - The list of packages represented by the INI file entries.
#
tr_entry_pkg() {
    entries="$1"
    result_list="$2"

    log $DEBUG "Entry list: ${entries}"
    pkgs=""
    for entry in ${entries}; do
        if [ x"${entry}" = x"CBA" ]; then
            log $DEBUG "Adding cba8"
            [ -n "${pkgs}" ] && pkgs="${pkgs} cba8"
            [ -z "${pkgs}" ] && pkgs="cba8"
            log $DEBUG "Adding ldiscan"
            [ -n "${pkgs}" ] && pkgs="${pkgs} ldiscan"
            [ -z "${pkgs}" ] && pkgs="ldiscan"
        elif [ x"${entry}" = x"SD" ]; then
            log $DEBUG "Adding sdclient"
            [ -n "${pkgs}" ] && pkgs="${pkgs} sdclient"
            [ -z "${pkgs}" ] && pkgs="sdclient"
        elif [ x"${entry}" = x"VS" ]; then
            log $DEBUG "Adding vulscan"
            [ -n "${pkgs}" ] && pkgs="${pkgs} vulscan"
            [ -z "${pkgs}" ] && pkgs="vulscan"
        else
            log $DEBUG "Ignoring INI entry [${entry}] for installation."
        fi
    done

    eval ${result_list}='"${pkgs}"'
}

#
# Run through a Core INI file to determine the core address, certificate files and
# installation packages. This information is only used if the options have not been
# specified on the command line.
#
# Param $1 - The INI filename to process.
# In/Out $2 - The FDNQ of the Core or empty for INI version.
# In/Out $3 - The certificate file list or empty for INI version.
# In/Out $4 - Custom repository definition or empty for INI version.
# In/Out $5 - Installation packages or empty for INI version.
# In/Out $6 - Uninstall packages or empty for INI version.
# In/Out $7 - Search path for tools or empty for INI version.
# In/Out $8 - Default environment or empty for INI version.
# In/Out $9 - Default shell or empty for INI version.
# In/Out $10 - Inventory privilege escalation command or empty for INI version.
# In/Out $11 - Distribution and patch settings guid or empty for INI version.
# In/Out $12 - Inventory settings guid or empty for INI version.
# In/Out $13 - Client Connectivity settings guid or empty for INI version.
#
process_ini_file() {
    ini_file="${1}"
    core="${2}"
    cert="${3}"
    agentver="${4}"
    custom_repo="${5}"
    install_pkgs="${6}"
    uninstall_pkgs="${7}"
    search_path="${8}"
    default_environment="${9}"
    default_shell="${10}"
    priv_escalation_cmd="${11}"
    distribution_patch_settings="${12}"
    inventory_settings="${13}"
    clientconnect_settings="${14}"

    ientry=""
    rentry=""
    core_entry=""
    cert_entry=""
    version_entry=""
    search_path_entry=""
    missing_prerequisite_entry=""
    dark_install_entry=""
    default_environment_entry=""
    default_shell_entry=""
    priv_escalation_command_entry=""

    distribution_patch_settings_entry=""
    inventory_settings_entry=""
    clientconnect_settings_entry=""
    debug_logging_entry=""

    log $INFO "Processing INI File: ${ini_file}"
    if [ -r "${ini_file}" -a -f "${ini_file}" ]; then
        for entry in ${INI_ENTRIES}; do
            log $DEBUG "Searching for: ${entry}=YES"
            grep -v "^ *;" "${ini_file}" | grep "${entry}=YES" >/dev/null 2>&1
            if [ $? -eq 0 ]; then
                log $DEBUG "Adding ${entry} to INI install entry list."
                [ -n "${ientry}" ] && ientry="${ientry} ${entry}"
                [ -z "${ientry}" ] && ientry="${entry}"
            else
                log $DEBUG "Adding ${entry} to INI uninstall entry list."
                [ -n "${rentry}" ] && rentry="${rentry} ${entry}"
                [ -z "${rentry}" ] && rentry="${entry}"
            fi
        done

        # Core provides files with carriage returns - they need to be stripped (hence last tr).
        core_entry=`grep -v "^ *;" "${ini_file}" | grep "ServerName=" | cut -d = -f 2 | tr -d '\r\n'`
        cert_entry=`grep -v "^ *;" "${ini_file}" | grep "FILE" | grep "\.0" | cut -d = -f 2 | tr '"' ' ' | paste -s -d" " - | tr -d '\r\n'`
        version_entry=`grep -v "^ *;" "${ini_file}" | grep "AgentVersion" | cut -d = -f 2 | tr -d '\r\n'`
        search_path_entry=`grep -v "^ *;" "${ini_file}" | grep "SearchPath=" | cut -d = -f 2 | tr '"' ' ' | paste -s -d" " - | tr -d '\r\n'`
        missing_prerequisite_entry=`grep -v "^ *;" "${ini_file}" | grep "PRQ=" | cut -d = -f 2 | tr '"' ' ' | paste -s -d" " - | tr -d '\r\n'`
        dark_install_entry=`grep -v "^ *;" "${ini_file}" | grep "NonRepoInstall=" | cut -d = -f 2 | tr '"' ' ' | paste -s -d" " - | tr -d '\r\n'`
        default_environment_entry=`grep -v "^ *;" "${ini_file}" | grep "DefaultEnvironment=" | cut -d = -f 2- | tr '"' ' ' | paste -s -d" " - | tr -d '\r\n'`
        default_shell_entry=`grep -v "^ *;" "${ini_file}" | grep "DefaultShell=" | cut -d = -f 2 | tr '"' ' ' | paste -s -d" " - | tr -d '\r\n'`
        priv_escalation_command_entry=`grep -v "^ *;" "${ini_file}" | grep "PrivilegeEscalationCommand=" | cut -d = -f 2 | tr '"' ' ' | paste -s -d" " - | tr -d '\r\n'`
        distribution_patch_settings_entry=`grep -v "^ *;" "${ini_file}" | grep "DistributionAndPatchSettings=" | cut -d = -f 2 | tr '"' ' ' | paste -s -d" " - | tr -d '\r\n'`
        inventory_settings_entry=`grep -v "^ *;" "${ini_file}" | grep "InventorySettings=" | cut -d = -f 2 | tr '"' ' ' | paste -s -d" " - | tr -d '\r\n'`
        clientconnect_settings_entry=`grep -v "^ *;" "${ini_file}" | grep "ClientConnectivitySettings=" | cut -d = -f 2 | tr '"' ' ' | paste -s -d" " - | tr -d '\r\n'`
		debug_logging_entry=`grep -v "^ *;" "${ini_file}" | grep "EnableDebugLogging=" | cut -d = -f 2 | tr '"' ' ' | paste -s -d" " - | tr -d '\r\n'`

        if [ -n "`grep -i '[Custom Repository]' \"${ini_file}\" 2>/dev/null`" ]; then
            repo_entry=`grep -v "^ *;" "${ini_file}" | grep "Repository=" | cut -d = -f 2 | tr '"' ' ' | paste -s -d" " - | tr -d '\r\n'`
            log $DEBUG "Custom repository ini entry: ${repo_entry}"
        fi
    else
        log $WARN "Specified INI file does not exist or is not accessible."
    fi

    # If options are not specified on the command line, attempt to pull
    # them from the INI file.
    [ -z "${CORE_ADDR}" ] && eval ${core}='"${core_entry}"'
    [ -z "${CERT_FILES}" ] && eval ${cert}='"${cert_entry}"'
    [ -z "${VERSION_INFO}" ] && eval ${agentver}='"${version_entry}"'
    [ -z "${CUSTOM_REPO}" ] && eval ${custom_repo}='"${repo_entry}"'
    [ -z "${SEARCH_PATH}" -a -n "${search_path_entry}" ] && eval ${search_path}='"${search_path_entry}"'
    [ -z "${DEFAULT_ENVIRONMENT}" -a -n "${default_environment_entry}" ] && eval ${default_environment}='"${default_environment_entry}"'
    [ -z "${DEFAULT_SHELL}" -a -n "${default_shell_entry}" ] && eval ${default_shell}='"${default_shell_entry}"'
    [ -z "${PRIV_ESCALATION_CMD}" -a -n "${priv_escalation_command_entry}" ] && eval ${priv_escalation_cmd}='"${priv_escalation_command_entry}"'

    [ -z "${DISTRIBUTION_PATCH_SETTINGS}" -a -n "${distribution_patch_settings_entry}" ] && eval ${distribution_patch_settings}='"${distribution_patch_settings_entry}"'
    [ -z "${INVENTORY_SETTINGS}" -a -n "${inventory_settings_entry}" ] && eval ${inventory_settings}='"${inventory_settings_entry}"'
    [ -z "${CLIENTCONNECT_SETTINGS}" -a -n "${clientconnect_settings_entry}" ] && eval ${clientconnect_settings}='"${clientconnect_settings_entry}"'

    [ ${INSTALL_MISSING} -eq 0 -a "${missing_prerequisite_entry}" = "YES" ] && INSTALL_MISSING=1
    [ ${DARK_INST} -eq 0 -a "${dark_install_entry}" = "YES" ] && DARK_INST=1

    if [ ${VERBOSE} -eq $INFO -a "${debug_logging_entry}" = "YES" ]; then
        VERBOSE=$DEBUG
        if [ -z "${LOGFILE}" ]; then
            LOGFILE="install.log"
            if [ -f "${LOGFILE}" ]; then
                log $INFO "======================================================================="
                log $INFO "====================== Starting new installation ======================"
                log $INFO "======================================================================="
            fi
        fi
    fi

    # If install or uninstall options are specified on the command line, ignore
    # any package information in the INI file.
    if [ -z "${INSTALL_PKGS}" -a -z "${UNINSTALL_PKGS}" ]; then
        tr_entry_pkg "${ientry}" ipkgs
        tr_entry_pkg "${rentry}" rpkgs
        eval ${install_pkgs}='"${ipkgs}"'
        eval ${uninstall_pkgs}='"${rpkgs}"'
        INI_INSTALL=1
    fi
}

#
# Verifies user intent and prints message to output. The incoming parameters
# for install and uninstall packages are updated with the upgrade packages
# and non-installed packages are dropped from the uninstall package list.
#
# Param $1 - Previously installed package list
# Global INSTALL_PKGS - The package list to install
# Global UNINSTALL_PKGS - The package list to remove (modified to drop non-installed packages
#                         and add upgrade packages)
#
verify_configuration() {
    prev_pkgs="$1"
    rv=0

    #
    # Handle platform specific modifications to the install/uninstall package lists before
    # verifying configuration information.
    #
    # AIX is special because vulscan is not supported so remove it from install lists.
    if [ "${OS_TYPE}" = "aix" ]; then
        if [ "${INSTALL_PKGS}" != "${ALL_PKGS}" ]; then
            contains "${INSTALL_PKGS}" "vulscan"
            [ $? -eq 0 ] && log $WARN "AIX does not support vulscan, removing package from install list."
        fi
        INSTALL_PKGS=`echo "${INSTALL_PKGS}" | sed 's/vulscan//'`

    # Linux has a special case of the pds2 package which does not exist on other platforms.
    elif [ "${OS_TYPE}" = "linux" ]; then
        if [ "${OS_VENDOR}" = "redhat" -o "${OS_VENDOR}" = "centos" ] && [ ${OS_RELEASE} -eq 5 ]; then
            INSTALL_PKGS=`echo "${INSTALL_PKGS}" | sed 's/cba8/cba8 pds2g6/'`
            UNINSTALL_PKGS=`echo "${UNINSTALL_PKGS}" | sed 's/cba8/cba8 pds2g6/'`
        else
            INSTALL_PKGS=`echo "${INSTALL_PKGS}" | sed 's/cba8/cba8 pds2/'`
            UNINSTALL_PKGS=`echo "${UNINSTALL_PKGS}" | sed 's/cba8/cba8 pds2/'`
        fi

    fi
    # Update packag names to new component arch packages if installing for linux
    #   INSTALL_PKGS and UNINSTALL_PKGS will contain packages like
    #   cba8, pds2, ldiscan, vulscan, and sdclient
    #   Replace them with 'ivanti' packages
    if [ "${OS_TYPE}" = "linux" ] && [ "${OS_VENDOR}" != "redhat" -o ${OS_RELEASE} -ne 5 ] && [ "${OS_VENDOR}" != "centos" -o ${OS_RELEASE} -ne 5 ]; then
        INSTALL_PKGS=`echo "${INSTALL_PKGS}" | sed 's/cba8/ivanti-cba8/'`
        UNINSTALL_PKGS=`echo "${UNINSTALL_PKGS}" | sed 's/cba8/ivanti-cba8/'`

        INSTALL_PKGS=`echo "${INSTALL_PKGS}" | sed 's/pds2/ivanti-pds2/'`
        UNINSTALL_PKGS=`echo "${UNINSTALL_PKGS}" | sed 's/pds2/ivanti-pds2/'`

        INSTALL_PKGS=`echo "${INSTALL_PKGS}" | sed 's/ldiscan/ivanti-base-agent ivanti-inventory ivanti-schedule/'`
        UNINSTALL_PKGS=`echo "${UNINSTALL_PKGS}" | sed 's/ldiscan/ivanti-base-agent ivanti-inventory ivanti-schedule/'`

        INSTALL_PKGS=`echo "${INSTALL_PKGS}" | sed 's/sdclient/ivanti-software-distribution/'`
        UNINSTALL_PKGS=`echo "${UNINSTALL_PKGS}" | sed 's/sdclient/ivanti-software-distribution/'`

        INSTALL_PKGS=`echo "${INSTALL_PKGS}" | sed 's/vulscan/ivanti-vulnerability/'`
        UNINSTALL_PKGS=`echo "${UNINSTALL_PKGS}" | sed 's/vulscan/ivanti-vulnerability/'`
    fi

    # Look for installed packages currently requested for installation.
    upgd_pkgs=""
    install_pkgs=""
    for pkg in ${INSTALL_PKGS}; do
        contains " ${prev_pkgs} " " ${pkg} "
        if [ $? -eq 0 ]; then
            [ -n "${upgd_pkgs}" ] && upgd_pkgs="${upgd_pkgs} ${pkg}"
            [ -z "${upgd_pkgs}" ] && upgd_pkgs="${pkg}"
        else
            [ -n "${install_pkgs}" ] && install_pkgs="${install_pkgs} ${pkg}"
            [ -z "${install_pkgs}" ] && install_pkgs="${pkg}"
        fi
    done

    # Look for installed packages currently requested for removal.
    noop_pkgs=""
    remove_pkgs=""
    for pkg in ${UNINSTALL_PKGS}; do
        contains " ${prev_pkgs} " " ${pkg} "
        if [ $? -eq 0 ]; then
            [ -n "${remove_pkgs}" ] && remove_pkgs="${remove_pkgs} ${pkg}"
            [ -z "${remove_pkgs}" ] && remove_pkgs="${pkg}"
        else
            [ -n "${noop_pkgs}" ] && noop_pkgs="${noop_pkgs} ${pkg}"
            [ -z "${noop_pkgs}" ] && noop_pkgs="${pkg}"
        fi
    done

    # Automatically remove any Legacy Packages.
    for pkg in ${LEGACY_PKGS}; do
        contains " ${prev_pkgs} " " ${pkg} "
        if [ $? -eq 0 ]; then
            contains " ${upgd_pkgs} " " ${pkg} "
            if [ $? -ne 0 ]; then
                [ -n "${remove_pkgs}" ] && remove_pkgs="${remove_pkgs} ${pkg}"
                [ -z "${remove_pkgs}" ] && remove_pkgs="${pkg}"
            fi
        fi
    done

    # Determine installation type: INI File, Local packages, Remove Packages or Tarball
    if [ $INI_INSTALL -ne 0 ]; then
        log $INFO "Installation Style: INI File"
    elif [ $RPM_INSTALL -ne 0 ]; then
        if [ -z "${CORE_ADDR}" ]; then
            log $INFO "Installation Style: Local Packages"
        else
            log $INFO "Installation Style: Packages"
        fi
    elif [ $LEGACY_INSTALL -ne 0 ]; then
        log $INFO "Installation Style: Tarball"
    fi

    # Log the request and the actual actions about to be performed.
    log $INFO "Core FQDN: ${CORE_ADDR}"
    log $INFO "Core certificates: ${CERT_FILES}"
    log $INFO "Working Directory: ${WD}"
    log $INFO "Additional Tool Search PATH: ${SEARCH_PATH}"
    [ ${DISABLE_PRIV_ESCALATION_CHECK} -eq 0 ] && log $INFO "Privilege escalation: Enabled" || log $INFO "Privilege escalation: Disabled"
    log $INFO "Requested Actions:"
    log $INFO "    Package installation: ${INSTALL_PKGS}"
    log $INFO "    Package removal: ${UNINSTALL_PKGS}"
    log $INFO "    Currently installed: ${prev_pkgs}"
    [ ${INSTALL_MISSING} -eq 0 ] && log $INFO "    Prerequisite install: No" || log $INFO "    Prerequistite install: Yes"
    [ ${DARK_INST} -eq 0 ] && log $INFO "    Non-Repository install: No" || log $INFO "    Non-Repository install: Yes"
    [ "${OS_TYPE}" = "linux" -a -n "${CUSTOM_REPO}" ] && log $INFO "    Custom Repository: ${CUSTOM_REPO}"
    [ -n "${DEFAULT_ENVIRONMENT}" ] && log $INFO "    Update Default Environment: ${DEFAULT_ENVIRONMENT}"
    [ -n "${DEFAULT_SHELL}" ] && log $INFO "    Update Default Shell: ${DEFAULT_SHELL}"
    [ -n "${PRIV_ESCALATION_CMD}" ] && log $INFO "    Update Privilege Escalation Command: ${PRIV_ESCALATION_CMD}"
    [ -n "${install_pkgs}" -o -n "${upgd_pkgs}" -o -n "${remove_pkgs}" ] && log $INFO "Planned Actions:"
    [ -n "${install_pkgs}" ] && log $INFO "    Install package: ${install_pkgs}"
    [ -n "${upgd_pkgs}" ]    && log $INFO "    Upgrade packages: ${upgd_pkgs}"
    [ -n "${remove_pkgs}" ]  && log $INFO "    Remove packages: ${remove_pkgs}"

    if [ -n "${noop_pkgs}" ]; then
        log $INFO "The following packages were requested for removal but are not installed:"
        log $INFO "   ${noop_pkgs}"
    fi
    [ "${OS_TYPE}" != "linux" -a -n "${CUSTOM_REPO}" ] && log $INFO "A custom repository was requested but this functionality is only for Linux - ignored"
    [ -n "${UNINSTALL_PKGS}" -a ${KEEP_GUID} -ne 0 ] && log $INFO "Removal of GUID file requested, this means the machine must be removed from the Core prior to reinstalling."

    # Verify size of INSTALL_PREFIX partition (250MB - dependencies for some platforms).
    if [ -n "${install_pkgs}" -a -z "${upgd_pkgs}" ]; then
        install_volume="${INSTALL_PREFIX}"
        while [ ! -d "${install_volume}" ]; do
            install_volume=`dirname "${install_volume}"`
        done

        log $INFO "Verifying ${INSTALL_PREFIX} located on mount point ${install_volume} has sufficient space (~250MB)."
        if [ "${OS_TYPE}" = "aix" ]; then
            volume_size=`df -k "${install_volume}" | sed -n '$p' | tr -s ' ' | cut -d ' ' -f 3`
        elif [ "${OS_TYPE}" = "hpux" ]; then
            volume_size=`df -P -k "${install_volume}" | sed -n '$p' | tr -s ' ' | cut -d ' ' -f 4`
        else
            volume_size=`df -k "${install_volume}" | sed -n '$p' | tr -s ' ' | cut -d ' ' -f 4`
        fi
        if [ $volume_size -lt 262144 ]; then
            log $ERROR "${install_volume} volume does not have enough space: ${volume_size} < 262144"
            rv=1
        fi
    fi

    # Reset the uninstall list because the no-ops are not needed but upgrade packages are needed.
    if [ -n "${remove_pkgs}" -a -n "${upgd_pkgs}" ]; then
        UNINSTALL_PKGS="${remove_pkgs} ${upgd_pkgs}"
    elif [ -n "${remove_pkgs}" ]; then
        UNINSTALL_PKGS="${remove_pkgs}"
    else
        UNINSTALL_PKGS="${upgd_pkgs}"
    fi

    # Verify installation packages match the known list of packages.
    error_pkgs=""
    for pkg in ${INSTALL_PKGS} ${UNINSTALL_PKGS}; do
        contains " ${ALL_COMP_PKGS} ${ALL_PKGS} pds2 pds2g6 ${LEGACY_PKGS} " " ${pkg} "
        if [ $? -ne 0 ]; then
            [ -n "${error_pkgs}" ] && error_pkgs="${error_pkgs} ${pkg}"
            [ -z "${error_pkgs}" ] && error_pkgs="${pkg}"
        fi
    done

    if [ -n "${error_pkgs}" ]; then
        log $ERROR "The following packages are not LDMS packages: ${error_pkgs}"
        rv=1
    fi

    if [ -z "${WD}" -o "${WD}" = "${SCRIPT}" ]; then
        log $ERROR "Script executed without full path which is required to properly set working directory."
        rv=1
    fi

    if [ ${INSTALL_MISSING} -ne 0 -o -n "${CUSTOM_REPO}" ] && [ ${DARK_INST} -ne 0 ]; then
        log $ERROR "Invalid configuration: Prerequisite installation or custom repository option selected with a non-network install."
        rv=1
    fi

    return $rv
}

#
# Attempts to find and determine if a command can be escalated if the
# current user is not root. If the commnand cannot be found or privileges
# cannot be escalated, the resulting global variable is set to a blank
# string and the verification function flags the errors as a group.
#
# Param $1 - OS Type normalized
# Param $2 - OS Architecture (sparc, x86_64, i386, etc.)
#
# Global PKG_ADD      - Package management command to install packages
# Global PKG_ADD_ALT  - Package management command to install packages without dependency download
# Global PKG_KEY_MGMT - Package management command to install keys
# Global PKG_RM       - Package management command to remove pacakges
# Global REPO_ADD     - Command used to add a custom package repository (optional)
# Global SYSTEM_INIT  - Systemd command to setup/tear-down services
# Global SERVICE_INIT - Upstart command to setup/tear-down services
# Global WD           - The current working directoy
#
process_required_tools() {
    os_type="${1}"
    architecture="${2}"

    # If the Core dropped a version of wget, move it so it will be picked up by find_tool.
    if [ -f "${WD}/wget_${os_type}_${architecture}" ]; then
        # Run without escalation in the local working directory.
        mv -f "${WD}/wget_${os_type}_${architecture}" "${WD}/wget" 2>/dev/null
        chmod +x "${WD}/wget" 2>/dev/null
    fi

    # Required tools which do not require escalation.
    # sudo must be found before the check_priv_escalation command is run.
    find_tool CURL curl
    find_tool SERVICE_INIT service
    find_tool SYSTEM_INIT systemctl
    find_tool SUDO sudo
    find_tool WGET wget

    # Run escalation checks which also finds proper command path.
    check_priv_escalation ${os_type} CHMOD chmod
    check_priv_escalation ${os_type} CRONTAB crontab
    check_priv_escalation ${os_type} CHOWN chown
    check_priv_escalation ${os_type} ED ed
    check_priv_escalation ${os_type} GROUPADD groupadd
    check_priv_escalation ${os_type} GROUPDEL groupdel
    check_priv_escalation ${os_type} KILL kill
    check_priv_escalation ${os_type} MKDIR mkdir
    check_priv_escalation ${os_type} MV mv
    check_priv_escalation ${os_type} RM rm
    check_priv_escalation ${os_type} USERADD useradd
    check_priv_escalation ${os_type} USERDEL userdel
    check_priv_escalation ${os_type} PKG_ADD ${PKG_ADD}
    [ -n "${PKG_ADD_ALT}" ] && check_priv_escalation ${OS_TYPE} PKG_ADD_ALT ${PKG_ADD_ALT}
    [ -n "${PKG_KEY_MGMT}" ] && check_priv_escalation ${OS_TYPE} PKG_KEY_MGMT ${PKG_KEY_MGMT}
    check_priv_escalation ${os_type} PKG_RM ${PKG_RM}
    [ -n "${REPO_ADD}" ] && check_priv_escalation ${os_type} REPO_ADD ${REPO_ADD}
    [ -n "${SYSTEM_INIT}" ] && check_priv_escalation ${OS_TYPE} SYSTEM_INIT ${SYSTEM_INIT}
    [ -n "${SERVICE_INIT}" ] && check_priv_escalation ${OS_TYPE} SERVICE_INIT ${SERVICE_INIT}

    # Fix tools which can go by other names based on platform
    [ -z "${GROUPADD}" ] && check_priv_escalation ${os_type} GROUPADD mkgroup
    [ -z "${GROUPDEL}" ] && check_priv_escalation ${os_type} GROUPDEL rmgroup
    [ -z "${ED}" ] && check_priv_escalation ${os_type} ED ex
}

#
# Verifies the existing tool set available on the system supports an installation
# or removal process and has the appropriate escalation privileges.
#
verify_required_tools() {
    rv=0

    # Check the required tools are installed - if not, get out.
    # sudo is not explicitly checked because the other commands will not be
    # defined if sudo was not defined and used as the privilege escalation means.
    if [ -n "${UNINSTALL_PKGS}" ] && \
       [ -z "${CHMOD}" -o -z "${CRONTAB}" -o -z "${ED}" -o -z "${GROUPDEL}" -o -z "${KILL}" -o -z "${MKDIR}" -o -z "${RM}" -o -z "${USERDEL}" -o -z "${PKG_RM}" ]; then
        log $INFO "Required tools missing or insufficient privileges for removal:"
        [ -z "${CHMOD}" ]    && log $INFO "    chmod [priv]"
        [ -z "${CRONTAB}" ]  && log $INFO "    crontab [priv]"
        [ -z "${ED}" ]       && log $INFO "    ed or ex [priv]"
        [ -z "${GROUPDEL}" ] && log $INFO "    groupdel or rmgroup [priv]"
        [ -z "${KILL}" ]     && log $INFO "    kill [priv]"
        [ -z "${MKDIR}" ]    && log $INFO "    mkdir [priv]"
        [ -z "${RM}" ]       && log $INFO "    rm [priv]"
        [ -z "${SUDO}" ]     && log $INFO "    sudo"
        [ -z "${USERDEL}" ]  && log $INFO "    userdel [priv]"
        [ -z "${PKG_RM}" ]   && log $INFO "    package removal (rpm, pkgrm, swremove) [priv]"
        rv=1
    fi

    if [ "${OS_TYPE}" = "linux" -a -n "${CUSTOM_REPO}" ]; then
        if [ -z "${REPO_ADD}" ]; then
            log $INFO "Required tools missing of insufficient privileges for adding/enabling a custom repository:"
            if [ "${OS_VENDOR}" = "redhat" -o "${OS_VENDOR}" = "centos" ]; then
                [ -z "${REPO_ADD}" ] && log $INFO "    yum-config-manager [priv]"
            elif [ "${OS_VENDOR}" = "sles" ]; then
                [ -z "${REPO_ADD}" ] && log $INFO "    zypper [priv]"
            fi
            rv=1
        fi
    fi

    if [ -n "${INSTALL_PKGS}" ]; then
        if [ -z "${CHMOD}" -o -z "${CRONTAB}" -o -z "${CHOWN}" -o -z "${ED}" -o -z "${GROUPADD}" -o -z "${MKDIR}" -o -z "${MV}" -o -z "${PKG_ADD}" -o -z "${RM}" -o -z "${USERADD}" ] || \
           [ -z "${WGET}" -a -z "${CURL}" -a ${LEGACY_INSTALL} -eq 0 ]; then
            log $INFO "Required tools missing or insufficient privileges for installation:"
            [ -z "${CHMOD}" ]    && log $INFO "    chmod [priv]"
            [ -z "${CRONTAB}" ]  && log $INFO "    crontab [priv]"
            [ -z "${CHOWN}" ]    && log $INFO "    chown [priv]"
            [ -z "${ED}" ]       && log $INFO "    ed or ex [priv]"
            [ -z "${GROUPADD}" ] && log $INFO "    groupadd or mkgroup [priv]"
            [ -z "${MKDIR}" ]    && log $INFO "    mkdir [priv]"
            [ -z "${MV}" ]       && log $INFO "    mv [priv]"
            [ -z "${PKG_ADD}" ]  && log $INFO "    package install (rpm, pkgadd, swinstall) [priv]"
            [ -z "${RM}" ]       && log $INFO "    rm [priv]"
            [ -z "${SUDO}" ]     && log $INFO "    sudo"
            [ -z "${USERADD}" ]  && log $INFO "    useradd [priv]"
            [ -z "${CURL}" -a -z "${WGET}" ] && log $INFO "    curl or wget"
            rv=1
        fi
    fi

    return $rv
}

#
# Verify access to the Core location where prerequisite packages should be placed.  This
# location is also the basis for agent installation packages.
#
# Param $1 - ignored
# Param $2 - ignored
#
verify_repository_access_aix() {
    rv=0
    url="${CORE_ADDR}/ldlogon/unix/aix"

    log $INFO "Verifying access to prerequisite package server: ${url}"

    test_connection "${url}"
    if [ $? -ne 0 ]; then
        log $ERROR "Failed connection to: ${url}"
        rv=1
    else
        log $INFO "Connection succeeded to: ${url}"
    fi

    return $rv
}

#
# Verify access to the Core location where prerequisite packages should be placed.  This
# location is also the basis for agent installation packages.
#
# Param $1 - ignored
# Param $2 - ignored
#
verify_repository_access_hpux() {
    rv=0
    url="${CORE_ADDR}/ldlogon/unix/hpux"

    log $INFO "Verifying access to prerequisite package server: ${url}"

    test_connection "${url}"
    if [ $? -ne 0 ]; then
        log $ERROR "Failed connection to: ${url}"
        rv=1
    else
        log $INFO "Connection succeeded to: ${url}"
    fi

    return $rv
}

#
# Verify access to prerequisite repositories. Each vendor has slightly different rules.
# RedHat and CentOS:
#   SSL repositories are skipped
#
# CentOS:
#   Verify non-SSL repository connections (Error)
#
# RedHat:
#   Verify an active subscription (Warning)
#   Verify non-SSL repository connections. (Error)
#
# SUSE:
#   Verify an active subscription (Warning)
#   Verify non-SSL repository connections. (Error)
#
# Param $1 - OS Vendor normalized
# Param $2 - Package management tool for install (yum/zypper)
#
verify_repository_access_linux() {
    os_vendor="$1"
    pkg_add="$2"
    file_repo_list=""
    ftp_repo_list=""
    http_repo_list=""
    mirror_repo_list=""
    ssl_mirror_repo_list=""
    ssl_repo_list=""
    rv=0

    log $INFO "Verifying access to available repositories."

    if [ "${os_vendor}" = "redhat" ]; then
        # Absense of this file does not mean the product is not registered. Some release added
        # this file and the subscription-manager status option. Checking the file because it is
        # more reliable than determining if the status option exists on the subscription-manager command.
        if [ -f /var/lib/rhsm/cache/entitlement_status.json ]; then
            grep "status" "/var/lib/rhsm/cache/entitlement_status.json" 2>&1 | grep "\"invalid\"," >/dev/null 2>&1
            if [ $? -eq 0 ]; then
                log $WARN "RedHat version is not registered."
            fi
        else
            log $INFO "Could not determine RedHat registration information."
        fi
    fi

    if [ "${os_vendor}" = "sles" ]; then
        if [ -f /var/cache/SuseRegister/lastzmdconfig.cache ]; then
            GUID=`grep guid /var/cache/SuseRegister/lastzmdconfig.cache | grep catalog | grep success | grep OK | sed 's/^.*<guid>//g' | sed 's/<\/guid.*$//g'`
            if [ ! -z "${GUID//[a-z0-9]}" ]; then
                log $WARN "SuSE version is not registered."
            fi
        else
            log $WARN "SuSE version is not registered."
        fi
    fi

    if [ "${os_vendor}" = "centos" -o "${os_vendor}" = "redhat" ]; then
        #capture Repo-baseurl and mirror values.
        base_urls="`${pkg_add} repolist -v 2>/dev/null | grep '^Repo-baseurl' | sed 's/^Repo-baseurl\s*:\s\+//' | cut -d ' ' -f 1`"
        mirrors_url="`${pkg_add} repolist -v 2>/dev/null | grep '^Repo-mirrors' | sed 's/^Repo-mirrors\s*:\s\+//' | cut -d ' ' -f 1`"

        file_repo_list="`echo "${base_urls}" | grep 'file://'`"
        ftp_repo_list="`echo "${base_urls}" | grep 'ftp://'`"
        http_repo_list="`echo "${base_urls}" | grep 'http://'`"

        [ -z "${http_repo_list}" ] && mirror_repo_list="`echo "${mirrors_url}" | grep 'http://'`"
        [ -z "${http_repo_list}" ] && ssl_mirror_repo_list="`echo "${mirrors_url}" | grep 'https://'`"

        ssl_repo_list="`echo "${base_urls}" | grep 'https://'`"
    elif [ "${os_vendor}" = "sles" ]; then
        file_repo_list=`${pkg_add} lr -u 2>/dev/null | grep "Yes *\(|[^|]\+\)\?| \+Yes *|" | sed -e "s/^\([^|]*|\)\+ *//" | grep "file://" | tr -d ' ' | tr '\n' ' '`
        ftp_repo_list=`${pkg_add} lr -u 2>/dev/null  | grep "Yes *\(|[^|]\+\)\?| \+Yes *|" | sed -e "s/^\([^|]*|\)\+ *//" | grep "ftp://" | tr -d ' ' | tr '\n' ' '`
        http_repo_list=`${pkg_add} lr -u 2>/dev/null | grep "Yes *\(|[^|]\+\)\?| \+Yes *|" | sed -e "s/^\([^|]*|\)\+ *//" | grep "http://" | tr -d ' ' | tr '\n' ' '`
        ssl_repo_list=`${pkg_add} lr -u 2>/dev/null  | grep "Yes *\(|[^|]\+\)\?| \+Yes *|" | sed -e "s/^\([^|]*|\)\+ *//" | grep "https://" | tr -d ' ' | tr '\n' ' '`
    elif [ "${os_vendor}" = "debian" ]; then
        file_repo_list=`cat /etc/apt/sources.list 2>/dev/null | grep "^deb" | cut -d ' ' -f 2 | grep "file://" | tr -d ' ' | tr '\n' ' '`
        ftp_repo_list=`cat /etc/apt/sources.list 2>/dev/null | grep "^deb" | cut -d ' ' -f 2 | grep "ftp://" | tr -d ' ' | tr '\n' ' '`
        http_repo_list=`cat /etc/apt/sources.list 2>/dev/null | grep "^deb" | cut -d ' ' -f 2 | grep "http://" | tr -d ' ' | tr '\n' ' '`
        ssl_repo_list=`cat /etc/apt/sources.list 2>/dev/null | grep "^deb" | cut -d ' ' -f 2 | grep "https://" | tr -d ' ' | tr '\n' ' '`
    fi

    if [ -z "${file_repo_list}" -a -z "${ftp_repo_list}" -a -z "${http_repo_list}" -a -z "${mirror_repo_list}" -a -z "${ssl_mirror_repo_list}" -a -z "${ssl_repo_list}" ]; then
        log $ERROR "No known repositories available."
        rv=1
    else
        failed_repos=0
        successful_repos=0
        [ -n "${ssl_repo_list}" -o -n "${ssl_mirror_repo_list}" ] && log $INFO "SSL secured repositories are not verified: ${ssl_repo_list} ${ssl_mirror_repo_list}"
        log $INFO "Attempting access verification of repositories: ${file_repo_list} ${ftp_repo_list} ${http_repo_list} ${mirror_repo_list}"
        for repo in ${file_repo_list}; do
            repo=`echo $repo | sed 's/file:\/\///'`
            if [ ! -e "${repo}" ]; then
                log $WARN "Repository path invalid: ${repo}"
                failed_repos=`expr ${failed_repos} + 1`
            else
                successful_repos=`expr ${successful_repos} + 1`
            fi
        done
        for repo in ${ftp_repo_list} ${http_repo_list} ${mirror_repo_list}; do
            test_connection "${repo}"
            if [ $? -ne 0 ]; then
                log $WARN "Failed connection to repository or mirror list: ${repo}"
                failed_repos=`expr ${failed_repos} + 1`
            else
                successful_repos=`expr ${successful_repos} + 1`
            fi
        done

        if [ -z "${ssl_repo_list}" -a -z "${ssl_mirror_repo_list}" ] && [ ${successful_repos} -eq 0 ]; then
            log $ERROR "Failed to verify any repository connections: Successful[${successful_repos}] Failed[${failed_repos}]"
            rv=1
        else
            log $INFO "Verified repository connections: Successful[${successful_repos}] Failed[${failed_repos}]"
        fi
    fi

    return $rv
}

#
# Verify access to the Core location where prerequisite packages should be placed.  This
# location is also the basis for agent installation packages.
#
# Note: This should be extended to deal with the IPS package system.
#
# Param $1 - ignored
# Param $2 - ignored
#
verify_repository_access_sunos() {
    rv=0
    url="${CORE_ADDR}/ldlogon/unix/solaris"

    log $INFO "Verifying access to prerequisite package server: ${url}"

    test_connection "${url}"
    if [ $? -ne 0 ]; then
        log $ERROR "Failed connection to: ${url}"
        rv=1
    else
        log $INFO "Connection succeeded to: ${url}"
    fi

    return $rv
}

#
# Verify the installation started CBA and the ldiscan components properly. Generally the issue
# is the map-scheduler claims the CBA port, if this occurs CBA does not start. If an issue is
# detected, stop everything and attempt a restart if the user is root.
#
# Param $1 - OS Type normalized
# Param $2 - Installation package list.
#
verify_installation() {
    os_type="$1"
    install_pkgs="$2"
    error=0

    log $INFO "Verifying installation is running properly."
    contains "${install_pkgs}" "cba"
    if [ $? -eq 0 ]; then
        check_pkgs="cba"
    fi

    contains "${install_pkgs}" "ldiscan"
    if [ $? -eq 0 ]; then
        [ -n "${check_pkgs}" ] && check_pkgs="${check_pkgs} ldiscan"
        [ -z "${check_pkgs}" ] && check_pkgs="ldiscan"
    fi

    for pkg in ${check_pkgs}; do
        [ "${pkg}" = "ldiscan" ] && pkg="map-"

        get_pids "${os_type}" "${pkg}" pid
        if [ -z "${pid}" ]; then
            log $WARN "${pkg} daemon(s) not started properly."
            error=1
        fi
    done

    if [ $error -ne 0 ]; then
        log $INFO "Attempting to correct daemon issues."
        if [ "${USER}" = "root" ]; then
            log $INFO "Stopping the cba8 daemon."
            [ -f /etc/init.d/cba ] && /etc/init.d/cba stop >/dev/null 2>&1
            [ -f /etc/init.d/cba8 ] && /etc/init.d/cba8 stop >/dev/null 2>&1
            [ -f /etc/rc.d/init.d/cba ] && /etc/rc.d/init.d/cba stop >/dev/null 2>&1
            [ -f /etc/rc.d/init.d/cba8 ] && /etc/rc.d/init.d/cba8 stop >/dev/null 2>&1
            log $INFO "Stopping the scraper and scheduler daemons."
            if [ -f /var/run/map-scraper.pid ]; then
                [ -f /etc/init.d/map-scraper ] && /etc/init.d/map-scraper stop >/dev/null 2>&1
                [ -f /etc/rc.d/init.d/map-scraper ] && /etc/rc.d/init.d/map-scraper stop >/dev/null 2>&1
            fi
            if [ -f /var/run/map-scheduler.pid ]; then
                [ -f /etc/init.d/map-scheduler ] && /etc/init.d/map-scheduler stop >/dev/null 2>&1
                [ -f /etc/rc.d/init.d/map-scheduler ] && /etc/rc.d/init.d/map-scheduler stop >/dev/null 2>&1
            fi
            sleep 5

            # Terminate any running processes
            get_landesk_pids "${os_type}" pids
            if [ -n "${pids}" ]; then
                log $INFO "Some processes failed to stop gracefully...forcefully terminating: ${pids}"
                kill_process "${os_type}" "${pids}"
                log $INFO "Sleeping for 10 seconds to allow daemons to close ports properly."
                sleep 10
            fi

            cnt=1
            while [ ${cnt} -le 4 ]; do
                log $INFO "Starting CBA"
                [ -f /etc/init.d/cba ] && /etc/init.d/cba start
                [ -f /etc/init.d/cba8 ] && /etc/init.d/cba8 start
                [ -f /etc/rc.d/init.d/cba ] && /etc/rc.d/init.d/cba start
                [ -f /etc/rc.d/init.d/cba8 ] && /etc/rc.d/init.d/cba8 start
                sleep 5
                get_landesk_pids "${os_type}" pids
                if [ -n "${pids}" ]; then
                    error=0
                    break
                else
                    log $INFO "Attempt: $cnt of 4 - Waiting 60 seconds to attempt restart."
                    sleep 60
                    cnt=`expr ${cnt} + 1`
                fi
            done

            if [ $error -ne 0 ]; then
                log $ERROR "Installation restart failed!"
            else
                log $INFO "Starting scraper"
                [ -f /etc/init.d/map-scraper ] && /etc/init.d/map-scraper start
                [ -f /etc/rc.d/init.d/map-scraper ] && /etc/rc.d/init.d/map-scraper start
                log $INFO "Starting scheduler"
                [ -f /etc/init.d/map-scheduler ] && /etc/init.d/map-scheduler start
                [ -f /etc/rc.d/init.d/map-scheduler ] && /etc/rc.d/init.d/map-scheduler start
                log $INFO "Installation restart succeeded - installation appears to be running correctly."
            fi
        else
            log $ERROR "Cannot attempt proper restart without privileged access"
        fi
    else
        log $INFO "Installation appears to be running correctly."
    fi

    # Verify landesk.conf contains "Device ID=" line which is required for
    # for CBA/Proxyhost to work properly.
    DEVICE_ID=`grep -i "Device ID=" ${INSTALL_PREFIX}/etc/landesk.conf 2>/dev/null | cut -d = -f 2`
    if [ -z "${DEVICE_ID}" ]; then
        log $ERROR "Install incomplete - requires ${INSTALL_PREFIX}/etc/landesk.conf to be updated with a valid 'Device ID=' line."
        error=1
    fi

    # Verify at least one Core certificate file exists in the standard location.
    installed_certificates=`ls -1 "${INSTALL_PREFIX}/var/cbaroot/certs/"*.0 2>/dev/null | sed -n '$p'`
    if [ -z "${installed_certificates}" ]; then
        log $ERROR "Install incomplete - requires ${INSTALL_PREFIX}/var/cbaroot/certs to contain at least 1 valid Core certificate."
        error=1
    fi

    installed_certificates=`ls -l "${INSTALL_PREFIX}/var/cbaroot/certs/"*.0 2>/dev/null | wc -l`
    if [ ${installed_certificates} -gt 1 ]; then
        log $WARN "${installed_certificates} Core certificates present - supported installs allow for only 1 Core certificate."
    fi

    return $error
}

is_child_of() {
    token_comm=$1
    parent_pid=`ps -o ppid= -p $$`
    while [ $parent_pid != 1 ]; do
        comm=`ps -o comm= -p $parent_pid`
        if [ "${comm}" = "${token_comm}" ]; then
            log $INFO "Process is child of ${token_comm}."
            return 0
        else
            parent_pid=`ps -o ppid= -p $parent_pid`
        fi
    done
    log $INFO "Process is not a child of ${token_comm}."
    return 1
}

is_systemd() {
    [ -d "/run/systemd/system" ]
}

add_crontab_task() {
    line=$1
    log $INFO "Adding crontab entry: ${line}"
    (crontab -l 2>/dev/null; echo "${line}") | crontab -
}

remove_crontab_task() {
    token=$1
    log $INFO "Removing crontab entry: ${token}"
    crontab -l 2>/dev/null | grep -v "${token}" | crontab -
}

####################################
#     Main                         #
####################################
CERT_FILES=""
CLIENTCONNECT_SETTINGS=""
CSA_IP=""
CSA_HOST=""
CORE_ADDR=""
DEFAULT_ENVIRONMENT=""
DEFAULT_SHELL=""
DISTRIBUTION_PATCH_SETTINGS=""
INI_FILE=""
INSTALL_PKGS=""
INVENTORY_SETTINGS=""
PRIV_ESCALATION_CMD=""
PREVIOUS_PKGS=""
REDIRECT_OUTPUT="/dev/null"
SEARCH_PATH=""
SUDO=""
SUDOER_FILE=""
UNINSTALL_PKGS=""
VERSION_INFO=""
DARK_INST=0
DISABLE_PRIV_ESCALATION_CHECK=0
INI_INSTALL=0
INSTALL_MISSING=0
KEEP_GUID=0
LEGACY_INSTALL=0
RPM_INSTALL=0
USE_CSA=0

# Process command line and INI file options.
process_configuration_options "$@"
[ $? -ne 0 ] && exit 1

# Schedule new process to run so that nixconfig isn't killed when run as a child of cba
if is_child_of "cba" ; then
    cp -rp ${WD} ${WD}_schedule
    script=`echo "$0 $*" | sed "s#${WD}#${WD}_schedule#g"`

    if is_systemd ; then
        log $INFO "Scheduling ${script} for systemd"
        systemd-run --on-active=30 sh $script
    else
        log $INFO "Scheduling ${script} in crontab"
        add_crontab_task "*/2 * * * * sh $script"
    fi
    log $INFO "Exiting script under CBA"
    exit 0;
elif is_child_of "crond" ; then
    log $INFO "Removing $0 from crontab"
    remove_crontab_task "$0"
fi

# If debug mode is on, try to put the command output to the proper location.
if [ $VERBOSE -eq $DEBUG ]; then
    [ -z "${LOGFILE:-}" ] && REDIRECT_OUTPUT=""
    [ -n "${LOGFILE}" ] && REDIRECT_OUTPUT="${LOGFILE}"
fi

# Determine OS type, vendor and release.
find_os_info OS_TYPE OS_VENDOR OS_RELEASE ARCHITECTURE
[ $? -ne 0 ] && abort "Unknown OS: ${OS_TYPE}" 1
log $INFO "OS Information: ${OS_TYPE} - ${OS_VENDOR} ${OS_RELEASE} ${ARCHITECTURE}"

# Find package management tooling.
find_package_mgmt_tool ${OS_TYPE} PKG_INFO PKG_ADD PKG_RM REPO_ADD PKG_KEY_MGMT PKG_ADD_ALT
[ $? -ne 0 ] && abort "Could not determine package management tooling for OS: ${OS_TYPE}" 1
log $INFO "Package Management: Query - ${PKG_INFO}, Install - ${PKG_ADD}, Remove - ${PKG_RM}"

# Determine if any existing packages are installed.
find_previously_installed_agent ${OS_TYPE} ${PKG_INFO} PREVIOUS_PKGS

# Determine actual installation and removal procedures.
verify_configuration "${PREVIOUS_PKGS}"
[ $? -ne 0 ] && abort "The specified configuration will not install properly. Please correct errors" 1

# If User isn't defined in the environment, grab it from the id command so we can use it later.
if [ -z "${USER}" ]; then
    USER=`id | sed 's/uid=[0-9]*(\(.*[^)]\)) gid=.*/\1/'`
fi
log $INFO "Running as user: ${USER}"
log $INFO "User's environment PATH: ${PATH}"

# Find required tools and check if the user can escalate privileges as needed.
process_required_tools ${OS_TYPE} ${ARCHITECTURE}
verify_required_tools
[ $? -ne 0 ] && abort "Required tools missing or insufficient privileges" 13

# Grab the current GUID and the global GUID if one exists.
DEVICE_ID=`grep -i "Device ID=" ${INSTALL_PREFIX}/etc/landesk.conf 2>/dev/null | cut -d = -f 2`
GLOBAL_DEVICE_ID=`grep -i "Device ID=" "${GLOBAL_UID_FILE}" 2>/dev/null | cut -d = -f 2`

# Before we uninstall anything make sure we can install on /opt.
${MKDIR} -p "${INSTALL_PREFIX}/.${$}"
[ $? -ne 0 ] && abort "/opt volume is not writable by ${USER}." 1
${RM} -rf "${INSTALL_PREFIX}/.${$}"

#
# Add custom repositories if defined - Linux distributions only.
#
if [ "${OS_TYPE}" = "linux" -a -n "${CUSTOM_REPO}" ]; then
    if [ "${OS_VENDOR}" = "debian" ]; then
        log $INFO "No support for custom repository for debian like OS(s)"
    else
        add_custom_repository ${OS_TYPE} ${OS_VENDOR} ${OS_RELEASE} "${REPO_ADD}" "${CUSTOM_REPO}"
        [ $? -ne 0 ] && log $WARN "Custom repository not added properly - continuing on"
    fi
fi

#
# CSA is not supported for non-linux machines, warn and continue without flag
#
if [ "${OS_TYPE}" != "linux" -a "${USE_CSA}" -eq 1 ]; then
	log $WARN "No support for CSA for non-linux machines, ignoring CSA flag"
	USE_CSA=0
fi

# If there are installation packages, check a connection to the Core can be established.
# Also check the prerequisite list prior to removing any existing packages. If prerequisite
# installation was not specified or cannot establish connection to repositories, abort.
if [ -n "${INSTALL_PKGS}" ]; then
    #Check for USE_CSA
    if [ "${USE_CSA}" -eq 0 ]; then
	    # Verify connection to Core can be established.
	    test_connection "${CORE_ADDR}"
	    [ $? -ne 0 ] && abort "Core connection test failed: ${CORE_ADDR}" 1
	    log $INFO "Core connection test successful: ${CORE_ADDR}"
    else
    	# Verify connection to CSA via IP or hostname
    	if [ -n "${CSA_IP}" ]; then
    		test_connection "${CSA_IP}"
    		[ $? -ne 0 ] && abort "CSA IP connection test failed: ${CSA_IP}" 1
	    	log $INFO "CSA IP connection test successful: ${CSA_IP}"
	    fi
	    if [ -n "${CSA_HOST}" ]; then
	    	test_connection "${CSA_HOST}"
    		[ $? -ne 0 ] && abort "CSA Host connection test failed: ${CSA_HOST}" 1
	    	log $INFO "CSA IP connection test successful: ${CSA_HOST}"
	    fi
    fi

    analyze_prerequisites ${OS_TYPE} ${OS_VENDOR} ${OS_RELEASE} ${PKG_INFO}
    if [ -n "${MISSING}" ]; then
        if [ ${INSTALL_MISSING} -eq 0 ] || [ ${DARK_INST} -eq 1 ]; then
            MISSING=`echo ${MISSING} | tr ':' '-'`
            abort "Missing prerequisites: ${MISSING}" 1
        fi
        verify_repository_access_${OS_TYPE} "${OS_VENDOR}" "${PKG_ADD}"
        [ $? -ne 0 ] && abort "Repository access failed." 1
    fi
fi

# Let's get to work but first change to the working directory.
cd ${WD} 2>/dev/null
[ $? -ne 0 ] && abort "Could not change to the working directory: ${WD}" 1

#
# Uninstall Packages
#
if [ -n "${UNINSTALL_PKGS}" ]; then
    log $INFO "Performing package removal."

    remove_packages ${OS_TYPE} "${UNINSTALL_PKGS}" "${PKG_RM}"

    # Count the number of uninstalled packages.
    pkg_rv=0
    pkg_cnt=0
    for pkg in ${ALL_COMP_PKGS} ${ALL_PKGS} pds2 pds2g6; do
        pkg_cnt=`expr $pkg_cnt + 1`
        query_pkg_${OS_TYPE} ${PKG_INFO} ${pkg}
        pkg_rv=`expr $pkg_rv + $?`
    done

    # If everything is gone, completely remove installation.
    [ $pkg_rv -eq $pkg_cnt ] && remove_install_crumbs "${OS_TYPE}"
fi

# If the device id exists and it does not match the current machine device id, update the machine device id.
if [ -n "${DEVICE_ID}" -a $KEEP_GUID -eq 0 ]; then
    [ "${DEVICE_ID}" != "${GLOBAL_DEVICE_ID}" -a -n "${GLOBAL_DEVICE_ID}" ] && log $WARN "Current GUID (${DEVICE_ID}) does not match machine GUID (${GLOBAL_DEVICE_ID})"
    log $INFO "Setting machine GUID to ${DEVICE_ID}"
    set_conf_value "${GLOBAL_UID_FILE}" "Device ID" "${DEVICE_ID}"
elif [ ! -n "${DEVICE_ID}" -a $KEEP_GUID -eq 0 -a -n "${GLOBAL_DEVICE_ID}" ]; then
    DEVICE_ID=${GLOBAL_DEVICE_ID}
    log $INFO "Setting DEVICE_ID to ${GLOBAL_DEVICE_ID} "
fi

#
# Install Packages
#
if [ -n "${INSTALL_PKGS}" ]; then
    # Gzip appears to be tucked away on HP-UX - good times.
    if [ "${OS_TYPE}" = "hpux" ]; then
        PATH=${PATH}:/usr/contrib/bin
        export PATH
    fi

    # Install prerequisites if requested.
    if [ -n "${MISSING}" -a ${INSTALL_MISSING} -ne 0 ]; then
        log $INFO "Attempting requested prerequisite installation: ${MISSING}"
        install_missing_prerequisites ${OS_TYPE} "${PKG_ADD}" "${PKG_INFO}" "${MISSING}"
        [ $? -ne 0 ] && abort "Prerequisites failed to install properly. Attempted packages: ${MISSING}" 1 1
    fi

    log $INFO "Performing package install."
    install_agent_packages ${OS_TYPE} ${OS_VENDOR} ${OS_RELEASE} ${ARCHITECTURE} "${PKG_ADD}" "${INSTALL_PKGS}" "${PKG_KEY_MGMT}"
    [ $? -ne 0 ] && abort "Installation failed" 1 1
    ${CHOWN} -R landesk:landesk "${INSTALL_PREFIX}"

    contains "${INSTALL_PKGS}" "cba8"
    if [ $? -eq 0 ]; then
        if [ -x "${INSTALL_PREFIX}/bin/alert" ]; then
            log $INFO "Notifying Core Install is complete."
            ${INSTALL_PREFIX}/bin/alert -f internal.cba8.install.complete
        else
            abort "CBA alert mechanism missing" 2 1
        fi
    fi

    verify_installation ${OS_TYPE} "${INSTALL_PKGS}"
    [ $? -ne 0 ] && abort "Installation failed to pass verification" 1 1

    # This will be temporary, replace with parsing of Client Connectivity file in future
	# If CSA is enabled, write to broker.conf.xml file so proxy can use it
	if [ "${USE_CSA}" -eq 1 ]; then
		create_broker_conf_file "${CSA_HOST}" "${CSA_IP}"
	fi

    # Launch the broker_config to try and request client certificate from core
    contains_match "${INSTALL_PKGS}" "ivanti-base-agent"
    if [ $? -eq 0 ]; then
        log $INFO "Launching initial broker certificate request."
        BROKER="${INSTALL_PREFIX}/bin/broker_config"
        check_priv_escalation ${OS_TYPE} BROKER "${BROKER}" "${INSTALL_PREFIX}/bin"
        if [ -n "${BROKER}" ]; then
            ${BROKER}
            if [ $? -eq 0 ]; then
                log $INFO "Initial certificate request completed successfully."
            else
                log $WARN "Initial certificate request failed to complete."
            fi
        elif [ -n "${SUDO}" ]; then
            ${SUDO} -n ${INSTALL_PREFIX}/bin/broker_config
            if [ $? -eq 0 ]; then
                log $INFO "Initial certificate request completed successfully."
            else
                log $WARN "Initial certificate request failed to complete."
            fi
        else
            log $WARN "Initial certificate request lacks sufficient privileges - will be launched within 24 hours via cron."
        fi
    fi

    # Launch the initial inventory (no need to check for proxyhost as
    # cba8 is chained dependency for this install)
    contains_match "${INSTALL_PKGS}" "ivanti-inventory"
    if [ $? -eq 0 ]; then
        log $INFO "Launching initial inventory scan."
        LDISCAN="${INSTALL_PREFIX}/bin/ldiscan"
        check_priv_escalation ${OS_TYPE} LDISCAN "${LDISCAN}" "${INSTALL_PREFIX}/bin"
        if [ -n "${LDISCAN}" ]; then
            ${LDISCAN}
            if [ $? -eq 0 ]; then
                log $INFO "Initial inventory completed successfully."
            else
                log $WARN "Initial inventory failed to complete."
            fi
        elif [ -n "${SUDO}" ]; then
            ${SUDO} -n ${INSTALL_PREFIX}/bin/ldiscan
            if [ $? -eq 0 ]; then
                log $INFO "Initial inventory completed successfully."
            else
                log $WARN "Initial inventory failed to complete."
            fi
        else
            log $WARN "Initial inventory scan lacks sufficient privileges - will be launched within 24 hours via cron."
        fi
    fi

    # Vulnerability scans will be launched after the script ends
    contains_match "${INSTALL_PKGS}" "ivanti-vulnerability"
    if [ $? -eq 0 ]; then
        log $INFO "Attempting initial launch of vulnerability scan as background process."
        VULSCAN="${INSTALL_PREFIX}/bin/vulscan"
        check_priv_escalation ${OS_TYPE} VULSCAN "${VULSCAN}" "${INSTALL_PREFIX}/bin"
        if [ -n "${VULSCAN}" ]; then
            NOHUP_VULSCAN="nohup ${VULSCAN} -AgentBehavior=-1 > /dev/null 2>&1 &"
            eval $NOHUP_VULSCAN
            log $INFO "Initial vulnerability scan launched successfully."
        elif [ -n "${SUDO}" ]; then
            NOHUP_VULSCAN="${SUDO} -n nohup ${INSTALL_PREFIX}/bin/vulscan -AgentBehavior=-1 > /dev/null 2>&1 &"
            eval $NOHUP_VULSCAN
            log $INFO "Initial vulnerability scan launched successfully."
        else
            log $WARN "Initial vulnerability scan lacks sufficient privileges - will be launched within 24 hours via cron."
        fi
    fi

    #Software distribution is required for agent settings
    contains_match "${INSTALL_PKGS}" "ivanti-software-distribution"
    if [ $? -eq 0 ]; then
        log $INFO "Attempting initial fetch of policies and agent settings."
        POLICY="${INSTALL_PREFIX}/bin/map-fetchpolicy"
        check_priv_escalation ${OS_TYPE} POLICY "${POLICY}" "${INSTALL_PREFIX}/bin"
        if [ -n "${POLICY}" ]; then
            ${POLICY}
            if [ $? -eq 0 ]; then
                log $INFO "Initial policy fetch completed successfully."
            else
                log $WARN "Initial policy fetch failed to complete."
            fi
        elif [ -n "${SUDO}" ]; then
            ${SUDO} -n ${INSTALL_PREFIX}/bin/map-fetchpolicy
            if [ $? -eq 0 ]; then
                log $INFO "Initial policy fetch completed successfully."
            else
                log $WARN "Initial policy fetch failed to complete."
            fi
        else
            log $WARN "Initial policy fetch lacks sufficient privileges - will be launched within 24 hours via cron."
        fi
    fi
    #
    # Clean everything up.
    #
    cleanup_tmp_files
fi

log $INFO "${SCRIPT} done."
# If PPID is 1, then systemd spawned the process
if is_child_of "crond" || [ $PPID -eq 1 ] ; then
    log $INFO "Cleaning up working directory ${WD}"
    rm -rf ${WD}
fi

exit 0
