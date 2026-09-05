#!/usr/bin/env bash
# Installs the two git-based dependencies. The Somnia reactivity contracts are
# vendored under lib/somnia-reactivity because they ship on npm, not git.
set -euo pipefail
cd "$(dirname "$0")"
forge install foundry-rs/forge-std --no-git
forge install OpenZeppelin/openzeppelin-contracts@v5.4.0 --no-git
echo "dependencies installed"
