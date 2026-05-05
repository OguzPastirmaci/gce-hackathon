// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package defaults

import (
	"testing"

	"k8s.io/utils/ptr"

	slinkyv1beta1 "github.com/SlinkyProject/slurm-operator/api/v1beta1"
)

func TestSetLoginSetDefaults(t *testing.T) {
	t.Run("nil loginset is a no-op", func(t *testing.T) {
		SetLoginSetDefaults(nil)
	})

	t.Run("zero value spec gets defaults", func(t *testing.T) {
		ls := &slinkyv1beta1.LoginSet{}
		SetLoginSetDefaults(ls)
		if ls.Spec.Replicas == nil || *ls.Spec.Replicas != DefaultLoginSetReplicas {
			t.Errorf("Replicas: want default %d, got %v", DefaultLoginSetReplicas, ls.Spec.Replicas)
		}
	})

	t.Run("explicit values are not overridden", func(t *testing.T) {
		ls := &slinkyv1beta1.LoginSet{}
		ls.Spec.Replicas = ptr.To(int32(3))
		SetLoginSetDefaults(ls)
		if ptr.Deref(ls.Spec.Replicas, 0) != 3 {
			t.Errorf("Replicas: want 3, got %v", ptr.Deref(ls.Spec.Replicas, 0))
		}
	})
}
