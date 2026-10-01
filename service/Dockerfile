# syntax=docker/dockerfile:1

# --- Build & AOT-Verarbeitung ---
# Voraussetzung: pom.xml enthaelt <start-class>...Application</start-class>
# und <java.version>25</java.version> (siehe readme.md)
FROM eclipse-temurin:25-jdk-alpine AS builder
WORKDIR /workspace
COPY .mvn ./.mvn
COPY mvnw pom.xml ./
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
