#!/usr/bin/env bash
# vm_ops: the OIM high-spec VMs (Azure). `vm <machine> <action>`: the first word picks
# the machine — `payg` (high-spec-linux-vm, 10.45.0.4, pay as you go) or `spot`
# (high-spec-spot, 10.45.0.5, a spot VM Azure may deallocate for capacity) — then the
# action. `vm --status` with no machine word is the pay-as-you-go one (the form of
# every earlier call). --start / --stop are vm_power.sh's (beside this file, sourced here:
# az alone, the data disk moved to the machine starting; the team runs that file on its
# own). What needs this laptop stays here: --vpn connects the VPN (ssh to the VMs' private
# addresses needs it), --wait waits for ssh, --status adds what ssh sees; --history and
# --cost read Azure's logs and Cost Management. The machine word 2026-10-01, --cost
# 2026-10-02, the split 2026-10-07.
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/vm_power.sh"
RG=$VM_RG
DATA_DISK=$VM_DATA_DISK
VPN="Osmosis Azure VPN"   # an Azure VPN Client profile: ssh to the VMs' private addresses needs it

MACHINE=payg
case "$1" in
    payg|spot) MACHINE=$1; shift ;;
    --*|"") ;;
    *) echo "no machine '$1': payg or spot"; exit 1 ;;
esac
NAME=$(vm_name_of "$MACHINE")
case "$MACHINE" in
    payg) HOST=oimvm ;;    # ~/.ssh/config
    spot) HOST=oimspot ;;  # ~/.ssh/config; a spot VM, eviction = deallocate
esac

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

case "$1" in
    --start)
        vm_power_start "$MACHINE"
        ;;

    --stop)
        vm_power_stop "$MACHINE"
        ;;

    --status)
        state=$(vm_power_of "$NAME")
        echo "$MACHINE ($NAME, $HOST): $state"
        holders=$(vm_disk_holders | paste -sd ' ' -)
        shares=$(vm_disk_shares)
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

    --cost)
        # spend over the past three local calendar days as `runtime | cost USD | cost GBP`
        # per day for the pay-as-you-go VM, the spot VM, every managed disk, the rest of the
        # group and the total. One source per day: the two past days from Cost Management
        # (posted usage, at the resource group's scope — the subscription's is refused; two
        # queries, the API takes two aggregations at most); today live, from the VMs'
        # start / stop events in the activity log (the schedule's and evictions included),
        # cross-checked with the instance view, times the current retail hourly price of
        # each VM's size, disks and the rest prorated from the last posted day. Cost
        # Management allows a few queries a minute on the scope. Read-only; needs az login.
        # Formatting and the live arithmetic: vm_cost.py beside this script.
        here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
        sub=$(az account show --query id -o tsv 2>/dev/null) || { echo "az account show failed: az login?"; exit 1; }
        from=$(date -u -d "$(date -d '2 days ago' +%F) 00:00" +%Y-%m-%dT%H:%M:%SZ)
        to=$(date -u -d "$(date -d yesterday +%F) 23:59:59" +%Y-%m-%dT%H:%M:%SZ)
        url="https://management.azure.com/subscriptions/$sub/resourceGroups/$RG/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
        period="\"type\":\"ActualCost\",\"timeframe\":\"Custom\",\"timePeriod\":{\"from\":\"$from\",\"to\":\"$to\"}"
        q1="{$period,\"dataset\":{\"granularity\":\"Daily\",\"aggregation\":{\"totalCost\":{\"name\":\"Cost\",\"function\":\"Sum\"},\"usage\":{\"name\":\"UsageQuantity\",\"function\":\"Sum\"}},\"grouping\":[{\"type\":\"Dimension\",\"name\":\"ResourceId\"},{\"type\":\"Dimension\",\"name\":\"MeterCategory\"},{\"type\":\"Dimension\",\"name\":\"UnitOfMeasure\"}]}}"
        q2="{$period,\"dataset\":{\"granularity\":\"Daily\",\"aggregation\":{\"totalCostUSD\":{\"name\":\"CostUSD\",\"function\":\"Sum\"}},\"grouping\":[{\"type\":\"Dimension\",\"name\":\"ResourceId\"}]}}"
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        if ! az rest --method post --url "$url" --body "$q1" -o json >"$tmp/q1.json" 2>"$tmp/err"; then
            case "$(cat "$tmp/err")" in
                *"Too many requests"*|*'"429"'*) echo "Cost Management is rate-limiting this scope (a few queries a minute): try again in a minute" ;;
                *RBACAccessDenied*|*Unauthorized*) echo "Cost Management refused the query: az login, or a reader role on $RG" ;;
                *) echo "Cost Management query failed:"; cat "$tmp/err" ;;
            esac
            exit 1
        fi
        # the USD query may fail on its own (rate limit): the posted days then show GBP alone
        az rest --method post --url "$url" --body "$q2" -o json >"$tmp/q2.json" 2>&1 || true
        # today's running intervals: every start / deallocate / powerOff that succeeded on either
        # VM in the last two days (a start yesterday may still be running); the log indexes an
        # event within minutes, the instance view covers the gap
        az monitor activity-log list --resource-group "$RG" --offset 2d --max-events 2000 \
            --query "[?status.value=='Succeeded' && contains(resourceId,'/virtualMachines/') && (contains(operationName.value,'/start/action') || contains(operationName.value,'/deallocate/action') || contains(operationName.value,'/powerOff/action'))].[eventTimestamp, resourceId, operationName.value]" \
            -o tsv >"$tmp/events.tsv" 2>/dev/null || : >"$tmp/events.tsv"
        {
            echo "["
            az vm get-instance-view --resource-group "$RG" --name "$(vm_name_of payg)" -o json
            echo ","
            az vm get-instance-view --resource-group "$RG" --name "$(vm_name_of spot)" -o json
            echo "]"
        } >"$tmp/vms.json" 2>/dev/null
        python3 "$here/vm_cost.py" "$tmp/q1.json" "$tmp/q2.json" "$tmp/events.tsv" "$tmp/vms.json" \
            "$(date -d '2 days ago' +%Y%m%d)" "$(date -d yesterday +%Y%m%d)" "$(date +%Y%m%d)"
        ;;

    *)
        echo "Usage: vm [payg|spot] --start | --stop | --status | --wait | --vpn | --history | --cost   (no machine word: payg; --start moves the data disk to the machine starting and refuses while the other runs — vm_power.sh, az alone; --vpn / --wait / --status reach the machine from here; --cost: the group's spend by day, past 3 days, runtime | USD | GBP; today live from the activity log, before from Cost Management)"
        exit 1
        ;;
esac
