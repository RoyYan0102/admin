#!/usr/bin/env bash
# vm_ops: the OIM high-spec VM (Azure). --start / --stop as before; --status, --wait,
# --history added 2026-09-26.
RG=OIM-CONTAINERS-UKSOUTH
NAME=high-spec-linux-vm
HOST=oimvm   # ~/.ssh/config

power_state() {
    az vm get-instance-view --resource-group "$RG" --name "$NAME" \
        --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus" -o tsv
}

case "$1" in
    --start)
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
        for _ in $(seq 1 18); do
            timeout 15 ssh -o ConnectTimeout=10 "$HOST" true 2>/dev/null && { echo "ssh up"; exit 0; }
            sleep 10
        done
        echo "no ssh after 3 min"; exit 1
        ;;

    --history)
        # who started / stopped it lately (times are UTC)
        az monitor activity-log list --resource-group "$RG" --offset 1d \
            --query "[?contains(operationName.value,'virtualMachines/start') || contains(operationName.value,'deallocate')] | [?status.value=='Succeeded'].[eventTimestamp, operationName.value, caller]" \
            -o tsv | sed -E 's|Microsoft.Compute/virtualMachines/||; s|/action||' | sort
        ;;

    *)
        echo "Usage: vm_ops --start | --stop | --status | --wait | --history"
        exit 1
        ;;
esac
