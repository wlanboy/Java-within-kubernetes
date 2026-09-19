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

**"no healthy upstream" bei 0 Replicas:** Der Chart enthält keinen Queue-Proxy/Activator
(wie z. B. Knative), der Requests puffert, während der Pod hochfährt. Bei `minReplicas: 0`
gibt es also kurz nach dem ersten Request (der den HPA erst zum Hochskalieren triggert)
noch keinen Endpoint – Envoy antwortet mit `503 no healthy upstream`, bis der Pod bereit
ist (Startup-/Readiness-Probe, siehe `startupProbe`/`readinessProbe`). Ein erneuter curl
nach ein paar Sekunden sollte dann `200 OK` liefern. Bleibt der Fehler dauerhaft bestehen,
mit `kubectl describe hpa -n default hello-world-hpa` prüfen, ob die Custom-Metrics-API
(`http_requests_per_second`) überhaupt Werte liefert (Event `FailedGetObjectMetric`
deutet auf einen Problem mit dem Prometheus Adapter hin).

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
