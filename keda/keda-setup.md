# KEDA – Operator-Setup (separates Release)

Dieser Ordner installiert **nur den KEDA-Operator** (CRDs wie `ScaledObject`) im
Cluster. Das ist bewusst von den App-Charts getrennt (siehe
[chart-keda/](../chart-keda/)): KEDA ist Cluster-Infrastruktur (ein Release pro
Cluster), waehrend chart-keda pro Anwendung/Namespace deployt wird und
lediglich `ScaledObject`-Ressourcen anlegt, die den bereits laufenden Operator
nutzen.

## Voraussetzungen

- KEDA-Operator noch nicht installiert (pruefen: `kubectl get crd scaledobjects.keda.sh`)
- Fuer den Prometheus-Trigger: ein erreichbarer Prometheus-Server (z. B. der
  Istio-Addon oder kube-prometheus-stack), der `istio_requests_total` scraped

## Vorbereitung

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
```

Vor dem Install/Upgrade pruefen, welche Werte die aktuell gepinnte
Chart-Version tatsaechlich unterstuetzt (das Schema aendert sich zwischen
Major-Versionen):

```bash
helm show values kedacore/keda > /tmp/keda-default-values.yaml
```

`keda/values-keda.yaml` in diesem Ordner nur als Ausgangspunkt verwenden und
gegen diese Default-Werte abgleichen.

## Install

```bash
helm install keda kedacore/keda \
  --namespace keda \
  --create-namespace \
  -f keda/values-keda.yaml
```

## Upgrade

```bash
helm upgrade keda kedacore/keda --namespace keda -f keda/values-keda.yaml
```

Vor dem Upgrade die Diffs pruefen (benoetigt Plugin `helm-diff`):

```bash
helm diff upgrade keda kedacore/keda --namespace keda -f keda/values-keda.yaml
```

## Status & Debugging

```bash
kubectl get pods -n keda
kubectl get crd | grep keda.sh
kubectl logs -n keda -l app=keda-operator
```

## Verifikation mit chart-keda

Erst nachdem `kubectl get pods -n keda` alle Operator-Pods als `Running`
zeigt, macht ein `helm install`/`upgrade` von [chart-keda/](../chart-keda/)
Sinn – vorher bleibt jedes `ScaledObject` ohne wirkenden Controller und der
HPA-Ersatz (`keda-hpa-<name>`) wird nie erzeugt.

```bash
kubectl get scaledobject -n default -w
kubectl get hpa -n default -w
```

## Rollback

```bash
helm history keda --namespace keda
helm rollback keda <REVISION> --namespace keda
```

## Uninstall

Erst alle `ScaledObject`-Ressourcen in den App-Namespaces entfernen (z. B.
`helm uninstall hello-world-keda`), sonst bleiben die davon verwalteten
Deployments auf ihrer letzten Replica-Zahl stehen, weil der Operator dann
keine HPA mehr fuer sie verwaltet:

```bash
helm uninstall hello-world-keda --namespace default

helm uninstall keda --namespace keda
kubectl delete namespace keda
```
