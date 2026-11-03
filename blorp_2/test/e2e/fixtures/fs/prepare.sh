#!/bin/sh
# Builds the tree that read.brp inspects, under the directory in $1. It holds
# the paths that no fs operation can create: a file that is not UTF-8, a
# symlink loop, a file with mode 000 and a FIFO.
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
