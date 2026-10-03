# 暂停与继续录制（#12）

工具条的“暂停”同时暂停屏幕和麦克风写入；系统确认后变为“继续”。暂停期间计时冻结，可以直接结束。切换中显示“正在暂停/继续”，禁止重复切换，仍可结束。工具条保持非激活、置顶、可拖动和跨 Space 行为。

暂停/切换中禁用新标记、新画笔和标记快捷键。已有画笔保留截图与笔迹，冻结新增笔划，仍可保存或取消；继续后可重新落笔。结束时保存一次当前画笔，保存失败保留内容并明确报错。暂停不产生新卡片，沿用 #10 的截图和讲解规则。

## 文件、时钟与故障

- 在同一 AVCaptureSession、屏幕输入、原麦克风及 AVCaptureMovieFileOutput 上使用原生 pauseRecording/resumeRecording，始终写入同一 MOV。没有分段文件、全片合成或第二次编码。
- pausing/resuming 由对应 delegate 确认，每次只保留一个请求。8 秒未确认会中断并保留文件；Stop 取消待处理转换，沿用 20 秒封口 watchdog。输出身份、文件 URL、录制世代和预期状态拦截旧回调。
- 媒体时钟取自同一文件输出的音频样本 PTS；start/pause/resume/stop 在该输出的采样边界执行。只保留当前有效区间起点和累计时长，暂停确认后冻结，不使用墙钟，不缓存帧、不重写样本、不再次扣除暂停时间。延迟截图包含录制 ID、事件 ID 和切换世代，快速暂停再继续也不能补拍旧请求。
- 截图、画笔区间、WAV 和 ASR 保持录制坐标。AudioChunker 保留真实音轨起点和缺口；供应商毫秒除以 1000 后只加一次分片起点，不人为删静音来掩盖暂停空档。
- 有意暂停时不累计麦克风 inactive/静音计时；继续时重置并检查原连接。设备断开、会话错误、系统睡眠仍中断，不静默切换麦克风。
- 稳定 paused/recording 及有效时长原子保存。失败显示“项目未保存”，不回滚已生效的媒体状态；下次暂停、继续或结束重试保存。崩溃遗留 paused 项目打开后转为 interrupted，不追加旧 MOV、不自动上传。
- 暂停及转换中仍为 busy，阻止退出/安装更新。仅最终 didFinish 后，视频轨有限正时长且能解码、音频检查和项目保存成功，才消费一次自动转写机会。暂停/继续不重新 arm 或消费门闩。
- 暂停只停止写文件，会话仍运行；不承诺释放麦克风、熄灭隐私指示灯或零 CPU。

## 验证方法与边界

核心测试覆盖 50 次转换、重复/旧确认、Stop 抢先、超时状态、截图世代、时钟冻结/单调、不重复扣除暂停与崩溃恢复。原生离线替身驱动真实 RecordingEngine 串行 queue、AVCaptureMovieFileOutput delegate、watchdog 和完成回调，覆盖 50 次、暂停直接结束、转换中结束、旧 output 和丢失确认。替身不等同于设备采集。

UI fixture 检查各状态工具条和更新保护；鼠标事件检查冻结笔迹、继续绘制与暂停保存一次。媒体 fixture 使用真实 AVFoundation 编码/解码检查视频、AAC/WAV、音轨偏移与分片。CI 还尝试实录 probe：权限或设备缺失时退出 77 并保存 status=unavailable，这不是采集通过。

在已经授权屏幕和麦克风的目标 Mac 执行（实际录制屏幕和系统默认麦克风；测试窗口覆盖屏幕为单色，无网络转写）：

```sh
"/Applications/Point & Tell.app/Contents/MacOS/PointAndTell" --capture-pause-probe "$HOME/Desktop/PointTell-pause-test-$(date +%s)"
```

运行约一分钟：录制 10 秒，暂停 30 秒，再录 8 秒。检查 MOV 约 18 秒、暂停计时冻结、视频不含暂停时的紫色画面、音视频 PTS 不含暂停长度缺口，以及生产 AudioChunker 输出单段约 18 秒 WAV。恢复后第 2 秒显示短暂橙色标记，核对该画面的实际成片 PTS 与截图时钟，误差必须小于 0.5 秒；实时最终读数与成片时长也必须小于 0.5 秒。随后进行第二次短录制，从已暂停状态直接结束，确认文件可解码且时间一致。results.json、MOV 和 WAV 留在该目录；失败不删除源文件。

