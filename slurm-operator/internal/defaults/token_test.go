// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package defaults

import (
	"testing"

	"k8s.io/utils/ptr"

	slinkyv1beta1 "github.com/SlinkyProject/slurm-operator/api/v1beta1"
)

func TestSetTokenDefaults(t *testing.T) {
	t.Run("nil token is a no-op", func(t *testing.T) {
		SetTokenDefaults(nil)
	})

	t.Run("zero value spec gets defaults", func(t *testing.T) {
		tok := &slinkyv1beta1.Token{}
		SetTokenDefaults(tok)
		if tok.Spec.Refresh == nil || !*tok.Spec.Refresh {
			t.Errorf("Refresh: want default %v, got %v", DefaultTokenRefresh, tok.Spec.Refresh)
		}
	})

	t.Run("explicit values are not overridden", func(t *testing.T) {
		tok := &slinkyv1beta1.Token{}
		tok.Spec.Refresh = ptr.To(true)
		SetTokenDefaults(tok)
		if tok.Spec.Refresh == nil || !*tok.Spec.Refresh {
			t.Errorf("Refresh: want true, got %v", tok.Spec.Refresh)
		}
		tok.Spec.Refresh = ptr.To(false)
		SetTokenDefaults(tok)
		// Explicit false is not changed (we only set when nil).
		if tok.Spec.Refresh == nil || *tok.Spec.Refresh {
			t.Errorf("Refresh: want explicit false preserved, got %v", tok.Spec.Refresh)
		}
	})
}
