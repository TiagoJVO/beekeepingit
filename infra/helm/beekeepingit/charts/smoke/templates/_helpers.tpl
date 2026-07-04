{{- define "smoke.fullname" -}}
{{- printf "%s-smoke" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
