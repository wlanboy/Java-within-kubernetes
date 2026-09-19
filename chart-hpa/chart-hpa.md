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

## Zugriff über das Istio Gateway

Wenn `istio.gateway.enabled=true` ist (Default), wird der Service über das bestehende
`istio-ingressgateway` per `Gateway`/`VirtualService` unter den Hosts `hello-world.local`
und `hello-world.gmk.lan` erreichbar gemacht (siehe `istio.gateway.hosts`).

IP und Port des Ingress-Gateways ermitteln (Namespace im Cluster: `istio-ingress`):

```bash
export INGRESS_HOST=$(kubectl -n istio-ingress get svc istio-ingressgateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
export INGRESS_PORT=$(kubectl -n istio-ingress get svc istio-ingressgateway \
  -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')
```

Request per curl mit gesetztem Host-Header (kein DNS-Eintrag nötig):

```bash
curl -H "Host: hello-world.local" "http://${INGRESS_HOST}:${INGRESS_PORT}/hello"
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

Das erzeugt `istio_requests_total` am Gateway und dient so – auch ohne laufende App-Pods –
als Quelle für das HPA-Scale-to-Zero.

**"no healthy upstream" bei 0 Replicas:**
Der Chart enthält keinen Queue-Proxy/Activator (wie z. B. Knative), der Requests puffert,
während der Pod hochfährt. Bei `minReplicas: 0` und 0 laufenden Pods hat der
Kubernetes-Service keine Endpoints (`kubectl get endpoints -n default hello-world-hpa`
zeigt keine `subsets`). Envoy kann dann beim allerersten Schritt (Host-Auswahl) gar keinen
Host wählen und gibt **sofort synchron** `503 no healthy upstream` zurück – das ist kein
Timeout, sondern ein lokaler Fehler *vor* jeder Netzwerk-Anfrage. Die Retry-Policy
(`istio.gateway.retries`) greift hier **nicht**: sie hilft nur, wenn Hosts vorhanden, aber
(temporär) ungesund sind (z. B. während eines Rolling-Updates), nicht wenn der Cluster
komplett leer ist. Gemessen: curl gegen einen 0-Replica-Service liefert den 503 in ~15ms,
nicht nach den konfigurierten ~15s Retry-Budget.

Praktische Konsequenz: Aufrufer, die gegen einen potenziell schlafenden (scale-to-zero)
Service laufen, müssen **selbst retryen**, z. B.:

```bash
curl --retry 5 --retry-all-errors --retry-delay 3 \
  -H "Host: hello-world.gmk.lan" "http://192.168.178.81/hello"
```

Bleibt der Fehler dauerhaft bestehen (auch nachdem ein Pod längst laufen sollte), mit
`kubectl describe hpa -n default hello-world-hpa` prüfen, ob die Custom-Metrics-API
(`http_requests_per_second`) überhaupt Werte liefert (Event `FailedGetObjectMetric`
deutet auf ein Problem mit dem Prometheus Adapter hin).

## Scale-up beschleunigen

Zeit von "0 Replicas" bis "Request wird bedient" setzt sich aus mehreren Faktoren
zusammen. Folgende Chart-seitige Hebel sind bereits gesetzt bzw. stehen zur Verfügung:

- **`istio.gateway.retries`** (aktiv, `attempts: 5`, `perTryTimeout: 3s`): hilft bei
  kurzzeitig ungesunden, aber vorhandenen Hosts (z. B. während eines Rolling-Updates).
  Bei echten 0 Replicas (leerer Service, keine Endpoints) greift das **nicht** – Envoy
  scheitert dann synchron bei der Host-Auswahl, bevor die Retry-Logik ausgeführt wird
  (siehe Hinweis oben). Für den Scale-to-Zero-Fall ist Client-seitiger Retry nötig.
- **`image.pullPolicy: IfNotPresent`** (statt `Always`): kein Registry-Roundtrip mehr
  bei jedem Scale-up, wenn das Image bereits auf dem Node liegt. Achtung bei Tag
  `latest`: ein neu gepushtes Image wird dadurch nicht automatisch geholt (siehe
  Kommentar in `values.yaml`).
- **`startupProbe.periodSeconds: 1`** (statt 2): der Pod wird im Schnitt ~0.5s früher
  als "ready" erkannt, sobald er es tatsächlich ist.
- **`autoscaling.behavior.scaleUp`**: bereits ohne Stabilization-Delay
  (`stabilizationWindowSeconds: 0`), reagiert also sofort auf einen Metrikwert über dem
  Ziel.

**Nicht über diesen Chart steuerbar, aber oft der größte Anteil der Latenz:** wie schnell
der HPA überhaupt merkt, dass wieder Traffic da ist. Das hängt vom Prometheus
`scrape_interval`, dem Relist-/Query-Intervall des Prometheus Adapters und der
HPA-Sync-Period des `kube-controller-manager` (Cluster-Default 15s) ab – zusammen oft
15–30s, bevor der HPA überhaupt reagiert. Das lässt sich nur clusterweit (nicht pro
Chart/Release) verkürzen.

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
