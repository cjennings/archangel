# ZFS-on-root: PrivateTmp=yes drop-ins for systemd-tmpfiles services

**Discovered:** 2026-04-21, on velox after Arch-on-ZFS reinstall via archangel.

## The symptom

Every boot of a fresh ZFS-on-root install produces 10-30 journal errors like:

```
systemd-tmpfiles[993]: statx(/var/tmp/systemd-private-<id>-<svc>.service-<rand>/tmp) failed: Protocol driver not attached
systemd-tmpfiles[993]: statx(/var/lib/containers/storage/tmp) failed: Protocol driver not attached
```

And `systemd-tmpfiles-clean.service` fails every periodic run with:

```
Main process exited, code=exited, status=73/CANTCREAT
Failed with result 'exit-code'.
```

## Root cause

On ZFS, `statx()` against another service's `/var/tmp/systemd-private-*/tmp`
mount returns errno 132 (ENOTNAM, "Protocol driver not attached"). Other
filesystems (ext4, btrfs) don't surface this as an error.

The stock `systemd-tmpfiles-setup.service` and `systemd-tmpfiles-clean.service`
units ship with no `PrivateTmp=` directive — they run in the root mount
namespace and try to traverse every service's private-tmp.

## The fix (install-time)

Drop identical `PrivateTmp=yes` conf into both service units. This puts
tmpfiles inside its own mount namespace, so it never sees (or tries to
statx) other services' private-tmp paths.

```bash
# In archangel's post-install step (adjust path prefix as needed)
for svc in systemd-tmpfiles-setup systemd-tmpfiles-clean; do
    install -d -m 755 /mnt/etc/systemd/system/${svc}.service.d
    cat > /mnt/etc/systemd/system/${svc}.service.d/zfs-private-tmp.conf <<'EOF'
# ZFS: statx of sibling services' /var/tmp/systemd-private-*/tmp mounts
# returns errno 132. Running in own namespace avoids traversing them.
[Service]
PrivateTmp=yes
EOF
done
```

Scope: ZFS-on-root only. Not needed on Btrfs or ext4 installs.

## Verification after install

```bash
systemctl cat systemd-tmpfiles-setup.service | grep -A1 PrivateTmp
systemctl cat systemd-tmpfiles-clean.service | grep -A1 PrivateTmp
```

Both should show `PrivateTmp=yes` in the Drop-In section. After next boot,
`journalctl -u systemd-tmpfiles-setup.service -b -p err` should be empty.

## Upstream

Possibly reportable to openzfs (statx ENOTNAM on private-tmp boundary) or
systemd (tmpfiles traversal of sibling namespaces). The drop-in is the
practical fix regardless — upstream bugs move slowly.

## Related session record

`~/projects/homelab/.ai/sessions/2026-04-21-00-40-dual-host-health-check-workflow-refactor.org`
— see the "Fixes applied on velox" section and the `system-health-check.org`
Known Issues Log entry dated 2026-04-21.
