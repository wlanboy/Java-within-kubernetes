{{- define "hello-world-keda.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "hello-world-keda.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "hello-world-keda.selectorLabels" -}}
app: {{ include "hello-world-keda.fullname" . }}
{{- end -}}

{{- define "hello-world-keda.labels" -}}
{{ include "hello-world-keda.selectorLabels" . }}
{{- end -}}
