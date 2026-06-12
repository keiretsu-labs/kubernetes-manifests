# Add Jetson Orin Nano (orin-0) as 2nd Control Plane to stpetersburg

> **STATUS: SUPERSEDED** — orin-0 became the sole control plane; spark-0/spark-1 are GPU workers.

**Date:** 2026-05-09
**Status:** Approved, ready for implementation plan

## Goal

Add a Jetson Orin Nano dev kit as the second control plane node (`orin-0`) to the existing stpetersburg Talos cluster. A second DGX Spark will follow shortly as the third CP, restoring proper 3-node etcd quorum.

## Current State

- Cluster: stpetersburg, Talos v1.12.6, k8s v1.35.4
- Sole CP: `spark-0` at 192.168.73.206, VIP 192.168.73.25
- ARM64 throughout; existing schematic includes `nonfree-kmod-nvidia-lts` + `nvidia-container-toolkit-lts` for the GB10 GPU on the Spark
- talconfig at `clusters/talos-stpetersburg/bootstrap/talos/talconfig.yaml`

## Hardware

- Jetson Orin Nano **Super** Developer Kit (Ampere GPU, 1024 CUDA / 32 tensor cores, 6-core Cortex-A78AE, 8GB LPDDR5, 67 INT8 TOPS)
- M.2 NVMe SSD installed (target install disk)
- Onboard Realtek RTL8111 GbE
- Super refresh ships with UEFI from factory — JetPack SD pre-flash likely a no-op, but kept as insurance
- DisplayPort output, DP cable + monitor on hand (UEFI menus + Talos boot output visible)
- 128 GB microSD card available (currently has stale L4T; safe to wipe)
- Spare USB stick available for Talos boot media

## Decisions

### Role: 2nd control plane node

Two-CP window is accepted with eyes open: any single CP failure during the window costs quorum. Window closes when 2nd Spark joins as 3rd CP.

### Per-node installer images (separate ARM64 schematics)

Both nodes are ARM64 but use **different installer images**:

- **spark-0** — keeps current schematic with `nonfree-kmod-nvidia-lts` + `nvidia-container-toolkit-lts` (correct for the GB10 discrete-style GPU)
- **orin-0** — new minimal ARM64 schematic, only `siderolabs/util-linux-tools`. The discrete-NVIDIA modules don't apply to Tegra integrated GPU and would just add risk; Tegra GPU is not a goal for this node (CP duty only).

Implementation: per-node `installer:` field in talconfig points each node at its own factory.talos.dev installer URL.

### Firmware path: JetPack 6 SD pre-flash

Jetson Orin Nano dev kits shipped before mid-2024 boot via cboot in QSPI; later units ship with UEFI. Booting an official JetPack 6 SD card image once auto-updates QSPI to UEFI even from cboot — this is the documented NVIDIA path and requires no Ubuntu host or recovery cable.

We use this as **insurance** rather than diagnosis: pre-flash JetPack 6 to the SD card, boot the Jetson from SD once headless (~10–15 min for the QSPI update plus a boot pass), power off, remove SD, then boot Talos from USB. Whether the unit was already UEFI or not, we end up at UEFI with no diagnosis branch.

## Architecture

```
                  ┌──────────────────────────────────────────┐
                  │  stpetersburg Talos cluster              │
                  │  endpoint VIP: 192.168.73.25             │
                  │  Pod CIDR: 10.5.0.0/16                   │
                  │  Svc CIDR: 10.4.0.0/16                   │
                  └────────────┬───────────┬─────────────────┘
                               │           │
                  ┌────────────┴──┐    ┌──┴────────────────┐
                  │ spark-0 (CP)  │    │ orin-0 (CP) NEW   │
                  │ DGX Spark     │    │ Jetson Orin Nano  │
                  │ 192.168.73.206│    │ 192.168.73.x DHCP │
                  │ NVMe + GB10   │    │ NVMe, no GPU use  │
                  │ NVIDIA LTS    │    │ Minimal ARM64     │
                  │ schematic     │    │ schematic         │
                  └───────────────┘    └───────────────────┘
                  Future: spark-1 (CP) joins → 3-node etcd quorum
```

## Implementation Outline

### 1. Build the orin-0 schematic

Generate via factory.talos.dev with these settings:

- Target: metal, ARM64
- Talos version: v1.12.6 (matches cluster)
- System extensions: `siderolabs/util-linux-tools`
- Kernel args (drop NVIDIA-related from existing schematic):
  - `apparmor=0`
  - `init_on_alloc=0`
  - `init_on_free=0`
  - `mitigations=off`
  - `security=none`
  - `talos.auditd.disabled=1`
  - `net.ifnames=0`
  - `talos.logging.kernel=tcp://10.73.69.51:5170/`

Capture the resulting schematic ID. Both the boot ISO and the installer image come from this schematic.

### 2. Pin spark-0 schematic explicitly

Add an `installer:` field to the existing spark-0 entry in talconfig pointing at its current NVIDIA-flavored installer URL (capture via factory.talos.dev with the existing schematic). This prevents spark-0 from accidentally adopting orin-0's image in future config regenerations.

