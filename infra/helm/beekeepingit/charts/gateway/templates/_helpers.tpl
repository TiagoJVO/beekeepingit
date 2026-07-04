{{- define "gateway.fullname" -}}
{{- printf "%s-gateway" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
