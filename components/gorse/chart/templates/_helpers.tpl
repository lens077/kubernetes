{{- define "gorse.name" -}}{{ .Release.Name }}{{- end -}}
{{- define "gorse.labels" -}}
app.kubernetes.io/name: {{ include "gorse.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
