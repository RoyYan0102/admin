#!/usr/bin/env bash
# vm_ops: the OIM high-spec VMs (Azure). `vm <machine> <action>`: the first word picks
# the machine — `payg` (high-spec-linux-vm, 10.45.0.4, pay as you go) or `spot`
# (high-spec-spot, 10.45.0.5, a spot VM Azure may deallocate for capacity) — then the
# action. `vm --status` with no machine word is the pay-as-you-go one (the form of
# every earlier call). --start / --stop as before; --status, --wait, --history added
# 2026-09-26; --vpn, and --start / --wait / --status connecting the VPN first,
# 2026-09-29; the machine word 2026-10-01.
RG=OIM-CONTAINERS-UKSOUTH
VPN="Osmosis Azure VPN"   # an Azure VPN Client profile: ssh to the VMs' private addresses needs it

MACHINE=payg
case "$1" in
    payg|spot) MACHINE=$1; shift ;;
    --*|"") ;;
    *) echo "no machine '$1': payg or spot"; exit 1 ;;
esac
case "$MACHINE" in
    payg) NAME=high-spec-linux-vm; HOST=oimvm ;;    # ~/.ssh/config
    spot) NAME=high-spec-spot;     HOST=oimspot ;;  # ~/.ssh/config; a spot VM, eviction = deallocate
esac
# The data disk (/data) is one disk the two machines take turns with. ext4 takes one
# mounting machine at a time: on 10-01 the spot booted and mounted it while the payg had
# it (attached to both, maxShares 3) and the filesystem took errors. So --start refuses
# unless the other machine is stopped, then moves the disk to the machine it starts
# (detach, attach at lun 1, caching None: the only setting Premium SSD v2 takes). While
# maxShares is still above 1 it detaches the disk from both, sets 1 (Azure changes it only
# on a detached disk) and attaches it here: from then on Azure refuses a second attachment.
# Both fstabs mount /data by UUID with nofail, so a machine started without it still boots.
DATA_DISK=vm-data-drive
name_of() { case "$1" in payg) echo high-spec-linux-vm ;; spot) echo high-spec-spot ;; esac; }
other() { [ "$MACHINE" = payg ] && echo spot || echo payg; }
power_of() {
    az vm get-instance-view --resource-group "$RG" --name "$1" \
        --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus" -o tsv
}
# the names of the VMs the data disk is attached to, one per line (none: detached)
disk_holders() {
    local ids
    ids=$(az disk show --resource-group "$RG" --name "$DATA_DISK" \
        --query "[managedBy, managedByExtended[]][] | [?@ != null]" -o tsv) || return 1
    printf '%s\n' "$ids" | sed 's|.*/||' | sort -u | sed '/^$/d'
}
disk_shares() { az disk show --resource-group "$RG" --name "$DATA_DISK" --query maxShares -o tsv; }
# the data disk onto this machine; --start has checked that both machines are stopped
move_disk_here() {
    local holders shares h
    holders=$(disk_holders) || return 1
    shares=$(disk_shares) || return 1
    [ "$holders" = "$NAME" ] && [ "${shares:-1}" -le 1 ] && return 0
    for h in $holders; do
        case "$h" in
            high-spec-linux-vm|high-spec-spot) ;;
            *) echo "$DATA_DISK is attached to $h, which is neither machine: left alone"; return 1 ;;
        esac
    done
    for h in $holders; do
        echo "Detaching $DATA_DISK from $h..."
        az vm disk detach --resource-group "$RG" --vm-name "$h" --name "$DATA_DISK" -o none || return 1
    done
    if [ "${shares:-1}" -gt 1 ]; then
        az disk update --resource-group "$RG" --name "$DATA_DISK" --max-shares 1 -o none || return 1
        echo "$DATA_DISK: maxShares $shares -> 1, so Azure refuses a second attachment from now on"
    fi
    echo "Attaching $DATA_DISK to $NAME (lun 1)..."
    az vm disk attach --resource-group "$RG" --vm-name "$NAME" --name "$DATA_DISK" \
        --lun 1 --caching None -o none
}

# vpn_up: connect the VPN unless it is. From WSL: Windows' rasdial with the Azure VPN
# Client's phonebook, no prompt while the app's sign-in is cached; elsewhere, nothing.
vpn_connected() { rasdial.exe 2>/dev/null | tr -d '\r' | grep -qxF "$VPN"; }
vpn_up() {
    command -v rasdial.exe >/dev/null && command -v powershell.exe >/dev/null || return 0
    vpn_connected && return 0
    echo "Connecting the VPN ($VPN)..."
    timeout 90 powershell.exe -NoProfile -Command "\$pbk = Join-Path \$env:LOCALAPPDATA 'Packages\\Microsoft.AzureVpn_8wekyb3d8bbwe\\LocalState\\rasphone.pbk'; rasdial.exe '$VPN' /phonebook:\$pbk" \
        2>&1 | tr -d '\r' | grep -v '^$' | tail -2
    vpn_connected || { echo "VPN not connected: connect \"$VPN\" in the Azure VPN Client"; return 1; }
}

