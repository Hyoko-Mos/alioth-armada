# alioth-armada — Redmi K40 / POCO F3 (alioth) port for Armada OS

Device bring-up, kernel patches, and the complete speaker investigation for
running [Armada OS](https://github.com/armada-os/armada) (the SteamOS-like ARM
distro) on the Xiaomi Redmi K40 / POCO F3 (codename **alioth**, Snapdragon 870 /
SM8250).

Everything here is **GPL-2.0-or-later**, matching Armada's own licensing.
**No proprietary blobs are shipped in this repo** — firmware is extracted from
your own device (see [docs/FIRMWARE.md](docs/FIRMWARE.md)).

## Status

| Subsystem | State |
|---|---|
| Boot / display / touch | ✅ working (touch matrix fix included) |
| GPU (a650 + zap shader) | ✅ working |
| Wi-Fi (ath11k QCA6390) / BT (hci_qca) | ✅ working |
| USB NCM networking (SSH over `fe80::1`) | ✅ working |
| Gamepad (xpad) | ✅ working |
| Sensors (SLPI) | ⚠️ crash-loop masked by service |
| **Speakers (2× CS35L41 over TERT MI2S)** | ✅ **working — audible, volume control, survives reboot** |
| Headphone jack / USB-C audio | untested / should work (`SND_USB_AUDIO=m`) |

## The speaker fix, in one paragraph

The amps' protection firmware defaults its PLL to a **12.288 MHz** reference
while the ADSP actually drives `TER_MI2S_IBIT` at **1.536 MHz** — an 8×
mismatch. Every software layer in between looks perfectly healthy: DAPM powers
up, `PWR_CTRL2` reads `0x3721` (the firmware raised `AMP_EN` and the boost
itself), no error bits anywhere, the PLL even reports locked — and the output
stage stays completely silent. Retargeting the PLL to the real BCLK at stream
start makes sound come out immediately. Full evidence trail:
[docs/AUDIO-INVESTIGATION.md](docs/AUDIO-INVESTIGATION.md).

## Repository layout

```
device/            image-build glue (Armada build_files, alioth variant)
  52-alioth-device-fixes.sh    device quirks installed at image build
  ucm/                         UCM2 profile for the xiaomi-alioth card
kernel/
  patches/          7 patches on top of nikroks/alioth (6.15.1)
  build.sh          cross-compile wrapper (applies patches automatically)
  BUILD.env         repo / branch / config selection
  alioth-armada.config.overrides
scripts/
  pin-probe.py      main-TLMM mi2s2 pad readback probe (/dev/mem)
  amp-regs.py       raw-i2c CS35L41 power-up sequence, bypassing the driver
  dtbo_dump.py      decode vendor dtbo partitions to text
docs/
  AUDIO-INVESTIGATION.md   the full seven-round speaker saga
  FIRMWARE.md              what to extract from your own device
  dtbo-tdm.txt, dtbo-amps.txt   decoded vendor DTBO audio nodes
```

## Kernel patches

`kernel/build.sh` applies these automatically before configuring.

| # | Patch | Purpose |
|---|---|---|
| 0001 | `q6afe`: wait for DSP audio services before populating children | Boot race: probing before the ADSP services are up makes LPASS core HW votes fail (`0x100f4` → status `0x16`). Signature matches [Nova-Deck/os-build#94](https://github.com/Nova-Deck/os-build/issues/94). |
| 0002 | `q6core`: fix the ADSP readiness check | A failed `AVCS_CMD_ADSP_EVENT_GET_STATE` used to be read as "DSP up". |
| 0003 | `q6asm-dai`: unregister the component on remove | Lets the ADSP restart path re-register cleanly. |
| 0004 | `q6routing`: unregister the component on remove | Same, for the routing component. |
| 0005 | `cs35l41-lib`: RESUME/PAUSE mailbox instead of PUP_DONE polling | This B2 spk-prot firmware never raises `PUP_DONE` (bit 24); power-up completion shows as bit 22 within 0.4 ms. Waiting for bit 24 always times out → false `-110` → DAPM rollback. |
| 0006 | `sm8250`: retarget the amp PLL + pin the frontend format | **(the actual fix)** Sets `CS35L41_CLKID_SCLK` @ 1 536 000 on each codec DAI at stream start, and constrains the q6asm frontend to 2ch / 48 kHz / `S16_LE` so PipeWire builds a usable sink instead of an 8-channel `s24-32le` one. |
| 0007 | DTS: alioth TERT MI2S audio | TERT MI2S RX/TX ports, main-TLMM `mi2s2` pins (gpio133/135/137), `gpio134` data0, speaker + capture DAI links. |

The patches apply cleanly (`--fuzz=0`) on a pristine clone of the
`nikroks/alioth` branch of [mainlining/linux](https://github.com/mainlining/linux)
(6.15.1); the resulting tree is byte-identical to the one that was built and
flashed to the device.

## Building

```bash
# Cross-compile on x86_64 (needs gcc-aarch64-linux-gnu):
KERNEL_SRC=/path/to/pristine/linux JOBS=12 bash kernel/build.sh out/
```

Without `KERNEL_SRC` the script clones `mainlining/linux` `nikroks/alioth`
itself and applies `kernel/patches/*.patch`. Output is
`Image.gz-dtb_alioth` plus `armada-kernel-<ver>.tar.zst` (modules).

**The audio driver is a module.** If you change audio code, flashing a new
`boot_b` is not enough — copy the rebuilt `.ko` files into
`/usr/lib/modules/<ver>/` on the running system and run `depmod -a`. Note that
`cat file | ssh "cat > file"` silently produces empty files; use `scp -O`.

## Talking to the device

The device exposes a USB NCM gadget; it is `fe80::1` on the host-side
interface. **The interface index changes between boots**, so resolve it rather
than hard-coding a name:

```bash
for f in /sys/class/net/eth*; do
  ping6 -c1 -W1 "fe80::1%$(basename "$f")" >/dev/null 2>&1 && IF=$(basename "$f")
done
ssh armada@fe80::1%$IF
```

If the host cannot reach it while Windows can, the gadget interface was
renumbered — check from the host side first.

## Volume semantics (easy trap)

`Digital PCM Volume` is `SOC_SINGLE_SX_TLV`: the ALSA control value is the
register code minus **1231**, in an **11-bit** field.

| Control value | Register code | Result |
|---|---|---|
| **816** | 2047 | **0 dB** |
| 913 (the advertised max) | wraps to 96 | near-silence |
| 0 | — | mute |

The UCM profile pins it at 816. Setting 913 — which looks like "maximum" —
actually mutes the amp.

## Firmware

This repo ships **no firmware**. See [docs/FIRMWARE.md](docs/FIRMWARE.md) for
exactly what to extract from your own device.

## Credits

- [Armada OS](https://github.com/armada-os/armada) — the base distro (GPL-2.0-or-later)
- [mainlining/linux](https://github.com/mainlining/linux) `nikroks/alioth` branch —
  the 6.15.1 alioth kernel and DTS
- [xiongnemo/hakios-alioth](https://github.com/xiongnemo/hakios-alioth) — the
  CS35L41 bring-up recipe (shared reset, I2C addresses, boost parameters,
  mailbox RESUME, PLL code `0x1b` for 1.536 MHz) and the board data that
  pointed at TERT MI2S on the main-TLMM `mi2s2` pins
- [Nova-Deck/os-build#94](https://github.com/Nova-Deck/os-build/issues/94) —
  the boot-race write-up that matched our `0x100f4`/`0x16` signature
- The QDSP6/ALSA upstream maintainers whose code we read far too deeply
