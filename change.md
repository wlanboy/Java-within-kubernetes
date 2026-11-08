# Änderungen

- **Startzeit:** Der JDK-AOT-Cache halbiert den Start von rund 1,8 s auf rund 0,9 s. Dafür startet die App jetzt per `-jar` statt über den `JarLauncher`.
- **Speicher:** Compact Object Headers verkleinern den Heap. NMT ist vorübergehend aktiv, um `resources.memory` auf Messwerte statt Schätzungen zu stützen.
- **Nebenläufigkeit:** Virtual Threads ersetzen den Tomcat-Worker-Pool. Die Thread-Pool-Einstellungen sind deshalb entfallen.
- **Start und Shutdown:** Native Istio-Sidecars und der native preStop-Sleep sorgen dafür, dass beim Start und beim Graceful Shutdown keine Requests verloren gehen.
- **Betrieb:** Pods im CrashLoop blockieren keinen Node-Drain mehr, `/tmp` ist auf 64Mi begrenzt, und die Standard-Labels `app.kubernetes.io/*` sind gesetzt.
- **Aufgeräumt:** Wirkungslose Optionen (`java.security.egd`, Tomcat-Thread-Limits) sind entfernt.
- **Offen:** `TieredStopAtLevel=1` bleibt, bis Lasttests den Durchsatz pro Pod als Engpass zeigen. Memory-Requests/-Limits sind seit 2026-11-08 nach Messung gesenkt (siehe unten).

Wichtig beim Ändern: Die JVM-Flags müssen im Chart und im Dockerfile-Trainingslauf übereinstimmen, sonst verwirft die JVM den AOT-Cache.

### Hinzugefügt

| Änderung | Wo | Warum |
|---|---|---|
| JDK-AOT-Cache (JEP 483/514/515) | `service/Dockerfile` (Trainingslauf mit `-XX:AOTCacheOutput`), `service/Dockerfile` ENTRYPOINT (`-XX:AOTCache=/app/app.aot -jar /app/app.jar`) | Startzeit etwa halbiert: gemessen 0,89–0,92 s statt 1,73–1,85 s. Wichtig für Scale-up und Scale-from-zero. |
| `-XX:+UseCompactObjectHeaders` (JEP 519) | `javaOpts`, `manifests/deployment.yaml` (`JAVA_TOOL_OPTIONS`), Dockerfile-Trainingslauf | Objekt-Header 8 statt 12 Byte, weniger Heap. Muss im Chart und im Dockerfile gleich gesetzt sein, sonst verwirft die JVM den AOT-Cache. |
| `-XX:NativeMemoryTracking=summary` | `javaOpts` | Speicherbedarf messen statt schätzen, als Grundlage für `resources.memory`. Messanleitung per `kubectl debug` + `jcmd` in der readme. Kann nach der Messung wieder raus. |
| `spring.threads.virtual.enabled=true` | `service/src/main/resources/application.properties` | Blockierendes I/O belegt keine Plattform-Threads mehr (Pinning seit JDK 24 behoben, JEP 491). Muss wegen Spring AOT zur Build-Zeit gesetzt sein, in der ConfigMap wäre es wirkungslos. |
| native preStop-Sleep (`lifecycle.preStop.sleep.seconds`) | `templates/deployment.yaml` | Ersetzt `sh -c sleep`, der Kubelet wartet selbst (GA seit Kubernetes 1.34). |
| `sidecar.istio.io/nativeSidecar: "true"` | `podAnnotations` | Envoy startet garantiert vor der App und endet erst nach ihr. Kein Request-Verlust beim Start und während des Graceful Shutdown. |
| `proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'` | `podAnnotations` | Fallback für Umgebungen ohne native Sidecars. |
| `unhealthyPodEvictionPolicy: AlwaysAllow` | `templates/poddisruptionbudget.yaml`, `podDisruptionBudget` in values | Pods im CrashLoop blockieren keinen Node-Drain mehr (GA seit Kubernetes 1.31). |
| `emptyDir.sizeLimit: 64Mi` für `/tmp` | `templates/deployment.yaml`, `tmpSizeLimit` in values | Ein volllaufendes `/tmp` führt nur zur Eviction dieses Pods, statt den Node-Speicher zu belasten. |
| Labels `app.kubernetes.io/*` und `helm.sh/chart` | `templates/_helpers.tpl` | Standard-Labels für Tooling und Istio (`canonical-revision`). Nur in `labels`, der Selector bleibt `app`, weil `spec.selector` unveränderlich ist. |

