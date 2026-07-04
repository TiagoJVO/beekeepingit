{{/*
Common labels every subchart's resources should carry, alongside their own
app.kubernetes.io/name. Helm loads parent + subchart templates into one shared
namespace, so subcharts can `include "beekeepingit.labels" .` directly.
*/}}
{{- define "beekeepingit.labels" -}}
app.kubernetes.io/part-of: beekeepingit
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
