#!/bin/bash
# Run JVM unit tests; logs to test_run.log.
set -e
cd "$(dirname "$0")/.."
export JAVA_HOME=/Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home
nohup ./gradlew testReleaseUnitTest > test_run.log 2>&1 < /dev/null &
echo "tests started, pid $!"
