# Java 25 Hello World in Kubernetes

Beispiel-Deployment für einen Spring-Boot-`hello-world.jar` auf
Java 25, inklusive AOT-Build, JVM-Tuning für geringen CPU- und RAM-Verbrauch
sowie Kubernetes-Manifesten (gedacht für Betrieb hinter einem Istio-Sidecar, funktioniert aber genauso lokal).

Voraussetzung für den Docker-Build ist ein Maven-Projekt (`pom.xml` + `src/`) neben der
`service/Dockerfile`, mit folgenden `pom.xml`-Properties
(siehe auch AOT-Vorgabe für Spring Boot/Java 25):

## Deploy

```bash
docker build --build-context git=.git -t wlanboy/helloworld:latest service/
kubectl apply -f manifests/
```

`--build-context git=.git` reicht das `.git`-Verzeichnis als Bind-Mount in den Maven-Build, damit
das `git-commit-id-maven-plugin` eine `git.properties` erzeugt (Commit, Branch, Tags unter
`/actuator/info`). Der Build-Kontext `service/` enthält selbst kein `.git`. Ohne den Parameter
läuft der Build trotzdem durch, nur ohne Git-Infos.

Im Cluster baut die Tekton-Pipeline in [tekton/](tekton/readme.md) das Image mit BuildKit und pusht es.

**Hinweis zum Image-Tag:** [deployment.yaml](manifests/deployment.yaml) nutzt bewusst `:latest` mit `imagePullPolicy: IfNotPresent` für dieses Beispiel-Repo (schnelles lokales Bauen/Testen ohne Versions-Bumps). Für den produktiven Einsatz sollte stattdessen ein gepinnter Tag (z. B. `1.0.0`) oder ein Image-Digest verwendet werden, damit Rollouts reproduzierbar bleiben und Nodes nicht dauerhaft an ein veraltetes gecachtes `latest`-Image gebunden sind.

---

## Server-/Tomcat-Konfiguration (`manifests/configmap.yaml`)

