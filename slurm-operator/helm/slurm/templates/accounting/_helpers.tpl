{{- /*
SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
SPDX-License-Identifier: Apache-2.0
*/}}

{{/*
Determine accounting extraConf
*/}}
{{- define "slurm.accounting.extraConf" -}}
{{- $extraConf := list -}}
{{- if .Values.accounting.extraConf -}}
  {{- $extraConf = splitList "\n" .Values.accounting.extraConf -}}
{{- else if .Values.accounting.extraConfMap -}}
  {{- $extraConf = (include "_toList" .Values.accounting.extraConfMap) | splitList ";" -}}
{{- end }}
{{- join "\n" $extraConf -}}
{{- end }}
