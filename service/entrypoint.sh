#!/bin/sh
set -e

exec java \
  ${JAVA_OPTS} \
  -Dspring.aot.enabled=true \
  org.springframework.boot.loader.launch.JarLauncher
