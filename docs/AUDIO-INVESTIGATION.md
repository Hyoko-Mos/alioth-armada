# The alioth speaker investigation — four rounds, one flat pad

This documents a complete, evidence-driven investigation into why the
speakers (2× Cirrus Logic CS35L41, i2c 3-0040/3-0041) stay silent on
mainline Linux (6.15.1) on the Xiaomi alioth (Redmi K40 / POCO F3,
SM8250), with everything else on the audio stack working.

**TL;DR** — the software chain is fully functional end-to-end, the ADSP
accepts every command, but the LPASS QUAT TDM/MI2S output block never
produces a physical BCLK. We believe the missing piece is ACDB
calibration data that Android's vendor audio HAL normally uploads to the
DSP, for which mainline has no userspace. **Help wanted.**

## Hardware facts (decoded from the vendor DTBO)

The vendor DTBO (decoded in `dtbo-tdm.txt`, `dtbo-amps.txt` via
`scripts/dtbo_dump.py`) says:

- Speaker path: **QUAT TDM** group 0x9130, port **0x9030**
  (`QUATERNARY_TDM_RX_0`), `clk-rate = 0x177000` (**1536000 Hz**),
  `clk-internal = 1`, `sync-mode = 1` (long sync), `sync-src = 1`
  (internal), `invert-sync = 1`, `data-delay = 1`.
- Pins: **LPASS LPI gpio0/1/2, function 2** — named `qua_mi2s_sck/ws/data`
  in mainline's LPI pinctrl driver. drive-strength 8, active state
  output-high. (Yes: the TDM block uses the "mi2s" pin group — on SM8250
  the QUAT MI2S and QUAT TDM share the LPI pins.)
- Amps: cs35l41 at i2c bus 3, addresses 0x40 (RCV, speaker-name-prefix
  "RCV") and 0x41 (LCV, `right-channel-amp`). Boost params: 4000 mA /
  1000 nH / 15 µF — identical in our DTS.

## What works (verified on-device)

