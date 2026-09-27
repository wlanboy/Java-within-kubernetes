# syntax=docker/dockerfile:1

# --- Build & AOT-Verarbeitung ---
# Voraussetzung: pom.xml enthaelt <start-class>...Application</start-class>
# und <java.version>25</java.version> (siehe readme.md)
FROM eclipse-temurin:25-jdk-alpine AS builder
WORKDIR /workspace
COPY .mvn ./.mvn
COPY mvnw pom.xml ./
COPY src ./src
RUN --mount=type=cache,target=/root/.m2 ./mvnw -q -DskipTests compile spring-boot:process-aot package

# --- Extraktion (kleineres, cachefreundlicheres Runtime-Image) ---
# NEU: ohne --launcher. Der JDK-AOT-Cache (siehe Runtime-Stage) funktioniert nur
# mit "java -jar application.jar" und einem Classpath aus dem Jar-Manifest. Mit
# dem JarLauncher (Nested-Jar-Classloader) koennen die Anwendungs- und
# Library-Klassen nicht aus dem Cache geladen werden.
FROM eclipse-temurin:25-jdk-alpine AS extractor
WORKDIR /workspace
COPY --from=builder /workspace/target/*.jar application.jar
RUN java -Djarmode=tools -jar application.jar extract --layers --destination extracted

# --- Runtime ---
FROM eclipse-temurin:25-jre-alpine
# feste UID/GID, damit sie exakt zu runAsUser/fsGroup in manifests/deployment.yaml passen
RUN addgroup -g 1000 -S spring && adduser -u 1000 -S spring -G spring
WORKDIR /app
COPY --from=extractor /workspace/extracted/dependencies/ ./
COPY --from=extractor /workspace/extracted/spring-boot-loader/ ./
COPY --from=extractor /workspace/extracted/snapshot-dependencies/ ./
COPY --from=extractor /workspace/extracted/application/ ./

# NEU: JDK-25-AOT-Cache (JEP 483/514/515) per Trainingslauf erzeugen.
# spring.context.exit=onRefresh beendet die App direkt nach dem Context-Refresh,
# d.h. alle beim Start geladenen/gelinkten Klassen landen im Cache, ohne dass
# der Webserver wirklich Requests annimmt.
# Laeuft bewusst in der Runtime-Stage, weil der Cache nur mit exakt derselben
# JVM (Build) und demselben Classpath gueltig ist.
# ACHTUNG: GC und UseCompactObjectHeaders muessen zu javaOpts im Helm-Chart
# passen, sonst verwirft die JVM den Cache beim Start (nur Warnung, kein Fehler,
# dann aber ohne Startzeit-Gewinn). -Dspring.aot.enabled=true, damit die
# Spring-AOT-Klassen (statt Reflection-Pfad) trainiert werden.
RUN java \
      -XX:AOTCacheOutput=app.aot \
      -XX:+UseSerialGC \
      -XX:+UseCompactObjectHeaders \
      -Dspring.aot.enabled=true \
      -Dspring.context.exit=onRefresh \
      -jar application.jar

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && chown -R spring:spring /app

# numerisch statt namentlich, damit runAsNonRoot/runAsUser in
# manifests/deployment.yaml die UID zuverlaessig auswerten koennen
USER 1000:1000
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
