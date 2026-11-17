# alioth 音频修复完整手册

> 红米 K40 / POCO F3（SM8250）在 Armada OS 上让扬声器出声的完整方法。
> 2026-11-15 实测确认可复现。所有结论都有设备证据，不是推断。
>
> 本文是本项目公开版的音频手册：构建路径和主机名已脱敏，技术内容未改。

---

## 一、硬件链路速览

```
PipeWire sink
  → ALSA UCM2 HiFi profile
    → card 0 "xiaomi-alioth" / hw:0,0
      → Q6ASM（ADSP 音频解码）+ Q6AFE（ADSP 音频前端）
        → TERTIARY MI2S 端口 0x1004，SD1，16-bit 立体声，48 kHz
          → 主 TLMM mi2s2 引脚（gpio133 SCK / gpio135 WS / gpio137 D1）
            → 两颗 CS35L41 智能功放（I2C bus 3）
                 RCV = 0x40（收声道）
                 LCV = 0x41（低音声道）
              → 扬声器
```

**关键事实**：CS35L41 不是普通 DAC，它内部有一个 **DSP**（跑 spk-prot 保护固件），
音频必须经过这个 DSP 才能到扬声器。DSP 没工作，寄存器全绿也不出声。

---

## 二、六层根因（按发现顺序）

每一层都会单独导致无声，必须全部满足才能出声。

### 第 1 层 — UCM2 查找路径

**现象**：`pactl list cards` 显示 `Active Profile: off`，`wpctl` 只有 Dummy Output。

**根因**：alsa-lib 找 UCM2 配置**只走** `conf.d/<CardDriver>/<CardLongName>.conf`，
不会直接扫 `Qualcomm/sm8250/`。alioth 缺这两个文件：

```
/usr/share/alsa/ucm2/Qualcomm/sm8250/Xiaomi-Alioth.conf          ← 顶层
/usr/share/alsa/ucm2/conf.d/sm8250/xiaomi-alioth.conf            ← 查找链接
```

链接内容：
```
../../Qualcomm/sm8250/Xiaomi-Alioth.conf
```

**验证**：镜像里其它 SM8250 掌机（PocketMICRO2、AirYPro…）每台都有
`conf.d/sm8250/*.conf`，只有 alioth 没有。

**排查手法**：ctypes 直调 `snd_use_case_mgr_open("xiaomi-alioth")`。
如果连**已知能工作的设备名**也返回 ENOENT，就是搜索路径不对，不是文件名错。

---

### 第 2 层 — PLL 参考时钟 8 倍错配

**现象**：DAPM 全 On、DAPM 图正常、寄存器无故障位、PLL 自报已锁，**但完全无声**。

**根因**：CS35L41 保护固件默认把 PLL 参考设为 **12.288 MHz**（`0x2C04 = 0x670`），
而 ADSP 实际驱动的 `TER_MI2S_IBIT` 只有 **1.536 MHz**。差 8 倍。

**修法**（内核补丁 0006）：在 `sm8250.c` 的 TERTIARY_MI2S_RX 启动路径上：

```c
for_each_rtd_codec_dais(rtd, j, codec_dai) {
    snd_soc_component_set_sysclk(codec_dai->component,
                                 CS35L41_CLKID_SCLK, 0,
                                 MI2S_BCLK_RATE,          // 1.536 MHz
                                 SNDRV_PCM_STREAM_PLAYBACK);
}
```

**判据实验**（11-14 首次确认）：播放中把 `0x2C04` 从 `0x670` 手工写成 `0x370`
→ 立刻出声。改好后播放期间固件不会改回。

**注意**：`0x370` = PLLSRC=SCLK + refclk 1.536 MHz；
完整工作态还要 **bit16（PLL enable）**，即 `0x10370`。

---

### 第 3 层 — ASP_ENABLES bit17（**最隐蔽的一层**）

**现象**：时钟在引脚上跑、数据在跑、功放寄存器全对、DSP 固件活着
（mailbox 有 ack）、无任何故障位——**但扬声器完全无声**。

**根因**：固件在**每次流启动时**把 `0x4800 ASP_ENABLES` 写成 **`0x30000`**。
- bit16 = ASP 使能（需要）
- **bit17 置位 → ASP 不接收 I2S 数据**

