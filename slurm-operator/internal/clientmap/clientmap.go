// SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
// SPDX-License-Identifier: Apache-2.0

package clientmap

import (
	"context"
	"sync"

	"k8s.io/apimachinery/pkg/types"

	"github.com/SlinkyProject/slurm-client/pkg/client"
)

type ClientMap struct {
	lock    sync.RWMutex
	clients map[string]client.Client
}

func NewClientMap() *ClientMap {
	return &ClientMap{
		clients: make(map[string]client.Client),
	}
}

func (c *ClientMap) Get(name types.NamespacedName) client.Client {
	c.lock.RLock()
	defer c.lock.RUnlock()
	client, ok := c.clients[name.String()]
	if ok {
		return client
	}
	return nil
}

func (c *ClientMap) Has(names ...types.NamespacedName) bool {
	c.lock.RLock()
	defer c.lock.RUnlock()
	for _, name := range names {
		if _, ok := c.clients[name.String()]; ok {
			return true
		}
	}
	return false
}

func (c *ClientMap) add(name types.NamespacedName, client client.Client) bool {
	if _, ok := c.clients[name.String()]; !ok {
		ctx := context.TODO()
		go client.Start(ctx)
		c.clients[name.String()] = client
		return true
	}
	return false
}

func (c *ClientMap) Add(name types.NamespacedName, client client.Client) bool {
	c.lock.Lock()
	defer c.lock.Unlock()
	c.remove(name)
	return c.add(name, client)
}

func (c *ClientMap) remove(name types.NamespacedName) bool {
	if client, ok := c.clients[name.String()]; ok {
		client.Stop()
		delete(c.clients, name.String())
		return true
	}
	return false
}

func (c *ClientMap) Remove(name types.NamespacedName) bool {
	c.lock.Lock()
	defer c.lock.Unlock()
	return c.remove(name)
}
