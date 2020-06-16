#!/bin/bash

set -uexo pipefail

~/dlang/install.sh install gdc
~/dlang/install.sh install ldc

~/dlang/install.sh list

GDMD=$(find ~/dlang -type f -name "gdmd")
LDMD2=$(find ~/dlang -type f -name "ldmd2")

make -f posix.mak all DMD="$(which dmd)"
make -f posix.mak test DMD="$(which dmd)" \
    RDMD_TEST_COMPILERS=dmd,"$GDMD","$LDMD2" \
    VERBOSE_RDMD_TEST=1

# Test setup.sh
shellcheck setup.sh

dmd=dmd/generated/linux/release/64/dmd
dir=generated/setup.sh-test
cwd="$(pwd)"

# check initial checkout
rm -rf "$dir" && mkdir "$dir" && pushd "$dir"
echo "y" | "$cwd"/setup.sh
echo 'void main(){ import std.stdio; "Hello World".writeln;}' | "./${dmd}" -run - | grep -q "Hello World"

# test updates
echo "y" | "$cwd"/setup.sh
echo 'void main(){ import std.stdio; "Hello World".writeln;}' | "./${dmd}" -run - | grep -q "Hello World"
popd && rm -rf "$dir" && mkdir "$dir" && pushd "$dir"

# test checking out tags
# requires an older host compiler too, see also: https://github.com/dlang/tools/pull/324
. $(~/dlang/install.sh install dmd-2.078.1 -a)
echo "y" | "$cwd"/setup.sh --tag=2.078.1
echo 'void main(){ import std.stdio; __VERSION__.writeln;}' | "./2.078.1/${dmd}" -run - | grep -q "2078"
popd

# test building the DUB packages
./test/test_dub.sh