空闲时固件把它清成 `0x0`。

**正确值**：**`0x10000`**（bit16 置、bit17 清）

**关键时序**：必须在**流已经开始之后**写入。写在 `startup()` 里会被固件的
`0x30000` 覆盖。

**实测证据**（每 200ms 采样 `0x4800`）：
```
播放开始前 : 0x00000
播放开始后 : 0x30000   ← 固件写的
手工写0x10000: 0x10000  ← 之后一直保持，固件不再改
```

**⚠️ 致命教训**：**不要**把这个写进内核的 `trigger(START)` 回调。
试过了，结果是**声卡完全 probe 不出来**：
```
platform sound: deferred probe pending:
  snd-sm8250: MultiMedia1: error getting cpu dai name
```
`sm8250_be_ops` 加 `.trigger` 会破坏 dai link 注册。
**可靠做法是用户态在流启动后写**（见第五节）。

---

### 第 4 层 — PWR_CTRL3 bit24（⚠️ 2026-11-15 P1 实测反证：非必需）

**2026-11-15 冷启动验证时的实测修正**：在**能听到连续哔声**的状态下采样，
两颗功放的实际值是：

```
ASP=0x10000   PWR3=0x01000010（缺 bit24）   PLL=0x370（无 bit16）   GLOBAL_EN=1
```

即 **bit24 与 PLL enable 都不是出声的必要条件**。它们是归档快照里的形态，
固件/驱动在每次流启动时会重写。原先把它们列为"必须"导致 boot-probe 把
本来能出声的功放判成 PROBLEM（误报），已于同日修正判定逻辑。

真正具备阻断性的只有：ASP bit16 置/bit17 清、GLOBAL_EN=1、非静音。

原始记录（保留供追溯）：出声时 `0x201C` = **`0x01100010`**，
按 hakios 配方（`upd(a, 0x201C, 0x100010, 0x100010)`）只写成了 `0x01000010`。

---

### 第 5 层 — 数字音量语义

**控件**：`Digital PCM Volume`，类型 `SOC_SINGLE_SX_TLV`
```
寄存器 0x6000：code = 控件值 + 1231，11 位域，低 3 位是 ramp
控件 816  → code 2047 → 0 dB   → 寄存器 0x6000 = 0xbffc / 0xbff8
控件 913（标称上限）→ code 2144 溢出成 96 → 近静音
控件 0   → MUTE
```
**必须用 816。**

**按 8dB 衰减写**（`别名 att`）：`reg = ((2048 - att) & 0x7ff) << 3 | 4`
- att 96 → -12 dB（推荐默认）
- att 320 → -40 dB（起始值，用于 ramp）

---

### 第 6 层 — WirePlumber 空闲挂起

**现象**：长音频（30 s）能响，**短音效（UI 按键音、通知音）完全没声**。

**根因**：WirePlumber 默认在 sink 空闲几秒后 suspend ALSA 设备。
CS35L41 从挂起恢复比一个短音效（~0.5 s）还慢，音频流结束时设备还没醒。

**修法**（每个其它 SM8250 掌机都有这个配置）：
```toml
# /usr/share/wireplumber/wireplumber.conf.d/52-alioth-suspend-timeout.conf
monitor.alsa.rules = [
  {
    matches = [
      { node.name = "~alsa_output.*"  alsa.card_name = "xiaomi-alioth" }
    ]
    actions = { update-props = { session.suspend-timeout-seconds = 0 } }
  }
]
```

---

## 三、内核补丁集（7 个 + 1 可选）

位于本仓库 `kernel/patches/`，`kernel/build.sh` 自动按文件名顺序应用。

