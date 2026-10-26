#!/usr/bin/env bash
set -euo pipefail

echo "script starting now"

# runs 1 + 1 (no output)
res1=$((1 + 1))

echo "output of 1+1 is ${res1}"

# runs 2 + 2 (no output)
res2=$((2 + 2))

echo "output of 2+2 is ${res2}"

