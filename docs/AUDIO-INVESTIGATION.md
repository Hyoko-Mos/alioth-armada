# The alioth speaker investigation — seven rounds, one PLL

How two Cirrus Logic CS35L41 amplifiers (i2c 3-0040 / 3-0041) on the Xiaomi
alioth (Redmi K40 / POCO F3, SM8250) went from "the entire software chain looks
healthy but nothing comes out" to **audible speakers with working volume control
that survive a reboot**.

If you read only one paragraph: the amp protection firmware defaults its PLL
reference to **12.288 MHz**, the ADSP drives `TER_MI2S_IBIT` at **1.536 MHz**,
and that 8× mismatch silences the output stage while leaving every readable
register looking perfect.

---

## Hardware (decoded from the vendor DTBO)

`scripts/dtbo_dump.py` → `docs/dtbo-tdm.txt`, `docs/dtbo-amps.txt`.

- **Amps**: CS35L41 on i2c bus 3, `0x40` (RCV, `sound-name-prefix "RCV"`) and
  `0x41` (LCV, `cirrus,right-channel-amp`). Shared reset on gpio114, IRQs on
  gpio113 / gpio112. Boost 4000 mA / 1000 nH / 15 µF, `boost-type = 0`
  (INT_BOOST).
- **Vendor DTBO port**: `QUAT TDM` group 0x9130 / port 0x9030 at
  `clk-rate 0x177000` (1 536 000 Hz). That is *not* the port that actually
  works here — see "the port we ended up on".
- **Pins (working path)**: main TLMM `mi2s2` — gpio133 (sck), gpio135 (ws),
  gpio137 (data1, mux 3). `gpio134` is `mi2s2_data0` and is an **ADSP output**
  (OE=1); it is not a usable CPU capture input.

## What was checked and eliminated

Verified on the device, mostly by poking registers over raw i2c and sampling
pads through `/dev/mem`.

| Hypothesis | Test | Result |
|---|---|---|
| Sound card does not register | boot logs | Registers every boot after patches 0001/0002 |
| Userspace never reaches the codec | PipeWire / UCM / `paplay` / direct `speaker-test` | All reach the codec; DAPM powers the chain |
| DAPM chain broken | `debugfs/asoc/.../dapm` | `AMP Playback`, `ASPRX1`, `DSP1`, `PCM Source`, `CLASS H`, `Main AMP`, `SPK` — all **On** |
| Amp never enabled | `PWR_CTRL1/2/3` during playback | `0x2014=0x1`, `0x2018=0x3721` — the firmware raised `AMP_EN` and the boost itself after a mailbox RESUME |
| Digital mute | `0x6000`, `0x2024` | `0x6000=0xbffc` (≈0 dB), `0x2024=0` (unmuted) |
| Wrong DAC source | `0x4C00` | `0x32` = protection DSP, as intended |
| Protection DSP faulted | `0x6418`, `0x640C`, `0x6410` | All zero |
| BCLK missing | main-TLMM pad probe | SCK / WS / D1 all toggle during playback |
| Wrong firmware | generic vs revb2 vendor | revb2 extracted from the vendor partition and loaded fine — same result |
| `PUP_DONE` never set | raw i2c `IRQ1_STATUS1` | True for this firmware, but **not the cause** — power-up completes via bit 22 and the RESUME mailbox; patch 0005 handles it |
| Digital volume | ALSA control | Default 0 = MUTE; max 913 **overflows** to code 96. Real 0 dB is **816**. A genuine second bug, but fixing it alone produced no sound |

Two red herrings cost the most time:

1. **Digital volume.** `SOC_SINGLE_SX_TLV` with `min=0x4CF`, `max=0x391`
   overflows an 11-bit field: control value 913 (the advertised maximum) wraps
   to register code 96, which is essentially muted. The useful value is 816.
2. **VBST capture.** We built an entire capture path
   (`TERTIARY_MI2S_TX` + `gpio134` + a `Tertiary MI2S Capture` DAI link) to
   measure boost voltage and got exact zeros — because `gpio134` is a *data0
   output* driven by the ADSP, never an input.

