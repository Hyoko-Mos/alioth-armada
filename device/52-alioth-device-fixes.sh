#!/bin/bash
# Redmi K40 / POCO F3 (alioth) device fixes.
#
# Differences vs thyme (52-thyme-device-fixes.sh):
#   touch  is the in-kernel FocalTech FT8756 SPI driver (focaltech,ft8756-spi
#          on spi4.0) — a real input device, no userspace THP daemon. The
#          panel has an intermittent hardware fault; a mask helper is shipped
#          (alioth-touch-mask) but NOT auto-enabled.
#   audio  the alioth sound card is named "xiaomi-alioth" and drives the two
#          CS35L41 amps over TERTIARY MI2S (TERT_MI2S_RX, main TLMM mi2s2 pins
#          gpio133/135/137, 48 kHz 16-bit stereo, TER_MI2S_IBIT 1.536 MHz). Not
#          thyme's "XIAOMI-UMI-..." card, so the thyme UCM2 does not match;
#          alioth UCM2 is staged under system_files/usr/share/alsa/ucm2.
#          audio is still not boot-critical (the route service is best-effort).
#   usb    pure NCM gadget (10.42.0.1/24 + fe80::1/64). RNDIS was dropped: this
#          host's RNDIS driver fails to start (Code 10) and one failing function
#          makes Windows reject the whole composite device. The gadget below is
#          synced verbatim from payload/armada-usbgadget (device-validated final
#          scheme: UDC wait + logging), with the retry drop-in and the NM
#          unmanaged conf installed alongside it.
#
# What stays identical to thyme:
#   steam   steam-now: probe the Steam CDN and fall back to offline mode.
#   selinux permissive for this variant; see the note at the bottom.
#
# NOTE: everything here installs into /usr/bin or /usr/libexec, never
# /usr/local. On ostree /usr/local is a symlink into /var, so files placed
# there at image build time do not survive deployment.
set -euxo pipefail

# ---------------------------------------------------------------------------
# 1. Remote access: sshd + pure-NCM USB gadget
#
# The gadget below is synced verbatim from payload/armada-usbgadget (the
# device-validated final scheme); keep the two identical, the payload file is
# the baseline. NCM only: a failing RNDIS function (Code 10 on this host) makes
# Windows reject the whole composite device.
# ---------------------------------------------------------------------------
systemctl enable sshd.service

cat > /usr/libexec/armada-usbgadget <<'GADGET'
#!/bin/bash
# USB Ethernet gadget (NCM only) for host access on alioth.
#
# NCM instead of RNDIS: this host's RNDIS driver fails to start (Code 10) and
# one failing function makes Windows reject the whole composite device.
#
# Everything is logged to /var/log/armada-usbgadget.log: with a dead touch
# panel and no network, the log file (readable from TWRP) is the only way to
# find out why the gadget did not come up. No `set -e` -- a failure must be
# reported, not silently abort the unit halfway through configfs setup.
set -u

GADGET=/sys/kernel/config/usb_gadget/armada
LOG=/var/log/armada-usbgadget.log
UDC_WAIT=${UDC_WAIT:-30}

log() {
    local line
    line="$(date -Is) $*"
    echo "$line" >&2
    [ -d /var/log ] && echo "$line" >>"$LOG" 2>/dev/null
}

step() {
    # Run one configfs step, log and fail loudly instead of dying silently.
    if ! "$@" 2>>"$LOG"; then
        log "FAILED: $*"
        return 1
    fi
}

up() {
    log "== up: begin =="
    modprobe libcomposite 2>>"$LOG" || log "modprobe libcomposite returned $?"

    if [ ! -d /sys/kernel/config/usb_gadget ]; then
        log "configfs usb_gadget is missing (libcomposite not loaded) -- giving up"
        return 1
    fi

    # The gadget can only be bound once the UDC shows up. On this board the dwc3
    # device is probed asynchronously, and a bind attempt on an empty
    # /sys/class/udc writes an empty string and silently leaves the port dead.
    local udc="" i=0
    while [ -z "$udc" ]; do
        udc=$(ls /sys/class/udc 2>/dev/null | head -1)
        [ -n "$udc" ] && break
        i=$((i + 1))
        if [ "$i" -gt "$UDC_WAIT" ]; then
            log "no UDC after ${UDC_WAIT}s -- giving up"
            return 1
        fi
        sleep 1
    done
    log "udc: $udc"

    [ -d "$GADGET" ] || mkdir -p "$GADGET" || { log "cannot create $GADGET"; return 1; }

    echo 0x1d6b >"$GADGET/idVendor" || { log "idVendor write failed"; return 1; }
    echo 0x0104 >"$GADGET/idProduct" || { log "idProduct write failed"; return 1; }
    echo 0x0200 >"$GADGET/bcdUSB"

    mkdir -p "$GADGET/strings/0x409"
    echo armada >"$GADGET/strings/0x409/manufacturer"
    echo armada >"$GADGET/strings/0x409/product"
    echo CHARISGADGET >"$GADGET/strings/0x409/serialnumber"

    mkdir -p "$GADGET/configs/c.1/strings/0x409"
    echo armada >"$GADGET/configs/c.1/strings/0x409/configuration"
    echo 500 >"$GADGET/configs/c.1/MaxPower"

    mkdir -p "$GADGET/functions/ncm.usb0" || { log "cannot create ncm function"; return 1; }
    ln -sf "$GADGET/functions/ncm.usb0" "$GADGET/configs/c.1/" || { log "cannot link ncm function"; return 1; }

    if ! echo "$udc" >"$GADGET/UDC" 2>>"$LOG"; then
        log "binding to $udc failed -- gadget is NOT visible to the host"
        return 1
    fi
    log "bound to $udc"

    # usb0 is deliberately left unmanaged by NetworkManager (conf.d drop-in), so
    # these addresses survive. Host side: static 10.42.0.2/24.
    ip link set usb0 mtu 1500 2>>"$LOG" || log "mtu set failed"
    ip link set usb0 up 2>>"$LOG" || log "link up failed"
    ip addr replace 10.42.0.1/24 dev usb0 2>>"$LOG" || log "ipv4 address failed"
    ip -6 addr replace fe80::1/64 dev usb0 2>>"$LOG" || log "ipv6 address failed"

    log "up: done $(ip -brief addr show usb0 2>&1 | tr '\n' ' ')"
    return 0
}

down() {
    [ -d "$GADGET" ] || return 0
    log "down: unbinding"
    echo "" >"$GADGET/UDC" 2>/dev/null || true
    rm -f "$GADGET/configs/c.1/ncm.usb0"
    rmdir "$GADGET/functions/ncm.usb0" \
          "$GADGET/configs/c.1/strings/0x409" "$GADGET/configs/c.1" \
          "$GADGET/strings/0x409" "$GADGET" 2>/dev/null || true
}

case "${1:-}" in
    up) up ;;
    down) down ;;
    *) echo "usage: $0 up|down" >&2; exit 1 ;;
esac
GADGET
chmod 0755 /usr/libexec/armada-usbgadget

cat > /usr/lib/systemd/system/armada-usbgadget.service <<'UNIT'
[Unit]
Description=USB Ethernet gadget (pure NCM) for host access
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/libexec/armada-usbgadget up
ExecStop=/usr/libexec/armada-usbgadget down

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable armada-usbgadget.service

# Retry drop-in (synced from payload/armada-usbgadget-retry.conf): the dwc3 UDC
# probes asynchronously; a one-shot bind before /sys/class/udc is populated
# leaves the port dead for the whole session.
mkdir -p /usr/lib/systemd/system/armada-usbgadget.service.d
cat > /usr/lib/systemd/system/armada-usbgadget.service.d/armada-usbgadget-retry.conf <<'RETRY'
# The dwc3 UDC is probed asynchronously and the gadget bind is a one-shot
# window: if this unit runs before /sys/class/udc is populated the port stays
# dead for the whole session. The script waits for a UDC itself; retrying the
# unit covers the rest (module load races, a failed bind, etc).
[Unit]
After=systemd-modules-load.service

[Service]
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=120
StartLimitBurst=12
RETRY

# NM must not manage usb0 (synced from payload/99-alioth-usb-unmanaged.conf,
# device-validated path): the gadget script alone owns the address; NM shared
# mode needs dnsmasq and leaves usb0 down when activation fails.
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/99-alioth-usb-unmanaged.conf <<'NMCONF'
# alioth: the NCM gadget interface is configured by /usr/libexec/armada-usbgadget,
# not by NetworkManager. NM's shared mode needs dnsmasq and, when activation
# fails, leaves usb0 down -- indistinguishable from a dead gadget. Keeping the
# interface unmanaged makes the link deterministic: the gadget script alone owns
# the address, so SSH works on the very first boot with no DHCP anywhere.
[keyfile]
unmanaged-devices=interface-name:usb0
NMCONF

# ---------------------------------------------------------------------------
# 2. Steam launcher with an offline fallback
# ---------------------------------------------------------------------------
cat > /usr/bin/steam-now <<'STEAM'
#!/bin/bash
# Launch Steam big picture; probe the Steam CDN briefly and fall back to
# offline mode so a blocked or slow network never strands the user at a
# download screen. The client tree is fully pre-staged in the image.
set -u
if curl -m 3 -sI https://store.steampowered.com >/dev/null 2>&1; then
    exec /usr/bin/steam -steamdeck "$@"
else
    logger -t steam-now "Steam CDN unreachable; starting offline"
    exec /usr/bin/steam -steamdeck -offline "$@"
fi
STEAM
chmod 0755 /usr/bin/steam-now

# ---------------------------------------------------------------------------
# 3. Touchscreen mask helper (NOT auto-enabled)
#
# The FT8756 panel has an intermittent hardware fault (ghost touches). When it
# misbehaves, mask it in software without touching the DTS:
#   alioth-touch-mask off   -> unbind spi4.0 (driver releases the input dev)
#   alioth-touch-mask on    -> rebind spi4.0
# A libinput/udev ignore rule is an alternative for Wayland sessions.
# ---------------------------------------------------------------------------
cat > /usr/bin/alioth-touch-mask <<'MASK'
#!/bin/bash
set -e
DRV=/sys/bus/spi/drivers/ft8756-spi
case "${1:-}" in
  off) echo spi4.0 > "$DRV/unbind" 2>/dev/null || true; echo "FT8756 touch masked (spi4.0 unbound)" ;;
  on)  echo spi4.0 > "$DRV/bind"   2>/dev/null || true; echo "FT8756 touch restored (spi4.0 bound)" ;;
  *)   echo "usage: alioth-touch-mask off|on" >&2; exit 1 ;;
esac
MASK
chmod 0755 /usr/bin/alioth-touch-mask

# ---------------------------------------------------------------------------
# 4. SELinux
#
# The alioth variant boots from a baked Android boot image with no ESP and no
# bootupd, and the image carries container-style labels. Relaxing to
# permissive keeps the phone functional while still logging every denial.
# ---------------------------------------------------------------------------
if [ -f /etc/selinux/config ]; then
    sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
    grep '^SELINUX=' /etc/selinux/config || true
fi

# ---------------------------------------------------------------------------
# 5. Game Mode rotation: output *and* touch input, user-switchable
#
# The panel is native portrait 1080x2400 while Game Mode is landscape.
# gamescope-session-plus builds --force-orientation from $ORIENTATION, and that
# variable is set per device in /usr/share/gamescope-session-plus/device-quirks,
# keyed on SYS_ID. On ARM there is no DMI, so SYS_ID is the DT model and on this
# board it reads "Qualcomm Technologies, Inc. xiaomi alioth" -- without an entry
# nothing sets ORIENTATION and the session stays portrait.
#
# gamescope 3.17 rotates the scanout but NOT touch input, so the FT8756 (which
# reports portrait coordinates) needs an explicit libinput calibration matrix.
# Measured on device: visual top-left -> raw (60,2345), visual bottom-right ->
# raw (985,100), therefore visual_x = 2400 - raw_y and visual_y = raw_x.
#
# Two orientations matter here: `left` is the default, `right` is its 180
# rotation. A telescopic controller is gripped the other way round, so the user
# needs to flip without rebuilding anything. gamescope only reads the flag at
# session start, hence the state file + `alioth-rotate` helper below.
# ---------------------------------------------------------------------------
install -d /etc/alioth
[ -s /etc/alioth/screen-orientation ] || echo left > /etc/alioth/screen-orientation

cat >> /usr/share/gamescope-session-plus/device-quirks <<'QUIRK'

# Xiaomi Redmi K40 / POCO F3 (alioth, SM8250): portrait 1080x2400 AMOLED
# (120/90 Hz, no 60 Hz mode). Game Mode is landscape, so rotate the output.
#
# NOTE: the DT model string on this unit is "Xiaomi POCO F3" -- it does NOT
# contain "alioth", so matching on that name alone silently never fired and
# ORIENTATION stayed unset (portrait session, broken touch mapping). Match the
# model we actually have, and keep "alioth" for board builds that report it.
#
# The direction is user-switchable (see alioth-rotate); anything other than a
# recognised value falls back to `left`.
if [[ "$SYS_ID" == *"POCO F3"* || "$SYS_ID" == *alioth* ]]; then
  PANEL_TYPE=internal
  ORIENTATION=$(cat /etc/alioth/screen-orientation 2>/dev/null || echo left)
  case "$ORIENTATION" in
    left|right|upsidedown|normal) ;;
    *) ORIENTATION=left ;;
  esac

  # Refresh-rate note (2026-11-15): this panel has NO 60 Hz mode - native
  # modes are 120/90 Hz only. Do NOT set CUSTOM_REFRESH_RATES=60 here: it
  # makes gamescope synthesize a phantom 1080x2400@59Hz mode the panel cannot
  # actually run, which produces whole-screen flicker plus a storm of
  # dsi_err_worker / dpu frame_done_timeout errors that also starve audio.
  # If a lower scan rate is ever needed for heat, 90 Hz is the only safe one.
fi
QUIRK

# Touch matrix is produced at udev time from the target SESSION type, not by
# rewriting rule files. /etc/alioth/touch-mode is persistent; a missing file
# means "game", which matches the autologin target on a cold boot.
cat > /usr/libexec/alioth-touch-matrix <<'MATRIX'
#!/bin/bash
# Emit the libinput calibration matrix for the session that is running.
#
# The matrix depends on WHO rotates the output:
#   Game Mode : gamescope rotates the composited output but does NOT transform
#               input, so libinput must rotate -> 0 -1 1 / 1 0 0 (mirrored when
#               the grip is flipped).
#   Desktop   : KWin rotates the output AND transforms input, so libinput must
#               stay neutral -> identity.
#
# /etc/alioth/touch-mode is written by session-control, the single entry point
# for every mode change (QAM button, boot hotkey, steamosctl). A missing file
# defaults to `game` so a cold boot can never come up with identity while
# gamescope presents a rotated output.
#
# Raw touch coords are portrait 1080x2400 (native panel orientation).
#
#   normal     : x' = x_raw,     y' = y_raw        (portrait, native)
#   left       : x' = 1 - y_raw, y' = x_raw        (landscape, USB-C on the left)
#   right      : x' = y_raw,     y' = 1 - x_raw    (landscape + 180 deg)
#   upsidedown : x' = 1 - x_raw, y' = 1 - y_raw    (portrait + 180 deg)
#
# `left` and `right` were both confirmed against the screen on 2026-11-15.
# `upsidedown` is not a toggle target (it renders portrait), but its matrix is
# kept correct in case it is selected explicitly.
case "$(cat /etc/alioth/touch-mode 2>/dev/null)" in
  desktop|mobile)
    # KWin already rotates input; libinput must not rotate it a second time.
    echo "LIBINPUT_CALIBRATION_MATRIX=1 0 0 0 1 0 0 0 1"
    ;;
  *)
    case "$(cat /etc/alioth/screen-orientation 2>/dev/null)" in
      right)      echo "LIBINPUT_CALIBRATION_MATRIX=0 1 0 -1 0 1 0 0 1" ;;
      upsidedown) echo "LIBINPUT_CALIBRATION_MATRIX=-1 0 1 0 -1 1 0 0 1" ;;
      normal)     echo "LIBINPUT_CALIBRATION_MATRIX=1 0 0 0 1 0 0 0 1" ;;
      *)          echo "LIBINPUT_CALIBRATION_MATRIX=0 -1 1 1 0 0 0 0 1" ;;
    esac
    ;;
esac
MATRIX
chmod 0755 /usr/libexec/alioth-touch-matrix

cat > /usr/lib/udev/rules.d/61-alioth-touch-rotation.rules <<'TOUCH'
# alioth: the FT8756 reports portrait coordinates while Game Mode presents a
# rotated 2400x1080 output that gamescope does not apply to touch input. The
# matrix is produced by alioth-touch-matrix from the saved orientation.
SUBSYSTEM=="input", ATTRS{name}=="Focaltech FT8756 Touchscreen", IMPORT{program}="/usr/libexec/alioth-touch-matrix"
TOUCH

# ---------------------------------------------------------------------------
# 6. ADSP remoteproc
#
# adsp.mbn lives in /usr/lib/firmware, but the remoteproc is probed ~4 s into
# boot, before the root is mounted: the firmware request fails with -ENOENT,
# the DSP stays offline and the SM8250 sound card never finishes probing
# ("deferred probe pending: MultiMedia1: error getting cpu dai name").
# Starting it again once local-fs is up brings the DSP up and the card follows.
# ---------------------------------------------------------------------------
cat > /usr/libexec/armada-adsp-start <<'ADSP'
#!/bin/bash
set -u
found=0
for rp in /sys/class/remoteproc/remoteproc*; do
    [ -e "$rp" ] || continue
    name=$(cat "$rp/name" 2>/dev/null || true)
    case "$name" in
        *adsp*) ;;
        *) continue ;;
    esac
    found=1
    state=$(cat "$rp/state" 2>/dev/null || true)
    if [ "$state" = "running" ]; then
        echo "adsp already running ($rp)"
        continue
    fi
    echo "starting adsp: $rp state=$state"
    echo start >"$rp/state" || echo "failed to start $rp" >&2
done
[ "$found" -eq 1 ] || { echo "no adsp remoteproc found" >&2; exit 1; }
ADSP
chmod 0755 /usr/libexec/armada-adsp-start

cat > /usr/lib/systemd/system/armada-adsp-start.service <<'ADSPUNIT'
[Unit]
Description=Start ADSP remoteproc (firmware lives on the root filesystem)
After=local-fs.target
Before=sound.target
Wants=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/libexec/armada-adsp-start

[Install]
WantedBy=multi-user.target
ADSPUNIT
systemctl enable armada-adsp-start.service

# ---------------------------------------------------------------------------
# 7. Speaker route (TERTIARY MI2S, main TLMM)
#
# The speakers hang off TERT_MI2S_RX on the main TLMM mi2s2 pins
# (gpio133 sck / gpio135 ws / gpio137 data1, pinctrl is applied by the sound
# node itself). The LPASS LPI pinctrl path used by the earlier QUATERNARY TDM
# recipe is now disabled in the device tree, so the reprobe dance it needed is
# gone. What still has to happen once per boot is opening the MultiMedia1 ->
# TERT_MI2S_RX mixer route and the cs35l41 DSP/volume controls; the UCM2
# profile in system_files/usr/share/alsa/ucm2 does not run outside a session.
#
# Note: cs35l41 PLL retargeting to the real 1.536 MHz BCLK is done by
# sm8250.c at stream start (the protection firmware defaults to 12.288 MHz).
# Do not try to fix it from userspace.
# ---------------------------------------------------------------------------
cat > /usr/libexec/alioth-amp-enable <<'AMPEN'
#!/usr/bin/env python3
"""Amp bring-up v5 -- cold-boot safe.

Differences from v4, both driven by what the device actually did:

  1. The protection DSP mailbox is often not ready in the first seconds of a
     boot (ack=False), which silently left the amp un-enabled. v5 retries the
     SPK_OUT_ENABLE command a few times and reports how many attempts it took.
     The retry is intentionally short because this script also runs from
     armada-speaker-route, which is ordered Before=wireplumber.service; the
     seconds-scale retry lives in alioth-audio-boot-fix.

  2. v4 only ran the full enable sequence when one of the four "decision"
     registers differed from the snapshot. If a stream had already started
     before this script ran, ASP was already 0x10000 and the enable sequence
     (GLOBAL_EN / DAC source / gain / unmute / ramp) was skipped entirely.
     v5 always runs it; the sequence is idempotent.

Measured correction (2026-11-15): PWR_CTRL3 bit24 and the PLL enable bit are
NOT required for sound. Audible beeps were confirmed with
ASP=0x10000, PWR3=0x01000010, PLL=0x370, GLOBAL_EN=1. They are still written
when absent, because they match the archived working snapshot, but the driver
rewrites them on every stream start anyway.
"""
import ctypes
import fcntl
import os
import struct
import sys
import time

I2C_SLAVE_FORCE = 0x0706
I2C_RDWR = 0x0707
I2C_M_RD = 0x0001
RCV, LCV = 0x40, 0x41

ASP_ENABLES, PWR3, PLL, PWR1 = 0x4800, 0x201C, 0x2C04, 0x2014
WANT = {ASP_ENABLES: 0x10000, PWR3: 0x01100010, PLL: 0x010370, PWR1: 0x1}

# Keep this short: armada-speaker-route runs Before=wireplumber.service, so a
# long mailbox retry here would hold the whole audio session back at boot.
# alioth-audio-boot-fix does the outer retry with seconds between attempts.
MAILBOX_TRIES = 3
MAILBOX_WAIT_S = 0.25


class i2c_msg(ctypes.Structure):
    _fields_ = [("addr", ctypes.c_uint16), ("flags", ctypes.c_uint16),
                ("len", ctypes.c_uint16), ("buf", ctypes.c_void_p)]


class i2c_rdwr(ctypes.Structure):
    _fields_ = [("msgs", ctypes.POINTER(i2c_msg)), ("nmsgs", ctypes.c_uint32)]


def io_r(addr, reg):
    fd = os.open("/dev/i2c-3", os.O_RDWR)
    try:
        fcntl.ioctl(fd, I2C_SLAVE_FORCE, addr)
        wb = ctypes.create_string_buffer(struct.pack(">I", reg), 4)
        rb = ctypes.create_string_buffer(4)
        a = (i2c_msg * 2)(
            i2c_msg(addr, 0, 4, ctypes.addressof(wb)),
            i2c_msg(addr, I2C_M_RD, 4, ctypes.addressof(rb)))
        fcntl.ioctl(fd, I2C_RDWR, i2c_rdwr(a, 2))
        return struct.unpack(">I", rb.raw)[0]
    finally:
        os.close(fd)


def io_w(addr, reg, val):
    fd = os.open("/dev/i2c-3", os.O_RDWR)
    try:
        fcntl.ioctl(fd, I2C_SLAVE_FORCE, addr)
        wv = ctypes.create_string_buffer(struct.pack(">II", reg, val), 8)
        a = (i2c_msg * 1)(i2c_msg(addr, 0, 8, ctypes.addressof(wv)))
        fcntl.ioctl(fd, I2C_RDWR, i2c_rdwr(a, 1))
    finally:
        os.close(fd)


def io_upd(addr, reg, mask, val):
    io_w(addr, reg, (io_r(addr, reg) & ~mask) | val)


def mailbox_once(a, cmd, wait_s):
    io_w(a, 0x10814, 1 << 20)
    io_w(a, 0x10014, 1 << 21)
    io_upd(a, 0x10914, 1 << 20, 0)
    io_w(a, 0x13020, cmd)
    ack = False
    end = time.monotonic() + wait_s
    while time.monotonic() < end:
        if io_r(a, 0x10014) & (1 << 21):
            ack = True
            break
        time.sleep(0.001)
    io_w(a, 0x10014, 1 << 21)
    io_upd(a, 0x10914, 1 << 20, 1 << 20)
    return ack, io_r(a, 0x13004)


def mailbox(a, cmd, wait_s=MAILBOX_WAIT_S):
    """Retry until the DSP acknowledges; returns (ack, state, attempts)."""
    ack, state = False, 0
    for n in range(1, MAILBOX_TRIES + 1):
        ack, state = mailbox_once(a, cmd, wait_s)
        if ack:
            return ack, state, n
    return ack, state, MAILBOX_TRIES


def vol_reg(att):
    """CS35L41: code = 2048 - attenuation, register = code<<3 | 4."""
    return (((2048 - att) & 0x7ff) << 3) | 4


def fix_registers(a):
    """Write only the values that differ from the working snapshot."""
    changed = []
    if io_r(a, ASP_ENABLES) != WANT[ASP_ENABLES]:
        io_upd(a, ASP_ENABLES, 0x30000, 0x10000)
        changed.append("ASP")
    if io_r(a, PWR3) != WANT[PWR3]:
        io_w(a, PWR3, WANT[PWR3])          # full value incl. bit24
        changed.append("PWR3")
    if io_r(a, PLL) != WANT[PLL]:
        # hakios PLL sequence, ending at 0x10370
        io_upd(a, PLL, 0x800, 0x800)
        io_upd(a, PLL, 0x7e0, 0x1b << 5)
        io_upd(a, PLL, 0x10, 0)
        io_upd(a, PLL, 7, 0)
        io_upd(a, PLL, 0x800, 0)
        io_upd(a, PLL, 0x10010, 0x10010)
        changed.append("PLL")
    if io_r(a, PWR1) != WANT[PWR1]:
        io_upd(a, PWR1, 1, 1)
        changed.append("GLOBAL_EN")
    return changed


def enable_amp(a, target_att=24):
    """Full output enable: assumes the four decision registers are correct.

    The volume ramp is deliberately NOT run when the DSP never acknowledges:
    with a cold boot that would otherwise be repeated on every retry and be
    audible as a train of chimes. Staying muted until the amp is really up is
    both quieter and a truthful signal that the enable failed.
    """
    io_upd(a, 0x2024, 0x10, 0x10)          # analog mute
    io_w(a, 0x6000, 0x2004)                # digital mute
    io_w(a, 0x4C00, 0x32)                  # DAC from protection DSP
    io_upd(a, 0x6C04, 0x3e0, 18 << 5)      # amp gain 18
    io_w(a, 0x10010, 0xFFFFFFFF)           # clear sticky
    io_w(a, 0x40, 0x55); io_w(a, 0x40, 0xAA)
    io_w(a, 0x2084, 0x002F1AA0)
    io_w(a, 0x40, 0xCC); io_w(a, 0x40, 0x33)
    io_upd(a, PWR1, 1, 1)
    time.sleep(0.002)
    ack, state, attempts = mailbox(a, 2)   # SPK_OUT_ENABLE
    if not ack:
        return ack, state, attempts
    att = 320
    while att > target_att:
        att = max(target_att, att - 48)
        io_upd(a, 0x6000, 0x3fff, vol_reg(att))
        time.sleep(0.1)
    io_upd(a, 0x2024, 0x10, 0)             # unmute
    return ack, state, attempts


def main():
    # -3 dB. Was 96 (-12 dB), which forced the user to run the sink at
    # 100% to hear anything; PipeWire's cubic curve adds another ~18 dB
    # of attenuation at 50%. att must stay >= 1: att=0 wraps to code 0,
    # which is the CS35L41 mute code (verified on the device).
    target = 24
    for arg in sys.argv[1:]:
        if arg.isdigit():
            target = min(int(arg), 816)

    failed = 0
    for name, a in (("RCV", RCV), ("LCV", LCV)):
        try:
            changed = fix_registers(a)
            ack, state, attempts = enable_amp(a, target)
            line = "alioth-amp-enable: %s" % name
            line += " regs=%s" % ("/".join(changed) if changed else "ok")
            line += " | mbox=%s after %d try" % (ack, attempts)
            line += " state=%d" % state
            if not ack:
                failed += 1
            line += " | ASP=%#x PWR3=%#x PLL=%#x PWR1=%#x vol=%#x" % (
                io_r(a, ASP_ENABLES), io_r(a, PWR3), io_r(a, PLL),
                io_r(a, PWR1), io_r(a, 0x6000))
            print(line, flush=True)
        except OSError as e:
            print("alioth-amp-enable: %s I2C error: %s" % (name, e),
                  file=sys.stderr, flush=True)
            sys.exit(1)

    if failed:
        print("alioth-amp-enable: %d amp(s) did not acknowledge" % failed,
              file=sys.stderr, flush=True)
        sys.exit(2)


if __name__ == "__main__":
    main()
AMPEN
chmod 0755 /usr/libexec/alioth-amp-enable

# Runtime PM: the driver's 3 s autosuspend -> failed wake leaves the HALO DSP
# frozen (silent speakers). Pin both amps awake at bind time.
cat > /usr/lib/udev/rules.d/62-alioth-amp-pm.rules <<'AMPPM'
# alioth: the CS35L41 amps' runtime suspend never wakes cleanly on this
# firmware (cs35l41_exit_hibernate times out; the HALO DSP ends up frozen
# and the speakers stay silent). Keep them awake.
ACTION=="bind", DRIVER=="cs35l41", TEST=="power/control", ATTR{power/control}="on"
AMPPM

cat > /usr/libexec/armada-speaker-route <<'SPKROUTE'
#!/bin/bash
set -u
for i in $(seq 1 20); do
    [ -e /dev/snd/controlC0 ] && break
    sleep 1
done
if [ ! -e /dev/snd/controlC0 ]; then
    echo "sound card did not appear" >&2
    exit 1
