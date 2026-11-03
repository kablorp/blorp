#!/bin/sh
# Rebuilds the directory in $1 that write.brp writes into, from nothing. The
# harness runs it before each of the example's two runs, so neither run sees
# the other's files, and it never touches the tree read.brp inspects. It holds
# what no fs operation can create: a symlink into another directory, a
# dangling link, a loop, a read-only file and a FIFO.
#
# Root may write a read-only file, so the harness runs this only after
# prepare.sh has found a user that file permissions refuse.
set -eu

root=$1
rm -rf "$root"
mkdir -p "$root/real" "$root/folder"

printf 'old' > "$root/existing.txt"
printf 'old' > "$root/real/target.txt"
ln -s real/target.txt "$root/link"
ln -s missing_target "$root/dangling"
ln -s loop "$root/loop"
printf 'kept' > "$root/read_only.txt"
chmod 444 "$root/read_only.txt"
mkfifo "$root/pipe"
