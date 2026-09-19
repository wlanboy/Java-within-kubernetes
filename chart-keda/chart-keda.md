# chart-keda – Helm-Befehle

Kommando-Referenz für das Chart [chart-keda/](chart-keda/) (hello-world-keda
mit KEDA `ScaledObject` statt nativer HorizontalPodAutoscaler, siehe
[chart-hpa/](../chart-hpa/) für den HPA-Ansatz).
Alle Beispiele nehmen Release-Name `hello-world-keda` und Namespace `default` an.

**Voraussetzungen:**
- der KEDA-Operator muss bereits im Cluster laufen, siehe
  [../keda/keda-setup.md](../keda/keda-setup.md). Ohne laufenden Operator
  bleibt jedes `ScaledObject` wirkungslos und es wird nie ein `keda-hpa-*`
  erzeugt.
- fuer den Prometheus-Trigger (Wake-from-Zero) muss zusaetzlich der
  Prometheus-Server aus [../prometheus/prometheus-setup.md](../prometheus/prometheus-setup.md)
  laufen. Ohne ihn bleibt `minReplicaCount: 0` zwar gesetzt, aber niemand
  skaliert den ersten Pod wieder hoch, sobald 0 Replicas erreicht sind
  (`metrics-server`/CPU-Trigger allein reicht dafuer nicht, siehe dortige
  Erklaerung).
- das Chart legt sein eigenes Istio `Gateway`/`VirtualService`
  (`templates/gateway.yaml`, `templates/virtualservice.yaml`) an, das
  Traffic vom bereits laufenden `istio-ingressgateway` zu diesem Service
  routet - erzeugt erst die `istio_requests_total`-Metrik, die der
  Prometheus-Trigger braucht. Falls im Cluster keine Istio-CRDs installiert
  sind, mit `--set istio.enabled=false` deaktivieren (dann bleibt nur der
  CPU-Trigger nutzbar, kein Wake-from-Zero).

## Vorbereitung

```bash
kubectl get pods -n keda
kubectl get crd scaledobjects.keda.sh
kubectl get pods -n prometheus

helm lint chart-keda
helm template hello-world-keda chart-keda
```

## Install

```bash
helm install hello-world-keda chart-keda \
  --namespace default \
  --create-namespace
```

Mit angepassten Werten (z. B. Image-Tag, Scaling-Grenzen):

```bash
helm install hello-world-keda chart-keda \
  --namespace default \
  --create-namespace \
  --set image.tag=1.0.0 \
  --set keda.minReplicaCount=0 \
  --set keda.maxReplicaCount=8
```

Oder mit eigener Values-Datei:

```bash
helm install hello-world-keda chart-keda -f my-values.yaml --namespace default
```

## Upgrade

```bash
helm upgrade hello-world-keda chart-keda --namespace default
```

Install-or-upgrade in einem Schritt (praktisch für CI/CD):

```bash
helm upgrade --install hello-world-keda chart-keda --namespace default
```

Vor dem Upgrade die Diffs prüfen (benötigt Plugin `helm-diff`):

```bash
helm diff upgrade hello-world-keda chart-keda --namespace default
```

Nach dem Upgrade den Rollout-Status prüfen:

```bash
kubectl rollout status -n default deployment/hello-world-keda
```

## Redeploy / Reroll (Pods neu starten ohne Chart-Änderung)

```bash
kubectl rollout restart -n default deployment/hello-world-keda
kubectl rollout status -n default deployment/hello-world-keda
```

## Scale-to-Zero beobachten

Solange kein Traffic ueber das istio-ingressgateway ankommt, faehrt KEDA nach
`keda.cooldownPeriod` (Default 300s) auf `minReplicaCount: 0` herunter.
Sobald wieder `istio_requests_total` fuer den Service gemessen wird, skaliert
KEDA innerhalb von `keda.pollingInterval` (Default 30s) wieder hoch:

```bash
kubectl get scaledobject -n default hello-world-keda -w
kubectl get hpa -n default keda-hpa-hello-world-keda -w
kubectl get pods -n default -l app=hello-world-keda -w
```

Test-Traffic ueber das Gateway schicken (Host-Header `hello-world-keda.local`,
siehe `templates/gateway.yaml`). Fuer eine berechenbare `rate()` muss der
Traffic mindestens ueber zwei Prometheus-Scrape-Intervalle (Default 1m)
laufen, ein einzelner Request reicht nicht:

```bash
kubectl run traffictest --rm -i --restart=Never --image=curlimages/curl:8.10.1 -n default -- \
  sh -c 'for i in $(seq 1 60); do curl -s -o /dev/null -H "Host: hello-world-keda.local" http://istio-ingressgateway.istio-ingress.svc.cluster.local; sleep 2; done'
```

## Status & Debugging

```bash
helm status hello-world-keda --namespace default
helm get values hello-world-keda --namespace default
helm history hello-world-keda --namespace default

kubectl get pods,deploy,scaledobject,hpa,pdb -n default -l app=hello-world-keda
kubectl get gateway,virtualservice -n default -l app=hello-world-keda
kubectl describe scaledobject -n default hello-world-keda
kubectl logs -n keda -l app=keda-operator
```

## Rollback

```bash
helm history hello-world-keda --namespace default
helm rollback hello-world-keda <REVISION> --namespace default
```

## Uninstall

```bash
helm uninstall hello-world-keda --namespace default
```

Prüfen, dass alle Ressourcen weg sind:

```bash
kubectl get all,scaledobject,hpa,pdb,configmap,gateway,virtualservice -n default -l app=hello-world-keda
```
