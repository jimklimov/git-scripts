#!/bin/bash
set -o pipefail

# A simple command-line parser that calls Jenkins REST API to validate syntax
# of a Jenkinsfile - helps get it "right" in the first approximation without
# hundreds of commits to try to build and run it. Or to update it when the
# (currently unreleased) Pipeline API syntax changes yet again ;)
#
# Run it from the workspace with the tested Jenkinsfile in current directory.
# Save sensitive config in ./.jenkinsfile-check or ~/.jenkinsfile-check
#
# Note that there are also other ways to achieve this or similar goal; this
# one is just the simple tool I use as long as it suffices ;)
# See also https://github.com/jenkinsci/pipeline-model-definition-plugin/wiki/Validating-(or-linting)-a-Declarative-Jenkinsfile-from-the-command-line
#
# Copyright (C) 2016-2018 by Jim Klimov

# Components for the URL below; override via ./.jenkinsfile-check in the repo
# (DO NOT git commit this file though!) or in ~/.jenkinsfile-check if you only
# have one (preferred) Jenkins to test against anyway.
JENKINS_USER="username"
JENKINS_PASS="my%2Fpass"
JENKINS_HOST="localhost"
JENKINS_PORT="8080"
JENKINS_ROOT="jenkins"

# Default pipeline script filename is Jenkinsfile, but some repos can host
# multiple pipeline scripts so they would be named differently
[ -z "$JENKINSFILE" ] && JENKINSFILE="Jenkinsfile" \
&& echo "NOTE: Using default JENKINSFILE='$JENKINSFILE' - if you want to test another, pass the envvar from caller"

# A copy of https://github.com/jimklimov/JSON.sh/blob/master/JSON.sh
# is used for normalize_errors() aka "-j" argument
# Note this has some needed differences from the upstream version!
JSONSH=JSON.sh
{ [ -x "`dirname $0`/JSON.sh" ] && JSONSH="`dirname $0`/JSON.sh"; } || \
{ [ -x "./JSON.sh" ] && JSONSH="./JSON.sh"; } || \
{ (which JSON.sh 2>/dev/null >/dev/null) && JSONSH="`which JSON.sh`" ; }

[ -f "${HOME}/.jenkinsfile-check" ] && source "${HOME}/.jenkinsfile-check"
[ -f .jenkinsfile-check ] && source .jenkinsfile-check

[ -z "$JENKINS_BASEURL" ] && \
    JENKINS_BASEURL="http://$JENKINS_USER:$JENKINS_PASS@$JENKINS_HOST:$JENKINS_PORT/$JENKINS_ROOT"

do_request() {
    CRUMB="`curl -k -v "$JENKINS_BASEURL/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,%22:%22,//crumb)"`" || CRUMB=""
    echo "$CRUMB" | grep -w 404 >/dev/null && CRUMB=""
    [ -n "$CRUMB" ] || echo "NOTE : Did not get a crumb, so will not use one"

    curl -k -v ${CRUMB:+H "$CRUMB"} \
        -X POST --form "jenkinsfile=<${JENKINSFILE}" \
        "$JENKINS_BASEURL/pipeline-model-converter/validateJenkinsfile"
}

default_request() {
    do_request ; REQ_RES=$?
    printf "\n\n($REQ_RES)\n"
    return $REQ_RES
}

normalize_errors() {
    OUT="`do_request 2>/dev/null`" ; REQ_RES=$?
    if [ "$REQ_RES" != 0 ]; then
        echo "REQUEST to REST API has failed ($REQ_RES)! Dump of data follows:"
        echo "====="
        echo "$OUT"
        echo "====="
        return $REQ_RES
    fi >&2

    JSON_OUT="`echo "$OUT" | "$JSONSH" -x '"data","errors",0,"error",[0-9]+'`"
    if [ $? != 0 ]; then
        echo "FAILED to parse REST API output as JSON markup! Dump of data follows:"
        echo "====="
        echo "$OUT"
        echo "====="
        return 2
    fi >&2

    [ -n "$JSON_OUT" ] && echo "$JSON_OUT" | grep '"data","errors",0,"error",'
    if [ $? = 0 ]; then
        # got a hit
        return 1
    else
        # grepped no errors, try another pattern
        JSON_OUT="`echo "$OUT" | "$JSONSH" -x '"data","errors",0,"error"'`"
        if [ $? != 0 ]; then
            echo "FAILED to parse REST API output as JSON markup! Dump of data follows:"
            echo "====="
            echo "$OUT"
            echo "====="
            return 2
        fi >&2
        [ -n "$JSON_OUT" ] && echo "$JSON_OUT" | grep '"data","errors",0,"error"'
        if [ $? = 0 ]; then
            # got a hit
            return 1
        fi
    fi

    echo "SUCCESS: No errors reported against this pipeline script!" >&2
    # got no hits
    return 0
}

bump_git() {
    OUT="`default_request`"

    if echo "$OUT" | grep '"data":{"result":"success"}}' ; then
        git add "${JENKINSFILE}" \
        && git commit -m "Bump ${JENKINSFILE} pipeline script" \
        && echo "COMMITTED OK, you can 'git push' any time now"
    else
        echo "$OUT"
        echo "VALIDATION FAILED" >&2
        return 1
    fi
}

usage() {
    cat << EOF
    -j      pipe listing of errors through JSON.sh (detect error reports)
    -b      if the report says syntax is OK, git-commit the bumped Jenkinsfile
    anything else for raw output of the REST API - no interpretation of content
EOF
}

case "$1" in
    -h) usage ;;
    -j) normalize_errors ;;
    -b) bump_git ;;
    *)  default_request ;;
esac
