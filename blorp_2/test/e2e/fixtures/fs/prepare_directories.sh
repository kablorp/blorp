#!/bin/sh
# Rebuilds the directory in $1 that directories.brp changes, from nothing. The
# harness runs it before each of the example's two runs, so neither run sees
# the other's changes. It holds what no fs operation can create: a symlink out
# of a tree to a file that must survive, an empty directory with mode 000, and
# names whose byte order differs from a naive order.
#
# Root may search a mode 000 directory, so the harness runs this only after
# prepare.sh has found a user that file permissions refuse.
set -eu

root=$1
# rm -rf cannot remove a mode 000 directory on macOS, and an interrupted run
# can leave one behind.
chmod -R u+rwx "$root" 2>/dev/null || true
rm -rf "$root"
mkdir -p "$root"

# Sorted by name bytes: B (42), _ (5F), a (61), ab, dir, link, then the two
# bytes of the e with an acute accent (C3 A9). The accent is written once,
# precomposed, as octal escapes, so no editor changes its form.
mkdir "$root/listing" "$root/listing/dir"
for name in B _ a ab; do
    : > "$root/listing/$name"
done
: > "$root/listing/$(printf '\303\251')"
ln -s a "$root/listing/link"
ln -s listing "$root/listing_link"

mkdir "$root/empty" "$root/scratch" "$root/removable" "$root/source_dir"
printf 'text' > "$root/file.txt"
ln -s nowhere "$root/dangling"
mkdir "$root/locked"
chmod 000 "$root/locked"

mkdir "$root/nonempty"
: > "$root/nonempty/child.txt"
: > "$root/to_remove.txt"
printf 'moved' > "$root/old.txt"

# The links in tree point out of it, to a file and to the directory holding it.
mkdir "$root/outside"
printf 'precious' > "$root/outside/precious.txt"
mkdir -p "$root/tree/a/b"
: > "$root/tree/a/b/c.txt"
: > "$root/tree/a/d.txt"
ln -s ../outside/precious.txt "$root/tree/escape"
ln -s ../outside "$root/tree/escape_dir"
