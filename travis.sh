#!/bin/bash

set -uexo pipefail

DIGGER_DIR="../digger"
DIGGER="../digger/digger"

# set to 64-bit by default
if [ -z ${MODEL:-} ] ; then
    MODEL=64
fi

build_digger() {
    git clone --recursive https://github.com/CyberShadow/Digger "$DIGGER_DIR"
    git -C "$DIGGER_DIR" checkout v3.0.0-alpha-5
    (cd "$DIGGER_DIR" && rdmd --build-only -debug digger)
}

install_digger() {
    $DIGGER build --model=$MODEL "master"
    export PATH=$PWD/work/result/bin:$PATH
}

if ! [ -d "$DIGGER_DIR" ] ; then
    build_digger
fi

install_digger

dmd --version
rdmd --help | head -n 1
dub --version

make -f posix.mak all DMD=$(which dmd)
make -f posix.mak test DMD=$(which dmd)