fi
# Frontend -> backend route.
amixer -c 0 cset "name=TERT_MI2S_RX Audio Mixer MultiMedia1" 1 >/dev/null 2>&1 || true
# Protection DSP + DAC source.
for n in "LCV DSP1 Preload Switch" "RCV DSP1 Preload Switch"; do
    amixer -c 0 cset "name=$n" 1 >/dev/null 2>&1 || true
done
for n in "LCV DSP RX1 Source" "RCV DSP RX1 Source"; do
    amixer -c 0 cset "name=$n" ASPRX1 >/dev/null 2>&1 || true
done
for n in "LCV PCM Source" "RCV PCM Source"; do
    amixer -c 0 cset "name=$n" DSP >/dev/null 2>&1 || true
done
# 0 dB digital (SOC_SINGLE_SX_TLV: 816 -> code 2047; 913 wraps to mute) and
# maximum analog gain. PipeWire applies the user-facing level on top.
for n in "LCV Digital PCM Volume" "RCV Digital PCM Volume"; do
    amixer -c 0 cset "name=$n" 816 >/dev/null 2>&1 || true
done
for n in "LCV Analog PCM Volume" "RCV Analog PCM Volume"; do
    amixer -c 0 cset "name=$n" 20 >/dev/null 2>&1 || true
done
# Hardware noise gate fights quiet material; the firmware protection DSP is
# what should be limiting, not the fixed gate.
for n in "LCV HW Noise Gate Enable" "RCV HW Noise Gate Enable"; do
    amixer -c 0 cset "name=$n" 0 >/dev/null 2>&1 || true
done
echo "speaker route opened"

# Amp output enable (2026-11-15): the kernel's runtime-PM hibernate path never
# wakes this firmware (cs35l41_exit_hibernate times out and the HALO DSP stays
# frozen -- every register reads fine, nothing is audible). Walk each amp
# through GLOBAL_EN + mailbox SPK_OUT_ENABLE + a volume ramp once the route is
# open. Idempotent. Not fatal: at boot the protection DSP is still
# loading and the mailbox will not answer yet; alioth-audio-boot-fix
# retries until it does.
/usr/libexec/alioth-amp-enable || true
SPKROUTE
chmod 0755 /usr/libexec/armada-speaker-route

cat > /usr/lib/systemd/system/armada-speaker-route.service <<'SPKROUTEUNIT'
[Unit]
Description=Open the alioth TERT MI2S speaker route
After=armada-adsp-start.service sound.target
Wants=armada-adsp-start.service
Before=wireplumber.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/libexec/armada-speaker-route

[Install]
WantedBy=multi-user.target
SPKROUTEUNIT
systemctl enable armada-speaker-route.service

# ---------------------------------------------------------------------------
# 8. UCM2 profile
#
# The upstream sm8250 UCM still describes the QUATERNARY TDM card, which this
# device tree no longer uses. Ship the TERT MI2S profile so an ACP-based
# consumer picks the right mixer names instead of failing on stale ones.
#
# TWO things are required, both learned the hard way (2026-11-15, on a device
# whose WirePlumber showed "Active Profile: off" and only a Dummy Output):
#
#   a. the top-level card conf next to the verb file -- without it there is no
#      SectionUseCase to enumerate;
#   b. a symlink in ucm2/conf.d/sm8250/xiaomi-alioth.conf -- alsa-lib's lookup
#      for hw cards is ucm2/conf.d/<CardDriver>/<CardLongName>.conf (see
#      /usr/share/alsa/ucm2/ucm.conf) and it NEVER walks ucm2/Qualcomm/sm8250/.
#      CardDriver is "sm8250", CardLongName is "xiaomi-alioth". Every other
#      SM8250 handheld here (PocketMICRO2, AYN Thor Lite, RetroidPocket...) has
#      exactly such a link; missing it makes the profile unavailable.
# ---------------------------------------------------------------------------
UCMDIR=/usr/share/alsa/ucm2/Qualcomm/sm8250
mkdir -p "$UCMDIR"
cat > "$UCMDIR/Xiaomi-Alioth-HiFi.conf" <<'UCMHIFI'
# HiFi verb for Xiaomi alioth speakers.
#   MultiMedia1 -> TERT_MI2S_RX -> cs35l41 RCV/LCV (hw:${CardId},0)
# The amp protection firmware defaults its PLL to a 12.288 MHz reference; the
# ADSP drives TER_MI2S_IBIT at 1.536 MHz, so sm8250.c retargets the PLL at
# stream start. Do not add a PLL cset here.
SectionVerb {
	EnableSequence [
		cset "name='TERT_MI2S_RX Audio Mixer MultiMedia1' 1"
		cset "name='RCV DSP1 Preload Switch' 1"
		cset "name='LCV DSP1 Preload Switch' 1"
		cset "name='RCV DSP RX1 Source' 'ASPRX1'"
		cset "name='LCV DSP RX1 Source' 'ASPRX1'"
		cset "name='RCV PCM Source' DSP"
		cset "name='LCV PCM Source' DSP"
	]

	DisableSequence [
		cset "name='TERT_MI2S_RX Audio Mixer MultiMedia1' 0"
	]

	Value {
		TQ "HiFi"
	}
}

SectionDevice."Speaker" {
	Comment "Speaker Playback"

	EnableSequence [
		# SOC_SINGLE_SX_TLV: ctl = register code - 1231 (11-bit field).
		# 816 -> code 2047 (0 dB). 913 wraps to code 96 (mute).
		cset "name='RCV Digital PCM Volume' 816"
		cset "name='LCV Digital PCM Volume' 816"
		cset "name='RCV Analog PCM Volume' 20"
		cset "name='LCV Analog PCM Volume' 20"
	]

	Value {
		PlaybackPriority 100
		PlaybackPCM "hw:${CardId},0"
		PlaybackChannels 2
	}
}
UCMHIFI
UCMHIFI

cat > "$UCMDIR/Xiaomi-Alioth.conf" <<'UCMTOP'
Syntax 4

Comment "Xiaomi Redmi K40 / POCO F3 (alioth) speakers"

SectionUseCase."HiFi" {
	File "/Qualcomm/sm8250/Xiaomi-Alioth-HiFi.conf"
	Comment "Speakers"
}

Include.card-init.File "/lib/card-init.conf"
Include.ctl-remap.File "/lib/ctl-remap.conf"
UCMTOP

# The lookup entry alsa-lib actually uses (see the comment above). Without it
# the whole UCM2 set above is dead weight the library never reads.
install -d /usr/share/alsa/ucm2/conf.d/sm8250
ln -sfn ../../Qualcomm/sm8250/Xiaomi-Alioth.conf \
    /usr/share/alsa/ucm2/conf.d/sm8250/xiaomi-alioth.conf

# ---------------------------------------------------------------------------
# 9. Never suspend: msm strands the panel
#
# drivers/gpu/drm/msm/msm_mdss.c:
#
#   mdss_pm_suspend(): if (pm_runtime_suspended(dev)) return 0;
#   mdss_pm_resume() : if (pm_runtime_suspended(dev)) return 0;
#
# Once the panel has runtime-suspended on idle, a system suspend skips the MDSS
# suspend -- and the resume therefore skips the MDSS resume. The DSI is never
# re-initialised, the screen stays black and the power key looks dead; the only
# way out is a long-press power-off.
#
# Until the DRM resume path is fixed, keep the system awake:
#   - idle never suspends
#   - a short power press does nothing (it used to suspend)
#   - a LONG power press still powers off, which is the escape hatch
#
# NOTE: /usr/lib/systemd/logind.conf.d/armada-handheld.conf ships
# HandlePowerKey=suspend; that is the file which must be overridden.
# ---------------------------------------------------------------------------
cat > /usr/lib/systemd/logind.conf.d/armada-handheld.conf <<'LOGIND'
# alioth: suspend on this board strands the panel (msm mdss_pm_resume returns
# early when the device is already runtime-suspended), leaving the screen black
# and the power key unresponsive. Keep the system awake.
[Login]
HandlePowerKey=ignore
HandlePowerKeyLongPress=poweroff
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
WallMessages=no
LOGIND

# ---------------------------------------------------------------------------
# 10. SDDM: do not relogin in a loop
#
# /etc/sddm.conf.d/armada.conf ships Relogin=true for the gamescope autologin
# session. The session already owns /dev/tty1, so every relogin attempt dies
# with
#
#   sddm-helper: Failed to take control of "/dev/tty1" ("root"):
#                Operation not permitted
#   sddm-helper: Session crashed (exit code 5)
#
# and Relogin=true makes SDDM retry immediately: measured 674 failures in 30 s
# (~22 per second). That pins every core, which starves the PipeWire thread and
# is audible as crackle when the screen comes on or right after boot.
#
# Keep the autologin, drop the retry.
# ---------------------------------------------------------------------------
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/99-alioth-no-relogin.conf <<'SDDMCONF'
# alioth: Relogin=true (from armada.conf) turns a failed tty1 takeover into an
# infinite retry storm (~22/s), starving the audio thread. Keep autologin,
# drop the retry.
[Autologin]
Relogin=false
SDDMCONF

# ---------------------------------------------------------------------------
# 11. Orientation: user-switchable, and a LB+RB gesture to flip it
#
# The panel is portrait 1080x2400 while Game Mode is landscape, so the scanout
# is rotated for the session. gamescope reads ORIENTATION only at session start,
# hence the direction lives in a state file and lands on the next session.
#
# Only two directions actually differ on this board:
#   left        landscape, the default grip (controller's USB plug on the left)
#   upsidedown  the same landscape flipped 180 degrees, for a reversed grip
# `right` is accepted for compatibility but gamescope 3.17 renders it exactly
# like `left` here (msm exports no panel_orientation), so it is not a toggle
# target. Touch input is NOT rotated by gamescope, so the calibration matrix has
# to follow the state file.
#
#   alioth-rotate [left|upsidedown|toggle] [-y]
#
# The LB+RB gesture is handled by armada-shoulder-rotate.service, which is
# deliberately inert while a Steam title is running (detected via Steam's
# launch reaper, `reaper SteamLaunch AppId=N`).
# ---------------------------------------------------------------------------
install -d /etc/alioth
[ -s /etc/alioth/screen-orientation ] || echo left > /etc/alioth/screen-orientation

cat > /usr/bin/alioth-rotate <<'ROTATE'
#!/bin/bash
# alioth-rotate [left|right|upsidedown|toggle] [-y]
#
# Landscape positions on this board (panel is native portrait 1080x2400):
#   left   - landscape, USB-C port on the LEFT (the default grip)
#   right  - landscape rotated 180 degrees (USB-C port on the RIGHT)
#   upsidedown - portrait, 180 degrees from native. NOT a landscape flip;
#                kept only for compatibility, never a toggle target.
#
# Measured on 2026-11-15: `right` renders as landscape + 180 deg and the touch
# matrix below tracks it. (The older note claiming "right renders identically
# to left" was wrong.)
#
# Touch calibration follows the state file; gamescope reads the orientation only
# at session start, so a change lands on the next session (-y restarts it).
set -u
STATE=/etc/alioth/screen-orientation
install -d /etc/alioth 2>/dev/null || true

want=toggle
do_restart=0
for a in "$@"; do
  case "$a" in
    left|right|upsidedown|normal|toggle) want="$a" ;;
    -y|--restart)                        do_restart=1 ;;
    -h|--help)
      echo "usage: alioth-rotate [left|right|upsidedown|toggle] [-y]"; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 1 ;;
  esac
done

cur=$(cat "$STATE" 2>/dev/null || echo left)
case "$cur" in left|right|upsidedown|normal) ;; *) cur=left ;; esac

if [ "$want" = toggle ]; then
  # Toggle between the two LANDSCAPE grips only.
  if [ "$cur" = right ]; then
    next=left
  else
    next=right
  fi
else
  next="$want"
fi

echo "$next" > "$STATE"
echo "orientation: $cur -> $next"

if [ -x /usr/libexec/alioth-touch-matrix ]; then
  udevadm trigger --subsystem-match=input --action=change 2>/dev/null || true
fi

if [ "$do_restart" -eq 1 ]; then
  echo "restarting the session (sddm)..."
  systemctl restart sddm 2>/dev/null || echo "restart the session manually" >&2
else
  echo "takes effect on the next session start (use -y to restart now)"
fi
ROTATE
chmod 0755 /usr/bin/alioth-rotate

cat > /usr/libexec/alioth-shoulder-rotate <<'DAEMON_EOF'
#!/usr/bin/env python3
"""
LB + RB toggles the Game Mode orientation -- but only in the Steam UI and on
the desktop. While a title is running the combo is inert, so it cannot fire
mid-game.

Design notes (all learned from failures on this device):

  * Device detection must use EVIOCGBIT, not `evtest --query`. The latter exits
    0 even for devices that do not declare the key at all (verified on the
    FT8756 touchscreen), which makes the touchscreen and the power key look
    like gamepads.

  * A gamepad is hot-plugged, so the set of devices must be refreshed. The
    previous version re-scanned every 10 s and *lept* the old descriptors
    (70 `(deleted)` fds after 14 minutes), which also meant `select()` kept
    waiting on stale nodes while a freshly plugged pad was ignored. This version
    closes what it no longer watches and re-scans on a timer plus on
    NETLINK_KOBJECT_UEVENT hotplug events.

  * Press window uses a small epsilon: monotonic() differences like
    10.15 - 10.00 come out as 0.15000000000000036, so an exact <= 0.15 test
    silently drops the "pressed together" case.

  * "A game is running" is detected by Steam's launch reaper
    (`reaper SteamLaunch AppId=N`), which exists only while a title is up.
"""
import glob
import os
import select
import struct
import subprocess
import sys
import time

EV_KEY = 1
KEY_LB = 0x136          # BTN_TL
KEY_RB = 0x137          # BTN_TR
PRESS_WINDOW_S = 0.15
EPS = 1e-6
DEBOUNCE_S = 12.0     # covers a session restart (~10 s)
RESCAN_INTERVAL_S = 5.0

STATE_FILE = "/etc/alioth/screen-orientation"
ROTATE = "/usr/bin/alioth-rotate"

NETLINK_KOBJECT_UEVENT = 15
NETLINK_ADD_MEMBERSHIP = 1


def log(msg):
    print("[shoulder-rotate] %s" % msg, flush=True)


def game_is_running():
    """True while a Steam title is up."""
    try:
        out = subprocess.run(["pgrep", "-f", "reaper SteamLaunch AppId="],
                             capture_output=True, text=True, timeout=2)
        return bool(out.stdout.strip())
    except Exception:
        return False


def device_name(path):
    try:
        with open("/sys/class/input/%s/device/name" % os.path.basename(path)) as f:
            return f.read().strip()
    except Exception:
        return "?"


def _eviocgbit(ev, length):
    # _IOC(_IOC_READ, 'E', 0x20 + ev, length); _IOC_READ == 2
    return (2 << 30) | (length << 16) | (ord("E") << 8) | (0x20 + ev)


