// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package defaults

import (
	"testing"

	"k8s.io/utils/ptr"

	slinkyv1beta1 "github.com/SlinkyProject/slurm-operator/api/v1beta1"
)

func TestSetControllerDefaults(t *testing.T) {
	t.Run("nil controller is a no-op", func(t *testing.T) {
		SetControllerDefaults(nil)
	})

	t.Run("zero value spec gets defaults", func(t *testing.T) {
		c := &slinkyv1beta1.Controller{}
		SetControllerDefaults(c)
		if c.Spec.Persistence.Enabled == nil || *c.Spec.Persistence.Enabled != DefaultControllerPersistenceEnabled {
			t.Errorf("Persistence.Enabled: want %v, got %v", DefaultControllerPersistenceEnabled, c.Spec.Persistence.Enabled)
		}
	})

	t.Run("explicit values are not overridden", func(t *testing.T) {
		c := &slinkyv1beta1.Controller{}
		c.Spec.Persistence.Enabled = ptr.To(true)
		SetControllerDefaults(c)
		if ptr.Deref(c.Spec.Persistence.Enabled, DefaultControllerPersistenceEnabled) != true {
			t.Errorf("Persistence.Enabled: want true, got %v", c.Spec.Persistence.Enabled)
		}
		c.Spec.Persistence.Enabled = ptr.To(false)
		SetControllerDefaults(c)
		if ptr.Deref(c.Spec.Persistence.Enabled, DefaultControllerPersistenceEnabled) != false {
			t.Errorf("Persistence.Enabled after explicit false: defaulting sets to true, got %v", c.Spec.Persistence.Enabled)
		}
	})
}
