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
# 5. Game Mode rotation: output *and* touch input
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
# ---------------------------------------------------------------------------
cat >> /usr/share/gamescope-session-plus/device-quirks <<'QUIRK'

# Xiaomi Redmi K40 / POCO F3 (alioth, SM8250): portrait 1080x2400 AMOLED
# (120/90 Hz, no 60 Hz mode). Game Mode is landscape, so rotate the output.
if [[ "$SYS_ID" == *alioth* ]]; then
  PANEL_TYPE=internal
  ORIENTATION=left
fi
QUIRK

cat > /usr/lib/udev/rules.d/61-alioth-touch-rotation.rules <<'TOUCH'
# alioth: the FT8756 reports portrait coordinates while Game Mode presents a
# rotated 2400x1080 output that gamescope does not apply to touch input.
ATTRS{name}=="Focaltech FT8756 Touchscreen", ENV{LIBINPUT_CALIBRATION_MATRIX}="0 -1 1 1 0 0 0 0 1"
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

echo "==> alioth device fixes done"