## The discovery

While dumping clock registers mid-playback:

```
0x2C04 (PLL_CLK_CTRL) = 0x670   -> REFCLK_FREQ field = 0x33 = 12 288 000 Hz
```

The actual bit clock is 1 536 000 Hz. Writing that register as `0x370`
(source = SCLK, `REFCLK_FREQ = 0x1b` = 1 536 000 Hz) **during** a stream made
sound appear instantly, reproducibly, twice.

Two follow-ups pinned down the fix:

- The PLL value is written once by the protection firmware at boot and is **not**
  re-written when a stream starts, so setting it at stream start is stable —
  verified by sampling the register across playback start.
- The plain `cs35l41_component_set_sysclk()` sequence is sufficient; an extra
  "PLL enable" bit is not needed (also verified audible).

## The fix

`kernel/patches/0006-sm8250-cs35l41-audio.patch`:

```c
case TERTIARY_MI2S_RX:
        ...
        for_each_rtd_codec_dais(rtd, j, codec_dai) {
                ret = snd_soc_component_set_sysclk(codec_dai->component,
                                                   CS35L41_CLKID_SCLK, 0,
                                                   MI2S_BCLK_RATE,   /* 1536000 */
                                                   SNDRV_PCM_STREAM_PLAYBACK);
                ...
        }
```

Plus a frontend constraint (`sm8250_fe_startup`): 2 channels, 48 kHz,
`S16_LE`. Without it the q6asm frontend advertises 1–8 channels and PipeWire
negotiates an `s24-32le 8ch` sink, which never matched the hardware path — the
desktop path was silent **and** the volume keys did nothing. With the
constraint the sink becomes `s16le 2ch 48000Hz` and PipeWire's volume works.

## The port we ended up on

Four earlier rounds tried, in order: TERT TDM on LPASS LPI pins, QUAT TDM on
LPI pins, TERT TDM on LPI `i2s2` pins, and finally **TERT MI2S on main-TLMM
`mi2s2` pins** (gpio133/135/137) — which is what
[xiongnemo/hakios-alioth](https://github.com/xiongnemo/hakios-alioth) uses on
this board. Only that pin group produces a real BCLK; the LPI pin groups never
moved at all. The vendor DTBO's `QUAT TDM` port and the working `TERT MI2S`
port disagree — trust the working one.

## Reproducing the diagnostics

- PLL register: `0x2C04` on each amp over i2c — `(value >> 5) & 0x3f` is the
  reference-clock code, `0x1b` = 1 536 000 Hz.
- Any register: the scripts use raw `I2C_SLAVE_FORCE` + `I2C_RDWR` ioctls
  because the kernel driver owns the address.
- Pads: `scripts/pin-probe.py` reads main-TLMM `0x0f100000`, 0x1000 stride.
- DAPM: `cat /sys/kernel/debug/asoc/xiaomi-alioth/cs35l41.3-0040/dapm/*`

**Test with intermittent beeps, not a continuous sine.** A continuous tone is
easy to confuse with the amp powering up and down; beeps with gaps are
unambiguous:

```bash
python3 - <<'EOF'
import wave, struct, math
rate = 48000; n = 5
beep = [struct.pack("<hh", v, v)
        for v in [int(11000 * math.sin(2*math.pi*600*i/rate)) for i in range(rate)]]
gap  = [struct.pack("<hh", 0, 0)] * int(rate * 0.7)
w = wave.open("/tmp/beeps.wav", "wb")
w.setnchannels(2); w.setsampwidth(2); w.setframerate(rate)
w.writeframes((b"".join(beep) + b"".join(gap)) * n)
w.close()
EOF
paplay /tmp/beeps.wav
```

## Known remaining wart

`Digital PCM Volume` still advertises a maximum of 913 while the useful range
ends at 816. Nothing is wrong with the driver per se — it is a
`SOC_SINGLE_SX_TLV` definition straight from upstream — but any UI that ramps
the control to its advertised maximum will mute the speaker. The UCM profile
pins it at 816.
