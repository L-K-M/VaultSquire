#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT/scripts/check-repository.sh"
"$ROOT/scripts/verify-toolchain.sh"
"$ROOT/scripts/test.sh"
"$ROOT/scripts/build-local.sh" Release
"$ROOT/scripts/build-local.sh" DirectProbe
"$ROOT/scripts/build-local.sh" SandboxProbe
