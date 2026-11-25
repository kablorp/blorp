#!/bin/sh
# Builds the tree that read.brp and lines.brp inspect, under the directory in
# $1. It holds the paths that no fs operation can create: a file that is not
# UTF-8, a symlink loop, a file with mode 000, a FIFO and long_not_utf8.txt.
#
# A file with mode 000 is still readable by root, so as root the example
# cannot provoke PermissionDenied. The script then builds nothing and exits
# with NOT_RUN_STATUS, which the harness reports as "not run".
set -eu

NOT_RUN_STATUS=77

if [ "$(id -u)" = 0 ]; then
    exit "$NOT_RUN_STATUS"
fi

root=$1
mkdir -p "$root"

printf 'hello\n' > "$root/settings.conf"
: > "$root/empty.txt"
mkdir "$root/folder"
printf 'ab\377\376cd' > "$root/not_utf8.bin"
ln -s settings.conf "$root/link_to_file"
ln -s missing_target "$root/dangling_link"
ln -s loop "$root/loop"
printf 'secret' > "$root/locked.txt"
chmod 000 "$root/locked.txt"
mkfifo "$root/pipe"

# Valid lines of about 100 KB, more than the first read's 64 KiB, so that the
# bad line falls in a later read, then a line holding byte 0377, which a Blorp
# String cannot hold, then one more line. The line before the bad one is the
# example's LAST_VALID_LINE.
#
# The lines are long so that they are few: lines.brp folds this file 300 times,
# in a sanitized -O0 build that counts every allocation, and each line it steps
# costs an allocation. With 20,000 short lines those folds took most of the
# harness's limit for a native run on a slow CI runner (FILESYSTEM_DECISIONS.md,
# "fold_lines e2e timeout on macOS CI"). Each line is line_bytes characters and
# its newline.
valid_lines=100
line_bytes=1000
awk -v count="$valid_lines" -v bytes="$line_bytes" 'BEGIN {
    for (number = 0; number < count; number++) {
        line = "long line " number " "
        while (length(line) < bytes) line = line "x"
        print line
    }
}' > "$root/long_not_utf8.txt"
printf 'last valid line\nbad \377 line\nafter\n' >> "$root/long_not_utf8.txt"
