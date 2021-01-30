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

# Just prepend $CI_TIME to a command line to optionally profile it:
case "${CI_TIME-}" in
    time|time_wrapper|*/time) ;;
    [Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]) CI_TIME="time_wrapper" ;;
    *) CI_TIME="" ;;
esac

# Should we dig into loops (more data, more impact from collecting it)?
case "${CI_TIME_LOOPS-}" in
    [Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]) CI_TIME_LOOPS="true" ;;
    *) CI_TIME_LOOPS="false" ;;
esac

if [ "${DEBUG-}" = true ]; then
    set -x
else
    DEBUG=false
fi

# NOTE: Currently all the support happens without extra recursion,
# so maybe this varname will be dropped.
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
case "${QUIET_SKIP-}" in
    [Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]) QUIET_SKIP=true ;;
    *) QUIET_SKIP=false ;;
esac

# Throttling inspired by https://stackoverflow.com/a/8735146/4715872
# TODO? Detect from CPU count
[ -n "$MAXJOBS" ] && [ "$MAXJOBS" -gt 0 ] \
|| MAXJOBS=8
throttle_running_child_count() {
    local SLEPT=false
    while [ "`jobs -pr | wc -l`" -ge $MAXJOBS ]; do
        sleep 0.1
        SLEPT=true
    done
    if $SLEPT && ( $DEBUG || [ -n "$CI_TIME" ] ) ; then
        echo "[D] `date`: Was blocked due to child subprocessess, now proceeding" >&2
    fi
}

# Detect a time-stamping capable (GNU) date in the current system
for GDATE in ${GDATE-} gdate date false ; do
    D="`$GDATE -u +%s 2>/dev/null`" && [ -n "$D" ] && [ "$D" -gt 0 ] && break
done
if [ "$GDATE" = false ]; then GDATE=""; fi

time_wrapper() {
    local TS_START=0
    local TS_END=0
    local SUB_RES=0
    local TS_TEXT=''
    [ -z "$GDATE" ] || TS_START="`$GDATE -u +%s`"
    time "$@" || SUB_RES=$?
    [ -z "$GDATE" ] || { TS_END="`$GDATE -u +%s`" ; TS_TEXT=" after $(($TS_END - $TS_START)) whole seconds"; }
    echo "[D] `date`: Completed command with code ${SUB_RES}${TS_TEXT} in dir '`pwd`': $*" >&2
    return $SUB_RES
}

declare -A KNOWN_EXCLUDED
is_repo_not_excluded() {
    # Returns 0 if we can go on registering/processing; 1 to skip this repo
    local REPO
    REPO="$1"

    if [ "${KNOWN_EXCLUDED["$REPO"]-}" = 1 ] ; then
        return 1
    fi

    if [ ! -s "$EXCEPT_PATTERNS_FILE" ] || [ "$SKIP_EXCEPT_PATTERNS_FILE" = true ] ; then
        # No exceptions
        return 0
    fi

    while read PAT ; do
        [ -n "$PAT" ] || continue
        case "$REPO" in
            "#"*) continue ;;
            $PAT)
                $QUIET_SKIP || echo "SKIP: Repo '$REPO' excluded by pattern '$PAT'" >&2
                KNOWN_EXCLUDED["$REPO"]=1
                return 1
                ;;
        esac
    done < "$EXCEPT_PATTERNS_FILE"

    # None of defined exceptions matched this repo
    return 0
}

# Track unique repos we have registered now
declare -A REGISTERED_NOW
declare -A REGISTERED_EARLIER
do_register_repo() {
    # REPO is a substring from `git remote` listing,
    # so technically can be an ID or part of URL (but
    # only a single complete URL makes sense for adding)
    local REPO
    REPO="$1"

    [ "${REGISTERED_NOW["$REPO"]}" = 1 ] \
        && { $QUIET_SKIP || echo "SKIP: Repo '$REPO' already registered during this run" ; } \
        && return 42

    [ "${REGISTERED_EARLIER["$REPO"]}" = 1 ] \
        && { $QUIET_SKIP || echo "SKIP: Repo '$REPO' was registered earlier and already seen during this run" ; } \
        && return 0

    is_repo_not_excluded "$REPO" || return 0 # being excluded is not a fatal error, just a skip (reported there)

    local REFREPODIR_REPO
    [ -n "${REFREPODIR_MODE-}" ] && REFREPODIR_REPO="`get_subrepo_dir "$REPO"`" \
        && { mkdir -p "${REFREPODIR_REPO}" && pushd "${REFREPODIR_BASE}/${REFREPODIR_REPO}" >/dev/null && trap 'popd >/dev/null ; trap - RETURN' RETURN || exit $? ; }

    [ -e .git ] || [ -s HEAD ] || \
        ( echo "[I] `date`: === Initializing bare repository for git references at `pwd` ..." ; \
          $CI_TIME git init --bare && $CI_TIME git config gc.auto 0 ) || exit $?

    $CI_TIME git remote -v | grep -i "$REPO" > /dev/null \
    && echo "SKIP: Repo '$REPO' already registered in `pwd`" \
    && REGISTERED_EARLIER["${REPO}"]=1 \
    && REGISTERED_EARLIER["${REPO} `pwd`"]=1 \
    && return 0

    sleep 1 # ensure unique ID
    local REPOID="repo-`date -u +%s`"
    $CI_TIME git remote add "$REPOID" "$REPO" \
    && $CI_TIME git remote set-url --push "$REPOID" no_push \
    && echo "[I] `date`: OK: Registered repo '$REPOID' => '$REPO' in `pwd`" \
    && REGISTERED_NOW["$REPO"]=1
#?#    && REGISTERED_NOW["$REPOID"]="$REPO"
}

