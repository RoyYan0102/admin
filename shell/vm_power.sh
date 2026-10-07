#!/usr/bin/env bash
# vm_power: start / stop the OIM high-spec VMs (Azure) with az alone — no VPN, no ssh config.
#   vm_power.sh payg|spot --start | --stop
# payg = high-spec-linux-vm (pay as you go); spot = high-spec-spot (Azure may deallocate it
# for capacity). The data disk (/data) is one disk the two machines take turns with: ext4
# takes one mounting machine at a time (2026-10-01: attached to both, the filesystem took
# errors). So --start refuses while the other machine runs, then moves the disk to the
# machine it starts: detach, attach at lun 1 with caching None (the only setting Premium
# SSD v2 takes); a maxShares above 1 is first set to 1, on the detached disk, so Azure
# refuses a second attachment from then on. Both fstabs mount /data by UUID with nofail: a
# machine started without it still boots. --stop deallocates (the VM is not billed).
# `vm` (vm_ops.sh beside this) sources this file for the same functions; run on its own it
# needs only az, logged in with rights on the two VMs and the disk.
VM_RG=OIM-CONTAINERS-UKSOUTH
VM_DATA_DISK=vm-data-drive
VM_PAYG=high-spec-linux-vm
VM_SPOT=high-spec-spot

vm_name_of() { case "$1" in payg) echo "$VM_PAYG" ;; spot) echo "$VM_SPOT" ;; esac; }
vm_other() { [ "$1" = payg ] && echo spot || echo payg; }
# "VM running" / "VM deallocated" / "VM stopped" / "VM starting" …; empty when az cannot say
vm_power_of() {
    az vm get-instance-view --resource-group "$VM_RG" --name "$1" \
        --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus" -o tsv
}
# the names of the VMs the data disk is attached to, one per line (none: detached)
vm_disk_holders() {
    local ids
    ids=$(az disk show --resource-group "$VM_RG" --name "$VM_DATA_DISK" \
        --query "[managedBy, managedByExtended[]][] | [?@ != null]" -o tsv) || return 1
    printf '%s\n' "$ids" | sed 's|.*/||' | sort -u | sed '/^$/d'
}
vm_disk_shares() { az disk show --resource-group "$VM_RG" --name "$VM_DATA_DISK" --query maxShares -o tsv; }
# the data disk onto VM $1; the caller has checked that both machines are stopped
vm_move_disk_to() {
    local name=$1 holders shares h
    holders=$(vm_disk_holders) || return 1
    shares=$(vm_disk_shares) || return 1
    [ "$holders" = "$name" ] && [ "${shares:-1}" -le 1 ] && return 0
    for h in $holders; do
        case "$h" in
            "$VM_PAYG"|"$VM_SPOT") ;;
            *) echo "$VM_DATA_DISK is attached to $h, which is neither machine: left alone"; return 1 ;;
        esac
    done
    for h in $holders; do
        echo "Detaching $VM_DATA_DISK from $h..."
        az vm disk detach --resource-group "$VM_RG" --vm-name "$h" --name "$VM_DATA_DISK" -o none || return 1
    done
    if [ "${shares:-1}" -gt 1 ]; then
        az disk update --resource-group "$VM_RG" --name "$VM_DATA_DISK" --max-shares 1 -o none || return 1
        echo "$VM_DATA_DISK: maxShares $shares -> 1, so Azure refuses a second attachment from now on"
    fi
    echo "Attaching $VM_DATA_DISK to $name (lun 1)..."
    az vm disk attach --resource-group "$VM_RG" --vm-name "$name" --name "$VM_DATA_DISK" \
        --lun 1 --caching None -o none
}

# start machine $1 (payg | spot): refused while the other runs; the disk moved here first
vm_power_start() {
    local machine=$1 name here other other_name there holders
    name=$(vm_name_of "$machine")
    here=$(vm_power_of "$name")
    case "$here" in
        "VM deallocated"|"VM stopped") ;;
        "VM running")
            holders=$(vm_disk_holders | paste -sd ' ' -)
            echo "$name ($machine) is already running; data disk $VM_DATA_DISK: ${holders:-detached}"
            return 0 ;;
        "") echo "could not read $name's state (az login?): not started"; return 1 ;;
        *) echo "$name ($machine): $here — try again once it has settled"; return 1 ;;
    esac
    other=$(vm_other "$machine")
    other_name=$(vm_name_of "$other")
    there=$(vm_power_of "$other_name")
    case "$there" in
        "VM deallocated"|"VM stopped") ;;
        "") echo "could not read $other_name's state (az login?): not started"; return 1 ;;
        *) echo "$other ($other_name): $there — one machine at a time holds $VM_DATA_DISK: --stop it first"
           return 1 ;;
    esac
    vm_move_disk_to "$name" || { echo "$VM_DATA_DISK could not be moved to $name: not started"; return 1; }
    echo "Starting $name ($machine)..."
    if ! az vm start --resource-group "$VM_RG" --name "$name"; then
        [ "$machine" = spot ] && echo "a spot VM starts only when Azure has the capacity: try again later, or payg"
        return 1
    fi
}

# deallocate machine $1 (payg | spot)
vm_power_stop() {
    local machine=$1 name
    name=$(vm_name_of "$machine")
    echo "Stopping $name ($machine)..."
    az vm deallocate --resource-group "$VM_RG" --name "$name"
}

vm_power_usage() {
    echo "Usage: vm_power.sh payg|spot --start | --stop   (--start moves the shared data disk to the machine starting and refuses while the other runs; --stop deallocates)"
}

vm_power_main() {
    local machine=$1 action=$2
    case "$machine" in
        payg|spot) ;;
        *) vm_power_usage; return 1 ;;
    esac
    case "$action" in
        --start|--stop) ;;
        *) vm_power_usage; return 1 ;;
    esac
    az account show -o none 2>/dev/null || { echo "az is not logged in (az login), or has no subscription: nothing done"; return 1; }
    case "$action" in
        --start) vm_power_start "$machine" ;;
        --stop) vm_power_stop "$machine" ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    vm_power_main "$@"
fi
