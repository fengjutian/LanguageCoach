# Language Coach

Language Coach 是一个 Android 优先的多语言 AI 语言教练。产品与技术基线见 [docs/TECHNICAL_DESIGN_V1.md](docs/TECHNICAL_DESIGN_V1.md)。

当前实现是 Phase 1 可运行骨架：

- 多语言对话与默认目标语言设置
- 显式目标语言优先解析
- `Auto / MiniMax / DeepSeek / Local Qwen3` 路由
- 结构化教练回复、逐句视图和语速控制
- 会话历史与模型管理页面原型
- Native AI Core 的命令/事件边界
- Android 原生语音识别（实时转写、麦克风权限与错误事件）

## 运行

```bash
flutter pub get
flutter run
```

默认使用内置 Demo Provider，因此无需 API Key 就能体验完整 UI 流程。云端与本地模型接入点位于 `lib/core/ai`。

语音输入当前使用 Android `SpeechRecognizer`，可用性及离线能力取决于设备安装的语音识别服务；后续可在保持 Flutter 事件协议不变的情况下替换为 sherpa-onnx。

