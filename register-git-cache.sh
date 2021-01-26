#!/usr/bin/env bash

# NOTE: bash syntax used, e.g. `;&` to fall through case statements
# Does not work in other /bin/sh handlers like dash!

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
# In particular, note that usage of reference repositories does its magic by
# having a newly cloned (and later updated?) repository refer to bits of code
# present in some filesystem path, rather than make a copy from the original
# remote repository again - so saving network, disk space and maybe time.
# Corollaries:
# * the reference repo should be in the filesystem (maybe over NFS) and
#   at the same locally resolved FS path if shared across build agents
# * the reference repo should be at least readable to the build account
#   when used in Jenkins
# * files (and contents inside) should not disappear or be renamed over
#   time (garbage collection, pruning, etc. do that) or the cloned repo
#   will become invalid (not a big issue for workspaces that made a build
#   in the past and are not reused as such, but may be a problem to remake
#   the same run without extra rituals to create a coherent checkout;
#   not sure if this is also a problem for reusing the workspace for later
#   runs of a job, with same or other commits)
# ** there is a "git disassociate" command for making a workspace standalone
#   again, by copying into it the data from a reference repo - forfeiting
#   the disk savings, but keeping the network/time improvements probably;
#   this is not integrated into Jenkins Git client side, AFAIK
# * the advanced option to use a reference repo is only applied during
#   cloning - existing workspaces must be remade to try it out
#
# This script also aims to help maintain a fanout of reference repositories
# hosted under a single directory, as proposed for improving performance in
# Jenkins jobs using a single configuration (e.g. generated from OrgFolders):
#   https://issues.jenkins.io/browse/JENKINS-64383
#   https://github.com/jenkinsci/git-client-plugin/pull/644
# For this support, it adds the following environment variables to fork and
# work in a determined sub-directory, applied if REFREPODIR_MODE is not empty:
# * REFREPODIR_BASE - location of the top-level refrepo (where this script
#   or symlink to it is located, by default)
# * REFREPODIR - location of the refrepo determined for the Git URL
# * REFREPODIR_MODE using a suffix defined in PR#644 above:
#   GIT_URL_BASENAME = subdir named by "basename" of normalized repo URL
#   GIT_URL_SHA256 = subdir named by hash of normalized repo URL
#   GIT_SUBMODULES = sha256 if present, or basename otherwise (here we
#       use bare repo on top, so real submodules are not handled directly)
#   GIT_URL = subdir tree named verbatim by normalized repo URL (not portable)
#   GIT_*_FALLBACK = if dir named above is not present, use REFREPODIR_BASE
# The new method get_subrepo_dir() can be used to determine in script code
# whether such forking should be used for adding or updating a Git URL: if
# it returns a success and not-empty string, that is the dir to (make and)
# change into for the actual git operations for that one Git URL.
#
# Copyright 2018-2021 (C) Jim Klimov <jimklimov@gmail.com>
# Shared on the terms of MIT license.
# Original development tracked at https://github.com/jimklimov/git-scripts
#

if [ "$DEBUG" = true ]; then
    set -x
fi

if [ -n "${REFREPODIR-}" ]; then
    # Up to the caller (including recursion with REFREPODIR_MODE options)
    # to make sure the request is valid (especially for relative paths!)
    cd "${REFREPODIR}" || { echo "FATAL: REFREPODIR='$REFREPODIR' was specified but not usable" >&2 ; exit 1; }
    if [ -z "${REFREPODIR_BASE-}" ] ; then
        echo "WARNING: REFREPODIR_BASE for the parent is not specified, would use REFREPODIR as the top level" >&2
        REFREPODIR_BASE="`pwd`"
    fi
else
    # With empty REFREPODIR, this script instance is not recursing now.
    # If a valid REFREPODIR_MODE is not empty, it will recurse for git ops.
    cd "`dirname $0`" || exit 1
    REFREPODIR_BASE="`pwd`"
    export REFREPODIR_BASE
fi

# This file can list line by line shell-glob (case) patterns to avoid addition
# of certain URLs (e.g. by automated jobs parsing a history of build setups,
# including references to SCM server instances that no longer exist).
EXCEPT_PATTERNS_FILE="${REFREPODIR_BASE}/.except"
[ -n "${QUIET_SKIP-}" ] || QUIET_SKIP=no

