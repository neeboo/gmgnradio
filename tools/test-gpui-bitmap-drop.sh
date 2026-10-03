#!/bin/sh
set -eu

test_source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test_build_dir=$(mktemp -d /tmp/gmgn-bitmap-drop-test.XXXXXX)
cleanup() {
    rm -f "$test_build_dir/test-gpui-bitmap-drop"
    rmdir "$test_build_dir"
}
trap cleanup EXIT HUP INT TERM
clang -fobjc-arc -Wall -Wextra -Werror -framework AppKit \
    "$test_source_dir/test-gpui-bitmap-drop.m" \
    -o "$test_build_dir/test-gpui-bitmap-drop"
"$test_build_dir/test-gpui-bitmap-drop"
