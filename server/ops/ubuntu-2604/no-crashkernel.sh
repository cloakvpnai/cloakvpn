set -e
cat > /etc/default/grub.d/zz-lattice-no-crashkernel.cfg <<'G'
# Ubuntu 26.04 reserves 320 MB of a 2 GB server for crash dumps (kdump-tools).
# On these small VPN servers that memory is needed at boot, so do not reserve it.
GRUB_CMDLINE_LINUX_DEFAULT="$(echo "$GRUB_CMDLINE_LINUX_DEFAULT" | sed 's/crashkernel=[^ ]*//g')"
G
update-grub >/dev/null 2>&1
systemctl disable kdump-tools >/dev/null 2>&1 || true
echo "$(hostname): crashkernel entries left in grub.cfg: $(grep -c crashkernel /boot/grub/grub.cfg) | default entry: $(grep -m1 -o 'vmlinuz-[^ ]*' /boot/grub/grub.cfg)"