| 补丁 | 文件 | 作用 |
|---|---|---|
| 0001 | `q6afe.c` | 等 DSP 音频服务就绪（10s）再 probe；否则 `MultiMedia1: error getting cpu dai name` |
| 0002 | `q6core.c` | 不把 `GET_STATE` 失败当成"DSP 已就绪" |
| 0003 | `q6asm-dai.c` | remove 时反注册 component（避免重复加载泄漏）|
| 0004 | `q6routing.c` | 同上 |
| 0005 | `cs35l41-lib.c` | 用 RESUME/PAUSE mailbox 代替轮询 PUP_DONE（此固件只置 bit22，轮询必超时）|
| 0006 | `sm8250.c` | PLL 重定向到 1.536 MHz + **FE 约束 2ch/48k/S16_LE** |
| 0007 | DTS | TERT MI2S 音频链路 + 蓝牙 `local-bd-address` |
| 90-optional | DTS | 5000 mAh 电池（**默认不应用**，用 `ARMADA_OPTIONAL_PATCHES=battery` 启用）|

**0006 的 FE 约束特别重要**：
q6asm 前端宣称支持 1–8 声道，PipeWire 会协商成 `8ch s24-32le` sink，
和硬件路径（2ch S16_LE）永远不匹配 → 桌面路径完全无声、音量键失效。

---

## 四、DTS 要点（补丁 0007）

```dts
&q6afedai {
    dai@20 {                          /* TERTIARY_MI2S_RX，播放 */
        reg = <TERTIARY_MI2S_RX>;
        qcom,sd-lines = <1>;
    };
    dai@21 {                          /* TERTIARY_MI2S_TX，采集/监控 */
        reg = <TERTIARY_MI2S_TX>;
        qcom,sd-lines = <0>;
    };
};

&tlmm {
    tert_mi2s_active: tert-mi2s-active-state {
        sck-pins  { pins = "gpio133"; function = "mi2s2_sck";  };
        ws-pins   { pins = "gpio135"; function = "mi2s2_ws";   };
        data-pins { pins = "gpio137"; function = "mi2s2_data1";};
        data0-pins{ pins = "gpio134"; function = "mi2s2_data0";};
    };
};

&sound {
    pinctrl-0 = <&tert_mi2s_active>;
    speaker-dai-link {
        link-name = "Tertiary MI2S Playback";
        cpu      { sound-dai = <&q6afedai TERTIARY_MI2S_RX>; };
        platform { sound-dai = <&q6routing>; };
        codec    { sound-dai = <&cs35l41_rcv 0>, <&cs35l41_lcv 0>; };
    };
};

cs35l41_lcv: speaker-amp@41 {
    cirrus,right-channel-amp;      /* LCV 作为右声道 */
    reset-gpios = <&tlmm 114 GPIO_ACTIVE_HIGH>;   /* 与 RCV 共享 */
};
```

**引脚事实**：gpio134 是 ADSP 驱动的 data0 **输出**（OE=1），
**不能**当 CPU 捕获输入用（曾为测 VBST 建过捕获链路，全零，纯属白费）。

---

## 五、用户态恢复方案（当前采用）

### 5.1 `/usr/libexec/alioth-amp-enable`

完整序列（两颗功放都执行，RCV=0x40 / LCV=0x41）：

```python
# 1. ASP：bit16 置、bit17 清
io_upd(a, 0x4800, 0x30000, 0x10000)

# 2. 静音保护
io_upd(a, 0x2024, 0x10, 0x10)      # 模拟静音
io_w  (a, 0x6000, 0x2004)          # 数字静音

# 3. DAC 与增益
io_w  (a, 0x4C00, 0x32)            # DAC 来自保护 DSP
io_upd(a, 0x6C04, 0x3e0, 18 << 5)  # amp gain = 18

# 4. PWR_CTRL3 —— 注意 bit24
io_w  (a, 0x201C, 0x01100010)      # 不是 0x01000010！

# 5. 清 sticky + test key 解锁 + pup patch + 上锁
io_w  (a, 0x10010, 0xFFFFFFFF)
io_w  (a, 0x40, 0x55); io_w(a, 0x40, 0xAA)
io_w  (a, 0x2084, 0x002F1AA0)
io_w  (a, 0x40, 0xCC); io_w(a, 0x40, 0x33)

# 6. GLOBAL_EN
io_upd(a, 0x2014, 1, 1)
time.sleep(0.002)

# 7. mailbox SPK_OUT_ENABLE（cmd 2）
mbox(a, 2)

# 8. 音量 ramp：-40 dB -> -12 dB，每步 6 dB，每步 100 ms
#    （听感上这段就是"断续的嘟嘟声"，属正常）
att = 320
while att > 96:
    att = max(96, att - 48)
    io_upd(a, 0x6000, 0x3fff, ((2048-att) & 0x7ff) << 3 | 4)
    time.sleep(0.1)

# 9. 解除模拟静音
io_upd(a, 0x2024, 0x10, 0)
```

