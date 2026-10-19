{{- define "portfolio.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "portfolio.selectorLabels" -}}
app.kubernetes.io/name: {{ include "portfolio.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "portfolio.labels" -}}
{{ include "portfolio.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
