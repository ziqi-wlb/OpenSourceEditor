#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
exec python3 tests/run_tests.py "$@"
