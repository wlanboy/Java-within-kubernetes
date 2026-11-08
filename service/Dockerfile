# syntax=docker/dockerfile:1

# --- Build & AOT-Verarbeitung ---
# Voraussetzung: pom.xml enthaelt <start-class>...Application</start-class>
# und <java.version>25</java.version> (siehe readme.md)
#
# [update] Basis-Images UBI 10 (Build: openjdk-25, Runtime: openjdk-25-runtime)
# statt eclipse-temurin alpine. Webserver bleibt Tomcat (bewusste Entscheidung, kein Jetty).

# --- Optionaler Build-Kontext fuer git-commit-id-maven-plugin ---
# Leere Default-Stage. Mit "docker build --build-context git=.git service/" ersetzt
# BuildKit sie durch das .git-Verzeichnis des Repos (Kontext service/ enthaelt kein .git).
# Ohne den Parameter bleibt sie leer, der Build laeuft trotzdem durch,
# nur ohne git.properties (/actuator/info liefert dann {}).
FROM scratch AS git

FROM registry.access.redhat.com/ubi10/openjdk-25:latest AS build
# [update] UBI-Build-Image laeuft als User 185 mit HOME=/home/default. WORKDIR legt Verzeichnisse
# als root an, daher einmalig root: /build (Maven) und /app (Training) fuer 185 schreibbar machen.
USER root
RUN mkdir /build /app && chown 185:0 /build /app
USER 185
WORKDIR /build

# [update] Reihenfolge pom.xml -> go-offline -> src -> Build (Layer-Caching).
# Cache-Mount auf /home/default/.m2 mit uid=185, sonst lädt jeder Build alle Dependencies neu.
COPY pom.xml .
RUN --mount=type=cache,target=/home/default/.m2,uid=185 mvn -q dependency:go-offline

COPY src ./src
# JavaC Compiler Infos
# javac optimiert praktisch nicht, das übernimmt zur Laufzeit der JIT (C1/C2).
# Startzeit/Speicher gewinnt man hier über Spring AOT und den JDK-AOT-Cache.
#
# Option                      Wirkung
# -O                          Wird seit JDK 1.3 ignoriert, das Flag existiert nur noch aus Kompatibilitätsgründen
# -g:none                     Entfernt Debug-Infos. Die Klassendateien werden etwas kleiner, schneller wird die Ausführung nicht,
#                             weil der JIT diese Infos ignoriert. Stacktraces hätten dann keine Zeilennummern mehr.
# -g:lines,source             Kompromiss: nur Zeilennummern und Dateiname, ohne Namen lokaler Variablen. Gewinn kaum messbar.
#                             Maven-Default ist -g (debug=true), also alle Debug-Infos.
# -parameters                 Wird für Spring gebraucht (Parameternamen bei DI und @PathVariable). spring-boot-starter-parent setzt es
# -encoding UTF-8             Quellcode-Encoding. spring-boot-starter-parent setzt project.build.sourceEncoding=UTF-8
# -proc:full                  Seit JDK 23 ist -proc:none der Default, Annotation Processing läuft nur noch, wenn es explizit
#                             aktiviert wird. Hier nicht nötig: <annotationProcessorPaths> in der pom.xml
#                             (spring-boot-configuration-processor) erzeugt --processor-path und aktiviert es damit
# -Xlint:all                  Zusätzliche Warnungen (deprecation, unchecked, ...). Nur Codequalität, keine Performance
# -Werror                     Macht Warnungen zu Fehlern. Sinnvoll in der CI, kein Laufzeiteffekt
# -implicit:none              Keine Klassendateien für implizit mitgeladene Quellen. Bei Maven ohne Wirkung, alle Quellen sind explizit
# useIncrementalCompilation   Maven-Option, Default true.
# -T 1C (Maven)               Paralleler Build. Ohne Wirkung, hier gibt es nur ein Modul
#
# Bereits durch spring-boot-starter-parent 4.1.1 gesetzt (geprüft mit mvn help:effective-pom):
#   maven-compiler-plugin 3.15.0 mit <parameters>true</parameters>  -> -parameters
#   maven.compiler.release=${java.version} (25)                     -> --release 25
#   project.build.sourceEncoding=UTF-8                              -> -encoding UTF-8
#   debug=true (Plugin-Default, kein debuglevel)                    -> -g
#
# CPU-Limit fuer den Build: BuildKit kennt kein --cpus pro RUN-Step, daher
# begrenzt -XX:ActiveProcessorCount die CPUs, die die JVM sieht (GC-Threads,
# JIT-Compiler-Threads, ForkJoin-Pool). JAVA_TOOL_OPTIONS statt MAVEN_OPTS, weil
# spring-boot:process-aot eine eigene JVM forkt, die MAVEN_OPTS nicht sieht.
# javac laeuft im Maven-Prozess und ist damit mit abgedeckt.
# Ueberschreiben: docker build --build-arg BUILD_CPUS=4
#
# -Dmaven.test.skip=true statt -DskipTests: -DskipTests kompiliert die Tests trotzdem
# (testCompile), und zwar jedes Mal komplett neu, weil process-aot in target/classes schreibt.
# .git kommt als Bind-Mount aus der Stage "git" (siehe oben) und landet in keinem Layer.
# rw: JGit darf z.B. den Index-Cache aktualisieren, die Aenderungen werden verworfen.
# -Pdocker laesst git.dirty weg (siehe Profil in der pom.xml).
# Ohne --build-context ist /workspace/.git ein leeres Verzeichnis. Das Plugin haelt es fuer
# ein Repo und bricht ab (failOnNoGitDirectory greift nicht), daher dann ganz ueberspringen.
ARG BUILD_CPUS=2
RUN --mount=type=cache,target=/home/default/.m2,uid=185 \
    --mount=type=bind,from=git,target=/build/.git,rw \
    GIT_SKIP=$([ -f .git/HEAD ] || echo -Dmaven.gitcommitid.skip=true) && \
    JAVA_TOOL_OPTIONS="-XX:ActiveProcessorCount=${BUILD_CPUS}" \
    mvn -q -Pdocker ${GIT_SKIP} -Dmaven.test.skip=true compile spring-boot:process-aot package

