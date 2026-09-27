{{- define "hello-world-hpa.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "hello-world-hpa.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "hello-world-hpa.selectorLabels" -}}
app: {{ include "hello-world-hpa.fullname" . }}
{{- end -}}

{{- define "hello-world-hpa.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
selectorLabels bleiben bewusst nur "app": spec.selector eines Deployments ist
unveraenderlich, jede Aenderung dort wuerde ein helm upgrade scheitern lassen.
NEU: die Standard-Labels (app.kubernetes.io/*, helm.sh/chart) stehen daher nur
in labels, nicht im Selector.
*/}}
{{- define "hello-world-hpa.labels" -}}
{{ include "hello-world-hpa.selectorLabels" . }}
app.kubernetes.io/name: {{ include "hello-world-hpa.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ include "hello-world-hpa.chart" . }}
{{- end -}}