is_repo_excluded() {
    # Returns 0 if we can go on registering/processing; 1 to skip this repo
    local REPO
    REPO="$1"

    if [ ! -s "$EXCEPT_PATTERNS_FILE" ] || [ "$SKIP_EXCEPT_PATTERNS_FILE" = true ] ; then
        # No exceptions
        return 0
    fi

    while read PAT ; do
        [ -n "$PAT" ] || continue
        case "$REPO" in
            "#"*) continue ;;
            $PAT) [ "${QUIET_SKIP-}" = yes ] || echo "SKIP: Repo '$REPO' excluded by pattern '$PAT'" >&2 ; return 1 ;;
        esac
    done < "$EXCEPT_PATTERNS_FILE"

    # None of defined exceptions matched this repo
    return 0
}

# Track unique repos we have registered now
declare -A REGISTERED_NOW
do_register_repo() {
    # REPO is a substring from `git remote` listing,
    # so technically can be an ID or part of URL (but
    # only a single complete URL makes sense for adding)
    local REPO
    REPO="$1"
    [ -e .git ] || [ -s HEAD ] || \
        ( echo "=== Initializing bare repository for git references at `pwd` ..." ; \
          git init --bare && git config gc.auto 0 ) || exit $?

    [ "${REGISTERED_NOW["$REPO"]}" = 1 ] \
        && { [ "${QUIET_SKIP-}" = yes ] || echo "SKIP: Repo '$REPO' already registered during this run" ; } \
        && return 42

    is_repo_excluded "$REPO" || return 0 # not a fatal error, just a skip (reported there)
    git remote -v | grep -i "$REPO" > /dev/null && echo "SKIP: Repo '$REPO' already registered" && return 0

    sleep 1 # ensure unique ID
    local REPOID="repo-`date -u +%s`"
    git remote add "$REPOID" "$REPO" \
    && git remote set-url --push "$REPOID" no_push \
    && echo "OK: Registered repo '$REPOID' => '$REPO'" \
    && REGISTERED_NOW["$REPO"]=1
#?#    && REGISTERED_NOW["$REPOID"]="$REPO"
}

do_list_remotes() {
    # For each arg, do git-ls-remote - List references in a remote repository
    # (NOT listing of known remote repo IDs - see do_list_repoids() for that)
    ( for REPO in "$@" ; do
        echo "===== Listing remotes of '$REPO'..." >&2
        is_repo_excluded "$REPO" || continue # not a fatal error, just a skip (reported there)
        git ls-remote "$REPO" | awk '{print $1}' &
      done ; wait) | sort | uniq
}

do_list_subrepos() {
    ( # List all unique branches/tags etc. known in the repo(s) from argument,
      # and from each branch, get a .gitmodules if any and URLs from it:
        for HASH in `do_list_remotes "$@"` ; do
            ( echo "===== Checking submodules (if any) under tip hash '$HASH'..." >&2
              git show "${HASH}:.gitmodules" 2>/dev/null | grep -w url ) &
        done
    wait ) \
    | tr -d ' \t' | GREP_OPTIONS= egrep '^url=' | sed -e 's,^url=,,' | sort | uniq
    # ...in the end, return all unique Git URLs registered as git submodules
}

