// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package objectutils

import (
	"time"

	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/util/workqueue"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

func EnqueueRequest(q workqueue.TypedRateLimitingInterface[reconcile.Request], obj client.Object) {
	EnqueueRequestAfter(q, obj, 0)
}

func EnqueueRequestAfter(q workqueue.TypedRateLimitingInterface[reconcile.Request], obj client.Object, duration time.Duration) {
	req := reconcile.Request{
		NamespacedName: types.NamespacedName{
			Namespace: obj.GetNamespace(),
			Name:      obj.GetName(),
		},
	}
	q.AddAfter(req, duration)
}
