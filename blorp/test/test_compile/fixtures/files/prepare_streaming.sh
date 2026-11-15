#!/bin/sh
# Known byte oracles built independently of the Blorp implementation.
set -eu
root=$1
mkdir -p "$root"
for size in 0 1 65536 65537 327681; do
    awk -v count="$size" 'BEGIN { for (i=0;i<count;i++) { n=i%5; if(n==0)printf "%c",0; if(n==1)printf "%c",255; if(n==2)printf "%c",128; if(n==3)printf "%c",65; if(n==4)printf "%c",10; }}' > "$root/input-$size.bin"
    cp "$root/input-$size.bin" "$root/equal-$size.bin"
done
awk 'BEGIN { for (i=0;i<327681;i++) { n=i%5; if(n==0)printf "%c",1; if(n==1)printf "%c",0; if(n==2)printf "%c",129; if(n==3)printf "%c",66; if(n==4)printf "%c",11; }}' > "$root/transformed.expected"
awk 'BEGIN { for (i=0;i<257;i++) printf "%c%c%c%c%c",0,255,128,65,10; }' > "$root/generated.expected"
cp "$root/input-327681.bin" "$root/late-mismatch.bin"
printf 'X' | dd of="$root/late-mismatch.bin" bs=1 seek=327670 conv=notrunc 2>/dev/null
printf 'existing target\000\377' > "$root/early-target.bin"
cp "$root/early-target.bin" "$root/early.expected"
dd if=/dev/zero of="$root/large.bin" bs=1048576 count=16 2>/dev/null
printf 'before\nbody\nafter\n' > "$root/aliases.expected"
printf 'first\r\nsecond\nthird' > "$root/lines.txt"
printf 'first\nsecond\nthird\n' > "$root/lines.expected"
printf 'original\000\377' > "$root/fold-failure.bin"
cp "$root/fold-failure.bin" "$root/fold-failure.expected"
printf 'step 1\nstep 2\nstep 3\nsuccess 3\nstep 1\nstep 2\nstopped\n' > "$root/fold.stdout.expected"