1. **Sound card registers on every boot** after our q6afe/q6core race
   patches (0001/0002). Before them, a fresh boot had *no sound card*:
   `q6afe` probed before the ADSP audio services were up, its LPASS core
   HW vote (`opcode 0x100f4`) was rejected with status `0x16`, the LPI
   pinctrl driver (`33c0000.pinctrl`) never got its `core`/`audio`
   clocks, and `sound` stayed deferred forever. Signature identical to
   [Nova-Deck/os-build#94](https://github.com/Nova-Deck/os-build/issues/94).
2. **PipeWire → UCM → ALSA → DAPM → codec**: we ship a UCM2 profile
   (`device/ucm/`) for the `xiaomi-alioth` card; with WirePlumber's
   forced-ACP default flipped off, `paplay` reaches a RUNNING sink and
   the stream flows through `MultiMedia1 → QUAT_TDM_RX_0`.
3. **Codec side**: cs35l41 DAI probes, its DSP firmware
   (`cs35l41-dsp1-spk-prot.wmfw`, v0.58.0) loads into both amps, the
   codec driver enables the amp (`GLOBAL_EN=1`, `PLL_EN=1`, PLL source
   SCLK) and then waits for power-up — `Enable(1) failed: -110` is the
   PUP_DONE timeout, not a probe failure.
4. **ADSP accepts all our commands**: port `DEVICE_START (0x100e5)` on
   0x9030 returns success (after the race fix), clock votes on
   `LPASS_CLK_ID_QUAD_TDM_IBIT` and `QUAD_MI2S_IBIT` return 0 at
   1.536 MHz, MACRO/DCODEC core HW votes succeed, routing mixer accepts
   the connection.

## The smoking gun

`scripts/pin-probe3.py` reads the **pad input** of LPI gpio0/1/2 via
`/dev/mem` (keeping the func2 mux intact). During playback:

```
SCLK pin0 cfg=0x00000ec8 func=2 OE=1 ones=0/20000 transitions=0
WS   pin1 cfg=0x00000ec8 func=2 OE=1 ones=0/20000 transitions=0
DATA pin2 cfg=0x00000ec8 func=2 OE=1 ones=0/20000 transitions=0
```

Zero toggles on SCLK, WS **and** DATA. `pin-scan.py` confirms **no LPI
pin of all 14** shows any activity during playback. The pad config
register (0xec8 = func2, OE, 8 mA drive) is exactly what the DTS asked
for. The pinmux is applied (debugfs pinmux-pins shows owner `sound`).

In other words: **the physical output block is never enabled, even
though the ADSP says "port started".**

## The elimination matrix

| Hypothesis | Test | Result |
|---|---|---|
| Driver differs from mainline | 3-way diff vs torvalds + nikroks | identical INT_BOOST path; no PLL_LOCK refactor exists anywhere (the "mainline refactor" theory was wrong) |
| Boost DT params wrong | vs vendor DTBO | identical (4000 mA / 1000 nH / 15 µF) |
| Wrong port (TDM vs MI2S) | built & flashed both | same symptom; pins are shared |
| Wrong sync-mode | tried 0 and 1 (vendor value) | same symptom |
| Wrong BCLK rate | vote 12.288 MHz vs 1.536 MHz | **12.288 MHz → ADSP EBADPARAM; 1.536 MHz → accepted. Vendor DTBO value 1536000 is the only legal one — evidence the ADSP parses our votes** |
| Wrong clock attribute | COUPLE_NO / INVERT_COUPLE_NO / couple | INVERT on TDM rejected (`-22`), COUPLE accepted, no output either way |
| Missing core HW votes | extra MACRO/DCODEC votes | accepted (ret=0), no output |
| Boot race left DSP wedged | full remoteproc stop/start, driver unbind/rebind | card recovers each time; pins still dead |
| Wrong codec fmt | NB_NF\|DSP_A vs IB_NF\|DSP_B | IB_NF rejected by cs35l41 driver |
| Wrong firmware | sha256 vs known-good copy | identical to the device-validated adsp.mbn (not the RB5 generic one) |
| Userspace routing | PipeWire/UCM/paplay + direct speaker-test | both reach the codec; same failure |

## The leading theory: missing ACDB upload

Qualcomm's ADSP audio needs **calibration/topology data (ACDB)** pushed
to it by the Android vendor audio HAL over ADM ioctls. On this device
the data exists — `acdbdata/Forte/Forte_*.acdb` (we have it deployed at
`/usr/share/qcom/sm8250/Xiaomi/alioth/acdbdata/`) — but mainline Linux
has **no userspace that uploads it**, and the stock `adsp.mbn` seems to
keep the LPASS output blocks gated until then.

Consistent observations:

- The ADSP accepts the clock vote only at the vendor rate (it parses,
  but something upstream of the pad never turns on).
- The port "starts" without error, yet no LPI pin moves — as if the
  AFE-to-LPASS-hardware plumbing the ADSP would normally configure from
  ACDB data is simply absent.
- Nova-Deck's issue #94 (RB5 board, same ADSP generation) shows the same
  "commands accepted, nothing happens" class of failure — theirs was
  timing; ours persists after timing was fixed, which points at data.

## What we could not do

- Extract ACDB/vendor from Xiaomi's line-flash `super.img`: it uses the
  **GDLA** container (`gDla4` magic + a byte-shuffled `ALP0`-variant LP
  header); payload regions are high-entropy with no zstd/gzip/erofs/ext4
  structure — effectively encrypted. (Doesn't matter — the ACDB files
  are extractable from a rooted stock device or the Armada rootfs.)
- Write a userspace ACDB uploader: the ADM ioctl protocol is not
  documented; it would need reversing CodeLinaro's audio HAL. This is
  where help would be most valuable.

## How to reproduce / instrument

- Pin probe (needs root, /dev/mem):
  `python3 scripts/pin-probe3.py playback` while a stream runs.
- Amp registers:
  `cat /sys/kernel/debug/regmap/3-0040/registers` (watch `0x2014`
  GLOBAL_EN, `0x10010` PUP_DONE bit24, `0x10018` PLL_LOCK bit1).
- Clock votes: watch `dmesg | grep qcom-q6afe` during stream start.
- Full logs from our runs are summarized in the repository history of
  this file; the tooling that produced them is in `scripts/`.

## Workaround

USB-C audio (`CONFIG_SND_USB_AUDIO=m`) and Bluetooth (hci_qca) work; a
USB-C DAC is the practical sound solution until the ACDB question is
solved.