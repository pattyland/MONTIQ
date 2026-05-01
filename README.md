# MONTIQ

MONitoring Telemetry In Queue (MONTIQ) is a tiny Bash helper for Raspberry Pi and other headless Linux mini PCs. It publishes health metrics to MQTT and creates Home Assistant entities automatically via MQTT Discovery.

MONTIQ is designed around Raspberry Pi-style monitoring. It can run on other Unix-like systems, but some sensors are best-effort there.

## Sensors
- **CPU Temperature**: SoC/CPU temperature. Works on Raspberry Pi via Linux thermal data or `vcgencmd`; only published when readable.
- **Undervoltage**: Raspberry Pi power warning from `vcgencmd get_throttled`. Usually unavailable on non-Raspberry Pi hardware.
- **Load 1m**: 1-minute system load average.
- **Memory Usage**: Used memory in percent.
- **Disk Usage**: Used disk space for the configured path. Defaults to `/` on Linux and `/System/Volumes/Data` on macOS.
- **Last Boot**: Timestamp of the last boot, if the platform exposes it.

If a sensor cannot be read, MONTIQ skips it and does not create a Home Assistant entity for it.

## Install Requirements
Debian / Ubuntu / Raspberry Pi OS:

```bash
sudo apt install mosquitto-clients
```

Fedora / Red Hat / CentOS:

```bash
sudo dnf install mosquitto
```

macOS:

```bash
brew install mosquitto
```

MONTIQ also expects standard shell tools such as `awk`, `df`, `uptime`, and `crontab`.

## Quick Start
```bash
cp montiq.example.conf montiq.conf
chmod +x montiq.sh
```

Edit `montiq.conf` and set at least `MQTT_HOST`. Then run a debug pass:

```bash
./montiq.sh --debug
```

Once the sensors appear in Home Assistant, schedule it with cron:

```cron
* * * * * /path/to/montiq.sh
```

## Configuration
Only `MQTT_HOST` is required. Copy `montiq.example.conf` to `montiq.conf` and edit that file; it is the single source for available options and defaults.

Common options include MQTT credentials, TLS settings, `DISK_PATH`, and `ENABLE_*` switches for disabling individual sensors.

`montiq.conf` is sourced as Bash, so only use configuration files you trust. It may contain local MQTT credentials and is ignored by Git via `.gitignore`; publish `montiq.example.conf`, not your private `montiq.conf`.