| Property | Wert | Begründung |
|---|---|---|
| `server.shutdown` | `graceful` | Tomcat nimmt keine neuen Requests mehr an, lässt laufende aber zu Ende laufen, bevor der Prozess stirbt. Zwingend nötig, damit Rolling Updates/Pod-Terminierung ohne 5xx-Fehler ablaufen. Zeitfenster wird über `spring.lifecycle.timeout-per-shutdown-phase` begrenzt. |
| `server.http2.enabled` | `true` | Reduziert Latenz durch Multiplexing/Header-Kompression, besonders relevant, wenn zusätzlich TLS-Termination am Istio-Sidecar/Ingress erfolgt. |
| 🆕 `spring.threads.virtual.enabled` | `true` (in `service/src/main/resources/application.properties`) | **NEU (2026-09-27).** Jeder Request läuft auf einem eigenen Virtual Thread statt auf einem Thread aus dem Tomcat-Worker-Pool. Blockierendes I/O belegt dann keinen Plattform-Thread mehr. Das Pinning-Problem bei `synchronized` ist seit JDK 24 behoben (JEP 491). **Muss zur Build-Zeit gesetzt sein**, nicht in der ConfigMap: `spring-boot:process-aot` wertet `@ConditionalOnThreading` beim Build aus und schreibt das Ergebnis fest (gleiches Problem wie bei `management.server.port`). |
| ~~`server.tomcat.threads.max`~~ | ~~`20`~~ **entfernt** | **ENTFERNT (2026-09-27).** Mit Virtual Threads nutzt Tomcat seinen Worker-Pool nicht mehr, der Wert wäre wirkungslos. Die Nebenläufigkeit begrenzt jetzt `server.tomcat.max-connections`. Früherer Grund: 200 Worker-Threads auf 1 Core bringen nur Context-Switching-Overhead. |
| `server.tomcat.max-connections` | `512` (statt Default `8192`) | Begrenzt offene Sockets/Speicher pro Connection. 8192 offene Verbindungen sind für einen 1-Core/512Mi-Pod hinter einem Load Balancer/Istio (das selbst schon Verbindungen poolt) weit überdimensioniert und nur unnötiges OOM-Risiko. |
| `server.tomcat.accept-count` | `100` | Wartschlange für Requests, wenn `max-connections` erreicht ist, statt sie sofort abzulehnen. Wichtig bei kurzen Lastspitzen. |
| `server.tomcat.processor-cache` | `200` (= Default) | Anzahl der `Processor`-Objekte, die Tomcat zur Wiederverwendung vorhält, statt sie bei jeder Verbindung neu zu erzeugen (GC-Druck). Explizit gesetzt, um die Kopplung an `max-connections` sichtbar zu machen: Bleibt der Wert deutlich über `max-connections`, gibt es keinen Objekt-Recycling-Overhead. |
| ~~`server.tomcat.threads.min-spare`~~ | ~~`5`~~ **entfernt** | **ENTFERNT (2026-09-27).** Aus demselben Grund wie `threads.max`: ohne Worker-Pool gibt es keine Idle-Threads, die vorgehalten werden. |
| `server.tomcat.connection-timeout` | `5s` (statt Default `20s`) | Kurz gehalten, damit offene, aber inaktive Verbindungen den graceful shutdown (nur 5s `preStop`-Puffer, siehe unten) nicht verzögern. |
| `server.tomcat.keep-alive-timeout` | `15s` | Analog zu `connection-timeout`: Keep-Alive-Verbindungen werden zügig geschlossen, statt Worker-Threads unnötig lange zu blockieren. |
| `server.tomcat.max-keep-alive-requests` | `50` (statt Default `100`) | Begrenzt, wie viele Requests über dieselbe Keep-Alive-Verbindung laufen, bevor sie geschlossen und neu aufgebaut wird. Bei nur 2 Replicas verhindert ein niedrigerer Wert, dass eine lang gehaltene Verbindung dauerhaft an einen einzelnen Pod gebunden bleibt. |
| `server.forward-headers-strategy` | `framework` | Hinter dem Istio-Sidecar terminiert Envoy TLS/Proxying; damit Spring die `X-Forwarded-*`-Header auswertet (korrekte Client-IP, Schema, Host in Logs/generierten URLs statt der internen Pod-Sicht). |
| `server.tomcat.mbeanregistry.enabled` | `false` | Deaktiviert die JMX-Registrierung der Tomcat-MBeans. Spart etwas Startzeit/Speicher, da Metriken hier über Actuator/Prometheus laufen, nicht über JMX. |
| `spring.lifecycle.timeout-per-shutdown-phase` | `30s` | Muss **kleiner** sein als `terminationGracePeriodSeconds` im Deployment (hier 40s inkl. 5s `preStop`-Puffer für Istio-Draining), sonst killt Kubernetes den Prozess per SIGKILL, bevor Graceful Shutdown fertig ist. |
| `management.server.port` | `8081` (separat von `server.port=8080`) | Actuator (Health/Metrics/Prometheus) läuft auf einem eigenen Port, der im Service (`manifests/service.yaml`) **nicht** exposed wird. Über Istio/Service ist er damit nicht erreichbar, nur direkt an der Pod-IP (siehe `management`-Containerport in `deployment.yaml`, den Probes und die `prometheus.io/port`-Annotation nutzen). |
| `management.health.probes.enabled` u.a. | `true` | Aktiviert die Kubernetes-spezifischen Actuator-Endpunkte `/actuator/health/liveness` und `/actuator/health/readiness`, die von den Probes im Deployment genutzt werden. |
| `management.endpoint.health.show-details` | `never` (= Default, explizit gesetzt) | Verhindert, dass interne Detail-Infos (DB-Status, Disk-Space etc.) über `/actuator/health` sichtbar werden, falls der Endpoint doch erreichbar ist. |
| `management.metrics.tags.application` | `hello-world` | Taggt alle Prometheus-Metriken mit dem App-Namen, damit sich die Metrikserien bei mehreren Deployments im selben Prometheus/Grafana sauber unterscheiden lassen. |

---

## JVM-Flags (`JAVA_TOOL_OPTIONS` in `manifests/deployment.yaml`)

