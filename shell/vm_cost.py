#!/usr/bin/env python3
"""Format `vm --cost`: the resource group's spend over the past three local calendar days,
as ``runtime (XhYm) | cost USD | cost GBP`` per day, one source per day:

- the two past days from Cost Management (posted usage: a VM's runtime is the hours of its
  "Virtual Machines" meter, its cost the meters' sum; disks and the rest of the group too);
- today live: each VM's running intervals from the activity log (start / deallocate /
  powerOff that succeeded, the scheduled stops and evictions included), cross-checked with
  its instance view, times the current retail hourly price of its size (on-demand, or the
  spot price for a spot VM) in GBP and USD; the disks and the rest of the group, which cost
  the same every day, prorated from the last posted day.

Arguments: q1.json q2.json (Cost Management: Cost + UsageQuantity by ResourceId / MeterCategory
/ UnitOfMeasure; CostUSD by ResourceId), events.tsv (eventTimestamp, resourceId, operation),
vms.json (a list of `az vm get-instance-view` objects), then the three days YYYYMMDD (local).
"""

from __future__ import annotations

import json
import re
import sys
import urllib.parse
import urllib.request
from collections import defaultdict
from datetime import datetime
from pathlib import Path

RETAIL = "https://prices.azure.com/api/retail/prices"


# ---- Cost Management (the past days) -------------------------------------------------------


def _load_query(path: str) -> tuple[list[str], list[list]] | str:
    raw = Path(path).read_text(encoding="utf-8")
    try:
        props = json.loads(raw)["properties"]
    except (ValueError, KeyError):
        return raw.strip().splitlines()[0][:160] if raw.strip() else "empty response"
    return [c["name"] for c in props["columns"]], props["rows"]


def _bucket(resource_id: str | None, names: dict[str, str]) -> str:
    parts = (resource_id or "").lower().split("/")
    name, kind = (parts[-1], parts[-2]) if len(parts) >= 2 else ("", "")
    if kind == "virtualmachines" and name in names:
        return names[name]
    if kind == "disks":
        return "disks"
    return "other"


def _hours(unit: str | None, quantity: float) -> float:
    """Usage in hours for a unit such as '1 Hour' or '10 Hours'; 0 for anything else."""
    head, _, tail = (unit or "").strip().partition(" ")
    if not tail.lower().startswith("hour"):
        return 0.0
    try:
        return quantity * float(head)
    except ValueError:
        return 0.0


def _hm(hours: float) -> str:
    minutes = int(round(hours * 60))
    return f"{minutes // 60}h{minutes % 60:02d}m"


# ---- today, live ---------------------------------------------------------------------------


def _parse_time(text: str) -> datetime:
    text = text.strip().replace("Z", "+00:00")
    text = re.sub(r"(\.\d{6})\d+", r"\1", text)  # Azure's 7 fractional digits -> 6
    return datetime.fromisoformat(text)


def _intervals(events: list[tuple[datetime, str]], running_now: bool, last_change: datetime | None,
               day_start: datetime, now: datetime) -> list[tuple[datetime, datetime]]:
    """Running intervals within [day_start, now) from the VM's start / stop events.

    `events` are (time, 'start' | 'stop'), any order. The state at day_start is the last
    event before it. A fresh event the log has not indexed yet is taken from the instance
    view: running now with no open interval -> running since `last_change`; stopped now with
    an open interval -> stopped at `last_change`.
    """
    events = sorted(events)
    running_since: datetime | None = None
    out: list[tuple[datetime, datetime]] = []
    for when, kind in events:
        if kind == "start":
            if running_since is None:
                running_since = when
        elif running_since is not None:
            out.append((running_since, when))
            running_since = None
    if running_since is None and running_now:
        running_since = last_change or now
    elif running_since is not None and not running_now:
        out.append((running_since, last_change or now))
        running_since = None
    if running_since is not None:
        out.append((running_since, now))
    clipped = []
    for a, b in out:
        a, b = max(a, day_start), min(b, now)
        if b > a:
            clipped.append((a, b))
    return clipped


def _retail_price(sku: str, spot: bool, currency: str) -> float | None:
    """The current hourly price of a Linux VM size in uksouth, on-demand or spot."""
    flt = (f"armRegionName eq 'uksouth' and armSkuName eq '{sku}' and priceType eq 'Consumption'"
           " and serviceName eq 'Virtual Machines'")
    url = f"{RETAIL}?currencyCode={currency}&$filter={urllib.parse.quote(flt)}"
    try:
        with urllib.request.urlopen(url, timeout=20) as resp:  # noqa: S310 (a fixed https host)
            items = json.load(resp).get("Items", [])
    except Exception:  # network, a changed API: the live row then shows no price
        return None
    for item in items:
        if "Windows" in item.get("productName", ""):
            continue
        meter = item.get("meterName", "")
        if meter.endswith(" Spot") == spot and "Low Priority" not in meter:
            return float(item["unitPrice"])
    return None


