#! /bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

set -e
cd "$( dirname "${BASH_SOURCE[0]}" )"
source ./validate-common.sh

status "running pep8"
pep8 --config=pep8rc relengapi || not_ok "pep8 failed"

status "running pylint"
pylint relengapi --rcfile=pylintrc || not_ok "pylint failed"

status "building docs"
relengapi build-docs || not_ok "build-docs failed"

status "running tests"
relengapi run-tests || not_ok "tests failed"

tmpbase=$(mktemp -d)
trap 'rm -f ${tmpbase}; exit 1' 1 2 3 15

# get the version
version=`python -c 'import pkg_resources; print pkg_resources.require("'relengapi'")[0].version'`

# remove SOURCES.txt, as it caches the expected contents of the package,
# over and above those specified in setup.py, MANIFEST, and MANIFEST.in
rm -f "relengapi.egg-info/SOURCES.txt"

# get the list of files git thinks should be present
status "getting file list from git"
git_only='
    .gitignore
    .travis.yml
    pep8rc
    pylintrc
    validate.sh
    validate-common.sh
    src
    settings_example.py
'
git ls-files . | while read f; do
                    ignore=false
                    for go in $git_only; do
                        [ "$go" = "$f" ] && ignore=true
                    done
                    $ignore || echo $f
                 done | sort > ${tmpbase}/git-files

# get the list of files in an sdist tarball
status "getting file list from sdist"
python setup.py -q sdist --dist-dir=${tmpbase}
tarball="${tmpbase}/relengapi-${version}.tar.gz"
[ -f ${tarball} ] || fail "No tarball at ${tarball}"
# exclude directories and a few auto-generated files from the tarball contents
tar -ztf $tarball | grep -v  '/$' | cut -d/ -f 2- | grep -vE '(egg-info|PKG-INFO|setup.cfg)' | sort > ${tmpbase}/sdist-files

# get the list of files *installed* from that tarball
status "getting file list from install"
(
    cd "${tmpbase}"
    tar -zxf ${tarball}
    cd `basename ${tarball%.tar.gz}`
    python setup.py -q install --root $tmpbase/root --record=installed.txt
    (
        # get everything installed under site-packages, and trim up to and including site-packages/ on each line,
        # excluding .pyc files, and including the two namespaced packages
        grep 'site-packages/relengapi/' installed.txt | grep -v '\.pyc$' | sed -e 's!.*/site-packages/!!'
        # get all installed $prefix/relengapi-docs
        grep '/relengapi-docs/' installed.txt | sed -e 's!.*/relengapi-docs/!docs/!'
    ) | sort > ${tmpbase}/install-files
)

# and calculate the list of git files that we expect to see installed:
# anything not at the top level, but not the namespaced __init__.py's
grep / ${tmpbase}/git-files | grep -Ev '^relengapi/(blueprints/|)__init__\.py$' > ${tmpbase}/git-expected-installed

# start comparing!
cd ${tmpbase}
status "comparing git and sdist"
diff -u git-files sdist-files || not_ok "sdist files differ from files in git"
status "comparing git and install"
diff -u git-expected-installed install-files || not_ok "installed files differ from files in git"

show_results

