# Java within Kubernetes – Hello World (Java 25 Runtime)

Beispiel-Deployment für einen Spring-Boot-`hello-world.jar` auf
Java 25, inklusive AOT-Build, JVM-Tuning für geringen CPU und RAM Verbrauch.
Kubernetes-Manifesten (gedacht für Betrieb hinter einem Istio-Sidecar, funktioniert aber genauso lokal).

Voraussetzung für den Docker-Build ist ein Maven-Projekt (`pom.xml` + `src/`) neben der
`service/Dockerfile`, mit folgenden `pom.xml`-Properties
(siehe auch AOT-Vorgabe für Spring Boot/Java 25):

## Deploy

```bash
docker build -t your-registry.example.com/hello-world:1.0.0 service/
kubectl apply -f manifests/
```

---

## Server-/Tomcat-Konfiguration (`manifests/configmap.yaml`)

| Property | Wert | Begründung |
|---|---|---|
| `server.shutdown` | `graceful` | Tomcat nimmt keine neuen Requests mehr an, lässt laufende aber zu Ende laufen, bevor der Prozess stirbt. Zwingend nötig, damit Rolling Updates/Pod-Terminierung ohne 5xx-Fehler ablaufen. Zeitfenster wird über `spring.lifecycle.timeout-per-shutdown-phase` begrenzt. |
| `server.http2.enabled` | `true` | Reduziert Latenz durch Multiplexing/Header-Kompression, besonders relevant, wenn zusätzlich TLS-Termination am Istio-Sidecar/Ingress erfolgt. |
| `server.tomcat.threads.max` | `20` (statt Default `200`) | Pod hat nur **1 CPU-Core** als Limit (siehe unten). 200 Worker-Threads auf einem Core bringen nur Context-Switching-Overhead statt Durchsatz. 20 Threads sind für ein Hello-World-Workload mit I/O-Wartezeiten ausreichend dimensioniert; bei höherem CPU-Limit entsprechend hochskalieren. |
| `server.tomcat.max-connections` | `512` (statt Default `8192`) | Begrenzt offene Sockets/Speicher pro Connection. 8192 offene Verbindungen sind für einen 1-Core/512Mi-Pod hinter einem Load Balancer/Istio (das selbst schon Verbindungen poolt) weit überdimensioniert und nur unnötiges OOM-Risiko. |
| `server.tomcat.accept-count` | `100` | Wartschlange für Requests, wenn `max-connections` erreicht ist, statt sie sofort abzulehnen – wichtig bei kurzen Lastspitzen. |
| `server.tomcat.processor-cache` | `200` (= Default) | Anzahl der `Processor`-Objekte, die Tomcat zur Wiederverwendung vorhält, statt sie bei jeder Verbindung neu zu erzeugen (GC-Druck). Explizit gesetzt, um die Kopplung an `max-connections` sichtbar zu machen: Bleibt der Wert deutlich über `max-connections`, gibt es keinen Objekt-Recycling-Overhead. |
| `spring.lifecycle.timeout-per-shutdown-phase` | `30s` | Muss **kleiner** sein als `terminationGracePeriodSeconds` im Deployment (hier 40s inkl. 5s `preStop`-Puffer für Istio-Draining), sonst killt Kubernetes den Prozess per SIGKILL, bevor Graceful Shutdown fertig ist. |
| `management.health.probes.enabled` u.a. | `true` | Aktiviert die Kubernetes-spezifischen Actuator-Endpunkte `/actuator/health/liveness` und `/actuator/health/readiness`, die von den Probes im Deployment genutzt werden. |

---

## JVM-Flags (`JAVA_OPTS` in `manifests/deployment.yaml`)

