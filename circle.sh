#!/bin/bash

set -uexo pipefail

HOST_DMD_VER=2.072.2 # same as in dmd/src/posix.mak
TRAVIS_BRANCH=${TRAVIS_BRANCH:-master}
DMD="../dmd/src/dmd"
CURL_USER_AGENT="CirleCI $(curl --version | head -n 1)"
N=2
CIRCLE_NODE_INDEX=${CIRCLE_NODE_INDEX:-0}

case $CIRCLE_NODE_INDEX in
    0) MODEL=64 ;;
    1) MODEL=32 ;;
esac

install_deps() {
    if [ $MODEL -eq 32 ]; then
        sudo apt-get update
        sudo apt-get install g++-multilib
    fi

    for i in {0..4}; do
        if curl -fsS -A "$CURL_USER_AGENT" --max-time 5 https://dlang.org/install.sh -O ||
           curl -fsS -A "$CURL_USER_AGENT" --max-time 5 https://nightlies.dlang.org/install.sh -O ; then
            break
        elif [ $i -ge 4 ]; then
            sleep $((1 << $i))
        else
            echo 'Failed to download install script' 1>&2
            exit 1
        fi
    done

    source "$(CURL_USER_AGENT=\"$CURL_USER_AGENT\" bash install.sh dmd-$HOST_DMD_VER --activate)"
    $DC --version
    env
}

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
    local base_branch="master"
    if [ -n "${CIRCLE_PR_NUMBER:-}" ]; then
        base_branch=$((curl -fsSL https://api.github.com/repos/dlang/tools/pulls/$CIRCLE_PR_NUMBER || echo) | jq -r '.base.ref')
    else
        base_branch=$CIRCLE_BRANCH
    fi
    # merge upstream branch with changes, s.t. we check with the latest changes
    if [ -n "${CIRCLE_PR_NUMBER:-}" ]; then
        local current_branch=$(git rev-parse --abbrev-ref HEAD)
        git config user.name dummyuser
        git config user.email dummyuser@dummyserver.com
        git remote add upstream https://github.com/dlang/tools.git
        git fetch upstream
        git checkout -f upstream/$base_branch
        git merge -m "Automatic merge" $current_branch
    fi

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

build_tools()
{
    # TODO: fix changed
    make -f posix.mak catdoc ddemangle detab dget dman dustmite tolf
}

case $1 in
    install-deps) install_deps ;;
    setup-repos) setup_repos ;;
    build-tools) build_tools;;
    test-rdmd) test_rdmd ;;
    *) echo "Unknown command"; exit 1;;
esac
