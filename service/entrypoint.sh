#!/bin/sh
set -e

# NEU: -jar statt JarLauncher und -XX:AOTCache, siehe Dockerfile (AOT-Cache-Trainingslauf)
exec java \
  ${JAVA_OPTS} \
  -XX:AOTCache=/app/app.aot \
  -jar /app/application.jar