### Entfernt

| Änderung | Warum |
|---|---|
| `-Djava.security.egd=file:/dev/./urandom` | Seit JDK 9 wirkungslos, `SecureRandom` blockiert unter Linux nicht mehr. |
| `server.tomcat.threads.max=20`, `server.tomcat.threads.min-spare=5` | Mit Virtual Threads wirkungslos, Tomcat nutzt keinen Worker-Pool mehr. Die Nebenläufigkeit begrenzt jetzt `max-connections`. |
| `--launcher` bei der Jar-Extraktion, `JarLauncher` im Entrypoint | Mit dem JarLauncher kann der AOT-Cache die Anwendungs- und Library-Klassen nicht laden. |

### Geprüft, aber bewusst nicht umgesetzt

| Vorschlag | Warum nicht (vorerst) |
|---|---|
| `requests.memory` = `limits.memory`, `MaxRAMPercentage` senken | Erst mit NMT unter realistischer Last messen. Erste Messung: ~200 MiB real bei 440 MB committed, Worst Case unter dem Limit von 512Mi. |
| `-XX:TieredStopAtLevel=1` entfernen | Trade-off Startzeit/CPU gegen Spitzendurchsatz. Beibehalten, bis Lasttests den Durchsatz pro Pod als Engpass zeigen. |
| `enableServiceLinks: false` | Geringer Nutzen. |

## [update] 2026-11-08: Umstieg auf UBI 10 (Tomcat bleibt)

- Base-Images: `ubi10/openjdk-25` (Build) und `ubi10/openjdk-25-runtime` (Runtime) statt eclipse-temurin alpine. Zwei Stages, Training in der Build-Stage nach `/app`, keine `RUN`-Befehle in der Runtime-Stage.
- Reihenfolge `pom.xml` → `dependency:go-offline` → `src` → Build, Cache-Mount `/home/default/.m2,uid=185`, `mvn` statt `mvnw`.
- Extraktion mit `--application-filename app.jar`, Start mit `-jar /app/app.jar`. Kein `entrypoint.sh` mehr: Exec-Form-ENTRYPOINT, JVM-Optionen per `JAVA_TOOL_OPTIONS` (statt `JAVA_OPTS` in Charts, manifests, `check.py`, `check.sh`).
- User 185 statt 1000 (`runAsUser`/`fsGroup` in `chart/`, `chart-hpa/`, `manifests/`).
- `service/src/layers.xml` mit `observability-dependencies` und `application-resources`, aktiviert in der `pom.xml`.
- OCI-Labels gesetzt.
- Gemessen (`-m 256m`, read-only, 1 CPU): Start 0,38 s, Tomcat auf 8080 und 8081, ca. 93 MiB, 7519 von 8771 Klassen aus dem AOT-Cache, `app.aot` 59 MB, Image 632 MB.

## [update] 2026-11-08: Minimaler Tomcat, fester Heap, kleinere Requests

Gilt für `chart/`, `chart-hpa/` und `manifests/`. Getestet mit `chart/` im kind-Cluster.

- **Tomcat ohne WebSocket und EL:** `tomcat-embed-websocket` und `tomcat-embed-el` in der `pom.xml` ausgeschlossen, es bleibt nur `tomcat-embed-core`.
- **Fester Heap:** `-Xms64m -Xmx128m` statt `Max-/InitialRAMPercentage=70` (vorher 358 MB Heap für ~30 MB Live-Daten). Dazu `-Xss512k`, `-XX:ReservedCodeCacheSize=48m`, `MaxMetaspaceSize` 96m → 64m. `NativeMemoryTracking` nach der Messung entfernt.
- **Resources:** requests 250m/256Mi → 100m/160Mi, limits.memory 512Mi → 320Mi, CPU-Limit bleibt 1.
- **`manifests/deployment.yaml`:** `-Djava.security.egd` jetzt auch dort entfernt.
- **Dockerfile:** `EXPOSE 8080 8081` (Actuator).
- Gemessen in kind (`chart/`): Start 0,79 s, ~4300 req/s, `memory.peak` 111–127 MiB, keine Restarts. Docker (`-m 384m`): NMT 146 MB committed, Heap ~30 MB belegt, 7511/8749 Klassen aus dem AOT-Cache.
