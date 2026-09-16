{{- define "producer.name" -}}
{{ .Release.Name }}
{{- end }}

{{- define "producer.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "producer.labels" -}}
helm.sh/chart: {{ include "producer.chart" . }}
app.kubernetes.io/name: {{ include "producer.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ .Chart.Name }}
{{- end }}

{{- define "producer.selectorLabels" -}}
app: {{ include "producer.name" . }}
app.kubernetes.io/name: {{ include "producer.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
