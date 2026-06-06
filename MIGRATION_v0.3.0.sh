#!/bin/bash
# Bux v0.3.0 — Restructure directories
set -e

echo "=== Bux v0.3.0 Restructuring ==="

# Step 1: Move compiler/selfhost → src
echo "Moving compiler/selfhost → src/"
git mv compiler/selfhost src

# Step 2: Move compiler/bootstrap → bootstrap
echo "Moving compiler/bootstrap → bootstrap/"
git mv compiler/bootstrap bootstrap

# Step 3: Move library/std → lib
echo "Moving library/std → lib/"
git mv library/std lib

# Step 4: Move library/runtime → rt
echo "Moving library/runtime → rt/"
git mv library/runtime rt

# Step 5: Move compiler/tests/*.nim → tests/
echo "Moving compiler/tests/*.nim → tests/"
for f in compiler/tests/*.nim; do
    git mv "$f" tests/
done

# Step 6: Remove empty/obsolete directories
echo "Removing _selfhost/"
rm -rf _selfhost

echo "Removing empty compiler/ and library/"
rmdir compiler/tests 2>/dev/null || true
rmdir compiler 2>/dev/null || true
rmdir library 2>/dev/null || true

echo "=== Done ==="
