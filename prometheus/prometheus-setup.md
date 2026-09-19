# Prometheus – Setup (separates Release)

Dieser Ordner installiert einen schlanken Prometheus-Server, dessen einziger
Zweck es ist, `istio_requests_total` am `istio-ingressgateway` zu scrapen und
damit die PromQL-Query zu beantworten, die das `ScaledObject` in
[chart-keda/](../chart-keda/) fuer sein Scale-to-Zero braucht (siehe
`chart-keda/values.yaml`: `keda.triggers.prometheus`).

Genau wie [keda/](../keda/) ist das bewusst von den App-Charts getrennt: ein
Release pro Cluster, unabhaengig davon, wie viele Anwendungen KEDA nutzen.

## Warum ueberhaupt ein eigener Prometheus?

`metrics-server` (bereits im Cluster installiert) liefert nur CPU/Memory pro
laufendem Pod - diese Metrik existiert nicht mehr, sobald KEDA auf 0 Replicas
herunterskaliert hat, und kann den ersten Pod daher niemals wieder aus dem
Stand von 0 hochfahren. Fuer das "Aufwecken aus 0" braucht es eine Metrik, die
unabhaengig von laufenden App-Pods existiert - hier: Requests/Sekunde am
Istio-Ingressgateway.

## Voraussetzungen

- `istio-ingressgateway` laeuft bereits (Namespace `istio-ingress` in diesem
  Cluster - **nicht** `istio-system`, das ist nur istiod)
- Ein Default-`StorageClass` fuer die Prometheus-PVC (`kubectl get storageclass`)

## Vorbereitung

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

Vor dem Install/Upgrade pruefen, welche Werte die aktuell gepinnte
Chart-Version tatsaechlich unterstuetzt:

```bash
helm show values prometheus-community/prometheus > /tmp/prometheus-default-values.yaml
```

## Install

```bash
helm install prometheus prometheus-community/prometheus \
  --namespace prometheus \
  --create-namespace \
  -f prometheus/values-prometheus.yaml
```

## Upgrade

```bash
helm upgrade prometheus prometheus-community/prometheus \
  --namespace prometheus \
  -f prometheus/values-prometheus.yaml
```

## Status & Debugging

```bash
kubectl get pods -n prometheus
kubectl get pvc -n prometheus
```

Pruefen, dass istio-ingressgateway als Scrape-Target erkannt wird:

```bash
kubectl port-forward -n prometheus svc/prometheus-server 9090:80
```

Danach im Browser unter `http://localhost:9090/targets` den Job
`kubernetes-pods` suchen - dort muss ein Target aus Namespace `istio-ingress`
auftauchen. Alternativ per Query-API:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=istio_requests_total' | jq .
```

## Verifikation mit chart-keda

Die Adresse in `chart-keda/values.yaml` (`keda.triggers.prometheus.serverAddress`)
muss auf den hier erzeugten Service zeigen:

```
http://prometheus-server.prometheus.svc.cluster.local
```

(Port 80, kein `:9090` - der Chart-Service laeuft standardmaessig auf Port 80,
nicht auf Prometheus' internem Port 9090. Vor dem Deploy von chart-keda mit
`kubectl get svc -n prometheus` gegenpruefen.)

## Rollback

```bash
helm history prometheus --namespace prometheus
helm rollback prometheus <REVISION> --namespace prometheus
```

## Uninstall

```bash
helm uninstall prometheus --namespace prometheus
kubectl delete namespace prometheus
```

Achtung: Damit verliert das `ScaledObject` in chart-keda seine einzige
Wake-from-Zero-Quelle - `keda.triggers.prometheus.enabled: false` setzen oder
`minReplicaCount` auf mindestens 1 anheben, bevor dieser Release entfernt wird.
