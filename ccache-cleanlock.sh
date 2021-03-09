#!/usr/bin/env bash

# For shared ccache storage maintenance on a build farm: sometimes a system
# doing the builds dies or is rebooted/disconnected, or NFS username mapping
# acts up forbidding the locks to get removed... and then all subsequent runs
# of ccache (and/or gcc) stall waiting for the lock to disappear, lagging the
# CI farm builds a lot and sometimes even timing out the build/test jobs.
#
# This script helps to check if such case happened (with "list" argument),
# and allows to clean up automatically the stale lock files, optionally with
# a check that they are not referenced by a still-running process, if executed
# from the builder host.
#
# (C) 2015-2021 by Jim Klimov
#

set -o pipefail

LANG=C
LC_ALL=C
TZ=UTC
export TZ LANG LC_ALL

# How long can a decent compilation of one file take? Even on a truck worker?
# Complain (exit 42) in listing if we see lock files older than this (sec).
# Also do not remove lock files younger than this, only report them if seen.
[ -n "$TOO_OLD" ] && [ "$TOO_OLD" -ge 0 ] || TOO_OLD=120

# Hint: for a massive cleanup, can set CLEANHOST=. or another regex to match
# In worst cases, try: find . -name 'stats.lock*' -type l -exec rm -f '{}' \;
[ -n "${CHECKPROC-}" ] || CHECKPROC=true
[ -n "${CLEANHOST-}" ] && CHECKPROC=false && { if [ "${CLEANHOST}" = "`hostname`" ] ; then CHECKPROC=true ; fi; } || CLEANHOST="`hostname`"

# For build farm, the shared ccache is mounted centrally
#[ -n "${CCACHE_DIR}" ] || CCACHE_DIR="$HOME/.ccache/"
[ -n "${CCACHE_DIR}" ] || CCACHE_DIR="/mnt/.ccache/"

# User of OBS, defined to same UID on all build hosts (and storage server)
CCACHE_USER=abuild

# GNU date with '-d' is needed
GDATE="$(which gdate 2>/dev/null)"
if [ -z "$GDATE" ] || [ ! -x "$GDATE" ]; then
    GDATE=date # Hope for the best
fi

cleanfilter() {
    grep "$CLEANHOST" | awk '{print $13" "$11}' \
    | while IFS=' :'  read B P T F \
    ; do
        echo "$P $F"
        [ -n "$P" ] && {
            if $CHECKPROC && [ -d "/proc/$P/" ] ; then
                echo "=== SKIP '${CCACHE_DIR}/$F' : process $P still alive on $CLEANHOST"
            else
                echo "=== rm -f '${CCACHE_DIR}/$F'"
                rm -f "${CCACHE_DIR}/$F"
            fi
        }
    done
}

hostnamefilter() {
    # Just prints the hit-count of builder hostnames
    sed 's,^.*\.lock -> \([^:]*\):[0-9].*$,\1,' | sort | uniq -c
}

