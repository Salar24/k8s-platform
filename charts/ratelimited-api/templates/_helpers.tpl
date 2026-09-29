{{- define "rla.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "rla.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "rla.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: ratelimited-api
app.kubernetes.io/version: {{ .Chart.AppVersion | trunc 12 | quote }}
{{- end -}}

{{/* Selector labels for a component: api, redis or postgres. */}}
{{- define "rla.selector" -}}
app.kubernetes.io/name: {{ include "rla.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "rla.serviceAccountName" -}}
{{- default (include "rla.fullname" .) .Values.serviceAccount.name -}}
{{- end -}}

{{- define "rla.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) -}}
{{- end -}}

{{/* Secret holding DATABASE_URL: the in-cluster one, or a user-provided one. */}}
{{- define "rla.databaseSecret" -}}
{{- if .Values.postgres.enabled -}}
{{- default (printf "%s-postgres" (include "rla.fullname" .)) .Values.postgres.existingSecret -}}
{{- else -}}
{{- .Values.external.databaseSecret -}}
{{- end -}}
{{- end -}}

{{- define "rla.redisURL" -}}
{{- if .Values.redis.enabled -}}
{{- printf "redis://%s-redis:6379/0" (include "rla.fullname" .) -}}
{{- else -}}
{{- .Values.external.redisURL -}}
{{- end -}}
{{- end -}}

{{/* Restricted pod security settings shared by all containers. */}}
{{- define "rla.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end -}}
