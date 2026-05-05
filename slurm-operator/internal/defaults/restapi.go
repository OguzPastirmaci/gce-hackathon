// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package defaults

import (
	"k8s.io/utils/ptr"

	slinkyv1beta1 "github.com/SlinkyProject/slurm-operator/api/v1beta1"
)

// Default values for RestApi Spec fields when unspecified.
const (
	DefaultRestApiReplicas int32 = 1
)

func SetRestApiDefaults(restapi *slinkyv1beta1.RestApi) {
	if restapi == nil {
		return
	}
	s := &restapi.Spec

	if s.Replicas == nil {
		s.Replicas = ptr.To(DefaultRestApiReplicas)
	}
}