### 2026-10-03 Intel 真机反馈

PR #14 与 #16 已合入 main，源码 0.5.1 / build 13。北京时间 15:04，用户在收到 0.5.1 Universal 测试包后反馈 Intel 真机实际测试完全没有问题，记录为用户设备使用通过。

这项反馈与自动化结果分别保留：[CI 37104362726](https://github.com/kejun/point-and-tell/actions/runs/37104362726) 的 arm64 任务全部通过，Intel 的 182 项核心测试、Universal 构建、更新安全、AAC 和 UI 通过，但暂停探针仍报告暂停画面写入 MOV。用户选择暂缓该 CI 差异调查，随后明确确认 0.5.1 真机无问题并要求关闭 [#12](https://github.com/kejun/point-and-tell/issues/12)，该 issue 已按用户验收关闭。此次反馈没有附带具体系统配置或逐项 probe/性能日志，下面的细分检查不因此自动全部勾选。

### 0.5.1 正式发布验收

用户随后要求发布 0.5.1 正式版。[验收记录](release-acceptance-0.5.1.json) 固定了已测试包的 SHA-256、源提交和全部应用源码、资源、依赖及打包脚本的 Git 对象标识。main 的 CI 和正式发布仍运行原探针；仅当版本为 0.5.1 / build 13、运行于 Intel、应用输入完全一致，且唯一报告为 `Paused magenta screen was written into MOV`、没有采集错误时，发布门禁接受用户真机验收。原 `results.json` 仍为 `failed`，任务摘要和日志明确显示 `accepted-on-device` 警告，媒体和报告继续作为 CI 产物保存。

这不是修复或探针通过，也不会推广到 Apple Silicon、新错误、PR、未来版本或改变后的应用代码。缺失报告、崩溃、非预期退出码、音频/时间戳错误继续失败。编译、核心测试、UI、导出、更新替换、签名及不可覆盖归档等其他门禁均保留。发布工具的回归测试覆盖验收范围和失效条件；不改变项目数据或录制逻辑。

### 实录发现及路线调整

macOS 15.7.9 CI 的真实屏幕/虚拟麦克风输出暴露了两个行为：暂停/恢复 delegate 到达时 `isRecordingPaused` 尚未切换；原始 `recordedDuration` 包含最终 MOV edit list 不呈现的区间，一次暂停后可比成片快约 2 秒。单纯关闭 B 帧没有消除偏差，因此保留系统协商编码设置，采用 macOS 10.8 已支持的 `AVCaptureFileOutputDelegate` 在同一输出的采样边界控制与计时。未引入 AVAssetWriter 或分段合成，也没有用固定偏移或删音频静音掩盖差异。与 issue 最初“直接读取 recordedDuration”的建议不同，这一调整基于保存的实录 MOV 和时间映射；原始读数仅保留在诊断日志中。

开启 sample-accurate control 会让系统在采集会话启动时准备编码器；暂停仍保持会话运行。首次 didStart 确认写文件后以当前媒体 PTS 校准起点，排除编码器准备阶段；之后控制以音频采样边界为准，避免视频编码重排延迟进入计时。回调只读取时间和执行一个待处理命令，不持有帧或音频数据；目标机器上的 CPU/能耗仍需实测。

仍须分别记录 Intel macOS 11.7.11 / 8 GB 和 Apple Silicon 的真实结果，人工检查拍手/画面提示同步、暂停中讲话未录入、跨暂停 seek、5/10 fps、断设备/睡眠、长录制多次暂停、CPU/内存与封口延迟。自动 probe 不提供语义音画同步证据，CI 成功不代表 Big Sur 或长期性能已验收。若原生实录 MOV/PTS 不满足要求，保留媒体证据分析后再评估分段合成，不用冻结 UI 或随意删静音掩盖。

参考：Apple [pauseRecording](https://developer.apple.com/documentation/avfoundation/avcapturefileoutput/pauserecording())、[resumeRecording](https://developer.apple.com/documentation/avfoundation/avcapturefileoutput/resumerecording())、[录制 delegate](https://developer.apple.com/documentation/avfoundation/avcapturefileoutputrecordingdelegate)、[文件输出样本边界 delegate](https://developer.apple.com/documentation/avfoundation/avcapturefileoutputdelegate)。
