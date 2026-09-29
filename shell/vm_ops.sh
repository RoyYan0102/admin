#!/usr/bin/env bash
# vm_ops: the OIM high-spec VM (Azure). --start / --stop as before; --status, --wait,
# --history added 2026-09-26; --vpn, and --start / --wait / --status connecting the VPN
# first, 2026-09-29.
RG=OIM-CONTAINERS-UKSOUTH
NAME=high-spec-linux-vm
HOST=oimvm   # ~/.ssh/config
VPN="Osmosis Azure VPN"   # an Azure VPN Client profile: ssh to the VM's private address needs it

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
        echo "Starting VM..."
        az vm start --resource-group "$RG" --name "$NAME"
        ;;

    --stop)
        echo "Stopping VM..."
        az vm deallocate --resource-group "$RG" --name "$NAME"
        ;;

    --status)
        state=$(power_state)
        echo "power: $state"
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
        # who started / stopped it lately (times are UTC)
        az monitor activity-log list --resource-group "$RG" --offset 1d \
            --query "[?contains(operationName.value,'virtualMachines/start') || contains(operationName.value,'deallocate')] | [?status.value=='Succeeded'].[eventTimestamp, operationName.value, caller]" \
            -o tsv | sed -E 's|Microsoft.Compute/virtualMachines/||; s|/action||' | sort
        ;;

    *)
        echo "Usage: vm_ops --start | --stop | --status | --wait | --vpn | --history"
        exit 1
        ;;
esac
