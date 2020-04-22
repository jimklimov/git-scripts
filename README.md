# git-scripts
Scripts to automate my working patterns with Git repositories

* `git-pull-ff` -- this script pulls any updates from configured remotes, and
attempts a fast-forward merge of the current workspace with its counterparts.

* `git-sync` -- this script first pushes any updates from local repository to
remote repos (except `upstream`), then does a `git pull-ff` to receive any
missing updates from the remotes.

* `git-merge-um` -- this script pulls updates from remote repos and tries to
merge the remote `upstream/master` (configurable) int the current workspace
branch, and optionally tries to rebase the workspace over the `upstream/master`
state.

* `git-zclone` -- uses ZFS to clone a dataset which contains a Git repository,
then rewrites some metadata in the new clone (reference to `origin`, NetBeans
project metadata, etc.) In effect this should yield similar results to local
filesystem-based `git clone`, except that with ZFS cloning, anything present
in the workspace dataset is cloned (such as old build products) unless you
add `--wipe -f` to the command-line. You can also automatically link to the
chosen `upstream` repo during initial cloning of your `origin`, following the
github-fork-clone model to get a workspace. I use this a lot lately, so the
typical command-line for such activity is, for reference, simply this:
````
:; git zclone https://github.com/user/repo.git "" -U https://github.com/project/repo.git
````

* `git-branchkill` -- helps clean up local workspaces (that share an upstream)
from proliferation of development branches, especially as those are getting
merged into a common upstream and are no longer needed separately.

* `git-meld` -- wraps usage of a difference-viewing program such as `meld`
(can be customized by setting `DIFFVIEWER` envvar in e.g. user profile) as
the one-time renderer for `git diff` requests. May be irrelevant as there is
a `git mergetool` wrapper (as I found later), but this one is still shorter ;)

* `git-branch-alias` -- a recent addition, and not mine to start with (kudos
go to Phil Sainty), this Git extension allows to reference branches by another
name. Think of all tools and habits that expect a `master` branch and hiccup
on an `oi/hipster` ;) I took Phil's script from his StackOverflow post and
just added links to his posts and a `bash` shebang.

* `git-dig-history` -- this allows to search and even rewrite the git repo
history, looking for a specified PATTERN. Use-cases include replacement of
sensitive data (e.g. avoid password leaking when a project gets opensourced)
and looking for commits related to a keyword you are trying to track down.

As with any other Git methods, it suffices that these scripts are available in
your `PATH` (e.g. in `$USER/bin`, or symlinked to `/usr/bin`, etc.) and then
they can be called as `git method-name`, such as `git zclone ws1 /tmp/buildws`.

* `git retimestamp` -- a PoC script to change timestamps of the most-recent
`BACK` commits in your branch, rewinding each by `OFFSET` (e.g. `-3 days`).

* `git reauthor` -- a PoC script to change authorship of the most-recent `BACK`
commits in your branch, changing to `$COMMIT_USER_NAME <$COMMIT_USER_EMAIL>`
and optionally filtering to only change commits originally owned by matches
to regex `$COMMIT_USER_FILTER`. Intended to fix up code initially developed
and tested "in vivo" on final deployments without proper git setup attributing
changes to certain persons.

# Other related automation scripts

* The `_Jenkinsfile-check.sh` is an odd addition to the bunch: it is not (yet)
a git method. This script allows to validate a `Jenkinsfile` that can automate
your CI pipelines (instructions stored and tracked as code, rather than results
of GUI clicks). It has an option however to "bump" the successfully passed file
by committing it into the git repository, so (after a push) it will be used to
drive actual builds and tests. This requires Jenkins REST API to to the actual
tests, and the credentials to access the CI application server instance can be
stored in a config file.

* The `register-git-cache.sh` script also is not (yet?) a git method.
This script is here to allow managing a git repository in the directory it
resides in as a sort of cache, usable as a reference git repo for faster
clones e.g. in a CI environment.

* The `ccache-cleanlock.sh` is not a git-related script. However it finds use
in the build farms I maintain so got hosted here :) As the name implies, this
one helps automate the ccache lock files, which sometimes can get abandoned by
an interrupted build or due to systemic issues, and slow down subsequent builds.

Hope this helps,
Jim Klimov