### 3. Add orin-0 node block to talconfig

```yaml
- hostname: "orin-0"
  ipAddress: "orin-0.stpetersburg.internal"  # update after IP discovered
  installDiskSelector:
    serial: "<NVMe serial>"  # discover via talosctl get disks
  installer: "factory.talos.dev/installer/<orin-schematic-id>:v1.12.6"
  controlPlane: true
  networkInterfaces:
    - interface: eth0
      dhcp: true
      vip:
        ip: "192.168.73.25"  # same VIP as spark-0
  patches:
    - "@./patches/node/orin-0.yaml"
```

Add `clusters/talos-stpetersburg/bootstrap/talos/patches/node/orin-0.yaml` with minimal node-specific overrides (likely empty or hostname/labels only).

Add corresponding additionalApiServerCertSans / additionalMachineCertSans entries for `orin-0.stpetersburg.internal` and the discovered IP.

### 4. Flash media (Mac, headless on the Jetson side)

- SD card (`/dev/disk5`, 128 GB): write JetPack 6 SD card image (downloaded from NVIDIA, latest stable 6.x)
- USB stick (separate device, plugged in after SD flash): write the orin-0 minimal ARM64 ISO

`dd` to `/dev/rdiskN` with `bs=4m` after `diskutil unmountDisk`. Verify device path before each `dd` — wrong target = data loss.

### 5. QSPI update pass

1. Insert SD card into Jetson, plug in Ethernet, power on
2. Wait ~10–15 min headless (QSPI flash + first L4T boot)
3. (Optional) confirm by scanning 192.168.73.0/24 for a new IP that responds on 22 (L4T sshd default)
4. Power off (hold power button)
5. Remove SD card

### 6. Talos boot + maintenance mode

1. Plug Talos USB in, power on Jetson
2. Talos enters maintenance mode and DHCPs an IP
3. Scan 192.168.73.0/24, find the new IP (Talos answers on talosctl maintenance API port 50000)
4. `talosctl --insecure -n <IP> get disks` — capture NVMe serial
5. Update talconfig with serial + IP

### 7. Generate config and apply

```bash
mise run genconfig                                 # regenerate clusterconfig/
talosctl apply-config --insecure -n <IP> \         # push config to maintenance mode
  --file clusterconfig/k8s.stpetersburg.internal-orin-0.yaml
```

Talos installs to NVMe, reboots into installed system, joins etcd cluster as 2nd member.

### 8. Verification

```bash
talosctl -n 192.168.73.25 get members              # 2 members
KUBECONFIG=~/.kube/stpetersburg kubectl get nodes  # 2 Ready
KUBECONFIG=~/.kube/stpetersburg kubectl -n kube-system \
  get pods -l component=etcd                       # 2 etcd pods, both Running
```

Post-install: commit talconfig changes and the new orin-0 patch file to git.

## Risks & Mitigations

1. **Tegra DTB not in Talos kernel** — Linux 6.18 mainline supports Tegra234, but Talos kernel build config not yet verified to include the Orin Nano DTB. *Mitigation:* if USB boot doesn't surface the node on the network, suspect this; add `intel_iommu=` style kernel args or generate ISO with custom DTB. Falls back to ordering the $8 USB-TTL adapter for serial boot diagnosis.
2. **Wrong eth interface name** — assumed `eth0` with `net.ifnames=0`. If renamed, talconfig fails. *Mitigation:* check via `talosctl get links` once in maintenance mode; rename in node patch if needed.
3. **2-CP quorum fragility** — until 3rd node joins, any CP reboot loses quorum. *Mitigation:* don't reboot either CP unnecessarily; do upgrades only after 3rd node is up.
4. **VIP failover in 2-node** — Talos VIP works with 2 nodes but is best-effort. *Mitigation:* accept; revisit when 3-node up.
5. **QSPI update from JetPack 6 SD** — assumes the unit's existing firmware will accept the update. Documented behavior, but unverified for this specific unit. *Mitigation:* if SD boot doesn't bring up DHCP after 15 min, the unit may need an SDK Manager flash from a Linux host (separate effort).

## Out of Scope

- Tegra GPU usage on orin-0 (would require entirely different driver path; not a goal)
- 3rd CP (separate work, after 2nd Spark hardware lands)
- Migration of any existing workloads (orin-0 is a control plane only)
- Kernel/Talos version upgrade (locked to v1.12.6 to match cluster)

## File Inventory

**To create:**
- `clusters/talos-stpetersburg/bootstrap/talos/patches/node/orin-0.yaml`

**To update:**
- `clusters/talos-stpetersburg/bootstrap/talos/talconfig.yaml` (add orin-0 block, add `installer:` field to spark-0)
- `clusters/talos-stpetersburg/bootstrap/talos/clusterconfig/*` (regenerated by `mise run genconfig`)

**To download (not committed):**
- JetPack 6 SD card image from developer.nvidia.com
- orin-0 minimal ARM64 ISO from factory.talos.dev
