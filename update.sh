#!/usr/bin/env zsh

# Run this script to install or update your dmd toolchain from
# github.
#
# Make sure zsh is installed. You may need to change the shebang.
#
# First run, create a working directory, e.g. /path/to/d/. Then run
# this script from that directory (the location of the script itself
# doesn't matter). It will create the following subdirectories:
# /path/to/d/dmd, /path/to/d/druntime, /path/to/d/phobos,
# /path/to/d/d-programming-language.org, /path/to/d/tools, and
# /path/to/d/installer. Then it will fetch all corresponding projects
# from github and build them fresh.
#
# On an ongoing basis, to update your toolchain from github go again
# to the same directory (in our example /path/to/d) and run the script
# again. The script will detect that directories exist and will do an
# update.
#

GIT_HOME=https://github.com/D-Programming-Language

setopt err_exit

local projects
typeset -a projects
projects=(dmd druntime phobos d-programming-language.org tools installer)
# Working directory
local wd=$(pwd)
# Configuration
local makecmd=make
local parallel=8
local model=64
# List of projects to install vs. update. Their disjoint union is
# $projects.
local toInstall toUpdate
typeset -a toInstall toUpdate
# Mess to go here
local tempdir=$(mktemp -d /tmp/dmd-update.XXX)

#
# Take care of the command line arguments
#
function handleCmdLine() {
    local arg
    for arg in $*; do
        case $arg in
          (--tag=*)
            tag="`echo $arg | sed 's/[-a-zA-Z0-9]*=//'`"
            ;;
            (*)
            echo "Error: $arg not recognized." >&2exit 1
            ;;
        esac
    done

    if [[ ! -z $tag ]]; then
        wd+="/$tag"
        mkdir -p "$wd"
    fi
}

#
# Confirm correct choices
#
function confirmChoices() {
    function joinWithWorkingDir() {
        for i in $*; do
            echo "$wd/$i"
        done
    }

    for project in $projects; do
        if [ -e "$wd/$project" ]; then
            toUpdate=($toUpdate "$project")
        else
            toInstall=($toInstall "$project")
        fi
    done
    if [[ ! -z $toInstall ]]; then
        echo "*** The following projects will be INSTALLED:"
        joinWithWorkingDir ${toInstall}
        echo "*** Note: this script assumes you have a github account set up."
    fi
    if [[ ! -z $toUpdate ]]; then
        echo "*** The following projects will be UPDATED:"
        joinWithWorkingDir ${toUpdate}
    fi

    echo "Is this what you want?"
    local yn
    while true; do
        read yn
        case $yn in
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
    projects=($*)
    for project in $projects; do
        (
            cd $wd &&
            git clone --quiet -o upstream $GIT_HOME/$project.git &&
            touch $tempdir/$project
        ) &
    done
    wait

    for project in $projects; do
        if [ ! -f $tempdir/$project ]; then
            echo "Getting $project failed." >&2
            rm -rf $tempdir
            exit 1
        fi
        if [[ ! -z $tag &&
                    ($project = dmd || $project = druntime || $project = phobos ||
                        $project = d-programming-language.org) ]]; then
          ( cd $wd/$project && git checkout v$tag )
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
        if ! ( cd "$wd/$project" && \
            git checkout master && \
            git pull upstream master && \
            git pull upstream master --tags && \
            git fetch && \
            git fetch --tags) 2>$tempdir/$project.log
        then
            echo "Failure updating $wd/$project." >>$tempdir/errors
            exit 1
        fi
    }

    for project in $toUpdate; do
        update_project $project &
    done
    wait

    if [ -f $tempdir/errors ]; then
        cat $tempdir/*.log >&2
        exit 1
    fi
}

function makeWorld() {
# First make dmd
    (
        cd "$wd/dmd/src" &&
        $makecmd -f posix.mak clean MODEL=$model &&
        $makecmd -f posix.mak -j $parallel MODEL=$model
    )

# Update the running dmd version
    local old=$(which dmd)
    if [ -f "$old" ]; then
        echo "Copying "$wd/dmd/src/dmd" over $old"
        [ ! -w "$old" ] && local sudo="sudo"
        $sudo cp "$wd/dmd/src/dmd" "$old"
    fi

# Then make druntime
    (
        cd "$wd/druntime" &&
        $makecmd -f posix.mak -j $parallel DMD="$wd/dmd/src/dmd" MODEL=$model
    )

# Then make phobos
    (
        cd "$wd/phobos" &&
        $makecmd -f posix.mak -j $parallel DMD="$wd/dmd/src/dmd" MODEL=$model
    )

# Then make website
    (
        cd "$wd/d-programming-language.org" &&
        $makecmd -f posix.mak clean DMD="$wd/dmd/src/dmd" MODEL=$model GIT_HOME=$GIT_HOME &&
        $makecmd -f posix.mak html -j $parallel DMD="$wd/dmd/src/dmd" MODEL=$model GIT_HOME=$GIT_HOME
    )
}

# main
handleCmdLine
confirmChoices
installAnew $toInstall
update $toUpdate
makeWorld
