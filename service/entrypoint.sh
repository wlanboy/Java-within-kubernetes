#!/bin/sh
set -e

exec java \
  ${JAVA_OPTS} \
  org.springframework.boot.loader.launch.JarLauncher