| Flag | Begründung |
|---|---|
| ~~`-Djava.security.egd=file:/dev/./urandom`~~ **entfernt** | **ENTFERNT (2026-09-27).** Seit JDK 9 wirkungslos: `SecureRandom` nutzt unter Linux standardmäßig `NativePRNG` mit `/dev/urandom` und blockiert nicht mehr. Seit Kernel 5.6 blockiert außerdem auch `/dev/random` nach der Initialisierung nicht mehr. Der Workaround stammt aus der Java-8-Zeit. |
| 🆕 `-XX:+UseCompactObjectHeaders` | **NEU (2026-09-27).** JEP 519, seit JDK 25 regulär verfügbar: Objekt-Header 8 statt 12 Byte. Weniger Heap-Verbrauch (typisch 10–20 % bei vielen kleinen Objekten) und bessere Cache-Lokalität. **Muss zum AOT-Cache-Trainingslauf im Dockerfile passen**, siehe [AOT Cache](#-aot-cache-jdk-25). |
| ~~`-XX:NativeMemoryTracking=summary`~~ **entfernt** | **ENTFERNT (2026-11-08)** nach der Messung, siehe [Speicher messen](#-speicher-messen-native-memory-tracking). Für neue Messungen temporär per `--set javaOpts=...` ergänzen. |
| 🆕 `-XX:AOTCache=/app/app.aot` | **NEU (2026-09-27).** Steht im ENTRYPOINT des Dockerfiles, nicht in `javaOpts`, weil der Pfad zum Image gehört. Siehe [AOT Cache](#-aot-cache-jdk-25). |
| `-XX:+ExitOnOutOfMemoryError` | Lässt die JVM bei einem echten OOM sofort beenden, statt in einem undefinierten Zombie-Zustand weiterzulaufen. In Kubernetes ist das erwünscht: Der Container stirbt sauber, die Liveness-Probe schlägt fehl (oder der Exit passiert direkt) und Kubernetes startet den Pod neu. |
| 🆕 `-Xms64m` / `-Xmx128m` | **NEU (2026-11-08)**, ersetzt `MaxRAMPercentage=70` / `InitialRAMPercentage=70`. Bei 512Mi-Limit waren das 358 MB Heap, voll committed, für ~30 MB Live-Daten. Fester Heap nach Messung (siehe [Speicher messen](#-speicher-messen-native-memory-tracking)). Bei mehr Live-Daten `-Xmx` und `limits.memory` gemeinsam erhöhen. |
| 🆕 `-Xss512k` | **NEU (2026-11-08).** Kleinere Stacks für die verbleibenden Plattform-Threads. Requests laufen auf Virtual Threads, deren Stacks wachsen dynamisch im Heap. |
| `-XX:MaxMetaspaceSize=64m` | Deckelt Klassenmetadaten-Speicher (sonst unbegrenzt → Risiko für natives OOM außerhalb des Heaps). **2026-11-08:** 96m → 64m, belegt sind ~6 MB, weil die Klassen im AOT-Cache („Shared class space“) liegen. |
| 🆕 `-XX:ReservedCodeCacheSize=48m` | **NEU (2026-11-08).** Deckelt den JIT-Code-Cache. Mit C1-only (`TieredStopAtLevel=1`) belegt: ~14 MB. Default wäre 240 MB reserviert. |
| `-XX:MaxDirectMemorySize=32m` | Deckelt NIO-Direct-Buffers (von Tomcat genutzt), verhindert unbemerktes Off-Heap-Wachstum. |
| `-XX:-UsePerfData` | Kein Schreiben von `/tmp/hsperfdata_*`; passt zu `readOnlyRootFilesystem: true` und spart I/O. |
| `-XX:+UseSerialGC` | Siehe [GC-Guide](#garbage-collector-guide) unten. Bewusst gewählt, weil der Pod nur 1 CPU-Core hat. |
| `-XX:ActiveProcessorCount=1` | Muss exakt zum CPU-`limit` im Deployment passen. Ohne explizite Angabe leitet die JVM die sichtbaren Cores teils aus `cpu.shares`/Node-Cores statt aus dem tatsächlichen `limit` ab und legt dann zu viele GC-/JIT-Compiler-Threads an, die unter dem CFS-Quota nur throtteln statt zu arbeiten. |
| `-XX:TieredStopAtLevel=1` | Beschränkt den JIT auf den C1-Compiler (kein aufwendiges C2-Tiering). Reduziert Compiler-Threads, RAM- und CPU-Verbrauch und verkürzt die Zeit bis zur "warmen" Performance, auf Kosten von etwas Peak-Throughput bei sehr lange laufenden, rechenintensiven Prozessen. Für kleine, horizontal skalierte Services (viele kurzlebige Pods, kein Dauerlast-Batch-Job) meist die bessere Wahl. In Kombination mit `spring.aot.enabled=true` (AOT-Verarbeitung, siehe Dockerfile) besonders wirksam für schnellen Start. |
| `-Dspring.aot.enabled=true` | Aktiviert zur Laufzeit die Nutzung der beim Build per `spring-boot:process-aot` generierten AOT-Metadaten (weniger Reflection/Proxy-Arbeit beim Start → schnellerer, ressourcenschonenderer Boot). |

---

## 🆕 AOT Cache (JDK 25)

**NEU (2026-09-27).** Spring AOT (`process-aot`) und der JDK-AOT-Cache sind zwei verschiedene Dinge, die sich ergänzen:

- **Spring AOT** ersetzt Reflection und Bean-Definition-Parsing durch generierten Code.
- **JDK-AOT-Cache** (JEP 483, 514, 515) speichert die beim Start geladenen und gelinkten Klassen (inkl. Methoden-Profilen) in einer Datei. Beim nächsten Start mappt die JVM diese direkt, statt sie erneut zu laden, zu verifizieren und zu linken.

**Umsetzung:**

1. `service/Dockerfile`: Extraktion **ohne** `--launcher`. Der Cache funktioniert nur mit `java -jar application.jar` und dem Classpath aus dem Jar-Manifest. Mit dem `JarLauncher` (Nested-Jar-Classloader) lassen sich die Anwendungs- und Library-Klassen nicht aus dem Cache laden.
2. `service/Dockerfile`: Trainingslauf in der Runtime-Stage mit `-XX:AOTCacheOutput=app.aot -Dspring.context.exit=onRefresh`. `onRefresh` beendet die App direkt nach dem Context-Refresh, der Build braucht also kein Netzwerk und keine ConfigMap. Er läuft in der Runtime-Stage, weil der Cache nur mit exakt derselben JVM gültig ist.
3. `service/Dockerfile` (ENTRYPOINT, Exec-Form): `java -XX:AOTCache=/app/app.aot ... -jar /app/app.jar`.

**Gemessen** (lokal, `docker run --cpus=1 -m 512m`, je 3 Läufe):

| | Spring-Startzeit | Prozess bis „Started“ |
|---|---|---|
| ohne AOT-Cache | 1,73–1,85 s | 2,01–2,12 s |
| mit AOT-Cache | 0,89–0,92 s | 1,06–1,22 s |

Im kind-Cluster mit Istio-Sidecar: `Started HelloworldApplication in 0.899 seconds`. Der Cache ist ca. 55 MB groß.

**Wichtig: Flags müssen übereinstimmen.** GC (`-XX:+UseSerialGC`) und `-XX:+UseCompactObjectHeaders` müssen im Trainingslauf und in `javaOpts` gleich sein. Sonst verwirft die JVM den Cache. Die App startet dann trotzdem, nur ohne Zeitgewinn, und im Log steht:

```
[warning][aot] Unable to use AOT cache.
The AOT cache's UseCompactObjectHeaders setting (enabled) does not equal the current UseCompactObjectHeaders setting (disabled).
```

Nach Änderungen an diesen Flags im Chart also immer auch das Dockerfile anpassen und nach dem Deploy im Log auf `[aot]`-Warnungen prüfen. Die Warnungen `Skipping ...: Unlinked class not supported` beim **Build** sind normal (einzelne Klassen, die beim Training nicht vollständig gelinkt wurden).

**Hinweis:** `-XX:+UseCompactObjectHeaders` ist auch in `manifests/deployment.yaml` gesetzt, der Cache wird dort also ebenfalls genutzt.

---

## 🆕 Speicher messen (Native Memory Tracking)

**NEU (2026-09-27).** Mit `-XX:NativeMemoryTracking=summary` in `javaOpts` lässt sich der Speicher der JVM im laufenden Pod aufschlüsseln. Das Runtime-Image ist ein JRE ohne `jcmd`, deshalb wird ein JDK-Container als Ephemeral Container an den Pod gehängt.

Der Debug-Container muss mit **derselben UID und GID** (185:0, UBI-Default) laufen wie die JVM, sonst verweigert der Kernel den Zugriff auf `/proc/1/root/tmp` (Attach-Socket). `kubectl debug --profile=restricted` allein setzt nur die UID, die GID bleibt 0. Daher die `--custom`-Datei:

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

# Tatsaechlicher Container-Verbrauch (das, was das Memory-Limit/OOMKill sieht)
kubectl exec -n <namespace> $POD -c hello-world -- cat /sys/fs/cgroup/memory.current /sys/fs/cgroup/memory.peak
```

Die JDK-Version des Debug-Images muss zur JVM passen (25). `-XX:-UsePerfData` stört nicht, `jcmd <pid>` funktioniert auch ohne `hsperfdata`.

**Erste Messung** (kind-Cluster, Istio-Sidecar, nach 20 s Last mit ~3400 req/s):

| Bereich (NMT) | committed |
|---|---|
| Java Heap | 360 MB (voll committed wegen `InitialRAMPercentage=70`) |
| Shared class space (AOT-Cache) | 51 MB |
| Code | 13 MB |
| Metaspace | 6 MB |
| Symbol, Thread, GC, Internal, NMT, Class | je 1–2 MB |
| **Total** | **440 MB** |

| Messgröße | Wert |
|---|---|
| Heap tatsächlich belegt (`GC.heap_info`) | ~26 MB (Eden 12 MB, Tenured 13 MB von 240 MB) |
| cgroup `memory.current` / `memory.peak` | 200 MiB / 202 MiB |
| Threads | 26 |

**Interpretation:**

- NMT „committed“ ist nicht gleich realer Verbrauch: Linux belegt Speicherseiten erst beim ersten Schreiben. Vom Tenured-Bereich wurden bisher nur ~5 % berührt, daher ~200 MiB real statt 440 MB.
- **Worst Case** (Tenured läuft einmal voll, bevor ein Full GC aufräumt): ~440 MB plus malloc außerhalb von NMT. Das liegt unter `limits.memory: 512Mi`, der Puffer beträgt aber nur ~70 MiB.
- `requests.memory: 256Mi` passt zum gemessenen Ruhezustand (~200 MiB), der Worst Case liegt jedoch deutlich darüber. Bei knappem Node-Speicher kann der Pod daher zuerst evicted werden.
- Die Live-Daten der Hello-World-App (~26 MB) sind im Vergleich zum 360-MB-Heap sehr klein. Für einen echten Service mit mehr Live-Daten gilt das nicht, deshalb hier noch keine Änderung an `resources`/`MaxRAMPercentage`. Erst mit realistischer Last messen und dann anpassen.

**Zweite Messung (2026-11-08)** mit festem Heap `-Xms64m -Xmx128m`, Tomcat ohne WebSocket/EL:

| Messgröße | Docker (`-m 384m --cpus 1`, 170k Requests) | kind (`chart/`, 130k Requests, ~4300 req/s) |
|---|---|---|
| NMT committed gesamt | 146 MB (Heap 64, AOT-Cache 52, Code 14, Metaspace 6) | |
| Heap belegt | ~30 MB (Tenured 16 MB) | |
| RSS / `memory.peak` | 119 MiB | 111–127 MiB |
| Startzeit | 0,77 s | 0,79 s |

Daraus: `requests.memory: 160Mi`, `limits.memory: 320Mi` (Heap 128 + AOT-Cache 64 + Code-Cache 48 + Metaspace + Direct 32 + Threads/GC), `requests.cpu: 100m`.

---

## Garbage-Collector-Guide

### Übersicht

| GC | Funktionsweise | Pause-Ziel | Typischer Speicher-/CPU-Overhead | Geeignet für |
|---|---|---|---|---|
| **Serial GC** (`-XX:+UseSerialGC`) | Ein einziger Thread für Minor+Major GC, Stop-the-World | Kurze Pausen bei **kleinem** Heap, keine Parallelität nötig | Minimal, kein zusätzlicher GC-Thread-Pool | Container mit **1 (v)CPU**, kleine Heaps (< ~1–2 GB), viele kurzlebige/horizontal skalierte Pods |
| **Parallel GC** (`-XX:+UseParallelGC`) | Mehrere Threads für Minor+Major GC, Stop-the-World | Höhere, aber seltenere Pausen | Mittel, skaliert mit Core-Zahl | Batch-/Durchsatz-orientierte Jobs mit ≥2 Cores, Pausenzeiten irrelevant |
| **G1 GC** (`-XX:+UseG1GC`, **Default seit JDK 9** bei ≥2 Cores & ≥2 GB Heap) | Region-basiert, überwiegend parallel, teils konkurrent | Ziel: einstellbare Pausenzeit (`-XX:MaxGCPauseMillis`), i. d. R. wenige 10–100ms | Höher als Serial/Parallel (Remembered Sets, mehr GC-Threads) | "Normale" Services mit ≥2 Cores und mehreren GB Heap, guter Allround-Default |
| **ZGC** (`-XX:+UseZGC`) | Region-basiert, fast vollständig konkurrent | < 1–10ms, praktisch heap-größenunabhängig | Deutlich mehr RAM/CPU-Grundlast (Colored Pointers/Load Barriers, mehr Concurrent-Threads); in kleinen/eng limitierten Containern oft instabil (OOM statt G1) | Latenzkritische Services mit **großen Heaps (≥4–8 GB)** und genug CPU-Headroom für Concurrent-Threads |
| **Shenandoah** (`-XX:+UseShenandoahGC`) | Ähnlich ZGC, konkurrentes Compaction | < 10ms, weitgehend heap-größenunabhängig | Ähnlich ZGC, tendenziell etwas weniger RAM-Overhead als ZGC | Latenzkritische Services, bei denen ZGC nicht verfügbar ist oder feineres Tuning gewünscht ist |

### Entscheidungsgrundlage

1. **Wie viele CPU-Cores stehen dem Container zur Verfügung?**
   - **1 Core / stark CPU-throttled** (typisch: kleine Microservices hinter Istio, `cpu.limit ≤ 1`) → **Serial GC**. Parallele/konkurrente Collectors legen mehrere GC-Threads an, die sich unter dem CFS-Quota gegenseitig throtteln und in Summe *mehr* Overhead erzeugen als der einfache, einthreadige Serial-Collector. Das ist der Grund, warum dieses Deployment `-XX:+UseSerialGC` + `-XX:ActiveProcessorCount=1` kombiniert.
   - **≥2 Cores** → G1 (Default) ist i. d. R. die richtige Wahl, ohne dass man überhaupt etwas explizit setzen muss.

2. **Wie groß ist der Heap?**
   - Kleiner Heap (Hello-World-/CRUD-Service, wenige hundert MB) → Serial oder G1 reichen; ZGC/Shenandoah lohnen den Overhead nicht.
   - Großer Heap (mehrere GB, z. B. Caching-/Aggregations-Services) → G1 als Standard, ZGC/Shenandoah wenn Pausenzeiten trotzdem spürbar/kritisch sind.

3. **Ist Latenz oder Durchsatz wichtiger?**
   - Durchsatz/Batch, Pausen egal → Parallel GC.
   - Ausgewogen, Standardfall → G1.
   - Harte Low-Latency-Anforderung (z. B. < 10ms p99 GC-Pause) UND genug RAM/CPU-Puffer für den Concurrent-Overhead → ZGC oder Shenandoah.

4. **Faustregel für dieses Repo:** Solange der Pod auf 1 Core / ≤512Mi limitiert bleibt, **Serial GC beibehalten**. Wird der Service später auf ≥2 Cores und mehrere GB Heap skaliert (z. B. weil er nicht mehr nur "Hello World" macht), `-XX:+UseSerialGC` entfernen und auf G1-Default wechseln bzw. bei Bedarf ZGC evaluieren. Dann auch `-XX:ActiveProcessorCount` und `server.tomcat.threads.max` entsprechend mit hochziehen.

---

## Resource-Limits (`manifests/deployment.yaml`)

| Setting | Wert | Begründung |
|---|---|---|
| `resources.limits.cpu` | `1` | Deckt sich mit `-XX:ActiveProcessorCount=1` und der Wahl von Serial GC. Ein einzelner GC-Thread kann den einen verfügbaren Core voll nutzen, ohne dass CFS-Throttling zwischen mehreren GC-Threads hin- und herschaltet. |
| `resources.requests.cpu` | `100m` (bis 2026-11-08: `250m`) | Im Leerlauf nahe 0. Erlaubt Kubernetes ein engeres Bin-Packing im Node, während Burst bis zum Limit (1 Core) für Lastspitzen/Start (AOT-Klassenladen, JIT) möglich bleibt. |
| `resources.limits.memory` | `320Mi` (bis 2026-11-08: `512Mi`) | Heap `-Xmx128m` + AOT-Cache (~64 MB) + Code-Cache (`48m`) + Metaspace (belegt ~6 MB, Deckel `64m`) + Direct-Memory (`32m`) + Thread-Stacks/GC. Gemessener Peak: 127 MiB. |
| `resources.requests.memory` | `160Mi` (bis 2026-11-08: `256Mi`) | Gemessener RSS unter Last (111–127 MiB) plus Puffer. |

**Wichtig:** `-Xmx` und `limits.memory` immer gemeinsam ändern. Der Speicher außerhalb des Heaps (AOT-Cache, Code-Cache, Metaspace, Direct-Memory, Threads) liegt hier bei ~150–190 MB.

---

## Graceful Shutdown & Istio

- `server.shutdown=graceful` + `spring.lifecycle.timeout-per-shutdown-phase=30s` sorgen dafür, dass Tomcat laufende Requests zu Ende bearbeitet, statt sie hart zu kappen.
- `terminationGracePeriodSeconds: 40` im Deployment gibt der Anwendung mehr Zeit als die 30s Spring-internes Timeout, damit Kubernetes nicht per SIGKILL dazwischenfunkt.
- Der `preStop`-Hook (`sleep 5`) verzögert den eigentlichen Shutdown kurz, damit der Istio-Sidecar den Pod aus dem Envoy-Routing entfernen kann, bevor Tomcat aufhört, neue Verbindungen anzunehmen. Vermeidet vereinzelte 503er während Rolling Updates.
- 🆕 **NEU (2026-09-27): native preStop-Sleep-Action** in den Helm-Charts (`lifecycle.preStop.sleep.seconds`, GA seit Kubernetes 1.34) statt `exec: sh -c "sleep 5"`. Der Kubelet wartet selbst, dafür braucht das Image weder Shell noch `sleep`-Binary, und es entsteht kein zusätzlicher Prozess im Container. [update] Das Image (UBI 10) nutzt Exec-Form-ENTRYPOINT und `JAVA_TOOL_OPTIONS`, `entrypoint.sh` entfällt.
- 🆕 **NEU (2026-09-27): Istio als nativer Sidecar** (Pod-Annotation `sidecar.istio.io/nativeSidecar: "true"`). Istio injiziert `istio-proxy` dann als initContainer mit `restartPolicy: Always`. Kubernetes startet ihn garantiert **vor** dem App-Container und beendet ihn erst **nach** ihm. Ohne das kann die App beim Start Requests senden, bevor Envoy bereit ist, und während preStop + Graceful Shutdown ist Envoy eventuell schon beendet, sodass ausgehende Requests fehlschlagen. Im kind-Cluster geprüft: `init: istio-proxy restartPolicy=Always`.
- 🆕 **NEU (2026-09-27): `proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'`** als Fallback für Cluster/Istio-Versionen ohne native Sidecars. Mit nativem Sidecar ist das Verhalten ohnehin implizit, die Annotation schadet dann nicht.

---

## Verfügbarkeit & Sicherheit (`manifests/deployment.yaml`)

| Setting | Wert | Begründung |
|---|---|---|
| `spec.strategy` | `RollingUpdate`, `maxUnavailable: 0`, `maxSurge: 1` | Explizit statt Default (25 % auf/ab, rundet bei `replicas: 2` ungünstig). Während des Rollouts darf kein Pod fehlen, stattdessen läuft kurzzeitig ein dritter Pod zusätzlich. Garantiert Zero-Downtime-Deploys, statt sich auf Rundungsverhalten zu verlassen. |
| `automountServiceAccountToken` | `false` | Die App braucht keinen Zugriff auf die Kubernetes-API. Kein Service-Account-Token im Pod reduziert die Angriffsfläche, weil es keinen Token gibt, der bei einem Container-Escape missbraucht werden könnte. Ergänzt die übrigen Security-Einstellungen (`runAsNonRoot`, `readOnlyRootFilesystem`, `capabilities.drop: ["ALL"]`, `seccompProfile`). |
| `affinity.podAntiAffinity` | `preferredDuringSchedulingIgnoredDuringExecution`, `topologyKey: kubernetes.io/hostname` | Die `PodDisruptionBudget` (`minAvailable: 1`) schützt nur vor freiwilligem Draining, nicht vor einem Node-Ausfall. Anti-Affinity verteilt die beiden Replicas bevorzugt auf unterschiedliche Nodes. `preferred` statt `required`, damit das Scheduling auch bei wenigen verfügbaren Nodes (z. B. lokal/Test-Cluster) nicht blockiert. |
| 🆕 `podDisruptionBudget.unhealthyPodEvictionPolicy` | `AlwaysAllow` | **NEU (2026-09-27).** GA seit Kubernetes 1.31. Pods, die nicht Ready sind (z. B. CrashLoopBackOff), dürfen immer evicted werden. Mit dem Default `IfHealthyBudget` zählt ein kaputter Pod gegen das Budget und blockiert jeden Node-Drain, obwohl er ohnehin keinen Traffic bedient. |
| 🆕 `volumes[tmp].emptyDir.sizeLimit` | `64Mi` (`tmpSizeLimit`) | **NEU (2026-09-27).** `/tmp` ist wegen `readOnlyRootFilesystem` das einzige beschreibbare Verzeichnis (Tomcat-Work-Dir, JVM-Attach-Socket für `jcmd`). Ohne Limit könnte ein volllaufendes `/tmp` den Node-Speicher belasten. Mit Limit wird nur dieser Pod evicted. |
| 🆕 Labels `app.kubernetes.io/*`, `helm.sh/chart` | `name`, `instance`, `version`, `managed-by`, `chart` | **NEU (2026-09-27).** Kubernetes-Standard-Labels für Tools (Dashboards, `kubectl`-Filter, Kiali). Istio nutzt `app.kubernetes.io/version` außerdem für `service.istio.io/canonical-revision`. **Nur in `labels`, nicht im Selector:** `spec.selector` eines Deployments ist unveränderlich, eine Änderung würde jedes `helm upgrade` bestehender Releases scheitern lassen. Der Selector bleibt deshalb bei `app`. |

---

## 🆕 Änderungsprotokoll 2026-09-27: Review der Helm-Charts

Gilt für `chart/` und `chart-hpa/` gleichermaßen. In `manifests/` ist bisher nur `-XX:+UseCompactObjectHeaders` nachgezogen.

### Hinzugefügt

| Änderung | Wo | Warum | Details |
|---|---|---|---|
| JDK-AOT-Cache | `service/Dockerfile` | Startzeit etwa halbiert (gemessen 0,9 s statt 1,8 s), wichtig für Scale-up und Scale-from-zero | [AOT Cache](#-aot-cache-jdk-25) |
| `-XX:+UseCompactObjectHeaders` | `javaOpts`, `manifests/deployment.yaml`, Dockerfile-Training | weniger Heap | [JVM-Flags](#jvm-flags-java_opts-in-manifestsdeploymentyaml) |
| `-XX:NativeMemoryTracking=summary` | `javaOpts` | `resources.memory` auf Messwerte statt Schätzung stützen (2026-11-08 nach der Messung wieder entfernt) | [Speicher messen](#-speicher-messen-native-memory-tracking) |
| Virtual Threads | `application.properties` (Build-Zeit) | Blockierendes I/O belegt keine Plattform-Threads | [Server-/Tomcat-Konfiguration](#server-tomcat-konfiguration-manifestsconfigmapyaml) |
| native preStop-Sleep | `deployment.yaml` | keine Shell für den Hook nötig | [Graceful Shutdown & Istio](#graceful-shutdown--istio) |
| Istio nativer Sidecar + `holdApplicationUntilProxyStarts` | `podAnnotations` | korrekte Start-/Stop-Reihenfolge App ↔ Envoy | [Graceful Shutdown & Istio](#graceful-shutdown--istio) |
| PDB `unhealthyPodEvictionPolicy: AlwaysAllow` | `poddisruptionbudget.yaml` | kaputte Pods blockieren keinen Node-Drain | [Verfügbarkeit & Sicherheit](#verfügbarkeit--sicherheit-manifestsdeploymentyaml) |
| `emptyDir.sizeLimit` für `/tmp` | `deployment.yaml` | Node-Speicher schützen | [Verfügbarkeit & Sicherheit](#verfügbarkeit--sicherheit-manifestsdeploymentyaml) |
| Standard-Labels | `_helpers.tpl` | Tooling/Istio, Selector unverändert | [Verfügbarkeit & Sicherheit](#verfügbarkeit--sicherheit-manifestsdeploymentyaml) |

### Entfernt

| Änderung | Warum |
|---|---|
| `-Djava.security.egd=file:/dev/./urandom` | seit JDK 9 wirkungslos, `SecureRandom` blockiert unter Linux nicht mehr |
| `server.tomcat.threads.max=20`, `server.tomcat.threads.min-spare=5` | mit Virtual Threads wirkungslos (kein Worker-Pool mehr) |
| `--launcher` bei der Jar-Extraktion, `JarLauncher` im Entrypoint | verhindert, dass der AOT-Cache Anwendungs- und Library-Klassen lädt |

### Geprüft, aber bewusst nicht umgesetzt

| Vorschlag | Warum nicht (vorerst) |
|---|---|
| `requests.memory` = `limits.memory` | Nicht übernommen. **2026-11-08:** `MaxRAMPercentage` durch festen Heap ersetzt, Requests/Limits nach Messung gesenkt (siehe [Resource-Limits](#resource-limits-manifestsdeploymentyaml)). |
| `-XX:TieredStopAtLevel=1` entfernen | Trade-off: schnellerer Start und weniger CPU gegen geringeren Spitzendurchsatz (kein C2). Beibehalten, bis Lasttests zeigen, dass der Durchsatz pro Pod der Engpass ist. Hinweis: Die Methoden-Profile im AOT-Cache (JEP 515) nützen vor allem C2, mit C1-only bringt der Cache vor allem Klassenladen/Linking. |
| `enableServiceLinks: false` | Nicht übernommen. Nur geringer Nutzen (weniger Umgebungsvariablen bei vielen Services im Namespace). |
| Probes auf dem Hauptport (`management.endpoint.health.probes.add-additional-paths=true`) | Nicht übernommen. Probes bleiben auf dem separaten Management-Port 8081. Einschränkung: Hängt nur der Haupt-Connector (8080), bemerkt die Probe das nicht. |
| Image-Tag fest statt `latest` + `pullPolicy: Always` | Nicht übernommen. Für dieses Beispiel-Repo bewusst `latest`, siehe Hinweis unter [Deploy](#deploy). |
| Port 8081 aus `values.ports.management` templaten | Nicht übernommen. `management.server.port` muss wegen Spring AOT ohnehin zur Build-Zeit in `application.properties` stehen, das Templaten im Chart würde ihn nicht wirklich änderbar machen. |
| CPU-Limit entfernen / In-Place Pod Resize für Start-Boost | Nicht übernommen. CPU-Limit 1 passt zu `ActiveProcessorCount=1` und Serial GC. Mit dem AOT-Cache ist der CPU-intensive Start ohnehin kürzer. |
| Shell komplett aus dem Image entfernen | Nicht möglich, solange `entrypoint.sh` `${JAVA_OPTS}` expandiert. Alternative wäre `JAVA_TOOL_OPTIONS` + Exec-Form-`ENTRYPOINT`. |

---

