#!/bin/bash

set -uexo pipefail

TRAVIS_BRANCH=${TRAVIS_BRANCH:-master}
DMD="../dmd/src/dmd"
N=2

# set to 64-bit by default
if [ -z ${MODEL:-} ] ; then
    MODEL=64
fi

clone() {
    local url="$1"
    local path="$2"
    local branch="$3"
    for i in {0..4}; do
        if git clone --depth=1 --branch "$branch" "$url" "$path"; then
            break
        elif [ $i -lt 4 ]; then
            sleep $((1 << $i))
        else
            echo "Failed to clone: ${url}"
            exit 1
        fi
    done
}

test_rdmd() {
    # run rdmd internal tests
    rdmd --compiler=$DMD -m$MODEL -main -unittest rdmd.d

    # compile rdmd & testsuite
    $DMD -m$MODEL rdmd.d
    $DMD -m$MODEL rdmd_test.d

    # run rdmd testsuite
    ./rdmd_test --compiler=$DMD
}

setup_repos()
{
    for repo in dmd druntime phobos dlang.org installer ; do
        if [ ! -d "../${repo}" ] ; then
            if [ $TRAVIS_BRANCH != master ] && [ $TRAVIS_BRANCH != stable ] &&
                   ! git ls-remote --exit-code --heads https://github.com/dlang/$proj.git $TRAVIS_BRANCH > /dev/null; then
                # use master as fallback for other repos to test feature branches
                clone https://github.com/dlang/${repo}.git ../${repo} master
            else
                clone https://github.com/dlang/${repo}.git ../${repo} $TRAVIS_BRANCH
            fi
        fi
    done

    make -j$N -C ../dmd/src -f posix.mak MODEL=$MODEL HOST_DMD=dmd all
    make -j$N -C ../druntime -f posix.mak MODEL=$MODEL HOST_DMD=$DMD
    make -j$N -C ../phobos -f posix.mak MODEL=$MODEL HOST_DMD=$DMD
}

setup_repos

$DMD --version
rdmd --help | head -n 1
dub --version

# all dependencies installed - run tests now
# TODO: fix changed
make -f posix.mak catdoc ddemangle detab dget dman dustmite tolf

test_rdmd
