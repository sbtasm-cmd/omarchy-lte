# omarchy-lte

An [Omarchy](https://omarchy.org/) bar widget for cellular modems, built on
ModemManager and NetworkManager.

- **Bar icon:** 1–3 signal bars computed from the real LTE RSRP. Many modems report 0% "signal quality" on LTE, so the icon doesn't use that value.
- **Popup:** operator and access technology, registration, a signal bar, RSRP/RSRQ/SNR, the IP address, the active NetworkManager profile, the modem model, and a **mobile data** switch.
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
- Python 3, for `bin/lte-status`, which collects the state as JSON.
- Use from the local graphical session: polkit allows mobile data control and signal polling setup (`mmcli --signal-setup`) only for the active local session.

## Settings

| Key | Default | Meaning |
|---|---|---|
| `refreshIntervalSec` | `10` | Refresh interval while the popup is closed (3 s while open) |
| `hideWithoutModem` | `true` | Hide the widget when ModemManager sees no modem |

## License

GPL-2.0-or-later
