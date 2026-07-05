{{- define "alert-webhook-sink.fullname" -}}
{{- default (printf "%s-alert-webhook-sink" .Release.Name) .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}
