# syntax=docker/dockerfile:1

# Spring Boot (Tomcat) auf UBI 10 mit Spring AOT und JDK-25-AOT-Cache.
#
# Stage "build":   Maven-Build mit process-aot, Extraktion der Layer, Trainingslauf für den AOT-Cache
# Runtime-Stage:   ubi10/openjdk-25-runtime, nur JRE, keine RUN-Befehle
#
# Voraussetzung in der pom.xml: <java.version>25</java.version> und
# <start-class>com.example.helloworld.HelloworldApplication</start-class>.
# Erklärung aller Schritte: readme.md, Abschnitt "Docker-Image".

# --- Optionaler Build-Kontext für das git-commit-id-maven-plugin ---
# Leere Default-Stage. Mit "docker build --build-context git=.git service/" ersetzt BuildKit
# sie durch das .git-Verzeichnis des Repos (der Kontext service/ enthält kein .git).
# Ohne den Parameter bleibt sie leer: Der Build läuft durch, es fehlt nur git.properties
# (/actuator/info liefert dann {}).
FROM scratch AS git

FROM registry.access.redhat.com/ubi10/openjdk-25:latest AS build
# Das UBI-Build-Image läuft als User 185 mit HOME=/home/default. WORKDIR legt fehlende
# Verzeichnisse als root an, deshalb hier einmal als root /build (Maven) und /app (Training)
# anlegen und 185 übergeben.
USER root
RUN mkdir /build /app && chown 185:0 /build /app
USER 185
WORKDIR /build

# Erst nur die pom.xml kopieren und die Dependencies laden. Dieser Layer bleibt gecacht,
# solange sich die pom.xml nicht ändert; Änderungen am Code laden nichts neu.
# Cache-Mount auf ~/.m2 des Users 185. uid=185 ist nötig, sonst gehört der Mount root und
# Maven kann nicht hineinschreiben. Ein Mount auf /root/.m2 würde nie benutzt.
COPY pom.xml .
RUN --mount=type=cache,target=/home/default/.m2,uid=185 mvn -q dependency:go-offline

# .dockerignore lässt nur src/main und src/layers.xml durch. Änderungen an src/test machen
# diesen Layer damit nicht ungültig.
COPY src ./src

# javac-Optionen: Hier gibt es nichts zu holen. javac optimiert praktisch nicht, das macht zur
# Laufzeit der JIT. Startzeit und Speicher gewinnt man über Spring AOT und den AOT-Cache.
#
#   -O                    seit JDK 1.3 ignoriert
#   -g:none               kleinere Klassendateien, aber nicht schneller (der JIT ignoriert Debug-Infos);
#                         Stacktraces hätten keine Zeilennummern mehr
#   -g:lines,source       nur Zeilennummern und Dateiname, Gewinn kaum messbar
#   -parameters           braucht Spring (Parameternamen für DI und @PathVariable)
#   -proc:full            seit JDK 23 ist -proc:none Default. Hier nicht nötig, weil
#                         <annotationProcessorPaths> (spring-boot-configuration-processor)
#                         --processor-path setzt und Annotation Processing damit aktiviert
#   -Xlint:all / -Werror  nur Codequalität, kein Laufzeiteffekt
#   -T 1C (Maven)         paralleler Build, ohne Wirkung bei nur einem Modul
#
# spring-boot-starter-parent 4.1.x setzt bereits (geprüft mit mvn help:effective-pom):
#   <parameters>true</parameters> -> -parameters, maven.compiler.release=25 -> --release 25,
#   project.build.sourceEncoding=UTF-8 -> -encoding UTF-8, debug=true -> -g
#
# Build-Befehl:
# - compile vor spring-boot:process-aot ist Pflicht, package baut das JAR inkl. AOT-Klassen.
# - -Dmaven.test.skip=true statt -DskipTests: -DskipTests kompiliert die Tests trotzdem, und zwar
#   jedes Mal komplett neu, weil process-aot in target/classes schreibt.
# - CPU-Limit: BuildKit kennt kein --cpus pro RUN-Step. -XX:ActiveProcessorCount begrenzt die CPUs,
#   die die JVM sieht (GC-, JIT- und ForkJoin-Threads). JAVA_TOOL_OPTIONS statt MAVEN_OPTS, weil
#   process-aot eine eigene JVM forkt, die MAVEN_OPTS nicht sieht. Überschreiben mit
#   docker build --build-arg BUILD_CPUS=4.
# - .git kommt als Bind-Mount aus der Stage "git" und landet in keinem Layer. rw, weil JGit z. B.
#   den Index-Cache aktualisiert; die Änderungen werden verworfen.
# - -Pdocker lässt git.dirty weg (siehe Profil in der pom.xml).
# - Ohne --build-context ist /build/.git ein leeres Verzeichnis. Das Plugin hält es für ein Repo
#   und bricht ab (failOnNoGitDirectory greift nicht), daher wird es dann übersprungen.
ARG BUILD_CPUS=2
RUN --mount=type=cache,target=/home/default/.m2,uid=185 \
    --mount=type=bind,from=git,target=/build/.git,rw \
    GIT_SKIP=$([ -f .git/HEAD ] || echo -Dmaven.gitcommitid.skip=true) && \
    JAVA_TOOL_OPTIONS="-XX:ActiveProcessorCount=${BUILD_CPUS}" \
    mvn -q -Pdocker ${GIT_SKIP} -Dmaven.test.skip=true compile spring-boot:process-aot package

