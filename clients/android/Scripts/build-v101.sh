#!/bin/bash
# v1.0.1 release build — run on the Mac (Android SDK + keystore live here).
# Launches gradle in the background; tail build_v101.log for progress.
set -e
cd "$(dirname "$0")/.."
export JAVA_HOME=/Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home
nohup ./gradlew bundleRelease assembleRelease > build_v101.log 2>&1 < /dev/null &
echo "gradle started, pid $!"
