# alioth-armada — Redmi K40 / POCO F3 (alioth) port for Armada OS

**English** | [中文](#中文说明)

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
| Boot / display / touch | ✅ working (touch matrix follows the Game Mode / Desktop session) |
| GPU (a650 + zap shader) | ✅ working |
| Wi-Fi (ath11k QCA6390) | ✅ working |
| Bluetooth (hci_qca) | ✅ LE + BR/EDR discovery, BLE (HoGP) and classic (HIDP) gamepads. ⚠️ **RFCOMM/BNEP are not built into this kernel** — HFP/HSP mic, phone audio and Bluetooth PAN do not work (see below) |
| USB NCM networking (SSH over `fe80::1`) | ✅ working |
| Gamepad (xpad) | ✅ working |
| Sensors (SLPI) | ⚠️ crash-loop masked by service |
| **Speakers (2× CS35L41 over TERT MI2S)** | ✅ **working — audible, volume control, survives reboot** |
| Headphone jack / USB-C audio | untested / should work (`SND_USB_AUDIO=m`) |
| Performance profiles (game / desktop / idle) | ✅ automatic scene switch via `armada-perf-auto` (installed by the device script) |
| FPS / temperature overlay | ✅ Steam QAM level; restored per session from the last QAM snapshot |

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
  patches/          7 required + 1 optional patch on nikroks/alioth (6.15.1)
  build.sh          cross-compile wrapper (applies patches automatically)
  BUILD.env         repo / branch / config selection
  alioth.config     board config (base for build.sh; from this device's /proc/config.gz)
  alioth-armada.config.overrides
scripts/
  pin-probe.py      main-TLMM mi2s2 pad readback probe (/dev/mem)
  amp-regs.py       raw-i2c CS35L41 power-up sequence, bypassing the driver
  dtbo_dump.py      decode vendor dtbo partitions to text
docs/
  AUDIO-INVESTIGATION.md   the full seven-round speaker saga
  AUDIO-FIX-GUIDE.md       complete audio manual (UCM, PLL, amp regs, resume)
  AUDIO-REGRESSION-2026-11-17.md   the post-resume distortion case
  FIRMWARE.md              what to extract from your own device
  dtbo-tdm.txt, dtbo-amps.txt   decoded vendor DTBO audio nodes
```

## Kernel patches

`kernel/build.sh` applies `kernel/patches/*.patch` in filename order before
configuring.

### Required (always applied)

| # | Patch | Purpose |
|---|---|---|
| 0001 | `q6afe`: wait for DSP audio services before populating children | Boot race: probing before the ADSP services are up makes LPASS core HW votes fail (`0x100f4` → status `0x16`). Signature matches [Nova-Deck/os-build#94](https://github.com/Nova-Deck/os-build/issues/94). |
| 0002 | `q6core`: fix the ADSP readiness check | A failed `AVCS_CMD_ADSP_EVENT_GET_STATE` used to be read as "DSP up". |
| 0003 | `q6asm-dai`: unregister the component on remove | Lets the ADSP restart path re-register cleanly. |
| 0004 | `q6routing`: unregister the component on remove | Same, for the routing component. |
| 0005 | `cs35l41-lib`: RESUME/PAUSE mailbox instead of PUP_DONE polling | This B2 spk-prot firmware never raises `PUP_DONE` (bit 24); power-up completion shows as bit 22 within 0.4 ms. Waiting for bit 24 always times out → false `-110` → DAPM rollback. |
| 0006 | `sm8250`: retarget the amp PLL + pin the frontend format | **(the actual audio fix)** Sets `CS35L41_CLKID_SCLK` @ 1 536 000 on each codec DAI at stream start, and constrains the q6asm frontend to 2ch / 48 kHz / `S16_LE` so PipeWire builds a usable sink instead of an 8-channel `s24-32le` one. |
| 0007 | DTS: alioth audio **and** Bluetooth | TERT MI2S RX/TX ports, main-TLMM `mi2s2` pins (gpio133/135/137), `gpio134` data0, speaker + capture DAI links, **plus `local-bd-address`** (see below). |

### Optional (board configuration, not a fix)

Files named `90-optional-*.patch` encode a *choice about your hardware*, so they
are **skipped by default**. Opt in only if it matches your unit.

| Patch | When to enable |
|---|---|
| `90-optional-dts-battery-5000mah` | You replaced the stock 4520 mAh cell with a 5000 mAh one. Without it the fuel gauge maps state-of-charge against the original capacity. |

```bash
# required patches only (correct for a stock, unmodified phone)
bash kernel/build.sh out/

# also apply the 5000 mAh battery figures
ARMADA_OPTIONAL_PATCHES=battery bash kernel/build.sh out/

# apply every optional patch
ARMADA_OPTIONAL_PATCHES=all bash kernel/build.sh out/
```

The required patches were generated against, and apply with zero fuzz to, a
**pristine clone** of the `nikroks/alioth` branch of
[mainlining/linux](https://github.com/mainlining/linux) (6.15.1). Note that
`build.sh` itself invokes `patch` with `--fuzz=2` so a small context drift
elsewhere in the same file does not abort the build.

**Don't build from a tree that already has the patches applied.** `patch --forward`
detects them as reversed and skips all of them with a warning; the build then
succeeds but ships an unpatched audio driver. `kernel/build.sh` always wants a
fresh source tree (`KERNEL_SRC` or its own clone).

### Why the Bluetooth address is in the DTS

The QCA6390 ROM on these units reports an **all-zero** BD address, which the
kernel's `hci_dev_get_bd_addr_from_property()` rejects. bluez then marks the
controller "unconfigured" and hides it from userspace entirely — `btmgmt`
reports an empty index list and `bluetoothctl` says "No default controller
available", which is exactly what the Steam Bluetooth panel shows as an endless
"searching". Patch 0007 injects a locally-administered address
(`02:00:00:00:5a:ad`) so the controller can be configured.

Firmware download is *not* the problem: `QCA setup on UART is completed`
already appears in dmesg before the address is needed.

### Known Bluetooth limitation: RFCOMM / BNEP are not compiled

The board config has `CONFIG_BT_RFCOMM=y` and `CONFIG_BT_BNEP=y`, but the
running kernel contains neither protocol: `/proc/net/protocols` lists only
`HIDP`, `modprobe rfcomm` / `bnep` fail, and bluetoothd logs
`socket(STREAM, RFCOMM): Protocol not supported (93)` every session.

Cause: `alioth-armada.config.overrides` asks for `CONFIG_BT=y`, but the base
config has `CONFIG_RFKILL=m` and `config BT` depends on `RFKILL || !RFKILL`, so
the merge can only leave `CONFIG_BT=m` (`Value requested for CONFIG_BT not in
final .config` in the build log). With BT built as a module, kbuild ignores the
`obj-y` subdirectories `net/bluetooth/rfcomm/` and `bnep/` (a module directory
cannot mix module and built-in objects), so those `.config` entries never
produce code.

What still works: LE and BR/EDR discovery, BLE gamepads (HoGP via `uhid`) and
classic HID gamepads (`hidp`). What does not: HFP/HSP headset microphones,
SMS/phone audio, and Bluetooth PAN. To enable them, build with
`CONFIG_BT_RFCOMM=m` + `CONFIG_BT_BNEP=m` (or make `CONFIG_RFKILL=y` and
`CONFIG_BT=y`) and install the extra `.ko` files.

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
ssh <user>@fe80::1%$IF
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

---

# 中文说明

**红米 K40 / POCO F3（代号 alioth，骁龙 870 / SM8250）跑 Armada OS 的移植仓库。**

本仓库包含设备适配、内核补丁，以及完整的扬声器排查过程。全部内容为
**GPL-2.0-or-later**，与 Armada OS 自身许可一致。**仓库不包含任何专有固件
blob**——固件需从你自己的设备中提取，见 [docs/FIRMWARE.md](docs/FIRMWARE.md)。

## 状态

| 子系统 | 状态 |
|---|---|
| 启动 / 显示 / 触摸 | ✅ 正常（触摸矩阵随 Game Mode / 桌面会话切换） |
| GPU（a650 + zap shader） | ✅ 正常 |
| Wi-Fi（ath11k QCA6390） | ✅ 正常 |
| 蓝牙（hci_qca） | ✅ LE 与 BR/EDR 扫描、BLE（HoGP）与经典（HIDP）手柄可用。⚠️ **内核未编入 RFCOMM/BNEP** —— HFP/HSP 麦克风、通话音频、蓝牙 PAN 不可用（见下文） |
| USB NCM 网络（`fe80::1` 上跑 SSH） | ✅ 正常 |
| 手柄（xpad） | ✅ 正常 |
| 传感器（SLPI） | ⚠️ 崩溃循环，已由服务屏蔽 |
| **扬声器（2× CS35L41，走 TERT MI2S）** | ✅ **正常出声、音量可控、重启后仍正常** |
| 耳机孔 / USB-C 音频 | 未测，理论可用（`SND_USB_AUDIO=m`） |
| 性能档位（游戏 / 桌面 / 闲置） | ✅ `armada-perf-auto` 自动切档（由设备脚本安装） |
| FPS / 温度叠加层 | ✅ Steam QAM 等级；每会话从上次 QAM 快照恢复 |

## 扬声器修复（一段话）

功放的保护固件默认把 PLL 参考设为 **12.288 MHz**，而 ADSP 实际驱动的
`TER_MI2S_IBIT` 只有 **1.536 MHz**——差 8 倍。中间每一层软件看上去都健康：
DAPM 上电正常、`PWR_CTRL2` 读到 `0x3721`（固件自己抬了 `AMP_EN` 和 boost）、
没有任何错误位、PLL 甚至报锁定——但输出级完全静音。在流启动时把 PLL
重定向到真实 BCLK，声音立刻出现。完整证据链见
[docs/AUDIO-INVESTIGATION.md](docs/AUDIO-INVESTIGATION.md)。

## 仓库结构

```
device/            镜像构建胶水层（Armada build_files 的 alioth 版本）
  52-alioth-device-fixes.sh    构建镜像时安装的设备适配
  ucm/                         xiaomi-alioth 声卡的 UCM2 profile
kernel/
  patches/          nikroks/alioth (6.15.1) 上 7 个必需 + 1 个可选补丁
  build.sh          交叉编译封装（自动按顺序打补丁）
  BUILD.env         仓库 / 分支 / 配置文件选择
  alioth.config     板级配置（build.sh 的基础，来自本设备 /proc/config.gz）
  alioth-armada.config.overrides    Armada 运行时配置片段
scripts/
  pin-probe.py      主 TLMM mi2s2 引脚回读探针（/dev/mem）
  amp-regs.py       绕过驱动、直接 I2C 驱动 CS35L41 上电序列
  dtbo_dump.py      把厂商 dtbo 分区解码成文本
docs/
  AUDIO-INVESTIGATION.md   七轮扬声器排查全过程
  AUDIO-FIX-GUIDE.md       完整音频手册（UCM、PLL、功放寄存器、休眠恢复）
  AUDIO-REGRESSION-2026-11-17.md   休眠后持续破音的实测记录
  FIRMWARE.md              需要从你自己设备提取哪些固件
  dtbo-tdm.txt, dtbo-amps.txt   解码后的厂商 DTBO 音频节点
```

## 内核补丁

`kernel/build.sh` 在配置前按文件名顺序应用 `kernel/patches/*.patch`。

### 必需（总是应用）

| 编号 | 补丁 | 作用 |
|---|---|---|
| 0001 | `q6afe`：填充子设备前等待 DSP 音频服务 | 启动竞态：ADSP 服务未就绪就 probe 会让 LPASS core HW vote 失败（`0x100f4` → status `0x16`）。症状与 [Nova-Deck/os-build#94](https://github.com/Nova-Deck/os-build/issues/94) 一致。 |
| 0002 | `q6core`：修正 ADSP 就绪判定 | 以前把 `AVCS_CMD_ADSP_EVENT_GET_STATE` 失败当成"DSP 已就绪"。 |
| 0003 | `q6asm-dai`：remove 时反注册 component | 让 ADSP 重启路径能干净地重新注册。 |
| 0004 | `q6routing`：remove 时反注册 component | 同上，针对 routing component。 |
| 0005 | `cs35l41-lib`：用 RESUME/PAUSE mailbox 替代 PUP_DONE 轮询 | 这颗 B2 spk-prot 固件从不置 `PUP_DONE`（bit 24）；上电完成实际表现为 0.4 ms 内的 bit 22。等 bit 24 必然超时 → 误报 `-110` → DAPM 回滚。 |
| 0006 | `sm8250`：重定向功放 PLL + 约束前端格式 | **（真正的音频修复）** 流启动时在每个 codec DAI 上设置 `CS35L41_CLKID_SCLK` @ 1 536 000，并把 q6asm 前端约束为 2ch / 48 kHz / `S16_LE`，使 PipeWire 能建立一个可用的 sink，而不是 8 声道 `s24-32le`。 |
| 0007 | DTS：alioth 音频**与**蓝牙 | TERT MI2S RX/TX 端口、主 TLMM `mi2s2` 引脚（gpio133/135/137）、`gpio134` data0、扬声器与采集 DAI 链路，**外加 `local-bd-address`**（见下文）。 |

### 可选（板级配置，不是修复）

`90-optional-*.patch` 表达的是**关于你硬件的选择**，默认**跳过**。
仅当与你的设备相符时才启用。

| 补丁 | 何时启用 |
|---|---|
| `90-optional-dts-battery-5000mah` | 你把原装 4520 mAh 电池换成了 5000 mAh。不加这个补丁，电量计仍按原容量换算电量百分比。 |

```bash
# 只打必需补丁（原装未改装手机的正确答案）
bash kernel/build.sh out/

# 额外应用 5000 mAh 电池数据
ARMADA_OPTIONAL_PATCHES=battery bash kernel/build.sh out/

# 应用所有可选补丁
ARMADA_OPTIONAL_PATCHES=all bash kernel/build.sh out/
```

必需补丁是针对 [mainlining/linux](https://github.com/mainlining/linux)
`nikroks/alioth` 分支（6.15.1）的**干净克隆**生成、并以零 fuzz 应用的。
注意 `build.sh` 自身调用 `patch` 时用 `--fuzz=2`，以避免同一文件别处的
少量上下文漂移直接中断构建。

**不要从已经打过补丁的源码树构建。** `patch --forward` 会把这些补丁
识别为"反向已应用"并全部跳过（只留一条警告）；构建照样成功，但产出的是
**没打补丁的音频驱动**。`kernel/build.sh` 始终需要一份新源码树
（`KERNEL_SRC` 或它自己克隆的那份）。

### 为什么蓝牙地址写在 DTS 里

这些机器的 QCA6390 ROM 上报的 BD 地址**全为零**，内核的
`hci_dev_get_bd_addr_from_property()` 会拒绝它。bluez 随后把控制器标成
"unconfigured" 并对用户态完全隐藏——`btmgmt` 索引列表为空、
`bluetoothctl` 报 "No default controller available"，在 Steam 蓝牙面板里
的表现就是永远显示"搜索中"。补丁 0007 注入一个本地管理地址
（`02:00:00:00:5a:ad`）让控制器可以被配置。

固件下载**不是**问题所在：在需要地址之前，dmesg 里早就有
`QCA setup on UART is completed`。

### 已知蓝牙限制：RFCOMM / BNEP 未编入

板级配置里写着 `CONFIG_BT_RFCOMM=y` 和 `CONFIG_BT_BNEP=y`，但运行中的内核
两个协议都不存在：`/proc/net/protocols` 只有 `HIDP`，
`modprobe rfcomm` / `bnep` 失败，bluetoothd 每个会话都刷
`socket(STREAM, RFCOMM): Protocol not supported (93)`。

原因：`alioth-armada.config.overrides` 请求 `CONFIG_BT=y`，但基础配置是
`CONFIG_RFKILL=m`，而 `config BT` 依赖 `RFKILL || !RFKILL`，所以合并后
只能留下 `CONFIG_BT=m`（构建日志里的
`Value requested for CONFIG_BT not in final .config`）。BT 作为模块构建时，
kbuild 会忽略 `obj-y` 子目录 `net/bluetooth/rfcomm/` 与 `bnep/`
（模块目录不能混用模块与内建目标），于是那些 `.config` 条目从未产生代码。

仍然可用：LE 与 BR/EDR 扫描、BLE 手柄（HoGP，走 `uhid`）、经典 HID 手柄
（`hidp`）。不可用：HFP/HSP 耳机麦克风、短信/通话音频、蓝牙 PAN。
要启用它们，用 `CONFIG_BT_RFCOMM=m` + `CONFIG_BT_BNEP=m` 构建
（或令 `CONFIG_RFKILL=y` 且 `CONFIG_BT=y`），并安装多出来的 `.ko`。

## 构建

```bash
# 在 x86_64 上交叉编译（需要 gcc-aarch64-linux-gnu）：
KERNEL_SRC=/path/to/pristine/linux JOBS=12 bash kernel/build.sh out/
```

不给 `KERNEL_SRC` 时，脚本会自己克隆 `mainlining/linux` 的 `nikroks/alioth`
分支并应用 `kernel/patches/*.patch`。产物为 `Image.gz-dtb_alioth`
以及 `armada-kernel-<ver>.tar.zst`（模块）。

**音频驱动是模块。** 改了音频代码只刷一个新的 `boot_b` 是不够的——还要把
重新编译出的 `.ko` 复制到运行系统上的 `/usr/lib/modules/<ver>/` 并执行
`depmod -a`。注意 `cat file | ssh "cat > file"` 会悄悄产生 0 字节文件；
请用 `scp -O`。

## 与设备通信

设备暴露一个 USB NCM gadget，在主机侧是 `fe80::1`。**接口序号每次启动都会
变**，所以请按可达性解析，不要硬编码名字：

```bash
for f in /sys/class/net/eth*; do
  ping6 -c1 -W1 "fe80::1%$(basename "$f")" >/dev/null 2>&1 && IF=$(basename "$f")
done
ssh <user>@fe80::1%$IF
```

如果主机连不上而 Windows 侧能连，通常是 gadget 接口被重新编号了——
先从主机侧确认。

## 音量语义（容易踩的坑）

`Digital PCM Volume` 是 `SOC_SINGLE_SX_TLV`：ALSA 控制值等于寄存器 code
减去 **1231**，字段是 **11 位**。

| 控制值 | 寄存器 code | 结果 |
|---|---|---|
| **816** | 2047 | **0 dB** |
| 913（界面显示的最大值） | 回绕成 96 | 接近静音 |
| 0 | — | 静音 |

UCM profile 把它固定在 816。设成 913——看起来像"最大"——实际上会把功放
静音。

## 固件

本仓库**不提供固件**。需要从你自己设备提取什么，见
[docs/FIRMWARE.md](docs/FIRMWARE.md)。

## 致谢

- [Armada OS](https://github.com/armada-os/armada)——基础发行版（GPL-2.0-or-later）
- [mainlining/linux](https://github.com/mainlining/linux) `nikroks/alioth` 分支——
  6.15.1 alioth 内核与 DTS
- [xiongnemo/hakios-alioth](https://github.com/xiongnemo/hakios-alioth)——
  CS35L41 上电配方（共享 reset、I2C 地址、boost 参数、mailbox RESUME、
  1.536 MHz 对应 PLL code `0x1b`），以及指向主 TLMM `mi2s2` 引脚上
  TERT MI2S 的板级数据
- [Nova-Deck/os-build#94](https://github.com/Nova-Deck/os-build/issues/94)——
  与我们的 `0x100f4`/`0x16` 症状吻合的启动竞态分析
- QDSP6/ALSA 上游维护者——我们读了太多他们的代码