# --- Extraktion ---
# Ohne --launcher entsteht application/app.jar mit einem Class-Path-Manifest auf lib/*.jar.
# Nur so kann der AOT-Cache die Anwendungs- und Library-Klassen aufnehmen. Mit --launcher lädt
# der JarLauncher die Klassen über einen eigenen Classloader, und die landen nie im Cache.
RUN JAR=$(ls target/*.jar | grep -v original) && \
    java -Djarmode=tools -jar "$JAR" extract --layers --application-filename app.jar --destination extracted

# --- Trainingslauf für den AOT-Cache ---
# Der Cache gilt nur, wenn Training und Laufzeit denselben Classpath haben: gleiche Pfade,
# Größen und mtimes der JARs. Deshalb die Layer hier nach /app zusammenführen, im selben Layout
# wie in der Runtime-Stage. cp -a und COPY erhalten die mtime.
WORKDIR /app
RUN for layer in dependencies observability-dependencies spring-boot-loader snapshot-dependencies application-resources application; do \
      [ -d /build/extracted/$layer ] && cp -a /build/extracted/$layer/. /app/; \
    done
# spring.context.exit=onRefresh beendet die App direkt nach dem Context-Refresh. Alle beim Start
# geladenen Klassen landen im Cache, ohne dass Tomcat Requests annimmt; der Build braucht dafür
# weder Netzwerk noch ConfigMap.
# GC und UseCompactObjectHeaders müssen mit ENTRYPOINT und JAVA_TOOL_OPTIONS (Helm javaOpts,
# manifests/deployment.yaml) übereinstimmen, sonst verwirft die JVM den Cache beim Start
# (nur eine Warnung, dann ohne Zeitgewinn). Den GC immer explizit setzen: Ohne Angabe wählt
# die JVM ihn nach CPU und RAM des Build-Containers.
# Kein "|| [ -f ... ]"-Guard: Der Lauf endet mit Exit 0, ein Fehler soll den Build brechen.
RUN java -XX:AOTCacheOutput=/app/app.aot \
         -XX:+UseSerialGC \
         -XX:+UseCompactObjectHeaders \
         -Dspring.aot.enabled=true \
         -Dspring.context.exit=onRefresh \
         -jar /app/app.jar

# --- Runtime ---
# Der AOT-Cache gilt nur mit exakt demselben JVM-Build wie im Training. Nach Base-Image-Updates
# beide :latest-Tags neu ziehen (docker pull), sonst startet die JVM ohne Cache.
FROM registry.access.redhat.com/ubi10/openjdk-25-runtime:latest

# version synchron zur pom.xml halten
LABEL org.opencontainers.image.title="helloworld" \
      org.opencontainers.image.description="Spring Boot Hello-World (Tomcat) fuer Kubernetes mit Spring AOT und JDK-25-AOT-Cache" \
      org.opencontainers.image.version="0.0.1-SNAPSHOT" \
      org.opencontainers.image.vendor="wlanboy" \
      org.opencontainers.image.source="https://github.com/wlanboy/Java-within-kubernetes" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="registry.access.redhat.com/ubi10/openjdk-25-runtime:latest"

WORKDIR /app
# Ein COPY pro Layer aus src/layers.xml, seltenste Änderung zuerst. Bei einer Code-Änderung
# wird nur der letzte Layer (application) neu gebaut und übertragen, die Dependencies bleiben
# gecacht. spring-boot-loader bleibt ohne --launcher leer, der Schritt bleibt trotzdem stehen.
COPY --from=build --chown=185:185 /build/extracted/dependencies/ ./
COPY --from=build --chown=185:185 /build/extracted/observability-dependencies/ ./
COPY --from=build --chown=185:185 /build/extracted/spring-boot-loader/ ./
COPY --from=build --chown=185:185 /build/extracted/snapshot-dependencies/ ./
COPY --from=build --chown=185:185 /build/extracted/application-resources/ ./
COPY --from=build --chown=185:185 /build/extracted/application/ ./
COPY --from=build --chown=185:185 /app/app.aot ./

# UBI-Standarduser. In Kubernetes passend runAsUser: 185 und fsGroup: 185.
USER 185
# 8080 = App, 8081 = Actuator (management.server.port)
EXPOSE 8080 8081
# Exec-Form ohne Shell und ohne Startskript: java ist PID 1 und bekommt SIGTERM direkt
# (nötig für Graceful Shutdown). Hier stehen nur die Flags, die zum Image gehören:
# Cache-Pfad sowie GC- und Header-Flags passend zum Training. Heap, Metaspace, CPU-Anzahl usw.
# kommen aus JAVA_TOOL_OPTIONS (Helm javaOpts), weil sie zu den Resources des Pods passen müssen.
ENTRYPOINT ["java", \
  "-XX:AOTCache=/app/app.aot", \
  "-Dspring.aot.enabled=true", \
  "-XX:+UseSerialGC", \
  "-XX:+UseCompactObjectHeaders", \
  "-XX:+ExitOnOutOfMemoryError", \
  "-jar", "/app/app.jar"]
