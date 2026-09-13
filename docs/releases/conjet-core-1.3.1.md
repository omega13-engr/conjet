# Conjet Core 1.3.1

Start `systemd-user-sessions.service` as part of the appliance target so SSH logins
are permitted once the guest is ready. The complete rootfs was rebuilt and booted
locally with fresh isolated root/data disks, and public CLI SSH was verified.

This release contains the Docker rootfs and the existing custom Linux 6.12.86
kernel built by the normal Core release workflow. No kernel source change is
needed for this fix. Existing profile data disks are preserved by `conjet update`;
the update restarts the runtime unless instructed otherwise.

Pair with Conjet 3.0.0 for the host networking, readiness and virtio RNG fixes.
Live Mac bind mounts remain unsupported by the current Jetstream host backend;
this rootfs update does not add filesystem sharing.
