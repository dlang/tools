#!/bin/bash

set -uexo pipefail

~/dlang/install.sh install ldc

~/dlang/install.sh list

LDMD2=$(find ~/dlang -type f -name "ldmd2")

make -f posix.mak all DMD=$(which dmd)
make -f posix.mak test DMD=$(which dmd) \
    RDMD_TEST_COMPILERS=dmd,$LDMD2 \
    VERBOSE_RDMD_TEST=1
