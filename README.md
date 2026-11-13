# alioth-armada — Redmi K40 / POCO F3 (alioth) port for Armada OS

Device bring-up, kernel patches, and a full audio investigation for running
[Armada OS](https://github.com/armada-os/armada) (the SteamOS-like ARM distro)
on the Xiaomi Redmi K40 / POCO F3 (codename **alioth**, Snapdragon 870 /
SM8250).

Everything here is **GPL-2.0-or-later**, matching Armada's own licensing.
**No proprietary blobs are shipped in this repo** — firmware is extracted
from your own device (see `scripts/`).

## Status

| Subsystem | State |
|---|---|
| Boot / display / touch | ✅ working (touch matrix fix included) |
| GPU (a650 + zap shader) | ✅ working |
| Wi-Fi (ath11k QCA6390) / BT (hci_qca) | ✅ working |
| USB NCM networking (SSH over fe80::1%usb0) | ✅ working |
| Gamepad (xpad) | ✅ working |
| Sensors (SLPI) | ⚠️ crash-loop masked by service |
| **Speakers (cs35l41 ×2 over QUAT TDM)** | ❌ **no sound — see docs/AUDIO-INVESTIGATION.md** |
| Headphone jack / USB-C audio | untested / should work (SND_USB_AUDIO=m) |

## Repository layout

```
device/            image-build glue (from the Armada build_files, alioth variant)
  52-alioth-device-fixes.sh    device quirks installed at image build
  ucm/                          UCM2 profile for the xiaomi-alioth card
kernel/
  patches/          4 patches on top of nikroks/alioth (6.15.1)
  build.sh          cross-compile wrapper (aarch64-linux-gnu-)
  alioth-armada.config.overrides
scripts/            diagnostic + extraction tools
  pin-probe3.py     LPASS LPI pin pad readback probe (/dev/mem)
  pin-scan.py       scan all 14 LPI pins for activity
  dtbo_dump.py      dump vendor dtbo partitions to text
docs/
  AUDIO-INVESTIGATION.md      the full four-round speaker saga
  dtbo-tdm.txt / dtbo-amps.txt   decoded vendor DTBO audio nodes
```

## Kernel patches

1. **`0001` q6afe: wait for DSP audio services before populating children** —
   fixes a boot race where `q6afe` probes before the ADSP audio services are
   up; the ADSP then rejects LPASS core HW votes (`0x100f4` → status `0x16`)
   and the LPI pinctrl driver never gets its clocks → no sound card on a
   fresh boot. (Same root cause as Nova-Deck/os-build#94; independently
   re-derived and re-implemented here for 6.15.1.)
2. **`0002` q6core: fix the ADSP readiness check** — a failed
   `AVCS_CMD_ADSP_EVENT_GET_STATE` response was misread as "DSP up".
3. **`0003` sm8250: alioth QUAT TDM speaker link** — machine-driver route
   for cs35l41 RCV/LCV on `QUATERNARY_TDM_RX_0` @ 1.536 MHz BCLK.
4. **`0004` DTS: alioth audio pins and TDM port** — LPI gpio0/1/2 func2
   (qua_mi2s pins, shared with the QUAT TDM block) + TDM port parameters
   mirroring the vendor DTBO.

Patches apply on top of the `nikroks/alioth` branch of
[mainlining/linux](https://github.com/mainlining/linux) (6.15.1).

## The speaker problem — help wanted

The short version: **the entire software chain works** — PipeWire → UCM →
ALSA → ASoC DAPM → cs35l41 codec PRE_PMU — and the ADSP firmware *accepts*
every configuration command (port start, clock votes, routing). Yet the QUAT
TDM/MI2S block never outputs a physical BCLK: all three LPI pads read a flat
0 with zero transitions during playback, the amp PLL never locks, and
`Enable()` times out with `-110`.

Evidence, decode logs, and the elimination matrix are in
**`docs/AUDIO-INVESTIGATION.md`**. The leading hypothesis is that the stock
`adsp.mbn` expects ACDB calibration (uploaded by Android's vendor audio HAL
over ADM ioctls) before it enables the output block — something mainline
Linux has no userspace for. If you have ideas — q6afe internals, AVS/ACDB
knowledge, or a similar board you got sound out of — please open an issue.

## Firmware

This repo ships **no firmware**. Extract it from your own device/backup:

```
adsp.mbn, cdsp.mbn, slpi.mbn, venus.mbn, a650_zap.mbn,
ath11k QCA6390 firmware, cirrus/cs35l41-dsp1-spk-prot.wmfw,
acdbdata/ (Forte_*.acdb)
```

These live under `qcom/sm8250/xiaomi/alioth/` and `usr/share/qcom/` in a
previous Armada rootfs, or can be pulled from a rooted stock-ROM device.
(We could not extract them from Xiaomi's line-flash `super.img`: it uses the
encrypted GDLA container format.)

## Credits

- [Armada OS](https://github.com/armada-os/armada) — the base distro (GPL-2.0-or-later)
- [mainlining/linux](https://github.com/mainlining/linux) `nikroks/alioth` branch —
  the 6.15.1 alioth kernel and DTS
- [Nova-Deck/os-build#94](https://github.com/Nova-Deck/os-build/issues/94) —
  the boot-race write-up that matched our `0x100f4`/`0x16` signature
- The QDSP6/ALSA upstream maintainers whose code we read far too deeply