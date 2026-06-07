#!/bin/bash
cd /home/ziko/z-git/bux/bux/apps/boko-framework

echo "=== CHECK ==="
../../buxc check 2>&1
echo "CHECK_EXIT=$?"

echo ""
echo "=== BUILD ==="
../../buxc build 2>&1
echo "BUILD_EXIT=$?"

echo ""
echo "=== FILES ==="
find . -type f -newer bux.toml 2>/dev/null | head -30
echo ""
echo "=== BINARY SEARCH ==="
file boko-framework 2>/dev/null || echo "no boko-framework"
ls -la build/ 2>/dev/null || echo "no build dir"