### 5.2 `/usr/libexec/alioth-sound-watch`（v4，低频干扰模式）

问题：固件在**每个新流开始时**把 ASP 写成 `0x30000`，所以必须每次补偿。

**v4 设计**（在 v3 基础上补一个只读心跳）：
- 5 Hz 轮询 `/proc/asound/card0/pcm0p/sub0/status`（纯文件读，不碰 I2C）
- 检测到 `RUNNING` 的**瞬间**检查/修正一次 ASP
- 之后 0.15 / 0.45 / 0.6 秒各复查一次
- **流运行期间**每秒**只读**一次 ASP；只有发现被固件改写了才写回
- 空闲时完全不碰 I2C

**为什么 v4 需要心跳**：WirePlumber 配了 `suspend-timeout-seconds = 0`，
所以 `pcm0p` 会**长期停在 RUNNING**（实测 owner_pid 一直是 pipewire）。
v3 只在"空闲→RUNNING"边沿触发，重启 pipewire 后这个边沿可能永远不再出现，
固件之后改写 ASP 就没人在意了。

**必须 root 运行**：`/dev/i2c-3` 是 `crw------- root root`，
以 armada 身份运行会 `Permission denied`（v1 就是这么静默失败的）。

### 5.2b 冷启动自愈（2026-11-15 P1 修复的真正问题）

**冷启动无声的真正原因不是寄存器值，而是时序**：

`armada-speaker-route` 在启动早期跑（`Before=wireplumber.service`），
此时保护 DSP 还在加载，mailbox `SPK_OUT_ENABLE` 必然 `ack=False` →
功放停在开机态。之前只能手工跑 `alioth-amp-enable` 才恢复。

修法（`alioth-audio-boot-fix` + `alioth-audio-boot-probe.service`）：

```
开机 8 s   → alioth-audio-boot-probe early     （记录状态快照）
开机 ~16 s → alioth-audio-boot-fix             （重试 route+amp-enable 直到 mbox=True）
之后       → alioth-audio-boot-probe after-fix （记录修复后快照）
```

实测：两次冷启动都在 **attempt 1** 就 `mbox=True after 1 try`，
开机约 22 s 后 `VERDICT: OK`。

**关键设计：ramp 只在 DSP 确认后才跑。**
v4 的 `amp-enable` 失败时也会做音量 ramp，重试就会被听成连续"嘟嘟"声；
v5 改成 `if not ack: return`，失败时保持静音。实测冷启动后首次播放
**没有开头断续**。

**mailbox 重试要短**：`alioth-amp-enable` 内只重试 3 次（~0.75 s），
因为 route 服务是 `Before=wireplumber.service`，长重试会拖住整个音频会话；
秒级重试交给 `alioth-audio-boot-fix`（8 s 间隔，最多 5 次）。

### 5.3 udev 规则：钉住 runtime PM

```
# /usr/lib/udev/rules.d/62-alioth-amp-pm.rules
ACTION=="bind", DRIVER=="cs35l41", TEST=="power/control", ATTR{power/control}="on"
```

原因：驱动 3 秒 autosuspend 后，唤醒路径 `cs35l41_exit_hibernate()`
**从未成功**（`Wake failed -42`），功放卡在半死态。

---

## 5.4 休眠后持续破音与 Steam UI 无声（2026-11-17 实测恢复）

### 现象与定位边界

一次 suspend/resume 后出现持续破音：1 秒 `paplay` 测试音和
Steam UI 点击音都破。软件 monitor 波形正常（无削波/断流），PipeWire/ALSA
是 `s16le 2ch 48kHz`，两颗功放 ASP/PLL/GLOBAL_EN/非静音在播放期间均正确，
MI2S 引脚有活动。**所以这不是音量、ASP、普通 mailbox 或 Steam 客户端单方面的问题。**

