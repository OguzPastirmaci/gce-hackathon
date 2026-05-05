# Lustre manual mount on OKE nodes - detailed reference

## Causal cluster specifics

- Operator host: `ssh causal-operator` (then `ssh -J causal-bastion ubuntu@<node-ip>` for worker nodes).
- Deploy dir on operator: `/home/ubuntu/lustre-deploy/` - contains `lustre-client-installer/` (chart) and `values-override.yaml`.
- Helm release: `lustre-client-installer` in namespace `kube-system`.
- Node affinity is pinned with `kubernetes.io/hostname In [...]` - to add nodes, append their IPs to that list in `values-override.yaml`, then run:
  ```sh
  ssh causal-operator '
    helm upgrade lustre-client-installer /home/ubuntu/lustre-deploy/lustre-client-installer \
      -n kube-system -f /home/ubuntu/lustre-deploy/values-override.yaml
  '
  ```
- MGS handle on this cluster: `10.140.33.240@tcp:/lustrefs`. PV name: `lustre-pv`.
- User has pre-authorized the `helm upgrade` above when the only change is adding hostnames - do not ask again, just run it.

## Background

On OKE clusters that use the OCI Lustre CSI driver (`lustre.csi.oraclecloud.com`), two separate things have to be true for a node to actually see `/mnt/oci-lustre`:

1. The Lustre client kernel modules (`lnet`, `libcfs`, `lustre`) have to be loaded.
2. The filesystem has to be mounted.

The `lustre-client-installer` Helm chart (DaemonSet) only does step 1 via dkms. It does not mount the filesystem. Step 2 is normally done by the CSI driver, but only when a pod is scheduled on the node that claims the Lustre PVC. Nodes without a consumer pod will therefore have the modules loaded but no mount.

When you are pre-provisioning nodes, reusing an existing PV, or a pod failed and left the node half-configured, you often want the mount present up-front and persisted in `/etc/fstab`. That is what this guide does.

## Assumptions

- Helm chart `lustre-client-installer` is installed (typically in `kube-system`).
- Its DaemonSet pods are `Running` on the target nodes. `Init:0/1` means dkms is still building (5-6 min).
- A `PersistentVolume` (e.g. `lustre-pv`) already exists and is `Bound`.
- You have `kubectl` access with permission to create privileged pods.

## Identify the MGS target

The MGS (management server) handle lives in the PV spec:

```sh
kubectl get pv lustre-pv -o yaml | grep volumeHandle
# volumeHandle: 10.140.33.240@tcp:/lustrefs
```

The canonical `/etc/fstab` line follows:

```
10.140.33.240@tcp:/lustrefs /mnt/oci-lustre lustre defaults,_netdev 0 0
```

You can copy the exact line from any already-working node (a node that has a pod consuming the PVC).

## Why not just SSH

On these clusters, direct SSH to worker node IPs was consistently refused/timed out. The reliable path is to run a privileged pod pinned to the node and enter the host namespaces with `nsenter`:

```
nsenter -t 1 -m -u -n -i -- sh -c '...'
```

`kubectl debug node/<nodeName>` is also a candidate, but it fails silently when the node name contains dots (it produces a DNS label warning and the debug pod never reports logs). Hand-rolled Pod manifests with `hostPID: true` and `nodeName: <ip>` are more predictable.

## Pod manifest

```yaml
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
          mount -t lustre 10.140.33.240@tcp:/lustrefs /mnt/oci-lustre || true
          grep -qE " /mnt/oci-lustre lustre " /etc/fstab || \
            cat <<'HOSTSH' >>/etc/fstab
          10.140.33.240@tcp:/lustrefs /mnt/oci-lustre lustre defaults,_netdev 0 0
          HOSTSH
          mount -a -f -v
          mount | grep -E " type lustre"
```

Replace `NODE_IP` (also in `metadata.name`) and the MGS string for your environment.

## Verification

`mount -a -f -v` is a dry run of `fstab`. A correctly configured node prints:

```
/mnt/oci-lustre                     : already mounted
```

And the live mount shows up under the `lustre` type:

```sh
mount | grep -E " type lustre"
# 10.140.33.240@tcp:/lustrefs on /mnt/oci-lustre type lustre (rw,_netdev)
```

## Post-install self-ping check and the `ksocklnd` priority race

LNet binds to eth0 and uses the node's own eth0 IP as its NID. The node MUST be able to ping its own eth0 IP (the packet should loop through `lo`, not leave the host).

### Symptom and cause

Observed failure on 4 nodes in block `kkq7ubugwsa` (`10.140.74.14`, `10.140.79.233`, `10.140.81.18`, `10.140.84.41`):

- `ping <own-eth0-ip>` → 100% packet loss.
- `ip rule list` contained a **priority-0** rule `from <eth0-ip> lookup eth0`.
- `ip route get <eth0-ip> from <eth0-ip>` returned `dev eth0 table eth0` instead of `dev lo table local`.
- The `eth0` custom table held only `10.140.64.0/19 dev eth0 proto kernel scope link src <eth0-ip>` (the subnet route) with no local route for the self-IP, so the kernel treated the self-IP as on-link, ARP'd for it on eth0, and the ping dropped.
- The `local` table sits at priority 100 on these workers (not the normal 0), so a priority-0 custom rule wins.
- Correlated anomaly: `lnetctl net show` reported two TCP NIDs (one bare, one bound to eth0). Working nodes have one NID bound to eth0.

