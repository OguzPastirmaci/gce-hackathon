// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package structutils

// Convert a list to a referenced list.
func ReferenceList[T any](items []T) []*T {
	list := make([]*T, 0, len(items))
	for _, item := range items {
		list = append(list, &item)
	}
	return list
}

// Convert a referenced list to a list.
func DereferenceList[T any](items []*T) []T {
	list := make([]T, 0, len(items))
	for _, item := range items {
		if item == nil {
			continue
		}
		list = append(list, *item)
	}
	return list
}

// MergeList concatenates all lists.
func MergeList[T any](items ...[]T) []T {
	cnt := 0
	for _, item := range items {
		cnt += len(item)
	}
	list := make([]T, 0, cnt)
	for _, item := range items {
		list = append(list, item...)
	}
	return list
}
