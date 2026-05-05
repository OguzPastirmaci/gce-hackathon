{{- /*
SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
SPDX-License-Identifier: Apache-2.0
*/}}

{{/*
Define login name
*/}}
{{- define "slurm.login.name" -}}
{{- printf "%s-login" (include "slurm.fullname" .) -}}
{{- end }}