# ---- the table -----------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    q1_path, q2_path, events_path, vms_path, *days = argv
    vms = json.loads(Path(vms_path).read_text(encoding="utf-8"))
    names = {vm["name"].lower(): ("VM spot" if (vm.get("priority") or "").lower() == "spot" else "VM payg") for vm in vms}
    items = ("VM payg", "VM spot", "disks", "other")
    width = max(len(i) for i in items + ("total",))

    # posted days
    q1 = _load_query(q1_path)
    if isinstance(q1, str):
        print(f"cost query failed: {q1}")
        return 1
    cols, rows = q1
    i_cost, i_qty, i_day = cols.index("Cost"), cols.index("UsageQuantity"), cols.index("UsageDate")
    i_rid, i_cat, i_unit, i_cur = (cols.index(c) for c in ("ResourceId", "MeterCategory", "UnitOfMeasure", "Currency"))
    gbp: dict[tuple[str, str], float] = defaultdict(float)
    runtime: dict[tuple[str, str], float] = defaultdict(float)
    posted: set[str] = set()
    currency = "GBP"
    for row in rows:
        day, item = str(row[i_day]), _bucket(row[i_rid], names)
        gbp[day, item] += row[i_cost] or 0.0
        posted.add(day)
        currency = row[i_cur] or currency
        if item.startswith("VM") and (row[i_cat] or "") == "Virtual Machines":
            runtime[day, item] += _hours(row[i_unit], row[i_qty] or 0.0)
    q2 = _load_query(q2_path)
    usd: dict[tuple[str, str], float] | None = defaultdict(float)
    notes: list[str] = []
    if isinstance(q2, str):
        usd, notes = None, [f"USD column of the posted days unavailable: {q2}"]
    else:
        cols2, rows2 = q2
        j_cost, j_day, j_rid = cols2.index("CostUSD"), cols2.index("UsageDate"), cols2.index("ResourceId")
        for row in rows2:
            usd[str(row[j_day]), _bucket(row[j_rid], names)] += row[j_cost] or 0.0

    def print_day(label: str, run: dict[str, str], cost_usd: dict[str, float | None], cost_gbp: dict[str, float]) -> None:
        print(label)
        tu = tg = 0.0
        usd_known = True
        for item in items:
            u, g = cost_usd.get(item), cost_gbp.get(item, 0.0)
            tg += g
            if u is None:
                usd_known = False
            else:
                tu += u
            u_text = f"{u:7.2f} USD" if u is not None else "      - USD"
            print(f"  {item:<{width}}  {run.get(item, '-'):>7} | {u_text} | {g:7.2f} {currency}")
        u_text = f"{tu:7.2f} USD" if usd_known else "      - USD"
        print(f"  {'total':<{width}}  {'':>7} | {u_text} | {tg:7.2f} {currency}")

    *past, today = days
    for day in past:
        label = f"{day[:4]}-{day[4:6]}-{day[6:]}  (posted)"
        if day not in posted:
            print(f"{label[:-9]} (nothing posted yet)")
            continue
        print_day(label,
                  {i: _hm(runtime[day, i]) for i in items if (day, i) in runtime},
                  {i: (usd.get((day, i), 0.0) if usd is not None else None) for i in items},
                  {i: gbp.get((day, i), 0.0) for i in items})

    # today, live
    now = datetime.now().astimezone()
    day_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    events: dict[str, list[tuple[datetime, str]]] = defaultdict(list)
    for line in Path(events_path).read_text(encoding="utf-8").splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        when, rid, op = parts[0], parts[1].lower(), parts[2].lower()
        name = rid.rsplit("/", 1)[-1]
        if name not in names:
            continue
        kind = "start" if op.endswith("/start/action") else "stop"
        events[names[name]].append((_parse_time(when), kind))
    run_today: dict[str, str] = {}
    usd_today: dict[str, float | None] = {}
    gbp_today: dict[str, float] = {}
    for vm in vms:
        item = names[vm["name"].lower()]
        statuses = vm.get("instanceView", {}).get("statuses", [])
        running_now = any(s.get("code") == "PowerState/running" for s in statuses)
        changed = next((s.get("time") for s in statuses if s.get("code", "").startswith("ProvisioningState/") and s.get("time")), None)
        spans = _intervals(events[item], running_now, _parse_time(changed) if changed else None, day_start, now)
        hours = sum((b - a).total_seconds() for a, b in spans) / 3600
        run_today[item] = _hm(hours) + ("+" if running_now else "")
        sku = vm.get("hardwareProfile", {}).get("vmSize", "")
        spot = (vm.get("priority") or "").lower() == "spot"
        p_gbp, p_usd = _retail_price(sku, spot, "GBP"), _retail_price(sku, spot, "USD")
        gbp_today[item] = hours * p_gbp if p_gbp is not None else 0.0
        usd_today[item] = hours * p_usd if p_usd is not None else None
        if p_gbp is None or p_usd is None:
            notes.append(f"{item}: no retail price found for {sku} ({'spot' if spot else 'on-demand'}): its live cost reads 0")
        else:
            notes.append(f"{item}: {sku}{' spot' if spot else ''} at {p_gbp:.4f} GBP / {p_usd:.4f} USD an hour (retail price now)")
    # disks and the rest: steady costs, prorated from the last posted day
    last_posted = max((d for d in posted if d < today), default=None)
    share = (now - day_start).total_seconds() / 86400
    for item in ("disks", "other"):
        run_today[item] = "-"
        if last_posted is None:
            gbp_today[item], usd_today[item] = 0.0, (0.0 if usd is not None else None)
        else:
            gbp_today[item] = gbp.get((last_posted, item), 0.0) * share
            usd_today[item] = usd.get((last_posted, item), 0.0) * share if usd is not None else None
    print_day(f"{today[:4]}-{today[4:6]}-{today[6:]}  (live, until {now:%H:%M}{', running: +' if any(r.endswith('+') for r in run_today.values()) else ''})",
              run_today, usd_today, gbp_today)
    print("posted days: Cost Management (Azure bills in UTC days and posts usage up to a day late);")
    print("today: the VMs' running intervals from the activity log x the current retail price, disks and")
    print(f"the rest of the group prorated from the last posted day{' (' + last_posted[:4] + '-' + last_posted[4:6] + '-' + last_posted[6:] + ')' if last_posted else ''}; '+' = still running.")
    for note in notes:
        print(note)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
