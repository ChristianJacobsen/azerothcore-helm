{{- define "azerothcore.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "azerothcore.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "azerothcore.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "azerothcore.labels" -}}
helm.sh/chart: {{ include "azerothcore.chart" . }}
app.kubernetes.io/name: {{ include "azerothcore.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: azerothcore
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.podLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "azerothcore.selectorLabels" -}}
app.kubernetes.io/name: {{ include "azerothcore.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "azerothcore.podMetadata" -}}
labels:
  {{- include "azerothcore.selectorLabels" . | nindent 2 }}
  {{- with .ctx.Values.podLabels }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
{{- with .ctx.Values.podAnnotations }}
annotations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{- define "azerothcore.renderImage" -}}
{{- $registry := .registry | default "docker.io" -}}
{{- $tag := .tag | default "latest" -}}
{{- if .digest -}}
{{- printf "%s/%s:%s@%s" $registry .repository (toString $tag) .digest -}}
{{- else -}}
{{- printf "%s/%s:%s" $registry .repository (toString $tag) -}}
{{- end -}}
{{- end -}}

{{- define "azerothcore.image" -}}
{{- $flavor := .ctx.Values.flavor -}}
{{- $images := index .ctx.Values.images $flavor -}}
{{- if or (not (has $flavor (list "vanilla" "playerbots"))) (not $images) -}}
{{- fail "flavor must be vanilla or playerbots" -}}
{{- end -}}
{{- $img := index $images .component -}}
{{- if or (not $img.repository) (not $img.tag) -}}
{{- fail (printf "images.%s.%s.repository and images.%s.%s.tag are required. Use a published tag of ghcr.io/christianjacobsen/azerothcore-%s-*, or build your own images with `FLAVOR=%s make images` and install with `-f build/images.generated.yaml`." $flavor .component $flavor .component $flavor $flavor) -}}
{{- end -}}
{{- include "azerothcore.renderImage" $img -}}
{{- end -}}

{{- define "azerothcore.pullSecrets" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{- define "azerothcore.db.host" -}}
{{- if .Values.mysql.enabled -}}
{{- printf "%s-mysql" (include "azerothcore.fullname" .) -}}
{{- else -}}
{{- required "externalDatabase.host is required when mysql.enabled=false" .Values.externalDatabase.host -}}
{{- end -}}
{{- end -}}

{{- define "azerothcore.db.port" -}}
{{- if .Values.mysql.enabled -}}3306{{- else -}}{{- .Values.externalDatabase.port | int -}}{{- end -}}
{{- end -}}

{{- define "azerothcore.db.secretName" -}}
{{- .Values.database.existingSecret | default (printf "%s-db" (include "azerothcore.fullname" .)) -}}
{{- end -}}

{{- define "azerothcore.db.adminUser" -}}
{{- if .Values.mysql.enabled -}}root{{- else -}}{{- .Values.externalDatabase.adminUser -}}{{- end -}}
{{- end -}}

{{- define "azerothcore.db.adminPasswordKey" -}}
{{- if .Values.mysql.enabled -}}root-password{{- else -}}admin-password{{- end -}}
{{- end -}}

{{/* $(DB_PASSWORD) expands only when DB_PASSWORD comes earlier in the env list. */}}
{{- define "azerothcore.db.info" -}}
{{- printf "%s;%s;%s;$(DB_PASSWORD);%s" (include "azerothcore.db.host" .ctx) (include "azerothcore.db.port" .ctx) .ctx.Values.database.user .name -}}
{{- end -}}

{{- define "azerothcore.db.env" -}}
{{- $names := .ctx.Values.database.names -}}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "azerothcore.db.secretName" .ctx }}
      key: password
- name: AC_LOGIN_DATABASE_INFO
  value: {{ include "azerothcore.db.info" (dict "ctx" .ctx "name" $names.auth) | quote }}
{{- if .world }}
- name: AC_WORLD_DATABASE_INFO
  value: {{ include "azerothcore.db.info" (dict "ctx" .ctx "name" $names.world) | quote }}
- name: AC_CHARACTER_DATABASE_INFO
  value: {{ include "azerothcore.db.info" (dict "ctx" .ctx "name" $names.characters) | quote }}
{{- if eq .ctx.Values.flavor "playerbots" }}
- name: AC_PLAYERBOTS_DATABASE_INFO
  value: {{ include "azerothcore.db.info" (dict "ctx" .ctx "name" $names.playerbots) | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Convert an AzerothCore conf key (verbatim from the .dist files) to the
environment variable the core maps it to:
prefix AC_, dots → underscores, camelCase → CAMEL_CASE.
e.g. AllowTwoSide.Interaction.Calendar → AC_ALLOW_TWO_SIDE_INTERACTION_CALENDAR
*/}}
{{- define "azerothcore.confEnvName" -}}
{{- $k := . -}}
{{- $k = regexReplaceAll `\.` $k `_` -}}
{{- $k = regexReplaceAll `([a-z0-9])([A-Z])` $k `${1}_${2}` -}}
{{- printf "AC_%s" (upper $k) -}}
{{- end -}}

{{/*
Render a values `config` map as AC_* env vars.
Usage: include "azerothcore.configEnv" .Values.worldserver.config
*/}}
{{- define "azerothcore.configEnv" -}}
{{- range $k, $v := . }}
- name: {{ include "azerothcore.confEnvName" $k }}
  value: {{ $v | quote }}
{{- end }}
{{- end -}}

{{- define "azerothcore.serviceAccountName" -}}
{{- printf "%s-wait" (include "azerothcore.fullname" .) -}}
{{- end -}}

{{- define "azerothcore.dataClaimName" -}}
{{- .Values.clientData.existingClaim | default (printf "%s-client-data" (include "azerothcore.fullname" .)) -}}
{{- end -}}

{{/* Jobs are immutable, so each release revision needs new Job names. */}}
{{- define "azerothcore.dbInitJobName" -}}
{{- printf "%s-db-init-r%d" (include "azerothcore.fullname" .) (.Release.Revision | int) -}}
{{- end -}}

{{- define "azerothcore.clientDataJobName" -}}
{{- printf "%s-client-data-r%d" (include "azerothcore.fullname" .) (.Release.Revision | int) -}}
{{- end -}}

{{- define "azerothcore.realmPort" -}}
{{- $svc := .Values.worldserver.service -}}
{{- if not (kindIs "invalid" .Values.dbInit.realm.port) -}}
{{- .Values.dbInit.realm.port | int -}}
{{- else if and (eq $svc.type "NodePort") $svc.nodePort -}}
{{- $svc.nodePort | int -}}
{{- else -}}
{{- $svc.port | int -}}
{{- end -}}
{{- end -}}
