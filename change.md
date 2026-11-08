# Änderungen

Neueste Einträge oben. Der aktuelle Stand mit allen Begründungen steht in [readme.md](readme.md).
Einträge beschreiben den Stand zum jeweiligen Datum, spätere Einträge können sie überholen.

Wichtig beim Ändern: GC- und Header-Flags müssen in `javaOpts`, im ENTRYPOINT und im
Dockerfile-Trainingslauf übereinstimmen, sonst verwirft die JVM den AOT-Cache.

---

## 2026-11-08: Doku aufgeräumt, `manifests/` an die Charts angeglichen

- **readme.md** beschreibt nur noch den aktuellen Stand. Die Änderungsprotokolle sind hierher
  gewandert, die NEU/ENTFERNT-Markierungen sind weg. Neue Abschnitte: Docker-Image (Build-Stage,
  Spring AOT, Thin-JAR und Layer, AOT-Cache, Runtime-Stage), Minimaler Tomcat,
  Build-Zeit-Properties.
- Korrigiert im readme:
  - `server.http2.enabled` wirkt hinter Istio nicht, weil der Service-Port `http` heißt und Envoy
    HTTP/1.1 zur App spricht.
  - Die Begründung für `processor-cache` widersprach dem Wert (200 bei `max-connections` 512).
  - G1 wird ab 2 CPUs und 1792 MB RAM Default, nicht ab „2 GB Heap“.
  - Die Rechnung für `limits.memory` unterscheidet jetzt Obergrenzen (~350 MB) und gemessene
    Werte (146 MB).
- **Dockerfile:** nur Kommentare überarbeitet, die Befehle sind unverändert.
- **`manifests/`** an `chart/` angeglichen:
  - `configmap.yaml`: `server.tomcat.threads.max=20` und `threads.min-spare=5` entfernt. Die
    Einträge waren dort bei der Umstellung auf Virtual Threads übersehen worden.
  - `deployment.yaml`: native preStop-Sleep-Action statt `sh -c "sleep 5"`, `/tmp` mit
    `sizeLimit: 64Mi`, Istio-Annotations `nativeSidecar` und `holdApplicationUntilProxyStarts`.
  - `poddisruptionbudget.yaml`: `unhealthyPodEvictionPolicy: AlwaysAllow`.
- **`check.py`** zeigt bei festem Heap `-Xms`/`-Xmx` an, statt „nicht berechenbar“ zu melden.
  `check.sh` hat keine Verweise mehr auf `entrypoint.sh` und das Alpine-Image.
- Nachgemessen (`docker run --cpus 1 -m 256m --read-only`, Flags wie im Chart):
  - Start 0,72–0,84 s, 7505 von 7689 Klassen aus dem AOT-Cache (mit `spring.context.exit=onRefresh`).
  - Ohne `JAVA_TOOL_OPTIONS` (also mit C2) 1,2–1,3 s. `TieredStopAtLevel=1` spart beim Start
    auf 1 CPU ~0,45 s.
  - Die 0,38 s aus dem UBI-Eintrag unten waren nicht reproduzierbar.

## 2026-11-08: Minimaler Tomcat, fester Heap, kleinere Requests

Gilt für `chart/`, `chart-hpa/` und `manifests/`. Getestet mit `chart/` im kind-Cluster.

- **Tomcat ohne WebSocket und EL:** `tomcat-embed-websocket` und `tomcat-embed-el` in der
  `pom.xml` ausgeschlossen, es bleibt nur `tomcat-embed-core`.
- **Fester Heap:** `-Xms64m -Xmx128m` statt `Max-/InitialRAMPercentage=70` (vorher 358 MB Heap
  für ~30 MB Live-Daten). Dazu `-Xss512k`, `-XX:ReservedCodeCacheSize=48m`, `MaxMetaspaceSize`
  96m → 64m. `NativeMemoryTracking` nach der Messung entfernt.
- **Resources:** requests 250m/256Mi → 100m/160Mi, limits.memory 512Mi → 320Mi, CPU-Limit bleibt 1.
- **`manifests/deployment.yaml`:** `-Djava.security.egd` jetzt auch dort entfernt.
- **Dockerfile:** `EXPOSE 8080 8081` (Actuator).
- Gemessen in kind (`chart/`): Start 0,79 s, ~4300 req/s, `memory.peak` 111–127 MiB, keine
  Restarts. Docker (`-m 384m`): NMT 146 MB committed, Heap ~30 MB belegt, 7511/8749 Klassen
  aus dem AOT-Cache (ohne `spring.context.exit=onRefresh` gezählt).

## 2026-11-08: Umstieg auf UBI 10 (Tomcat bleibt)

- Base-Images `ubi10/openjdk-25` (Build) und `ubi10/openjdk-25-runtime` (Runtime) statt
  eclipse-temurin alpine. Zwei Stages, Training in der Build-Stage nach `/app`, keine
  `RUN`-Befehle in der Runtime-Stage.
- Reihenfolge `pom.xml` → `dependency:go-offline` → `src` → Build, Cache-Mount
  `/home/default/.m2,uid=185`, `mvn` statt `mvnw`.
