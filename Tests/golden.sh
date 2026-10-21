#!/bin/sh
# Phase 1 golden DSP checks: builds jdsp-offline and runs its selftest.
set -eu
cd "$(dirname "$0")/.."
xcodegen -q
xcodebuild -scheme jdsp4mac -configuration Debug -derivedDataPath build/DerivedData build -quiet
build/DerivedData/Build/Products/Debug/jdsp-offline selftest
