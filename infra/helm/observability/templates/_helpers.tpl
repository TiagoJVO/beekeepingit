{{/*
Common labels every subchart's resources should carry, alongside their own
app.kubernetes.io/name. Same helper name as the beekeepingit umbrella chart's so
subcharts (alert-webhook-sink) render identically under either parent — including
its rule that this goes on Deployment POD TEMPLATES as well as the Deployment's
own metadata (`kubectl logs -l app.kubernetes.io/part-of=...` selects pods, and a
pod inherits only what its template carries; #246). It emits
app.kubernetes.io/instance, so a block including it must not set that key too.
*/}}
{{- define "beekeepingit.labels" -}}
app.kubernetes.io/part-of: beekeepingit
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