`armada-speaker-route` + `alioth-amp-enable`（两颗 `mbox=True`）**不能**恢复，
不要在这种情况下反复 ramp 或盲目重启 DSP。故障位于 PipeWire 之后的
ADSP/Q6AFE/MI2S 端口状态/时钟路径。

### 已验证的恢复方法（两段缺一不可）

1. 重启用户音频栈，令 AFE 端口真正 STOP → SET_PARAM → START：
   ```bash
   sudo -u armada -H env XDG_RUNTIME_DIR=/run/user/1000 \
     systemctl --user restart wireplumber pipewire-pulse pipewire
   ```
   等待 sink 恢复后，1 秒测试音**完全正常**。`alioth-sound-watch`
   随后重新修正 ASP。

2. 音频栈重启会让 gamescope 的 PipeWire 流变成 `unconnected`，
   Steam 的 `audio.mojom.AudioService` 也可能不重连。现象是：
   **测试音正常、Steam UI 点击无声。** 此时需重启一次 gamescope/Steam
   会话，让 CEF 音频客户端重连：
   ```bash
   sudo -u armada -H env XDG_RUNTIME_DIR=/run/user/1000 \
     systemctl --user stop gamescope-session-plus@steam.service
   ```
   由现有会话管理器重新拉起后，Steam UI 音效**恢复**（实测确认）。

**不要只把 `armada-speaker-route` 放进 systemd-sleep 就宣称固化完成。**
它只能修 mailbox/ASP，不能替代 AFE 重开，也不能保证 Steam 客户端重连。

### 恢复脚本的设计原则

`/usr/lib/systemd/system-sleep/alioth-audio-resume`（同时安装为
`/usr/bin/alioth-audio-resume`）实现了上述两段恢复：

- 保留短按休眠，不擅自禁用 suspend；只处理 `post`。
- resume 时重启 PipeWire/WirePlumber，等待默认 sink 回来；
  再按当前会话类型重连 Steam 音频客户端。
- 游戏中（或 `/proc` 不可读）**只写 pending 标记**，不碰音频与会话——
  在游戏运行中重启 PipeWire 未被证明无害。退出游戏后可手动执行
  `sudo alioth-audio-resume --restart-session`。
- 每次会话（`boot_id` + session MainPID）最多自动重连一次，新会话可再次恢复；
  单实例 flock，不重试、不循环重启。
- 所有用户 D-Bus 调用都带超时：实测 resume 后约 12 秒 `user.slice` 才解冻，
  过短的超时会在这之前失败，所以等待窗口取 60 秒（仍然有界）。
- 桌面模式从不启动或停止 gamescope；会话类型由 `/proc/comm` 判断，
  不用可能在 resume 后阻塞的 D-Bus 查询。
- 日志 `/var/log/alioth-audio-resume.log`，pending 标记
  `/run/alioth-audio-resume.pending`，会话戳 `/run/alioth-audio-resume.session`。
- AFE 端口没有专用 runtime resume 回调，内核依据是 ALSA
  `shutdown`(DEVICE_STOP) → `prepare`(SET_PARAM + DEVICE_START)。

**验收边界**：真实 suspend/resume 后听感恢复正常，但 hook 日志曾停在
restart 处未见完成标记；自动化收尾仍需核实。不要把 mock 测试通过
当作真实恢复通过。后续需要覆盖连续唤醒不反复重启、桌面模式不误操作
gamescope、cold boot 不被不必要地二次重启。

### 采集脚本

`audio-regression-readonly.sh`、`audio-live-readonly.py`、
`audio-power-history-readonly.sh`；详细时间线见
`docs/AUDIO-REGRESSION-2026-11-17.md`。

## 六、出声的寄存器基准

**两颗功放相同**（除 `0x4820`）：

