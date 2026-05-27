#!/bin/bash
# Test auto-formatting on compile/run/test
# These tests guard auto-format-on-use behavior for check/run/test.

set -e
BLORP="./blorp"
PASS=0
FAIL=0
TOTAL=0

check() {
  TOTAL=$((TOTAL + 1))
  if eval "$2"; then
    PASS=$((PASS + 1))
    echo "  [PASS] $1"
  else
    FAIL=$((FAIL + 1))
    echo "  [FAIL] $1"
  fi
}

echo "=== Auto-Format Tests ==="

# --- Setup: create a badly-formatted test file ---
TMPDIR=$(mktemp -d)
cat > "$TMPDIR/messy.brp" << 'EOF'
func   main( args:   List[String] )   ->   Int:
    x:Int=42
    print( to_string( x ) )
    0
EOF
cp "$TMPDIR/messy.brp" "$TMPDIR/messy_orig.brp"

# --- Test 1: blorp check auto-formats the file ---
cp "$TMPDIR/messy_orig.brp" "$TMPDIR/messy.brp"
$BLORP check "$TMPDIR/messy.brp" 2>/dev/null
check "check auto-formats file" \
  '! diff -q "$TMPDIR/messy_orig.brp" "$TMPDIR/messy.brp" > /dev/null 2>&1'

# --- Test 2: blorp run auto-formats the file ---
cp "$TMPDIR/messy_orig.brp" "$TMPDIR/messy.brp"
$BLORP run "$TMPDIR/messy.brp" 2>/dev/null || true
check "run auto-formats file" \
  '! diff -q "$TMPDIR/messy_orig.brp" "$TMPDIR/messy.brp" > /dev/null 2>&1'

# --- Test 3: --no-format skips formatting ---
cp "$TMPDIR/messy_orig.brp" "$TMPDIR/messy.brp"
BLORP_NO_FORMAT=1 $BLORP check "$TMPDIR/messy.brp" 2>/dev/null || true
check "BLORP_NO_FORMAT=1 skips formatting" \
  'diff -q "$TMPDIR/messy_orig.brp" "$TMPDIR/messy.brp" > /dev/null 2>&1'

# --- Test 4: blorp test auto-formats the file ---
cat > "$TMPDIR/messy_test.brp" << 'EOF'
import:
    test:TestSuite

func   test_one(  ) -> Bool:
    True

tests:TestSuite={description="auto fmt",tests=[("one",test_one)]}
EOF
cp "$TMPDIR/messy_test.brp" "$TMPDIR/messy_test_orig.brp"
$BLORP test "$TMPDIR/messy_test.brp" 2>/dev/null || true
check "test auto-formats file" \
  '! diff -q "$TMPDIR/messy_test_orig.brp" "$TMPDIR/messy_test.brp" > /dev/null 2>&1'

# --- Test 5: formatting is cached (second run doesn't re-format) ---
cp "$TMPDIR/messy_orig.brp" "$TMPDIR/messy.brp"
$BLORP check "$TMPDIR/messy.brp" 2>/dev/null  # formats it
FORMATTED_MTIME=$(stat -f %m "$TMPDIR/messy.brp" 2>/dev/null || stat -c %Y "$TMPDIR/messy.brp" 2>/dev/null)
sleep 1
$BLORP check "$TMPDIR/messy.brp" 2>/dev/null  # should use cache, not re-write
CACHED_MTIME=$(stat -f %m "$TMPDIR/messy.brp" 2>/dev/null || stat -c %Y "$TMPDIR/messy.brp" 2>/dev/null)
check "cached file not re-written" \
  '[ "$FORMATTED_MTIME" = "$CACHED_MTIME" ]'

# --- Test 6: std library files are NOT formatted ---
STD_MTIME_BEFORE=$(stat -f %m std/list.brp 2>/dev/null || stat -c %Y std/list.brp 2>/dev/null)
cat > "$TMPDIR/uses_std.brp" << 'EOF'
import:
    list as L

func   main(args:List[String])->Int:
    xs:List[Int]=[1,2,3]
    print(to_string(L.length(xs)))
    0
EOF
$BLORP check "$TMPDIR/uses_std.brp" 2>/dev/null || true
STD_MTIME_AFTER=$(stat -f %m std/list.brp 2>/dev/null || stat -c %Y std/list.brp 2>/dev/null)
check "std library files not formatted" \
  '[ "$STD_MTIME_BEFORE" = "$STD_MTIME_AFTER" ]'

# --- Cleanup ---
rm -rf "$TMPDIR"

echo ""
echo "Results: $PASS passed, $FAIL failed out of $TOTAL tests"
if [ $FAIL -gt 0 ]; then
  exit 1
fi