declare -A REGISTERED_RECURSIVELY_NOW
do_register_repos_recursive() {
    # Register each repo URL and dig into all branches' `.gitmodules` file to recurse
    # Note a REPO may be something already registered, then we just look for submodules
    # Note: If recursing for nested refrepos (not-empty REFREPODIR_MODE),
    # we may need to only fork to process each one child repo - but go back
    # into parent to track all URLs we have processed to avoid doing them
    # more than once. Maybe also can need to avoid the LOCK on parent dir?..
    local REPO SUBREPO
    local RES=0
    local _RES=0
    local RECURSE_MODE="all"

    if [ $# = 0 ]; then return 0; fi

    case "$1" in
        all|new) RECURSE_MODE="$1"; shift ;;
    esac

    local REPO_LIST TOPREPO_LIST
    declare -a REPO_LIST
    declare -a TOPREPO_LIST
    for REPO in "$@" ; do
        [ "${REGISTERED_RECURSIVELY_NOW["$REPO"]}" = 1 ] \
        && { [ "${QUIET_SKIP-}" = yes ] || echo "SKIP: '$REPO' was already inspected recursively during this run" >&2 ; } \
        || { is_repo_excluded "$REPO" && TOPREPO_LIST+=( "$REPO" ) ; }
        # Note: is_repo_excluded() returns 0 to go on processing the repo
    done

    # First register the nearest-level repos
    for REPO in "${TOPREPO_LIST[@]}" ; do
        echo "=== Register '$REPO' or see if it is already here..."
        do_register_repo "$REPO" || { _RES=$?; [ "${_RES}" = 42 ] || RES="${_RES}"; continue ; }
        REGISTERED_RECURSIVELY_NOW["$REPO"]=1

        case "$RECURSE_MODE" in
            new) # we would only recurse into repo URLs previously not known
                if [ "${REGISTERED_NOW["$REPO"]}" = 1 ] ; then
                    REPO_LIST+=( "$REPO" )
                fi
                ;;
            all) # will recurse into all known repos to check for new branches etc.
                REPO_LIST+=( "$REPO" ) ;;
        esac

        if [ "$DO_FETCH" = false ] && [ "${REGISTERED_NOW["$REPO"]}" != 1 ] ; then
            echo "=== Not fetching '$REPO' contents (it existed and caller says it was recently refreshed)..."
        else
            # We need the (recent) contents to look into .gitmodules files later
            echo "=== Fetch '$REPO' contents..."
            do_fetch_repos "$REPO" || { RES=$?; continue ; }
        fi
    done

    # Then look inside for unique submodule URLs
    for SUBREPO in `do_list_subrepos "${REPO_LIST[@]}"`; do
        echo "===== Recursively register '$SUBREPO'..."
        do_register_repos_recursive "$RECURSE_MODE" "$SUBREPO" || RES=$?
    done

    return $RES
}

do_unregister_repo() {
    # REPO is a substring from `git remote` listing,
    # so can be part of an ID or URL
    local REPO
    REPO="$1"

    REPO_IDS="`git remote -v | GREP_OPTIONS= grep -i "$REPO" | awk '{print $1}' | sort | uniq`" || REPO_IDS=""
    [ -z "$REPO_IDS" ] && echo "SKIP: Repo '$REPO' not registered" && return 0

    RES=0
    for REPO_ID in $REPO_IDS ; do
        echo "=== Unregistering repository ID '$REPO_ID' ..."
        git remote remove "$REPO_ID" || RES=$?
    done
    return $RES
}

lc() {
    echo "$*" | tr 'A-Z' 'a-z'
}

lower_priority() {
    # Do not bring the system down by bursting dozens (or more) of
    # git clients... Though not a critical failure if we can not.
    # TODO : Use GNU parallel or somesuch?
    renice -n +5 $$ || true
}

