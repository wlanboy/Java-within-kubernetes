# chart-hpa – Helm-Befehle

Kommando-Referenz für das Chart [chart-hpa/](chart-hpa/) (hello-world-hpa mit HorizontalPodAutoscaler).
Alle Beispiele nehmen Release-Name `hello-world` und Namespace `default` an – bei Bedarf anpassen.

## Vorbereitung

```bash
helm lint chart-hpa
helm template hello-world chart-hpa
```

## Install

Namespace mit Istio-Sidecar-Injection anlegen (falls Istio genutzt wird):

```bash
kubectl create namespace default
kubectl label namespace default istio-injection=enabled
```

```bash
helm install hello-world chart-hpa \
  --namespace default \
  --create-namespace

helm status hello-world --namespace default
```

Mit angepassten Werten (z. B. Image-Tag, Autoscaling-Grenzen):

```bash
helm install hello-world chart-hpa \
  --namespace default \
  --create-namespace \
  --set image.tag=1.0.0 \
  --set autoscaling.minReplicas=1 \
  --set autoscaling.maxReplicas=8
```

Oder mit eigener Values-Datei:

```bash
helm install hello-world chart-hpa -f my-values.yaml --namespace default
```

## Upgrade

```bash
helm upgrade hello-world chart-hpa --namespace default
```

Install-or-upgrade in einem Schritt (praktisch für CI/CD):

```bash
helm upgrade --install hello-world chart-hpa --namespace default
```

Vor dem Upgrade die Diffs prüfen (benötigt Plugin `helm-diff`):

```bash
helm diff upgrade hello-world chart-hpa --namespace default
```

Nach dem Upgrade den Rollout-Status prüfen:

```bash
kubectl rollout status -n default deployment/hello-world-hpa
```

## Redeploy / Reroll (Pods neu starten ohne Chart-Änderung)

Wenn sich z. B. nur das `:latest`-Image geändert hat und ein Neustart der Pods erzwungen werden soll:

```bash
kubectl rollout restart -n default deployment/hello-world-hpa
kubectl rollout status -n default deployment/hello-world-hpa
```

## Lasttest (HPA testen)

[lasttest.sh](lasttest.sh) startet mehrere kurzlebige Pods im Cluster, die den Service parallel
mit Requests bombardieren, und raeumt sie danach automatisch wieder auf:

```bash
./chart-hpa/lasttest.sh -n default -s hello-world-hpa -c 10 -d 60
```

Parallel dazu in einem zweiten Terminal die Skalierung beobachten:

```bash
kubectl get hpa -n default hello-world-hpa -w
kubectl top pods -n default -l app=hello-world-hpa
```

`kubectl get hpa -w` zeigt den Metrikwert nur relativ zum Target (`<current>/<target>`)
und oft `<unknown>`, solange kein Pod läuft. Den rohen Wert, den der Prometheus Adapter
für die Object-Metrik `http_requests_per_second` (gemessen am Service `hello-world-hpa`,
siehe [templates/hpa.yaml](templates/hpa.yaml)) an die Custom-Metrics-API liefert, direkt abfragen:

```bash
kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/default/services/hello-world-hpa/http_requests_per_second" | jq .
```

Die `SuccessfulRescale`-Events des HPA (mit Zeitstempel und alter/neuer Replica-Zahl)
zeigen, wann und wie oft der HPA tatsächlich skaliert hat:

```bash
kubectl get events -n default \
  --field-selector involvedObject.name=hello-world-hpa,involvedObject.kind=HorizontalPodAutoscaler,reason=SuccessfulRescale \
  --sort-by='.lastTimestamp'
```

### Scale-up/Scale-down Dauer messen

Statt die Zeit manuell an der Uhr abzulesen, in einem dritten Terminal parallel zum
Lasttest mitlaufen lassen. Scale-up: vor bzw. beim Start von `lasttest.sh` starten,
wartet bis die erste Replica `Ready` ist:

```bash
start=$(date +%s)
until [ "$(kubectl get deploy -n default hello-world-hpa -o jsonpath='{.status.readyReplicas}')" -ge 1 ] 2>/dev/null; do
  sleep 1
done
echo "Scale-up: $(( $(date +%s) - start ))s bis 1. Replica Ready"
```

Scale-down: nach Ende von `lasttest.sh` starten, wartet bis wieder 0 Replicas übrig sind:

```bash
start=$(date +%s)
until [ "$(kubectl get deploy -n default hello-world-hpa -o jsonpath='{.status.readyReplicas}')" = "0" ]; do
  sleep 1
done
echo "Scale-down: $(( $(date +%s) - start ))s bis 0 Replicas"
```

Alternativ die `SuccessfulRescale`-Events des HPA (mit Zeitstempel und alter/neuer
Replica-Zahl) direkt einsehen:

```bash
kubectl get events -n default \
  --field-selector involvedObject.name=hello-world-hpa,involvedObject.kind=HorizontalPodAutoscaler,reason=SuccessfulRescale \
  --sort-by='.lastTimestamp'
```

## Zugriff über das Istio Gateway

Wenn `istio.gateway.enabled=true` ist (Default), wird der Service über das bestehende
`istio-ingressgateway` per `Gateway`/`VirtualService` unter den Hosts `hello-world.local`
und `hello-world.gmk.lan` erreichbar gemacht (siehe `istio.gateway.hosts`).

Request per curl mit gesetztem Host-Header (kein DNS-Eintrag nötig):

```bash
curl -H "Host: hello-world.local" "http://localhost:80/hello"
```

Mit funktionierendem DNS (z. B. `hello-world.gmk.lan` zeigt per Wildcard auf die
Ingress-LoadBalancer-IP) reicht auch:

