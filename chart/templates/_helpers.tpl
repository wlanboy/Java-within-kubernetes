{{- define "hello-world.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "hello-world.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "hello-world.selectorLabels" -}}
app: {{ include "hello-world.fullname" . }}
{{- end -}}

{{- define "hello-world.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
selectorLabels bleiben bewusst nur "app": spec.selector eines Deployments ist
unveraenderlich, jede Aenderung dort wuerde ein helm upgrade scheitern lassen.
NEU: die Standard-Labels (app.kubernetes.io/*, helm.sh/chart) stehen daher nur
in labels, nicht im Selector.
*/}}
{{- define "hello-world.labels" -}}
{{ include "hello-world.selectorLabels" . }}
app.kubernetes.io/name: {{ include "hello-world.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ include "hello-world.chart" . }}
{{- end -}}
