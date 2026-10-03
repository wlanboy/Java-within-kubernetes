# Tekton-Pipeline

Baut das Image aus `service/Dockerfile` im Cluster und pusht es in eine Registry, das Gegenstück zu
`docker build --build-context git=.git -t wlanboy/helloworld:latest service/`.

| Datei | Inhalt |
|---|---|
| [pipeline.yaml](pipeline.yaml) | Pipeline `helloworld-build`: `fetch-source` → `build-push` |
| [task-buildkit.yaml](task-buildkit.yaml) | Task `buildkit-build-push`: BuildKit rootless, Push, Results `IMAGE_URL`/`IMAGE_DIGEST` |
| [pipelinerun.yaml](pipelinerun.yaml) | Beispiel-Run |
| [pvc-buildkit-cache.yaml](pvc-buildkit-cache.yaml) | PVC für den Build-Cache (Layer + Maven-Repository) |

`fetch-source` nutzt die `git-clone`-Task 0.10 aus dem [Tekton-Katalog](https://github.com/tektoncd/catalog),
geladen über den Git-Resolver. Sie muss nicht installiert werden.

## Voraussetzungen

- Tekton Pipelines mit aktiviertem Git-Resolver (Default seit v0.50)
- Kubernetes ≥ 1.30 (`appArmorProfile` im `securityContext`)
- Der Namespace darf Pods mit `seccompProfile: Unconfined` starten. Unter Pod Security
  `restricted` oder `baseline` schlägt der Build-Step fehl, rootless BuildKit braucht eigene User-Namespaces.

## Installation

```bash
kubectl create secret docker-registry registry-credentials \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=<user> --docker-password=<token>

kubectl apply -f tekton/task-buildkit.yaml -f tekton/pipeline.yaml -f tekton/pvc-buildkit-cache.yaml
```

## Starten

```bash
kubectl create -f tekton/pipelinerun.yaml
```

Das Image bekommt zwei Tags: `tag` (Default `latest`) und den Short-SHA des Commits, z. B.
`wlanboy/helloworld:fa7f9bb`. Für die Manifeste in `manifests/` ist der SHA-Tag die reproduzierbare
Wahl, siehe Hinweis zum Image-Tag in der [readme](../readme.md#deploy).

## Details

**Warum BuildKit und nicht Kaniko:** Das Dockerfile braucht `RUN --mount=type=cache` (Maven-Repository)
und `RUN --mount=type=bind,from=git` (Named Build Context für `.git`). Das unterstützt nur BuildKit.
`--build-context git=.git` wird zu `--local git=<workspace>/.git --opt context:git=local:git`.

**Git-Infos:** `git-clone` checkt mit `depth=1` aus. Für das `git-commit-id-maven-plugin` reicht das,
`git.commit.id`, `git.branch` und Co. landen in `/actuator/info`. Fehlt `.git`, läuft der Build ohne Git-Infos durch.

**Cache:** Der PipelineRun bindet die PVC `helloworld-buildkit-cache`, dadurch bleiben Layer und
`/root/.m2` zwischen den Runs erhalten. BuildKit sperrt das Verzeichnis, zwei Runs mit derselben PVC
laufen deshalb nicht gleichzeitig. Wer ohne Cache bauen will, bindet stattdessen `emptyDir: {}`,
dann startet jeder Run kalt und Maven lädt alle Dependencies neu.

**fsGroup 65532:** `git-clone` läuft als UID 65532 und muss in die frisch angelegte PVC schreiben.
BuildKit läuft als UID 1000, liest den Quellcode und schreibt über die Gruppe 65532 in die Cache-PVC.
