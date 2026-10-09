# SPDX-License-Identifier: GPL-2.0-or-later
"""Persistent mobile data counter.

The kernel's per-interface byte counters start from zero on every boot and
whenever the modem interface is recreated (modem reset after suspend, driver
rebind). This module keeps a running total in
$XDG_STATE_HOME/omarchy-lte/traffic.json and adds only the increase since the
last sample. When the counter went backwards, the boot changed, or the
interface was recreated, the current value counts as all-new traffic.
"""
import fcntl
import json
import os
import time

STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")), "omarchy-lte")
STATE_FILE = os.path.join(STATE_DIR, "traffic.json")
DEFAULT_IFACE = "wwan0"


def _read(path, default=None):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def _now():
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def _sample(iface):
    base = f"/sys/class/net/{iface}"
    rx, tx = _read(f"{base}/statistics/rx_bytes"), _read(f"{base}/statistics/tx_bytes")
    if rx is None or tx is None:
        return None
    return {"rx": int(rx), "tx": int(tx), "ifindex": _read(f"{base}/ifindex", ""),
            "boot": _read("/proc/sys/kernel/random/boot_id", "")}


def _locked(update):
    """Run update(state) -> state under an exclusive lock and save the result."""
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(STATE_FILE + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with open(STATE_FILE) as f:
                state = json.load(f)
        except (OSError, ValueError):
            state = {}
        state.setdefault("rx", 0)
        state.setdefault("tx", 0)
        state.setdefault("since", _now())
        state = update(state)
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(state, f, indent=1)
        os.replace(tmp, STATE_FILE)
        return state


def update(iface=DEFAULT_IFACE):
    """Add traffic since the last sample; return {rx, tx, total, since}."""
    def step(state):
        cur = _sample(iface)
        if cur is None:
            return state
        last = state.get("last")
        same_counter = (last and last.get("boot") == cur["boot"] and last.get("ifindex") == cur["ifindex"]
                        and last.get("iface") == iface)
        for key in ("rx", "tx"):
            if same_counter and cur[key] >= last[key]:
                state[key] += cur[key] - last[key]
            else:
                state[key] += cur[key]           # counter restarted: all of it is new
        state["last"] = dict(cur, iface=iface)
        return state

    return summary(_locked(step))


def reset(iface=DEFAULT_IFACE):
    """Zero the totals; the current kernel counters become the new baseline."""
    def step(state):
        cur = _sample(iface)
        state.update({"rx": 0, "tx": 0, "since": _now()})
        if cur is not None:
            state["last"] = dict(cur, iface=iface)
        return state

    return summary(_locked(step))


def summary(state):
    return {"rx": state["rx"], "tx": state["tx"], "total": state["rx"] + state["tx"], "since": state["since"]}
