#!/bin/sh

set -eu

ensure() {
    command -v $1 >/dev/null || (echo "$1 not found"; exit 1)
}

ensure curl
ensure tar
ensure gunzip
ensure mount

uid=$(id -u)
if [ "$uid" -ne 0 ]; then
    ensure sudo
    exec sudo $0
fi

arch="x86_64"

case $(uname -m) in
    "x86_64") arch=x86_64 ;;
    "i686") arch=x86 ;;
    *) exit 1 ;;
esac

version=${VERSION:-3.15.0}

branch="v$(echo $version | rev | cut -d'.' -f2- | rev)"
filename="alpine-minirootfs-$version-$arch.tar.gz"

# clean up, just in case
rm -f "$filename"
umount new_root 2>/dev/null || true
rm -rf new_root

# download alpine minirootfs
curl -Ok "https://dl-cdn.alpinelinux.org/alpine/$branch/releases/$arch/$filename"

# extract the files to new_root
mkdir new_root
mount -t tmpfs tmpfs new_root
< "$filename" gunzip | tar xf - -C new_root
rm -f "$filename"

cd new_root
mkdir old_root

mount -t sysfs sysfs sys
mount -t devtmpfs devtmpfs dev
mount -t proc proc proc

cp /etc/resolv.conf etc/resolv.conf
echo '
pivot_root . old_root
rm second_stage.sh

apk add alpine-base util-linux-misc syslinux

/bin/umount -Rl old_root/* 2>/dev/null
rm -rf old_root/*

export DISKOPTS="-k lts /old_root"
echo sys > /tmp/alpine-install-diskmode.out
setup-alpine

echo "Fixing MBR..."
rootdev=$(grep old_root /proc/mounts | cut -d" " -f1 | sed -E "s/[0-9]+$//")
dd if=/usr/share/syslinux/mbr.bin of=$rootdev
extlinux -i /old_root/boot

echo "It is now safe to turn off your computer."
' > second_stage.sh
bin/ash second_stage.sh

# that will probably fail
reboot
