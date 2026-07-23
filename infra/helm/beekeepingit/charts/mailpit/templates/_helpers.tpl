{{- define "mailpit.fullname" -}}
{{- printf "%s-mailpit" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
