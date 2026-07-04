{{- define "alert-webhook-sink.fullname" -}}
{{- printf "%s-alert-webhook-sink" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
