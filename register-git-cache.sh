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
# Copyright 2018 (C) Jim Klimov <jimklimov@gmail.com>
# Shared on the terms of MIT license.
# Original development tracked at https://github.com/jimklimov/git-scripts
#

do_register_repo() {
    REPO="$1"
    [ -e .git ] || [ -s HEAD ] || ( git init --bare && git config gc.auto 0 ) || exit $?

    git remote -v | grep -i "$REPO" > /dev/null && echo "SKIP: Repo '$REPO' already registered" && return 0
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
    git remote -v | while read R U M ; do
        [ "$M" = '(fetch)' ] && \
        U_LC="`lc "$U"`" && \
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
                git remote -v | grep fetch | awk '{print $1" "$2}'
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

BIG_RES=0
LOCK="`dirname $0`/.gitcache.lock"
cd "`dirname $0`" || exit 1

if [ -z "$SKIP_LOCK" ] ; then
# Skipping is reserved for RO operations like listing, or for debugging the script
  while [ -s "$LOCK" ] ; do
    OLDPID="`head -1 "$LOCK"`"
    OLDHOST="`head -2 "$LOCK" | tail -1`"
    if [ -n "$OLDPID" ] && [ "$OLDPID" -gt 0 ] ; then
        echo "LOCKED by PID $OLDPID on $OLDHOST, waiting (export SKIP_LOCK=true to bypass in safe conditions)..."
        if [ "$OLDHOST" = "`hostname`" ]; then
            if [ ! -d "/proc/$OLDPID" ]; then
                echo "I am `hostname` and '/proc/$OLDPID' is absent, removing lock and waiting for up to 15 sec (maybe other copies will kick in)..."
                rm -f "$LOCK" ; sleep "`expr 5 + $$ % 10`"
            fi
        fi
        sleep 1
    fi
  done
  ( echo "$$" ; hostname ) > "$LOCK"
  trap 'rm -rf "$LOCK"' 0 1 2 3 15
fi

while [ $# -gt 0 ]; do
    case "$1" in
        help|-h|--help)
            cat << EOF
Usage:
$0 [add] REPO REPO ...
$0 { del | co } REPO_REGEX
$0 { list | ls } [REPO...]
$0 up [-v|-vs|-vp]
$0 up [-v|-vs|-vp] REPO REPO ...
where REPO are original remote repository URLs
EOF
            exit 0
            ;;
        list|ls)
            shift
            do_list_repoids "$@" ; exit $?
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
                lower_priority
                # Note: -jN parallelizes submodules, not remotes
                git fetch -f --all -j8 --prune --tags 2>/dev/null || \
                git fetch -f --all --prune --tags
            else
                shift
                do_fetch_repos "$@" ; exit $?
            fi
            ;;
        gc) git gc --prune=now ;;
        *)  echo "ERROR: Unrecognized argument: $1" >&2
            exit 1
            ;;
    esac
    shift
done

exit $BIG_RES
