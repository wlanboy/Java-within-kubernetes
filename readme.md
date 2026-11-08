# Java 25 Hello World in Kubernetes

Beispiel-Deployment für einen Spring-Boot-Service (Tomcat) auf Java 25 mit Spring AOT,
JDK-AOT-Cache und JVM-Tuning für wenig CPU und RAM. Dazu Kubernetes-Manifeste und zwei
Helm-Charts, gedacht für den Betrieb hinter einem Istio-Sidecar. Lokal funktioniert alles
genauso, die Istio-Annotations sind dann ohne Wirkung.

Dieses Dokument beschreibt den aktuellen Stand und begründet jede Einstellung. Wann sich was
geändert hat, steht in [change.md](change.md).

## Inhalt

- [Ergebnis in Zahlen](#ergebnis-in-zahlen)
- [Deploy](#deploy)
- [Docker-Image](#docker-image)
- [Minimaler Tomcat](#minimaler-tomcat)
- [Build-Zeit-Properties](#build-zeit-properties-applicationproperties)
- [Server-/Tomcat-Konfiguration](#server-tomcat-konfiguration-configmap)
- [JVM-Flags](#jvm-flags-java_tool_options)
- [Garbage-Collector-Guide](#garbage-collector-guide)
- [Resource-Limits](#resource-limits)
- [Speicher messen](#speicher-messen)
- [Graceful Shutdown & Istio](#graceful-shutdown--istio)
- [Verfügbarkeit & Sicherheit](#verfügbarkeit--sicherheit)
- [Geprüft, aber bewusst nicht umgesetzt](#geprüft-aber-bewusst-nicht-umgesetzt)

---

## Ergebnis in Zahlen

Gemessen im kind-Cluster mit Istio-Sidecar (`chart/`, 1 CPU, 130k Requests mit ~4300 req/s),
verglichen mit dem Stand vor den Optimierungen (eclipse-temurin, `JarLauncher`, kein AOT-Cache,
`MaxRAMPercentage=70`, Tomcat mit WebSocket und EL).

| | vorher | jetzt |
|---|---|---|
| Startzeit (`Started HelloworldApplication in ...`) | 1,7–1,9 s | 0,79 s (Docker, 1 CPU: 0,72–0,84 s) |
| Heap | 358 MB (70 % von 512Mi, voll committed) | `-Xms64m -Xmx128m`, ~30 MB belegt |
| NMT committed | 440 MB | 146 MB |
| RSS unter Last (`memory.peak`) | ~200 MiB | 111–127 MiB |
| requests / limits | 250m/256Mi, 1/512Mi | 100m/160Mi, 1/320Mi |

Den größten Anteil an der Startzeit hat der JDK-AOT-Cache, den größten Anteil am Speicher der
feste Heap. Tomcat ohne WebSocket/EL bringt nur wenige MB.

---

## Deploy

```bash
docker build --build-context git=.git -t wlanboy/helloworld:latest service/
kubectl apply -f manifests/
# oder per Helm
helm upgrade --install hello-world chart/
```

Es gibt drei Varianten mit denselben Einstellungen:

| Verzeichnis | Inhalt |
|---|---|
| [manifests/](manifests/) | rohe Manifeste, 2 Replicas |
| [chart/](chart/) | Helm-Chart, 2 Replicas |
| [chart-hpa/](chart-hpa/chart-hpa.md) | Helm-Chart mit HorizontalPodAutoscaler und Scale-to-Zero |

Änderungen an JVM-Flags, Resources oder der ConfigMap immer in allen drei nachziehen.

`--build-context git=.git` hängt das `.git`-Verzeichnis als Bind-Mount in den Maven-Build. Das
`git-commit-id-maven-plugin` erzeugt damit eine `git.properties` (Commit, Branch, Tags unter
`/actuator/info`). Der Build-Kontext `service/` enthält selbst kein `.git`. Ohne den Parameter
läuft der Build trotzdem durch, nur ohne Git-Infos.

Im Cluster baut die Tekton-Pipeline in [tekton/](tekton/readme.md) das Image mit BuildKit und pusht es.

**Hinweis zum Image-Tag.** [deployment.yaml](manifests/deployment.yaml) nutzt für dieses
Beispiel-Repo bewusst `:latest` mit `imagePullPolicy: IfNotPresent`, damit man lokal ohne
Versions-Bumps bauen und testen kann. Produktiv gehört dort ein fester Tag (z. B. `1.0.0`) oder
ein Image-Digest hin. Sonst sind Rollouts nicht reproduzierbar, und Nodes behalten ein altes
gecachtes `latest`.

---

## Docker-Image

[service/Dockerfile](service/Dockerfile) hat zwei Stages:

| Stage | Base Image | Aufgabe |
|---|---|---|
| `build` | `registry.access.redhat.com/ubi10/openjdk-25:latest` | Maven-Build mit Spring AOT, Layer extrahieren, AOT-Cache trainieren |
| Runtime | `registry.access.redhat.com/ubi10/openjdk-25-runtime:latest` | nur JRE, keine `RUN`-Befehle |

Voraussetzung in der [pom.xml](service/pom.xml):

```xml
<properties>
    <java.version>25</java.version>
    <start-class>com.example.helloworld.HelloworldApplication</start-class>
</properties>
```

### Build-Stage

| Maßnahme | Begründung |
|---|---|
| `COPY pom.xml` → `mvn dependency:go-offline` → `COPY src` → Build | Der Dependency-Layer bleibt gecacht, solange sich die `pom.xml` nicht ändert. Eine Code-Änderung lädt keine Dependencies neu. Die Reihenfolge nicht umstellen. |
| `--mount=type=cache,target=/home/default/.m2,uid=185` | Das UBI-Build-Image läuft als User 185 mit `HOME=/home/default`. Ein Mount auf `/root/.m2` würde nie benutzt. Ohne `uid=185` gehört der Mount root und Maven kann nicht schreiben. Mit Cache dauert `go-offline` nach einer `pom.xml`-Änderung ~2 s statt ~47 s. |
| `USER root`, `mkdir /build /app && chown 185:0 ...`, `USER 185` | `WORKDIR` legt fehlende Verzeichnisse als root an, dann kann Maven nicht hineinschreiben. |
| `compile spring-boot:process-aot package` | Spring AOT, siehe unten. `compile` muss vor `process-aot` laufen. |
| `-Dmaven.test.skip=true` statt `-DskipTests` | `-DskipTests` kompiliert die Tests trotzdem, und zwar jedes Mal komplett neu, weil `process-aot` in `target/classes` schreibt. |
| `JAVA_TOOL_OPTIONS="-XX:ActiveProcessorCount=${BUILD_CPUS}"` (Default 2) | BuildKit kennt kein `--cpus` pro `RUN`. So sieht die JVM nur 2 CPUs und legt entsprechend wenige GC- und JIT-Threads an. `MAVEN_OPTS` reicht nicht, weil `process-aot` eine eigene JVM forkt. |
| javac-Optionen | Bringen nichts für die Laufzeit, javac optimiert praktisch nicht. Die Liste der geprüften Optionen steht als Kommentar im Dockerfile. |

`docker build --no-cache` verwirft auch die Cache-Mounts, Maven lädt dann alles neu. Für normale
Rebuilds und Messungen ohne `--no-cache` bauen.

### Spring AOT

`spring-boot:process-aot` erzeugt beim Build Java-Code für die Bean-Definitionen. Zur Laufzeit
(`-Dspring.aot.enabled=true`) entfallen Classpath-Scanning, das Auswerten der
`@Conditional`-Annotationen und ein großer Teil der Reflection.

Der Haken: `process-aot` wertet die Bedingungen schon beim Build aus. Alles, was Beans an- oder
abschaltet, muss deshalb in der eingebauten `application.properties` stehen. Siehe
[Build-Zeit-Properties](#build-zeit-properties-applicationproperties).

### Thin-JAR und Layer

```dockerfile
java -Djarmode=tools -jar app.jar extract --layers --application-filename app.jar --destination extracted
```

Ohne `--launcher` entsteht `application/app.jar` mit einem `Class-Path`-Manifest auf
`lib/*.jar`. Gestartet wird mit `java -jar /app/app.jar`. Das ist die Voraussetzung für den
AOT-Cache: Mit `--launcher` lädt der `JarLauncher` die Klassen über einen eigenen Classloader,
und diese Klassen landen nie im Cache.

Die Layer definiert [service/src/layers.xml](service/src/layers.xml) (in der `pom.xml`
aktiviert). Das Dockerfile kopiert sie einzeln, seltenste Änderung zuerst. Bei einer
Code-Änderung baut und überträgt Docker nur den letzten Layer.

| Layer | Inhalt |
|---|---|
| `dependencies` | Release-Libraries (Spring, Tomcat, Jackson ...) |
| `observability-dependencies` | Micrometer, Prometheus, HdrHistogram, LatencyUtils |
| `spring-boot-loader` | bleibt ohne `--launcher` leer, der `COPY` bleibt trotzdem stehen |
| `snapshot-dependencies` | `*-SNAPSHOT`-Libraries |
| `application-resources` | `application*.properties`, `static/`, `templates/` |
| `application` | `app.jar` mit App-Code und AOT-generierten Klassen |

Einen neuen Layer in `layers.xml`, in der Trainings-Schleife und bei den `COPY`-Befehlen
gleichzeitig eintragen.

### JDK-AOT-Cache

Spring AOT und der JDK-AOT-Cache sind zwei verschiedene Dinge und ergänzen sich:

- **Spring AOT** ersetzt Reflection und das Auswerten der Bean-Definitionen durch generierten Code.
- **JDK-AOT-Cache** (JEP 483, 514, 515, Nachfolger von AppCDS) speichert die beim Start
  geladenen und gelinkten Klassen samt JIT-Profilen in einer Datei. Beim nächsten Start mappt
  die JVM die Datei, statt die Klassen erneut zu laden, zu verifizieren und zu linken.

Ablauf im Dockerfile:

1. Die Layer nach `/app` zusammenführen, im selben Layout wie in der Runtime-Stage. `cp -a` und
   `COPY` erhalten die mtime der JARs.
2. Trainingslauf in der Build-Stage:
   `java -XX:AOTCacheOutput=/app/app.aot -XX:+UseSerialGC -XX:+UseCompactObjectHeaders -Dspring.aot.enabled=true -Dspring.context.exit=onRefresh -jar /app/app.jar`.
   `onRefresh` beendet die App direkt nach dem Context-Refresh. Der Build braucht dafür weder
   Netzwerk noch ConfigMap.
3. `app.aot` in die Runtime-Stage kopieren, Start mit `-XX:AOTCache=/app/app.aot`.

Gemessen beim Umbau (Temurin, `docker run --cpus=1 -m 512m`, je 3 Läufe):

| | Spring-Startzeit | Prozess bis „Started“ |
|---|---|---|
| ohne AOT-Cache | 1,73–1,85 s | 2,01–2,12 s |
| mit AOT-Cache | 0,89–0,92 s | 1,06–1,22 s |

Mit dem heutigen Image (UBI, `docker run --cpus 1 -m 256m --read-only`, Flags wie im Chart,
2026-11-08): 0,72–0,84 s, Prozess bis „Started“ 0,85–1,03 s.

Der Cache ist ca. 56 MiB groß, das Image wächst entsprechend.

Damit die JVM den Cache benutzt, müssen drei Dinge passen:

- **Classpath:** Pfade, Größen und mtimes der JARs müssen im Training und zur Laufzeit gleich sein.
- **JVM-Build:** Build- und Runtime-Image brauchen exakt denselben JVM-Build (z. B. beide 25.0.5+8).
  Nach Base-Image-Updates beide `:latest`-Tags neu ziehen.
- **Flags:** GC (`-XX:+UseSerialGC`) und `-XX:+UseCompactObjectHeaders` müssen im Training, im
  ENTRYPOINT und in `JAVA_TOOL_OPTIONS` gleich sein.

Passt etwas nicht, startet die App trotzdem, nur ohne Zeitgewinn. Im Log steht dann z. B.:

```
[warning][aot] Unable to use AOT cache.
The AOT cache's UseCompactObjectHeaders setting (enabled) does not equal the current UseCompactObjectHeaders setting (disabled).
```

Nach Änderungen an diesen Flags also nach dem Deploy im Log nach `[aot]`-Warnungen suchen. Die
Meldungen `Skipping ...: Unlinked class not supported` beim **Build** sind normal.

Prüfen, ob der Cache greift:

```bash
docker run --rm --entrypoint java wlanboy/helloworld:latest \
  -XX:AOTCache=/app/app.aot -XX:+UseSerialGC -XX:+UseCompactObjectHeaders -Xlog:aot=info -version \
  | grep "Opened AOT cache"

# Anteil der Klassen aus dem Cache
docker run --rm -e JAVA_TOOL_OPTIONS="-Xlog:class+load=info:file=/tmp/cl.txt -Dspring.context.exit=onRefresh" \
  --entrypoint sh wlanboy/helloworld:latest -c \
  'java -XX:AOTCache=/app/app.aot -Dspring.aot.enabled=true -XX:+UseSerialGC -XX:+UseCompactObjectHeaders -jar /app/app.jar >/dev/null; \
   echo "$(grep -c "shared objects file" /tmp/cl.txt) von $(wc -l < /tmp/cl.txt)"'
```

Mit `spring.context.exit=onRefresh` kommen 7505 von 7689 Klassen (98 %) aus dem Cache. Ohne das
Flag zählen auch die Klassen mit, die erst der erste Request lädt, dann sinkt der Anteil
(gemessen 7511 von 8749). Ein Cache unter 1 MB ist leer.

Zwei Einschränkungen:

- Mit `TieredStopAtLevel=1` (nur C1) nützen die JIT-Profile im Cache wenig. Der Gewinn kommt
  dann aus Klassenladen und Linking.
- Nicht mit ZGC unter JDK 25: Der Cache archiviert dann keine Heap-Objekte (erst ab JDK 26,
  JEP 516), es fehlen Lambdas, Proxies und der Modul-Graph.

### Runtime-Stage

| Maßnahme | Begründung |
|---|---|
| `USER 185`, `COPY --chown=185:185` | UBI-Standarduser, kein root. In Kubernetes passend `runAsUser: 185`, `fsGroup: 185`. Der Prozess läuft mit GID 0 (`uid=185 gid=0 groups=0,185`). |
| keine `RUN`-Befehle | Das Image enthält nur, was die Build-Stage liefert. |
| `EXPOSE 8080 8081` | App und Actuator (`management.server.port`). |
| ENTRYPOINT in Exec-Form, kein Startskript | `java` ist PID 1 und bekommt SIGTERM direkt. Das braucht Graceful Shutdown. |
| OCI-Labels | `version` synchron zur `pom.xml` halten. |

**Welche Flags wohin.** Der ENTRYPOINT enthält nur die Flags, die zum Image gehören: Cache-Pfad,
`spring.aot.enabled`, GC- und Header-Flags passend zum Training sowie `ExitOnOutOfMemoryError`.
Damit nutzt auch ein nacktes `docker run` den Cache. Heap, Metaspace, CPU-Anzahl usw. kommen aus
`JAVA_TOOL_OPTIONS` (Helm-Value `javaOpts`), weil sie zu den Resources des Pods passen müssen.

Die GC- und Header-Flags stehen zusätzlich auch in `JAVA_TOOL_OPTIONS`, damit `check.py`,
`check.sh` und jeder Leser des Deployments sie sehen. Die JVM wertet `JAVA_TOOL_OPTIONS` vor der
Kommandozeile aus, bei gleichen Flags gewinnt also der ENTRYPOINT. Wer auf einen anderen GC
wechseln will, muss das Dockerfile ändern (Training und ENTRYPOINT). Steht in `javaOpts`
`-XX:+UseG1GC` und im ENTRYPOINT `-XX:+UseSerialGC`, startet die JVM nicht
(`Multiple garbage collectors selected`).

---

## Minimaler Tomcat

Tomcat bleibt bewusst (kein Jetty). `spring-boot-starter-webmvc` zieht über
`spring-boot-starter-tomcat-runtime` neben `tomcat-embed-core` auch `tomcat-embed-websocket` und
`tomcat-embed-el` mit. Beide sind in der [pom.xml](service/pom.xml) ausgeschlossen:

- **WebSocket**: Spring Boot konfiguriert WebSocket nur `@ConditionalOnClass`, ohne das JAR
  passiert nichts. Wieder aufnehmen, sobald der Service WebSockets nutzt.
- **EL** (Expression Language): braucht nur JSP und Bean Validation (Hibernate Validator
  formatiert damit Fehlermeldungen). **Wieder aufnehmen, sobald `spring-boot-starter-validation`
  dazukommt.**

Prüfen:

```bash
cd service && ./mvnw dependency:tree -Dincludes=org.apache.tomcat.embed:*
```

Der Gewinn liegt bei einigen MB und etwas weniger Klassen beim Start.

---

## Build-Zeit-Properties (`application.properties`)

Diese Properties stehen in [service/src/main/resources/application.properties](service/src/main/resources/application.properties),
nicht in der ConfigMap. `spring-boot:process-aot` wertet die zugehörigen `@Conditional`-Annotationen
beim Build aus und schreibt das Ergebnis als Bean-Definition fest. Zur Laufzeit gesetzt wären sie
wirkungslos.

| Property | Wert | Begründung |
|---|---|---|
| `management.server.port` | `8081` | Actuator auf eigenem Port. Kommt der Wert erst zur Laufzeit, läuft Actuator still auf `server.port` (8080). Die ConfigMap wiederholt den Wert nur zur Dokumentation. |
| `management.endpoints.web.exposure.include` | `health,info,prometheus` | Nur die Endpunkte, die Probes und Prometheus brauchen. |
| `spring.threads.virtual.enabled` | `true` | Jeder Request läuft auf einem eigenen Virtual Thread statt auf einem Thread aus dem Tomcat-Worker-Pool. Blockierendes I/O belegt dann keinen Plattform-Thread. Das Pinning-Problem bei `synchronized` ist seit JDK 24 behoben (JEP 491). |

Werte, die nur in eine Bean injiziert werden (Timeouts, Größen, URLs), dürfen weiter aus der
ConfigMap kommen. Darum steht der Rest unten.

---

## Server-/Tomcat-Konfiguration (ConfigMap)

[manifests/configmap.yaml](manifests/configmap.yaml) bzw. `config` in den Helm-Values. Die Datei
wird nach `/config/` gemountet und über `SPRING_CONFIG_ADDITIONAL_LOCATION=optional:file:/config/`
geladen. `additional-location` ergänzt die eingebaute `application.properties`, statt sie zu
ersetzen (anders als `spring.config.location`).

| Property | Wert | Begründung |
|---|---|---|
| `server.shutdown` | `graceful` | Tomcat nimmt keine neuen Requests mehr an und lässt laufende zu Ende laufen. Nötig, damit Rolling Updates ohne 5xx ablaufen. Das Zeitfenster begrenzt `spring.lifecycle.timeout-per-shutdown-phase`. |
| `spring.lifecycle.timeout-per-shutdown-phase` | `30s` | Muss **kleiner** sein als `terminationGracePeriodSeconds` (40 s inkl. 5 s `preStop`), sonst beendet Kubernetes den Prozess per SIGKILL mitten im Graceful Shutdown. |
| `server.http2.enabled` | `true` | Erlaubt h2c (HTTP/2 ohne TLS) für Clients, die direkt auf den Pod gehen. Hinter Istio hat es keine Wirkung: Der Service-Port heißt `http`, Envoy spricht deshalb HTTP/1.1 zur App. Für HTTP/2 zwischen Envoy und App müsste der Port `http2` heißen oder `appProtocol: h2c` haben. |
| `server.tomcat.max-connections` | `512` (Default 8192) | Mit Virtual Threads die eigentliche Grenze für gleichzeitige Requests. 8192 offene Verbindungen sind für einen 1-Core-Pod mit 320Mi hinter Istio (Envoy poolt selbst Verbindungen) viel zu viel und nur OOM-Risiko. |
| `server.tomcat.accept-count` | `100` | Warteschlange im Kernel, wenn `max-connections` erreicht ist. Kurze Lastspitzen warten, statt abgelehnt zu werden. |
| `server.tomcat.processor-cache` | `200` (= Default) | Zahl der `Processor`-Objekte, die Tomcat zur Wiederverwendung behält. Laufen mehr als 200 Requests gleichzeitig (möglich bis `max-connections`=512), erzeugt Tomcat die zusätzlichen neu und wirft sie danach weg. Bei dieser App kommt das kaum vor. Wer dauerhaft mehr parallele Requests erwartet, setzt den Wert auf `max-connections`. |
| `server.tomcat.connection-timeout` | `5s` (Default 20s) | Wie lange Tomcat nach dem Verbindungsaufbau auf die Request-Zeile wartet. Kurz, damit halb offene Verbindungen den Shutdown nicht verzögern. |
| `server.tomcat.keep-alive-timeout` | `15s` | Inaktive Keep-Alive-Verbindungen schließt Tomcat nach 15 s. Hält die Zahl offener Sockets unter `max-connections` klein. |
| `server.tomcat.max-keep-alive-requests` | `50` (Default 100) | Nach 50 Requests schließt Tomcat die Verbindung, der Client baut sie neu auf. So bleibt eine lang gehaltene Verbindung nicht dauerhaft an einem Pod hängen, und neue Pods bekommen nach einem Scale-up schneller Traffic. |
| `server.forward-headers-strategy` | `framework` | Envoy terminiert TLS und proxyt. Spring wertet die `X-Forwarded-*`-Header aus, damit Client-IP, Schema und Host in Logs und generierten URLs stimmen. |
| `server.tomcat.mbeanregistry.enabled` | `false` | Keine JMX-Registrierung der Tomcat-MBeans. Metriken laufen über Actuator/Prometheus. |
| `management.endpoint.health.probes.enabled` u. a. | `true` | Aktiviert `/actuator/health/liveness` und `/actuator/health/readiness` für die Probes. |
| `management.endpoint.health.show-details` | `never` (= Default) | Explizit gesetzt, damit keine internen Details (DB-Status, Disk-Space) sichtbar werden, falls der Endpoint doch erreichbar ist. |
| `management.metrics.tags.application` | `hello-world` | Taggt alle Metriken mit dem App-Namen, damit sich mehrere Deployments in Prometheus/Grafana unterscheiden lassen. |

`server.tomcat.threads.max` und `threads.min-spare` fehlen absichtlich. Mit Virtual Threads
nutzt Tomcat keinen Worker-Pool, beide Werte wären wirkungslos.

---

## JVM-Flags (`JAVA_TOOL_OPTIONS`)

Gesetzt in `javaOpts` (Helm) bzw. `JAVA_TOOL_OPTIONS` in [manifests/deployment.yaml](manifests/deployment.yaml).

| Flag | Begründung |
|---|---|
| `-Xms64m` / `-Xmx128m` | Fester Heap nach Messung: ~30 MB belegt nach 170k Requests. `MaxRAMPercentage`/`InitialRAMPercentage` dimensionieren nach dem Container-Limit (bei 512Mi und 70 % waren das 358 MB für ~30 MB Live-Daten), ohne Limit sogar nach dem Host-RAM. Bei mehr Live-Daten `-Xmx` und `limits.memory` gemeinsam erhöhen. |
| `-Xss512k` | Kleinere Stacks für die verbliebenen Plattform-Threads. Virtual Threads haben dynamische Stacks im Heap, für sie gilt das Flag nicht. |
| `-XX:MaxMetaspaceSize=64m` | Deckelt die Klassenmetadaten. Belegt sind ~6 MB, weil die Klassen im AOT-Cache („Shared class space“) liegen. Ohne Cache wären eher 128m nötig. |
| `-XX:ReservedCodeCacheSize=48m` | Deckelt den JIT-Code-Cache. Mit C1-only belegt ~14 MB, Default wären 240 MB reserviert. |
| `-XX:MaxDirectMemorySize=32m` | Deckelt NIO-Direct-Buffers, damit Off-Heap-Speicher nicht unbemerkt wächst. Ohne Angabe gilt `-Xmx` als Grenze. |
| `-XX:+UseSerialGC` | Kleinster Footprint bei kleinem Heap, siehe [GC-Guide](#garbage-collector-guide). Muss zum AOT-Cache passen. |
| `-XX:+UseCompactObjectHeaders` | JEP 519, ab JDK 25 Produkt-Flag. Objekt-Header 8 statt 12 Byte, typisch 10–20 % weniger Heap bei vielen kleinen Objekten. Muss zum AOT-Cache passen. |
| `-XX:ActiveProcessorCount=1` | Gleich dem CPU-Limit. Ohne Angabe leitet die JVM die CPU-Zahl je nach Version und cgroup-Setup aus der Quota oder den Node-Cores ab und legt dann zu viele GC-, JIT-, ForkJoin- und Carrier-Threads an, die unter der CFS-Quota nur gedrosselt werden. |
| `-XX:TieredStopAtLevel=1` | Nur der C1-Compiler, kein C2. Weniger Compiler-Threads, weniger CPU und Speicher. Auf 1 CPU spart das beim Start ~0,45 s, weil keine C2-Compiler-Threads mit dem Start um den Core konkurrieren (gemessen 0,73–0,80 s statt 1,2–1,3 s). Kostet Spitzendurchsatz bei CPU-lastiger Logik. Für einen I/O-gebundenen Service mit vielen kleinen Pods die bessere Wahl. |
| `-XX:+ExitOnOutOfMemoryError` | Bei einem OOM beendet sich die JVM sofort, statt in undefiniertem Zustand weiterzulaufen. Kubernetes startet den Container neu. |
| `-XX:-UsePerfData` | Kein `/tmp/hsperfdata_*`. Passt zu `readOnlyRootFilesystem`, `jcmd 1` funktioniert trotzdem. |
| `-Dspring.aot.enabled=true` | Nutzt zur Laufzeit den beim Build erzeugten AOT-Code. Ohne das Flag ignoriert Spring ihn. |

Der Cache-Pfad `-XX:AOTCache=/app/app.aot` steht nur im ENTRYPOINT, weil er zum Image gehört.

Für eine Messung `-XX:NativeMemoryTracking=summary` temporär ergänzen (siehe
[Speicher messen](#speicher-messen)). Nicht mehr verwendet werden
`-Djava.security.egd=file:/dev/./urandom` (seit JDK 9 wirkungslos, `SecureRandom` blockiert unter
Linux nicht) und G1-Optionen wie `MaxGCPauseMillis`.

---

## Garbage-Collector-Guide

| GC | Funktionsweise | Pausen | Overhead | Geeignet für |
|---|---|---|---|---|
| **Serial** (`-XX:+UseSerialGC`) | ein Thread, Stop-the-World | bei < 200 MB Heap einstellige ms | minimal, keine GC-Threads | 1 (v)CPU, kleine Heaps, viele kleine Pods |
| **Parallel** (`-XX:+UseParallelGC`) | mehrere Threads, Stop-the-World | länger, aber seltener | mittel, skaliert mit Cores | Batch-Jobs mit ≥ 2 Cores, Pausen egal |
| **G1** (`-XX:+UseG1GC`) | regionenbasiert, teils nebenläufig | Ziel per `MaxGCPauseMillis`, meist 10–100 ms | höher (Remembered Sets, mehr Threads) | normale Services mit ≥ 2 Cores und mehreren GB Heap |
| **ZGC** (`-XX:+UseZGC`) | fast vollständig nebenläufig | < 1–10 ms, unabhängig von der Heap-Größe | deutlich mehr RAM und CPU | latenzkritisch, große Heaps (≥ 4–8 GB), genug CPU-Reserve |
| **Shenandoah** (`-XX:+UseShenandoahGC`) | ähnlich ZGC | < 10 ms | ähnlich ZGC, etwas weniger RAM | latenzkritisch, wenn ZGC nicht passt |

Ohne explizite Angabe wählt die JVM G1, wenn sie mindestens 2 CPUs und 1792 MB RAM sieht,
sonst Serial. Das hängt vom Container ab, deshalb den GC immer explizit setzen. Beim AOT-Cache
ist das ohnehin Pflicht.

**Entscheidung für dieses Repo.** 1 CPU und 128 MB Heap: Serial GC. Parallele oder nebenläufige
Collectors legen mehrere Threads an, die sich unter der CFS-Quota gegenseitig drosseln. Im
MirrorService-Projekt lag der RSS mit G1 bei ~210 MiB, mit ZGC am OOM-Limit von 256 MiB.

**Wann wechseln.** Bekommt der Service ≥ 2 Cores und mehrere GB Heap, auf G1 wechseln, bei harten
Latenzanforderungen ZGC prüfen. Dafür müssen Dockerfile (Training und ENTRYPOINT), `javaOpts`,
`ActiveProcessorCount` und das CPU-Limit gemeinsam angepasst werden. ZGC unter JDK 25 verliert
einen Teil des AOT-Cache-Effekts (siehe oben).

---

## Resource-Limits

| Setting | Wert | Begründung |
|---|---|---|
| `limits.cpu` | `1` | Gleich `ActiveProcessorCount=1`. Serial GC kann den einen Core voll nutzen. |
| `requests.cpu` | `100m` | Im Leerlauf nahe 0. Erlaubt dichtes Packen der Pods auf den Nodes. Start und Lastspitzen bursten bis zum Limit. |
| `limits.memory` | `320Mi` | Rechnung siehe unten. |
| `requests.memory` | `160Mi` | Gemessener RSS unter Last (111–127 MiB) plus Puffer. |
| `ephemeral-storage` | `128Mi` / `256Mi` | Logs und `/tmp`. Das Limit deckelt Ausreißer wie Heap-Dumps. |

Rechnung für `limits.memory`, mit den gemessenen Werten (Docker, `-m 384m`, 170k Requests):

| Bereich | Obergrenze | gemessen (NMT committed) |
|---|---|---|
| Heap | 128 MB (`-Xmx`) | 64 MB (`-Xms`), davon ~30 MB belegt |
| AOT-Cache | 56 MiB (Dateigröße) | 52 MB |
| Code-Cache | 48 MB (`ReservedCodeCacheSize`) | 14 MB |
| Metaspace | 64 MB (`MaxMetaspaceSize`) | 6 MB |
| Direct Memory | 32 MB (`MaxDirectMemorySize`) | gering |
| Threads, GC, Sonstiges | ~20 MB | ~10 MB |
| **Summe** | **~350 MB** | **146 MB** |

Die Summe aller Obergrenzen liegt über 320Mi. Realistisch ist aber nur der Heap ganz ausgereizt,
Metaspace und Code-Cache bleiben weit unter ihren Deckeln. Mit vollem Heap und den gemessenen
Off-Heap-Werten landet man bei ~260 MB, das lässt ~60 MiB Puffer. `-Xmx` und `limits.memory`
deshalb immer gemeinsam ändern.

---

## Speicher messen

Das Runtime-Image ist ein JRE ohne `jcmd`. Für eine Messung im Pod
`-XX:NativeMemoryTracking=summary` per `--set javaOpts=...` ergänzen (1–2 % Overhead) und einen
JDK-Container als Ephemeral Container anhängen.

Der Debug-Container muss mit **derselben UID und GID** (185:0) laufen wie die JVM, sonst
verweigert der Kernel den Zugriff auf den Attach-Socket unter `/proc/1/root/tmp`.
`kubectl debug --profile=restricted` setzt nur die UID, deshalb die `--custom`-Datei:

```bash
cat > nmt-debug.json <<'EOF'
{"securityContext":{"runAsUser":185,"runAsGroup":0,"runAsNonRoot":true,"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}
EOF

POD=$(kubectl get pod -n <namespace> -l app=hello-world -o jsonpath='{.items[0].metadata.name}')

kubectl debug -n <namespace> $POD --image=registry.access.redhat.com/ubi10/openjdk-25:latest \
  --target=hello-world --profile=restricted --custom=nmt-debug.json \
  -c nmt -- sleep 3600

# JVM ist PID 1 im Container
kubectl exec -n <namespace> $POD -c nmt -- jcmd 1 VM.native_memory summary scale=MB
kubectl exec -n <namespace> $POD -c nmt -- jcmd 1 GC.heap_info

# Tatsächlicher Container-Verbrauch (das, was das Memory-Limit und der OOM-Killer sehen)
kubectl exec -n <namespace> $POD -c hello-world -- cat /sys/fs/cgroup/memory.current /sys/fs/cgroup/memory.peak
```

Die JDK-Version des Debug-Images muss zur JVM passen (25).

NMT „committed“ ist nicht der reale Verbrauch: Linux belegt Speicherseiten erst beim ersten
Schreiben. Für Requests und Limits zählt `memory.peak`. Bei der ersten Messung mit
`InitialRAMPercentage=70` zeigte NMT 440 MB committed, real belegt waren ~200 MiB.

[check.py](check.py) und [manifests/check.sh](manifests/check.sh) lesen CPU, Speicher,
effektive JVM-Flags und Startzeit eines laufenden Pods aus.

---

## Graceful Shutdown & Istio

- `server.shutdown=graceful` und `spring.lifecycle.timeout-per-shutdown-phase=30s`: Tomcat
  bearbeitet laufende Requests zu Ende, statt sie abzubrechen.
- `terminationGracePeriodSeconds: 40` gibt der App mehr Zeit als die 30 s von Spring, damit
  Kubernetes nicht vorher per SIGKILL beendet.
- `preStop` wartet 5 s, bevor Kubernetes SIGTERM schickt. In der Zeit entfernt Istio den Pod
  aus dem Envoy-Routing, und es kommen keine neuen Requests mehr an. Das vermeidet vereinzelte
  503 bei Rolling Updates. Umgesetzt als native Sleep-Action (`lifecycle.preStop.sleep.seconds`,
  GA seit Kubernetes 1.34): Der Kubelet wartet selbst, im Container läuft kein Prozess, und das
  Image braucht keine Shell.
- `sidecar.istio.io/nativeSidecar: "true"`: Istio injiziert `istio-proxy` als initContainer mit
  `restartPolicy: Always`. Kubernetes startet ihn vor dem App-Container und beendet ihn erst
  danach. Ohne das kann die App beim Start Requests senden, bevor Envoy bereit ist, und beim
  Shutdown ist Envoy eventuell schon weg. Im kind-Cluster geprüft: `init: istio-proxy restartPolicy=Always`.
- `proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'`: Fallback für
  Istio-Versionen ohne native Sidecars. Mit nativem Sidecar schadet es nicht.

---

## Verfügbarkeit & Sicherheit

| Setting | Wert | Begründung |
|---|---|---|
| `strategy` | `RollingUpdate`, `maxUnavailable: 0`, `maxSurge: 1` | Explizit statt Default (25 %, rundet bei 2 Replicas ungünstig). Während des Rollouts fehlt kein Pod, es läuft kurz ein dritter. |
| `startupProbe` | 30 × 2 s auf `/actuator/health/readiness` | 60 s Startbudget, ohne dass die Liveness-Probe den Pod beim Start beendet. `timeoutSeconds: 5`, weil auf 1 Core eine GC-Pause den Actuator-Call über 1 s ziehen kann. |
| Probes auf Port 8081 | `management` | Der Management-Port ist im Service nicht freigegeben, über Istio also nicht erreichbar, nur direkt an der Pod-IP. |
| `automountServiceAccountToken` | `false` | Die App braucht die Kubernetes-API nicht. Ohne Token im Pod gibt es nach einem Container-Escape keinen Token zum Missbrauchen. |
| `securityContext` | `runAsNonRoot`, `runAsUser: 185`, `readOnlyRootFilesystem`, `capabilities.drop: ["ALL"]`, `allowPrivilegeEscalation: false`, `seccompProfile: RuntimeDefault` | Grundhärtung. UID 185 passt zum UBI-Image. |
| `/tmp` als `emptyDir` mit `sizeLimit: 64Mi` | | Wegen `readOnlyRootFilesystem` das einzige beschreibbare Verzeichnis (Tomcat-Work-Dir, Attach-Socket für `jcmd`). Läuft es voll, wird nur dieser Pod evicted. |
| `podAntiAffinity` | `preferred`, `topologyKey: kubernetes.io/hostname` | Verteilt die Replicas auf verschiedene Nodes. Die PDB schützt nur vor geplantem Draining, nicht vor einem Node-Ausfall. `preferred`, damit Scheduling in kleinen Clustern nicht blockiert. |
| PDB `minAvailable: 1` | | Bei Node-Drain bleibt immer ein Pod verfügbar. |
| PDB `unhealthyPodEvictionPolicy` | `AlwaysAllow` | GA seit Kubernetes 1.31. Pods, die nicht Ready sind (z. B. CrashLoopBackOff), dürfen immer evicted werden. Mit dem Default blockiert ein kaputter Pod jeden Node-Drain. |
| Labels `app.kubernetes.io/*`, `helm.sh/chart` | nur Helm-Charts | Standard-Labels für Tools und Istio (`canonical-revision`). Nur in `labels`, der Selector bleibt `app`, weil `spec.selector` unveränderlich ist und eine Änderung jedes `helm upgrade` scheitern ließe. |

---

## Geprüft, aber bewusst nicht umgesetzt

| Vorschlag | Warum nicht |
|---|---|
| `-XX:TieredStopAtLevel=1` entfernen | Kostet auf 1 CPU ~0,45 s Startzeit und mehr CPU, bringt dafür mehr Spitzendurchsatz. Bleibt, bis Lasttests den Durchsatz pro Pod als Engpass zeigen. |
| `requests.memory` = `limits.memory` | Würde 320Mi pro Pod reservieren, gemessen sind ~120 MiB. Das Eviction-Risiko bei knappem Node-Speicher ist für dieses Beispiel akzeptiert. |
| Jetty statt Tomcat | Bringt nur einige MB und Threads. Tomcat bleibt bewusst. |
| Native Image (GraalVM) | Startet schneller und braucht weniger RAM, aber längerer Build und andere Einschränkungen. Der JVM-Weg mit AOT-Cache ist hier der Standard. |
| `enableServiceLinks: false` | Geringer Nutzen (weniger Umgebungsvariablen bei vielen Services im Namespace). |
| Probes auf dem Hauptport (`management.endpoint.health.probes.add-additional-paths=true`) | Probes bleiben auf 8081. Einschränkung: Hängt nur der Connector auf 8080, merkt die Probe das nicht. |
| Fester Image-Tag statt `latest` | Für dieses Beispiel-Repo bewusst `latest`, siehe [Deploy](#deploy). |
| Port 8081 aus den Helm-Values templaten | `management.server.port` muss wegen Spring AOT in der eingebauten `application.properties` stehen. Im Chart wäre er nicht wirklich änderbar. |
| CPU-Limit entfernen oder In-Place Pod Resize als Start-Boost | CPU-Limit 1 passt zu `ActiveProcessorCount=1` und Serial GC. Mit dem AOT-Cache ist der CPU-intensive Start ohnehin kurz. |
