#!/bin/sh
# Non-mutating default suite: no Docker, mounts, restarts, or uploads.
set -eu
cd "$(dirname "$0")"
export PYTHONDONTWRITEBYTECODE=1
python3 -m unittest discover -v -p 'test_*.py'
python3 -m unittest -v runtime.StaticTests
