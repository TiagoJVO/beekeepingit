{{- define "powersync.fullname" -}}
{{- printf "%s-powersync" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
