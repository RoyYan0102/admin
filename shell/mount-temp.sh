#!/bin/bash
# Installs mount-temp on a VM: run it there once (it uses sudo); running it again
# reinstalls and re-runs it. At every boot the service makes the VM's local NVMe disks one
# RAID0 ext4 at /mnt/scratch (Azure wipes them on every deallocation or eviction; a reboot
# keeps them), gives every login user a private /mnt/scratch/<user> and links ~/scratch to
# it. After adding a user: sudo systemctl restart mount-temp
sudo tee /usr/local/sbin/mount-temp.sh >/dev/null <<'EOF'
#!/bin/bash
set -euo pipefail
MNT=/mnt/scratch
mapfile -t DEVS < <(lsblk -dpno NAME,MODEL | awk '/NVMe Direct Disk/{print $1}')
(( ${#DEVS[@]} == 0 )) && exit 0             # no local disks on this VM size
mkdir -p "$MNT"

if ! mountpoint -q "$MNT"; then
  # no ARRAY line in /etc/mdadm/mdadm.conf on purpose: the array is gone after every
  # deallocation, and a listed array that never appears holds up the boot
  mdadm --assemble --scan >/dev/null 2>&1 || true   # reuse array after a reboot
  udevadm settle                              # so blkid sees an array just assembled
  TARGET=$(blkid -L scratch || true)

  if [[ -z "$TARGET" ]]; then                 # disks are blank: build fresh
    for d in "${DEVS[@]}"; do                 # but never format over an array or filesystem
      if [[ -n $(blkid -p -o value -s TYPE "$d" 2>/dev/null) ]]; then
        echo "$d holds $(blkid -p -o value -s TYPE "$d") but no 'scratch' label turned up: not formatting" >&2
        exit 1
      fi
    done
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
fi

# /mnt/scratch/<user> (700) for every login user, made before the top opens to everyone
# (1777) so nobody can take another user's name first, and ~/scratch linking to it.
# Anything already at either path that is not ours is left alone and logged.
getent passwd | while IFS=: read -r user _ uid gid _ home _; do
  (( uid >= 1000 && uid <= 60000 )) && [[ -d "$home" ]] || continue
  dir=$MNT/$user
  if [[ ! -e "$dir" && ! -L "$dir" ]]; then
    { mkdir -m 700 "$dir" && chown "$uid:$gid" "$dir" && echo "made $dir"; } \
      || echo "$dir: not made" >&2
  fi
  if [[ -L "$dir" || ! -d "$dir" || $(stat -c %u "$dir") != "$uid" ]]; then
    echo "$dir is not $user's own directory: no ~/scratch link for $user" >&2
    continue
  fi
  link=$home/scratch
  if [[ ! -e "$link" && ! -L "$link" ]]; then
    { ln -sT "$dir" "$link" && chown -h "$uid:$gid" "$link" && echo "linked $link"; } \
      || echo "$link: not linked" >&2
  elif [[ $(readlink "$link") != "$dir" ]]; then
    echo "$link is already there and is not the link to $dir: left alone" >&2
  fi
done
chmod 1777 "$MNT"
EOF
sudo chmod +x /usr/local/sbin/mount-temp.sh

sudo tee /etc/systemd/system/mount-temp.service >/dev/null <<'EOF'
[Unit]
Description=Format and mount Azure local NVMe temp disk, a scratch dir per user
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/mount-temp.sh

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable mount-temp.service
sudo systemctl restart mount-temp.service
