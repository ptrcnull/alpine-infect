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

mount -o remount --make-private /

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
umount -R new_root 2>/dev/null || true
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
pivot_root . old_root || exit 1
rm second_stage.sh

apk add alpine-base util-linux-misc syslinux gdb procps

_ppid=$$
while [[ "$_ppid" != 1 ]]; do
  parent=$_ppid
  _ppid=$(cut -f4 -d" " /proc/$parent/stat)
done

busybox kill -- "-$parent"

cp /etc/inittab /etc/inittab.bak
echo "tty1::wait:/sbin/getty -n -l /third_stage.sh 38400 tty1" > /etc/inittab

# here be dragons

init_file=/old_root/sbin/init
init_link=$(readlink $init_file)
if [[ "$init_link" != "" ]]; then
  init_file=/old_root$init_link
fi

echo -e "set follow-fork-mode child
set solib-absolute-prefix /old_root
file $init_file
attach 1
call (int)execl(\"/sbin/init\", \"/sbin/init\", 0)
" | gdb
' > second_stage.sh

echo '#!/bin/ash
rm third_stage.sh

# kill all remaining processes
cd /proc
ps ax | awk "{print \$1}" | tail -n +3 | while read pid; do
  if grep -qE "^/dev/\w+ / " /proc/$pid/mounts; then
    kill -9 $pid
  fi
done
cd /

/bin/umount -Rl old_root/* 2>/dev/null
/bin/umount old_root

# get nameservers
setup-interfaces -a
ifquery --list | xargs ifup

# restore inittab
mv /etc/inittab.bak /etc/inittab

# maybe ask user what kernel they want? TODO
export DISKOPTS="-k lts"
setup-alpine

echo "It is now safe to turn off your computer."
reboot
' > third_stage.sh
chmod +x third_stage.sh

setsid bin/ash second_stage.sh
