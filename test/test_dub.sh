#!/bin/bash
# Test building of all DUB packages

set -euo pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# dman is excluded in this test because it requires the d-tags.json file for building
for package in tests_extractor dget checkwhitespace ddemangle detab tolf \
               rdmd contributors changed catdoc ; do
    echo "Testing DUB build of $package"
    dub build --root "$DIR/.." ":$package"
done
