# Änderungen

- **Startzeit:** Der JDK-AOT-Cache halbiert den Start von rund 1,8 s auf rund 0,9 s. Dafür startet die App jetzt per `-jar` statt über den `JarLauncher`.
- **Speicher:** Compact Object Headers verkleinern den Heap. NMT ist vorübergehend aktiv, um `resources.memory` auf Messwerte statt Schätzungen zu stützen.
- **Nebenläufigkeit:** Virtual Threads ersetzen den Tomcat-Worker-Pool. Die Thread-Pool-Einstellungen sind deshalb entfallen.
- **Start und Shutdown:** Native Istio-Sidecars und der native preStop-Sleep sorgen dafür, dass beim Start und beim Graceful Shutdown keine Requests verloren gehen.
- **Betrieb:** Pods im CrashLoop blockieren keinen Node-Drain mehr, `/tmp` ist auf 64Mi begrenzt, und die Standard-Labels `app.kubernetes.io/*` sind gesetzt.
- **Aufgeräumt:** Wirkungslose Optionen (`java.security.egd`, Tomcat-Thread-Limits) sind entfernt.
- **Offen:** Memory-Requests/-Limits und `TieredStopAtLevel=1` bleiben, bis Messungen unter Last vorliegen.

Wichtig beim Ändern: Die JVM-Flags müssen im Chart und im Dockerfile-Trainingslauf übereinstimmen, sonst verwirft die JVM den AOT-Cache.

### Hinzugefügt

| Änderung | Wo | Warum |
|---|---|---|
| JDK-AOT-Cache (JEP 483/514/515) | `service/Dockerfile` (Trainingslauf mit `-XX:AOTCacheOutput`), `service/entrypoint.sh` (`-XX:AOTCache=/app/app.aot -jar /app/application.jar`) | Startzeit etwa halbiert: gemessen 0,89–0,92 s statt 1,73–1,85 s. Wichtig für Scale-up und Scale-from-zero. |
| `-XX:+UseCompactObjectHeaders` (JEP 519) | `javaOpts`, `manifests/deployment.yaml` (`JAVA_OPTS`), Dockerfile-Trainingslauf | Objekt-Header 8 statt 12 Byte, weniger Heap. Muss im Chart und im Dockerfile gleich gesetzt sein, sonst verwirft die JVM den AOT-Cache. |
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