- Extraktion mit `--application-filename app.jar`, Start mit `-jar /app/app.jar`. Kein
  `entrypoint.sh` mehr: Exec-Form-ENTRYPOINT, JVM-Optionen per `JAVA_TOOL_OPTIONS` (statt
  `JAVA_OPTS` in Charts, manifests, `check.py`, `check.sh`). Damit ist auch der Punkt „Shell aus
  dem Image entfernen“ aus dem Review vom 2026-09-27 erledigt, das Image braucht keine Shell mehr.
- User 185 statt 1000 (`runAsUser`/`fsGroup` in `chart/`, `chart-hpa/`, `manifests/`).
- `service/src/layers.xml` mit `observability-dependencies` und `application-resources`,
  aktiviert in der `pom.xml`.
- OCI-Labels gesetzt.
- Gemessen (`-m 256m`, read-only, 1 CPU): Start 0,38 s (später nicht reproduzierbar, siehe
  oben), Tomcat auf 8080 und 8081, ca. 93 MiB, 7519 von 8771 Klassen aus dem AOT-Cache,
  `app.aot` 59 MB, Image 632 MB.

## 2026-09-27: Review der Helm-Charts

Gilt für `chart/` und `chart-hpa/`. In `manifests/` wurde damals nur
`-XX:+UseCompactObjectHeaders` nachgezogen, der Rest folgte am 2026-11-08.

- **Startzeit:** Der JDK-AOT-Cache halbiert den Start von rund 1,8 s auf rund 0,9 s. Dafür
  startet die App per `-jar` statt über den `JarLauncher`.
- **Speicher:** Compact Object Headers verkleinern den Heap. NMT war vorübergehend aktiv, um
  `resources.memory` auf Messwerte zu stützen.
- **Nebenläufigkeit:** Virtual Threads ersetzen den Tomcat-Worker-Pool.
- **Start und Shutdown:** Native Istio-Sidecars und der native preStop-Sleep.
- **Betrieb:** Pods im CrashLoop blockieren keinen Node-Drain mehr, `/tmp` ist auf 64Mi
  begrenzt, Standard-Labels `app.kubernetes.io/*` gesetzt.

### Hinzugefügt

| Änderung | Wo | Warum |
|---|---|---|
| JDK-AOT-Cache (JEP 483/514/515) | `service/Dockerfile` (Trainingslauf mit `-XX:AOTCacheOutput`, ENTRYPOINT mit `-XX:AOTCache`) | Start gemessen 0,89–0,92 s statt 1,73–1,85 s. Wichtig für Scale-up und Scale-from-zero. |
| `-XX:+UseCompactObjectHeaders` (JEP 519) | `javaOpts`, `manifests/deployment.yaml`, Dockerfile-Trainingslauf | Objekt-Header 8 statt 12 Byte, weniger Heap. |
| `-XX:NativeMemoryTracking=summary` | `javaOpts` | Speicherbedarf messen statt schätzen. Am 2026-11-08 nach der Messung entfernt. |
| `spring.threads.virtual.enabled=true` | `service/src/main/resources/application.properties` | Blockierendes I/O belegt keine Plattform-Threads mehr. Muss wegen Spring AOT zur Build-Zeit gesetzt sein. |
| native preStop-Sleep (`lifecycle.preStop.sleep.seconds`) | `templates/deployment.yaml` | Ersetzt `sh -c sleep`, der Kubelet wartet selbst. |
| `sidecar.istio.io/nativeSidecar: "true"` | `podAnnotations` | Envoy startet vor der App und endet erst nach ihr. |
| `proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'` | `podAnnotations` | Fallback für Umgebungen ohne native Sidecars. |
| `unhealthyPodEvictionPolicy: AlwaysAllow` | `templates/poddisruptionbudget.yaml` | Pods im CrashLoop blockieren keinen Node-Drain mehr. |
| `emptyDir.sizeLimit: 64Mi` für `/tmp` | `templates/deployment.yaml`, `tmpSizeLimit` | Ein volles `/tmp` führt nur zur Eviction dieses Pods. |
| Labels `app.kubernetes.io/*` und `helm.sh/chart` | `templates/_helpers.tpl` | Standard-Labels für Tooling und Istio. Selector bleibt `app`. |

### Entfernt

| Änderung | Warum |
|---|---|
| `-Djava.security.egd=file:/dev/./urandom` | Seit JDK 9 wirkungslos, `SecureRandom` blockiert unter Linux nicht mehr. |
| `server.tomcat.threads.max=20`, `server.tomcat.threads.min-spare=5` | Mit Virtual Threads wirkungslos. Die Nebenläufigkeit begrenzt `max-connections`. |
| `--launcher` bei der Jar-Extraktion, `JarLauncher` im Entrypoint | Mit dem JarLauncher kann der AOT-Cache die Anwendungs- und Library-Klassen nicht laden. |

### Damals geprüft, aber nicht umgesetzt

| Vorschlag | Stand damals | Stand heute |
|---|---|---|
| `requests.memory` = `limits.memory`, `MaxRAMPercentage` senken | Erst mit NMT messen | Am 2026-11-08 durch festen Heap und kleinere Requests/Limits gelöst |
| `-XX:TieredStopAtLevel=1` entfernen | Trade-off Startzeit gegen Durchsatz | Bleibt, siehe readme |
| Shell aus dem Image entfernen | Nicht möglich wegen `entrypoint.sh` | Am 2026-11-08 mit dem Exec-Form-ENTRYPOINT erledigt |
| `enableServiceLinks: false` | Geringer Nutzen | unverändert |
