#!/bin/bash
sudo tee /usr/local/sbin/mount-temp.sh >/dev/null <<'EOF'
#!/bin/bash
set -euo pipefail
MNT=/mnt/scratch
mapfile -t DEVS < <(lsblk -dpno NAME,MODEL | awk '/NVMe Direct Disk/{print $1}')
(( ${#DEVS[@]} == 0 )) && exit 0             # no local disks on this VM size
mkdir -p "$MNT"
mountpoint -q "$MNT" && exit 0

mdadm --assemble --scan >/dev/null 2>&1 || true   # reuse array after a reboot
TARGET=$(blkid -L scratch || true)

if [[ -z "$TARGET" ]]; then                   # disks are blank: build fresh
  if (( ${#DEVS[@]} == 1 )); then
    TARGET=${DEVS[0]}
  else
    mdadm --create /dev/md/scratch --level=0 --run \
          --raid-devices=${#DEVS[@]} "${DEVS[@]}"
    udevadm settle
    TARGET=/dev/md/scratch
  fi
  mkfs.ext4 -F -L scratch -E nodiscard "$TARGET"
fi

mount -o noatime "$TARGET" "$MNT"
chmod 1777 "$MNT"
EOF
sudo chmod +x /usr/local/sbin/mount-temp.sh

sudo tee /etc/systemd/system/mount-temp.service >/dev/null <<'EOF'
[Unit]
Description=Format and mount Azure local NVMe temp disk
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mount-temp.sh

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now mount-temp.service
