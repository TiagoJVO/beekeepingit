{{/*
Common labels every subchart's resources should carry, alongside their own
app.kubernetes.io/name. Same helper name as the beekeepingit umbrella chart's so
subcharts (alert-webhook-sink) render identically under either parent.
*/}}
{{- define "beekeepingit.labels" -}}
app.kubernetes.io/part-of: beekeepingit
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
