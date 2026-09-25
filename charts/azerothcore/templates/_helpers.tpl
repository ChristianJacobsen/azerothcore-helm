{{/*
======================================================================
  Naming
======================================================================
*/}}

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

{{/*
======================================================================
  Labels
======================================================================
*/}}

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

{{/* Usage: include "azerothcore.selectorLabels" (dict "ctx" . "component" "worldserver") */}}
{{- define "azerothcore.selectorLabels" -}}
app.kubernetes.io/name: {{ include "azerothcore.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/*
======================================================================
  Images
======================================================================
*/}}

{{/*
Resolve the image reference for a component.
Flavor rewrite rule: when flavor != vanilla, every images.<component> entry
that still points at the upstream "acore/" namespace is redirected to
<flavorRegistry>/<image-name>:<flavor> (digest dropped). Explicitly
overridden repositories are always used verbatim.
Usage: include "azerothcore.image" (dict "ctx" . "component" "worldserver")
*/}}
{{- define "azerothcore.image" -}}
{{- $ctx := .ctx -}}
{{- $img := index $ctx.Values.images .component -}}
{{- $flavor := $ctx.Values.flavor -}}
{{- $registry := $img.registry | default "docker.io" -}}
{{- $repository := $img.repository -}}
{{- $tag := $img.tag | default "latest" -}}
{{- $digest := $img.digest | default "" -}}
{{- if and (ne $flavor "vanilla") (hasPrefix "acore/" $repository) -}}
  {{- if not $ctx.Values.flavorRegistry -}}
    {{- fail (printf "flavor=%q requires flavorRegistry (e.g. ghcr.io/myorg) or an explicit images.%s.repository override" $flavor .component) -}}
  {{- end -}}
  {{- $registry = regexFind "^[^/]+" $ctx.Values.flavorRegistry -}}
  {{- $namespace := trimPrefix (printf "%s/" $registry) $ctx.Values.flavorRegistry -}}
  {{- $repository = printf "%s/%s" $namespace (base $repository) -}}
  {{- $tag = $flavor -}}
  {{- $digest = "" -}}
{{- end -}}
{{- if $digest -}}
{{- printf "%s/%s:%s@%s" $registry $repository $tag $digest -}}
{{- else -}}
{{- printf "%s/%s:%s" $registry $repository $tag -}}
{{- end -}}
{{- end -}}

{{/*
Render imagePullSecrets + pull policy blocks.
*/}}
{{- define "azerothcore.pull" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
======================================================================
  Database
======================================================================
*/}}

{{- define "azerothcore.db.host" -}}
{{- if .Values.mysql.enabled -}}
{{- printf "%s-mysql" (include "azerothcore.fullname" .) -}}
{{- else -}}
{{- required "externalDatabase.host is required when mysql.enabled=false" .Values.externalDatabase.host -}}
{{- end -}}
{{- end -}}

{{- define "azerothcore.db.port" -}}
{{- if .Values.mysql.enabled -}}3306{{- else -}}{{- .Values.externalDatabase.port -}}{{- end -}}
{{- end -}}

{{- define "azerothcore.db.user" -}}
{{- if .Values.mysql.enabled -}}root{{- else -}}{{- .Values.externalDatabase.user -}}{{- end -}}
{{- end -}}

{{- define "azerothcore.db.secretName" -}}
{{- if .Values.mysql.enabled -}}
{{- if .Values.mysql.existingSecret -}}{{- .Values.mysql.existingSecret -}}{{- else -}}{{ printf "%s-db" (include "azerothcore.fullname" .) -}}{{- end -}}
{{- else -}}
{{- required "externalDatabase.existingSecret is required when mysql.enabled=false" .Values.externalDatabase.existingSecret -}}
{{- end -}}
{{- end -}}

{{- define "azerothcore.db.secretKey" -}}
{{- if .Values.mysql.enabled -}}{{- .Values.mysql.existingSecretPasswordKey -}}{{- else -}}{{- .Values.externalDatabase.existingSecretPasswordKey -}}{{- end -}}
{{- end -}}

{{/*
Environment shared by every AzerothCore component: DB connection strings.
MYSQL_ROOT_PASSWORD must be declared before the AC_*_DATABASE_INFO vars that
reference it via $(...) expansion.
*/}}
{{- define "azerothcore.dbEnv" -}}
- name: MYSQL_ROOT_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "azerothcore.db.secretName" . }}
      key: {{ include "azerothcore.db.secretKey" . }}
- name: AC_LOGIN_DATABASE_INFO
  value: "{{ include "azerothcore.db.host" . }};{{ include "azerothcore.db.port" . }};{{ include "azerothcore.db.user" . }};$(MYSQL_ROOT_PASSWORD);acore_auth"
{{- end -}}

{{- define "azerothcore.dbEnvWorld" -}}
- name: AC_CHARACTER_DATABASE_INFO
  value: "{{ include "azerothcore.db.host" . }};{{ include "azerothcore.db.port" . }};{{ include "azerothcore.db.user" . }};$(MYSQL_ROOT_PASSWORD);acore_characters"
- name: AC_WORLD_DATABASE_INFO
  value: "{{ include "azerothcore.db.host" . }};{{ include "azerothcore.db.port" . }};{{ include "azerothcore.db.user" . }};$(MYSQL_ROOT_PASSWORD);acore_world"
{{- end -}}

{{/*
======================================================================
  Configuration → environment
======================================================================
*/}}

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

{{/*
======================================================================
  Misc
======================================================================
*/}}

{{- define "azerothcore.serviceAccountName" -}}
{{- printf "%s-wait" (include "azerothcore.fullname" .) -}}
{{- end -}}

{{- define "azerothcore.dataClaimName" -}}
{{- if .Values.clientData.existingClaim -}}
{{- .Values.clientData.existingClaim -}}
{{- else -}}
{{- printf "%s-client-data" (include "azerothcore.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/* Job names carry the release revision: Jobs are immutable, so upgrades
must create new ones. */}}
{{- define "azerothcore.dbInitJobName" -}}
{{- printf "%s-db-init-r%d" (include "azerothcore.fullname" .) .Release.Revision -}}
{{- end -}}

{{- define "azerothcore.clientDataJobName" -}}
{{- printf "%s-client-data-r%d" (include "azerothcore.fullname" .) .Release.Revision -}}
{{- end -}}

{{/*
Render an image map {registry, repository, tag, digest} to a reference.
No flavor rewriting — for non-AzerothCore images (mysql, kubectl, ...).
Usage: include "azerothcore.renderImage" .Values.mysql.image
*/}}
{{- define "azerothcore.renderImage" -}}
{{- $registry := .registry | default "docker.io" -}}
{{- $tag := .tag | default "latest" -}}
{{- if .digest -}}
{{- printf "%s/%s:%s@%s" $registry .repository $tag .digest -}}
{{- else -}}
{{- printf "%s/%s:%s" $registry .repository $tag -}}
{{- end -}}
{{- end -}}

{{- define "azerothcore.kubectlImage" -}}
{{- include "azerothcore.renderImage" .Values.images.kubectl -}}
{{- end -}}
