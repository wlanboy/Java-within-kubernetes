# syntax=docker/dockerfile:1

# --- Build & AOT-Verarbeitung ---
# Voraussetzung: pom.xml enthaelt <start-class>...Application</start-class>
# und <java.version>25</java.version> (siehe readme.md)
FROM eclipse-temurin:25-jdk-alpine AS builder
WORKDIR /workspace
COPY pom.xml .
COPY src ./src
RUN --mount=type=cache,target=/root/.m2 mvn -q -DskipTests compile spring-boot:process-aot package

# --- Layer-Extraktion (kleineres, cachefreundlicheres Runtime-Image) ---
FROM eclipse-temurin:25-jdk-alpine AS extractor
WORKDIR /workspace
COPY --from=builder /workspace/target/*.jar app.jar
RUN java -Djarmode=tools -jar app.jar extract --layers --destination extracted

# --- Runtime ---
FROM eclipse-temurin:25-jre-alpine
# feste UID/GID, damit sie exakt zu runAsUser/fsGroup in manifests/deployment.yaml passen
RUN addgroup -g 1000 -S spring && adduser -u 1000 -S spring -G spring
WORKDIR /app
COPY --from=extractor /workspace/extracted/dependencies/ ./
COPY --from=extractor /workspace/extracted/spring-boot-loader/ ./
COPY --from=extractor /workspace/extracted/snapshot-dependencies/ ./
COPY --from=extractor /workspace/extracted/application/ ./
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && chown -R spring:spring /app

# numerisch statt namentlich, damit runAsNonRoot/runAsUser in
# manifests/deployment.yaml die UID zuverlaessig auswerten koennen
USER 1000:1000
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