power_state() {
    az vm get-instance-view --resource-group "$RG" --name "$NAME" \
        --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus" -o tsv
}

case "$1" in
    --start)
        vpn_up
        here=$(power_state)
        case "$here" in
            "VM deallocated"|"VM stopped") ;;
            "VM running")
                holders=$(disk_holders | paste -sd ' ' -)
                echo "$NAME ($MACHINE) is already running; data disk $DATA_DISK: ${holders:-detached}"
                exit 0 ;;
            "") echo "could not read $NAME's state (az login?): not started"; exit 1 ;;
            *) echo "$NAME ($MACHINE): $here — try again once it has settled"; exit 1 ;;
        esac
        there=$(power_of "$(name_of "$(other)")")
        case "$there" in
            "VM deallocated"|"VM stopped") ;;
            "") echo "could not read $(name_of "$(other)")'s state (az login?): not started"; exit 1 ;;
            *) echo "$(other) ($(name_of "$(other)")): $there — one machine at a time holds $DATA_DISK: vm $(other) --stop first"
               exit 1 ;;
        esac
        move_disk_here || { echo "$DATA_DISK could not be moved to $NAME: not started"; exit 1; }
        echo "Starting $NAME ($MACHINE)..."
        if ! az vm start --resource-group "$RG" --name "$NAME"; then
            [ "$MACHINE" = spot ] && echo "a spot VM starts only when Azure has the capacity: try again later, or payg"
            exit 1
        fi
        ;;

    --stop)
        echo "Stopping $NAME ($MACHINE)..."
        az vm deallocate --resource-group "$RG" --name "$NAME"
        ;;

    --status)
        state=$(power_state)
        echo "$MACHINE ($NAME, $HOST): $state"
        holders=$(disk_holders | paste -sd ' ' -)
        shares=$(disk_shares)
        echo "data disk $DATA_DISK: ${holders:-detached}$([ "${shares:-1}" -gt 1 ] && echo " (maxShares $shares: the next --start sets 1)")"
        if [ "$state" = "VM running" ]; then
            vpn_up
            timeout 20 ssh -o ConnectTimeout=10 "$HOST" '
                echo "up:    $(uptime -p) — load $(cut -d" " -f1-3 /proc/loadavg)"
                echo "users: $(who | awk "{print \$1}" | sort | uniq -c | awk "{printf \"%s(%s) \", \$2, \$1}")"
                echo "mem:   $(free -g | awk "/Mem:/ {print \$7 \" GB free of \" \$2}")"
                echo "busy:  $(ps -eo user,pcpu,comm --sort=-pcpu | awk "NR>1 && NR<=4 {printf \"%s %s%% %s; \", \$1, \$2, \$3}")"
            ' 2>/dev/null || echo "(ssh did not answer)"
        fi
        ;;

    --wait)
        # after --start: until ssh answers, three minutes at most
        vpn_up || exit 1
        for _ in $(seq 1 18); do
            timeout 15 ssh -o ConnectTimeout=10 "$HOST" true 2>/dev/null && { echo "ssh up"; exit 0; }
            sleep 10
        done
        echo "no ssh after 3 min"; exit 1
        ;;

    --vpn)
        command -v rasdial.exe >/dev/null || { echo "no rasdial.exe here (not WSL): connect the VPN yourself"; exit 1; }
        vpn_up && echo "VPN connected ($VPN)"
        ;;

    --history)
        # who started / stopped this machine lately (times are UTC). --max-events: the
        # default page holds the latest 50 entries, which policy audits fill in an hour
        az monitor activity-log list --resource-group "$RG" --offset 1d --max-events 1000 \
            --query "[?contains(resourceId,'/virtualMachines/$NAME') && (contains(operationName.value,'virtualMachines/start') || contains(operationName.value,'deallocate'))] | [?status.value=='Succeeded'].[eventTimestamp, operationName.value, caller]" \
            -o tsv | sed -E 's|Microsoft.Compute/virtualMachines/||; s|/action||' | sort
        ;;

    *)
        echo "Usage: vm [payg|spot] --start | --stop | --status | --wait | --vpn | --history   (no machine word: payg; --start moves the data disk to the machine starting and refuses while the other runs)"
        exit 1
        ;;
esac
