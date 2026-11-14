# Firmware you need to supply yourself

This repository ships **no firmware blobs** — they are proprietary. Extract
them from your own device or your own stock-ROM backup.

## What is needed

Under `/usr/lib/firmware/` (Armada/Arch layout) or equivalent:

```
qcom/sm8250/xiaomi/alioth/
    adsp.mbn           ADSP audio/image DSP
    cdsp.mbn           compute DSP
    slpi.mbn           sensors DSP
    venus.mbn          video
    a650_zap.mbn       GPU secure boot shader
    ...
cirrus/
    cs35l41-dsp1-spk-prot.wmfw          amp protection DSP firmware
    cs35l41-dsp1-spk-prot-RCV.bin       RCV tuning
    cs35l41-dsp1-spk-prot-LCV.bin       LCV tuning
ath11k/QCA6390/...                      Wi-Fi + BT
usr/share/qcom/sm8250/Xiaomi/alioth/acdbdata/...   audio calibration
```

## Where the CS35L41 firmware matters

The working combination on this device is the **revb2** firmware from the
vendor image, installed under the generic filenames the mainline driver
requests:

| File the driver asks for | Actually contains |
|---|---|
| `cirrus/cs35l41-dsp1-spk-prot.wmfw` | `cs35l41-dsp1-spk-prot-revb2.wmfw` (33 220 B) |
| `cirrus/cs35l41-dsp1-spk-prot-RCV.bin` | `cs35l41-dsp1-spk-prot-RCV-revb2.bin` |
| `cirrus/cs35l41-dsp1-spk-prot-LCV.bin` | `cs35l41-dsp1-spk-prot-revb2.bin` |

Loaded firmware identifies as `400a4 vendor: 0x2 v0.13.0`, 1 algorithm.
Keep the originals backed up — swapping them back is one `cp` each.

## Notes

- The vendor `super` partition on this device uses the GDLA container
  (`gDla` magic + a byte-shuffled LP header) with high-entropy payload
  regions; offline extraction did not work. Pull the files from a rooted
  stock device or from your previous rootfs instead.
- `acdbdata/` is present but **not consumed** by mainline Linux (and not
  needed for the speaker fix documented here).
