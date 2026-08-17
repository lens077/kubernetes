#!/bin/bash
set -x

sudo vgchange -a n lvmvg
sudo vgremove lvmvg
sudo pvremove /dev/loop0

sudo losetup -a
sudo losetup -d /dev/loop0
sudo rm /tmp/disk.img

set +x
