// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package defaults

import (
	"testing"

	slinkyv1beta1 "github.com/SlinkyProject/slurm-operator/api/v1beta1"
)

func TestSetAccountingDefaults(t *testing.T) {
	t.Run("nil accounting is a no-op", func(t *testing.T) {
		SetAccountingDefaults(nil)
	})

	t.Run("zero value spec gets defaults", func(t *testing.T) {
		a := &slinkyv1beta1.Accounting{}
		SetAccountingDefaults(a)
		if a.Spec.StorageConfig.Port != DefaultAccountingStoragePort {
			t.Errorf("StorageConfig.Port: want default %d, got %d", DefaultAccountingStoragePort, a.Spec.StorageConfig.Port)
		}
		if a.Spec.StorageConfig.Database != DefaultAccountingStorageDB {
			t.Errorf("StorageConfig.Database: want default %q, got %q", DefaultAccountingStorageDB, a.Spec.StorageConfig.Database)
		}
	})

	t.Run("explicit values are not overridden", func(t *testing.T) {
		a := &slinkyv1beta1.Accounting{}
		a.Spec.StorageConfig.Port = 9999
		a.Spec.StorageConfig.Database = "mydb"
		SetAccountingDefaults(a)
		if a.Spec.StorageConfig.Port != 9999 {
			t.Errorf("StorageConfig.Port: want 9999, got %d", a.Spec.StorageConfig.Port)
		}
		if a.Spec.StorageConfig.Database != "mydb" {
			t.Errorf("StorageConfig.Database: want mydb, got %q", a.Spec.StorageConfig.Database)
		}
	})
}