do_list_remotes() {
    # For each arg, do git-ls-remote - List references in a remote repository
    # (NOT listing of known remote repo IDs - see do_list_repoids() for that)
    local TS_START=0
    local TS_END=0
    local TS_TEXT=''

    if [ -n "$CI_TIME" ]; then
        [ -z "$GDATE" ] || TS_START="`$GDATE -u +%s`"
        echo "[D] `date`: Discovering references from any tip commit of repo(s): $*" >&2
    fi

    ( TEMPDIR_REMOTES="`mktemp -d --tmpdir rgc.XXXXXX`" && [ -n "$TEMPDIR_REMOTES" ] && [ -d "$TEMPDIR_REMOTES" ] || TEMPDIR_REMOTES=""
      if [ -n "$TEMPDIR_REMOTES" ] ; then
        # Absolutize to be sure
        TEMPDIR_REMOTES="$(cd "$TEMPDIR_REMOTES" && pwd)"
        #trap 'echo "do_list_remotes(): REMOVING TEMPDIR_REMOTES=$TEMPDIR_REMOTES">&2 && rm -rf "$TEMPDIR_REMOTES"' 0
        trap 'rm -rf "$TEMPDIR_REMOTES"' 0
      else
        echo "do_list_remotes(): Failed to create TEMPDIR_REMOTES" >&2
        exit 1
      fi
      # Temp files proved crucial to not mix up stdout's from parallel child
      # processes which happened sometimes in the original implementation

      for REPO in "$@" ; do
        echo "[I] `date`: ===== Listing remotes of '$REPO'..." >&2
        is_repo_not_excluded "$REPO" || continue # not a fatal error, just a skip (reported there)
        (
            local REFREPODIR_REPO=''
            [ -n "${REFREPODIR_MODE-}" ] && REFREPODIR_REPO="`get_subrepo_dir "$REPO"`" \
                && { pushd "${REFREPODIR_BASE}/${REFREPODIR_REPO}" >/dev/null || exit $? ; }
            { $CI_TIME git ls-remote "$REPO" || echo "[I] `date`: FAILED to 'git ls-remote $REPO' in '`pwd`'">&2 ; } \
                | awk -v REPODIR="${REFREPODIR_REPO}" -v REPO="${REPO}" '{print $1"\t"$2"\t"REPODIR"\t"REPO}' \
                > "`mktemp --tmpdir="$TEMPDIR_REMOTES" remote-refs.XXXXXXXXXXXX`"
            # Note: the trailing column is empty for discoveries/runs without REFREPODIR
            # And we ignore here faults like absent remotes... or invalid Git dirs...
        ) &
        throttle_running_child_count
      done
      if [ -n "$CI_TIME" ]; then
          echo "[D] `date`: Waiting for subprocesses for discovery of references from any tip commit of repo(s): $*" >&2
      fi
      wait
      $CI_TIME sync
      if [ -n "`ls -1 "${TEMPDIR_REMOTES}/"`" ]; then
          cat "$TEMPDIR_REMOTES"/* || true
          if $CI_TIME_LOOPS || $DEBUG; then
              echo "[D] `date`: Dumping raw discovery of git-references data:" >&2
              cat "${TEMPDIR_REMOTES}/"* >&2
          fi
      fi
      if [ -n "$CI_TIME" ]; then
          echo "[D] `date`: Completed raw discovery of references from any tip commit of repo(s): $*" >&2
      fi
    ) | sort | uniq
    if [ -n "$CI_TIME" ]; then
        [ -z "$GDATE" ] || { TS_END="`$GDATE -u +%s`" ; TS_TEXT=" after $(($TS_END - $TS_START)) whole seconds"; }
        echo "[D] `date`: Finished discovering and filtering references from any tip commit of repo(s)${TS_TEXT}: $*" >&2
    fi
}

do_list_subrepos() {
    local TS_START=0
    local TS_END=0
    local TS_TEXT=''

    if [ -n "$CI_TIME" ]; then
        [ -z "$GDATE" ] || TS_START="`$GDATE -u +%s`"
        echo "[D] `date`: Discovering submodules (if any) referenced from any tip commit of repo(s): $*" >&2
    fi

    ( # List all unique branches/tags etc. known in the repo(s) from argument,
      # and from each branch, get a .gitmodules if any and URLs from it:
        TEMPDIR_SUBURLS="`mktemp -d --tmpdir="$TEMPDIR_BASE" subrepos.$$.XXXXXXXX`" && [ -n "$TEMPDIR_SUBURLS" ] && [ -d "$TEMPDIR_SUBURLS" ] || TEMPDIR_SUBURLS=""
        if [ -n "$TEMPDIR_SUBURLS" ] ; then
            # Absolutize to be sure
            TEMPDIR_SUBURLS="$(cd "$TEMPDIR_SUBURLS" && pwd)"
            #trap 'echo "do_list_subrepos(): REMOVING TEMPDIR_SUBURLS=$TEMPDIR_SUBURLS">&2 && rm -rf "$TEMPDIR_SUBURLS"' 0
            trap 'rm -rf "$TEMPDIR_SUBURLS"' 0
        else
            echo "do_list_subrepos(): Failed to create TEMPDIR_SUBURLS" >&2
            exit 1
        fi

        do_list_remotes "$@" | while IFS="`printf '\t'`" read HASH GITREF REFREPODIR_REPO REPOURL ; do
            echo "===== Will check submodules (if any) under tip hash '$HASH' => '$GITREF' $REFREPODIR_REPO $REPOURL..." >&2
            # After pretty reporting, constrain the list to unique items for inspection
            echo "$HASH $REFREPODIR_REPO"
        done | sort | uniq | \
        ( local FIRSTLOOP=true
          declare -A PREEXISTING_MODDATA
          for F in $(cd ${TEMPDIR_BASE}/ && ls -1) ; do
            PREEXISTING_MODDATA["$F"]=1
          done
          while read HASH REFREPODIR_REPO ; do
            # This should fire only after stdin pours in - when sort|uniq
            # pipes are done and "under tip" log above no longer streams
            $FIRSTLOOP && echo "[D] `date`: Searching commits listed above (if any) for unique URLs from .gitmodules (if any)..." >&2
            FIRSTLOOP=false
            # Avoid forking thousands of subshells if we can:
            if [[ -v PREEXISTING_MODDATA["${HASH}:.gitmodules-urls"] ]] ; then
                # Already existed before
                $CI_TIME_LOOPS && echo "[D] ${HASH} was pre-existing" >&2
                if [ -s "${TEMPDIR_BASE}/${HASH}:.gitmodules-urls" ] && [ ! -e "${TEMPDIR_SUBURLS}/${HASH}:.gitmodules-urls" ] ; then
                    # Do not link to empty files to cat them below
                    ln "${TEMPDIR_BASE}/${HASH}:.gitmodules-urls" "${TEMPDIR_SUBURLS}/"
                fi
            else
            (   $CI_TIME_LOOPS && echo "[D] ${HASH} not pre-existing" >&2

                # Note the 'test -e': here we assume that a file creation
                # and population attempt was successful as an atomic operation
                # and even if it is empty, that is a definitive final status
                if \
                       [ -e "${TEMPDIR_BASE}/${HASH}:.gitmodules-urls" ] \
                    || [ -e "${TEMPDIR_BASE}/${HASH}:.gitmodules-urls.tmp" ] \
                ; then
                    # Made recently, or is being parsed by another thread now
                    if $CI_TIME_LOOPS; then
                        echo "[D] `date`: ======= NOT Checking submodules (if any) under tip hash '$HASH' '`pwd`' / '$REFREPODIR_REPO' - results already filed" >&2
                    fi
                else
                    # Not existing before, not made recently nor being made now by another thread (.tmp)
                    trap 'rm -f "${TEMPDIR_BASE}/${HASH}:.gitmodules-urls.tmp" || true' 0
                    [ -n "${REFREPODIR_REPO}" ] \
                        && { pushd "${REFREPODIR_BASE}/${REFREPODIR_REPO}" >/dev/null || exit $? ; }
                    if $CI_TIME_LOOPS ; then
                        echo "[D] `date`: ======= Checking submodules (if any) under tip hash '$HASH' '`pwd`' / '$REFREPODIR_REPO'..." >&2
                        $CI_TIME git show "${HASH}:.gitmodules"
                    else
                        git show "${HASH}:.gitmodules" 2>/dev/null
                    fi \
                        | sed -e 's,[ \t\r\n]*,,g' -e '/^url=/!d' -e 's,^url=,,' \
                        > "${TEMPDIR_BASE}/${HASH}:.gitmodules-urls.tmp" \
                        && mv -f "${TEMPDIR_BASE}/${HASH}:.gitmodules-urls.tmp" "${TEMPDIR_BASE}/${HASH}:.gitmodules-urls"
                    # If we did not succeed for whatever reason, no final file should appear
                    rm -f "${TEMPDIR_BASE}/${HASH}:.gitmodules-urls.tmp" || true
                fi

                if [ -s "${TEMPDIR_BASE}/${HASH}:.gitmodules-urls" ] && [ ! -e "${TEMPDIR_SUBURLS}/${HASH}:.gitmodules-urls" ] ; then
                    # Do not link to empty files to cat them below
                    ln "${TEMPDIR_BASE}/${HASH}:.gitmodules-urls" "${TEMPDIR_SUBURLS}/"
                fi
            ) &
            throttle_running_child_count
            fi
          done
        )
        if [ -n "$CI_TIME" ]; then
            echo "[D] `date`: Waiting for subprocesses for discovery of submodules (if any) referenced from any tip commit of repo(s): $*" >&2
        fi
        wait
        $CI_TIME sync
        if [ -n "`ls -1 "${TEMPDIR_SUBURLS}/"`" ]; then
            cat "${TEMPDIR_SUBURLS}/"*:.gitmodules-urls
            if $CI_TIME_LOOPS || $DEBUG; then
                echo "[D] `date`: Dumping raw discovery of submodules data:" >&2
                cat "${TEMPDIR_SUBURLS}/"*:.gitmodules-urls >&2
            fi
        fi
        if [ -n "$CI_TIME" ]; then
            echo "[D] `date`: Completed raw discovery of submodules (if any) referenced from any tip commit of repo(s): $*" >&2
        fi
    ) | sort | uniq
    if [ -n "$CI_TIME" ]; then
        [ -z "$GDATE" ] || { TS_END="`$GDATE -u +%s`" ; TS_TEXT=" after $(($TS_END - $TS_START)) whole seconds"; }
        echo "[D] `date`: Finished discovering and filtering submodules (if any) referenced from any tip commit of repo(s)${TS_TEXT}: $*" >&2
    fi
    # ...in the end, return all unique Git URLs registered as git submodules
}

# Track which repos (URLs) we have inspected during the recursion -
# whether new registrations or previously existing population, here:
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
    local TS_START=0
    local TS_END=0
    local TS_TEXT=''

    [ -z "$GDATE" ] || TS_START="`$GDATE -u +%s`"

    # Exit recursion; for call to refresh all already registered URLs pass $1=="all"
    if [ $# = 0 ]; then return 0; fi

    case "$1" in
        all|new) RECURSE_MODE="$1"; shift ;;
    esac

    local REPO_LIST TOPREPO_LIST
    declare -a REPO_LIST
    declare -a TOPREPO_LIST

    if [ $# = 0 ]; then
        # A special case for top-level recursive handler from CLI:
        # recursive calls would have a RECURSE_MODE and another arg
        # (even if that would be an empty token).
        echo "Caller specified a RECURSE_MODE as the only argument, so list all known Git URLs and refresh submodules that they might reference" >&2
        if [ "$DO_FETCH" = false ] ; then
            echo "Caller asked to not re-fetch Git URLs already registered - probably they were recently refreshed in a separate call" >&2
        else
            echo "[I] `date`: === Fetch all known repositories' contents for recursion analysis..." >&2
            do_fetch_repos || RES=$?
        fi
        REPO_LIST+=( `QUIET_SKIP=true do_list_repoids | awk '{print $2}' | sort | uniq` )
        echo "Discovered the following currently-known Git URLs for further recursion: ${REPO_LIST[*]}" >&2
        if [ "${#REPO_LIST[@]}" = 0 ]; then
            echo "FAILED: No Git URLs found under `pwd`, aborting the recursive inspection" >&2
            return 1
        fi
    else
        if [ -n "$CI_TIME" ]; then
            echo "[D] `date`: Recursing into possible submodules of repo URL(s): $*" >&2
        fi
        for REPO in "$@" ; do
            [ "${REGISTERED_RECURSIVELY_NOW["$REPO"]}" = 1 ] \
            && { $QUIET_SKIP || echo "SKIP: '$REPO' was already inspected recursively during this run" >&2 ; } \
            || { is_repo_not_excluded "$REPO" && TOPREPO_LIST+=( "$REPO" ) ; }
            # Note: is_repo_not_excluded() returns 0 to go on processing the repo
        done

        # First register the nearest-level repos
        for REPO in "${TOPREPO_LIST[@]}" ; do
            # Repos disliked by exclude pattern were filtered away above, as
            # well as repos already visited in other recursion codepaths.
            # Other repos that existed earlier we want to dig into, except for
            # code 42 (means skip because already registered during this run,
            # as a double failsafe precaution - e.g. listed twice in CLI args):
            echo "[I] `date`: === Register '$REPO' or see if it is already here..." >&2
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
                echo "[I] `date`: === Not fetching '$REPO' contents (it existed and caller says it was recently refreshed)..." >&2
            else
                # We need the (recent) contents to look into .gitmodules files later
                echo "[I] `date`: === Fetch '$REPO' contents for recursion analysis..." >&2
                do_fetch_repos "$REPO" || RES=$?
            fi
        done
    fi

    # Above we have selected some Git URLs that whose contents we did
    # not investigate yet; here we look inside for unique submodule URLs
    # and recurse this routine into such URLs. Note that if there are
    # no new URLs referenced by submodules since last iteration, there
    # should be no recursion for a parameterless run that checks "all".
    #
    # TODO?: For REFREPODIR_MODE, group repos in same directory to
    # check and dedup their likely-crossing hashes once and for all
    # (currently dropped from do_list_repoids()|awk... lookup above)
    for SUBREPO in `do_list_subrepos "${REPO_LIST[@]}"`; do
        # Avoid recursing to speed up - lots of operations there we know we would do in vain
        if [ "${REGISTERED_RECURSIVELY_NOW["$SUBREPO"]}" = 1 ] ; then
            $QUIET_SKIP || echo "SKIP: '$SUBREPO' was already inspected recursively during this run and got requested again" >&2
            continue
        fi
        echo "[I] `date`: ===== Recursively register '$SUBREPO'..." >&2
        do_register_repos_recursive "$RECURSE_MODE" "$SUBREPO" || RES=$?
        # Now we've certainly handled this URL:
        REGISTERED_RECURSIVELY_NOW["$SUBREPO"]=1
    done

    if [ -n "$CI_TIME" ]; then
        [ -z "$GDATE" ] || { TS_END="`$GDATE -u +%s`" ; TS_TEXT=" after $(($TS_END - $TS_START)) whole seconds"; }
        echo "[D] `date`: Finished ($RES) recursing into possible submodules of repo URL(s)${TS_TEXT}: $*" >&2
    fi

    return $RES
}

do_unregister_repo() {
    # REPO is a substring from `git remote` listing,
    # so can be part of an ID or URL
    local REPO REPO_IDS REPO_ID
    REPO="$1"

    local REFREPODIR_REPO
    [ -n "${REFREPODIR_MODE-}" ] && REFREPODIR_REPO="`get_subrepo_dir "$REPO"`" \
        && { pushd "${REFREPODIR_BASE}/${REFREPODIR_REPO}" >/dev/null && trap 'popd >/dev/null ; trap - RETURN' RETURN || return $? ; }

    # There may happen to be several registrations for same URL
    REPO_IDS="`$CI_TIME git remote -v | GREP_OPTIONS= grep -i "$REPO" | awk '{print $1}' | sort | uniq`" || REPO_IDS=""
    [ -z "$REPO_IDS" ] && echo "SKIP: Repo '$REPO' not registered in `pwd`" && return 0

    RES=0
    for REPO_ID in $REPO_IDS ; do
        echo "[I] `date`: === Unregistering repository ID '$REPO_ID' from `pwd`..."
        $CI_TIME git remote remove "$REPO_ID" || RES=$?
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
    # TODO: Cleaner handling of REFREPODIR_* cases (e.g. match only $@
    # provided dirs, if any)?..
    if [ -n "$CI_TIME" ]; then
        echo "[D] `date`: Listing repoid's and locations for repo URL(s): $*" >&2
    fi
    ( $CI_TIME git remote -v || echo "FAILED to 'git remote -v' in '`pwd`'">&2
      if [ -n "${REFREPODIR_MODE-}" ] ; then
        for DG in `ls -1d "${REFREPODIR_BASE-}"/*/.git "${REFREPODIR_BASE-}"/*/objects 2>/dev/null` ; do
            ( D="`dirname "$DG"`" && cd "$D" && { $CI_TIME git remote -v || echo "FAILED to 'git remote -v' in '`pwd`'">&2 ; } | sed 's,$, '"`basename "$D"`," )
        done
      fi
    ) | \
    ( if [ $# = 0 ]; then cat ; else
        # Maybe `echo "$@" | tr ' ' '|' is even better?
        # This could however fall victim to whitespaces in URLs,
        # double-whitespaces, etc. :\
        RE="`printf '%s' "$1"; shift; while [ $# -gt 0 ]; do printf '%s' "|${1}"; shift; done`"
        grep -E "$RE"
      fi
    ) | \
    while read R U M D ; do
        [ "$M" = '(fetch)' ] || continue
        U_LC="`lc "$U"`" || continue
        is_repo_not_excluded "$U_LC" || continue # not a fatal error, just a skip (reported there)

        if [ $# = 0 ]; then
            printf '%s\t%s\t%s\n' "$R" "$U" "$D"
        else
            for UU in "$@" ; do
                if [ "`lc "$UU"`" = "$U_LC" ]; then
                    printf '%s\t%s\t%s\n' "$R" "$U" "$D"
                fi
            done
        fi
    done
    if [ -n "$CI_TIME" ]; then
        echo "[D] `date`: Finished listing repoid's and locations for repo URL(s): $*" >&2
    fi
}

do_fetch_repos_verbose_seq() (
    # Fetches repos listed on stdin and reports, sequentially
    # -f allows to force-update references to remote current state (e.g. floating tags)
    RES=0
    while read R U D; do
        [ -n "$U" ] || U="$R"
        echo "=== (fetcher:verbose:seq) $U ($R):" >&2
        is_repo_not_excluded "$U" || continue # not a fatal error, just a skip (reported there)

        (   local REFREPODIR_REPO="$D"
            { [ -n "${REFREPODIR_REPO}" ] || \
              { [ -n "${REFREPODIR_MODE-}" ] && REFREPODIR_REPO="`get_subrepo_dir "$U"`" ; } ; } \
                && { pushd "${REFREPODIR_BASE}/${REFREPODIR_REPO}" >/dev/null || exit $? ; }
            echo "[I] `date`: === (fetcher:verbose:seq) Starting $U ($R) in `pwd` :" >&2
            $CI_TIME git fetch -f --progress "$R" '+refs/heads/*:refs/remotes/'"$R"'/*' \
                && $CI_TIME git fetch -f --tags --progress "$R" \
                && echo "[I] `date`: ===== (fetcher:verbose:seq) Completed $U ($R) in `pwd`" >&2
        ) || { RES=$? ; echo "[I] `date`: (fetcher:verbose:seq) FAILED TO FETCH : $U ($R)" >&2 ; }
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
    while read R U D ; do
        [ -n "$U" ] || U="$R"
        is_repo_not_excluded "$U" || continue # not a fatal error, just a skip (reported there)

        (   local REFREPODIR_REPO="$D"
            { [ -n "${REFREPODIR_REPO}" ] || \
              { [ -n "${REFREPODIR_MODE-}" ] && REFREPODIR_REPO="`get_subrepo_dir "$U"`" ; } ; } \
                && { pushd "${REFREPODIR_BASE}/${REFREPODIR_REPO}" >/dev/null || exit $? ; }
            echo "[I] `date`: === (fetcher:verbose:par) Starting $U ($R) in `pwd` in background..." >&2
            $CI_TIME git fetch -f --progress "$R" '+refs/heads/*:refs/remotes/'"$R"'/*' \
                && $CI_TIME git fetch -f --tags --progress "$R" \
                || { RES=$? ; echo "[I] `date`: (fetcher:verbose:par) FAILED TO FETCH : $U ($R) in `pwd` in background" >&2 ; exit $RES; }
            echo "[I] `date`: ===== (fetcher:verbose:par) Completed $U ($R) in `pwd` in background" >&2
        ) &
        throttle_running_child_count
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
            if [ $# = 0 ] && [ -z "${REFREPODIR_MODE-}" ] ; then
                $CI_TIME git remote -v | GREP_OPTIONS= grep fetch | awk '{print $1" "$2}'
            else
                if [ -z "${REFREPODIR_MODE-}" ] ; then
                    do_list_repoids "$@"
                else
                    # Reverse sort, to prioritize presumed-smaller-scope (faster) repos in subdirs
                    do_list_repoids "$@" | sort -k3r
                fi
            fi | $FETCHER
            return $?
            ;;
    esac

    # Non-verbose default mode:
    # TODO: Can we pass a refspec to fetch all branches here?
    # Or should we follow up with another fetch (like verbose)?
    if [ -z "${REFREPODIR_MODE-}" ] ; then
        echo "[I] `date`: === (fetcher:default:seq) Processing refrepo dir '`pwd`': $*" >&2
        $CI_TIME git fetch -f --multiple --tags `do_list_repoids "$@" | awk '{print $1}'`
    else
        local R U D
        local D_='.'
        local R_=''
        local RES=0

        # Reverse sort, to prioritize presumed-smaller-scope (faster) repos in subdirs
        ( do_list_repoids "$@" | sort -k3r | uniq ; echo '. . .' ) | \
        ( RESw=0
          # Track which repo URLs we have already fetched in specific-scoped
          # subdirs, to not refetch those URLs in the root-dir wad (we keep
          # it for history for now, but it is very slow to manage, even for
          # its own updating fetches). So unconverted consumers might still
          # use this directory, but if we deal with REFREPODIR mode then no
          # point maintaining it for URLs handled by subdirs (no consumers
          # expected really). It can be fully updated separately, by a run
          # without REFREPODIR_MODE setting from caller.
          declare -A FETCHED_REPO
          while read R U D ; do
            if [ "$D" = "$D_" ] ; then
                if [ -z "${FETCHED_REPO["$U"]-}" ]; then
                    R_="$R_ $R"
                    FETCHED_REPO["$U"]="$D"
                else
                    echo "===== (fetcher:default) SKIP: Git URL '$U' was already considered for subdirectory '${FETCHED_REPO["$U"]}' - not re-fetching into '$D'" >&2
                fi
            else
                # Hit a new value in directory column, fetch the list collected
                # for previous dir if any ('.' here is the starting value of D_)
                if [ "$D_" != '.' ]; then
                    ( [ -n "$D_" ] || D_="${REFREPODIR_BASE}"
                      if [ -z "$R_" ]; then
                          echo "===== (fetcher:default) SKIP: Git URL list is empty after selection - not re-fetching into '$D_'" >&2
                          exit 0 # just exiting a subprocess here
                      fi
                      echo "[I] `date`: ===== (fetcher:default:par) Processing refrepo dir '$D_': $R_" >&2
                      cd "$D_" || exit
                      $CI_TIME git fetch -f -j8 --multiple --tags $R_ || \
                      { echo "[I] `date`: ======= (fetcher:default:seq) Retry sequentially refrepo dir '$D_': $R_" >&2 ;
                        $CI_TIME git fetch -f --multiple --tags $R_ ; }
                    ) || RESw=$?
                fi
                if [ "$D" = '.' ]; then
                    # Sentinel entry '. . .' was hit
                    break
                fi

                # Initialize next loop (or the first loop ever)
                echo "[I] `date`: === (fetcher:default) Preparing filtered list of Git URLs for dir '$D'..." >&2
                D_="$D"
                if [ -z "${FETCHED_REPO["$U"]-}" ]; then
                    R_="$R"
                    FETCHED_REPO["$U"]="$D"
                else
                    R_=''
                    echo "===== (fetcher:default) SKIP: Git URL '$U' was already considered for subdirectory '${FETCHED_REPO["$U"]}' - not re-fetching into '$D'" >&2
                fi
            fi
          done
          exit $RESw
        ) || RES=$?
        return $RES
    fi
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

# We actually want to retain data in TEMPDIR_BASE to avoid discovering
# it from same commit hashes again and again
# TODO: Garbage-collection in TEMPDIR_BASE as we would change HEADs,
# delete repos, known old pulls, tags and/or branches etc. over time?
TEMPDIR_BASE="${REFREPODIR_BASE}/.git.cache.rgc"
# Absolutize to be sure
mkdir -p "$TEMPDIR_BASE"
TEMPDIR_BASE="$(cd "$TEMPDIR_BASE" && pwd)"
rm -f "${TEMPDIR_BASE}"/*.tmp || true

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
$0 up-all                             => fetch new commits for all registered
                                         repos (including those URLs normally
                                         skipped by .exclude patterns if any)
$0 co REPO_URL                        => register + fetch
$0 del REPO_GLOB                      => unregister
$0 dedup-references [REPO_URL...]     => unregister URLs that are listed many
                                         times (e.g. when converting to fanout)
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
                QUIET_SKIP=true do_list_repoids "$@" ; exit $?
            fi
            ;;
        list-recursive|ls-recursive|lsr)
            shift
            if [ "$#" = 0 ]; then
                do_list_subrepos ; exit $?
            else
                QUIET_SKIP=true do_list_subrepos "$@" ; exit $?
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
            # Note: also fetches contents to dig into submodules,
            # unless DO_FETCH=false is specified
            if [ $# = 0 ]; then
                do_register_repos_recursive all || BIG_RES=$?
            else
                # Assume list of Git URLs; note it can be prohibitively long for shell interpreter limits
                do_register_repos_recursive "$@" || BIG_RES=$?
                shift $#
            fi
            DID_UPDATE=true
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
        fetch-all|update-all|pull-all|up-all)
            lower_priority
            # Note: -jN parallelizes submodules, not remotes
            # Note: this can bypass EXCEPT_PATTERNS_FILE
            if [ -n "${REFREPODIR_MODE-}" ] ; then
                # Prioritize presumed smaller-scoped refrepos in subdirs that should complete faster
                for DG in `ls -1d "${REFREPODIR_BASE-}"/*/.git "${REFREPODIR_BASE-}"/*/objects 2>/dev/null` ; do
                    ( D="`dirname "$DG"`"
                      cd "$D" || exit
                      echo "[I] `date`: === (fetcher:default:all) Processing refrepo dir '$D':" >&2
                        $CI_TIME git fetch -f --all -j8 --prune --tags 2>/dev/null || \
                        { echo "[I] `date`: ===== (fetcher:default:all) Retry sequentially refrepo dir '$D_':" >&2 ;
                          $CI_TIME git fetch -f --all --prune --tags ; }
                    )
                done
            fi
            echo "[I] `date`: === (fetcher:default:all) Processing refrepo dir '`pwd`':" >&2
            $CI_TIME git fetch -f --all -j8 --prune --tags 2>/dev/null || \
            { echo "[I] `date`: ===== (fetcher:default:all) Retry sequentially refrepo dir '`pwd`':" >&2 ;
              $CI_TIME git fetch -f --all --prune --tags ; }
            DID_UPDATE=true
            ;;
        fetch|update|pull|up)
            shift
            QUIET_SKIP=true do_fetch_repos "$@" || BIG_RES=$?
            shift $#
            DID_UPDATE=true
            ;;
        gc) $CI_TIME git gc --prune=now || BIG_RES=$?
            if [ -n "${REFREPODIR_MODE-}" ] ; then
                for DG in `ls -1d "${REFREPODIR_BASE-}"/*/.git "${REFREPODIR_BASE-}"/*/objects 2>/dev/null` ; do
                    ( cd "`dirname "$DG"`" && $CI_TIME git gc --prune=now ) || BIG_RES=$?
                done
            fi
            DID_UPDATE=true
            ;;
        repack) $CI_TIME git repack -A -d || BIG_RES=$?
            if [ -n "${REFREPODIR_MODE-}" ] ; then
                for DG in `ls -1d "${REFREPODIR_BASE-}"/*/.git "${REFREPODIR_BASE-}"/*/objects 2>/dev/null` ; do
                    ( cd "`dirname "$DG"`" && $CI_TIME git repack -A -d ) || BIG_RES=$?
                done
            fi
            DID_UPDATE=true
            ;;
        repack-parallel) $CI_TIME git repack -A -d --threads=0 || BIG_RES=$?
            # This assumes parallel compression, so each subrepo can be sequential
            if [ -n "${REFREPODIR_MODE-}" ] ; then
                for DG in `ls -1d "${REFREPODIR_BASE-}"/*/.git "${REFREPODIR_BASE-}"/*/objects 2>/dev/null` ; do
                    ( cd "`dirname "$DG"`" && $CI_TIME git repack -A -d --threads=0 ) || BIG_RES=$?
                done
            fi
            DID_UPDATE=true
            ;;
        dedup-references)
            shift
            # Group by (2) URL first, then by (3) non-trivial directories first
            # and empty basedir last, finally by (1) repoid so the oldest ID is
            # seen first in the selection per dir and URL.
            # This way newest redundant submissions are killed off.
            do_list_repoids "$@" | sort  -k2,2 -k3,3r -k1,1n | \
            (   RP=''; UP='';
                while read R U D; do
                    if [ "$U" = "$UP" ]; then
                        echo "[I] `date`: drop '$R' => '$U' in '$D'" >&2
                        ( [ -z "$D" ] || { cd "$D" || exit; }
                          $CI_TIME git remote remove "$R"
                        )
                    else
                        echo "[I] `date`: retain '$R' => '$U' in '$D'" >&2
                    fi
                    UP="$U"
                done
            )
            DID_UPDATE=true
            shift $#
            ;;
        --dev-test)
            shift
            echo "[I] `date`: Dev-testing a routine: $*" >&2
            [ $# -gt 0 ] || exit
            "$@" || BIG_RES=$?
            echo "[I] `date`: Dev-test completed with code $BIG_RES" >&2
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
    echo "[I] `date`: ZFS: Trying to snapshot `pwd` as '@${SNAPNAME}' ..." >&2
    mkdir -p .zfs/snapshot/"$SNAPNAME" \
    || echo "WARNING: Could not 'zfs snapshot'; did you 'zfs allow -ldu $USER snapshot POOL/DATASET/NAME' on the storage server?" >&2
fi

if [ "${#REGISTERED_NOW[@]}" -gt 0 ]; then
    echo "[I] `date`: During this run, registered the following new REPO_URL(s): ${!REGISTERED_NOW[@]}"
fi

exit $BIG_RES
