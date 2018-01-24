#!/bin/bash

set -uexo pipefail

make -f posix.mak all DMD="$(which $DMD)"
make -f posix.mak test DMD="$(which $DMD)"
