#!/bin/sh

# This script manages registration of remote git repositories
# in the current single workspace, to help faster CI clones
# with a git-reference. It shoud be instantiated on each worker
# or shared via NFS. The full pathname of the script should be
# available (as a copy or symlink) in the directory it would
# manage as the git reference/cache repository. After you
# register the repositories you want to track, you can call
# this script from a crontab to occasionally update the cache.
#
# For background, see e.g.
#   https://support.cloudbees.com/hc/en-us/articles/115001728812-Using-a-Git-reference-repository
#   https://randyfay.com/content/reference-cache-repositories-speed-clones-git-clone-reference
#   https://randyfay.com/content/git-clone-reference-considered-harmful   for some caveats
#
# Copyright 2018 (C) Jim Klimov <jimklimov@gmail.com>
# Shared on the terms of MIT license.
# Original development tracked at https://github.com/jimklimov/git-scripts
#

do_register_repo() {
    REPO="$1"
    [ -e .git ] || [ -s HEAD ] || ( git init --bare && git config gc.auto 0 ) || exit $?

    git remote -v | grep -i "$REPO" && echo "SKIP: Repo '$REPO' already registered" && return 0
    sleep 1 # ensure unique ID
    git remote add "repo-`date -u +%s`" "$REPO" && echo "OK: Registered repo '$REPO'"
}

do_unregister_repo() {
    REPO="$1"

    REPO_IDS="`git remote -v | grep -i "$REPO" | awk '{print $1}' | sort | uniq`" || REPO_IDS=""
    [ -z "$REPO_IDS" ] && echo "SKIP: Repo '$REPO' not registered" && return 0

    RES=0
    for REPO_ID in $REPO_IDS ; do
        git remote remove "$REPO_ID" || RES=$?
    done
    return $RES
}

lc() {
    echo "$*" | tr 'A-Z' 'a-z'
}

do_list_repoids() {
    git remote -v | while read I U M ; do
        [ "$M" = '(fetch)' ] && \
        U_LC="`lc "$U"`" && \
        for R in "$@" ; do
            if [ "`lc "$R"`" = "$U_LC" ]; then
                echo "$I"
            fi
        done
    done
}

do_fetch_repos() {
    if [ "$1" = "-v" ]; then
        shift
	if [ $# = 0 ]; then
            git remote -v | grep fetch | awk '{print $2}'
        else
            do_list_repoids "$@"
        fi | while read R ; do echo "=== $R:"; git fetch "$R" ; echo ""; done
        return $?
    fi

    git fetch --multiple `do_list_repoids "$@"`
}

BIG_RES=0
LOCK="`dirname $0`/.gitcache.lock"
cd "`dirname $0`" || exit 1

while [ -s "$LOCK" ] ; do
    OLDPID="`head -1 "$LOCK"`"
    if [ -n "$OLDPID" ] && [ "$OLDPID" -gt 0 ] && [ -d "/proc/$OLDPID" ]; then
        echo "LOCKED by PID $OLDPID, waiting..."
        sleep 1
    fi
done
echo "$$" > "$LOCK"
trap 'rm -rf "$LOCK"' 0 1 2 3 15

while [ $# -gt 0 ]; do
    case "$1" in
	help|-h|--help)
	    cat << EOF
Usage:
$0 [add] REPO REPO ...
$0 { del | co } REPO_REGEX
$0 up [-v]
$0 up [-v] REPO REPO ...
EOF
	    exit 0
	    ;;
        git@*|ssh://*|https://*|http://*)
            do_register_repo "$1" || BIG_RES=$?
            ;;
        add)
            do_register_repo "$2" || BIG_RES=$?
            shift
            ;;
        clone|checkout|co)
            do_register_repo "$2" \
            && do_fetch_repos "$2" \
            || BIG_RES=$?
            shift
            ;;
        del|delete|remove|rm)
            do_unregister_repo "$2" || BIG_RES=$?
            shift
            ;;
        fetch|update|pull|up)
            if [ "$#" = 1 ]; then
                git fetch --all -P4 --prune 2>/dev/null || \
                git fetch --all --prune
            else
                shift
                do_fetch_repos "$@" && git gc --prune=now ; exit $?
            fi
            ;;
        *)  echo "ERROR: Unrecognized argument: $1" >&2
            exit 1
            ;;
    esac
    shift
done

exit $BIG_RES
