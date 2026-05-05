# Lustre manual mount on OKE nodes - quickstart

Use when `lustre-client-installer` is installed but a node does not have `/mnt/oci-lustre` mounted (the CSI driver only mounts on-demand for pods that consume the PVC).

## Causal cluster quick facts

- Deploy dir: `causal-operator:/home/ubuntu/lustre-deploy/` (chart + `values-override.yaml`).
- Release: `lustre-client-installer` in `kube-system`.
- MGS: `10.140.33.240@tcp:/lustrefs`, PV: `lustre-pv`.
- SSH to workers: `ssh -J causal-bastion ubuntu@<node-ip>`.

## Add a node end-to-end (chart + fstab mount)

The chart only installs the kernel modules - it does NOT mount `/mnt/oci-lustre`. Do both:

1. Append hostname(s) to the `kubernetes.io/hostname In` list in `causal-operator:/home/ubuntu/lustre-deploy/values-override.yaml`.
2. Roll out the chart (pre-authorized, no need to ask):
   ```sh
   ssh causal-operator '
     helm upgrade lustre-client-installer /home/ubuntu/lustre-deploy/lustre-client-installer \
       -n kube-system -f /home/ubuntu/lustre-deploy/values-override.yaml
   '
   ```
3. Wait for DaemonSet pod on each new node to reach `Running` (dkms ~5-6 min).
4. Add fstab entry + mount on each new node (parallel-safe):
   ```sh
   for ip in <new node ips>; do
     ssh -J causal-bastion ubuntu@"$ip" '
       ENTRY="10.140.33.240@tcp:/lustrefs /mnt/oci-lustre lustre defaults,_netdev 0 0"
       sudo mkdir -p /mnt/oci-lustre
       grep -qE "^10\.140\.33\.240@tcp:/lustrefs /mnt/oci-lustre lustre" /etc/fstab || \
         echo "$ENTRY" | sudo tee -a /etc/fstab >/dev/null
       mount | grep -qE "/mnt/oci-lustre .*type lustre" || sudo mount /mnt/oci-lustre
     ' &
   done; wait
   ```
5. Verify: `ls /mnt/oci-lustre` on each node should show the usual data dirs (9 entries on this cluster).
6. Verify self-ping on the eth0 IP (required for LNet; the node must be able to ping itself):
   ```sh
   for ip in <new node ips>; do
     ssh -J causal-bastion ubuntu@"$ip" "ping -c 2 -W 2 -q $ip >/dev/null && echo $ip OK || echo $ip FAIL"
   done
   ```
   If any node FAILs, apply the self-ping fix below before moving on.

Post-reboot, the fstab entry makes the mount persistent. The longer manual-mount procedure below is only relevant if something goes wrong with the chart install or you need a one-off mount on a node not managed by the DaemonSet.

## Self-ping fix (ksocklnd route/rule race)

Symptom: `ping <own-eth0-ip>` returns 100% packet loss on the node itself.

Root cause: Lustre's `ksocklnd-config` (run when the `ksocklnd` kernel module loads) does `ip route add 10.140.64.0/19 ... table eth0` and `ip rule add from <eth0-ip> table eth0` with no priority specified. The kernel's default priority depends on what's already in the rule table:
- If RDMA setup (priority-0 `iif rdma0..15 lookup local` rules) has not yet run, the new rule lands at priority 32765 (after the `100: from all lookup local` that gets added later). Self-addressed packets loop through `lo` and self-ping works.
- If RDMA setup has already run, the new rule lands at priority 0, before the `100:` local lookup. Self-addressed packets are pushed to the `eth0` table, which only has `10.140.64.0/19 scope link`, so the kernel tries to send them out on eth0 and ARP fails.

Because `ksocklnd-config` runs only when the module loads (i.e., when Lustre is first mounted), nodes that mount Lustre late in boot lose the race and land at priority 0. Cluster is TCP-only LNet, so none of the route setup is needed.

### Persistent fix (do this on every node, pre-workload)

Tell `ksocklnd` to skip the whole route/rule setup:

```sh
for ip in <node ips>; do
  ssh -J causal-bastion ubuntu@"$ip" "echo 'options ksocklnd skip_mr_route_setup=1' | sudo tee /etc/modprobe.d/lustre-skip-mr-route.conf"
done
```

Takes effect on next `ksocklnd` load (next reboot or `rmmod ksocklnd && modprobe ksocklnd`). Do NOT apply on nodes running workloads you cannot disrupt if you also plan to unload the module; the file alone is harmless. Skip nodes running Nemo/NCCL pods until they're drained, then apply.

### Runtime-only fix (when you cannot reboot/reload)

If self-ping is currently broken and you need it fixed without touching the module:

```sh
for ip in <failing node ips>; do
  ssh -J causal-bastion ubuntu@"$ip" "sudo ip rule del from $ip lookup eth0 && ping -c 2 -W 2 -q $ip >/dev/null && echo $ip OK"
done
```

This only removes the offending rule. The route in table `eth0` remains (harmless once the rule is gone). Next `ksocklnd` reload will re-add the rule unless the modprobe config above is also in place.

### Diagnose

```sh
ip rule list | grep -E "from $(hostname -I | awk '{print $1}') lookup"
ip route get "$(hostname -I | awk '{print $1}')" from "$(hostname -I | awk '{print $1}')"
# broken: priority-0 rule, route via "dev eth0 table eth0"
# good:   priority-32765 rule (or no rule), route via "dev lo table local"
```

## Prereqs

- `lustre-client-installer` DaemonSet pods `Running` on target nodes (dkms build ~5-6 min).
- Existing `lustre-pv` with a known MGS handle, e.g. `10.140.33.240@tcp:/lustrefs`.

## Steps (per node)

1. Get the MGS handle:

   ```sh
   kubectl get pv lustre-pv -o jsonpath='{.spec.csi.volumeHandle}'
   ```

2. Apply a privileged mount pod (replace `NODE_IP` and `MGS`):

   ```sh
   cat <<EOF | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: lustre-mount-NODE_IP
     namespace: kube-system
   spec:
     hostPID: true
     nodeName: NODE_IP
     restartPolicy: Never
     tolerations:
       - operator: Exists
     containers:
       - name: fix
         image: busybox
         securityContext:
           privileged: true
         command: ["nsenter", "-t", "1", "-m", "-u", "-n", "-i", "--", "sh", "-c"]
         args:
           - |
             set -e
             mkdir -p /mnt/oci-lustre
             mount -t lustre MGS /mnt/oci-lustre || true
             grep -qE " /mnt/oci-lustre lustre " /etc/fstab || \
               cat <<'HOSTSH' >>/etc/fstab
             MGS /mnt/oci-lustre lustre defaults,_netdev 0 0
             HOSTSH
             mount -a -f -v
             mount | grep -E " type lustre"
   EOF
   ```

3. Verify:

   ```sh
   kubectl logs -n kube-system lustre-mount-NODE_IP
   # expect: " /mnt/oci-lustre : already mounted" and a "type lustre" line
   ```

4. Cleanup:

   ```sh
   kubectl delete pod -n kube-system lustre-mount-NODE_IP
   ```

## Canonical fstab line

```
10.140.33.240@tcp:/lustrefs /mnt/oci-lustre lustre defaults,_netdev 0 0
```