| Flag | Begründung |
|---|---|
| `-Djava.security.egd=file:/dev/./urandom` | Verhindert, dass `SecureRandom`/TLS-Handshakes beim Start auf den blockierenden `/dev/random`-Entropie-Pool warten (klassisches Problem in Containern mit wenig Entropie) – nutzt stattdessen den nicht-blockierenden `urandom`-Pfad. |
| `-XX:+ExitOnOutOfMemoryError` | Lässt die JVM bei einem echten OOM sofort beenden, statt in einem undefinierten Zombie-Zustand weiterzulaufen. In Kubernetes ist das erwünscht: Der Container stirbt sauber, die Liveness-Probe schlägt fehl (oder der Exit passiert direkt) und Kubernetes startet den Pod neu. |
| `-XX:MaxRAMPercentage=75.0` | Container-aware JVMs (seit JDK 10) leiten die Heap-Größe standardmäßig aus dem cgroup-Memory-Limit ab. Ohne diese Flags nutzt die JVM nur 25 % des Limits als Heap. 75 % lassen ausreichend Puffer für Metaspace, Thread-Stacks, Code-Cache und Off-Heap-Buffer innerhalb des `resources.limits.memory` (hier 512Mi → Heap ≈ 384Mi). |
| `-XX:InitialRAMPercentage=75.0` | Initial- = Max-Heap, damit die Heap-Größe nicht erst über mehrere GC-Zyklen zur Laufzeit hochwächst (schnellerer, stabilerer Start; für kleine, kurzlebige Microservices üblich). |
| `-XX:+UseSerialGC` | Siehe [GC-Guide](#garbage-collector-guide) unten – bewusst gewählt, weil der Pod nur 1 CPU-Core hat. |
| `-XX:ActiveProcessorCount=1` | Muss exakt zum CPU-`limit` im Deployment passen. Ohne explizite Angabe leitet die JVM die sichtbaren Cores teils aus `cpu.shares`/Node-Cores statt aus dem tatsächlichen `limit` ab und legt dann zu viele GC-/JIT-Compiler-Threads an, die unter dem CFS-Quota nur throtteln statt zu arbeiten. |
| `-XX:TieredStopAtLevel=1` | Beschränkt den JIT auf den C1-Compiler (kein aufwendiges C2-Tiering). Reduziert Compiler-Threads, RAM- und CPU-Verbrauch und verkürzt die Zeit bis zur "warmen" Performance – auf Kosten von etwas Peak-Throughput bei sehr lange laufenden, rechenintensiven Prozessen. Für kleine, horizontal skalierte Services (viele kurzlebige Pods, kein Dauerlast-Batch-Job) meist die bessere Wahl. In Kombination mit `spring.aot.enabled=true` (AOT-Verarbeitung, siehe Dockerfile) besonders wirksam für schnellen Start. |
| `-Dspring.aot.enabled=true` | Aktiviert zur Laufzeit die Nutzung der beim Build per `spring-boot:process-aot` generierten AOT-Metadaten (weniger Reflection/Proxy-Arbeit beim Start → schnellerer, ressourcenschonenderer Boot). |

---

## Garbage Collector Guide

### Übersicht

| GC | Funktionsweise | Pause-Ziel | Typischer Speicher-/CPU-Overhead | Geeignet für |
|---|---|---|---|---|
| **Serial GC** (`-XX:+UseSerialGC`) | Ein einziger Thread für Minor+Major GC, Stop-the-World | Kurze Pausen bei **kleinem** Heap, keine Parallelität nötig | Minimal – kein zusätzlicher GC-Thread-Pool | Container mit **1 (v)CPU**, kleine Heaps (< ~1–2 GB), viele kurzlebige/horizontal skalierte Pods |
| **Parallel GC** (`-XX:+UseParallelGC`) | Mehrere Threads für Minor+Major GC, Stop-the-World | Höhere, aber seltenere Pausen | Mittel, skaliert mit Core-Zahl | Batch-/Durchsatz-orientierte Jobs mit ≥2 Cores, Pausenzeiten irrelevant |
| **G1 GC** (`-XX:+UseG1GC`, **Default seit JDK 9** bei ≥2 Cores & ≥2 GB Heap) | Region-basiert, überwiegend parallel, teils konkurrent | Ziel: einstellbare Pausenzeit (`-XX:MaxGCPauseMillis`), i. d. R. wenige 10–100ms | Höher als Serial/Parallel (Remembered Sets, mehr GC-Threads) | "Normale" Services mit ≥2 Cores und mehreren GB Heap – guter Allround-Default |
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

4. **Faustregel für dieses Repo:** Solange der Pod auf 1 Core / ≤512Mi limitiert bleibt, **Serial GC beibehalten**. Wird der Service später auf ≥2 Cores und mehrere GB Heap skaliert (z. B. weil er nicht mehr nur "Hello World" macht), `-XX:+UseSerialGC` entfernen und auf G1-Default wechseln bzw. bei Bedarf ZGC evaluieren – dann auch `-XX:ActiveProcessorCount` und `server.tomcat.threads.max` entsprechend mit hochziehen.

---

## Resource-Limits (`manifests/deployment.yaml`)

| Setting | Wert | Begründung |
|---|---|---|
| `resources.limits.cpu` | `1` | Deckt sich mit `-XX:ActiveProcessorCount=1` und der Wahl von Serial GC – ein einzelner GC-Thread kann den einen verfügbaren Core voll nutzen, ohne dass CFS-Throttling zwischen mehreren GC-Threads hin- und herschaltet. |
| `resources.requests.cpu` | `250m` | Erlaubt Kubernetes ein engeres Bin-Packing im Node, während Burst bis zum Limit (1 Core) für Lastspitzen/Start (AOT-Klassenladen, JIT) möglich bleibt. |
| `resources.limits.memory` | `512Mi` | Ergibt mit `-XX:MaxRAMPercentage=75.0` einen Heap von ~384Mi; die restlichen ~128Mi decken Metaspace, Thread-Stacks (`threads.max=20` × Default-Stackgröße), Code-Cache und native/Off-Heap-Puffer ab. |
| `resources.requests.memory` | `256Mi` | Realistischer Ruhezustands-Verbrauch nach dem Start; verhindert übermäßiges Overcommitment auf dem Node bei gleichzeitig ausreichend Headroom bis zum Limit. |

**Wichtig:** `limits.memory` sollte nie so knapp gewählt werden, dass `MaxRAMPercentage` den gesamten Container-Speicher als Heap beansprucht (kein Puffer für Metaspace/Threads → OOMKilled trotz "funktionierender" Heap-Größe). 75 % ist hierfür ein bewährter Kompromiss.

---

## Graceful Shutdown & Istio

- `server.shutdown=graceful` + `spring.lifecycle.timeout-per-shutdown-phase=30s` sorgen dafür, dass Tomcat laufende Requests zu Ende bearbeitet, statt sie hart zu kappen.
- `terminationGracePeriodSeconds: 40` im Deployment gibt der Anwendung mehr Zeit als die 30s Spring-internes Timeout, damit Kubernetes nicht per SIGKILL dazwischenfunkt.
- Der `preStop`-Hook (`sleep 5`) verzögert den eigentlichen Shutdown kurz, damit der Istio-Sidecar den Pod aus dem Envoy-Routing entfernen kann, bevor Tomcat aufhört, neue Verbindungen anzunehmen – vermeidet vereinzelte 503er während Rolling Updates.

---

