{{- /*
SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
SPDX-License-Identifier: Apache-2.0
*/}}

{{/*
Define auth/slurm secret ref name
*/}}
{{- define "slurm.authSlurmRef.name" -}}
{{- $ref := .Values.slurmKey.secretRef | default dict -}}
{{- if $ref.name }}
{{- $ref.name }}
{{- else }}
{{- printf "%s-auth-slurm" (include "slurm.fullname" .) -}}
{{- end }}
{{- end }}

{{/*
Define auth/slurm secret ref key
*/}}
{{- define "slurm.authSlurmRef.key" -}}
{{- $ref := .Values.slurmKey.secretRef | default dict -}}
{{- if $ref.key }}
{{- $ref.key }}
{{- else }}
{{- print "slurm.key" -}}
{{- end }}
{{- end }}

{{/*
Define auth/jwt secret ref name
*/}}
{{- define "slurm.authJwtRef.name" -}}
{{- $ref := .Values.jwtKey.secretRef | default dict -}}
{{- if $ref.name }}
{{- $ref.name }}
{{- else }}
{{- printf "%s-auth-jwt" (include "slurm.fullname" .) -}}
{{- end }}
{{- end }}

{{/*
Define auth/jwt secret ref key
*/}}
{{- define "slurm.authJwtRef.key" -}}
{{- $ref := .Values.jwtKey.secretRef | default dict -}}
{{- if $ref.key }}
{{- $ref.key }}
{{- else }}
{{- print "jwt.key" -}}
{{- end }}
{{- end }}

{{/*
Define JWKS configMap ref name
*/}}
{{- define "slurm.authJwksRef.name" -}}
{{- $ref := .Values.jwksKeys.configMapRef | default dict -}}
{{- if $ref.name }}
{{- $ref.name }}
{{- else }}
{{- printf "%s-auth-jwks" (include "slurm.fullname" .) -}}
{{- end }}
{{- end }}

{{/*
Define JWKS configMap ref key
*/}}
{{- define "slurm.authJwksRef.key" -}}
{{- $ref := .Values.jwksKeys.configMapRef | default dict -}}
{{- if $ref.key }}
{{- $ref.key }}
{{- else }}
{{- print "jwks.json" -}}
{{- end }}
{{- end }}
