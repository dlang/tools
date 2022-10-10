#!/usr/bin/env bash

# Run this script to install or update your dmd toolchain from
# github.
#
# First run, create a working directory, e.g. /path/to/d/. Then run
# this script from that directory (the location of the script itself
# doesn't matter). It will create the following subdirectories:
# /path/to/d/dmd, /path/to/d/phobos, /path/to/d/dlang.org,
# /path/to/d/tools, and /path/to/d/installer. Then it will fetch all
# corresponding projects from github and build them fresh.
#
# On an ongoing basis, to update your toolchain from github go again
# to the same directory (in our example /path/to/d) and run the script
# again. The script will detect that directories exist and will do an
# update.
#

set -ueo pipefail

declare -a projects
projects=(dmd phobos dlang.org tools installer dub)
# Working directory
wd=$(pwd)
# github username
githubUser="dlang"
# Configuration
makecmd="make"
parallel=8
model=64
build="release"
githubUri="https://github.com/"
tag=""
# List of projects to install vs. update. Their disjoint union is
# $projects.
declare -a toInstall toUpdate
toInstall=()
toUpdate=()
# Mess to go here
tempdir=$(mktemp -d /tmp/dmd-update.XXX)

function cleanup() {
    rm -rf "$tempdir";
}
trap cleanup EXIT

function help() {
    echo "./setup.sh
Clones and builds dmd, phobos, dlang.org, tools, installer and dub.

Additional usage

  install       replace current dmd binary with the freshly dmd

Options

  --user=USER   set a custom GitHub user name (requires the repos to be forked)
  --tag=TAG     select a specific tag to clone" >&2
}

#
# Take care of the command line arguments
#
function handleCmdLine() {
    for arg in "$@"; do
        case "$arg" in
    	    --tag=*)
    	    tag="${arg//[-a-zA-Z0-9]*=/}"
            ;;
    	    --user=*)
    	    githubUser="${arg//[-a-zA-Z0-9]*=/}"
            ;;
            install)
            install="yes"
            ;;
            *)
            echo "Error: $arg not recognized." >&2
            echo >&2
            help
            exit 1
            ;;
        esac
    done

    if [ -n "${tag+x}" ] ; then
        wd+="/$tag"
        mkdir -p "$wd"
    fi
}

#
# Confirm correct choices
#
function confirmChoices() {
    function joinWithWorkingDir() {
        for i in "$@"; do
            echo "$wd/$i"
        done
    }

    for project in "${projects[@]}" ; do
        if [ -d "$wd/$project" ] ; then
            toUpdate+=("$project")
        else
            toInstall+=("$project")
        fi
    done
    if [[ ${#toInstall[@]} -gt 0 ]]; then
        echo "*** The following projects will be INSTALLED:"
        joinWithWorkingDir "${toInstall[@]}"
    fi
    if [[ ${#toUpdate[@]} -gt 0 ]]; then
        echo "*** The following projects will be UPDATED:"
        joinWithWorkingDir "${toUpdate[@]}"
    fi

    echo "Is this what you want? [y|n]"
    local yn
    while true; do
        read -r yn
        case "$yn" in
            [Yy]* ) break;;
            [Nn]* ) exit;;
            * ) echo "Please answer y or n.";;
        esac
    done
}

#
# Install from scratch
#

function installAnew() {
    local projects
    projects=("$@")
    for project in "${projects[@]}" ; do
        (
        git clone "${githubUri}${githubUser}/$project.git" "$wd/$project"
        if [ "$githubUser" != "dlang" ] ; then
            git -C "$wd/$project" remote add upstream "${githubUri}dlang/$project.git"
        fi
        touch "$tempdir/$project"
        ) &
    done
    wait

    for project in "${projects[@]}" ; do
        if [ ! -f "$tempdir/$project" ]; then
            echo "Getting $project failed." >&2
            exit 1
        fi
        if [ -n "${tag}" ] ; then
            if [ "$project" == "dmd" ] || [ "$project" == "phobos" ] || \
		[ "$project" == "dlang.org" ] || [ "$project" == "tools" ] ; then
	            git -C "$wd/$project" checkout "v$tag"
            fi
        fi
    done
}

#
# Freshen existing stuff
#

function update() {
    echo "Updating projects in $wd..."

    function update_project() {
        local project=$1
        local gitproject="${githubUri}dlang/$project.git"
        local git=("git" "-C" "$wd/$project")
        if ! ( \
            "${git[@]}" checkout master && \
            "${git[@]}" pull --ff-only --tags "$gitproject" master ) 2> "$tempdir/$project.log"
        then
            echo "Failure updating $wd/$project." >> "$tempdir/errors"
            exit 1
        fi
    }

    for project in "${toUpdate[@]}" ; do
        update_project "$project" &
    done
    wait

    if [ -f "$tempdir/errors" ]; then
        cat "$tempdir"/*.log >&2
        exit 1
    fi
}

function makeWorld() {
    local BOOTSTRAP=""
    command -v dmd >/dev/null || BOOTSTRAP="AUTO_BOOTSTRAP=1"
    for repo in dmd phobos ; do
        # Pass `AUTO_BOOTSTRAP` because of https://issues.dlang.org/show_bug.cgi?id=20727
        "$makecmd" -C "$wd/$repo" -f posix.mak clean $BOOTSTRAP
        "$makecmd" -C "$wd/$repo" -f posix.mak "-j${parallel}" MODEL="$model" BUILD="$build" $BOOTSTRAP
    done

    # Update the running dmd version (only required once)
    if [[ -n "${install+x}" ]]; then
        local old dmdBinary
        old=$(command -v dmd)
        dmdBinary=$(ls -1 $wd/dmd/generated/*/$build/$model/dmd)
        if [ -f "$old" ]; then
            echo "Linking '$dmdBinary' to $old"
            local sudo=""
            if [ ! -w "$old" ] ; then
                sudo="sudo"
            fi
            ln -s "$tempdir/dmd.symlink" "$old"
            "$sudo" mv "$tempdir/dmd.symlink" "$old"
        fi
    fi
}

# main
handleCmdLine "$@"
confirmChoices
if [ ${#toInstall[@]} -gt 0 ] ; then
    installAnew "${toInstall[@]}"
fi
if [ ${#toUpdate[@]} -gt 0 ] ; then
    update "${toUpdate[@]}"
fi
makeWorld