# --- Extraktion + Training ---
# Ohne --launcher: der JDK-AOT-Cache funktioniert nur mit "java -jar app.jar" und einem Classpath
# aus dem Jar-Manifest (lib/*.jar). Mit dem JarLauncher (Nested-Jar-Classloader) koennen die
# Anwendungs- und Library-Klassen nicht aus dem Cache geladen werden.
# [update] --application-filename app.jar, Start zur Laufzeit mit -jar /app/app.jar.
RUN JAR=$(ls target/*.jar | grep -v original) && \
    java -Djarmode=tools -jar "$JAR" extract --layers --application-filename app.jar --destination extracted

# [update] Layer nach /app zusammenfuehren (gleiche Pfade wie zur Laufzeit, cp -a erhaelt mtime)
# und dort trainieren. Pfade, Groessen und mtimes der JARs muessen zur Runtime identisch sein.
# spring.context.exit=onRefresh beendet die App direkt nach dem Context-Refresh,
# d.h. alle beim Start geladenen/gelinkten Klassen landen im Cache, ohne dass
# der Webserver wirklich Requests annimmt.
# ACHTUNG: GC und UseCompactObjectHeaders muessen zu ENTRYPOINT (und javaOpts im Helm-Chart)
# passen, sonst verwirft die JVM den Cache beim Start (nur Warnung, dann ohne Startzeit-Gewinn).
# G1/Serial explizit setzen, sonst waehlt die JVM nach CPU/RAM des Build-Containers.
# [update] Kein "|| [ -f ... ]"-Guard: ein kaputter Trainingslauf soll den Build brechen.
WORKDIR /app
RUN for layer in dependencies observability-dependencies spring-boot-loader snapshot-dependencies application-resources application; do \
      [ -d /build/extracted/$layer ] && cp -a /build/extracted/$layer/. /app/; \
    done
RUN java -XX:AOTCacheOutput=/app/app.aot \
         -XX:+UseSerialGC \
         -XX:+UseCompactObjectHeaders \
         -Dspring.aot.enabled=true \
         -Dspring.context.exit=onRefresh \
         -jar /app/app.jar

# --- Runtime ---
# [update] Gleiche JVM wie im Build-Image (Pflicht fuer den AOT-Cache). Nach Base-Image-Updates
# beide :latest-Tags neu ziehen (docker pull).
FROM registry.access.redhat.com/ubi10/openjdk-25-runtime:latest

# [update] OCI-Labels version synchron zur pom.xml halten.
LABEL org.opencontainers.image.title="helloworld" \
      org.opencontainers.image.description="Spring Boot Hello-World (Tomcat) fuer Kubernetes mit Spring AOT und JDK-25-AOT-Cache" \
      org.opencontainers.image.version="0.0.1-SNAPSHOT" \
      org.opencontainers.image.vendor="wlanboy" \
      org.opencontainers.image.source="https://github.com/wlanboy/Java-within-kubernetes" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="registry.access.redhat.com/ubi10/openjdk-25-runtime:latest"

WORKDIR /app
# [update] Layer laut src/layers.xml einzeln (seltenste Aenderung zuerst) aus der Extraktion, COPY erhaelt die mtime.
# spring-boot-loader bleibt ohne --launcher leer, der Schritt bleibt trotzdem stehen.
COPY --from=build --chown=185:185 /build/extracted/dependencies/ ./
COPY --from=build --chown=185:185 /build/extracted/observability-dependencies/ ./
COPY --from=build --chown=185:185 /build/extracted/spring-boot-loader/ ./
COPY --from=build --chown=185:185 /build/extracted/snapshot-dependencies/ ./
COPY --from=build --chown=185:185 /build/extracted/application-resources/ ./
COPY --from=build --chown=185:185 /build/extracted/application/ ./
COPY --from=build --chown=185:185 /app/app.aot ./

# [update] User 185 (UBI-Standard) statt 1000: runAsUser/fsGroup in Charts und manifests angepasst.
USER 185
# 8080 = App, 8081 = Actuator (management.server.port)
EXPOSE 8080 8081
# [update] Exec-Form statt entrypoint.sh (Skript entfaellt). Zusaetzliche JVM-Optionen kommen aus
# JAVA_TOOL_OPTIONS (Helm: javaOpts). GC-/Header-Flags identisch zum Trainingslauf.
ENTRYPOINT ["java", \
  "-XX:AOTCache=/app/app.aot", \
  "-Dspring.aot.enabled=true", \
  "-XX:+UseSerialGC", \
  "-XX:+UseCompactObjectHeaders", \
  "-XX:+ExitOnOutOfMemoryError", \
  "-jar", "/app/app.jar"]
