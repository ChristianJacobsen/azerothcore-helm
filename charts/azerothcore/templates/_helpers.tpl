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

{{/* IniKeyToEnvVarKey in src/common/Configuration/Config.cpp, character by character. */}}
{{- define "azerothcore.envName" -}}
{{- $chars := splitList "" . -}}
{{- $last := sub (len $chars) 1 -}}
{{- $out := "" -}}
{{- range $i, $c := $chars -}}
{{- if has $c (list " " "." "-") -}}
{{- $out = print $out "_" -}}
{{- else -}}
{{- $out = print $out (upper $c) -}}
{{- if lt $i $last -}}
{{- $next := index $chars (add1 $i) -}}
{{- $digit := regexMatch "^[0-9]$" $c -}}
{{- $nextDigit := regexMatch "^[0-9]$" $next -}}
{{- if or (and (not (regexMatch "^[A-Z]$" $c)) (regexMatch "^[A-Z]$" $next)) (and (not $digit) $nextDigit) (and $digit (not $nextDigit)) -}}
{{- $out = print $out "_" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- printf "AC_%s" $out -}}
{{- end -}}

{{/*
Integer options cannot parse "true", so booleans become 1 and 0. Helm reads
YAML numbers as float64, so whole numbers need a cast: 1000000 would render
as 1e+06.
*/}}
{{- define "azerothcore.confValue" -}}
{{- if kindIs "bool" . -}}
{{- ternary "1" "0" . -}}
{{- else if and (kindIs "float64" .) (eq (float64 (int64 .)) .) -}}
{{- int64 . -}}
{{- else -}}
{{- toString . -}}
{{- end -}}
{{- end -}}

{{- define "azerothcore.confEnv" -}}
{{- range $k, $v := . }}
- name: {{ include "azerothcore.envName" $k }}
  value: {{ include "azerothcore.confValue" $v | quote }}
{{- end }}
{{- end -}}

{{- define "azerothcore.serviceAccountName" -}}
{{- printf "%s-wait" (include "azerothcore.fullname" .) -}}
{{- end -}}

{{- define "azerothcore.dataClaimName" -}}
{{- .Values.clientData.existingClaim | default (printf "%s-client-data" (include "azerothcore.fullname" .)) -}}
{{- end -}}

{{- define "azerothcore.createDataClaim" -}}
{{- if and (not .Values.clientData.volume) (not .Values.clientData.existingClaim) -}}true{{- end -}}
{{- end -}}

{{- define "azerothcore.dataVolume" -}}
{{- if .Values.clientData.volume -}}
{{- toYaml .Values.clientData.volume -}}
{{- else -}}
persistentVolumeClaim:
  claimName: {{ include "azerothcore.dataClaimName" . }}
{{- end -}}
{{- end -}}

{{- define "azerothcore.waitsForJobs" -}}
{{- if or .Values.dbInit.enabled (eq .Values.clientData.source "download") -}}true{{- end -}}
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

{{- define "azerothcore.waitJob" -}}
- name: {{ printf "wait-%s" .name }}
  image: {{ include "azerothcore.renderImage" .ctx.Values.images.kubectl }}
  imagePullPolicy: {{ .ctx.Values.imagePullPolicy }}
  command: ["kubectl"]
  args:
    - wait
    - --for=condition=complete
    - {{ printf "job/%s" .job }}
    - --timeout=3600s
  env:
    - name: HOME
      value: /tmp
  volumeMounts:
    - name: tmp
      mountPath: /tmp
  securityContext:
    {{- toYaml .ctx.Values.securityContext | nindent 4 }}
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      memory: 128Mi
{{- end -}}

{{/* The entrypoint of the images writes the .conf files and checks that it can write the logs. */}}
{{- define "azerothcore.writableMounts" -}}
- name: etc
  mountPath: /azerothcore/env/dist/etc
- name: logs
  mountPath: /azerothcore/env/dist/logs
- name: tmp
  mountPath: /tmp
{{- end -}}

{{- define "azerothcore.writableVolumes" -}}
- name: etc
  emptyDir: {}
- name: logs
  emptyDir: {}
- name: tmp
  emptyDir: {}
{{- end -}}
