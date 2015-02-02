# git-scripts
Scripts to automate my working patterns with Git repositories

* `git-pull-ff` -- this script pulls any updates from configured remotes, and
attempts a fast-forward merge of the current workspace with its counterparts.

* `git-sync` -- this script first pushes any updates from local repository to
remote repos (except 'upstream'), then does a `git pull-ff` to receive any
missing updates from the remotes.

* `git-zclone` -- uses ZFS to clone a dataset which contains a GIT repository,
then rewrites some metadata in the new clone (reference to 'origin', NetBeans
project metadata, etc.) In effect this should yield similar results to local
filesystem-based `git clone`, except that with ZFS cloning, anything present
in the workspace dataset is cloned (such as old build products).