do_list_repoids() {
    # Optional arguments are a list of URLs that must match exactly
    # (.git extension included) though case-insensitively to be listed.
    # Returns the git remote repo names (e.g. repo-1536929947 here) and
    # the original URL.
    git remote -v | \
    ( if [ $# = 0 ]; then cat ; else
        # Maybe `echo "$@" | tr ' ' '|' is even better?
        # This could however fall victim to whitespaces in URLs,
        # double-whitespaces, etc. :\
        RE="`printf "$1"; shift; while [ $# -gt 0 ]; do printf "|${1}"; shift; done`"
        grep -E "$RE"
      fi
    ) | \
    while read R U M ; do
        [ "$M" = '(fetch)' ] && \
        U_LC="`lc "$U"`" && \
        { is_repo_excluded "$U_LC" || continue # not a fatal error, just a skip (reported there)
        } && \
        if [ $# = 0 ]; then
            printf '%s\t%s\n' "$R" "$U"
        else
            for UU in "$@" ; do
                if [ "`lc "$UU"`" = "$U_LC" ]; then
                    printf '%s\t%s\n' "$R" "$U"
                fi
            done
        fi
    done
}

do_fetch_repos_verbose_seq() (
    # Fetches repos listed on stdin and reports, sequentially
    # -f allows to force-update references to remote current state (e.g. floating tags)
    RES=0
    while read R U ; do
        [ -n "$U" ] || U="$R"
        echo "=== $U ($R):"
        is_repo_excluded "$U" || continue # not a fatal error, just a skip (reported there)

        git fetch -f --progress "$R" '+refs/heads/*:refs/remotes/'"$R"'/*' \
        && git fetch -f --tags --progress "$R" \
        || { RES=$? ; echo "FAILED TO FETCH : $U ($R)" >&2 ; }
        echo ""
    done
    exit $RES
)

do_fetch_repos_verbose_par() (
    # Fetches repos listed on stdin and reports, in parallel. NOTE:
    # * can complete faster than seq, but with messier output
    # * no job control for multiple children so far
    # -f allows to force-update references to remote current state (e.g. floating tags)
    RES=0
    while read R U ; do
        [ -n "$U" ] || U="$R"
        is_repo_excluded "$U" || continue # not a fatal error, just a skip (reported there)

        echo "=== Starting $U ($R) in background..."
        ( git fetch -f "$R" '+refs/heads/*:refs/remotes/'"$R"'/*' \
          && git fetch -f --tags "$R" \
          || { RES=$? ; echo "FAILED TO FETCH : $U ($R)" >&2 ; exit $RES; }
          echo "===== Completed $U ($R)" ; ) &
        echo ""
    done
    wait || RES=$?
    exit $RES
)

do_fetch_repos() {
    FETCHER="do_fetch_repos_verbose_seq"
    case "$1" in
        -vp) FETCHER="do_fetch_repos_verbose_par"
            lower_priority
            ;& # fall through
        -vs|-v)
            shift
            if [ $# = 0 ]; then
                git remote -v | GREP_OPTIONS= grep fetch | awk '{print $1" "$2}'
            else
                do_list_repoids "$@"
            fi | $FETCHER
            return $?
            ;;
    esac

    # Non-verbose default mode:
    # TODO: Can we pass a refspec to fetch all branches here?
    # Or should we follow up with another fetch (like verbose)?
    git fetch -f --multiple --tags `do_list_repoids "$@" | awk '{print $1}'`
}

normalize_git_url() {
    # Perform Git URL normalization similar to that in JENKINS-64383 solution
    local REPO="$1"
    local REPONORM="`echo "$REPO" | tr 'A-Z' 'a-z' | sed -e 's,\.git$,,'`"

    case "${REPONORM}" in
        *://*) ;;
        /*) REPONORM="file://`echo "${REPONORM}" | sed -e 's,/\./,/,g' -e 's,//*,/,g'`" ;;
        *)  REPONORM="file://$(echo "`pwd`/${REPONORM}" | sed -e 's,/\./,/,g' -e 's,//*,/,g')" ;;
    esac

    echo "$REPONORM"
}

get_subrepo_dir() {
    # Returns a sub-directory name (relative to parent workspace) determined
    # by rules similar to those for JENKINS-64383 solution for hosting several
    # reference repositories with smaller scopes under one common configured
    # location. The caller should check if the directory exists before using
    # it; non-zero return codes are for errors determining the path name.
    # A currently non-existent name return in some contexts may be something
    # to `mkdir` for example.
    local REPO="$1"
    local REPONORM="`normalize_git_url "$REPO"`"
    local SUBREPO_DIR=""

    # Compatibility with JENKINS-64383 solution
    case "${REFREPODIR_MODE}" in
        "") return 2 ;; # Standalone run
        GIT_URL|'${GIT_URL}'|GIT_URL_FALLBACK|'${GIT_URL_FALLBACK}')
            # Note this can include non-portable FS characters like ":"
            SUBREPO_DIR="${REPONORM}"
            ;;
        GIT_URL_BASENAME|'${GIT_URL_BASENAME}'|GIT_URL_BASENAME_FALLBACK|'${GIT_URL_BASENAME_FALLBACK}')
            SUBREPO_DIR="`basename "$REPONORM"`"
            ;;
        GIT_URL_SHA256|'${GIT_URL_SHA256}'|GIT_URL_SHA256_FALLBACK|'${GIT_URL_SHA256_FALLBACK}')
            SUBREPO_DIR="`echo "$REPONORM" | sha256sum | cut -d' ' -f1`"
            ;;
        GIT_SUBMODULES|'${GIT_SUBMODULES}'|GIT_SUBMODULES_FALLBACK|'${GIT_SUBMODULES_FALLBACK}')
            # Simplified matcher logic for best expectations from JENKINS-64383
            SUBREPO_DIR="`echo "$REPONORM" | sha256sum | cut -d' ' -f1`"
            [ -d "$SUBREPO_DIR" ] || [ -d "$SUBREPO_DIR.git" ] \
            || SUBREPO_DIR="`basename "$REPONORM"`"
            ;;
        *)  echo "WARNING: Unsupported mode REFREPODIR_MODE='$REFREPODIR_MODE'" >&2
            return 3
            ;;
    esac

    if [ -n "${SUBREPO_DIR}" ] ; then
        [ -e "${SUBREPO_DIR}/.git" -o -e "${SUBREPO_DIR}/objects" ] || SUBREPO_DIR="${SUBREPO_DIR}.git"
    fi

    case "${REFREPODIR_MODE}" in
        GIT_*_FALLBACK|'${GIT_'*'_FALLBACK}')
            if [ -n "${SUBREPO_DIR}" ] && [ -e "${SUBREPO_DIR}/.git" -o -e "${SUBREPO_DIR}/objects" ] ; then
                : # No fallback needed
            else
                # Exported below if this script is recursing or running at top level
                SUBREPO_DIR="${REFREPODIR_BASE-}"
            fi
            ;;
    esac

    [ -n "${SUBREPO_DIR}" ] \
    && echo "${SUBREPO_DIR}" \
    || return 1
}

BIG_RES=0
DID_UPDATE=false

# Note: assumes the script running user may write to the refrepo dir tree
if [ -n "${REFREPODIR-}" ] && [ -d "${REFREPODIR-}" ]; then
    LOCK="${REFREPODIR}/.gitcache.lock"
else
    LOCK="`dirname $0`/.gitcache.lock"
fi

if [ -z "$SKIP_LOCK" ] && [ "$1" != "--dev-test" ] ; then
# Skipping is reserved for RO operations like listing, or for debugging the script
  while [ -s "$LOCK" ] ; do
    OLDPID="`head -1 "$LOCK"`"
    OLDHOST="`head -2 "$LOCK" | tail -1`"
    if [ "$OLDPID" = "admin-lock" ] ; then
        if [ "$1" = "unlock" ]; then
            echo "`date -u`: [$$]: WAS LOCKED by administrator on $OLDHOST, unlocking now..." >&2
            rm -f "$LOCK"
            shift
        else
            echo "`date -u`: [$$]: LOCKED by administrator on $OLDHOST, use '$0 unlock' to clear this lock" >&2
            sleep 1
        fi
    else
        if [ -n "$OLDPID" ] && [ "$OLDPID" -gt 0 ] ; then
            echo "`date -u`: [$$]: LOCKED by PID $OLDPID on $OLDHOST, waiting (export SKIP_LOCK=true to bypass in safe conditions)..." >&2
            if [ "$OLDHOST" = "`hostname`" ]; then
                if [ ! -d "/proc/$OLDPID" ]; then
                    echo "I am `hostname` and '/proc/$OLDPID' is absent, removing lock and waiting for up to 15 sec (maybe other copies will kick in)..."
                    rm -f "$LOCK" ; sleep "`expr 5 + $$ % 10`"
                fi
            fi
            sleep 1
        fi
    fi
  done
  ( echo "$$" ; hostname ) > "$LOCK"
  trap 'rm -rf "$LOCK"' 0 1 2 3 15
fi

ACTIONS=""
while [ $# -gt 0 ]; do
    [ -z "$ACTIONS" ] && ACTIONS="$1" || ACTIONS="$ACTIONS $1"

    case "$1" in
        help|-h|--help)
            cat << EOF
Usage:
$0 [add] REPO_URL [REPO_URL...]
$0 add-recursive [new|all] REPO_URL [REPO_URL...] => register repo (if not yet),
                            fetch its contents, and do same for submodules (if any)
$0 { list | ls | ls-recursive } [REPO_URL...]
$0 up [-v|-vs|-vp] [REPO_URL...]      => fetch new commits
$0 co REPO_URL                        => register + fetch
$0 del REPO_GLOB                      => unregister
where REPO_URL are singular original exact remote repository URLs
and REPO_GLOB matches by substring of 'git remote -v' output

$0 { repack | repack-parallel | gc }  => maintenance operations
$0 { lock | unlock }  => admin lock to not disturb during maintenance
EOF
            exit 0
            ;;
        unlock) ;; # No-op, processed above if applicable
        lock) echo "admin-lock" > "$LOCK" ;;
        list|ls)
            shift
            if [ "$#" = 0 ]; then
                do_list_repoids ; exit $?
            else
                QUIET_SKIP=yes do_list_repoids "$@" ; exit $?
            fi
            ;;
        list-recursive|ls-recursive|lsr)
            shift
            if [ "$#" = 0 ]; then
                do_list_subrepos ; exit $?
            else
                QUIET_SKIP=yes do_list_subrepos "$@" ; exit $?
            fi
            ;;
        git@*|ssh://*|https://*|http://*)
            do_register_repo "$1" || BIG_RES=$?
            DID_UPDATE=true
            ;;
        add)
            do_register_repo "$2" || BIG_RES=$?
            DID_UPDATE=true
            shift
            ;;
        add-recursive)
            shift
            # Note: also fetches contents to dig into submodules
            do_register_repos_recursive "$@" || BIG_RES=$?
            DID_UPDATE=true
            shift $#
            ;;
        clone|checkout|co)
            do_register_repo "$2" \
            && do_fetch_repos "$2" \
            || BIG_RES=$?
            DID_UPDATE=true
            shift
            ;;
        del|delete|remove|rm)
            do_unregister_repo "$2" || BIG_RES=$?
            DID_UPDATE=true
            shift
            ;;
        fetch|update|pull|up)
            if [ "$#" = 1 ]; then
                lower_priority
                # Note: -jN parallelizes submodules, not remotes
                # Note: this can bypass EXCEPT_PATTERNS_FILE
                git fetch -f --all -j8 --prune --tags 2>/dev/null || \
                git fetch -f --all --prune --tags
            else
                shift
                QUIET_SKIP=yes do_fetch_repos "$@" || BIG_RES=$?
                shift $#
            fi
            DID_UPDATE=true
            ;;
        gc) git gc --prune=now || BIG_RES=$?
            DID_UPDATE=true
            ;;
        repack) git repack -A -d || BIG_RES=$?
            DID_UPDATE=true
            ;;
        repack-parallel) git repack -A -d --threads=0 || BIG_RES=$?
            DID_UPDATE=true
            ;;
        --dev-test)
            shift
            echo "Dev-testing a routine: $*" >&2
            [ $# -gt 0 ] || exit
            "$@" || BIG_RES=$?
            echo "Dev-test completed with code $BIG_RES" >&2
            exit $BIG_RES
            ;;
        *)  echo "ERROR: Unrecognized argument: $1" >&2
            exit 1
            ;;
    esac
    shift
done

if "$DID_UPDATE" && [ -d ./.zfs ] ; then
    SNAPDATE="`TZ=UTC date -u +%Y%m%dT%H%M%SZ`" && [ -n "$SNAPNAME" ] \
    || { SNAPDATE="`date -u +%s`" ; }
    SNAPNAME="rgc-auto-${SNAPDATE}_res-${BIG_RES}_actions-${ACTIONS}"
    SNAPNAME="`echo "$SNAPNAME" | tr ' ' '-'`"
    echo "ZFS: Trying to snapshot `pwd` as '@${SNAPNAME}' ..." >&2
    mkdir -p .zfs/snapshot/"$SNAPNAME" \
    || echo "WARNING: Could not 'zfs snapshot'; did you 'zfs allow -ldu $USER snapshot POOL/DATASET/NAME' on the storage server?" >&2
fi

if [ "${#REGISTERED_NOW[@]}" -gt 0 ]; then
    echo "During this run, registered the following new REPO_URL(s): ${!REGISTERED_NOW[@]}"
fi

exit $BIG_RES
