# omarchy-lte

An [Omarchy](https://omarchy.org/) bar widget for cellular modems, built on
ModemManager and NetworkManager.

- **Bar icon:** 1–3 signal bars computed from the real LTE RSRP. Many modems report 0% "signal quality" on LTE, so the icon doesn't use that value.
- **Popup:** operator and access technology, registration, a signal bar, RSRP/RSRQ/SNR, the IP address, the active NetworkManager profile, whether it connects at boot, the modem model, and a three-state **Off / Net / Data** switch.
- **Off / Net / Data switch** (`bin/lte-mode`): **Off** turns the modem off (NetworkManager WWAN radio off, kept across reboots); **Net** keeps it registered for SMS and USSD without mobile data; **Data** connects. It also sets the profile's `autoconnect`, so the choice survives a reboot. If the modem stays idle (not registered) for a minute while the radio is on, which happens after some boots, the widget power-cycles it once (at most every 10 minutes) so it registers.
- **Data roaming switch:** sets the profile's `gsm.home-only`.
- **Traffic counter:** received, sent, and total mobile data since the last reset, with a **Reset** button (click twice to confirm). It survives reboots and modem resets: `bin/lte_traffic.py` keeps a running total in `~/.local/state/omarchy-lte/traffic.json` and adds only the increase in the `wwan0` kernel counters, treating a counter restart (new boot, recreated interface) as new traffic. The total also appears in the icon tooltip. `bin/lte-traffic reset` resets it from the command line.
- **Network mode:** Auto (3G+4G, prefer 4G), 4G only, or 3G only, through ModemManager.
- **USSD:** an input field plus an optional **Balance** button (`balanceCode` setting), with interactive menus supported. Many networks register a data-centric LTE modem as "SMS only", which leaves it without the CS domain, so USSD fails on LTE. `bin/lte-ussd` temporarily restricts the modem to 3G, waits for stable registration, sends the request (with retries), and then forces LTE reselection and restores the original modes.
- **Modem log (`󰈙`):** opens a terminal following this boot's modem log: all of ModemManager, plus the modem-related lines from NetworkManager and the kernel (iosm/wwan), the FCC unlock, the resume reset, and the widget's own actions (`lte-mode`). From the command line: `bin/lte-logs` (follow) or `bin/lte-logs --print`.
- **Speed test (`󰓅`):** the same dials as the Omarchy Wi-Fi speed test (fast.com, 5 s each way), with all traffic forced through the modem interface, so it measures the mobile link even while Wi-Fi is the default route. One run uses roughly 10–20 MB of mobile data.
- **Clicks:** left opens the popup, right toggles mobile data, middle refreshes.

It works with any modem that ModemManager drives. It was written for the Intel
XMM7360 / Fibocom L850-GL, which needs a ModemManager fix to get onto the
network at all: see [xmm7360-lte](https://github.com/sbtasm-cmd/xmm7360-lte).

## Install

```sh
omarchy plugin add https://github.com/sbtasm-cmd/omarchy-lte.git --enable
```

The plugin lands in `~/.config/omarchy/plugins/xmm7360.lte/` and appears in the
right section of the bar. Move it with `omarchy bar move xmm7360.lte ...`.

## Requirements

- ModemManager (`mmcli`) and NetworkManager (`nmcli`), with a GSM connection profile, for example:
  ```sh
  sudo nmcli connection add type gsm ifname '*' con-name lte gsm.apn <your-apn> connection.autoconnect yes
  ```
- Python 3, for `bin/lte-status`, which collects the state as JSON. `curl` and `jq` for `bin/lte-speedtest`.
- Use from the local graphical session: polkit allows mobile data control and signal polling setup (`mmcli --signal-setup`) only for the active local session.

## Settings

| Key | Default | Meaning |
|---|---|---|
| `refreshIntervalSec` | `10` | Refresh interval while the popup is closed (3 s while open) |
| `hideWithoutModem` | `true` | Hide the widget when ModemManager sees no modem |
| `balanceCode` | `""` | USSD code for the Balance button, e.g. `*111#`; the button is hidden while empty |

## License

GPL-2.0-or-later
