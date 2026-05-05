// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package defaults

import (
	"testing"

	"k8s.io/utils/ptr"

	slinkyv1beta1 "github.com/SlinkyProject/slurm-operator/api/v1beta1"
)

func TestSetRestApiDefaults(t *testing.T) {
	t.Run("nil restapi is a no-op", func(t *testing.T) {
		SetRestApiDefaults(nil)
	})

	t.Run("zero value spec gets defaults", func(t *testing.T) {
		ra := &slinkyv1beta1.RestApi{}
		SetRestApiDefaults(ra)
		if ra.Spec.Replicas == nil || *ra.Spec.Replicas != DefaultRestApiReplicas {
			t.Errorf("Replicas: want default %d, got %v", DefaultRestApiReplicas, ra.Spec.Replicas)
		}
	})

	t.Run("explicit values are not overridden", func(t *testing.T) {
		ra := &slinkyv1beta1.RestApi{}
		ra.Spec.Replicas = ptr.To(int32(5))
		SetRestApiDefaults(ra)
		if ptr.Deref(ra.Spec.Replicas, 0) != 5 {
			t.Errorf("Replicas: want 5, got %v", ptr.Deref(ra.Spec.Replicas, 0))
		}
	})
}
