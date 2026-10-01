# vm_commands: az commands worth knowing for the two OIM VMs. All commented out: copy the
# one you need. Each was checked on 2026-10-01 against az 2.90's help, the Microsoft
# reference, or a read-only run (both bash and fish for the quoted ones).
# Set these first:
#   bash: RG=OIM-CONTAINERS-UKSOUTH VM=high-spec-spot
#   fish: set RG OIM-CONTAINERS-UKSOUTH; set VM high-spec-spot     (payg: high-spec-linux-vm)
# Reference: https://learn.microsoft.com/en-us/cli/azure/vm?view=azure-cli-latest

# --- Look ----------------------------------------------------------------------------------

# Both VMs on one screen: power state, size, spot or not, private IP, zone
# az vm list -d -g $RG --query "[].{name:name, power:powerState, size:hardwareProfile.vmSize, priority:priority, ip:privateIps, zone:zones[0]}" -o table

# CPU over the last day, hourly average and peak: is the size right?
# az monitor metrics list --resource $(az vm show -g $RG -n $VM --query id -o tsv) --metric "Percentage CPU" --offset 1d --interval PT1H --aggregation Average Maximum -o table

# Quota left in uksouth. The spot draws on "Low-priority vCPUs": 48 of 50 used on 10-01
# az vm list-usage -l uksouth --query "[?contains(name.value, 'Dadsv7') || contains(name.value, 'Easv7') || name.value=='lowPriorityCores' || name.value=='cores'].{quota:localName, used:currentValue, limit:limit}" -o table

# --- Size and price ------------------------------------------------------------------------

# Sizes this VM can move to where it runs now (deallocated, it can go to more); then resize,
# which restarts it
# az vm list-vm-resize-options -g $RG -n $VM -o table
# az vm resize -g $RG -n $VM --size Standard_D32ads_v7

# Hourly price in GBP, pay-as-you-go and spot (no login needed)
# az rest --method get --skip-authorization-header --url "https://prices.azure.com/api/retail/prices?currencyCode=GBP&\$filter=armRegionName eq 'uksouth' and armSkuName eq 'Standard_E16as_v7' and priceType eq 'Consumption'" --query "Items[?!contains(productName,'Windows')].{meter:meterName, gbp_per_hour:retailPrice}" -o table

# Spot eviction rate band per size (Azure Resource Graph): all three were 0-5% on 10-01
# az rest --method post --url "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01" --body '{"query": "SpotResources | where type =~ \"microsoft.compute/skuspotevictionrate/location\" and location =~ \"uksouth\" | where sku.name in~ (\"standard_d48ads_v7\", \"standard_f32as_v7\", \"standard_e16as_v7\") | project sku = tostring(sku.name), rate = tostring(properties.evictionRate)"}' --query data -o table

# --- When ssh fails ------------------------------------------------------------------------

# Run a shell command on the VM through Azure: no ssh, no VPN; runs as root, slower than ssh
# az vm run-command invoke -g $RG -n $VM --command-id RunShellScript --scripts "uptime; df -h /data /mnt/scratch; who" --query "value[0].message" -o tsv

# The firewall rules that reach the VM's network card for port 22, Defender's just-in-time
# rules included (they cut ssh on 10-01)
# az network nic list-effective-nsg --ids $(az vm show -g $RG -n $VM --query "networkProfile.networkInterfaces[0].id" -o tsv) --query "value[].effectiveSecurityRules[?direction=='Inbound'] | [] | [?contains(join(',', destinationPortRanges), '22') || access=='Deny'].{rule:name, access:access, prio:priority, src:join(' ', sourceAddressPrefixes)}" -o table

# The console log of the last boot as plain text: fstab, emergency mode and disk errors
# show here (boot diagnostics is on for both VMs)
# curl -s "$(az vm boot-diagnostics get-boot-log-uris -g $RG -n $VM --query serialConsoleLogBlobUri -o tsv)" | tr -d '\r' | sed 's/\x1b\[[0-9;=?]*[A-Za-z]//g' | tail -50

# A live serial console, even with the network down. Logging in needs an account with a
# password, and ours are key-only; it still shows the boot. Ctrl+] then q leaves.
# Installs the serial-console extension on first use.
# az serial-console connect -g $RG -n $VM

# Put a user's ssh key back, or reset sshd's config to Azure's default (VMAccess extension)
# az vm user update -g $RG -n $VM -u royceyan --ssh-key-value "$(cat ~/.ssh/id_ed25519.pub)"
# az vm user reset-ssh -g $RG -n $VM

# The OS disk won't boot: a rescue VM gets a copy of it as a data disk, you fix it there,
# then restore swaps the fixed copy in. Installs the vm-repair extension. A small rescue
# size, because by default it copies the source VM's size and needs that much quota
# az vm repair create -g $RG -n $VM --size Standard_D4ads_v7 --repair-username rescue --repair-password '<password>' --verbose
# az vm repair restore -g $RG -n $VM --verbose

# --- Spot, scratch and disks ---------------------------------------------------------------

# A reboot keeps /mnt/scratch (the local NVMe); deallocation, eviction and redeploy wipe
# it, and a resize can
# az vm restart -g $RG -n $VM

# Rehearse a spot eviction: Azure evicts the VM as it would for capacity (deallocated, as
# its policy says). The way to see what an eviction does to running jobs
# az vm simulate-eviction -g $RG -n high-spec-spot

# Snapshot the data disk before anything risky: incremental, kept on Standard HDD, billed
# for the used size. A Premium SSD v2 snapshot is usable once completionPercent is 100
# az snapshot create -g $RG -n vm-data-drive-$(date +%F) --source vm-data-drive --incremental true
# az snapshot list -g $RG --query "[?incremental].{name:name, made:timeCreated, done:completionPercent}" -o table
# Restoring is a new disk from it, in zone 2 like the VMs, attached in place of vm-data-drive
# az disk create -g $RG -n vm-data-drive-restored --source vm-data-drive-2026-10-01 --sku PremiumV2_LRS --zone 2

# Move the VM to another Azure host, when the host itself misbehaves; wipes the local NVMe
# az vm redeploy -g $RG -n $VM
