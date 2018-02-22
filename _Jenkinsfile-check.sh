#!/bin/bash

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
[ -z "$JENKINSFILE" ] && JENKINSFILE="Jenkinsfile"

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
curl -s -H "`curl -s "$JENKINS_BASEURL/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,%22:%22,//crumb)"`" \
    -X POST --form "jenkinsfile=`cat "${JENKINSFILE}"`" \
    "$JENKINS_BASEURL/pipeline-model-converter/validateJenkinsfile"
}

default_request() {
    do_request
    printf "\n\n($?)\n"
}

normalize_errors() {
    OUT="`do_request 2>/dev/null`"
    echo "$OUT" | "$JSONSH" -x '"data","errors",0,"error",[0-9]+' | grep '"data","errors",0,"error",'
    if [ $? = 0 ]; then
        return 1
    else
        # grepped no errors
        echo "$OUT" | "$JSONSH" -x '"data","errors",0,"error"' | grep '"data","errors",0,"error"'
        if [ $? = 0 ]; then
            return 1
        fi
        return 0
    fi
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
    -j      pipe listing of errors through JSON.sh
    -b      if the report says syntax is OK, git-commit the bumped Jenkinsfile
    anything else for raw output
EOF
}

case "$1" in
    -h) usage ;;
    -j) normalize_errors ;;
    -b) bump_git ;;
    *)  default_request ;;
esac
