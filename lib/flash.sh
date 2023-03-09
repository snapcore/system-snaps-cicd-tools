#!/bin/sh

# This is to reflash a spread runner.
# This script takes one argument: a gzipped image to be flashed onto the disk.
# After successfully running this script, a reboot or power down will
# flash the machine with the given image.

set -eu

DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends dracut-core busybox-initramfs

[ -d /run/initramfs ] || mkdir -p /run/initramfs

mount -t tmpfs -o exec,size=2G none /run/initramfs

cp -T "${1}" /run/initramfs/image.gz

/usr/lib/dracut/dracut-install --ldd -D/run/initramfs -a systemctl dd /usr/lib/systemd/systemd-shutdown
/usr/lib/dracut/dracut-install -D/run/initramfs /usr/lib/initramfs-tools/bin/busybox /bin/busybox

ln -s busybox /run/initramfs/bin/sh
ln -s busybox /run/initramfs/bin/gunzip

if [ -b /dev/vda ]; then
  DISK=/dev/vda
elif [ -b /dev/sda ]; then
  DISK=/dev/sda
else
  echo "Cannot find disk" 2>&1
  exit 1
fi

cat <<EOF >/run/initramfs/shutdown
#!/bin/sh

echo "SHUTTING DOWN"

set -eux

gunzip -c /image.gz | dd of='${DISK}' bs=32M

exec /usr/lib/systemd/systemd-shutdown "\${@}"
EOF

chmod +x /run/initramfs/shutdown