Both the route and the rule are added by Lustre's `/usr/sbin/ksocklnd-config` script at module load time:

```
ksocklnd-config: /sbin/ip route flush table eth0
ksocklnd-config: /sbin/ip route add 10.140.64.0/19 dev eth0 proto kernel scope link src <eth0-ip> table eth0
ksocklnd-config: /sbin/ip rule del from <eth0-ip> table eth0
ksocklnd-config: /sbin/ip rule add from <eth0-ip> table eth0
```

`ip rule add` is called without an explicit priority. Linux's `fib4_rule_default_pref()` inspects the second rule in the rule list: if its priority is non-zero it assigns `(that-1)`, otherwise `0`. So the priority picked depends on what was in the rule table when `ksocklnd-config` ran:

- **Early (before OCI RDMA setup):** second rule is `32766: from all lookup main`, so the ksocklnd rule lands at **32765**, after `100: from all lookup local`. Self-ping works because local lookup fires first.
- **Late (after OCI RDMA setup has pushed priority-0 `iif rdma0..15` rules):** second rule has priority 0, so the ksocklnd rule lands at **0**, before `100: from all lookup local`. Self-ping breaks.

`ksocklnd-config` runs when the `ksocklnd` module loads, which on these nodes happens only when Lustre is first mounted. Nodes whose first Lustre mount happens late in boot lose the race.

### Persistent fix

This cluster is TCP-only LNet (no o2ib/Infiniband routing through LNet), so the route/rule setup is unnecessary. Tell `ksocklnd-config` to exit early via the module parameter `skip_mr_route_setup=1`:

```sh
echo 'options ksocklnd skip_mr_route_setup=1' | sudo tee /etc/modprobe.d/lustre-skip-mr-route.conf
```

The option is consulted at the top of `ksocklnd-config` (`checkskipcmd=$(cat /sys/module/ksocklnd/parameters/skip_mr_route_setup 2>&-); if [ "$checkskipcmd" == "1" ]; then exit 0; fi`), so nothing gets added to the rule table at all. Takes effect on next `ksocklnd` load (next reboot or `rmmod ksocklnd && modprobe ksocklnd`).

Apply to every node in the lustre node-affinity list. Skip nodes running workloads (Nemo/NCCL) only if you plan to also `rmmod`; the config file alone is inert until the module reloads.

### Runtime-only fix (when you cannot touch the module)

```sh
sudo ip rule del from <eth0-ip> lookup eth0
```
Removes only the priority-0 offender; the route stays in table `eth0` (harmless without the rule). Self-ping is restored immediately. Next `ksocklnd` reload will re-add the rule unless the modprobe config above is also in place.

## Gotchas

- **SSH refused.** Do not waste time on SSH - go straight to privileged pod + `nsenter -t 1 -m -u -n -i`.
- **`kubectl debug node/<ip>` is silent.** The dotted IP fails the DNS label check. Use a plain Pod with `hostPID: true` and `nodeName: <ip>`.
- **Empty fstab line.** Writing `"$ENTRY"` inside a double-quoted outer heredoc strips the value. Use a nested single-quoted heredoc (`<<'HOSTSH' ... HOSTSH`) so the literal line survives untouched.
- **False-positive mount match.** `mount | grep lustre` matches configmap volume paths like `lustre-client-volume`. Always filter with `grep -E " type lustre"`.
- **DaemonSet still initializing.** If `lustre-client-installer-*` is in `Init:0/1`, wait for the dkms build (5-6 min) before trying to mount - the `mount -t lustre` call will fail with `no such device` while the module is missing.
- **CSI is not broken.** If a pod that claims `lustre-pvc` gets scheduled on the node, the CSI driver will mount it correctly. This manual procedure is for nodes that need the mount before or without such a consumer.
- **`lustre-client-installer` does not mount or persist.** The chart installs kernel modules via dkms only. It does not mount `/mnt/oci-lustre` and does not add an `/etc/fstab` entry. After chart rollout, run the fstab+mount block on each new node:
  ```sh
  ENTRY="10.140.33.240@tcp:/lustrefs /mnt/oci-lustre lustre defaults,_netdev 0 0"
  sudo mkdir -p /mnt/oci-lustre
  grep -qE "^10\.140\.33\.240@tcp:/lustrefs /mnt/oci-lustre lustre" /etc/fstab || \
    echo "$ENTRY" | sudo tee -a /etc/fstab >/dev/null
  mount | grep -qE "/mnt/oci-lustre .*type lustre" || sudo mount /mnt/oci-lustre
  ```
- **Self-ping on the eth0 IP must work before Lustre is usable.** See the "Post-install self-ping check" section above - a stray priority-0 `from <eth0-ip> lookup eth0` rule has been observed to block self-ping on several nodes. LNet depends on it.