hostnamefilter_newest() (
    set +o pipefail
    # pick out names like  ui-builder-nodev6-11:933:1587486802 from stdin listing
    TABCHAR="`printf '\t'`"
    #TABCHAR='\t'
    sed -e 's,^.*\.lock ->,,' \
        -e 's,^[ '"${TABCHAR}"']*,,g' \
        -e 's,[ '"${TABCHAR}"']*$,,g' \
        -e 's,^\([^ '"${TABCHAR}"']*\)[ '"${TABCHAR}"'].*$,\1,' \
    | grep : | \
    (
        declare -A HOSTNAMES_COUNT
        declare -A HOSTNAMES_LATEST
        declare -A HOSTNAMES_OLDEST
        declare -A HOSTNAMES_OLDEST_PID
        OLDEST=-1
        LATEST=-1
        RES=0
        while IFS=: read B P T ; do
            HOSTNAMES_COUNT[$B]=$((${HOSTNAMES_COUNT[$B]} + 1))
            if [ -n "${HOSTNAMES_LATEST[$B]}" ] && [ "${HOSTNAMES_LATEST[$B]}" -gt "$T" ] \
            ; then : ; else HOSTNAMES_LATEST[$B]=$T ; fi
            if [ -n "${HOSTNAMES_OLDEST[$B]}" ] && [ "${HOSTNAMES_OLDEST[$B]}" -lt "$T" ] \
            ; then : ; else HOSTNAMES_OLDEST[$B]=$T ; HOSTNAMES_OLDEST_PID[$B]=$P; fi
            if [ "$T" -gt "$LATEST" ] ; then LATEST="$T" ; fi
            if [ "$T" -lt "$OLDEST" ] || [ "$OLDEST" = -1 ] ; then OLDEST="$T" ; fi
        done
        if [ "${#HOSTNAMES_COUNT[@]}" -gt 0 ]; then
            for B in $( echo "${!HOSTNAMES_COUNT[@]}" | tr ' ' '\n' | sort ); do
                printf '%6d\t%s\t%s\t%s\t%s\t%s\t%s\n' "${HOSTNAMES_COUNT[$B]}" \
                    "${HOSTNAMES_LATEST[$B]}" "`${GDATE} -u -d '1970-01-01 + '"${HOSTNAMES_LATEST[$B]}"' sec'`" \
                    "${HOSTNAMES_OLDEST[$B]}" "`${GDATE} -u -d '1970-01-01 + '"${HOSTNAMES_OLDEST[$B]}"' sec'`" \
                    "${HOSTNAMES_OLDEST_PID[$B]}" "$B"
            done
            NOW="`${GDATE} -u +%s`"
            printf '\n  NOW:\t%s\t%s\n' "$NOW"  "`${GDATE} -u -d '1970-01-01 + '"$NOW"' sec'`"
            if [ "$LATEST" -gt -1 ] ; then
                printf 'LATEST:\t%s\t%s\t~%s\n'  "$LATEST" "`${GDATE} -u -d '1970-01-01 + '"$LATEST"' sec'`" "$(($NOW - $LATEST))"
                if [ "$(($NOW - $LATEST))" -gt "$TOO_OLD" ] ; then RES=42 ; fi
            fi
            if [ "$OLDEST" -gt -1 ] ; then
                printf 'OLDEST:\t%s\t%s\t~%s\n'  "$OLDEST" "`${GDATE} -u -d '1970-01-01 + '"$OLDEST"' sec'`" "$(($NOW - $OLDEST))"
                if [ "$(($NOW - $OLDEST))" -gt "$TOO_OLD" ] ; then RES=42 ; fi
            fi
            if [ "$RES" = 0 ]; then
                echo "ALL OK: Some stale/recent lock files were found, but none were older than $TOO_OLD sec"
            else
                echo "FAILED: Some stale/recent lock files were found to be older than $TOO_OLD sec" >&2
            fi
        else
            echo "ALL OK: No (stale/recent) lock files found"
        fi
        exit $RES
    )
)

# Subprocesses for "cd"
# Find immediate subdirs
list_two() (
    cd ${CCACHE_DIR} && find . -maxdepth 2 -name '*.lock' -ls
)

# Subprocesses for "cd"
# Dig deeper
list_all() (
    cd ${CCACHE_DIR} && find . -name '*.lock' -ls
)

listing_header() {
    echo "If a hostname is reported more than a couple times, likely a stale file blocks others"
    echo "Then preferably:   ssh ${CCACHE_USER}@'<HOSTNAME>' '${CCACHE_DIR}/ccache-cleanlock.sh'"
    echo "Or worse on bios-backup:  CLEANHOST='<HOSTNAME>' CHECKPROC=false ${CCACHE_DIR}/ccache-cleanlock.sh"
    echo "Note that such clean up can take a LONG WHILE"
    echo ""
    echo "Looking for existing lock files in $1 subdir levels ..."
    printf "  COUNT\tNEWEST-TS\tEXPANDED_NEWEST_TIMESTAMP\tOLDEST-TS\tEXPANDED_OLDEST_TIMESTAMP\tOLDEST-PID\tCLEANHOST=\n"
    echo ""
}

case "$1" in
    ls-two|ls)
	echo "Listing all lock-files in nearest levels first..."
	list_two
	;;
    ls-all)
	echo "Listing all lock-files in nearest levels first..."
	list_two
	echo "Listing all lock-files in all levels..."
	list_all
	;;
    find|show|list|find-two|show-two|list-two)
	listing_header "nearest"
	list_two | hostnamefilter_newest
	;;
    find-all|show-all|list-all)
	listing_header "all"
	list_all | hostnamefilter_newest
	;;
    clean-two)
	echo "Cleaning for builder $CLEANHOST (with CHECKPROC=$CHECKPROC) in nearest levels..."
	list_two | cleanfilter
	;;
    clean|clean-all|'')
	echo "Cleaning for builder $CLEANHOST (with CHECKPROC=$CHECKPROC) in nearest levels first..."
	list_two | cleanfilter
	echo "Cleaning for builder $CLEANHOST (with CHECKPROC=$CHECKPROC) in all levels..."
	list_all | cleanfilter
	;;
    *)  echo "ERROR : Unknown argument '$1'" >&2
	listing_header "nearest"
	list_two | hostnamefilter_newest
	exit 1
	;;
esac