def has_shoulders(path):
    """Does this evdev node declare BTN_TL *and* BTN_TR?"""
    import fcntl
    try:
        fd = os.open(path, os.O_RDONLY)
    except Exception:
        return False
    try:
        buf = bytearray(96)              # 768 bits >= KEY_MAX (0x2ff)
        fcntl.ioctl(fd, _eviocgbit(1, 96), buf)   # 1 == EV_KEY
        bits = set(i for i in range(96 * 8) if buf[i // 8] & (1 << (i % 8)))
        return KEY_LB in bits and KEY_RB in bits
    except Exception:
        return False
    finally:
        try:
            os.close(fd)
        except Exception:
            pass


def open_uevent():
    """Netlink socket for device hotplug notifications."""
    try:
        import socket
        s = socket.socket(socket.AF_NETLINK, socket.SOCK_DGRAM,
                          NETLINK_KOBJECT_UEVENT)
        s.setsockopt(270, NETLINK_ADD_MEMBERSHIP, 1)   # SOL_NETLINK
        s.bind(("", 1))
        s.setblocking(False)
        return s
    except Exception:
        return None


def close_fd(fd):
    try:
        os.close(fd)
    except Exception:
        pass


VIRTUAL_NAMES = (
    "Microsoft X-Box 360 pad 0",   # inputplumber's clone of a real pad
    "Microsoft Xbox One pad 0",
    "Microsoft Xbox Series pad 0",
)


def is_virtual_clone(path):
    """Does this evdev node live under /devices/virtual/?

    inputplumber mirrors a physical pad into a second, virtual node. Watching
    both makes every press arrive twice, which looks like the gesture firing on
    its own. But a Bluetooth pad is *also* virtual (uhid), so this alone must
    not decide what to ignore -- see the preference rule in rescan().
    """
    try:
        real = os.path.realpath("/sys/class/input/%s" % os.path.basename(path))
        return "/devices/virtual/" in real
    except Exception:
        return False


def rescan(watched):
    """Refresh the watched set.

    Only opens new nodes and closes ones that disappeared -- it must NOT
    reopen everything each time (that churns descriptors and, in the earlier
    version, leaked them).
    """
    all_with_shoulders = [
        p for p in glob.glob("/dev/input/event*") if has_shoulders(p)
    ]
    # Prefer physical devices so inputplumber's virtual clone (which mirrors the
    # same physical pad and would double every press) is not watched alongside
    # it. If *only* virtual devices report shoulders -- a Bluetooth pad lives
    # under /devices/virtual/ via uhid -- fall back to those, otherwise a BT
    # controller would never be seen.
    physical = [p for p in all_with_shoulders if not is_virtual_clone(p)]
    candidates = set(physical) if physical else set(all_with_shoulders)

    old_paths = set(watched.values())
    if candidates == old_paths:
        return watched                      # nothing changed

    # Close nodes we no longer want.
    for fd, path in list(watched.items()):
        if path not in candidates:
            close_fd(fd)
            watched.pop(fd, None)
            log("stopped watching %s" % path)

    # Open nodes we did not have.
    have = set(watched.values())
    for path in candidates - have:
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
            watched[fd] = path
            log("watching %s (%s)" % (path, device_name(path)))
        except Exception as e:
            log("cannot open %s: %s" % (path, e))

    if not watched:
        log("no gamepad with shoulders present")
    return watched


def rotate():
    """Flip the orientation and restart the session so it is actually visible.

    gamescope reads ORIENTATION only when the session starts, so writing the
    state file alone changes nothing on screen. Restarting sddm re-runs the
    autologin, which re-reads device-quirks and applies --force-orientation.

    This is only ever reached when no game is running (checked by the caller),
    so nothing is interrupted mid-play. The restart is detached so the watcher
    keeps running and does not block for the ~10 s the session takes to return.
    """
    if not os.access(ROTATE, os.X_OK):
        log("missing %s" % ROTATE)
        return
    try:
        # Write the state first, so even if the restart fails the next session
        # picks the new direction up anyway.
        out = subprocess.run([ROTATE, "toggle"], capture_output=True,
                             text=True, timeout=10)
        log("rotate: %s" % (out.stdout.strip() or out.stderr.strip()))
    except Exception as e:
        log("rotate failed: %s" % e)
        return

    try:
        subprocess.Popen(
            ["systemctl", "restart", "sddm"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True)
        log("session restart requested")
    except Exception as e:
        log("session restart failed: %s" % e)


def main():
    os.makedirs("/etc/alioth", exist_ok=True)
    if not os.path.exists(STATE_FILE):
        with open(STATE_FILE, "w") as f:
            f.write("left\n")

    log("v3 starting; window=%.0f ms, debounce=%.1f s"
        % (PRESS_WINDOW_S * 1000, DEBOUNCE_S))

    uevent = open_uevent()
    if uevent is None:
        log("no hotplug socket; falling back to polling")

    watched = rescan({})
    lb_at = rb_at = None
    last_fire = 0.0
    next_scan = time.monotonic() + RESCAN_INTERVAL_S

    while True:
        now = time.monotonic()

        if uevent is not None:
            try:
                while True:
                    data = uevent.recv(2048)
                    if not data:
                        break
                    # Only act on input-subsystem add/remove chatter.
                    text = data.decode("utf-8", "ignore")
                    if "/input/" in text or "input" in text:
                        watched = rescan(watched)
                        next_scan = time.monotonic() + RESCAN_INTERVAL_S
            except BlockingIOError:
                pass
            except Exception:
                pass

        if now >= next_scan:
            watched = rescan(watched)
            next_scan = time.monotonic() + RESCAN_INTERVAL_S

        watch_fds = list(watched.keys())
        if uevent is not None:
            watch_fds = watch_fds + [uevent.fileno()]

        if not watch_fds:
            time.sleep(0.5)
            continue

        try:
            ready, _, _ = select.select(watch_fds, [], [], 0.5)
        except Exception:
            for fd in list(watched):
                close_fd(fd)
            watched = {}
            continue

        for fd in ready:
            if uevent is not None and fd == uevent.fileno():
                continue                      # handled above
            try:
                data = os.read(fd, 24 * 64)
            except BlockingIOError:
                continue
            except Exception:
                # device vanished
                watched.pop(fd, None)
                close_fd(fd)
                continue

            for off in range(0, len(data) - 23, 24):
                _s, _u, etype, code, value = struct.unpack_from("<qqHHi", data, off)
                if etype != EV_KEY:
                    continue
                if code == KEY_LB:
                    lb_at = now if value else None
                elif code == KEY_RB:
                    rb_at = now if value else None

        if (lb_at is not None and rb_at is not None
                and abs(lb_at - rb_at) <= PRESS_WINDOW_S + EPS
                and (now - last_fire) > DEBOUNCE_S):
            lb_at = rb_at = None
            last_fire = now
            if game_is_running():
                log("LB+RB ignored (a game is running)")
                continue
            log("LB+RB -> toggling orientation")
            rotate()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
DAEMON_EOF
chmod 0755 /usr/libexec/alioth-shoulder-rotate

cat > /usr/lib/systemd/system/armada-shoulder-rotate.service <<'UNIT'
[Unit]
Description=alioth: LB+RB toggles screen orientation (UI/desktop only)
After=inputplumber.service
Wants=inputplumber.service

[Service]
Type=simple
ExecStart=/usr/libexec/alioth-shoulder-rotate
Restart=always
RestartSec=3
Nice=-5

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable armada-shoulder-rotate.service

# ---------------------------------------------------------------------------
# 12. steamos-manager: mask the daemon that cannot start on this kernel
#
# The kernel has no CONFIG_FTRACE, so /sys/kernel/tracing does not exist and
# cannot be created (sysfs rejects every mkdir with EPERM). steamos-manager's
# very first action is mkdirat("/sys/kernel/tracing") for its SLS log receiver,
# so it dies ~10 ms after exec. systemd restarts it every 2 min, and the
# user-level twin -- which can never see a root daemon on the bus -- times out
# and is SIGABRT'd every ~101 s, leaving a 1 MB core dump each time.
#
# Consequences while it ran: ~250 core dumps / 238 MB on a small partition,
# armada-powerd's 15 s watchdog missing its feed (dropping governor and fan
# policy), and a constant ~1 core of wasted CPU.
#
# It provides nothing here: Armada replaces platform.toml with an empty file
# precisely so no upstream interface registers. The real power controls live
# in armada-powerd (org.armada.Power), which implements the
# com.steampowered.SteamOSManager1.{PerformanceProfile,CpuScaling,
# GpuPerformanceLevel,LowPowerMode}1 interfaces on its own object path.
#
# Side effect: two oneshot units Require= it, so they stop running.
#   armada-steam-default-session   -- re-run once by hand below
#   steamos-manager-session-cleanup -- cosmetic only
# ---------------------------------------------------------------------------
systemctl mask steamos-manager 2>/dev/null || true

# The user-level twin, masked in the service user's own manager.
su - armada -c '
export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
systemctl --user mask steamos-manager 2>/dev/null || true
' || true

# Drop the wants symlinks so graphical-session.target cannot pull them back.
for f in /etc/systemd/user/graphical-session.target.wants/steamos-manager.service \
         /etc/systemd/user/graphical-session.target.wants/steamos-manager-session-cleanup.service \
         /etc/systemd/user/graphical-session.target.wants/armada-steam-default-session.service; do
    rm -f "$f"
done

# armada-powerd's watchdog: 15 s is too tight for this SoC under load. A missed
# kick SIGKILLs powerd, which drops governor and fan policy until it restarts.
install -d /etc/systemd/system/armada-powerd.service.d
cat > /etc/systemd/system/armada-powerd.service.d/60-watchdog.conf <<'WD'
# Widened from 15 s: too tight for this SoC under load (drops policy).
[Service]
WatchdogSec=60
WD

# Old cores from the loop, if this image was booted before the mask landed.
rm -f /var/lib/systemd/coredump/*steamos-manager* 2>/dev/null || true

# The default-desktop-session oneshot never runs now; do its one job by hand.
/usr/libexec/armada/steam-default-session 2>/dev/null || true

systemctl daemon-reload 2>/dev/null || true


# WirePlumber closes the ALSA sink after a few seconds idle. The CS35L41 amps
# and their DSP take longer than a short UI blip to come back, so blips were
# silent while a long stream (which outlives the resume) played fine. Every
# other SM8250 handheld on this image sets suspend-timeout-seconds to 0 for
# exactly this reason ("Keep the sinks open so the HPH PA does not pop").
install -d /usr/share/wireplumber/wireplumber.conf.d
cat > /usr/share/wireplumber/wireplumber.conf.d/52-alioth-suspend-timeout.conf <<'WPSUSP'
# Keep the sink open so the CS35L41 amps and their DSP stay running: a short
# UI blip would otherwise end before the ALSA device resumes from idle
# suspend, and the user hears nothing.
monitor.alsa.rules = [
  {
    matches = [
      {
        node.name = "~alsa_output.*"
        alsa.card_name = "xiaomi-alioth"
      }
    ]
    actions = {
      update-props = {
        session.suspend-timeout-seconds = 0
      }
    }
  }
]
WPSUSP


# ---------------------------------------------------------------------------
# The CS35L41 protection firmware writes ASP_ENABLES (0x4800) itself each time
# a stream starts: 0x30000, i.e. bit17 set, which keeps the ASP from taking
# the incoming audio. The pins toggle, every register reads healthy, and the
# speaker stays silent. Compensating from the kernel is not an option -- a
# write in trigger(START) made the card fail to probe entirely -- so this
# userspace watcher does it.
#
# v3 keeps the disturbance near zero: it polls the PCM status file at 5 Hz
# (no I2C), fixes the register only on the transition to RUNNING plus two
# re-checks within 600 ms, and never touches I2C while a stream keeps running.
# It must run as root: /dev/i2c-3 is root-only.
# ---------------------------------------------------------------------------
cat > /usr/libexec/alioth-sound-watch <<'SOUNDWATCH'
#!/usr/bin/env python3
"""Keep the CS35L41 ASP enabled without disturbing playback (v4).

v3 fixed ASP when the PCM went from idle to RUNNING. That misses two cases
seen on the device:

  * the PCM can sit at RUNNING permanently (WirePlumber is configured with
    session.suspend-timeout-seconds = 0), so there is only ever ONE edge and
    a later firmware rewrite of 0x4800 is never noticed;
  * the watcher can start while a stream is already RUNNING, which is only
    covered because v3 treats "last = False" at startup as an edge.

v4 keeps the same timing model and adds a slow read-only heartbeat:
  * 5 Hz file read of the PCM status (no I2C);
  * on a transition to RUNNING: check ASP immediately, re-check at
    0.15 / 0.45 / 0.6 s;
  * while a stream runs: read ASP once per second (I2C read only, no write)
    and fix it only if the firmware has rewritten it;
  * nothing playing: no I2C at all.

Reads are cheap; the audible stutter seen in v1/v2 came from writing to the
amp during steady playback, which this still never does.
"""
import ctypes
import fcntl
import os
import struct
import time

I2C_SLAVE_FORCE = 0x0706
I2C_RDWR = 0x0707
I2C_M_RD = 0x0001
RCV, LCV = 0x40, 0x41
ASP_ENABLES = 0x4800
WANTED = 0x10000
STATUS = "/proc/asound/card0/pcm0p/sub0/status"

# 20 Hz: the first stream start leaves ASP at 0x30000 for up to one poll,
# and that gap is the crackle heard on the first sound only. This is a
# file read; I2C reads/writes stay on their own slower schedules.
# Measured 2026-11-16: window 90 ms (0.2) -> 31 ms (0.05).
POLL_S = 0.05             # PCM status polling (file read only)
RECHECK_AFTER_S = (0.15, 0.45, 0.6)
HEARTBEAT_S = 1.0        # read-only drift check while a stream runs


class i2c_msg(ctypes.Structure):
    _fields_ = [("addr", ctypes.c_uint16), ("flags", ctypes.c_uint16),
                ("len", ctypes.c_uint16), ("buf", ctypes.c_void_p)]


class i2c_rdwr(ctypes.Structure):
    _fields_ = [("msgs", ctypes.POINTER(i2c_msg)), ("nmsgs", ctypes.c_uint32)]


def io_r(addr, reg):
    fd = os.open("/dev/i2c-3", os.O_RDWR)
    try:
        fcntl.ioctl(fd, I2C_SLAVE_FORCE, addr)
        wb = ctypes.create_string_buffer(struct.pack(">I", reg), 4)
        rb = ctypes.create_string_buffer(4)
        a = (i2c_msg * 2)(
            i2c_msg(addr, 0, 4, ctypes.addressof(wb)),
            i2c_msg(addr, I2C_M_RD, 4, ctypes.addressof(rb)))
        fcntl.ioctl(fd, I2C_RDWR, i2c_rdwr(a, 2))
        return struct.unpack(">I", rb.raw)[0]
    finally:
        os.close(fd)


def io_w(addr, reg, val):
    fd = os.open("/dev/i2c-3", os.O_RDWR)
    try:
        fcntl.ioctl(fd, I2C_SLAVE_FORCE, addr)
        wv = ctypes.create_string_buffer(struct.pack(">II", reg, val), 8)
        a = (i2c_msg * 1)(i2c_msg(addr, 0, 8, ctypes.addressof(wv)))
        fcntl.ioctl(fd, I2C_RDWR, i2c_rdwr(a, 1))
    finally:
        os.close(fd)


def stream_running():
    try:
        with open(STATUS) as f:
            for line in f:
                if line.startswith("state:"):
                    return line.split(":", 1)[1].strip() == "RUNNING"
    except OSError:
        return False
    return False


def ensure(verbose=True):
    """One pass: make sure both amps have ASP bit16 set / bit17 clear."""
    fixed = []
    for a in (RCV, LCV):
        try:
            if io_r(a, ASP_ENABLES) != WANTED:
                io_w(a, ASP_ENABLES, WANTED)
                fixed.append(a)
        except OSError as e:
            if verbose:
                print("alioth-sound-watch: i2c %#x: %s" % (a, e), flush=True)
    return fixed


def main():
    print("alioth-sound-watch: v4, low-disturbance mode", flush=True)
    last = False
    pending = []
    fixes = 0
    next_hb = 0.0
    while True:
        try:
            running = stream_running()
            now = time.monotonic()

            if running and not last:
                fixed = ensure()
                if fixed:
                    fixes += 1
                    print("alioth-sound-watch: stream started, fixed %s"
                          % ", ".join("%#x" % a for a in fixed), flush=True)
                else:
                    print("alioth-sound-watch: stream started (ASP already ok)",
                          flush=True)
                pending = [(now + d, i) for i, d in enumerate(RECHECK_AFTER_S)]
                next_hb = now + HEARTBEAT_S

            if not running and last:
                print("alioth-sound-watch: stream ended (fixes %d)" % fixes,
                      flush=True)
                pending = []

            if running and pending:
                due = [p for p in pending if p[0] <= now]
                if due:
                    fixed = ensure(verbose=False)
                    if fixed:
                        fixes += 1
                        print("alioth-sound-watch: re-fix %s"
                              % ", ".join("%#x" % a for a in fixed), flush=True)
                    pending = [p for p in pending if p[0] > now]

            # slow read-only heartbeat: catches a firmware rewrite that happens
            # without a PCM state transition
            if running and now >= next_hb:
                next_hb = now + HEARTBEAT_S
                fixed = ensure(verbose=False)
                if fixed:
                    fixes += 1
                    print("alioth-sound-watch: heartbeat re-fix %s"
                          % ", ".join("%#x" % a for a in fixed), flush=True)

            last = running
            time.sleep(POLL_S)
        except Exception as e:
            print("alioth-sound-watch: %s" % e, flush=True)
            time.sleep(1)


if __name__ == "__main__":
    main()
SOUNDWATCH
chmod 0755 /usr/libexec/alioth-sound-watch

cat > /usr/lib/systemd/system/alioth-sound-watch.service <<'SWUNIT'
[Unit]
Description=alioth: keep the CS35L41 ASP enabled for every audio stream
After=pipewire.service wireplumber.service armada-speaker-route.service
Wants=armada-speaker-route.service

[Service]
Type=simple
ExecStart=/usr/libexec/alioth-sound-watch
Restart=always
RestartSec=3
# Root is required for /dev/i2c-3.
Environment=XDG_RUNTIME_DIR=/run/user/1000

[Install]
WantedBy=multi-user.target
SWUNIT
systemctl enable alioth-sound-watch.service


echo "==> steamos-manager masked; powerd watchdog widened to 60 s"


# ---------------------------------------------------------------------------
# 7b. Cold-boot audio self-healing
#
# armada-speaker-route runs early, while the protection DSP is still loading.
# Its amp-enable call therefore gets ack=False and the amps never leave their
# power-on state -- that was the actual "cold boot comes up silent" bug.
#
# This pair records the boot state and then retries the bring-up until the
# DSP acknowledges. Verified on 2026-11-15: cold boot, attempt 1 succeeded
# (mbox=True after 1 try) at ~18 s, and the speakers came up without any
# audible ramp/intermittency at the start of playback.
#
# Also note (measured): PWR_CTRL3 bit24 and the PLL enable bit are NOT
# required for sound. Asp bit17 clear + GLOBAL_EN are. The probe verdict
# reflects that so it stops reporting a working amp as broken.
# ---------------------------------------------------------------------------
cat > /usr/libexec/alioth-audio-boot-probe <<'AUDIOPROBE'
#!/bin/bash
# Boot-time audio probe: records exactly what the audio path looked like when
# the system came up, so a silent cold boot can be diagnosed after the fact.
# Writes /var/lib/alioth/audio-boot.log (append, one block per run).
#
# 2026-11-15 correction: PWR_CTRL3 bit24 and the PLL enable bit are NOT
# required for sound. Measured while playing audible beeps:
#   ASP=0x10000 PWR3=0x01000010 PLL=0x370 GLOBAL_EN=1  -> sound OK
# So only ASP (bit17 clear / enabled) and GLOBAL_EN are treated as blocking;
# the other two are reported as "below the archived snapshot" for reference.
set -u

LOG=/var/lib/alioth/audio-boot.log
mkdir -p /var/lib/alioth
exec >>"$LOG" 2>&1

echo "=================================================================="
echo "BOOT $(date -Is)  reason=${1:-boot}  uptime=$(cut -d' ' -f1 /proc/uptime)s"
echo "kernel=$(uname -r)  boot_id=$(cat /proc/sys/kernel/random/boot_id)"

echo
echo "-- sound card --"
if grep -q xiaomialioth /proc/asound/cards 2>/dev/null; then
    echo "CARD: present"
    grep xiaomialioth /proc/asound/cards | sed 's/^/  /'
else
    echo "CARD: MISSING"
fi

echo
echo "-- deferred probe / DAI errors --"
dmesg 2>/dev/null | grep -iE "deferred probe|error getting cpu dai|no backend DAIs" | head -5 | sed 's/^/  /' ||
    echo "  (none)"

echo
echo "-- services --"
for u in armada-adsp-start armada-speaker-route alioth-sound-watch; do
    printf "  %-24s %s\n" "$u" "$(systemctl is-active $u 2>/dev/null)"
done

echo
echo "-- amp registers (RCV 0x40 / LCV 0x41) --"
python3 - <<'PY' 2>/dev/null || echo "  (i2c probe failed)"
import ctypes, fcntl, os, struct
I2C_SLAVE_FORCE=0x0706; I2C_RDWR=0x0707; I2C_M_RD=0x0001
class M(ctypes.Structure):
    _fields_=[("addr",ctypes.c_uint16),("flags",ctypes.c_uint16),
              ("len",ctypes.c_uint16),("buf",ctypes.c_void_p)]
class IO(ctypes.Structure):
    _fields_=[("msgs",ctypes.POINTER(M)),("nmsgs",ctypes.c_uint32)]
def rd(addr,reg):
    fd=os.open("/dev/i2c-3",os.O_RDWR)
    try:
        fcntl.ioctl(fd,I2C_SLAVE_FORCE,addr)
        wb=ctypes.create_string_buffer(struct.pack(">I",reg),4)
        rb=ctypes.create_string_buffer(4)
        a=(M*2)(M(addr,0,4,ctypes.addressof(wb)),M(addr,0x0001,4,ctypes.addressof(rb)))
        fcntl.ioctl(fd,I2C_RDWR,IO(a,2))
        return struct.unpack(">I",rb.raw)[0]
    finally: os.close(fd)
REGS = [0x4800, 0x201C, 0x2C04, 0x2014, 0x6000, 0x2024]
for name, a in (("RCV",0x40), ("LCV",0x41)):
    try:
        vals = {r: rd(a,r) for r in REGS}
    except OSError as e:
        print("  %s: I2C error %s" % (name, e))
        continue
    print("  %s:" % name)
    for r in REGS:
        print("    %#06x = %#010x" % (r, vals[r]))
    bad = []
    if vals[0x4800] != 0x10000:   bad.append("ASP bit17 set or disabled")
    if not (vals[0x2014] & 1):    bad.append("GLOBAL_EN off")
    notes = []
    if (vals[0x201C] & (1 << 24)) == 0: notes.append("PWR3 bit24 clear (non-blocking)")
    if (vals[0x2C04] & (1 << 16)) == 0: notes.append("PLL enable bit clear (non-blocking)")
    if vals[0x2024] & 0x10:       bad.append("analog muted")
    if bad:
        print("    VERDICT: PROBLEM: " + "; ".join(bad))
    else:
        print("    VERDICT: OK (sound-capable)")
    if notes:
        print("    NOTE: " + "; ".join(notes))
PY

echo
echo "-- PipeWire sink --"
su - armada -c 'export XDG_RUNTIME_DIR=/run/user/1000
d=$(pactl get-default-sink 2>/dev/null)
echo "  default: ${d:-none}"
pactl list short sinks 2>/dev/null | sed "s/^/  /"' 2>/dev/null | sed 's/^/  /' || echo "  (user session not up)"

echo
echo "-- PCM --"
sed -n '1p;/owner_pid/p;/hw_ptr/p' /proc/asound/card0/pcm0p/sub0/status 2>/dev/null | sed 's/^/  /' ||
    echo "  (no pcm0p)"

echo
echo "-- UCM2 files --"
for f in /usr/share/alsa/ucm2/Qualcomm/sm8250/Xiaomi-Alioth.conf \
         /usr/share/alsa/ucm2/conf.d/sm8250/xiaomi-alioth.conf; do
    [ -e "$f" ] && echo "  OK      $f" || echo "  MISSING $f"
done

echo
echo "-- kernel audio lines --"
dmesg 2>/dev/null | grep -iE "cs35l41|MultiMedia1|ADSP|adsp" | tail -8 | sed 's/^/  /'

echo
echo "--- end of boot block ---"
echo
AUDIOPROBE
chmod 0755 /usr/libexec/alioth-audio-boot-probe

cat > /usr/libexec/alioth-audio-boot-fix <<'AUDIOBOOTFIX'
#!/bin/bash
# Cold-boot self-healing step for the alioth speaker path.
#
# Why this exists: at boot the protection DSP is not ready for mailbox
# commands, so the single amp-enable call from armada-speaker-route reports
# ack=False and the amp never leaves its power-on state. Sound then only
# comes back after running alioth-amp-enable by hand.
#
# What it does:
#   1. waits for /dev/snd/controlC0
#   2. retries armada-speaker-route + alioth-amp-enable until the DSP
#      acknowledges, up to MAX_ATTEMPTS with RETRY_S between tries
#   3. logs every attempt to /var/lib/alioth/audio-boot.log
#
# amp-enable stays muted until the amp really acknowledges, so failed
# attempts are silent instead of a train of volume ramps.
set -u

LOG=/var/lib/alioth/audio-boot.log
mkdir -p /var/lib/alioth

MAX_ATTEMPTS=5
RETRY_S=8
CARD_WAIT_S=45

log() { echo "$@" >>"$LOG"; }

log ""
log "-- boot fix $(date -Is) --"

for _ in $(seq 1 "$CARD_WAIT_S"); do
    [ -e /dev/snd/controlC0 ] && break
    sleep 1
done
if [ ! -e /dev/snd/controlC0 ]; then
    log "  ABORT: sound card never appeared"
    exit 1
fi

ok=0
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    # The route script opens the mixer path and calls amp-enable itself.
    out=$(/usr/libexec/armada-speaker-route 2>&1 | tr '\n' ' ')
    log "  attempt $attempt: $out"
    if echo "$out" | grep -q "mbox=True"; then
        ok=1
        log "  attempt $attempt: amp acknowledged -> done"
        break
    fi
    if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
        sleep "$RETRY_S"
    fi
done

if [ "$ok" -eq 0 ]; then
    log "  RESULT: amp never acknowledged after $MAX_ATTEMPTS attempts"
    exit 2
fi
log "  RESULT: amp enabled"
AUDIOBOOTFIX
chmod 0755 /usr/libexec/alioth-audio-boot-fix

cat > /usr/lib/systemd/system/alioth-audio-boot-probe.service <<'AUDIOPROBEUNIT'
[Unit]
Description=alioth: record the audio path state at boot and self-heal it
After=armada-speaker-route.service pipewire.service wireplumber.service sound.target
Wants=armada-speaker-route.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'sleep 8; /usr/libexec/alioth-audio-boot-probe early'
ExecStartPost=/bin/bash -c '/usr/libexec/alioth-audio-boot-fix'
ExecStartPost=/bin/bash -c '/usr/libexec/alioth-audio-boot-probe after-fix'
StandardOutput=null

[Install]
WantedBy=multi-user.target
AUDIOPROBEUNIT
systemctl enable alioth-audio-boot-probe.service



# ---------------------------------------------------------------------------
# 12b. SLPI: stop the unused sensor co-processor that crash-loops
#
# slpi.mbn dies roughly every 40 s on this device:
#
#   qmi_decode_string_elem: String len 128 >= Max Len 65
#   failed to decode incoming message
#   qcom_q6v5_pas ... fatal error received:
#     EF:sensor_process ... USER-PD DOG detects stalled initialization
#   remoteproc0: crash detected in slpi -> recovering -> up -> dies again
#
# A single 54-minute boot took 71 crashes. Each cycle tears down and rebuilds
# the whole glink/rpmsg/fastrpc stack, which costs an enormous amount of
# interrupt and CPU time.
#
# Nothing on this system consumes the SLPI: iio-sensor-proxy is inactive, no
# process holds /dev/rpmsg*, and the iio devices that exist are PMIC ADCs on
# spmi/i2c. Touch is i2c (FT8756) and orientation is forced by gamescope, so
# stopping it loses no functionality.
#
# Measured 2026-11-15: interrupts 11300/s -> 2357/s, SoC 15 C cooler.
# Reversible: echo start > /sys/class/remoteproc/remoteproc0/state
# ---------------------------------------------------------------------------
cat > /usr/libexec/alioth-slpi-guard <<'SLPI_GUARD'
#!/bin/bash
# Keep the SLPI stopped across boots without breaking remoteproc.
#
# The crash loop restarts itself from the kernel side, so a one-shot `stop`
# at boot is enough: remoteproc does not auto-start a device that was stopped
# and the user did not ask to start again. This script is called at boot and
# verifies the outcome in the log.
#
# Reversible: remove the unit, or `echo start > .../remoteproc0/state`.
set -u

LOG=/var/lib/alioth/audio-boot.log
R=/sys/class/remoteproc/remoteproc0

# Wait for the SLPI to finish its own boot (firmware load happens early).
for _ in $(seq 1 30); do
    s=$(cat "$R/state" 2>/dev/null)
    [ "$s" = "running" ] && break
    sleep 1
done

if [ "$(cat "$R/state" 2>/dev/null)" = "running" ]; then
    echo stop > "$R/state" 2>/dev/null && state=stopped || state=failed
else
    state="not-running"
fi

{
  echo "-- slpi guard $(date -Is) --"
  echo "  slpi $state (crashes so far: $(journalctl -b -k --no-pager 2>/dev/null | grep -c 'handling crash #'))"
} >> "$LOG" 2>/dev/null
SLPI_GUARD
chmod 0755 /usr/libexec/alioth-slpi-guard

cat > /usr/lib/systemd/system/alioth-slpi-guard.service <<'SLPI_GUARD_UNIT'
[Unit]
Description=alioth: keep the unused, crash-looping SLPI stopped
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/libexec/alioth-slpi-guard

[Install]
WantedBy=multi-user.target
SLPI_GUARD_UNIT
systemctl enable alioth-slpi-guard.service


# ---------------------------------------------------------------------------
# 12c. SM8250 device profile: let the underclock tables actually apply
#
# device-env picks a per-device conf by matching the DT model against a fixed
# list. Our model is "Xiaomi POCO F3", which is not in that list (the board
# string does not contain "alioth" either), so $profile stayed empty, no conf
# was sourced, ARMADA_SOC_CLASS stayed empty, and every [underclock.SM8250.*]
# entry in /usr/share/armada/power-profiles.conf plus the
# ARMADA_GPU_STOCK_MAX_MHZ ceiling were silently ignored.
#
# Consequence: Balanced ran all three clusters at their hardware maximum and
# the GPU was allowed its full 670 MHz. Steam UI renders continuously at
# ~88 fps, which pins the GPU at that top bin -- the dominant heat source here.
#
# Measured 2026-11-16, Balanced, GPU ceiling 587 instead of 670:
#   gpu-top 74 C -> 63 C   (fps unchanged at 88.5)
# See docs/AUDIO-FIX-GUIDE.md (thermal notes).
# ---------------------------------------------------------------------------
if ! grep -q 'profile=alioth' /usr/libexec/armada/device-env 2>/dev/null; then
python3 - <<'ALIOTH_ENV'
p = "/usr/libexec/armada/device-env"
s = open(p).read()
anchor = '    "Retroid Pocket 5") profile=retroid-pocket-5 ;;\n'
add = (
    '    # Redmi K40 / POCO F3 (SM8250). The DT model is "Xiaomi POCO F3"\n'
    '    # -- it does not contain "alioth".\n'
    '    "Xiaomi POCO F3"|*alioth*) profile=alioth ;;\n'
)
if anchor in s and 'profile=alioth' not in s:
    s = s.replace(anchor, anchor + add, 1)
    open(p, "w").write(s)
ALIOTH_ENV
fi

cat > /usr/lib/armada/devices/alioth.conf <<'ALIOTH_CONF'
# Redmi K40 / POCO F3 (alioth), Qualcomm SM8250.
#
# Without this file ARMADA_SOC_CLASS stays empty, so every SM8250 entry in
# /usr/share/armada/power-profiles.conf ([underclock.SM8250.*]) and the
# ARMADA_GPU_STOCK_MAX_MHZ ceiling are ignored. That made Balanced run all
# three clusters at their hardware maximum and the Eco profile scale from the
# hardware max (670 MHz) instead of the reference stock clock (587 MHz).
#
# GPU stock clock: the Adreno 650 in SM8250 is specified at 587 MHz. This
# panel and Steam UI render continuously at ~88 fps, which pins the GPU at
# 670 MHz and is the dominant heat source -- see docs/AUDIO-FIX-GUIDE.md (thermal notes).

ARMADA_DEVICE_ID=alioth
ARMADA_DEVICE_NAME='Xiaomi POCO F3'
ARMADA_SOC_CLASS=SM8250

ARMADA_PANEL_ORIENTATION=left
ARMADA_IP_TARGETS=xbox-series,xb360,ds5
ALIOTH_CONF


# ---------------------------------------------------------------------------
# 12d. armada-powerd: serve Steam's performance interfaces
#
# steamui.so drives the QAM performance page from
# com.steampowered.SteamOSManager1 (PerformanceProfile1, GpuPerformanceLevel1,
# CpuScaling1, TdpLimit1). armada-powerd already implemented all four, but
# on org.armada.Power at /org/armada/Power -- a different name and path, so
# nothing looking for Steam's namespace ever found them.
#
# steamos-manager cannot serve that name here: it mkdirs
# /sys/kernel/tracing on startup, which this kernel rejects (no
# CONFIG_FTRACE), so section 12 masks it.
#
# This gives armada-powerd the second name plus an ObjectManager at "/",
# which is how the Steam bindings enumerate objects. The native
# org.armada.Power name and path are untouched, so armada-control and
# steamosctl keep working.
#
# NOTE: STEAM_XML is an f-string, so the D-Bus signature a{su} must be written
# a{{su}} -- otherwise Python reads {su} as a placeholder and powerd dies with
# NameError on startup.
# ---------------------------------------------------------------------------
if ! grep -q 'STEAM_BUS_NAME' /usr/libexec/armada/armada-powerd 2>/dev/null; then
python3 - <<'POWERD_STEAM'
import shutil
PATH = "/usr/libexec/armada/armada-powerd"
src = open(PATH).read()
shutil.copy2(PATH, PATH + ".bak-steam")

old = 'LOGIN1_NAME = "org.freedesktop.login1"\n'
new = (
    'LOGIN1_NAME = "org.freedesktop.login1"\n'
    '\n'
    '# Steam looks for its platform interfaces under its own well-known name\n'
    '# and enumerates them through an ObjectManager at "/".\n'
    'STEAM_BUS_NAME = "com.steampowered.SteamOSManager1"\n'
    'STEAM_OBJECT_PATH = "/com/steampowered/SteamOSManager1"\n'
    'OBJECT_MANAGER_IFACE = "org.freedesktop.DBus.ObjectManager"\n'
)
assert old in src, "const anchor"
src = src.replace(old, new, 1)

old = '''    def register(self, connection):
        self.connection = connection
        self.node = Gio.DBusNodeInfo.new_for_xml(XML)
        for iface in self.node.interfaces:
            connection.register_object(
                OBJECT_PATH,
                iface,
                self.handle_method_call,
                self.handle_get_property,
                self.handle_set_property,
            )
'''
new = '''    def register(self, connection):
        self.connection = connection
        self.node = Gio.DBusNodeInfo.new_for_xml(XML)
        # The steam-facing interfaces live on their own path; the native ones
        # stay at OBJECT_PATH so org.armada.Power clients are unaffected.
        self.steam_node = Gio.DBusNodeInfo.new_for_xml(STEAM_XML)
        for iface in self.node.interfaces:
            connection.register_object(
                OBJECT_PATH,
                iface,
                self.handle_method_call,
                self.handle_get_property,
                self.handle_set_property,
            )
        for iface in self.steam_node.interfaces:
            connection.register_object(
                STEAM_OBJECT_PATH,
                iface,
                self.handle_method_call,
                self.handle_get_property,
                self.handle_set_property,
            )
        self.register_object_manager(connection)
'''
assert old in src, "register anchor"
src = src.replace(old, new, 1)

old = '    def handle_method_call(self, _conn, _sender, _path, iface, method, params, invocation):\n'
new = '''    def register_object_manager(self, connection):
        connection.register_object(
            "/",
            Gio.DBusNodeInfo.new_for_xml(OBJECT_MANAGER_XML).interfaces[0],
            self.handle_method_call,
            None,
            None,
        )

    def managed_objects(self):
        props = {}
        for iface in self.steam_node.interfaces:
            names = REMOTE_PROPS.get(iface.name, {})
            props[iface.name] = {}
            for remote in names:
                try:
                    props[iface.name][remote] = self.get_property(names[remote])
                except Exception:
                    pass
        return {STEAM_OBJECT_PATH: props}

    def handle_method_call(self, _conn, _sender, _path, iface, method, params, invocation):
        if iface == OBJECT_MANAGER_IFACE and method == "GetManagedObjects":
            invocation.return_value(
                GLib.Variant("(a{oa{sa{sv}}})", (self.managed_objects(),))
            )
            return
'''
assert old in src, "handler anchor"
src = src.replace(old, new, 1)

anchor = 'XML = f"""'
assert anchor in src, "XML anchor"
insert = '''OBJECT_MANAGER_XML = """
<node>
  <interface name="org.freedesktop.DBus.ObjectManager">
    <method name="GetManagedObjects">
      <arg type="a{oa{sa{sv}}}" name="objects" direction="out"/>
    </method>
    <signal name="InterfacesAdded">
      <arg type="o" name="object"/>
      <arg type="a{sa{sv}}" name="interfaces"/>
    </signal>
    <signal name="InterfacesRemoved">
      <arg type="o" name="object"/>
      <arg type="as" name="interfaces"/>
    </signal>
  </interface>
</node>
"""

STEAM_XML = f"""
<node>
  <interface name="{IFACE_PROFILE}">
    <property name="AvailablePerformanceProfiles" type="as" access="read"/>
    <property name="PerformanceProfile" type="s" access="readwrite"/>
    <property name="SuggestedDefaultPerformanceProfile" type="s" access="read"/>
  </interface>
  <interface name="{IFACE_GPU}">
    <property name="AvailableGpuPerformanceLevels" type="as" access="read"/>
    <property name="GpuPerformanceLevel" type="s" access="readwrite"/>
    <property name="ManualGpuClock" type="u" access="readwrite"/>
    <property name="ManualGpuClockMin" type="u" access="read"/>
    <property name="ManualGpuClockMax" type="u" access="read"/>
  </interface>
  <interface name="{IFACE_CPU}">
    <property name="AvailableCpuScalingGovernors" type="as" access="read"/>
    <property name="CpuScalingGovernor" type="s" access="readwrite"/>
  </interface>
  <interface name="{IFACE_LOW_POWER}">
    <method name="EnterDownloadMode">
      <arg type="s" name="identifier" direction="in"/>
      <arg type="h" name="handle" direction="out"/>
    </method>
    <method name="ListDownloadModeHandles">
      <arg type="a{{su}}" name="identifiers" direction="out"/>
    </method>
  </interface>
</node>
"""

'''
src = src.replace(anchor, insert + anchor, 1)

old = '''    owner_id = Gio.bus_own_name(
        Gio.BusType.SYSTEM,
        BUS_NAME,
        Gio.BusNameOwnerFlags.NONE,
        bus_acquired,
        None,
        name_lost,
    )
'''
new = '''    owner_id = Gio.bus_own_name(
        Gio.BusType.SYSTEM,
        BUS_NAME,
        Gio.BusNameOwnerFlags.NONE,
        bus_acquired,
        None,
        name_lost,
    )
    # Second name: Steam's namespace.
    steam_owner_id = Gio.bus_own_name(
        Gio.BusType.SYSTEM,
        STEAM_BUS_NAME,
        Gio.BusNameOwnerFlags.NONE,
        None,
        None,
        None,
    )
'''
assert old in src, "main anchor"
src = src.replace(old, new, 1)

old = '        Gio.bus_unown_name(owner_id)\n'
new = '''        Gio.bus_unown_name(owner_id)
        Gio.bus_unown_name(steam_owner_id)
'''
assert old in src, "unown anchor"
src = src.replace(old, new, 1)

open(PATH, "w").write(src)
print("patched armada-powerd with Steam interfaces")
POWERD_STEAM
fi


# ---------------------------------------------------------------------------
# 12e. Session-bus bridge + alioth-perf
#
# Steam runs as the armada user and talks to the *session* bus
# (/run/user/1000/bus). armada-powerd owns the Steam name on the *system*
# bus, so Steam's activation on the session bus still hits the masked
# steamos-manager.service.
#
# A user-session daemon mirrors the ObjectManager and Properties surface
# onto the session bus. steamosctl then works as the normal user, which is
# what alioth-perf wraps.
#
# Note: this makes the *tools* work. The Steam UI's own QAM performance page
# gates on os-release (ID=steamos / VARIANT_ID), not on D-Bus, so the
# in-overlay TDP slider does not appear -- see docs/AUDIO-FIX-GUIDE.md.
# ---------------------------------------------------------------------------
base64 -d > /usr/libexec/armada/alioth-steam-bridge <<'BRIDGE_B64'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJCcmlkZ2UgY29tLnN0ZWFtcG93ZXJlZC5TdGVhbU9TTWFuYWdlcjEgZnJvbSB0aGUgc3lzdGVtIGJ1cyBvbnRvIHRoZSB1c2VyIGJ1cy4KClN0ZWFtIHJ1bnMgYXMgdGhlIGBhcm1hZGFgIHVzZXIgYW5kIHRhbGtzIHRvIHRoZSAqc2Vzc2lvbiogYnVzCigvcnVuL3VzZXIvMTAwMC9idXMpLiBhcm1hZGEtcG93ZXJkIGlzIGEgcm9vdCBzeXN0ZW0gc2VydmljZSBhbmQgb3ducyB0aGF0Cm5hbWUgb24gdGhlICpzeXN0ZW0qIGJ1cyBvbmx5LCBzbyBTdGVhbSdzIGFjdGl2YXRpb24gb2YKY29tLnN0ZWFtcG93ZXJlZC5TdGVhbU9TTWFuYWdlcjEgb24gdGhlIHNlc3Npb24gYnVzIHN0aWxsIGhpdHMgdGhlIG1hc2tlZApzdGVhbW9zLW1hbmFnZXIuc2VydmljZSBhbmQgZ2l2ZXMgdXAgLS0gd2hpY2ggaXMgd2h5IHRoZSBRQU0gcGVyZm9ybWFuY2UgcGFnZQpyZW5kZXJzIHdpdGhvdXQgaXRzIFREUCBzbGlkZXIuCgpUaGlzIGxpdHRsZSB1c2VyLXNlc3Npb24gZGFlbW9uIGZvcndhcmRzIHRoZSB3aG9sZQpvcmcuZnJlZWRlc2t0b3AuREJ1cy5PYmplY3RNYW5hZ2VyIHN1cmZhY2UgcGx1cyB0aGUgUHJvcGVydGllcyBjYWxscyBmb3IgdGhlCmtub3duIHN0ZWFtIGludGVyZmFjZXMsIGZyb20gdGhlIHNlc3Npb24gYnVzIHRvIHRoZSBzeXN0ZW0gYnVzLgoiIiIKaW1wb3J0IG9zCmltcG9ydCBzeXMKCmltcG9ydCBnaQoKZ2kucmVxdWlyZV92ZXJzaW9uKCJHaW8iLCAiMi4wIikKZnJvbSBnaS5yZXBvc2l0b3J5IGltcG9ydCBHTGliLCBHaW8gICMgbm9xYTogRTQwMgoKU1RFQU1fQlVTID0gImNvbS5zdGVhbXBvd2VyZWQuU3RlYW1PU01hbmFnZXIxIgpTVEVBTV9QQVRIID0gIi9jb20vc3RlYW1wb3dlcmVkL1N0ZWFtT1NNYW5hZ2VyMSIKT01fSUZBQ0UgPSAib3JnLmZyZWVkZXNrdG9wLkRCdXMuT2JqZWN0TWFuYWdlciIKUFJPUFNfSUZBQ0UgPSAib3JnLmZyZWVkZXNrdG9wLkRCdXMuUHJvcGVydGllcyIKCklGQUNFUyA9IFsKICAgICJjb20uc3RlYW1wb3dlcmVkLlN0ZWFtT1NNYW5hZ2VyMS5QZXJmb3JtYW5jZVByb2ZpbGUxIiwKICAgICJjb20uc3RlYW1wb3dlcmVkLlN0ZWFtT1NNYW5hZ2VyMS5HcHVQZXJmb3JtYW5jZUxldmVsMSIsCiAgICAiY29tLnN0ZWFtcG93ZXJlZC5TdGVhbU9TTWFuYWdlcjEuQ3B1U2NhbGluZzEiLAogICAgImNvbS5zdGVhbXBvd2VyZWQuU3RlYW1PU01hbmFnZXIxLlRkcExpbWl0MSIsCiAgICAiY29tLnN0ZWFtcG93ZXJlZC5TdGVhbU9TTWFuYWdlcjEuTG93UG93ZXJNb2RlMSIsCl0KCk9NX1hNTCA9ICIiIgo8bm9kZT4KICA8aW50ZXJmYWNlIG5hbWU9Im9yZy5mcmVlZGVza3RvcC5EQnVzLk9iamVjdE1hbmFnZXIiPgogICAgPG1ldGhvZCBuYW1lPSJHZXRNYW5hZ2VkT2JqZWN0cyI+CiAgICAgIDxhcmcgdHlwZT0iYXtvYXtzYXtzdn19fSIgbmFtZT0ib2JqZWN0cyIgZGlyZWN0aW9uPSJvdXQiLz4KICAgIDwvbWV0aG9kPgogIDwvaW50ZXJmYWNlPgo8L25vZGU+CiIiIgoKUFJPUFNfWE1MID0gIiIiCjxub2RlPgogIDxpbnRlcmZhY2UgbmFtZT0ib3JnLmZyZWVkZXNrdG9wLkRCdXMuUHJvcGVydGllcyI+CiAgICA8bWV0aG9kIG5hbWU9IkdldCI+CiAgICAgIDxhcmcgdHlwZT0icyIgbmFtZT0iaW50ZXJmYWNlIiBkaXJlY3Rpb249ImluIi8+CiAgICAgIDxhcmcgdHlwZT0icyIgbmFtZT0icHJvcGVydHkiIGRpcmVjdGlvbj0iaW4iLz4KICAgICAgPGFyZyB0eXBlPSJ2IiBuYW1lPSJ2YWx1ZSIgZGlyZWN0aW9uPSJvdXQiLz4KICAgIDwvbWV0aG9kPgogICAgPG1ldGhvZCBuYW1lPSJHZXRBbGwiPgogICAgICA8YXJnIHR5cGU9InMiIG5hbWU9ImludGVyZmFjZSIgZGlyZWN0aW9uPSJpbiIvPgogICAgICA8YXJnIHR5cGU9ImF7c3Z9IiBuYW1lPSJwcm9wZXJ0aWVzIiBkaXJlY3Rpb249Im91dCIvPgogICAgPC9tZXRob2Q+CiAgICA8bWV0aG9kIG5hbWU9IlNldCI+CiAgICAgIDxhcmcgdHlwZT0icyIgbmFtZT0iaW50ZXJmYWNlIiBkaXJlY3Rpb249ImluIi8+CiAgICAgIDxhcmcgdHlwZT0icyIgbmFtZT0icHJvcGVydHkiIGRpcmVjdGlvbj0iaW4iLz4KICAgICAgPGFyZyB0eXBlPSJ2IiBuYW1lPSJ2YWx1ZSIgZGlyZWN0aW9uPSJpbiIvPgogICAgPC9tZXRob2Q+CiAgPC9pbnRlcmZhY2U+Cjwvbm9kZT4KIiIiCgoKZGVmIHN5c3RlbV9idXMoKToKICAgIHJldHVybiBHaW8uYnVzX2dldF9zeW5jKEdpby5CdXNUeXBlLlNZU1RFTSwgTm9uZSkKCgpkZWYgZm9yd2FyZF9jYWxsKGlmYWNlLCBtZXRob2QsIHBhcmFtcywgaW52b2NhdGlvbiwgc2Vzc2lvbl9jYWxsKToKICAgICIiIkhhbmQgYSBzZXNzaW9uLWJ1cyBjYWxsIHRvIHRoZSBzYW1lIG9iamVjdCBvbiB0aGUgc3lzdGVtIGJ1cy4iIiIKICAgIHRyeToKICAgICAgICByZXBseSA9IHNlc3Npb25fY2FsbC5jYWxsX3N5bmMoU1RFQU1fQlVTLCBTVEVBTV9QQVRILCBpZmFjZSwgbWV0aG9kLCBwYXJhbXMsIE5vbmUsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEdpby5EQnVzQ2FsbEZsYWdzLk5PTkUsIC0xLCBOb25lKQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBleGM6ICAjIG5vcWE6IEJMRTAwMQogICAgICAgIGludm9jYXRpb24ucmV0dXJuX2Vycm9yX2xpdGVyYWwoCiAgICAgICAgICAgIEdpby5kYnVzX2Vycm9yX3F1YXJrKCksIDEsIHN0cihleGMpCiAgICAgICAgKQogICAgICAgIHJldHVybgogICAgaW52b2NhdGlvbi5yZXR1cm5fdmFsdWUocmVwbHkpCgoKZGVmIG1ha2VfaGFuZGxlcihidXMpOgogICAgZGVmIGhhbmRsZXIoX2Nvbm4sIF9zZW5kZXIsIHBhdGgsIGlmYWNlLCBtZXRob2QsIHBhcmFtcywgaW52b2NhdGlvbik6CiAgICAgICAgaWYgaWZhY2Ugbm90IGluIChPTV9JRkFDRSwgUFJPUFNfSUZBQ0UpOgogICAgICAgICAgICBpbnZvY2F0aW9uLnJldHVybl9lcnJvcl9saXRlcmFsKEdpby5kYnVzX2Vycm9yX3F1YXJrKCksIDIsICJ1bmtub3duIGlmYWNlIikKICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgaWYgaWZhY2UgPT0gT01fSUZBQ0U6CiAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgIHJlcGx5ID0gYnVzLmNhbGxfc3luYyhTVEVBTV9CVVMsICIvIiwgT01fSUZBQ0UsIG1ldGhvZCwgcGFyYW1zLCBOb25lLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEdpby5EQnVzQ2FsbEZsYWdzLk5PTkUsIC0xLCBOb25lKQogICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGV4YzogICMgbm9xYTogQkxFMDAxCiAgICAgICAgICAgICAgICBpbnZvY2F0aW9uLnJldHVybl9lcnJvcl9saXRlcmFsKEdpby5kYnVzX2Vycm9yX3F1YXJrKCksIDEsIHN0cihleGMpKQogICAgICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgICAgIGludm9jYXRpb24ucmV0dXJuX3ZhbHVlKHJlcGx5KQogICAgICAgICAgICByZXR1cm4KICAgICAgICAjIFByb3BlcnRpZXMgY2FsbHMgY2FycnkgdGhlIHJlYWwgaW50ZXJmYWNlIGFzIHRoZSBmaXJzdCBhcmd1bWVudC4KICAgICAgICB1bnBhY2tlZCA9IHBhcmFtcy51bnBhY2soKQogICAgICAgIHRhcmdldCA9IHVucGFja2VkWzBdIGlmIHVucGFja2VkIGVsc2UgTm9uZQogICAgICAgIGlmIHRhcmdldCBub3QgaW4gSUZBQ0VTOgogICAgICAgICAgICBpbnZvY2F0aW9uLnJldHVybl9lcnJvcl9saXRlcmFsKEdpby5kYnVzX2Vycm9yX3F1YXJrKCksIDIsICJ1bmtub3duIHByb3BlcnR5IGlmYWNlIikKICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgdHJ5OgogICAgICAgICAgICByZXBseSA9IGJ1cy5jYWxsX3N5bmMoU1RFQU1fQlVTLCBTVEVBTV9QQVRILCBQUk9QU19JRkFDRSwgbWV0aG9kLCBwYXJhbXMsIE5vbmUsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBHaW8uREJ1c0NhbGxGbGFncy5OT05FLCAtMSwgTm9uZSkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGV4YzogICMgbm9xYTogQkxFMDAxCiAgICAgICAgICAgIGludm9jYXRpb24ucmV0dXJuX2Vycm9yX2xpdGVyYWwoR2lvLmRidXNfZXJyb3JfcXVhcmsoKSwgMSwgc3RyKGV4YykpCiAgICAgICAgICAgIHJldHVybgogICAgICAgIGludm9jYXRpb24ucmV0dXJuX3ZhbHVlKHJlcGx5KQoKICAgIHJldHVybiBoYW5kbGVyCgoKZGVmIG1haW4oKToKICAgIGJ1cyA9IHN5c3RlbV9idXMoKQogICAgbG9vcCA9IEdMaWIuTWFpbkxvb3AoKQoKICAgIGRlZiBvbl9idXMoY29ubmVjdGlvbiwgX25hbWUpOgogICAgICAgIGZvciB4bWwgaW4gKE9NX1hNTCwgUFJPUFNfWE1MKToKICAgICAgICAgICAgaW5mbyA9IEdpby5EQnVzTm9kZUluZm8ubmV3X2Zvcl94bWwoeG1sKQogICAgICAgICAgICBmb3IgaSBpbiBpbmZvLmludGVyZmFjZXM6CiAgICAgICAgICAgICAgICBwYXRoID0gIi8iIGlmIGkubmFtZSA9PSBPTV9JRkFDRSBlbHNlIFNURUFNX1BBVEgKICAgICAgICAgICAgICAgIGNvbm5lY3Rpb24ucmVnaXN0ZXJfb2JqZWN0KHBhdGgsIGksIG1ha2VfaGFuZGxlcihidXMpLCBOb25lLCBOb25lKQoKICAgIGRlZiBvbl9sb3N0KF9jb25uZWN0aW9uLCBfbmFtZSk6CiAgICAgICAgcHJpbnQoInN0ZWFtLWJyaWRnZTogbG9zdCBuYW1lIiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIGxvb3AucXVpdCgpCgogICAgR2lvLmJ1c19vd25fbmFtZSgKICAgICAgICBHaW8uQnVzVHlwZS5TRVNTSU9OLCBTVEVBTV9CVVMsIEdpby5CdXNOYW1lT3duZXJGbGFncy5OT05FLAogICAgICAgIG9uX2J1cywgTm9uZSwgb25fbG9zdCwKICAgICkKICAgIGxvb3AucnVuKCkKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgbWFpbigpCg==
BRIDGE_B64
chmod 0755 /usr/libexec/armada/alioth-steam-bridge

cat > /usr/lib/systemd/user/alioth-steam-bridge.service <<'BRIDGE_UNIT'
[Unit]
Description=Bridge SteamOSManager1 from the system bus onto the session bus
After=gamescope-session.target dbus.socket
PartOf=graphical-session.target
BindsTo=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/libexec/armada/alioth-steam-bridge
Restart=always
RestartSec=2

[Install]
WantedBy=graphical-session.target
BRIDGE_UNIT

base64 -d > /usr/bin/alioth-perf <<'PERF_B64'
IyEvYmluL2Jhc2gKIyBhbGlvdGg6IHBlcmZvcm1hbmNlIHByb2ZpbGUgY29udHJvbC4KIwojICAg
YWxpb3RoLXBlcmYgICAgICAgICAgICAgICAgICAgICBzaG93IGN1cnJlbnQgc3RhdGUKIyAgIGFs
aW90aC1wZXJmIGVjb3xiYWxhbmNlZHxwZXJmb3JtYW5jZSAgIG1hbnVhbCBsb2NrLCB0aGVuIHN3
aXRjaAojICAgYWxpb3RoLXBlcmYgYXV0byAgICAgICAgICAgICAgICBoYW5kIGNvbnRyb2wgYmFj
ayB0byB0aGUgc2NlbmUgc2NoZWR1bGVyCiMgICBhbGlvdGgtcGVyZiB0ZHAgPE1Iej4gICAgICAg
ICAgIHNldCB0aGUgVERQIGxpbWl0IChzZWUgcmFuZ2UgYmVsb3cpCiMKIyBNYW51YWwgcHJvZmls
ZXMgYXJlIGEgbG9jazogYSBzY2VuZSBkYWVtb24gKGFybWFkYS1wZXJmLWF1dG8uc2VydmljZSkg
a2VlcHMKIyB0aGVtIHVudGlsIGBhbGlvdGgtcGVyZiBhdXRvYC4gQSBydW5uaW5nIGdhbWUgc3Rp
bGwgZm9yY2VzIHBlcmZvcm1hbmNlLgojCiMgVGhlIHByb2ZpbGUgd3JpdGUgZ29lcyB0aHJvdWdo
IHRoZSBzZXNzaW9uIGJ1cyAoc3RlYW1vc2N0bCkgd2hlbiBhIHNlc3Npb24KIyBleGlzdHMsIGFu
ZCB0aHJvdWdoIHRoZSBzeXN0ZW0gYnVzIG90aGVyd2lzZSwgc28gaXQgd29ya3MgZnJvbSB0aGUg
ZGVza3RvcCwKIyBmcm9tIEdhbWUgTW9kZSwgYW5kIG92ZXIgU1NILgojCiMgU3lzdGVtIGluc3Rh
bGw6IDUyLWFsaW90aC1kZXZpY2UtZml4ZXMuc2ggc2VjdGlvbiAxMmguCgpzZXQgLXUKClVTRVJf
VUlEPTEwMDAKVVNFUl9SVU5USU1FPS9ydW4vdXNlci8kVVNFUl9VSUQKCmlmIFtbICIkKGlkIC11
KSIgIT0gMCBdXTsgdGhlbgoJVVNFUl9SVU5USU1FPSR7WERHX1JVTlRJTUVfRElSOi0kVVNFUl9S
VU5USU1FfQoJZXhwb3J0IFhER19SVU5USU1FX0RJUj0iJFVTRVJfUlVOVElNRSIKCWV4cG9ydCBE
QlVTX1NFU1NJT05fQlVTX0FERFJFU1M9IiR7REJVU19TRVNTSU9OX0JVU19BRERSRVNTOi11bml4
OnBhdGg9JFVTRVJfUlVOVElNRS9idXN9IgpmaQoKUFlUSE9OPS91c3IvYmluL3B5dGhvbjMKU1lT
X05BTUU9b3JnLmFybWFkYS5Qb3dlcgpTWVNfUEFUSD0vb3JnL2FybWFkYS9Qb3dlcgpTWVNfSUZB
Q0U9b3JnLmFybWFkYS5Qb3dlcjEKCiMgUnVuIGEgY29tbWFuZCBpbiB0aGUgYXJtYWRhIHNlc3Np
b24gKG5lZWRlZCB3aGVuIHJvb3QgcnVucyB0aGlzIG92ZXIgU1NIKS4KdXNlcl9ydW4oKSB7Cglz
dWRvIC11IGFybWFkYSBlbnYgXAoJCUhPTUU9L3Zhci9ob21lL2FybWFkYSBcCgkJVVNFUj1hcm1h
ZGEgTE9HTkFNRT1hcm1hZGEgXAoJCVhER19SVU5USU1FX0RJUj0iJFVTRVJfUlVOVElNRSIgXAoJ
CURCVVNfU0VTU0lPTl9CVVNfQUREUkVTUz0idW5peDpwYXRoPSRVU0VSX1JVTlRJTUUvYnVzIiBc
CgkJIiRAIgp9CgoKbW9kZV9maWxlKCkgewoJaWYgW1sgLW4gIiR7QVJNQURBX1BFUkZfTU9ERV9G
SUxFOi19IiBdXTsgdGhlbgoJCXByaW50ZiAnJXNcbicgIiRBUk1BREFfUEVSRl9NT0RFX0ZJTEUi
CgllbHNlCgkJcHJpbnRmICclc1xuJyAvdmFyL2hvbWUvYXJtYWRhLy5jb25maWcvYWxpb3RoL3Bl
cmYtbW9kZQoJZmkKfQoKCndyaXRlX21vZGUoKSB7Cglsb2NhbCBmaWxlCglmaWxlPSQobW9kZV9m
aWxlKQoJbWtkaXIgLXAgIiQoZGlybmFtZSAiJGZpbGUiKSIgMj4vZGV2L251bGwgfHwgdHJ1ZQoJ
aWYgISBwcmludGYgJyVzXG4nICIkMSIgPiAiJGZpbGUiIDI+L2Rldi9udWxsOyB0aGVuCgkJaWYg
W1sgIiQoaWQgLXUpIiA9PSAwIF1dOyB0aGVuCgkJCXN1ZG8gLXUgYXJtYWRhIG1rZGlyIC1wICIk
KGRpcm5hbWUgIiRmaWxlIikiIDI+L2Rldi9udWxsIHx8IHRydWUKCQkJc3VkbyAtdSBhcm1hZGEg
dGVlICIkZmlsZSIgPi9kZXYvbnVsbCA8PDwiJDEiIDI+L2Rldi9udWxsIHx8IHRydWUKCQllbHNl
CgkJCXJldHVybiAxCgkJZmkKCWZpCglbWyAiJChpZCAtdSkiID09IDAgXV0gJiYgY2hvd24gYXJt
YWRhOmFybWFkYSAiJGZpbGUiIDI+L2Rldi9udWxsIHx8IHRydWUKCXJldHVybiAwCn0KCgpyZWFk
X21vZGUoKSB7Cglsb2NhbCBmaWxlCglmaWxlPSQobW9kZV9maWxlKQoJW1sgLXIgIiRmaWxlIiBd
XSB8fCB7IGVjaG8gYXV0bzsgcmV0dXJuOyB9Cgl0ciAtZCAnWzpzcGFjZTpdJyA8ICIkZmlsZSIg
Mj4vZGV2L251bGwgfCB0ciAnQS1aJyAnYS16Jwp9CgoKIyBzdGVhbW9zY3RsIHRhbGtpbmcgdG8g
dGhlIGFybWFkYSBzZXNzaW9uIChvciBhcyByb290LCB0aGF0IHVzZXIncyBzZXNzaW9uKS4KY3Rs
KCkgewoJaWYgW1sgIiQoaWQgLXUpIiA9PSAwIF1dOyB0aGVuCgkJdXNlcl9ydW4gL3Vzci9zYmlu
L3N0ZWFtb3NjdGwgIiRAIgoJZWxzZQoJCXN0ZWFtb3NjdGwgIiRAIgoJZmkKfQoKCnNldF9wcm9m
aWxlKCkgewoJaWYgY3RsIHNldC1wZXJmb3JtYW5jZS1wcm9maWxlICIkMSIgMj4vZGV2L251bGw7
IHRoZW4KCQlyZXR1cm4gMAoJZmkKCSMgTm8gdXNhYmxlIHNlc3Npb24gYnVzIC0+IHRoZSBzeXN0
ZW0gYnVzIGlzIGFsd2F5cyB0aGVyZS4KCWJ1c2N0bCAtLXN5c3RlbSBzZXQtcHJvcGVydHkgIiRT
WVNfTkFNRSIgIiRTWVNfUEFUSCIgIiRTWVNfSUZBQ0UiIFByb2ZpbGUgcyAiJDEiIDI+L2Rldi9u
dWxsCn0KCgpnYW1lX3J1bm5pbmcoKSB7CglwZ3JlcCAtZiAncmVhcGVyIFN0ZWFtTGF1bmNoIEFw
cElkPScgPi9kZXYvbnVsbCAyPiYxCn0KCgpub3RpZnkoKSB7CglbWyAtbiAiJHtBUk1BREFfUEVS
Rl9RVUlFVDotfSIgXV0gJiYgcmV0dXJuIDAKCWNvbW1hbmQgLXYgbm90aWZ5LXNlbmQgPi9kZXYv
bnVsbCAyPiYxIHx8IHJldHVybiAwCglpZiBbWyAiJChpZCAtdSkiID09IDAgXV07IHRoZW4KCQl1
c2VyX3J1biAvdXNyL3NiaW4vbm90aWZ5LXNlbmQgLXQgMjUwMCAtYSBhbGlvdGggIlBlcmZvcm1h
bmNlIHByb2ZpbGUiICIkMSIgMj4vZGV2L251bGwKCWVsc2UKCQlub3RpZnktc2VuZCAtdCAyNTAw
IC1hIGFsaW90aCAiUGVyZm9ybWFuY2UgcHJvZmlsZSIgIiQxIiAyPi9kZXYvbnVsbAoJZmkKCXJl
dHVybiAwCn0KCgpzaG93KCkgewoJbG9jYWwgbW9kZSBwcm9maWxlCgltb2RlPSQocmVhZF9tb2Rl
KQoJZWNobyAiICBTY2hlZHVsZXI6ICR7bW9kZX0gKGF1dG98ZWNvfGJhbGFuY2VkfHBlcmZvcm1h
bmNlKSIKCWlmIGN0bCBnZXQtcGVyZm9ybWFuY2UtcHJvZmlsZSA+L2Rldi9udWxsIDI+JjE7IHRo
ZW4KCQljdGwgZ2V0LXBlcmZvcm1hbmNlLXByb2ZpbGUgMj4vZGV2L251bGwgfCBzZWQgJ3MvXi8g
IC8nCgkJY3RsIGdldC10ZHAtbGltaXQgICAgICAyPi9kZXYvbnVsbCB8IHNlZCAncy9eLyAgLycK
CQljdGwgZ2V0LXRkcC1saW1pdC1taW4gIDI+L2Rldi9udWxsIHwgc2VkICdzL14vICAvJwoJCWN0
bCBnZXQtdGRwLWxpbWl0LW1heCAgMj4vZGV2L251bGwgfCBzZWQgJ3MvXi8gIC8nCgllbHNlCgkJ
IyBObyBzZXNzaW9uIGJ1cyAoU1NILW9ubHkgLyBib290KSAtPiByZWFkIHRoZSBwcm9wZXJ0eSBk
aXJlY3RseS4KCQlwcm9maWxlPSQoYnVzY3RsIC0tc3lzdGVtIGdldC1wcm9wZXJ0eSAiJFNZU19O
QU1FIiAiJFNZU19QQVRIIiAiJFNZU19JRkFDRSIgUHJvZmlsZSAyPi9kZXYvbnVsbCB8CgkJICAg
ICAgICAgIHNlZCAncy8uKiJcKC4qXCkiL1wxLycpCgkJZWNobyAiICBQcm9maWxlOiAke3Byb2Zp
bGU6LXVua25vd259IChzeXN0ZW0gYnVzKSIKCWZpCgllY2hvICIgIENQVSBjZWlsaW5nczoiCglm
b3IgcCBpbiAvc3lzL2RldmljZXMvc3lzdGVtL2NwdS9jcHVmcmVxL3BvbGljeSo7IGRvCgkJWyAt
ciAiJHAvc2NhbGluZ19tYXhfZnJlcSIgXSB8fCBjb250aW51ZQoJCXByaW50ZiAiICAgICUtMTBz
ICVzIE1IelxuIiAiJChiYXNlbmFtZSAiJHAiKSIgIiQoKCQoY2F0ICIkcC9zY2FsaW5nX21heF9m
cmVxIikgLyAxMDAwKSkiCglkb25lCglpZiBbIC1yIC9zeXMvY2xhc3MvZGV2ZnJlcS8zZDAwMDAw
LmdwdS9tYXhfZnJlcSBdOyB0aGVuCgkJcHJpbnRmICIgICAgJS0xMHMgJXMgTUh6XG4iIGdwdSAi
JCgoJChjYXQgL3N5cy9jbGFzcy9kZXZmcmVxLzNkMDAwMDAuZ3B1L21heF9mcmVxKSAvIDEwMDAw
MDApKSIKCWZpCglpZiBbIC1yIC9ydW4vYXJtYWRhL3BlcmYtYXV0by5zdGF0ZSBdOyB0aGVuCgkJ
ZWNobyAiICBMYXN0IGRlY2lzaW9uOiIKCQkkUFlUSE9OIC0gPDwnUFknIDI+L2Rldi9udWxsIHwg
c2VkICdzL14vICAvJwppbXBvcnQganNvbgpkID0ganNvbi5sb2FkKG9wZW4oIi9ydW4vYXJtYWRh
L3BlcmYtYXV0by5zdGF0ZSIpKQpwcmludCgiICAgIHRhcmdldD0lcyBnYW1lPSVzIGRlc2t0b3A9
JXMgaWRsZT0lc3MiICUgKAogICAgZC5nZXQoInRhcmdldCIpLCBkLmdldCgiZ2FtZSIpLCBkLmdl
dCgiZGVza3RvcCIpLCBkLmdldCgiaWRsZV9zIikpKQpQWQoJZmkKfQoKCmNhc2UgIiR7MTotfSIg
aW4KCSIiKSAgICAgICAgICAgc2hvdyA7OwoJZWNvfGJhbGFuY2VkfHBlcmZvcm1hbmNlKQoJICAg
ICAgICAgICAgICB3cml0ZV9tb2RlICIkMSIKCSAgICAgICAgICAgICAgIyBBIHJ1bm5pbmcgZ2Ft
ZSBpcyBuZXZlciB0aHJvdHRsZWQ6IHJlY29yZCB0aGUgbG9jaywgYnV0IGxldAoJICAgICAgICAg
ICAgICAjIHRoZSBzY2hlZHVsZXIga2VlcCBQZXJmb3JtYW5jZSB1bnRpbCB0aGUgdGl0bGUgZXhp
dHMuCgkgICAgICAgICAgICAgIGlmIGdhbWVfcnVubmluZyAmJiBbICIkMSIgIT0gcGVyZm9ybWFu
Y2UgXTsgdGhlbgoJCSAgICAgICAgICAgICAgbm90aWZ5ICIkKGVjaG8gIiR7MTowOjF9IiB8IHRy
ICdhLXonICdBLVonKSR7MToxfSAobG9ja2VkOyBhcHBsaWVzIGFmdGVyIHRoZSBnYW1lIGV4aXRz
KSIKCSAgICAgICAgICAgICAgZWxzZQoJCSAgICAgICAgICAgICAgc2V0X3Byb2ZpbGUgIiQxIgoJ
CSAgICAgICAgICAgICAgbm90aWZ5ICIkKGVjaG8gIiR7MTowOjF9IiB8IHRyICdhLXonICdBLVon
KSR7MToxfSIKCSAgICAgICAgICAgICAgZmkgOzsKCXBlcmYpICAgICAgICAgd3JpdGVfbW9kZSBw
ZXJmb3JtYW5jZQoJICAgICAgICAgICAgICBzZXRfcHJvZmlsZSBwZXJmb3JtYW5jZQoJICAgICAg
ICAgICAgICBub3RpZnkgIlBlcmZvcm1hbmNlIiA7OwoJYXV0b3xzY2hlZHVsZSkKCSAgICAgICAg
ICAgICAgd3JpdGVfbW9kZSBhdXRvCgkgICAgICAgICAgICAgIG5vdGlmeSAiQXV0b21hdGljIHNj
aGVkdWxpbmciIDs7Cgl0ZHApICAgICAgICAgIFsgJCMgLWdlIDIgXSB8fCB7IGVjaG8gInVzYWdl
OiBhbGlvdGgtcGVyZiB0ZHAgPE1Iej4iID4mMjsgZXhpdCAyOyB9CgkgICAgICAgICAgICAgIGN0
bCBzZXQtdGRwLWxpbWl0ICIkMiIgOzsKCSopICAgICAgICAgICAgZWNobyAidXNhZ2U6IGFsaW90
aC1wZXJmIFtlY298YmFsYW5jZWR8cGVyZm9ybWFuY2V8YXV0b3x0ZHAgPE1Iej5dIiA+JjI7IGV4
aXQgMiA7Owplc2FjCg==
PERF_B64
chmod 0755 /usr/bin/alioth-perf
# Older images put a wrapper in /usr/local/bin, which precedes /usr/bin
# in PATH and would shadow this one. /usr/local is /var on ostree anyway.
rm -f /usr/local/bin/alioth-perf

# Enable the bridge in the service user's own manager (it is a session service).
su - armada -c '
export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
systemctl --user daemon-reload
systemctl --user enable alioth-steam-bridge.service
' || true

systemctl restart armada-powerd || true

# ---------------------------------------------------------------------------
# 12f. Steam session switching + charger-mode screen
#
# Two separate problems, one root cause each:
#
# (a) The QAM "Switch to Desktop" button did nothing for minutes. Steam's
#     steamui.so calls SwitchToDesktopMode / SwitchToGameMode on
#     com.steampowered.SteamOSManager1.SessionManagement1 -- an interface
#     armada-powerd never implemented, so the call waited on a dead name until
#     it timed out. Section 12d gives powerd the Steam name; this section adds
#     the interface, forwarding to the switcher armada already ships
#     (/usr/libexec/armada/session-control).
#
# (b) "Power off" from the Steam menu rebooted instead. The bootloader starts
#     the kernel with androidboot.mode=charger whenever a cable is attached at
#     power-off, which is stock Android behaviour (charge while off). Nothing
#     here handled that mode, so the device did a full boot. alioth-charger-mode
#     paints the existing splash, shows the charge level, and holds until the
#     cable is pulled or the power key is pressed -- then continues to a normal
#     boot.
#
# NOTE: the charger screen must stay out of the way on normal boots. The
# androidboot.mode=charger check returns 1 immediately, and the unit is
# ordered Before=basic.target so a hold blocks everything else.
# ---------------------------------------------------------------------------
if ! grep -q 'IFACE_SESSION' /usr/libexec/armada/armada-powerd 2>/dev/null; then
python3 - <<'POWERD_SESSION'
import shutil
PATH = "/usr/libexec/armada/armada-powerd"
src = open(PATH).read()
shutil.copy2(PATH, PATH + ".bak-session")

old = 'IFACE_TDP = "com.steampowered.SteamOSManager1.TdpLimit1"\n'
new = (
    'IFACE_TDP = "com.steampowered.SteamOSManager1.TdpLimit1"\n'
    '# Steam\'s QAM "Switch to Desktop" / "Switch to Game Mode" buttons.\n'
    'IFACE_SESSION = "com.steampowered.SteamOSManager1.SessionManagement1"\n'
)
assert old in src, "const anchor"
src = src.replace(old, new, 1)

old = 'STEAM_XML = f"""\n<node>\n'
new = ('STEAM_XML = f"""\n<node>\n'
       '  <interface name="{IFACE_SESSION}">\n'
       '    <method name="SwitchToDesktopMode"/>\n'
       '    <method name="SwitchToGameMode"/>\n'
       '    <method name="SwitchToLoginMode"/>\n'
       '    <method name="SwitchToDesktopSession">\n'
       '      <arg type="s" name="session" direction="in"/>\n'
       '    </method>\n'
       '    <property name="ValidDesktopSessions" type="as" access="read"/>\n'
       '  </interface>\n')
assert old in src, "xml anchor"
src = src.replace(old, new, 1)

old = '''    def handle_method_call(self, _conn, _sender, _path, iface, method, params, invocation):
        if iface == OBJECT_MANAGER_IFACE and method == "GetManagedObjects":
'''
new = '''    def switch_session(self, target, invocation):
        helper = os.environ.get(
            "ARMADA_SESSION_CONTROL", "/usr/libexec/armada/session-control"
        )
        try:
            subprocess.run(
                [helper, target],
                check=True, timeout=60,
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
            )
        except subprocess.CalledProcessError as exc:
            invocation.return_dbus_error(
                f"{BUS_NAME}.Error.SessionSwitchFailed",
                (exc.stderr or "").strip() or f"exit {exc.returncode}",
            )
            return
        except Exception as exc:
            invocation.return_dbus_error(
                f"{BUS_NAME}.Error.SessionSwitchFailed", str(exc)
            )
            return
        invocation.return_value(None)

    def handle_method_call(self, _conn, _sender, _path, iface, method, params, invocation):
        if iface == OBJECT_MANAGER_IFACE and method == "GetManagedObjects":
'''
assert old in src, "dispatch anchor"
src = src.replace(old, new, 1)

old = '''        if iface != IFACE:
            invocation.return_dbus_error(f"{BUS_NAME}.Error.UnknownInterface", iface)
            return
'''
new = '''        if iface == IFACE_SESSION:
            if method == "SwitchToDesktopMode":
                self.switch_session("switch-desktop", invocation)
            elif method == "SwitchToGameMode":
                self.switch_session("switch-gamemode", invocation)
            elif method in ("SwitchToLoginMode", "SwitchToDesktopSession"):
                invocation.return_dbus_error(
                    f"{BUS_NAME}.Error.Unsupported", method
                )
            else:
                invocation.return_dbus_error(f"{BUS_NAME}.Error.UnknownMethod", method)
            return
        if iface != IFACE:
            invocation.return_dbus_error(f"{BUS_NAME}.Error.UnknownInterface", iface)
            return
'''
assert old in src, "method anchor"
src = src.replace(old, new, 1)

old = '''        if prop == "TdpLimit":
'''
new = '''        if prop == "ValidDesktopSessions":
            return GLib.Variant("as", [
                "armada-plasma.desktop", "armada-plasma-mobile.desktop",
            ])
        if prop == "TdpLimit":
'''
assert old in src, "getprop anchor"
src = src.replace(old, new, 1)

old = '''    IFACE_TDP: {
        "TdpLimit": "TdpLimit",
        "TdpLimitMin": "TdpLimitMin",
        "TdpLimitMax": "TdpLimitMax",
    },
}
'''
new = '''    IFACE_TDP: {
        "TdpLimit": "TdpLimit",
        "TdpLimitMin": "TdpLimitMin",
        "TdpLimitMax": "TdpLimitMax",
    },
    IFACE_SESSION: {
        "ValidDesktopSessions": "ValidDesktopSessions",
    },
}
'''
assert old in src, "remote anchor"
src = src.replace(old, new, 1)

open(PATH, "w").write(src)
print("patched SessionManagement1")
POWERD_SESSION
fi

# The session-bus bridge has to forward the new interface too, and it has to
# route *methods* (which carry no interface argument) as well as properties.
if ! grep -q 'SessionManagement1' /usr/libexec/armada/alioth-steam-bridge 2>/dev/null; then
python3 - <<'BRIDGE_SESSION'
PATH = "/usr/libexec/armada/alioth-steam-bridge"
s = open(PATH).read()

old = '    "com.steampowered.SteamOSManager1.LowPowerMode1",\n]'
new = ('    "com.steampowered.SteamOSManager1.LowPowerMode1",\n'
       '    "com.steampowered.SteamOSManager1.SessionManagement1",\n]')
assert old in s, "ifaces"
s = s.replace(old, new, 1)

old = '''        unpacked = params.unpack()
        target = unpacked[0] if unpacked else None
        if target not in IFACES:
            invocation.return_error_literal(Gio.dbus_error_quark(), 2, "unknown property iface")
            return
'''
new = '''        unpacked = params.unpack()
        if method in ("Get", "GetAll", "Set"):
            target = unpacked[0] if unpacked else None
            if target not in IFACES:
                invocation.return_error_literal(Gio.dbus_error_quark(), 2, "unknown property iface")
                return
'''
assert old in s, "props"
s = s.replace(old, new, 1)

old = '''        if iface not in (OM_IFACE, PROPS_IFACE):
'''
new = '''        if iface not in (OM_IFACE, PROPS_IFACE) and iface not in IFACES:
'''
assert old in s, "guard"
s = s.replace(old, new, 1)

open(PATH, "w").write(s)
print("bridge forwards SessionManagement1")
BRIDGE_SESSION
fi

# Charger-mode screen.
cat > /usr/libexec/armada/alioth-charger-mode <<'CHARGER_EOF'
#!/bin/bash
# alioth: charger-mode screen.
#
# When the device is powered off with a cable attached, the bootloader starts
# the kernel with androidboot.mode=charger instead of booting normally. Stock
# Android shows a battery screen and stays there. Without this the device
# performs a full boot -- which is why "power off" looked like "reboot".
#
# The screen is shown for DISPLAY_SECS, then the panel is driven fully black:
# an always-on AMOLED charge screen burns pixels and slows charging. Any touch
# or power-key press brings it back for another interval. Pulling the cable
# continues to a normal boot.
set -uo pipefail

ARMADA_CHARGER_HOLD="${ARMADA_CHARGER_HOLD:-1}"
MAX_SECS="${ARMADA_CHARGER_MAX:-28800}"
POLL_S="${ARMADA_CHARGER_POLL:-10}"
DISPLAY_SECS="${ARMADA_CHARGER_DISPLAY_SECS:-30}"
# Power-key hold that boots the system, matching stock Android.
LONGPRESS_S="${ARMADA_CHARGER_LONGPRESS_S:-1.5}"

STATUS="${ARMADA_SPLASH_STATUS:-/run/armada/splash/status}"

log() { logger -t alioth-charger -- "$*" 2>/dev/null; return 0; }

is_charger_boot() {
    grep -q 'androidboot.mode=charger' /proc/cmdline 2>/dev/null
}

if [[ "${1:-}" == "--check" ]]; then
    is_charger_boot && exit 0 || exit 1
fi
is_charger_boot || exit 0
(( ARMADA_CHARGER_HOLD )) || exit 0

# ---------------------------------------------------------------- helpers
soc_capacity() {
    local c
    for p in /sys/class/power_supply/*; do
        c=$(cat "$p/capacity" 2>/dev/null) || continue
        [[ "$c" =~ ^[0-9]+$ ]] && { echo "$c"; return 0; }
    done
    echo 0
}

plugged() {
    local s
    for p in /sys/class/power_supply/*; do
        s=$(cat "$p/status" 2>/dev/null) || continue
        [[ "$s" == Charging || "$s" == Full ]] && return 0
        s=$(cat "$p/online" 2>/dev/null) || continue
        [[ "$s" == 1 ]] && return 0
    done
    return 1
}

backlight_dir() {
    local d
    for d in /sys/class/backlight/*; do
        [[ -w "$d/brightness" ]] && { echo "$d"; return 0; }
    done
    return 1
}

paint() {
    install -d -m 0755 "$(dirname "$STATUS")" 2>/dev/null || true
    printf "%s\n" "$1" > "$STATUS" 2>/dev/null || true
}

# Wait up to $1 seconds for a key/touch event on the power key or touchscreen.
# Returns 0 on input, 1 on timeout.
# Wait up to $1 seconds for anything on the power key or touchscreen.
# Prints and returns:
#   0  power key held for >= $2 seconds   (boot)
#   1  any other input                    (light the screen)
#   2  timeout
# Both devices are watched in one call: a first wait that consumed the EV_KEY
# event would make a second, separate long-press timer see nothing.
charger_await() {
    python3 - "$1" "$2" <<'PY'
import select, struct, sys, time

limit = float(sys.argv[1])
hold = float(sys.argv[2])

PWRNAME = "/dev/input/event0"
TOUCHNAME = "/dev/input/event2"

streams = {}
for path in (PWRNAME, TOUCHNAME):
    try:
        streams[path] = open(path, "rb", buffering=0)
    except OSError:
        continue
if not streams:
    time.sleep(limit)
    print(2)
    sys.exit(0)

EV_KEY = 0x01
KEY_POWER = 116

pwr = streams.get(PWRNAME)
touch = streams.get(TOUCHNAME)

deadline = time.monotonic() + limit
pressed_at = None
other_seen = False

while True:
    now = time.monotonic()
    if pressed_at is not None and now - pressed_at >= hold:
        print(0)
        sys.exit(0)
    if now >= deadline:
        break

    # If the key is held, wake up when the hold completes, not on the full limit.
    wait = min(deadline - now,
               (pressed_at + hold - now) if pressed_at is not None else limit)

    watch = [s for s in (pwr, touch) if s is not None]
    ready, _, _ = select.select(watch, [], [], max(0.0, wait))
    if not ready:
        continue

    for s in ready:
        data = s.read(24)
        if not data or len(data) < 20:
            continue
        _sec, _usec, typ, code, val = struct.unpack("IIHHi", data[:20])

        if s is touch:
            other_seen = True
            print(1)
            sys.exit(0)

        if typ == EV_KEY and code == KEY_POWER:
            if val == 1:          # press
                pressed_at = time.monotonic()
            elif val == 2:        # autorepeat keeps the hold alive
                if pressed_at is None:
                    pressed_at = time.monotonic()
            elif val == 0:        # release
                if pressed_at is not None and time.monotonic() - pressed_at < hold:
                    other_seen = True
                pressed_at = None
        else:
            other_seen = True

    if other_seen:
        print(1)
        sys.exit(0)

print(2)
PY
}

show_screen() {
    [[ -n "$BL" ]] || return 0
    printf '%s' "$bright_orig" > "$BL/brightness" 2>/dev/null || true
    printf '0' > "$BL/bl_power" 2>/dev/null || true
}

black_screen() {
    [[ -n "$BL" ]] || return 0
    # black + backlight off: nothing to burn, and the panel stops drawing.
    printf '0' > "$BL/brightness" 2>/dev/null || true
    printf '3' > "$BL/bl_power" 2>/dev/null || true
}

# ---------------------------------------------------------------- main
BL=$(backlight_dir) || BL=""
bright_orig=29
if [[ -n "$BL" && -r "$BL/brightness" ]]; then
    bright_orig=$(cat "$BL/brightness" 2>/dev/null) || bright_orig=29
    [[ "$bright_orig" =~ ^[0-9]+$ ]] || bright_orig=29
fi

paint "Charging $(soc_capacity)%"
log "charger boot: holding at $(soc_capacity)%, display ${DISPLAY_SECS}s"

# fb0 appears only once the DPU binds, same as the boot splash.
for ((i = 0; i < 100; i++)); do
    [[ "$(cat /sys/class/graphics/fb0/name 2>/dev/null)" == msmdrmfb ]] && break
    sleep 0.1
done
/usr/libexec/armada/armada-splash-launcher >/dev/null 2>&1 &
DRAWER=$!

# The splash launcher raises brightness itself; record what it set.
if [[ -n "$BL" ]]; then
    sleep 2
    b=$(cat "$BL/brightness" 2>/dev/null) || b=""
    [[ "$b" =~ ^[0-9]+$ ]] && bright_orig=$b
fi

deadline=$(( $(date +%s) + MAX_SECS ))
last_cap=-1
lit_at=$(( $(date +%s) ))
lit=1

while (( $(date +%s) < deadline )); do
    # leaving charger mode: android boots the system when the cable goes
    if ! plugged; then
        log "charger removed -> booting normally"
        break
    fi

    cap=$(soc_capacity)
    if (( cap != last_cap )); then
        paint "Charging ${cap}%"
        last_cap=$cap
    fi

    if (( lit )); then
        remaining=$(( DISPLAY_SECS - ($(date +%s) - lit_at) ))
        (( remaining < 1 )) && remaining=1
        rc=0; charger_await "$remaining" "$LONGPRESS_S" || rc=$?
        case $rc in
            0) log "power held ${LONGPRESS_S}s -> booting"; break ;;
            1) lit_at=$(date +%s) ;;          # any press while lit extends it
        esac
        if (( rc == 2 )); then
            log "display timeout -> panel off"
            black_screen
            lit=0
            last_cap=-1
        fi
    else
        # Dark: only a press or a cable change matters. Poll slower to save power.
        rc=0; charger_await "$POLL_S" "$LONGPRESS_S" || rc=$?
        case $rc in
            0) log "power held ${LONGPRESS_S}s -> booting"; break ;;
            1) paint "Charging $(soc_capacity)%"
               show_screen
               lit=1
               lit_at=$(date +%s)
               log "woken by input" ;;
        esac
    fi
done

# Hand the framebuffer back and continue the normal boot.
[[ -n "$BL" ]] && printf '0' > "$BL/bl_power" 2>/dev/null || true
[[ -n "$BL" ]] && printf '%s' "$bright_orig" > "$BL/brightness" 2>/dev/null || true
kill "$DRAWER" 2>/dev/null || true
wait "$DRAWER" 2>/dev/null || true
rm -f "$STATUS" 2>/dev/null || true
log "charger screen done, starting system"
exit 0
CHARGER_EOF
chmod 0755 /usr/libexec/armada/alioth-charger-mode

cat > /usr/lib/systemd/system/alioth-charger-mode.service <<'CHARGER_UNIT'
[Unit]
Description=alioth: show the charger screen when booted by androidboot.mode=charger
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=basic.target
ConditionPathExists=/sys/class/graphics/fb0

[Service]
Type=oneshot
ExecStart=/usr/libexec/armada/alioth-charger-mode
RemainAfterExit=yes
TimeoutStartSec=infinity

[Install]
WantedBy=basic.target
CHARGER_UNIT
systemctl daemon-reload || true
systemctl enable alioth-charger-mode.service || true

systemctl restart armada-powerd || true

# ---------------------------------------------------------------------------
# 12g. Touch calibration follows the session type
#
# The FT8756 reports portrait coordinates. Two different compositors present
# this panel in landscape, and they handle input differently:
#
#   Game Mode : gamescope rotates the composited output but does NOT transform
#               input, so libinput must rotate -> matrix 0 -1 1 / 1 0 0
#   Desktop   : KWin rotates the output AND transforms input, so libinput must
#               stay neutral -> identity matrix
#
# Sharing one value made Desktop touch 180 degrees reversed (confirmed by hand
# on 2026-11-16: bottom-right responded to a tap at top-left).
#
# The permanent rule (installed above) stays in /usr/lib/udev/rules.d forever
# and asks alioth-touch-matrix for the value. The helper below only updates the
# persistent target state /etc/alioth/touch-mode, so the rule itself is never
# moved, deleted or shadowed: a cold boot cannot end up without a matrix.
#
# Called from session-control, the single entry point for every mode change
# (QAM button, boot hotkey, steamosctl).
#
# NOTE: libinput reads the matrix ONCE when it opens the device. Switching
# modes must therefore restart the compositor, which session-control already
# does. Updating touch-mode alone has no effect on a running session.
# ---------------------------------------------------------------------------
cat > /usr/libexec/armada/alioth-touch-for-mode <<'TOUCH_MODE_EOF'
#!/bin/bash
# Record which compositor owns the panel, then ask udev to re-evaluate the
# permanent rule so it picks up the new matrix.
#   desktop/mobile : KWin rotates the output -> libinput stays neutral
#   game           : gamescope does not transform input -> matrix must rotate
#
# The rule file is permanent and never moved: the value comes from
# alioth-touch-matrix, which reads this target state. Only /etc/alioth is
# written here, so an interrupted switch still leaves a valid matrix behind on
# the next cold boot.
set -uo pipefail

STATE=/etc/alioth/touch-mode
PERM=/usr/lib/udev/rules.d/61-alioth-touch-rotation.rules
# Rule files written by the previous file-swapping implementation.
STALE_RULE=/run/udev/rules.d/61-alioth-touch-session.rules
STALE_PARKED=/run/armada/touch-perm-rule.parked

case "${1:-}" in
    desktop|mobile|game) ;;
    *) echo "usage: $0 {desktop|mobile|game}" >&2; exit 2 ;;
esac

install -d -m 0755 /etc/alioth
printf '%s\n' "$1" > "$STATE"

# Recover from an interrupted file swap: if the permanent rule is missing but a
# parked copy survived, put it back. This is a repair, not the normal path.
if [[ ! -e "$PERM" && -e "$STALE_PARKED" ]]; then
    mv -f "$STALE_PARKED" "$PERM"
fi
rm -f "$STALE_RULE"

udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --subsystem-match=input --action=add 2>/dev/null || true
TOUCH_MODE_EOF
chmod 0755 /usr/libexec/armada/alioth-touch-for-mode

if ! grep -q 'alioth-touch-for-mode' /usr/libexec/armada/session-control 2>/dev/null; then
python3 - <<'SESSION_TOUCH'
import re
p = "/usr/libexec/armada/session-control"
s = open(p).read()
pat = re.compile(r"^([ \t]*)printf '\[Autologin\][^\n]*zz-holo-autologin\.conf$", re.M)
m = pat.search(s)
if not m:
    raise SystemExit("session-control: autologin anchor not found")
indent = m.group(1)
line = m.group(0)
block = (
    f"{indent}case \"$session\" in\n"
    f"{indent}    armada-plasma.desktop)        touch_mode=desktop ;;\n"
    f"{indent}    armada-plasma-mobile.desktop) touch_mode=mobile  ;;\n"
    f"{indent}    *)                            touch_mode=game    ;;\n"
    f"{indent}esac\n"
    f"{indent}# Desktop rotates the output inside KWin; Game Mode needs the matrix\n"
    f"{indent}# to rotate for it. They cannot share one calibration value.\n"
    f"{indent}if [[ -x /usr/libexec/armada/alioth-touch-for-mode ]]; then\n"
    f"{indent}    /usr/libexec/armada/alioth-touch-for-mode \"$touch_mode\" || true\n"
    f"{indent}fi\n"
    f"{line}"
)
s = s[: m.start()] + block + s[m.end():]
open(p, "w").write(s)
print("session-control: touch matrix now follows the session type")
SESSION_TOUCH
fi

# ---------------------------------------------------------------------------
# 12h. Scene-based performance profile scheduler
#
# Game Mode renders Steam's UI at ~88 fps unbounded, which pins the GPU at its
# top clock and is the whole reason this device ran at 74 C. Profiles exist
# (12d/12e) but nothing switched them, so the UI paid the full gaming power
# cost while the user was reading a library page.
#
# armada-perf-auto decides once per second:
#
#   game running            -> performance  (Steam's reaper SteamLaunch AppId=
#                                            process exists only while a title
#                                            is up; same signal shoulder-rotate
#                                            uses)
#   manual lock (perf-mode) -> that profile  (alioth-perf eco|balanced|...
#                                            until `alioth-perf auto`)
#   desktop session         -> balanced      (KWin needs CPU response)
#   Steam UI, input idle    -> eco           (2 min without a key press)
#   Steam UI, input active  -> balanced
#
# Details learned on the device:
#  * struct input_event is 24 bytes on 64-bit (timeval q,q + H,H,i); parsing
#    it as 8 bytes matches nothing and the scheduler never sees input.
#  * Activity means an EV_KEY press, not any event: a connected gamepad
#    reporting stick jitter would otherwise hold the UI at Balanced forever.
#  * Steam chains reapers during launch (legacycompat evaluator, then the real
#    one). Without a 20 s grace window the profile flapped Performance -> Eco
#    mid-load.
#  * A manual lock is recorded but not applied while a game runs: throttling
#    a live title because someone opened the desktop shortcut is wrong.
#  * Walking every /proc/<pid>/cmdline each second cost ~1.8% CPU on this SoC;
#    a 3 s cache brings that to ~0.6% with no visible latency.
#  * It writes only the Profile property; fan/suspend logic stays powerd's.
#
# Shortcuts call `alioth-perf <profile|auto>`. Plasma refuses root-owned
# desktop entries, so they are written as armada:armada 0755.
# ---------------------------------------------------------------------------
base64 -d > /usr/bin/alioth-perf-auto <<'PERFAUTO_B64'
IyEvdXNyL2Jpbi9weXRob24zCiIiImFsaW90aDogc2NlbmUtYmFzZWQgcGVyZm9ybWFuY2UgcHJv
ZmlsZSBzY2hlZHVsZXIuCgpEZWNpZGVzIHRoZSBhcm1hZGEtcG93ZXJkIHByb2ZpbGUgZnJvbSB3
aGF0IHRoZSBkZXZpY2UgaXMgZG9pbmc6CgogIGdhbWUgcnVubmluZyAgICAgICAgICAgICAgLT4g
cGVyZm9ybWFuY2UgIChhbHdheXMsIGV2ZW4gd2hlbiBsb2NrZWQpCiAgbWFudWFsIGxvY2sgKHBl
cmYtbW9kZSkgICAtPiB0aGF0IHByb2ZpbGUgKHVudGlsIGBhbGlvdGgtcGVyZiBhdXRvYCkKICBk
ZXNrdG9wIHNlc3Npb24gICAgICAgICAgIC0+IGJhbGFuY2VkICAgICAoS1dpbiBuZWVkcyBDUFUg
cmVzcG9uc2UpCiAgU3RlYW0gVUksIGlucHV0IGlkbGUgICAgICAtPiBlY28gICAgICAgICAgKGlk
bGUgLyBkb3dubG9hZGluZykKICBTdGVhbSBVSSwgaW5wdXQgYWN0aXZlICAgIC0+IGJhbGFuY2Vk
CgpBY3Rpdml0eSBpcyBhbiBldmRldiBrZXkgcHJlc3MgKHRvdWNoc2NyZWVuLCBwb3dlciBrZXks
IGphY2ssIGdhbWVwYWQpOyBpZGxlCmdhbWVwYWQgc3RpY2sgbm9pc2UgZG9lcyBub3QgY291bnQs
IHNvIGEgY29ubmVjdGVkIHBhZCBjYW5ub3QgcGluIHRoZSBVSSBhdApCYWxhbmNlZC4gTm9kZXMg
YXJlIHJlLXNjYW5uZWQ6IGlucHV0cGx1bWJlcidzIHZpcnR1YWwgcGFkcyBjb21lIGFuZCBnby4K
ClRoZSBwcm9maWxlIGlzIHNldCB0aHJvdWdoIGFybWFkYS1wb3dlcmQncyBzeXN0ZW0tYnVzIHBy
b3BlcnR5LCB0aGUgc2FtZQprbm9iIGBhbGlvdGgtcGVyZmAgdXNlcy4gV3JpdGVzIGhhcHBlbiBv
bmx5IHdoZW4gdGhlIHRhcmdldCBjaGFuZ2VzLCBzbwpwb3dlcmQga2VlcHMgYXBwbHlpbmcgaXRz
IG93biBmYW4vc3VzcGVuZCBsb2dpYyB1bmRpc3R1cmJlZC4KClRlc3QgaG9va3MgKHVudXNlZCBp
biBwcm9kdWN0aW9uKToKICBBUk1BREFfUEVSRl9JRExFX1MgICAgIGlkbGUgdGhyZXNob2xkIChk
ZWZhdWx0IDEyMCkKICBBUk1BREFfUEVSRl9USUNLX1MgICAgIHBvbGwgaW50ZXJ2YWwgICAoZGVm
YXVsdCAxKQogIEFSTUFEQV9QRVJGX0RSWV9SVU4gICAgMSA9IGNvbXB1dGUgKyBsb2cgb25seSwg
bm8gYnVzIHdyaXRlcwogIEFSTUFEQV9QRVJGX01PREVfRklMRSAgcGF0aCB0byB0aGUgbWFudWFs
LWxvY2sgZmlsZQogIEFSTUFEQV9QRVJGX1NERE1fQ09ORiAgcGF0aCB0byB0aGUgYXV0b2xvZ2lu
IHNlc3Npb24gZmlsZQogIC0tcmVwb3J0ICAgICAgICAgICAgICAgcHJpbnQgb25lIGRlY2lzaW9u
IGFzIEpTT04gYW5kIGV4aXQKIiIiCmltcG9ydCBnbG9iCmltcG9ydCBqc29uCmltcG9ydCBvcwpp
bXBvcnQgcmUKaW1wb3J0IHNlbGVjdAppbXBvcnQgc3RydWN0CmltcG9ydCBzdWJwcm9jZXNzCmlt
cG9ydCBzeXMKaW1wb3J0IHRpbWUKCk1PREVfRklMRSA9IG9zLmVudmlyb24uZ2V0KAogICAgIkFS
TUFEQV9QRVJGX01PREVfRklMRSIsICIvdmFyL2hvbWUvYXJtYWRhLy5jb25maWcvYWxpb3RoL3Bl
cmYtbW9kZSIpClNUQVRFX0ZJTEUgPSBvcy5lbnZpcm9uLmdldCgKICAgICJBUk1BREFfUEVSRl9T
VEFURV9GSUxFIiwgIi9ydW4vYXJtYWRhL3BlcmYtYXV0by5zdGF0ZSIpClNERE1fQ09ORiA9IG9z
LmVudmlyb24uZ2V0KAogICAgIkFSTUFEQV9QRVJGX1NERE1fQ09ORiIsICIvZXRjL3NkZG0uY29u
Zi5kL3p6LWhvbG8tYXV0b2xvZ2luLmNvbmYiKQoKSURMRV9TID0gZmxvYXQob3MuZW52aXJvbi5n
ZXQoIkFSTUFEQV9QRVJGX0lETEVfUyIsICIxMjAiKSkKVElDS19TID0gZmxvYXQob3MuZW52aXJv
bi5nZXQoIkFSTUFEQV9QRVJGX1RJQ0tfUyIsICIxIikpCiMgU3RlYW0gbGF1bmNoZXMgYSB0aXRs
ZSB0aHJvdWdoIHNldmVyYWwgcmVhcGVycyBpbiBzZXF1ZW5jZSAobGVnYWN5Y29tcGF0CiMgZXZh
bHVhdG9yLCB0aGVuIHRoZSByZWFsIGxhdW5jaCkuIFdpdGhvdXQgYSBob2xkIHRoZSBwcm9maWxl
IGZsYXBzCiMgUGVyZm9ybWFuY2UgLT4gRWNvIGJldHdlZW4gdGhlbSwgd2hpY2ggcmUtYXBwbGll
cyBDUFUvR1BVIGNhcHMgbWlkLWxvYWQuCkdBTUVfR1JBQ0VfUyA9IGZsb2F0KG9zLmVudmlyb24u
Z2V0KCJBUk1BREFfUEVSRl9HQU1FX0dSQUNFX1MiLCAiMjAiKSkKRFJZX1JVTiA9IG9zLmVudmly
b24uZ2V0KCJBUk1BREFfUEVSRl9EUllfUlVOIikgPT0gIjEiClJFU0NBTl9TID0gNS4wCiMgQ29t
cGFyZSBhZ2FpbnN0IHRoZSBsaXZlIHByb3BlcnR5IG9mdGVuOiBgYWxpb3RoLXBlcmZgIHdyaXRl
cyBpdCBkaXJlY3RseSwKIyBhbmQgcG93ZXJkIHJlc3RvcmVzIGl0cyBvd24gc2F2ZWQgdmFsdWUg
d2hlbiBpdCByZXN0YXJ0cy4KUkVDT05DSUxFX1MgPSA1LjAKIyBXYWxraW5nIGV2ZXJ5IC9wcm9j
LzxwaWQ+L2NtZGxpbmUgZWFjaCBzZWNvbmQgY29zdCB+MS44JSBDUFUgb24gdGhpcyBTb0MuCiMg
QSB0aXRsZSB0YWtlcyB0ZW5zIG9mIHNlY29uZHMgdG8gc3RhcnQsIHNvIGEgMyBzIGNhY2hlIGlz
IHBsZW50eS4KUFJPQ19TQ0FOX1MgPSAzLjAKClBST0ZJTEVTID0gKCJlY28iLCAiYmFsYW5jZWQi
LCAicGVyZm9ybWFuY2UiKQpMQUJFTFMgPSB7IkVjbyI6ICJlY28iLCAiQmFsYW5jZWQiOiAiYmFs
YW5jZWQiLCAiUGVyZm9ybWFuY2UiOiAicGVyZm9ybWFuY2UifQpCVVNfTkFNRSA9ICJvcmcuYXJt
YWRhLlBvd2VyIgpCVVNfUEFUSCA9ICIvb3JnL2FybWFkYS9Qb3dlciIKQlVTX0lGQUNFID0gIm9y
Zy5hcm1hZGEuUG93ZXIxIgoKRVZfU1lOLCBFVl9LRVksIEVWX0FCUyA9IDAsIDEsIDMKIyBzdHJ1
Y3QgaW5wdXRfZXZlbnQgb24gNjQtYml0OiAxNiBieXRlcyBvZiB0aW1ldmFsICsgdTE2IHR5cGUg
KyB1MTYgY29kZSArCiMgczMyIHZhbHVlID0gMjQgYnl0ZXMuIFJlYWRpbmcgaXQgYXMgOCBieXRl
cyBmaW5kcyBubyBrZXlzIGF0IGFsbC4KRVZFTlQgPSBzdHJ1Y3QuU3RydWN0KCI8cXFISGkiKQoK
R0FNRV9NQVJLID0gYiJyZWFwZXIgU3RlYW1MYXVuY2ggQXBwSWQ9IgpHQU1FU0NPUEVfTUFSSyA9
IGIiL3Vzci9iaW4vZ2FtZXNjb3BlIgpLV0lOX01BUksgPSBiImt3aW5fd2F5bGFuZCIKCgpkZWYg
bG9nKG1zZyk6CiAgICBwcmludCgiW3BlcmYtYXV0b10gJXMiICUgbXNnLCBmbHVzaD1UcnVlKQoK
CmRlZiByZWFkX21vZGUoKToKICAgIHRyeToKICAgICAgICB3aXRoIG9wZW4oTU9ERV9GSUxFLCBl
bmNvZGluZz0idXRmLTgiKSBhcyBmOgogICAgICAgICAgICB2YWx1ZSA9IGYucmVhZCgpLnN0cmlw
KCkubG93ZXIoKQogICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgcmV0dXJuICJhdXRvIgogICAg
cmV0dXJuIHZhbHVlIGlmIHZhbHVlIGluIFBST0ZJTEVTIGVsc2UgImF1dG8iCgoKX3NjYW5fY2Fj
aGUgPSBbMC4wLCAoRmFsc2UsIEZhbHNlLCBGYWxzZSldCgoKZGVmIHNjYW5fcHJvY3MoKToKICAg
ICIiIkNhY2hlZCAvcHJvYyBwYXNzOiAoZ2FtZV9ydW5uaW5nLCBnYW1lc2NvcGVfcnVubmluZywg
a3dpbl9ydW5uaW5nKS4KCiAgICAvcHJvYy88cGlkPi9jbWRsaW5lIHNlcGFyYXRlcyBhcmd2IHdp
dGggTlVMcywgc28gdGhlIG11bHRpLXdvcmQgZ2FtZQogICAgbWFya2VyIG9ubHkgbWF0Y2hlcyBh
ZnRlciB0aGUgTlVMcyBiZWNvbWUgc3BhY2VzIC0tIHdoaWNoIGlzIHdoYXQKICAgIGBwZ3JlcCAt
ZmAgZG9lcy4KICAgICIiIgogICAgYWdlID0gdGltZS5tb25vdG9uaWMoKSAtIF9zY2FuX2NhY2hl
WzBdCiAgICBpZiBhZ2UgPCBQUk9DX1NDQU5fUzoKICAgICAgICByZXR1cm4gX3NjYW5fY2FjaGVb
MV0KICAgIHJlc3VsdCA9IF9zY2FuX3Byb2NzKCkKICAgIF9zY2FuX2NhY2hlWzBdID0gdGltZS5t
b25vdG9uaWMoKQogICAgX3NjYW5fY2FjaGVbMV0gPSByZXN1bHQKICAgIHJldHVybiByZXN1bHQK
CgpkZWYgX3NjYW5fcHJvY3MoKToKICAgIGdhbWUgPSBnYW1lc2NvcGUgPSBrd2luID0gRmFsc2UK
ICAgIGZvciBlbnRyeSBpbiBvcy5zY2FuZGlyKCIvcHJvYyIpOgogICAgICAgIGlmIG5vdCBlbnRy
eS5uYW1lLmlzZGlnaXQoKToKICAgICAgICAgICAgY29udGludWUKICAgICAgICB0cnk6CiAgICAg
ICAgICAgIHdpdGggb3BlbigiL3Byb2MvJXMvY21kbGluZSIgJSBlbnRyeS5uYW1lLCAicmIiKSBh
cyBmOgogICAgICAgICAgICAgICAgY21kbGluZSA9IGYucmVhZCgpCiAgICAgICAgZXhjZXB0IE9T
RXJyb3I6CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgaWYgbm90IGNtZGxpbmU6CiAgICAg
ICAgICAgIGNvbnRpbnVlCiAgICAgICAgaWYgR0FNRV9NQVJLIGluIGNtZGxpbmUucmVwbGFjZShi
IlwwIiwgYiIgIik6CiAgICAgICAgICAgIGdhbWUgPSBUcnVlCiAgICAgICAgZWxpZiBHQU1FU0NP
UEVfTUFSSyBpbiBjbWRsaW5lOgogICAgICAgICAgICBnYW1lc2NvcGUgPSBUcnVlCiAgICAgICAg
ZWxpZiBLV0lOX01BUksgaW4gY21kbGluZToKICAgICAgICAgICAga3dpbiA9IFRydWUKICAgICAg
ICBpZiBnYW1lIGFuZCBnYW1lc2NvcGUgYW5kIGt3aW46CiAgICAgICAgICAgIGJyZWFrCiAgICBy
ZXR1cm4gZ2FtZSwgZ2FtZXNjb3BlLCBrd2luCgoKZGVmIGRlc2t0b3Bfc2Vzc2lvbihnYW1lc2Nv
cGUsIGt3aW4pOgogICAgIyBBIGxpdmUgY29tcG9zaXRvciB3aW5zIG92ZXIgdGhlIGF1dG9sb2dp
biBmaWxlOiBkdXJpbmcgYSBzd2l0Y2ggdGhlCiAgICAjIGZpbGUgYWxyZWFkeSBuYW1lcyB0aGUg
bmV4dCBzZXNzaW9uIHdoaWxlIHRoZSBvbGQgb25lIHN0aWxsIHJ1bnMuCiAgICBpZiBrd2luIGFu
ZCBub3QgZ2FtZXNjb3BlOgogICAgICAgIHJldHVybiBUcnVlCiAgICBpZiBnYW1lc2NvcGU6CiAg
ICAgICAgcmV0dXJuIEZhbHNlCiAgICB0cnk6CiAgICAgICAgd2l0aCBvcGVuKFNERE1fQ09ORiwg
ZW5jb2Rpbmc9InV0Zi04IikgYXMgZjoKICAgICAgICAgICAgdGV4dCA9IGYucmVhZCgpCiAgICBl
eGNlcHQgT1NFcnJvcjoKICAgICAgICByZXR1cm4gRmFsc2UKICAgIG0gPSByZS5zZWFyY2gociIo
P20pXlNlc3Npb25ccyo9XHMqKC4rKSQiLCB0ZXh0KQogICAgcmV0dXJuIGJvb2wobSkgYW5kICJw
bGFzbWEiIGluIG0uZ3JvdXAoMSkKCgpkZWYgY3VycmVudF9wcm9maWxlKCk6CiAgICB0cnk6CiAg
ICAgICAgb3V0ID0gc3VicHJvY2Vzcy5ydW4oCiAgICAgICAgICAgIFsiYnVzY3RsIiwgIi0tc3lz
dGVtIiwgImdldC1wcm9wZXJ0eSIsIEJVU19OQU1FLCBCVVNfUEFUSCwKICAgICAgICAgICAgIEJV
U19JRkFDRSwgIlByb2ZpbGUiXSwKICAgICAgICAgICAgY2FwdHVyZV9vdXRwdXQ9VHJ1ZSwgdGV4
dD1UcnVlLCB0aW1lb3V0PTMpCiAgICBleGNlcHQgKE9TRXJyb3IsIHN1YnByb2Nlc3MuU3VicHJv
Y2Vzc0Vycm9yKToKICAgICAgICByZXR1cm4gIiIKICAgIGlmIG91dC5yZXR1cm5jb2RlICE9IDA6
CiAgICAgICAgcmV0dXJuICIiCiAgICBtID0gcmUuc2VhcmNoKHInIihbXiJdKykiJywgb3V0LnN0
ZG91dCkKICAgIHJldHVybiBMQUJFTFMuZ2V0KG0uZ3JvdXAoMSksIG0uZ3JvdXAoMSkubG93ZXIo
KSkgaWYgbSBlbHNlICIiCgoKZGVmIHNldF9wcm9maWxlKHByb2ZpbGUpOgogICAgaWYgRFJZX1JV
TjoKICAgICAgICBsb2coIihkcnktcnVuKSB3b3VsZCBzZXQgcHJvZmlsZSAlcyIgJSBwcm9maWxl
KQogICAgICAgIHJldHVybiBUcnVlCiAgICB0cnk6CiAgICAgICAgb3V0ID0gc3VicHJvY2Vzcy5y
dW4oCiAgICAgICAgICAgIFsiYnVzY3RsIiwgIi0tc3lzdGVtIiwgInNldC1wcm9wZXJ0eSIsIEJV
U19OQU1FLCBCVVNfUEFUSCwKICAgICAgICAgICAgIEJVU19JRkFDRSwgIlByb2ZpbGUiLCAicyIs
IHByb2ZpbGVdLAogICAgICAgICAgICBjYXB0dXJlX291dHB1dD1UcnVlLCB0aW1lb3V0PTUpCiAg
ICBleGNlcHQgKE9TRXJyb3IsIHN1YnByb2Nlc3MuU3VicHJvY2Vzc0Vycm9yKToKICAgICAgICBy
ZXR1cm4gRmFsc2UKICAgIGlmIG91dC5yZXR1cm5jb2RlICE9IDA6CiAgICAgICAgbG9nKCJwcm9m
aWxlIHdyaXRlIGZhaWxlZDogJXMiCiAgICAgICAgICAgICUgb3V0LnN0ZGVyci5kZWNvZGUoZXJy
b3JzPSJyZXBsYWNlIikuc3RyaXAoKSkKICAgICAgICByZXR1cm4gRmFsc2UKICAgIHJldHVybiBU
cnVlCgoKZGVmIGRlY2lkZShtb2RlLCBnYW1lLCBkZXNrdG9wLCBpZGxlKToKICAgIGlmIGdhbWU6
CiAgICAgICAgcmV0dXJuICJwZXJmb3JtYW5jZSIKICAgIGlmIG1vZGUgIT0gImF1dG8iOgogICAg
ICAgIHJldHVybiBtb2RlCiAgICBpZiBkZXNrdG9wOgogICAgICAgIHJldHVybiAiYmFsYW5jZWQi
CiAgICByZXR1cm4gImVjbyIgaWYgaWRsZSA+PSBJRExFX1MgZWxzZSAiYmFsYW5jZWQiCgoKZGVm
IHdyaXRlX3N0YXRlKG1vZGUsIGdhbWUsIGRlc2t0b3AsIGlkbGUsIHRhcmdldCk6CiAgICB0cnk6
CiAgICAgICAgdG1wID0gU1RBVEVfRklMRSArICIudG1wIgogICAgICAgIHdpdGggb3Blbih0bXAs
ICJ3IiwgZW5jb2Rpbmc9InV0Zi04IikgYXMgZjoKICAgICAgICAgICAganNvbi5kdW1wKHsibW9k
ZSI6IG1vZGUsICJnYW1lIjogZ2FtZSwgImRlc2t0b3AiOiBkZXNrdG9wLAogICAgICAgICAgICAg
ICAgICAgICAgICJpZGxlX3MiOiByb3VuZChpZGxlLCAxKSwgInRhcmdldCI6IHRhcmdldCwKICAg
ICAgICAgICAgICAgICAgICAgICAidHMiOiBpbnQodGltZS50aW1lKCkpfSwgZikKICAgICAgICAg
ICAgZi53cml0ZSgiXG4iKQogICAgICAgIG9zLmNobW9kKHRtcCwgMG82NDQpCiAgICAgICAgb3Mu
cmVwbGFjZSh0bXAsIFNUQVRFX0ZJTEUpCiAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICBwYXNz
CgoKZGVmIHJlcG9ydCgpOgogICAgbW9kZSA9IHJlYWRfbW9kZSgpCiAgICBnYW1lLCBnYW1lc2Nv
cGUsIGt3aW4gPSBfc2Nhbl9wcm9jcygpCiAgICBkZXNrdG9wID0gZGVza3RvcF9zZXNzaW9uKGdh
bWVzY29wZSwga3dpbikKICAgIHByaW50KGpzb24uZHVtcHMoeyJtb2RlIjogbW9kZSwgImdhbWUi
OiBnYW1lLCAiZGVza3RvcCI6IGRlc2t0b3AsCiAgICAgICAgICAgICAgICAgICAgICAiaWRsZV9z
IjogMC4wLAogICAgICAgICAgICAgICAgICAgICAgInRhcmdldCI6IGRlY2lkZShtb2RlLCBnYW1l
LCBkZXNrdG9wLCAwLjApfSkpCgoKZGVmIG9wZW5faW5wdXRzKGV4aXN0aW5nKToKICAgIGZvciBw
YXRoIGluIGdsb2IuZ2xvYigiL2Rldi9pbnB1dC9ldmVudCoiKToKICAgICAgICBpZiBwYXRoIGlu
IGV4aXN0aW5nLnZhbHVlcygpOgogICAgICAgICAgICBjb250aW51ZQogICAgICAgIHRyeToKICAg
ICAgICAgICAgZmQgPSBvcy5vcGVuKHBhdGgsIG9zLk9fUkRPTkxZIHwgb3MuT19OT05CTE9DSykK
ICAgICAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICAgICAgY29udGludWUKICAgICAgICBleGlz
dGluZ1tmZF0gPSBwYXRoCgoKZGVmIGNsb3NlX2lucHV0cyhleGlzdGluZywga2VlcCk6CiAgICBm
b3IgZmQsIG5vZGUgaW4gbGlzdChleGlzdGluZy5pdGVtcygpKToKICAgICAgICBpZiBub2RlIGlu
IGtlZXA6CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgdHJ5OgogICAgICAgICAgICBvcy5j
bG9zZShmZCkKICAgICAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICAgICAgcGFzcwogICAgICAg
IGRlbCBleGlzdGluZ1tmZF0KCgpkZWYgaXNfYWN0aXZpdHkoZGF0YSk6CiAgICAiIiJBbnkgRVZf
S0VZIHByZXNzIG9uIGFueSBub2RlIGNvdW50cyBhcyB0aGUgdXNlciB0b3VjaGluZyB0aGUgZGV2
aWNlLiIiIgogICAgZm9yIG9mZiBpbiByYW5nZSgwLCBsZW4oZGF0YSkgLSBFVkVOVC5zaXplICsg
MSwgRVZFTlQuc2l6ZSk6CiAgICAgICAgX3NlYywgX3VzZWMsIGV2X3R5cGUsIF9jb2RlLCB2YWx1
ZSA9IEVWRU5ULnVucGFja19mcm9tKGRhdGEsIG9mZikKICAgICAgICBpZiBldl90eXBlID09IEVW
X0tFWSBhbmQgdmFsdWU6CiAgICAgICAgICAgIHJldHVybiBUcnVlCiAgICByZXR1cm4gRmFsc2UK
CgpkZWYgbWFpbigpOgogICAgZmRzID0ge30KICAgIG9wZW5faW5wdXRzKGZkcykKICAgIGxhc3Rf
YWN0aXZpdHkgPSB0aW1lLm1vbm90b25pYygpCiAgICBsYXN0X3Jlc2NhbiA9IGxhc3RfYWN0aXZp
dHkKICAgIGxhc3Rfc3RhdGUgPSBsYXN0X2FjdGl2aXR5CiAgICAjIEV4cGlyZWQgYXQgYm9vdCBz
byBhIG5vcm1hbCBzdGFydCBkb2VzIG5vdCBob2xkIFBlcmZvcm1hbmNlIGZvciAyMCBzLgogICAg
bGFzdF9nYW1lID0gbGFzdF9hY3Rpdml0eSAtIEdBTUVfR1JBQ0VfUwogICAgYXBwbGllZCA9IE5v
bmUKICAgIGxhc3RfZGVza3RvcCA9IGRlc2t0b3Bfc2Vzc2lvbigqc2Nhbl9wcm9jcygpWzE6XSkK
CiAgICB3aGlsZSBUcnVlOgogICAgICAgIG5vdyA9IHRpbWUubW9ub3RvbmljKCkKICAgICAgICBp
ZiBub3cgLSBsYXN0X3Jlc2NhbiA+PSBSRVNDQU5fUzoKICAgICAgICAgICAgb3Blbl9pbnB1dHMo
ZmRzKQogICAgICAgICAgICBjbG9zZV9pbnB1dHMoZmRzLCBzZXQoZ2xvYi5nbG9iKCIvZGV2L2lu
cHV0L2V2ZW50KiIpKSkKICAgICAgICAgICAgbGFzdF9yZXNjYW4gPSBub3cKCiAgICAgICAgdHJ5
OgogICAgICAgICAgICByZWFkeSwgXywgXyA9IHNlbGVjdC5zZWxlY3QobGlzdChmZHMpLCBbXSwg
W10sIFRJQ0tfUykKICAgICAgICBleGNlcHQgKE9TRXJyb3IsIFZhbHVlRXJyb3IpOgogICAgICAg
ICAgICByZWFkeSA9IFtdCiAgICAgICAgICAgIGZvciBmZCBpbiBsaXN0KGZkcyk6CiAgICAgICAg
ICAgICAgICBjbG9zZV9pbnB1dHMoZmRzLCBzZXQoKSkKICAgICAgICAgICAgdGltZS5zbGVlcChU
SUNLX1MpCgogICAgICAgIGZvciBmZCBpbiByZWFkeToKICAgICAgICAgICAgdHJ5OgogICAgICAg
ICAgICAgICAgZGF0YSA9IG9zLnJlYWQoZmQsIDQwOTYpCiAgICAgICAgICAgIGV4Y2VwdCBPU0Vy
cm9yOgogICAgICAgICAgICAgICAgY2xvc2VfaW5wdXRzKGZkcywgc2V0KCkpCiAgICAgICAgICAg
ICAgICBjb250aW51ZQogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBpZiBkYXRhIGFu
ZCBpc19hY3Rpdml0eShkYXRhKToKICAgICAgICAgICAgICAgICAgICBsYXN0X2FjdGl2aXR5ID0g
dGltZS5tb25vdG9uaWMoKQogICAgICAgICAgICBleGNlcHQgKHN0cnVjdC5lcnJvciwgVmFsdWVF
cnJvcikgYXMgZXhjOgogICAgICAgICAgICAgICAgIyBNYWxmb3JtZWQgYnVmZmVyIChob3QtdW5w
bHVnIG1pZC1yZWFkKTogZHJvcCB0aGF0IG5vZGUgYW5kCiAgICAgICAgICAgICAgICAjIGtlZXAg
dGhlIHNjaGVkdWxlciBhbGl2ZS4gQSBjcmFzaCBoZXJlIHJlc3RhcnRzIHRoZSBzZXJ2aWNlCiAg
ICAgICAgICAgICAgICAjIGFuZCByZS1hcHBsaWVzIHRoZSBwcm9maWxlLCB3aGljaCBpcyB2aXNp
YmxlIHRvIHRoZSB1c2VyLgogICAgICAgICAgICAgICAgbG9nKCJpbnB1dCBwYXJzZSBlcnJvciBv
biAlczogJXMiICUgKGZkcy5nZXQoZmQpLCBleGMpKQogICAgICAgICAgICAgICAgY2xvc2VfaW5w
dXRzKGZkcywgc2V0KCkpCgogICAgICAgIGlkbGUgPSB0aW1lLm1vbm90b25pYygpIC0gbGFzdF9h
Y3Rpdml0eQogICAgICAgIG1vZGUgPSByZWFkX21vZGUoKQogICAgICAgIGdhbWUsIGdhbWVzY29w
ZSwga3dpbiA9IHNjYW5fcHJvY3MoKQogICAgICAgIGlmIGdhbWU6CiAgICAgICAgICAgIGxhc3Rf
Z2FtZSA9IHRpbWUubW9ub3RvbmljKCkKICAgICAgICAjIEEgcmVhcGVyIGdhcCBiZXR3ZWVuIFN0
ZWFtJ3MgY2hhaW5lZCBsYXVuY2hlcnMgaXMgbm90ICJ0aGUgZ2FtZQogICAgICAgICMgZXhpdGVk
IjsgaG9sZCBQZXJmb3JtYW5jZSBhY3Jvc3MgaXQuCiAgICAgICAgZ2FtZSA9IGdhbWUgb3IgKHRp
bWUubW9ub3RvbmljKCkgLSBsYXN0X2dhbWUpIDwgR0FNRV9HUkFDRV9TCiAgICAgICAgZGVza3Rv
cCA9IGRlc2t0b3Bfc2Vzc2lvbihnYW1lc2NvcGUsIGt3aW4pCiAgICAgICAgaWYgZGVza3RvcCAh
PSBsYXN0X2Rlc2t0b3A6CiAgICAgICAgICAgICMgQSBzZXNzaW9uIHN3aXRjaCBpcyB1c2VyIGFj
dGl2aXR5OiB3aXRob3V0IHRoaXMgdGhlIGRhZW1vbiBjYW4KICAgICAgICAgICAgIyBsYW5kIGlu
IHRoZSBuZXcgc2Vzc2lvbiBhbHJlYWR5ICJpZGxlIiAoVUkgcmVhZGFibGUgb25seSBhZnRlcgog
ICAgICAgICAgICAjIHRoZSBjb21wb3NpdG9yIGlzIHVwKSBhbmQgZHJvcCB0byBFY28gcmlnaHQg
YXdheS4KICAgICAgICAgICAgbGFzdF9hY3Rpdml0eSA9IHRpbWUubW9ub3RvbmljKCkKICAgICAg
ICAgICAgaWRsZSA9IDAuMAogICAgICAgICAgICBsYXN0X2Rlc2t0b3AgPSBkZXNrdG9wCiAgICAg
ICAgdGFyZ2V0ID0gZGVjaWRlKG1vZGUsIGdhbWUsIGRlc2t0b3AsIGlkbGUpCgogICAgICAgIGlm
IHRhcmdldCAhPSBhcHBsaWVkOgogICAgICAgICAgICBsaXZlID0gY3VycmVudF9wcm9maWxlKCkK
ICAgICAgICAgICAgaWYgbGl2ZSBhbmQgbGl2ZSAhPSB0YXJnZXQ6CiAgICAgICAgICAgICAgICBh
cHBsaWVkID0gdGFyZ2V0IGlmIHNldF9wcm9maWxlKHRhcmdldCkgZWxzZSBsaXZlCiAgICAgICAg
ICAgIGVsc2U6CiAgICAgICAgICAgICAgICBhcHBsaWVkID0gdGFyZ2V0CiAgICAgICAgICAgIGxv
ZygicHJvZmlsZSAtPiAlcyAobW9kZT0lcyBnYW1lPSVzIGRlc2t0b3A9JXMgaWRsZT0lLjBmcyki
CiAgICAgICAgICAgICAgICAlIChhcHBsaWVkLCBtb2RlLCBnYW1lLCBkZXNrdG9wLCBpZGxlKSkK
ICAgICAgICAgICAgd3JpdGVfc3RhdGUobW9kZSwgZ2FtZSwgZGVza3RvcCwgaWRsZSwgdGFyZ2V0
KQogICAgICAgICAgICBsYXN0X3N0YXRlID0gdGltZS5tb25vdG9uaWMoKQogICAgICAgIGVsaWYg
dGltZS5tb25vdG9uaWMoKSAtIGxhc3Rfc3RhdGUgPj0gUkVDT05DSUxFX1M6CiAgICAgICAgICAg
ICMgUmVjb25jaWxlOiBwb3dlcmQgbWF5IGhhdmUgcmVzdGFydGVkIChpdCBrZWVwcyBpdHMgb3du
IGNvcHkpLgogICAgICAgICAgICBsaXZlID0gY3VycmVudF9wcm9maWxlKCkKICAgICAgICAgICAg
aWYgbGl2ZSBhbmQgbGl2ZSAhPSB0YXJnZXQ6CiAgICAgICAgICAgICAgICBhcHBsaWVkID0gdGFy
Z2V0IGlmIHNldF9wcm9maWxlKHRhcmdldCkgZWxzZSBsaXZlCiAgICAgICAgICAgICAgICBsb2co
InByb2ZpbGUgcmVjb25jaWxlZCAtPiAlcyAod2FzICVzKSIgJSAoYXBwbGllZCwgbGl2ZSkpCiAg
ICAgICAgICAgIHdyaXRlX3N0YXRlKG1vZGUsIGdhbWUsIGRlc2t0b3AsIGlkbGUsIHRhcmdldCkK
ICAgICAgICAgICAgbGFzdF9zdGF0ZSA9IHRpbWUubW9ub3RvbmljKCkKCiAgICByZXR1cm4gMAoK
CmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBpZiAiLS1yZXBvcnQiIGluIHN5cy5hcmd2
WzE6XToKICAgICAgICByZXBvcnQoKQogICAgICAgIHN5cy5leGl0KDApCiAgICBzeXMuZXhpdCht
YWluKCkpCg==
PERFAUTO_B64
chmod 0755 /usr/bin/alioth-perf-auto

base64 -d > /usr/bin/alioth-perf-shortcuts <<'PERFSHORT_B64'
IyEvYmluL2Jhc2gKIyBhbGlvdGg6IGluc3RhbGwgZGVza3RvcC1tb2RlIHNob3J0Y3V0cyBmb3Ig
dGhlIHBlcmZvcm1hbmNlIHByb2ZpbGVzLgojCiMgICBhbGlvdGgtcGVyZi1zaG9ydGN1dHMgICAg
ICAgICAgaW5zdGFsbCAob3IgcmVwYWlyKSB0aGUgc2hvcnRjdXRzCiMgICBhbGlvdGgtcGVyZi1z
aG9ydGN1dHMgcmVtb3ZlICAgZGVsZXRlIHRoZW0KIwojIFRoZSBsYXVuY2hlcnMgY2FsbCBgYWxp
b3RoLXBlcmYgPHByb2ZpbGV8YXV0bz5gLCB3aGljaCBsb2NrcyB0aGUgcHJvZmlsZQojIChBdXRv
IGhhbmRzIGNvbnRyb2wgYmFjayB0byB0aGUgc2NlbmUgc2NoZWR1bGVyKS4gUGxhc21hIHJlcXVp
cmVzIHRoZQojIGRlc2t0b3AgZmlsZSB0byBiZSBleGVjdXRhYmxlOyBvd25lcnNoaXAgbXVzdCBi
ZSB0aGUgc2Vzc2lvbiB1c2VyLCBiZWNhdXNlCiMgUGxhc21hIHJlZnVzZXMgdG8gbGF1bmNoIHJv
b3Qtb3duZWQgZGVza3RvcCBlbnRyaWVzLgoKc2V0IC11CgpERVNLVE9QX0RJUj0iJHtBUk1BREFf
REVTS1RPUF9ESVI6LS92YXIvaG9tZS9hcm1hZGEvRGVza3RvcH0iCk9XTkVSPSIke0FSTUFEQV9E
RVNLVE9QX09XTkVSOi1hcm1hZGF9IgoKZGVjbGFyZSAtQSBUSVRMRVM9KAoJW2Vjb109IlBlcmZv
cm1hbmNlOiBFY28iCglbYmFsYW5jZWRdPSJQZXJmb3JtYW5jZTogQmFsYW5jZWQiCglbcGVyZm9y
bWFuY2VdPSJQZXJmb3JtYW5jZTogUGVyZm9ybWFuY2UiCglbYXV0b109IlBlcmZvcm1hbmNlOiBB
dXRvIgopCmRlY2xhcmUgLUEgQ09NTUVOVFM9KAoJW2Vjb109Ikxvd2VzdCBjbG9ja3M7IGJlc3Qg
YmF0dGVyeS4gU3RheXMgbG9ja2VkIHVudGlsIEF1dG8uIgoJW2JhbGFuY2VkXT0iRXZlcnlkYXkg
Y2xvY2tzOyB1c2VkIGJ5IHRoZSBkZXNrdG9wIHNlc3Npb24uIgoJW3BlcmZvcm1hbmNlXT0iRnVs
bCBjbG9ja3M7IGFsc28gZm9yY2VkIHdoaWxlIGEgZ2FtZSBydW5zLiIKCVthdXRvXT0iUmV0dXJu
IHRvIHNjZW5lIHNjaGVkdWxpbmcgKEdhbWUgPSBQZXJmb3JtYW5jZSwgVUkgaWRsZSA9IEVjbyku
IgopCmRlY2xhcmUgLUEgSUNPTlM9KAoJW2Vjb109Ii91c3Ivc2hhcmUvaWNvbnMvQWR3YWl0YS9z
eW1ib2xpYy9zdGF0dXMvcG93ZXItcHJvZmlsZS1wb3dlci1zYXZlci1zeW1ib2xpYy5zdmciCglb
YmFsYW5jZWRdPSIvdXNyL3NoYXJlL2ljb25zL0Fkd2FpdGEvc3ltYm9saWMvc3RhdHVzL3Bvd2Vy
LXByb2ZpbGUtYmFsYW5jZWQtc3ltYm9saWMuc3ZnIgoJW3BlcmZvcm1hbmNlXT0iL3Vzci9zaGFy
ZS9pY29ucy9BZHdhaXRhL3N5bWJvbGljL3N0YXR1cy9wb3dlci1wcm9maWxlLXBlcmZvcm1hbmNl
LXN5bWJvbGljLnN2ZyIKCVthdXRvXT0iL3Vzci9zaGFyZS9pY29ucy9BZHdhaXRhL3N5bWJvbGlj
L3N0YXR1cy9wb3dlci1wcm9maWxlLWJhbGFuY2VkLXN5bWJvbGljLnN2ZyIKKQoKbmFtZV9mb3Io
KSB7CglwcmludGYgJyVzL2FsaW90aC1wZXJmLSVzLmRlc2t0b3BcbicgIiRERVNLVE9QX0RJUiIg
IiQxIgp9CgppbnN0YWxsX29uZSgpIHsKCWxvY2FsIGlkPSQxIGZpbGUKCWZpbGU9JChuYW1lX2Zv
ciAiJGlkIikKCXByaW50ZiAnW0Rlc2t0b3AgRW50cnldXG5UeXBlPUFwcGxpY2F0aW9uXG5OYW1l
PSVzXG5Db21tZW50PSVzXG5JY29uPSVzXG5FeGVjPS91c3IvYmluL2FsaW90aC1wZXJmICVzXG5U
ZXJtaW5hbD1mYWxzZVxuQ2F0ZWdvcmllcz1VdGlsaXR5O1xuJyBcCgkJIiR7VElUTEVTWyRpZF19
IiAiJHtDT01NRU5UU1skaWRdfSIgIiR7SUNPTlNbJGlkXX0iICIkaWQiID4gIiRmaWxlIgoJY2ht
b2QgMDc1NSAiJGZpbGUiCgljaG93biAiJHtPV05FUn06JHtPV05FUn0iICIkZmlsZSIgMj4vZGV2
L251bGwgfHwgdHJ1ZQp9CgpyZW1vdmVfb25lKCkgewoJbG9jYWwgaWQ9JDEKCXJtIC1mICIkKG5h
bWVfZm9yICIkaWQiKSIKfQoKY2FzZSAiJHsxOi1pbnN0YWxsfSIgaW4KCWluc3RhbGwpCgkJbWtk
aXIgLXAgIiRERVNLVE9QX0RJUiIKCQlbWyAiJChpZCAtdSkiID09IDAgXV0gJiYgY2hvd24gIiR7
T1dORVJ9OiR7T1dORVJ9IiAiJERFU0tUT1BfRElSIiAyPi9kZXYvbnVsbCB8fCB0cnVlCgkJZm9y
IGlkIGluIGVjbyBiYWxhbmNlZCBwZXJmb3JtYW5jZSBhdXRvOyBkbwoJCQlpbnN0YWxsX29uZSAi
JGlkIgoJCWRvbmUKCQllY2hvICJpbnN0YWxsZWQgNCBzaG9ydGN1dHMgaW4gJERFU0tUT1BfRElS
IgoJCTs7CglyZW1vdmV8dW5pbnN0YWxsKQoJCWZvciBpZCBpbiBlY28gYmFsYW5jZWQgcGVyZm9y
bWFuY2UgYXV0bzsgZG8KCQkJcmVtb3ZlX29uZSAiJGlkIgoJCWRvbmUKCQllY2hvICJyZW1vdmVk
IHRoZSBwZXJmb3JtYW5jZSBzaG9ydGN1dHMgZnJvbSAkREVTS1RPUF9ESVIiCgkJOzsKCSopCgkJ
ZWNobyAidXNhZ2U6ICQwIFtpbnN0YWxsfHJlbW92ZV0iID4mMgoJCWV4aXQgMgoJCTs7CmVzYWMK
PERFSHORT_B64
chmod 0755 /usr/bin/alioth-perf-shortcuts

cat > /usr/lib/systemd/system/armada-perf-auto.service <<'PERFAUTO_UNIT'
[Unit]
Description=alioth: scene-based performance profile scheduler
After=armada-powerd.service
Wants=armada-powerd.service

[Service]
Type=simple
ExecStart=/usr/bin/alioth-perf-auto
Restart=always
RestartSec=2
Nice=5

[Install]
WantedBy=multi-user.target
PERFAUTO_UNIT

install -d -m 0755 -o armada -g armada /var/home/armada/.config/alioth
systemctl daemon-reload
systemctl enable armada-perf-auto.service

# Desktop shortcuts are per-user data; install them for the session user.
su - armada -c '/usr/bin/alioth-perf-shortcuts install' || true

# ---------------------------------------------------------------------------
# 12i. Performance overlay (Steam's FPS / temperature readout)
#
# Steam's QAM "performance overlay level" rewrites $MANGOHUD_CONFIGFILE --
# a fresh /tmp/mangohud.XXXXXXXX that gamescope-session-plus creates per
# session and pre-seeds with a bare "no_display" line. mangohud's mangoapp
# draws the readout on gamescope's compositor and gamescope watches that file,
# so the file IS the switch.
#
# What we add:
#   * alioth-overlay-hook: keeps the last QAM snapshot
#     (~/.config/alioth/overlay.last) and restores it once per session from
#     post_gamescope_start, BEFORE Steam starts. A watcher saves later QAM
#     edits but never writes the live file while it runs.
#   * a manual switch, alioth-perf-overlay {on|off|status}
#
# Device notes:
#   * /tmp is protected_regular, so a root shell cannot rewrite a file owned by
#     armada -- writes go through `sudo -u armada`.
#   * Only a snapshot that is not gamescope's pre-seed and not our old forced
#     template ("mangoapp_steam" / "no_display=0") is saved. The QAM writes a
#     full multi-line config (control= + preset=/sharpness), never one bool.
#   * mangoapp only repaints when a new frame arrives, so a low CPU sample does
#     not mean the overlay is hidden; verify with a game or the QAM.
#   * Do NOT re-apply the overlay on a timer: the old 25 s forced-on write
#     fought the QAM and is exactly what made "off" come back on.
# ---------------------------------------------------------------------------
base64 -d > /usr/libexec/armada/alioth-overlay-hook <<'OVERLAYHOOK_B64'
IyEvYmluL2Jhc2gKIyBhbGlvdGggQTIgb3ZlcmxheSBzdGF0ZSBob29rIChsb2NhbCwgbm90IGlu
c3RhbGxlZCkKIyAgIHJlc3RvcmUgICA6IG9uY2UsIG9ubHkgaWYgbGl2ZSBjZmcgaXMgZ2FtZXNj
b3BlJ3MgcHJlLXNlZWRlZCBzaW5nbGUtbGluZQojICAgICAgICAgICAgICAgIm5vX2Rpc3BsYXki
OyBhdG9taWNhbGx5IHJlc3RvcmUgdGhlIHNhdmVkIGZ1bGwgUUFNIHNuYXBzaG90LgojICAgd2F0
Y2ggICAgIDogaW5vdGlmeXdhaXQgY2xvc2Vfd3JpdGU7IHNhdmUgc3RhYmxlIFFBTSB0ZXh0IHRv
CiMgICAgICAgICAgICAgICAkSE9NRS8uY29uZmlnL2FsaW90aC9vdmVybGF5Lmxhc3QuIE5ldmVy
IHdyaXRlcyB0aGUgbGl2ZSBmaWxlLgojICAgc3RhdHVzICAgIDogcHJpbnQgc25hcHNob3QgKyBj
dXJyZW50IGxpdmUgY2ZnIChyZWFkLW9ubHkpCiMgICBzYXZlLWZpbGUgPHA+IDogaW50ZXJuYWwg
c2VhbSB1c2VkIGJ5IHRlc3RzCiMKIyBjZmcgc2VsZWN0aW9uOiBvbmx5IGEgdW5pcXVlIGNhbmRp
ZGF0ZSBpcyBhY2NlcHRlZC4gTXVsdGlwbGUgZ2FtZXNjb3BlIFBJRHMKIyBhcmUgcmVzb2x2ZWQg
YnkgdGhlIGNhbmRpZGF0ZSBjZmcncyBvd24gbXRpbWU7IGEgdGllIGlzIGFtYmlndW91cyBhbmQg
d2UKIyBleGl0IHdpdGhvdXQgd3JpdGluZy4gQUxJT1RIX0NGR19MSVNUIChwaWQ8VEFCPnBhdGgg
bGluZXMpIGlzIGEgdGVzdCBzZWFtLgpzZXQgLXUKClBST0ZJTEU9JHtIT01FfS8uY29uZmlnL2Fs
aW90aC9vdmVybGF5Lmxhc3QKCiMgcHJpbnRzIHBhdGgsIHJldHVybnMgMDsgMSA9IG5vdGhpbmc7
IDIgPSBhbWJpZ3VvdXMKY2ZnX2ZpbGUoKSB7Cglsb2NhbCBsaW5lIHBhdGggYmVzdCBiZXN0X20g
bQoJaWYgWyAtbiAiJHtBTElPVEhfQ0ZHX09WRVJSSURFOi19IiBdOyB0aGVuCgkJcHJpbnRmICcl
c1xuJyAiJEFMSU9USF9DRkdfT1ZFUlJJREUiOyByZXR1cm4gMAoJZmkKCWlmIFsgLW4gIiR7QUxJ
T1RIX0NGR19MSVNUOi19IiBdOyB0aGVuCgkJWyAtciAiJEFMSU9USF9DRkdfTElTVCIgXSB8fCBy
ZXR1cm4gMQoJCWJlc3Q9IiI7IGJlc3RfbT0tMQoJCXdoaWxlIElGUz0kJ1x0JyByZWFkIC1yIF8g
cGF0aDsgZG8KCQkJWyAtbiAiJHBhdGgiIF0gJiYgWyAtciAiJHBhdGgiIF0gfHwgY29udGludWUK
CQkJbT0kKHN0YXQgLWMgJVkgIiRwYXRoIiAyPi9kZXYvbnVsbCB8fCBlY2hvIDApCgkJCWlmIFsg
IiRtIiAtZ3QgIiRiZXN0X20iIF07IHRoZW4gYmVzdD0kcGF0aDsgYmVzdF9tPSRtCgkJCWVsaWYg
WyAiJG0iIC1lcSAiJGJlc3RfbSIgXSAmJiBbICIkcGF0aCIgIT0gIiRiZXN0IiBdOyB0aGVuCgkJ
CQllY2hvICJhbWJpZ3VvdXMgY2ZnIGNhbmRpZGF0ZXMiID4mMjsgcmV0dXJuIDIKCQkJZmkKCQlk
b25lIDwgIiRBTElPVEhfQ0ZHX0xJU1QiCgkJWyAtbiAiJGJlc3QiIF0gJiYgeyBwcmludGYgJyVz
XG4nICIkYmVzdCI7IHJldHVybiAwOyB9CgkJcmV0dXJuIDEKCWZpCgkjIFRoZSBjb21wb3NpdG9y
J3MgL3Byb2MvUElEL2NvbW0gaXMgImdhbWVzY29wZS13bCIgb24gdGhpcyBkZXZpY2U7CgkjIHBs
YWluICJnYW1lc2NvcGUiIGlzIGFjY2VwdGVkIHRvby4gVGhlIHdyYXBwZXIgc2NyaXB0cyBhcmUg
bmFtZWQKCSMgImdhbWVzY29wZS1zZXNzaS4uLiIgYW5kIG11c3Qgbm90IG1hdGNoLgoJbG9jYWwg
cGlkcyBwIGNvbW0KCXBpZHM9IiIKCWZvciBjIGluIC9wcm9jL1swLTldKi9jb21tOyBkbwoJCXA9
JHtjIy9wcm9jL307IHA9JHtwJS9jb21tfQoJCWNvbW09JChjYXQgIiRjIiAyPi9kZXYvbnVsbCkg
fHwgY29udGludWUKCQljYXNlICIkY29tbSIgaW4KCQlnYW1lc2NvcGV8Z2FtZXNjb3BlLXdsKSBw
aWRzPSIkcGlkcyAkcCIgOzsKCQllc2FjCglkb25lCglbIC1uICIkcGlkcyIgXSB8fCByZXR1cm4g
MQoJYmVzdD0iIjsgYmVzdF9tPS0xCglmb3IgcCBpbiAkcGlkczsgZG8KCQlwYXRoPSQodHIgJ1ww
JyAnXG4nIDwgIi9wcm9jLyRwL2Vudmlyb24iIDI+L2Rldi9udWxsIFwKCQkJfCBzZWQgLW4gJ3Mv
Xk1BTkdPSFVEX0NPTkZJR0ZJTEU9Ly9wJyB8IGhlYWQgLTEpCgkJWyAtbiAiJHBhdGgiIF0gJiYg
WyAtciAiJHBhdGgiIF0gfHwgY29udGludWUKCQltPSQoc3RhdCAtYyAlWSAiJHBhdGgiIDI+L2Rl
di9udWxsIHx8IGVjaG8gMCkKCQlpZiBbICIkbSIgLWd0ICIkYmVzdF9tIiBdOyB0aGVuIGJlc3Q9
JHBhdGg7IGJlc3RfbT0kbQoJCWVsaWYgWyAiJG0iIC1lcSAiJGJlc3RfbSIgXSAmJiBbICIkcGF0
aCIgIT0gIiRiZXN0IiBdOyB0aGVuCgkJCWVjaG8gImFtYmlndW91cyBjZmcgY2FuZGlkYXRlcyIg
PiYyOyByZXR1cm4gMgoJCWZpCglkb25lCglbIC1uICIkYmVzdCIgXSAmJiB7IHByaW50ZiAnJXNc
bicgIiRiZXN0IjsgcmV0dXJuIDA7IH0KCXJldHVybiAxCn0KCmlzX2luaXRfb25seSgpIHsgICMg
Z2FtZXNjb3BlIHByZS1zZWVkOiBleGFjdGx5IG9uZSBsaW5lICJub19kaXNwbGF5IgoJWyAiJCh3
YyAtbCA8ICIkMSIpIiA9IDEgXSAmJiBbICIkKGhlYWQgLTEgIiQxIikiID0gIm5vX2Rpc3BsYXki
IF0KfQoKaXNfb2xkX3RlbXBsYXRlKCkgeyAgIyBvdXIgZm9ybWVyIGZvcmNlZCBvdmVybGF5LCBu
b3QgYSBRQU0gY2hvaWNlCglncmVwIC1xeCAnbWFuZ29hcHBfc3RlYW0nICIkMSIgfHwgZ3JlcCAt
cXggJ25vX2Rpc3BsYXk9MCcgIiQxIgp9CgpzYXZlX3NuYXBzaG90KCkgeyAgIyBzYXZlX3NuYXBz
aG90IDxzcmM+Cglsb2NhbCBzcmM9JDEgdG1wCglbIC1yICIkc3JjIiBdIHx8IHJldHVybiAxCglp
c19pbml0X29ubHkgIiRzcmMiICYmIHJldHVybiAwICAgICAgICAgICMgbm90IGEgUUFNIHdyaXRl
Cglpc19vbGRfdGVtcGxhdGUgIiRzcmMiICYmIHJldHVybiAwICAgICAgICMgbGVnYWN5IGZvcmNl
ZCB0ZW1wbGF0ZQoJbWtkaXIgLXAgIiQoZGlybmFtZSAiJFBST0ZJTEUiKSIgfHwgcmV0dXJuIDEK
CXRtcD0kKG1rdGVtcCAiJFBST0ZJTEUuWFhYWFhYIikgfHwgcmV0dXJuIDEKCWNhdCAiJHNyYyIg
PiAiJHRtcCIgJiYgbXYgLWYgIiR0bXAiICIkUFJPRklMRSIKfQoKcmVzdG9yZV9vbmNlKCkgewoJ
bG9jYWwgZiB0bXAKCWY9JChjZmdfZmlsZSkgfHwgZXhpdCAwCglbIC1yICIkZiIgXSAmJiBbIC1y
ICIkUFJPRklMRSIgXSB8fCBleGl0IDAKCWlzX2luaXRfb25seSAiJGYiIHx8IGV4aXQgMAoJaXNf
b2xkX3RlbXBsYXRlICIkUFJPRklMRSIgJiYgZXhpdCAwCgl0bXA9JChta3RlbXAgIiRmLlhYWFhY
WCIpIHx8IGV4aXQgMAoJY2F0ICIkUFJPRklMRSIgPiAiJHRtcCIgJiYgbXYgLWYgIiR0bXAiICIk
ZiIKfQoKc3RhdGVfZmlsZSgpIHsKCXByaW50ZiAnJXNcbicgIiR7QUxJT1RIX1NUQVRFX0ZJTEU6
LSR7WERHX1JVTlRJTUVfRElSOi0vcnVuL3VzZXIvJChpZCAtdSl9L2FsaW90aC1vdmVybGF5LXdh
dGNofSIKfQoKd2F0Y2hfbG9vcCgpIHsKCWxvY2FsIGYgc3QKCWY9JChjZmdfZmlsZSkgfHwgcmV0
dXJuIDEKCXN0PSQoc3RhdGVfZmlsZSkKCXRyYXAgJ3JtIC1mICIkc3QiJyBFWElUCgl0cmFwICdl
eGl0IDAnIElOVCBURVJNIEhVUAoJcHJpbnRmICclc1xuJXNcbicgIiQkIiAiJGYiID4gIiRzdCIg
Mj4vZGV2L251bGwgfHwgdHJ1ZQoJcHJpbnRmICclc1xuJyAiJGYiCgl3aGlsZSA6OyBkbwoJCWlu
b3RpZnl3YWl0IC1xcSAtZSBjbG9zZV93cml0ZSAtLWZvcm1hdCAnJXcnICIkZiIgJiBpdz0kIQoJ
CXdhaXQgIiRpdyIgfHwgYnJlYWsKCQlzYXZlX3NuYXBzaG90ICIkZiIKCWRvbmUKfQoKIyBJcyBh
IGxpdmUgd2F0Y2hlciBhbHJlYWR5IGNvcnJlY3QgZm9yIHRoZSBjdXJyZW50IGNmZz8gU3RhdGUg
ZmlsZSBob2xkcwojICJwaWRcbmNmZyIuIEEgc3RhbGUgcGlkLCB3cm9uZyBjbWRsaW5lIG9yIGRp
ZmZlcmVudCBjZmcgbWVhbnMgcmVzdGFydC4Kd2F0Y2hlcl9vaygpIHsKCWxvY2FsIHN0IHBpZCB3
YW50CglzdD0kKHN0YXRlX2ZpbGUpCglbIC1yICIkc3QiIF0gfHwgcmV0dXJuIDEKCXBpZD0kKHNl
ZCAtbiAnMXAnICIkc3QiKTsgd2FudD0kKHNlZCAtbiAnMnAnICIkc3QiKQoJWyAtbiAiJHBpZCIg
XSAmJiBbIC1uICIkd2FudCIgXSB8fCByZXR1cm4gMQoJWyAtciAiL3Byb2MvJHBpZC9jbWRsaW5l
IiBdIHx8IHJldHVybiAxCgljYXNlICIkKHRyICdcMCcgJyAnIDwgIi9wcm9jLyRwaWQvY21kbGlu
ZSIpIiBpbgoJKmFsaW90aC1vdmVybGF5LWhvb2sqd2F0Y2gqKSA7OwoJKikgcmV0dXJuIDEgOzsK
CWVzYWMKCVsgIiR3YW50IiA9ICIkKGNmZ19maWxlIDI+L2Rldi9udWxsKSIgXSB8fCByZXR1cm4g
MQoJcmV0dXJuIDAKfQoKZW5zdXJlX3dhdGNoZXIoKSB7Cglsb2NhbCBzdAoJd2F0Y2hlcl9vayAm
JiByZXR1cm4gMAoJc3Q9JChzdGF0ZV9maWxlKTsgcm0gLWYgIiRzdCIKCSMgc3RhcnQgZGV0YWNo
ZWQ7IGl0IHdyaXRlcyBpdHMgb3duIHN0YXRlIGFuZCByZW1vdmVzIGl0IG9uIGV4aXQKCSggZXhl
YyAiJDAiIHdhdGNoICkgPi9kZXYvbnVsbCAyPiYxICYKCXJldHVybiAwCn0KCmNhc2UgIiR7MTot
c3RhdHVzfSIgaW4KCXJlc3RvcmUpIHJlc3RvcmVfb25jZSA7OwoJc2F2ZS1maWxlKSBzYXZlX3Nu
YXBzaG90ICIkezI6P3BhdGggcmVxdWlyZWR9IjsgZWNobyAic2F2ZWQiIDs7CgllbnN1cmUtd2F0
Y2gpCgkJZm9yIGkgaW4gMSAyIDMgNCA1IDYgNyA4IDkgMTA7IGRvCgkJCWNmZ19maWxlID4vZGV2
L251bGwgMj4mMSAmJiBicmVhawoJCQlzbGVlcCAxCgkJZG9uZQoJCWVuc3VyZV93YXRjaGVyIDs7
Cgl3YXRjaCkKCQlmb3IgaSBpbiAxIDIgMyA0IDUgNiA3IDggOSAxMDsgZG8KCQkJY2ZnX2ZpbGUg
Pi9kZXYvbnVsbCAyPiYxICYmIGJyZWFrCgkJCXNsZWVwIDEKCQlkb25lCgkJd2F0Y2hfbG9vcCA7
OwoJc3RhdHVzKQoJCWVjaG8gInNuYXBzaG90OiAkUFJPRklMRSIKCQlbIC1yICIkUFJPRklMRSIg
XSAmJiBzZWQgJ3MvXi8gIC8nICIkUFJPRklMRSIgfHwgZWNobyAiICAobm9uZSkiCgkJZj0kKGNm
Z19maWxlIDI+L2Rldi9udWxsKTsgcmM9JD8KCQljYXNlICIkcmMiIGluCgkJMCkgWyAtciAiJGYi
IF0gJiYgeyBlY2hvICJsaXZlOiAkZiI7IHNlZCAncy9eLyAgLycgIiRmIjsgfSBcCgkJCXx8IGVj
aG8gImxpdmU6IChjYW5kaWRhdGUgbm90IHJlYWRhYmxlKSIgOzsKCQkyKSBlY2hvICJsaXZlOiAo
YW1iaWd1b3VzIGdhbWVzY29wZSBjZmcgY2FuZGlkYXRlczsgcmVmdXNpbmcgdG8gcGljaykiIDs7
CgkJKikgZWNobyAibGl2ZTogKGdhbWVzY29wZSBub3QgcnVubmluZykiIDs7CgkJZXNhYyA7OwoJ
KikgZWNobyAidXNhZ2U6ICQwIHtyZXN0b3JlfHdhdGNofHN0YXR1c30iID4mMjsgZXhpdCAyIDs7
CmVzYWMK
OVERLAYHOOK_B64
chmod 0755 /usr/libexec/armada/alioth-overlay-hook

# The session script sources sessions.d/steam and calls post_gamescope_start.
# Put restore + watcher inside that function: it runs after gamescope is up and
# before Steam's client starts, so the saved QAM snapshot is applied once and
# the watcher is alive for later QAM edits. Idempotent and reverts the old
# tail-append hook if this image was built with it.
OVERLAY_SESSION=/usr/share/gamescope-session-plus/sessions.d/steam
if [ -f "$OVERLAY_SESSION" ]; then
python3 - "$OVERLAY_SESSION" <<'SESSION_HOOK'
import io, re, sys
path = sys.argv[1]
s = io.open(path, encoding="utf-8").read()
MARK = "alioth: A2 overlay restore/watch"

old = re.compile(
    r"\n# alioth: performance overlay default \(52 section 12i\)\n"
    r"# Re-apply the saved overlay setting after gamescope/Steam start\.\n"
    r"if \[\[ -x /usr/libexec/armada/alioth-overlay-hook \]\]; then\n"
    r"\t/usr/libexec/armada/alioth-overlay-hook &\n"
    r"fi\n")
s = old.sub("\n", s)
ins = re.compile(
    r"\n\t# %s\n\tif \[\[ -x [^\n]*\]\]; then\n(?:.*?\n)*?\tfi\n" % re.escape(MARK))
s = ins.sub("\n", s)

func = re.compile(r"(function post_gamescope_start \{\n(?:.*?\n)*?)(\})", re.S)
block = (
    "\t# %s\n"
    "\tif [[ -x /usr/libexec/armada/alioth-overlay-hook ]]; then\n"
    "\t\t/usr/libexec/armada/alioth-overlay-hook restore >/dev/null 2>&1 || true\n"
    "\t\t/usr/libexec/armada/alioth-overlay-hook ensure-watch "
    ">/tmp/alioth-overlay-watch.log 2>&1\n"
    "\tfi\n") % MARK
if MARK in s:
    sys.exit("unremovable old hook remains")
m = func.search(s)
if not m:
    sys.exit("post_gamescope_start not found")
s = s[:m.end(1)] + block + s[m.end(1):]
if s.count(MARK) != 1:
    sys.exit("marker count != 1")
io.open(path, "w", encoding="utf-8", newline="\n").write(s)
print("session hook installed in post_gamescope_start")
SESSION_HOOK
fi

install -d -o armada -g armada /var/home/armada/.config/alioth


# ---------------------------------------------------------------------------
# 12j. Audio recovery after suspend/resume
#
# After resume the Q6AFE TERTIARY_MI2S_RX playback path can come back broken:
# the software waveform is clean but the speaker crackles. Restarting the user
# audio stack fixes it; in Game Mode the CEF AudioService also has to reconnect,
# which the session restart does.
#
# /usr/lib/systemd/system-sleep/alioth-audio-resume is the post-resume hook.
# While a game is running (or /proc cannot be read) it touches NOTHING - not
# even PipeWire, because restarting it under a game is not proven harmless -
# and only leaves a pending marker for manual recovery. It never starts
# gamescope in desktop mode, restarts a session at most once per session
# (boot_id + MainPID), and leaves the power key / logind policy alone.
#   sudo alioth-audio-resume --restart-session
# ---------------------------------------------------------------------------
install -d -m 0755 /usr/lib/systemd/system-sleep
base64 -d > /usr/lib/systemd/system-sleep/alioth-audio-resume <<'AUDIORESUME_B64'
IyEvYmluL2Jhc2gKIyBhbGlvdGggYXVkaW8gcmVzdW1lIHJlY292ZXJ5IChzeXN0ZW1kIHN5c3Rl
bS1zbGVlcCBob29rLCBwb3N0IG9ubHkpCiMKIyBBZnRlciByZXN1bWUgdGhlIFE2QUZFL0FEU1Ag
cGxheWJhY2sgcGF0aCBjYW4gY29tZSBiYWNrIGJyb2tlbjogdGhlIHNvZnR3YXJlCiMgd2F2ZWZv
cm0gaXMgY2xlYW4gYnV0IHRoZSBzcGVha2VyIGNyYWNrbGVzLiBSZXN0YXJ0aW5nIHRoZSB1c2Vy
IGF1ZGlvIHN0YWNrCiMgZml4ZXMgaXQgKHZlcmlmaWVkKS4gSW4gR2FtZSBNb2RlIHRoZSBDRUYg
QXVkaW9TZXJ2aWNlIGFsc28gaGFzIHRvIHJlY29ubmVjdCwKIyB3aGljaCB0aGUgc2Vzc2lvbiBy
ZXN0YXJ0IGRvZXMgKHZlcmlmaWVkKS4KIwojIFNhZmV0eToKIyAgICogcG9zdCBvbmx5LCBwcmUg
aXMgYSBuby1vcDsgc3lzdGVtLXNsZWVwIGl0c2VsZiBvbmx5IGNhbGxzIHByZXxwb3N0CiMgICAq
IHNpbmdsZSBpbnN0YW5jZSAoZmxvY2spLCBuZXZlciBhIHJldHJ5IGxvb3AKIyAgICogc2Vzc2lv
biByZXN0YXJ0ZWQgYXQgbW9zdCBvbmNlIFBFUiBTRVNTSU9OIChib290X2lkICsgc2Vzc2lvbiBN
YWluUElEKSwKIyAgICAgc28gYSBzZWNvbmQgcmVzdW1lIGluIGEgbmV3IHNlc3Npb24gY2FuIHJl
Y292ZXIgYWdhaW4gd2l0aG91dCBsb29wcwojICAgKiBhIHJ1bm5pbmcgZ2FtZSBuZXZlciBnZXRz
IGl0cyBhdWRpbyBzdGFjayBPUiBpdHMgc2Vzc2lvbiB0b3VjaGVkOgojICAgICByZXN0YXJ0aW5n
IFBpcGVXaXJlIGR1cmluZyBwbGF5IGlzIG5vdCBwcm92ZW4gaGFybWxlc3MgZWl0aGVyLCBzbyB3
ZQojICAgICBvbmx5IHdyaXRlIHRoZSBwZW5kaW5nIG1hcmtlci4gRGV0ZWN0aW9uIHdhbGtzIHJl
YWwgL3Byb2MKIyAgICAgY21kbGluZXM7IGl0IGNhbm5vdCBzZWUgYSBnYW1lIHN0YXJ0ZWQgb3V0
c2lkZSBTdGVhbSBvciBvbmUgd2hvc2UKIyAgICAgY21kbGluZSBpcyB1bnJlYWRhYmxlIChoaWRl
cGlkKSwgc28gd2hlbiBubyBjbWRsaW5lIGlzIHJlYWRhYmxlIGF0IGFsbAojICAgICB3ZSB0cmVh
dCB0aGUgc3RhdGUgYXMgdW5rbm93biBhbmQgbGVhdmUgdGhlIHNlc3Npb24gYWxvbmUgKHBlbmRp
bmcgZmxhZykKIyAgICogZGVza3RvcCBtb2RlIG5ldmVyIHN0YXJ0cyBvciBzdG9wcyBnYW1lc2Nv
cGU7IGl0IGlzIGRldGVjdGVkIGZyb20KIyAgICAgL3Byb2MgY29tbSwgbm90IGZyb20gYSBELUJ1
cyBjYWxsIHRoYXQgbWF5IGJsb2NrIGFmdGVyIHJlc3VtZQojICAgKiBldmVyeSB1c2VyIEQtQnVz
IGNhbGwgaXMgd3JhcHBlZCBpbiB0aW1lb3V0LCBzbyB0aGUgaG9vayBzdGF5cyBib3VuZGVkCiMg
ICAgIGV2ZW4gd2hpbGUgdGhlIHVzZXIgc2xpY2UgaXMgc3RpbGwgdGhhd2luZwojICAgKiB0aGUg
cG93ZXIga2V5IC8gbG9naW5kIHBvbGljeSBpcyB1bnRvdWNoZWQKIwojIE1hbnVhbCBlbnRyeSAo
dXNlciwgYWZ0ZXIgY2xvc2luZyBhIGdhbWUpOgojICAgc3VkbyBhbGlvdGgtYXVkaW8tcmVzdW1l
IC0tcmVzdGFydC1zZXNzaW9uCiMgSXQgc3RpbGwgcmVmdXNlcyB3aGVuIGEgZ2FtZSBpcyBydW5u
aW5nLgojCiMgbG9nOiAvdmFyL2xvZy9hbGlvdGgtYXVkaW8tcmVzdW1lLmxvZwojIHBlbmRpbmc6
IC9ydW4vYWxpb3RoLWF1ZGlvLXJlc3VtZS5wZW5kaW5nCiMgc3RhbXA6IC9ydW4vYWxpb3RoLWF1
ZGlvLXJlc3VtZS5zZXNzaW9uIChib290X2lkICsgc2Vzc2lvbiBNYWluUElEKQpzZXQgLXUKClVJ
RF9TRVNTSU9OPSR7QUxJT1RIX1VJRDotMTAwMH0KUlVORElSPSR7QUxJT1RIX1JVTkRJUjotL3J1
bi91c2VyLyRVSURfU0VTU0lPTn0KU0lOSz0ke0FMSU9USF9TSU5LOi1hbHNhX291dHB1dC5wbGF0
Zm9ybS1zb3VuZC5IaUZpX19TcGVha2VyX19zaW5rfQpVTklUPSR7QUxJT1RIX1VOSVQ6LWdhbWVz
Y29wZS1zZXNzaW9uLXBsdXNAc3RlYW0uc2VydmljZX0KTE9HPSR7QUxJT1RIX0xPRzotL3Zhci9s
b2cvYWxpb3RoLWF1ZGlvLXJlc3VtZS5sb2d9CkxPQ0s9JHtBTElPVEhfTE9DSzotL3J1bi9hbGlv
dGgtYXVkaW8tcmVzdW1lLmxvY2t9ClBFTkRJTkc9JHtBTElPVEhfUEVORElORzotL3J1bi9hbGlv
dGgtYXVkaW8tcmVzdW1lLnBlbmRpbmd9ClNUQU1QPSR7QUxJT1RIX1NUQU1QOi0vcnVuL2FsaW90
aC1hdWRpby1yZXN1bWUuc2Vzc2lvbn0KV0FJVF9TPSR7QUxJT1RIX1dBSVQ6LTI1fQpQUk9DX0RJ
Uj0ke0FMSU9USF9QUk9DX0RJUjotL3Byb2N9CiMgRXZlcnkgdXNlciBELUJ1cyBjYWxsIGlzIGJv
dW5kZWQsIGJ1dCB0aGUgYm91bmQgbXVzdCBvdXRsYXN0IHRoZSB0aGF3LgojIE1lYXN1cmVkIDIw
MjYtMTEtMTc6IHJlc3VtZSBleGl0IDE0OjM4OjUwLCAiU3VjY2Vzc2Z1bGx5IHRoYXdlZCB1bml0
CiMgdXNlci5zbGljZSIgMTJzIGxhdGVyIGF0IDE0OjM5OjAyLiBBIDEwcyBib3VuZCBleHBpcmVk
IGp1c3QgYmVmb3JlIHRoZSB0aGF3CiMgYW5kIHRoZSBhdWRpbyByZXN0YXJ0IGxvc3QgdGhhdCBy
YWNlLiA2MHMgaXMgc3RpbGwgc3RyaWN0bHkgYm91bmRlZCBhbmQKIyBjb21mb3J0YWJseSBiZXlv
bmQgdGhlIG9ic2VydmVkIHRoYXc7IHdhaXRpbmcgaXMgTk9UIHVuYm91bmRlZCByZXRyeWluZy4K
UkVTVEFSVF9TPSR7QUxJT1RIX1JFU1RBUlRfVElNRU9VVDotNjB9ClNUT1BfUz0ke0FMSU9USF9T
VE9QX1RJTUVPVVQ6LTYwfQpQUk9CRV9TPSR7QUxJT1RIX1BST0JFX0JPVU5EOi0zfQpTRVNTSU9O
X1dBSVRfUz0ke0FMSU9USF9TRVNTSU9OX1dBSVQ6LTIwfQoKbG9nKCkgeyBwcmludGYgJyVzICVz
XG4nICIkKGRhdGUgJyslRiAlVCcpIiAiJCoiID4+ICIkTE9HIiAyPi9kZXYvbnVsbCB8fCB0cnVl
OyB9Cgphc191c2VyKCkgeyBzdWRvIC11ICIjJFVJRF9TRVNTSU9OIiAtSCBYREdfUlVOVElNRV9E
SVI9IiRSVU5ESVIiIFwKCURCVVNfU0VTU0lPTl9CVVNfQUREUkVTUz0idW5peDpwYXRoPSRSVU5E
SVIvYnVzIiBcCgliYXNoIC1sYyAiJHtBTElPVEhfUEFUSF9QUkVGSVg6K1BBVEg9JyRBTElPVEhf
UEFUSF9QUkVGSVg6J1wkUEFUSDsgfSR7QUxJT1RIX0NNRF9QUkVGSVg6KyRBTElPVEhfQ01EX1BS
RUZJWDsgfSQxIjsgfQoKc2lua19vaygpIHsgYXNfdXNlciAicGFjdGwgaW5mbyAyPi9kZXYvbnVs
bCB8IHNlZCAtbiAncy9eRGVmYXVsdCBTaW5rOiAvL3AnIiB8IGdyZXAgLXF4ICIkU0lOSyI7IH0K
CiMgQm91bmRlZCBNYWluUElEIHByb2JlLiBFbXB0eSBvdXRwdXQgbWVhbnMgImNvdWxkIG5vdCBh
c2siICh0aGUgYnVzIGlzIHN0aWxsCiMgZnJvemVuIGFmdGVyIHJlc3VtZSkgYW5kIG11c3QgbmV2
ZXIgYmUgcmVhZCBhcyAiZGVza3RvcCIgb3IgInNhbWUgc2Vzc2lvbiIuCnNlc3Npb25fbWFpbl9w
aWQoKSB7Cglhc191c2VyICJ0aW1lb3V0ICR7UFJPQkVfU31zIHN5c3RlbWN0bCAtLXVzZXIgc2hv
dyAtcCBNYWluUElEIC0tdmFsdWUgJFVOSVQiIDI+L2Rldi9udWxsIFwKCQl8IHNlZCAtbiAncy9e
XChbMC05XVswLTldKlwpJC9cMS9wJwp9CgojIEdhbWUgTW9kZSBwcmVzZW5jZSBjb21lcyBmcm9t
IC9wcm9jLCBuZXZlciBmcm9tIGEgRC1CdXMgY2FsbCB0aGF0IGNhbiBibG9jawojIGZvciB0ZW5z
IG9mIHNlY29uZHMgd2hpbGUgdGhlIHVzZXIgc2xpY2UgaXMgdGhhd2luZy4gVGhlIGNvbXBvc2l0
b3IncyBjb21tCiMgaXMgImdhbWVzY29wZS13bCIgb24gdGhpcyBkZXZpY2U7IHRoZSB3cmFwcGVy
IHNjcmlwdHMgYXJlICJnYW1lc2NvcGUtc2Vzc2kiLgpjb21wb3NpdG9yX3J1bm5pbmcoKSB7Cgls
b2NhbCBkIGNvbW0gcHJvY3Jvb3Q9JHtQUk9DX0RJUiUvfQoJZm9yIGQgaW4gIiRwcm9jcm9vdCIv
WzAtOV0qOyBkbwoJCVsgLWQgIiRkIiBdICYmIFsgLXIgIiRkL2NvbW0iIF0gfHwgY29udGludWUK
CQljb21tPSQoY2F0ICIkZC9jb21tIiAyPi9kZXYvbnVsbCkgfHwgY29udGludWUKCQljYXNlICIk
Y29tbSIgaW4gZ2FtZXNjb3BlfGdhbWVzY29wZS13bCkgcmV0dXJuIDAgOzsgZXNhYwoJZG9uZQoJ
cmV0dXJuIDEKfQoKYm9vdF9pZCgpIHsKCXByaW50ZiAnJXNcbicgIiR7QUxJT1RIX0JPT1RfSUQ6
LSQoY2F0IC9wcm9jL3N5cy9rZXJuZWwvcmFuZG9tL2Jvb3RfaWQgMj4vZGV2L251bGwgfHwgZWNo
byB1bmtub3duKX0iCn0KCiMgQSBsaXZlIGdhbWUgPSBhIHJlYWwgL3Byb2MgY21kbGluZSB0aGF0
IGlzIG5vdCB0aGlzIGhvb2ssIG5vdCBvdXIgcGFyZW50CiMgc2hlbGwsIGFuZCBub3QgYW5vdGhl
ciBpbnN0YW5jZSBvZiB0aGlzIGhlbHBlci4KZ2FtZV9ydW5uaW5nKCkgewoJbG9jYWwgZCBwIGMg
cmVhZGFibGU9MCBwcm9jcm9vdD0ke1BST0NfRElSJS99Cglmb3IgZCBpbiAiJHByb2Nyb290Ii9b
MC05XSo7IGRvCgkJIyBBbiB1bm1hdGNoZWQgZ2xvYiBzdGF5cyBsaXRlcmFsOyBza2lwIGFueXRo
aW5nIHRoYXQgaXMgbm90IGEKCQkjIHJlYWRhYmxlIHByb2Nlc3MgZW50cnkgaW5zdGVhZCBvZiBl
cnJvcmluZy4KCQlpZiBbICEgLWQgIiRkIiBdIHx8IFsgISAtciAiJGQvY21kbGluZSIgXTsgdGhl
biBjb250aW51ZTsgZmkKCQlwPSR7ZCMjKi99CgkJWyAiJHAiID0gIiQkIiBdICYmIGNvbnRpbnVl
CgkJWyAtbiAiJHtQUElEOi19IiBdICYmIFsgIiRwIiA9ICIkUFBJRCIgXSAmJiBjb250aW51ZQoJ
CWM9JCh0ciAnXDAnICcgJyA8ICIkZC9jbWRsaW5lIiAyPi9kZXYvbnVsbCkgfHwgY29udGludWUK
CQlyZWFkYWJsZT0kKChyZWFkYWJsZSArIDEpKQoJCWNhc2UgIiRjIiBpbiAqYWxpb3RoLWF1ZGlv
LXJlc3VtZSopIGNvbnRpbnVlIDs7IGVzYWMKCQljYXNlICIkYyIgaW4KCQkqU3RlYW1MYXVuY2gq
QXBwSWQqfCpzdGVhbWFwcHMvY29tbW9uKikgcmV0dXJuIDAgOzsKCQllc2FjCglkb25lCgkjIE5v
IGNtZGxpbmUgcmVhZGFibGUgKGhpZGVwaWQsIG5hbWVzcGFjZSk6IGRldGVjdGlvbiBmYWlsZWQg
LT4gYmUKCSMgY29uc2VydmF0aXZlIGFuZCB0cmVhdCB0aGUgc2Vzc2lvbiBhcyBidXN5LgoJWyAi
JHJlYWRhYmxlIiAtZXEgMCBdICYmIHJldHVybiAwCglyZXR1cm4gMQp9CgpyZXN0YXJ0X2F1ZGlv
KCkgewoJbG9nICJyZXN0YXJ0aW5nIHdpcmVwbHVtYmVyLCBwaXBld2lyZS1wdWxzZSwgcGlwZXdp
cmUiCglhc191c2VyICJ0aW1lb3V0ICR7UkVTVEFSVF9TfXMgc3lzdGVtY3RsIC0tdXNlciByZXN0
YXJ0IHdpcmVwbHVtYmVyLnNlcnZpY2UgcGlwZXdpcmUtcHVsc2Uuc2VydmljZSBwaXBld2lyZS5z
ZXJ2aWNlIiBcCgkJPj4gIiRMT0ciIDI+JjEgfHwgeyBsb2cgInVzZXIgc3lzdGVtY3RsIHJlc3Rh
cnQgZmFpbGVkL3RpbWVkIG91dCBhZnRlciAke1JFU1RBUlRfU31zIjsgcmV0dXJuIDE7IH0KCWxv
Y2FsIGk9MAoJdW50aWwgc2lua19vazsgZG8KCQlpPSQoKGkrMSkpCgkJWyAiJGkiIC1nZSAiJFdB
SVRfUyIgXSAmJiB7IGxvZyAiZGVmYXVsdCBzaW5rIG5vdCAkU0lOSyBhZnRlciAke1dBSVRfU31z
IjsgcmV0dXJuIDE7IH0KCQlzbGVlcCAxCglkb25lCglsb2cgImRlZmF1bHQgc2luayBpcyAkU0lO
SyIKCXJldHVybiAwCn0KCiMgU2FtZSBzZXNzaW9uID0gc2FtZSBib290IEFORCBzYW1lIHNlc3Np
b24gbWFuYWdlciBQSUQuIEEgbmV3IHNlc3Npb24gKGFmdGVyCiMgYSBzdG9wKSBnZXRzIGEgbmV3
IE1haW5QSUQsIHNvIHJlY292ZXJ5IGlzIGFsbG93ZWQgYWdhaW4gZXhhY3RseSBvbmNlLgpzZXNz
aW9uX3Rva2VuKCkgeyAgIyA8TWFpblBJRD46IHJlZnVzZSB0byBpbnZlbnQgYSBwbGFjZWhvbGRl
ciBzZXNzaW9uCglbIC1uICIkezE6LX0iIF0gJiYgWyAiJHsxOi19IiAhPSAwIF0gfHwgcmV0dXJu
IDEKCXByaW50ZiAnJXMgJXNcbicgIiQoYm9vdF9pZCkiICIkMSIKfQoKc2Vzc2lvbl9hbHJlYWR5
X2RvbmUoKSB7Cglsb2NhbCBwaWQgdG9rZW4KCVsgLXIgIiRTVEFNUCIgXSB8fCByZXR1cm4gMQoJ
cGlkPSQoc2Vzc2lvbl9tYWluX3BpZCkKCVsgLW4gIiRwaWQiIF0gfHwgcmV0dXJuIDEKCXRva2Vu
PSQoc2Vzc2lvbl90b2tlbiAiJHBpZCIpIHx8IHJldHVybiAxCglbICIkKGNhdCAiJFNUQU1QIiki
ID0gIiR0b2tlbiIgXQp9CgpzdG9wX3Nlc3Npb25fbm93KCkgewoJbG9nICJyZXN0YXJ0aW5nICRV
TklUIChDRUYgQXVkaW9TZXJ2aWNlIHJlY29ubmVjdCkiCglhc191c2VyICJ0aW1lb3V0ICR7U1RP
UF9TfXMgc3lzdGVtY3RsIC0tdXNlciBzdG9wICRVTklUIiA+PiAiJExPRyIgMj4mMSB8fCB7CgkJ
bG9nICJzZXNzaW9uIHN0b3AgZmFpbGVkL3RpbWVkIG91dCBhZnRlciAke1NUT1BfU31zIjsgcmV0
dXJuIDE7IH0KCXJtIC1mICIkUEVORElORyIKCXJldHVybiAwCn0KCiMgUG9sbCB0aGUgd2hvbGUg
Ym91bmRlZCB3aW5kb3cgZm9yIGEgTWFpblBJRCBkaWZmZXJlbnQgZnJvbSB0aGUgb2xkIG9uZS4K
IyBBIHNpbmdsZSBlYXJseSByZWFkIHN0aWxsIHNob3dpbmcgdGhlIG9sZCBQSUQgaXMgbm9ybWFs
IChzeXN0ZW1kIGhhcyBub3QKIyByZXNwYXduZWQgeWV0KTsgaXQgaXMgbm90IGEgZmFpbHVyZS4K
d2FpdF9uZXdfc2Vzc2lvbigpIHsgICMgPG9sZCBNYWluUElEPjsgcHJpbnRzIHRoZSBuZXcgUElE
IG9uIHN1Y2Nlc3MKCWxvY2FsIG9sZD0kMSBpPTAgcGlkCglbICIkU0VTU0lPTl9XQUlUX1MiID0g
MCBdICYmIHJldHVybiAwCgl3aGlsZSBbICIkaSIgLWx0ICIkU0VTU0lPTl9XQUlUX1MiIF07IGRv
CgkJcGlkPSQoc2Vzc2lvbl9tYWluX3BpZCkKCQlpZiBbIC1uICIkcGlkIiBdICYmIFsgIiRwaWQi
ICE9ICIkb2xkIiBdOyB0aGVuCgkJCXByaW50ZiAnJXNcbicgIiRwaWQiOyByZXR1cm4gMAoJCWZp
CgkJaT0kKChpKzEpKTsgc2xlZXAgMQoJZG9uZQoJbG9nICJubyBuZXcgc2Vzc2lvbiBNYWluUElE
IHdpdGhpbiAke1NFU1NJT05fV0FJVF9TfXMgKG9sZCAkb2xkKSIKCXJldHVybiAxCn0KCmRvX3Jl
c3VtZSgpIHsKCSMgQSBnYW1lIChvciB1bnJlYWRhYmxlIC9wcm9jKSBpcyBjaGVja2VkIEJFRk9S
RSB0b3VjaGluZyBhdWRpbzogcmVzdGFydGluZwoJIyBQaXBlV2lyZSB1bmRlciBhIHJ1bm5pbmcg
Z2FtZSBpcyBub3QgcHJvdmVuIGhhcm1sZXNzIGVpdGhlci4gT25seSBhCgkjIHBlbmRpbmcgbWFy
a2VyIGlzIHdyaXR0ZW47IHRoZSB1c2VyIHJlY292ZXJzIG1hbnVhbGx5IGFmdGVyd2FyZHMuCglp
ZiBnYW1lX3J1bm5pbmc7IHRoZW4KCQlsb2cgImEgZ2FtZSBsb29rcyBydW5uaW5nIChvciBkZXRl
Y3Rpb24gaXMgdW5hdmFpbGFibGUpOiBvbmx5IG1hcmtpbmcgcGVuZGluZyIKCQk6ID4gIiRQRU5E
SU5HIiAyPi9kZXYvbnVsbCB8fCB0cnVlCgkJcmV0dXJuIDAKCWZpCgkjIEF1ZGlvIGZpcnN0OiB0
aGlzIGlzIHRoZSBwcm92ZW4gcmVjb3ZlcnkgYW5kIG11c3Qgbm90IHdhaXQgb24gRC1CdXMKCSMg
dXNlci1zY29wZSByZWFkaW5lc3MuIEdhbWUgTW9kZSBkZXRlY3Rpb24gdGhlbiBjb21lcyBmcm9t
IC9wcm9jLgoJcmVzdGFydF9hdWRpbyB8fCB7IGxvZyAiYXVkaW8gc3RhY2sgbm90IGhlYWx0aHk7
IG5vdCB0b3VjaGluZyB0aGUgc2Vzc2lvbiI7IHJldHVybiAxOyB9CgkjIEdhbWUgTW9kZSBkZXRl
Y3Rpb24gY29tZXMgZnJvbSAvcHJvYywgbmV2ZXIgZnJvbSBhIGJsb2NraW5nIEQtQnVzIGNhbGwu
CglpZiAhIGNvbXBvc2l0b3JfcnVubmluZzsgdGhlbgoJCWxvZyAiZGVza3RvcCBtb2RlIChubyBn
YW1lc2NvcGUgcHJvY2Vzcyk6IGF1ZGlvIHJlc3RvcmVkLCBzZXNzaW9uIHVudG91Y2hlZCIKCQly
ZXR1cm4gMAoJZmkKCWlmIHNlc3Npb25fYWxyZWFkeV9kb25lOyB0aGVuCgkJbG9nICJzZXNzaW9u
IGFscmVhZHkgcmVjb3ZlcmVkIGluIHRoaXMgc2Vzc2lvbjsgbm90IHN0b3BwaW5nIGFnYWluIgoJ
CXJldHVybiAwCglmaQoJIyBSZWNvcmQgdGhlIHRva2VuIEJFRk9SRSB0aGUgc3RvcDogdGhlIHN0
b3Aga2lsbHMgdGhpcyBzZXNzaW9uLCBzbyB0aGUKCSMgcGlkIG11c3QgYmUgY2FwdHVyZWQgd2hp
bGUgaXQgc3RpbGwgcnVucy4gV2l0aG91dCBhIFBJRCB3ZSBjYW5ub3QgdGVsbAoJIyBzZXNzaW9u
cyBhcGFydCwgc28gd2UgZG8gbm90IHN0b3AgYXQgYWxsLgoJb2xkX3BpZD0kKHNlc3Npb25fbWFp
bl9waWQpCgl0b2tlbj0kKHNlc3Npb25fdG9rZW4gIiRvbGRfcGlkIikgfHwgewoJCWxvZyAiY2Fu
bm90IHJlYWQgdGhlIHNlc3Npb24gTWFpblBJRDsgbm90IHN0b3BwaW5nIChhdm9pZHMgYSBzdG9w
IGxvb3ApIgoJCXJldHVybiAwCgl9CgkjIE9ubHkgYSB2YWxpZCB0b2tlbiByZWFjaGVzIHRoZSBz
dGFtcDogdGhlIHdyaXRlIGhhcHBlbnMgYWZ0ZXIgdGhlIGNoZWNrLAoJIyBzbyBhIGZhaWxlZCBs
b29rdXAgY2Fubm90IGxlYXZlIGEgcGxhY2Vob2xkZXIgYmVoaW5kLgoJdG1wPSQobWt0ZW1wICIk
U1RBTVAuWFhYWFhYIiAyPi9kZXYvbnVsbCkgJiYgcHJpbnRmICclc1xuJyAiJHRva2VuIiA+ICIk
dG1wIiBcCgkJJiYgbXYgLWYgIiR0bXAiICIkU1RBTVAiIDI+L2Rldi9udWxsIHx8IHRydWUKCXN0
b3Bfc2Vzc2lvbl9ub3cKCXdhaXRfbmV3X3Nlc3Npb24gIiRvbGRfcGlkIgp9CgptYW51YWxfcmVz
dGFydCgpIHsKCWlmIGdhbWVfcnVubmluZzsgdGhlbgoJCWxvZyAibWFudWFsOiBhIGdhbWUgbG9v
a3MgcnVubmluZzsgcmVmdXNpbmcgdG8gaW50ZXJydXB0IChjbG9zZSBpdCBmaXJzdCkiCgkJZWNo
byAicmVmdXNpbmc6IGEgZ2FtZSBpcyBydW5uaW5nOyBjbG9zZSBpdCBhbmQgcmV0cnkiID4mMgoJ
CXJldHVybiAxCglmaQoJaWYgISBjb21wb3NpdG9yX3J1bm5pbmc7IHRoZW4KCQlsb2cgIm1hbnVh
bDogbm8gZ2FtZXNjb3BlIHByb2Nlc3M7IG5vdGhpbmcgdG8gcmVjb25uZWN0IgoJCXJldHVybiAw
CglmaQoJcmVzdGFydF9hdWRpbyB8fCB7IGxvZyAibWFudWFsOiBhdWRpbyBzdGFjayBub3QgaGVh
bHRoeSI7IHJldHVybiAxOyB9CgkjIFNhbWUgZ3VhcmQgYXMgdGhlIGF1dG9tYXRpYyBwYXRoOiB3
aXRob3V0IGEgcmVhZGFibGUgTWFpblBJRCBhIHN0b3AKCSMgY291bGQgbm90IGJlIHRvbGQgYXBh
cnQgZnJvbSB0aGUgcHJldmlvdXMgc2Vzc2lvbi4KCWlmICEgc2Vzc2lvbl9tYWluX3BpZCA+L2Rl
di9udWxsIDI+JjEgfHwgWyAteiAiJChzZXNzaW9uX21haW5fcGlkKSIgXTsgdGhlbgoJCWxvZyAi
bWFudWFsOiBjYW5ub3QgcmVhZCB0aGUgc2Vzc2lvbiBNYWluUElEIChidXMgbm90IHJlYWR5KTsg
bm90IHN0b3BwaW5nIgoJCWVjaG8gImNhbm5vdCByZWFkIHNlc3Npb24gTWFpblBJRDsgbm90IHJl
c3RhcnRpbmcgdGhlIHNlc3Npb24iID4mMgoJCXJldHVybiAxCglmaQoJbG9nICJtYW51YWw6IGZv
cmNpbmcgQ0VGIHJlY29ubmVjdCBmb3IgdGhlIGN1cnJlbnQgc2Vzc2lvbiIKCWFzX3VzZXIgInRp
bWVvdXQgJHtTVE9QX1N9cyBzeXN0ZW1jdGwgLS11c2VyIHN0b3AgJFVOSVQiID4+ICIkTE9HIiAy
PiYxIHx8IHsKCQlsb2cgIm1hbnVhbDogc2Vzc2lvbiBzdG9wIGZhaWxlZC90aW1lZCBvdXQgYWZ0
ZXIgJHtTVE9QX1N9cyI7IHJldHVybiAxOyB9CglybSAtZiAiJFBFTkRJTkciCglyZXR1cm4gMAp9
CgptYWluKCkgewoJbG9jYWwgcmM9MAoJWyAtZCAiJFJVTkRJUiIgXSB8fCB7IGxvZyAibm8gJFJV
TkRJUjsgc2Vzc2lvbiBub3QgdXAsIG5vdGhpbmcgdG8gZG8iOyBleGl0IDA7IH0KCW1rZGlyIC1w
ICIkKGRpcm5hbWUgIiRMT0NLIikiIDI+L2Rldi9udWxsIHx8IHRydWUKCWV4ZWMgOT4iJExPQ0si
IHx8IGV4aXQgMAoJZmxvY2sgLW4gOSB8fCB7IGxvZyAiYW5vdGhlciByZXN1bWUgYWxyZWFkeSBy
dW5uaW5nIjsgZXhpdCAwOyB9CgljYXNlICIkezE6LX0iIGluCglwb3N0KQoJCWxvZyAiPT09IHJl
c3VtZSA9PT0iCgkJZG9fcmVzdW1lCgkJbG9nICI9PT0gcmVzdW1lIGRvbmUgPT09IgoJCTs7Cgkt
LXJlc3RhcnQtc2Vzc2lvbikKCQlsb2cgIj09PSBtYW51YWwgcmVzdGFydC1zZXNzaW9uID09PSIK
CQltYW51YWxfcmVzdGFydDsgcmM9JD8KCQlsb2cgIj09PSBtYW51YWwgZG9uZSAocmM9JHJjKSA9
PT0iCgkJZXhpdCAiJHJjIgoJCTs7CgkqKQoJCSMgcHJlIG9yIGFueXRoaW5nIGVsc2U6IHN5c3Rl
bS1zbGVlcCBtYXkgY2FsbCBwcmU7IGRvIG5vdGhpbmcKCQk7OwoJZXNhYwp9CgptYWluICIkQCIK
AUDIORESUME_B64
chmod 0755 /usr/lib/systemd/system-sleep/alioth-audio-resume
install -m 0755 /usr/lib/systemd/system-sleep/alioth-audio-resume /usr/bin/alioth-audio-resume

echo "==> alioth device fixes done"
