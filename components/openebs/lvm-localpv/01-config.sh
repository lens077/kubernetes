#!/bin/bash

set -x

sudo apt-get update -y
sudo apt-get install lvm2

sudo modprobe dm_snapshot
lsmod | grep dm_snapshot

sudo tee /etc/modules-load.d/dm-snapshot.conf <<EOF
dm_snapshot
EOF
lsmod | grep dm_snapshot

set +x