```bash
curl "http://hello-world.gmk.lan/hello"
```

Alternativ per Port-Forward auf das Gateway, falls keine externe LoadBalancer-IP vorhanden ist:

```bash
kubectl -n istio-ingress port-forward svc/istio-ingressgateway 8080:80
curl -H "Host: hello-world.local" "http://localhost:8080/hello"
```

Das erzeugt `istio_requests_total` am Gateway und dient so, auch ohne laufende App-Pods,
als Quelle für das HPA-Scale-to-Zero.

## Zeitmessungen

Neben der Stopwatch-Methode (siehe [Scale-up/Scale-down Dauer messen](#scale-updown-dauer-messen))
zeigen die Kubernetes-Events die komplette Melde-Kette hinter einem Scale-up/Scale-down
und helfen, eine gemessene Verzögerung einer Stufe zuzuordnen (Metrik-Pipeline vs.
Pod-Start vs. Termination), statt nur die Gesamtzeit zu kennen.

### Scale-up: Melde-Kette

1. **Metrik-Pipeline** – keine einzelnen Events, sondern die Zeit bis zur Scale-Entscheidung,
   verteilt über mehrere unabhängige Instanzen. Startpunkt zum Messen ist der erste Wert
   `> 0` aus der Custom-Metrics-API (siehe oben):
   - **Prometheus** (`scrape_interval: 15s`, ConfigMap `prometheus-config` im Namespace
     `monitoring`). Wie oft neue Traffic-Samples überhaupt erfasst werden.
   - **Prometheus Adapter** (`--metrics-relist-interval=10s`, Deployment
     `prometheus-adapter` im Namespace `monitoring`). Wie oft der Adapter neu prüft,
     welche Metrik-Zeitreihen aktuell existieren.
   - **Prometheus Adapter** (`rate(...[1m])` in der Adapter-Regel, ConfigMap
     `prometheus-adapter-config` im Namespace `monitoring`). Größe des Zeitfensters,
     über das die Rate gemittelt wird; bestimmt, wie schnell ein neuer Traffic-Ausschlag
     den gemittelten Wert über das Target hebt.
   - **`kube-controller-manager`** (kein explizites `--horizontal-pod-autoscaler-sync-period`
     gesetzt → Kubernetes-Default `15s`) – wie oft der HPA-Controller die
     Custom-Metrics-API überhaupt abfragt und eine Scale-Entscheidung trifft.
2. **Pod `Scheduled`** – Node zugewiesen.
3. **Pod `Pulled`** (pro Container: erst `istio-proxy`, dann App-Container) – Image
   lokal vorhanden oder nachgeladen. `already present on machine` = kein Pull-Overhead,
   sonst zusätzlicher Registry-Roundtrip.
4. **Pod `Created` / `Started`** – Container-Runtime hat den Prozess gestartet.
5. **Pod `Unhealthy` (`Startup probe failed`)** – in den ersten Sekunden **normal**,
   solange die App noch bootet (JVM-/Spring-Context-Init). Kein Fehler, sondern
   erwartetes Verhalten bis zur ersten erfolgreichen Probe.
6. Kein eigenes "Ready"-Event: der Zeitpunkt "ready" ergibt sich erst daraus, dass
   keine weiteren `Unhealthy`-Events mehr kommen bzw. aus `readyReplicas` im
   Deployment-Status (siehe Stopwatch-Snippet oben).

**HPA `SuccessfulRescale`** (`New size: N; reason: external metric ... above target`)
markiert den Übergang zwischen Punkt 1 und Punkt 2 – das Ende der Metrik-Pipeline und
den Start der eigentlichen Pod-Erzeugung.

### Scale-down: Melde-Kette

1. **HPA `SuccessfulRescale`** (`New size: N; reason: All metrics below target`)
2. **Pod `Killing`** (zwei Einträge – `istio-proxy` und App-Container) – Beginn der
   Terminierung.
3. `readyReplicas` fällt auf 0, sobald der letzte Pod vollständig entfernt ist; dafür
   gibt es kein separates "Terminated"-Event, `readyReplicas` ist hier der verlässliche
   Marker (siehe Stopwatch-Snippet oben).

### Beide Ketten gemeinsam auswerten

```bash
kubectl get events -n default \
  --field-selector involvedObject.name=hello-world-hpa,involvedObject.kind=HorizontalPodAutoscaler,reason=SuccessfulRescale \
  --sort-by='.lastTimestamp'

kubectl get events -n default --field-selector involvedObject.kind=Pod --sort-by='.lastTimestamp' \
  | grep hello-world-hpa
```

Die Differenz zwischen dem ersten Wert `> 0` aus der Custom-Metrics-API (siehe oben)
und `SuccessfulRescale` ist die Metrik-Pipeline-Latenz. Die Differenz zwischen
`SuccessfulRescale` und dem letzten `Unhealthy`-Event (danach: ready) ist die reine
Pod-/App-Startzeit.

## Status & Debugging

```bash
helm status hello-world --namespace default
helm get values hello-world --namespace default
helm history hello-world --namespace default

kubectl get pods,deploy,hpa,pdb -n default -l app=hello-world-hpa
kubectl describe hpa -n default hello-world-hpa
kubectl get hpa -n default hello-world-hpa -w
```

## Rollback

```bash
helm history hello-world --namespace default
helm rollback hello-world <REVISION> --namespace default
```

## Uninstall

```bash
helm uninstall hello-world --namespace default
```

Prüfen, dass alle Ressourcen weg sind:

```bash
kubectl get all,hpa,pdb,configmap -n default -l app=hello-world-hpa
```
