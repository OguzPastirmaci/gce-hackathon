// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package defaults

import (
	"k8s.io/utils/ptr"

	slinkyv1beta1 "github.com/SlinkyProject/slurm-operator/api/v1beta1"
)

// Default values for Token Spec fields when unspecified.
const (
	DefaultTokenRefresh bool = true
)

func SetTokenDefaults(token *slinkyv1beta1.Token) {
	if token == nil {
		return
	}
	s := &token.Spec

	if s.Refresh == nil {
		s.Refresh = ptr.To(DefaultTokenRefresh)
	}
}
