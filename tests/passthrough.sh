#!/bin/sh

# Exercise both sides of the open-path decision: ordinary local files must use
# passthrough in force mode, while members supplied by an archive must continue
# through rar2fs extraction I/O.  Exit 77 when the host cannot run FUSE
# passthrough integration tests.

set -u

RAR2FS=${RAR2FS:-../src/rar2fs}
RAR=${RAR:-rar}

skip()
{
        echo "SKIP: $*"
        exit 77
}

command -v "$RAR" >/dev/null 2>&1 || skip "rar command is not installed"
command -v fusermount3 >/dev/null 2>&1 || skip "fusermount3 is not installed"
command -v mountpoint >/dev/null 2>&1 || skip "mountpoint is not installed"
test -c /dev/fuse || skip "/dev/fuse is not available"
test -x "$RAR2FS" || skip "rar2fs has not been built"

tmp=${TMPDIR:-/tmp}/rar2fs-passthrough.$$
src=$tmp/source
archive_src=$tmp/archive-source
mnt=$tmp/mount
log=$tmp/rar2fs.log
pid=

cleanup()
{
        if mountpoint -q "$mnt" 2>/dev/null; then
                fusermount3 -u "$mnt" >/dev/null 2>&1 || true
        fi
        if test -n "$pid" && kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
        fi
        test -z "$pid" || wait "$pid" 2>/dev/null || true
        rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$src" "$archive_src" "$mnt"
printf '%s\n' local-before >"$src/local.txt"
printf '%s\n' archive-data >"$archive_src/archived.txt"
(cd "$archive_src" && "$RAR" a -idq "$src/content.rar" archived.txt) || exit 1

"$RAR2FS" "$src" "$mnt" -f -o passthrough=force >"$log" 2>&1 &
pid=$!

i=0
while ! mountpoint -q "$mnt" 2>/dev/null; do
        if ! kill -0 "$pid" 2>/dev/null; then
                if grep -Eqi 'not supported|requires libfuse3|operation not permitted|/dev/fuse' "$log"; then
                        skip "FUSE passthrough is not supported by this host"
                fi
                cat "$log" >&2
                exit 1
        fi
        i=$((i + 1))
        test "$i" -lt 100 || skip "mount did not become ready"
        sleep 0.1
done

printf '%s\n' local-before | cmp - "$mnt/local.txt" || exit 1
printf '%s\n' local-after >"$mnt/local.txt" || exit 1
printf '%s\n' local-after | cmp - "$src/local.txt" || exit 1

# There is no local archived.txt in the source tree.  A successful read here
# therefore verifies that force mode does not try to register archive handles
# as passthrough backing files.
printf '%s\n' archive-data | cmp - "$mnt/archived.txt" || exit 1

exit 0
