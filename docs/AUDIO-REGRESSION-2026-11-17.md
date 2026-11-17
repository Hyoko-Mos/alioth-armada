# 音频持续破音回归 — 2026-11-17

> 现象、排除项与恢复方法的实测记录。寄存器与排查方法见 `AUDIO-FIX-GUIDE.md`。

## 现象

一次 suspend/resume 之后出现持续破音：1 秒 600 Hz 测试音和 Steam UI
点击音都破，描述为“开头没声，后面像气泡破裂”。不是只影响 Steam UI 音效。
之后几次 gamescope 会话重启仍然存在。

## 已证实排除

- `paplay` monitor 波形正常：峰值 9000，无削波、无中途软件断流。
- PipeWire sink `s16le 2ch 48000Hz`；ALSA period 512 / buffer 4096，未见证实 xrun。
- SDDM `Relogin=false`、无旧死循环；CPU 无异常打满。
- 两颗 CS35L41 在播放期间：ASP=0x10000、PLL=0x10370、PWR1=1、
  mute=0、vol=0x3f44 (att 24)、gain=0x240、IRQ1/2 无错误；30 ms 采样无变化。
- MI2S 引脚 BCLK/WS/DATA 均活动；DAPM FE/BE 都是 S16_LE / 2ch / 48k / start。
- `armada-speaker-route` + `alioth-amp-enable` 两颗均 mailbox=True，
  恢复后破音仍在——所以重复 ramp、重启音频或降低音量都不能掩盖这个问题。
- `alioth-sound-watch` active、`POLL_S=.05`；不能仅因旧版 I2C 干扰就认定
  当前 v4 是原因。

## 时间线与高概率区域

12:15:42 suspend → 12:35:49 resume（约 20 分钟），之后经历多次会话重启。
`AUDIO-FIX-GUIDE` 已指出 resume 后音频栈重建会加剧破音；系统此前只有
boot 阶段的音频修复，没有 speaker/DSP 的 resume 处理。
但本次 mailbox 恢复无效，因此不能只补一个 resume 时的 `amp-enable` 调用
就宣称修好。

## 定位边界

**故障位于 PipeWire 之后、扬声器之前的 ADSP/Q6AFE/MI2S 时钟或数据帧
/DSP 保护固件路径。** 静态功放寄存器正常不等于实际帧时序正常。
regmap 缓存与直接 I2C 有差异，不应混作同一来源。
ADSP remoteproc2 处于 running；LPASS `clk_summary` 多为 deviceless firmware
clock，不能直接当作端口实际速率。

## 建议的下一步（先取证，不先改配置）

1. 对照 q6afe AFE port `TERTIARY_MI2S_RX` (0x1004) 的启动配置/时钟选择与
   runtime resume 后的实际参数，核实 1.536 MHz BCLK / 48k LRCLK 及帧同步；
   现有 `tlmm-probe` 只证明引脚在翻转，不能证明频率/帧对齐。
2. 查 ADSP/Q6APM 服务、端口 stop/start 顺序与 resume 行为，不先整机重启或重刷。
3. 如必须验证恢复，优先按内核/驱动支持的 AFE 端口重开顺序做，并准备精确
   命令与回退；不连续播放，不频繁 I2C 写，不把 ASP 放进 trigger。
4. 区分 suspend 是否为独立诱因：目前只有时间线相关，尚不能声称某一次修复
   直接改坏了音频。

## 采集脚本

- 只读总采集：`audio-regression-readonly.sh`
- 播放中采样：`audio-live-readonly.py`
- 电源历史：`audio-power-history-readonly.sh`
- 波形原始数据：设备 `/tmp/alioth-monitor-check.raw`
- 1 秒测试音：设备 `/tmp/alioth-short-check.wav`

## 13:54 恢复证据

一次受控测试重启 PipeWire/WirePlumber，实际走完 AFE STOP → SET_PARAM → START。
`alioth-sound-watch` 记录 `stream ended → started fixed 0x40/0x41`。
**随后同一 1 秒测试音恢复正常。**

所以根因是休眠后 AFE 端口/时钟路径异常，音频服务重开即可恢复；
不是普通音量/ASP mailbox 问题。

但 Steam UI 点击音仍无声：PipeWire 重启使 gamescope
`pipewire: stream state changed: unconnected`，CEF AudioService 不重连。
再次重启 Steam 会话后客户端注册恢复。持久修复必须把“音频重开”与
“客户端重连”作为同一恢复流程，而不是只调用 `amp-enable`。

## 相关状态

FPS 叠加层（A2 单控制源）已安装，QAM 等级 2 即时开关已确认；
snapshot watcher 生效，跨会话记忆仍待验收。
Game Mode 触摸已修复，四方向确认。内核 NCM 补丁仅本地验证，未刷机。