| 寄存器 | 值 | 说明 |
|---|---|---|
| `0x2014` PWR1 | `0x00000001` | GLOBAL_EN（**必需**）|
| `0x2018` PWR2 | `0x00003721` | 固件自抬 AMP_EN + boost |
| `0x201C` PWR3 | `0x01100010` 或 `0x01000010` | bit24 **非必需**（实测缺 bit24 照样出声）|
| `0x2024` | `0x00000000` | bit4=0（非静音，**必需**）|
| `0x2C04` PLL | `0x00010370` 或 `0x00000370` | bit16 **非必需**（实测缺 enable 照样出声）|
| `0x2C08` | `0x00000003` | 锁定 |
| `0x2C0C` | `0x00000003` | FS = 48 kHz |
| `0x4800` ASP | **`0x00010000`** | bit16 置 / bit17 清 |
| `0x4808` | `0x10180200` | I2S 16-bit |
| `0x4820` slot | **RCV=`0x100` LCV=`0x1`** | 两颗不同 |
| `0x4840` | `0x00000010` | 16 bit 字长 |
| `0x4C00` | `0x00000032` | DAC 来自 DSP |
| `0x6000` | `0x00003d04` | -12 dB |
| `0x6C04` | `0x00000240` | gain 18 |
| `0x10010` | `0x01000000` | 无故障 |
| `0x10804` | `0x00000000` | 无故障 |

完整快照见 `WORKING-STATE-2026-11-15.txt` / `-B.txt`
和 `AUDIO-WORKING-STATE-REFERENCE.md`。

---

## 七、验证方法

**用断续哔声，不要用连续正弦**——连续音极易和功放上下电混淆，
本项目因此误判过多次。

```python
import wave, struct, math
rate = 48000
w = wave.open("/tmp/beep.wav", "wb"); w.setnchannels(2); w.setsampwidth(2); w.setframerate(rate)
beep = [struct.pack("<hh", v, v)
        for v in [int(11000*math.sin(2*math.pi*600*i/rate)) for i in range(rate)]]
gap  = [struct.pack("<hh", 0, 0)] * int(rate*0.7)
w.writeframes((b"".join(beep) + b"".join(gap)) * 5); w.close()
```

```bash
paplay /tmp/beep.wav
```

---

## 八、排查清单（无声时按序检查）

```bash
# 1. 声卡存在吗
cat /proc/asound/cards                       # 应看到 xiaomialioth

# 2. profile 与 sink
pactl list cards | grep "Active Profile"     # 应为 HiFi
pactl get-default-sink                       # 不应是 auto_null

# 3. 功放寄存器（见第六节表）
python3 /usr/libexec/alioth-amp-enable       # 幂等，直接跑一遍最快

# 4. 声卡 probe 失败（deferred）
dmesg | grep "deferred probe"

# 5. 引脚波形（有波形 ≠ 出声）
python3 tlmm-probe.py                        # BCLK/WS/DATA 应翻转
```

**排查顺序建议**：先跑 `alioth-amp-enable`（90% 问题能解决），
再看寄存器差异，最后才查内核/DTS。

---

## 九、踩过的假线索（别再试）

| 现象 | 真相 |
|---|---|
| `VBST mon = 0` 以为 boost 没输出 | VBST/VBAT 是 ASP TX 监控通道，**无直读电压寄存器** |
| HALO 心跳 `0x2800004` 冻结 | 不是本固件的心跳地址 |
| `Wake failed -42` | 休眠唤醒失败，但**不是**无声的直接原因 |
| 引脚有数据翻转就当能出声 | 只证明 ADSP 在发，**bit17 未清照样无声** |
| `0x6000 = 0xbff8` 以为被静音 | 这是 **0 dB 的合法形态**（0xbffc 附近） |
| 把 ASP 写进内核 `trigger()` | **会让声卡 probe 失败**，绝对不要 |
| 给 WirePlumber 硬指定 `audio.format` | **sink 会消失变成 auto_null** |

---

## 十、构建与刷写

```bash
# 内核（含 7 个补丁）
# 应用本仓库的脚本（需要一份干净的 nikroks/alioth 源码树）
KERNEL_SRC=/path/to/pristine/linux JOBS=12 bash kernel/build.sh out/

# 完整镜像（rootfs + boot.img）：由 Armada OS 的镜像构建流程负责
```

**只换内核模块**（不重建 rootfs）：
```bash
scp -O <staging>/lib/modules/6.15.1-armada/kernel/sound/soc/qcom/snd-soc-sm8250.ko \
    '<user>@<device-host>:/tmp/'
# 设备上：备份 → 替换 → depmod → 重启
```

**注意**：内核 built-in 部分（q6afe/q6core/q6asm）改了必须刷 boot.img，
只换 `.ko` 不够。
