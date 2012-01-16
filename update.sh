#!/bin/zsh

# Run this script to install or update your dmd toolchain from
# github.
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

setopt err_exit

local projects
typeset -a projects
projects=(dmd druntime phobos d-programming-language.org tools installer)
# Working directory
local wd=$(pwd)
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
            git clone --quiet git@github.com:D-Programming-Language/$project.git &&
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
            git pull origin master && \
            git pull origin master --tags && \
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
    ( cd "$wd/dmd/src" && make -f posix.mak clean  && make -f posix.mak -j 8 )

# Update the running dmd version
    echo "Copying "$wd/dmd/src/dmd" over $(which dmd)"
    sudo cp "$wd/dmd/src/dmd" $(which dmd)

# Then make druntime
    ( cd "$wd/druntime" && make -f posix.mak -j 8 DMD="$wd/dmd/src/dmd" )

# Then make phobos
    ( cd "$wd/phobos" && make -f posix.mak -j 8 DMD="$wd/dmd/src/dmd" )

# Then make website
    ( cd "$wd/d-programming-language.org" &&
        make -f posix.mak clean DMD="$wd/dmd/src/dmd" &&
        make -f posix.mak html -j 8 DMD="$wd/dmd/src/dmd"
    )
}

# main
handleCmdLine
confirmChoices
installAnew $toInstall
update $toUpdate
makeWorld
