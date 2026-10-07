下面这份可以直接作为 **Language Coach V1 技术设计基线**。我把前面已经确定的决策全部合并进去，并特别处理了 **Qwen3-TTS、多语言、MiniMax/DeepSeek、本地 Qwen3-0.6B、sherpa-onnx、逐句播放、Rive、聊天记录、模型管理**。

# Language Coach

## 多语言 AI 语言教练 App 技术设计文档

**版本：V1.0**
**项目名称：Language Coach**
**目标平台：Android 优先**
**UI：Flutter**
**Native：Kotlin + C/C++**
**核心模型：Qwen3 / Qwen3-TTS**
**云端 LLM：MiniMax、DeepSeek**
**ASR：sherpa-onnx**

---

# 1. 产品定位

Language Coach 不是传统翻译器。

核心定位：

> **让用户使用自然语言与 AI 对话，并通过 AI 学习另一种语言的表达、发音和实际交流。**

例如用户：

> 今天下雨，如何使用英语表达？

系统理解用户真正的意图：

```text
Intent = expression_help
Source = Chinese
Target = English
Topic = 今天下雨
```

然后：

> **It's raining today.**

并提供：

```text
🔊 播放

0.75×  1.0×  1.25×  1.5×

逐句播放

跟读
```

如果用户继续：

> 为什么用 raining？

系统进入：

```text
Intent = grammar_question
```

而不是再次翻译。

---

# 2. 核心产品原则

## 2.1 多语言，而不是英语专用

首期支持：

* English
* 日本語
* Français
* 한국어
* Español
* Deutsch
* Italiano
* 中文
* Russian
* Portuguese

Qwen3-TTS 当前覆盖上述 10 种主要语言。([GitHub][1])

---

## 2.2 默认语言是英语

这是产品默认行为：

```text
preferred_language = English
```

但不是：

```text
supported_languages = English
```

而是：

```text
supported_languages = multiple
preferred_language = English
```

用户可以在：

> Settings → Preferred Language

中修改。

---

# 3. 语言解析优先级

这是 Language Coach 非常重要的业务规则。

```text
用户输入
   │
   ▼
是否明确指定目标语言？
   │
 ┌─┴───────┐
 │         │
 YES       NO
 │         │
 ▼         ▼
使用指定语言   Preferred Language
                  │
                  ▼
               默认 English
```

例如：

### 设置

```text
Preferred Language = English
```

用户：

> 今天下雨怎么说？

→ English

> 日语怎么说？

→ Japanese

> 法语呢？

→ French

所以：

**用户明确指定 > 用户首选语言 > 默认英语**

---

# 4. 总体技术架构

```text
┌────────────────────────────────────────────────────┐
│                    Flutter UI                      │
│                                                    │
│ Chat / Voice / Settings / Practice / History       │
│ Rive / Waveform / Sentence Player                  │
└───────────────────────┬────────────────────────────┘
                        │
                  MethodChannel
                        │
┌───────────────────────▼────────────────────────────┐
│                 Android Native Core                │
│                                                    │
│ Audio / ASR / LLM / TTS / Model Manager / DB       │
└───────┬───────────────┬───────────────┬────────────┘
        │               │               │
        ▼               ▼               ▼
   sherpa-onnx      LLM Router       Qwen3-TTS
        │               │               │
        │        ┌──────┼──────┐        │
        │        ▼      ▼      ▼        │
        │     MiniMax DeepSeek Qwen3    │
        │                     0.6B       │
        │                     Local      │
        │                                │
        └──────────────┬─────────────────┘
                       ▼
                Conversation Engine
                       │
                       ▼
                     SQLite
```

---

# 5. 技术栈

| 层                | 技术                       |
| ---------------- | ------------------------ |
| UI               | Flutter                  |
| Language         | Dart                     |
| Android          | Kotlin                   |
| Native inference | C/C++                    |
| LLM local        | llama.cpp                |
| Local LLM        | Qwen3-0.6B               |
| Cloud LLM        | MiniMax / DeepSeek       |
| ASR              | sherpa-onnx              |
| VAD              | sherpa-onnx              |
| TTS              | Qwen3-TTS                |
| Animation        | Rive                     |
| Waveform         | Flutter CustomPainter    |
| Database         | SQLite / Room            |
| Audio            | AudioRecord / AudioTrack |
| API              | HTTPS + JSON             |
| Model storage    | App-private storage      |
| State            | Riverpod                 |
| Networking       | Dio                      |
| Serialization    | json_serializable        |

`sherpa-onnx` 已提供 Android 和 Flutter 的流式 ASR 方案，也提供本地运行的 Flutter TTS/ASR 示例，因此非常适合作为 Language Coach 的语音基础层。([K2 FSA][2])

---

# 6. AI 模型体系

## 6.1 LLM

Language Coach 支持三类 LLM：

```text
LlmProvider
│
├── LocalQwenProvider
│
├── MiniMaxProvider
│
└── DeepSeekProvider
```

### Local

**Qwen3-0.6B**

用途：

* 离线
* 简单表达
* 简单翻译
* 简单纠错
* 快速响应
* 降低 API 成本

### Cloud

**MiniMax**

主要承担：

* 高质量对话
* 自然语言表达
* 复杂语言学习
* Roleplay

**DeepSeek**

主要承担：

* 复杂理解
* 语法解释
* 翻译
* 改写
* 纠错

DeepSeek API 当前提供 OpenAI-compatible API，因此可以统一抽象到 `LlmProvider`。([DeepSeek API Docs][3])

---

# 7. LLM Router

```text
                    LlmRouter
                       │
               ┌───────┴───────┐
               │               │
             Auto            Manual
               │
       ┌───────┼────────┐
       │       │        │
    Simple   Complex   Offline
       │       │        │
     Qwen3   Cloud     Qwen3
              │
        ┌─────┴─────┐
        ▼           ▼
     MiniMax     DeepSeek
```

设置：

```text
AI Provider

● Auto
○ MiniMax
○ DeepSeek
○ Local Qwen3
```

---

# 8. Conversation Engine

这是整个项目最重要的业务层之一。

不要直接：

```text
User → LLM → Text
```

应该：

```text
User
 │
 ▼
Conversation Engine
 │
 ├── Language Detection
 ├── Intent Detection
 ├── Target Language Resolution
 ├── Context Management
 ├── LLM Routing
 ├── Response Validation
 └── Learning Metadata
 │
 ▼
LLM
```

---

# 9. Intent 系统

V1 定义：

```text
expression_help
translation
conversation
grammar_question
vocabulary
pronunciation
correction
explanation
roleplay
practice
```

例如：

### expression_help

> 今天下雨，怎么用英语表达？

---

### vocabulary

> 出差英语怎么说？

---

### grammar_question

> 为什么这里用 raining？

---

### correction

> I go Shanghai tomorrow.

---

### conversation

> What did you do today?

---

### roleplay

> 和我模拟一次酒店入住。

---

# 10. Structured Output

强烈建议 LLM 不直接返回纯文本。

统一：

```json
{
  "intent": "expression_help",
  "source_language": "zh-CN",
  "target_language": "en",
  "answer": {
    "primary": "It's raining today.",
    "alternatives": [
      "It's raining outside today."
    ],
    "explanation": "A natural way to describe today's rainy weather."
  },
  "sentences": [
    {
      "id": "s1",
      "text": "It's raining today."
    }
  ],
  "learning": {
    "difficulty": "beginner",
    "keywords": [
      "raining"
    ]
  }
}
```

Flutter 直接渲染。

---

# 11. ASR 架构

统一使用：

**sherpa-onnx**

```text
Microphone
    │
    ▼
AudioRecord
    │
    ▼
VAD
    │
    ▼
Streaming ASR
    │
    ▼
Text
```

支持：

```text
中文
英语
日语
法语
...
```

具体语言由 ASR model profile 决定，而不是由 Flutter UI 写死。sherpa-onnx 的 Android 文档已经提供不同语言 ASR 模型的部署方式。

---

# 12. Audio Pipeline

```text
AudioRecord
     │
     ├── PCM → VAD
     │
     ├── PCM → ASR
     │
     └── PCM → Waveform Analyzer
```

三个消费者共享同一音频流。

不要录三遍。

---

# 13. Rive 动画

Rive **不负责声音波形**。

Rive 只负责 AI 状态。

```text
IDLE
 │
 ▼
LISTENING
 │
 ▼
THINKING
 │
 ▼
SPEAKING
 │
 ▼
IDLE
```

Flutter：

```text
Audio amplitude
       ↓
CustomPainter
       ↓
Waveform
```

Rive：

```text
AIState
       ↓
State Machine
       ↓
Animation
```

这是两个完全独立的渲染系统。

---

# 14. TTS：Qwen3-TTS

正式确定：

> **Language Coach V1 使用 Qwen3-TTS。**

不再把 Piper/Kokoro 作为核心方案。

Qwen3-TTS 目前有：

* 0.6B
* 1.7B

并支持多语言及语音控制。([GitHub][1])

---

# 15. Qwen3-TTS Android 策略

V1：

```text
Qwen3-TTS 0.6B
```

V2：

```text
Qwen3-TTS 1.7B
```

根据设备能力：

```text
Device Capability
        │
 ┌──────┴──────┐
 ▼             ▼
普通设备       高端设备
 │             │
0.6B           1.7B
```

已有第三方 Android 项目已经验证了 Qwen3-TTS 0.6B Q4_K_M 在 Android 本地运行的技术路线，包括 tokenizer/talker GGUF、App-private storage 和 CPU runtime。这个项目不是官方实现，因此只能作为可行性参考。([GitHub][4])

---

# 16. Qwen3-TTS 多语言模型管理

这里采用：

> **共享模型 + language parameter**

而不是：

```text
English model
Japanese model
French model
```

模型：

```text
Qwen3-TTS
     │
     ├── English
     ├── Japanese
     ├── French
     ├── Korean
     ├── German
     └── ...
```

调用时：

```kotlin
tts.synthesize(
    text = text,
    language = "en"
)
```

或者：

```kotlin
tts.synthesize(
    text = text,
    language = "ja"
)
```

---

# 17. 不按语言拆主模型权重

Language Coach 的模型管理不要设计成：

```text
qwen-tts-en.bin
qwen-tts-ja.bin
qwen-tts-fr.bin
```

而是：

```text
models/
└── qwen3-tts/
    ├── 0.6b/
    │   ├── tokenizer/
    │   ├── talker/
    │   └── config/
    │
    └── 1.7b/
        ├── tokenizer/
        ├── talker/
        └── config/
```

语言只是运行参数：

```text
language = en
language = ja
language = fr
```

---

# 18. 为什么这么设计

因为 Qwen3-TTS 是共享的多语言模型。

真正适合拆的是：

```text
模型版本
Voice
Tokenizer
Runtime
```

而不是强行按语言拆模型。

因此：

```text
Core Model
+
Voice Profile
+
Language
+
Speed
+
Emotion / Style
```

组合成最终 TTS 请求。

---

# 19. TTS 接口

Kotlin：

```kotlin
data class TtsRequest(
    val text: String,
    val language: String,
    val voiceId: String,
    val speed: Float,
    val emotion: String? = null
)
```

例如：

```json
{
  "text": "It's raining today.",
  "language": "en",
  "voiceId": "default",
  "speed": 1.0
}
```

日语：

```json
{
  "text": "今日は雨が降っています。",
  "language": "ja",
  "voiceId": "default",
  "speed": 1.0
}
```

---

# 20. 音色不和 LLM 绑定

这是正式架构原则。

错误：

```text
MiniMax → Voice A
DeepSeek → Voice B
```

正确：

```text
LLM
 │
 ▼
Text
 │
 ▼
TTS
 │
 ├── Language
 ├── Voice
 ├── Speed
 └── Style
```

用户即使从 MiniMax 切换到 DeepSeek：

> **声音完全不应该变化。**

---

# 21. Voice Profile

```kotlin
data class VoiceProfile(
    val id: String,
    val name: String,
    val language: String,
    val speaker: String?,
    val modelVersion: String,
    val gender: String?,
    val description: String?
)
```

数据库：

```text
voice_profiles

id
name
language
speaker
model_version
description
created_at
```

---

# 22. 语速

支持：

```text
0.75x
0.85x
1.00x
1.15x
1.25x
1.50x
```

默认：

```text
1.0x
```

语速属于：

```text
TTS Setting
```

不是：

```text
LLM Setting
```

---

# 23. 逐句播放

这是 Language Coach 的核心功能。

LLM：

```text
I'm going to Shanghai tomorrow.
I have an important meeting there.
So I'll probably stay for two days.
```

Sentence Splitter：

```text
S1
I'm going to Shanghai tomorrow.

S2
I have an important meeting there.

S3
So I'll probably stay for two days.
```

分别 TTS：

```text
S1 → audio_001
S2 → audio_002
S3 → audio_003
```

播放器：

```text
S1
 ↓
S2
 ↓
S3
```

---

# 24. UI

```text
┌─────────────────────────────┐
│ Language Coach              │
│                             │
│ 🇺🇸 English             ▼   │
├─────────────────────────────┤
│                             │
│ 你                           │
│ 今天下雨怎么用英语表达？     │
│                             │
│ AI                           │
│ It's raining today.         │
│                             │
│ 🔊  ▶  0.75× 1× 1.25×      │
│                             │
│ ─────────────────────────── │
│                             │
│ 解释                         │
│ raining 是 rain 的现在分词   │
│                             │
└─────────────────────────────┘
```

---

# 25. Chat Message 数据结构

```kotlin
data class ChatMessage(
    val id: String,
    val conversationId: String,
    val role: MessageRole,
    val sourceText: String?,
    val targetText: String?,
    val language: String?,
    val intent: String?,
    val model: String?,
    val createdAt: Long
)
```

---

# 26. 数据库

```text
conversations
────────────────────────
id
title
preferred_language
created_at
updated_at


messages
────────────────────────
id
conversation_id
role
source_text
target_text
language
intent
model
created_at


sentences
────────────────────────
id
message_id
sequence
text
audio_path
duration
created_at


voice_profiles
────────────────────────
id
name
language
speaker
model
description


settings
────────────────────────
key
value
```

---

# 27. 音频文件

不要把 WAV/Binary 直接存 SQLite。

使用：

```text
app-private/
└── audio/
    └── conversations/
        └── conversation-id/
            ├── sentence-001.wav
            ├── sentence-002.wav
            └── sentence-003.wav
```

SQLite 只保存：

```text
audio_path
```

---

# 28. 模型管理器

建立：

```text
ModelManager
```

负责：

```text
模型发现
下载
暂停
恢复
校验
删除
版本更新
空间检测
设备能力检测
模型加载
模型卸载
```

结构：

```kotlin
interface ModelManager {

    suspend fun check(modelId: String): ModelStatus

    suspend fun download(modelId: String)

    suspend fun delete(modelId: String)

    suspend fun load(modelId: String)

    suspend fun unload(modelId: String)
}
```

---

# 29. 模型目录

```text
/files/models/

├── llm/
│   └── qwen3-0.6b/
│
├── tts/
│   ├── qwen3-tts-0.6b/
│   └── qwen3-tts-1.7b/
│
└── asr/
    ├── zh/
    ├── en/
    ├── ja/
    └── fr/
```

---

# 30. 不把模型塞进 APK

这一点必须坚持。

APK：

```text
Language Coach APK
≈ UI + Runtime + Native Library
```

模型：

```text
首次运行下载
```

否则：

```text
APK
+
Qwen3
+
Qwen3-TTS
+
ASR
```

会导致安装包巨大。

llama.cpp 的 Android 文档本身支持从 app-private storage 加载模型文件，并提供 Android NDK 构建路径。([GitHub][5])

---

# 31. Local LLM Runtime

Qwen3-0.6B：

```text
GGUF
   ↓
llama.cpp
   ↓
JNI
   ↓
Kotlin
   ↓
Flutter
```

llama.cpp 已有 Android 构建文档，并支持 Android NDK / ARM64 路线。([GitHub][5])

---

# 32. Flutter ↔ Native

建议不要让 Flutter 直接控制底层模型。

```text
Flutter
   │
MethodChannel
   │
Kotlin
   │
Native AI Core
```

例如：

```dart
final result = await ai.invokeMethod(
  'generate',
  {
    'prompt': prompt,
    'model': 'qwen3-0.6b',
  },
);
```

TTS：

```dart
await ai.invokeMethod(
  'synthesize',
  {
    'text': text,
    'language': 'en',
    'voice': 'default',
    'speed': 1.0,
  },
);
```

---

# 33. 推荐进一步使用 Event Stream

因为：

* ASR 是流式
* LLM 是流式
* TTS 可以流式
* 音频播放有进度

所以不要全部使用一次性 MethodChannel。

建议：

```text
MethodChannel
    ↓
命令

EventChannel
    ↓
实时事件
```

例如：

```text
ASR_PARTIAL
ASR_FINAL
LLM_TOKEN
LLM_COMPLETE
TTS_START
TTS_PROGRESS
TTS_COMPLETE
AUDIO_PROGRESS
```

---

# 34. 语音对话完整流程

```text
User presses microphone
        │
        ▼
Rive = LISTENING
        │
        ▼
AudioRecord
        │
        ▼
sherpa VAD
        │
        ▼
sherpa ASR
        │
        ▼
Chinese text
        │
        ▼
Conversation Engine
        │
        ├── Intent
        ├── Language
        └── Context
        │
        ▼
LLM Router
        │
        ├── Qwen3
        ├── MiniMax
        └── DeepSeek
        │
        ▼
Structured Response
        │
        ▼
Sentence Splitter
        │
        ▼
Qwen3-TTS
        │
        ▼
Audio Queue
        │
        ├──────────────┐
        ▼              ▼
Flutter Player       Rive
                     SPEAKING
```

---

# 35. AI 状态机

Flutter：

```dart
enum AiState {
  idle,
  listening,
  processing,
  speaking,
  paused,
}
```

Rive：

```text
idle
 ↓
listening
 ↓
thinking
 ↓
speaking
 ↓
idle
```

---

# 36. Practice 模式

V1.5 可以增加：

```text
AI：
I'm going to Shanghai tomorrow.

        ↓

🎤 Your turn

        ↓

用户跟读

        ↓

ASR

        ↓

Comparison Engine
```

比较：

```text
Expected:
I'm going to Shanghai tomorrow.

Actual:
I'm going Shanghai tomorrow.
```

结果：

```text
Grammar
82%

Pronunciation
91%

Naturalness
76%
```

---

# 37. Roleplay

这是 Language Coach 后续非常重要的功能。

例如：

```text
Scenario

☕ Coffee Shop
🏨 Hotel
✈️ Airport
💼 Business Meeting
🛍 Shopping
🏥 Hospital
🍽 Restaurant
```

用户：

> Let's practice hotel check-in.

AI：

> Good evening. Welcome to the hotel. Do you have a reservation?

用户直接说话。

系统：

```text
ASR
 ↓
LLM
 ↓
Roleplay
 ↓
TTS
```

---

# 38. Settings

```text
Settings
│
├── Language
│   └── Preferred Language
│
├── Voice
│   ├── Voice
│   ├── Speech Speed
│   └── Auto Play
│
├── AI
│   ├── Provider
│   ├── MiniMax API
│   ├── DeepSeek API
│   └── Local Model
│
├── Models
│   ├── Qwen3
│   ├── Qwen3-TTS
│   └── ASR
│
├── Conversation
│   ├── Save History
│   └── Auto Title
│
└── Privacy
```

---

# 39. AI Provider 设置

```text
AI Provider

● Auto

○ MiniMax
○ DeepSeek
○ Local Qwen3
```

MiniMax / DeepSeek API Key：

```text
API Key
[*********************]
```

API Key 必须：

> Android Keystore / EncryptedSharedPreferences

不要明文写 SQLite。

---

# 40. 模型下载中心

```text
Models
────────────────────────

LLM

Qwen3 0.6B
✓ Installed

TTS

Qwen3-TTS 0.6B
✓ Installed

Qwen3-TTS 1.7B
↓ Download

ASR

English
✓ Installed

Japanese
↓ Download

French
↓ Download
```

---

# 41. 设备能力检测

启动时：

```text
DeviceCapability
```

检测：

```text
RAM
CPU cores
ABI
NEON
GPU
NPU
Android version
Storage
```

然后：

```text
if ram >= threshold:
    allow 1.7B

else:
    recommend 0.6B
```

但**不能仅用 RAM 做判断**。

最终应该建立 benchmark：

```text
Model Benchmark
──────────────────
load time
first token
tokens/sec
tts realtime factor
peak memory
temperature
```

---

# 42. 内存管理

非常重要。

不要同时：

```text
Qwen3-0.6B
+
Qwen3-TTS 1.7B
+
ASR
```

全部常驻内存。

应该：

```text
ASR active
    ↓
LLM active
    ↓
LLM release / suspend
    ↓
TTS active
```

或者：

```text
ASR
 ↓
LLM
 ↓
TTS
```

采用模型生命周期管理：

```text
ModelManager
   │
   ├── load
   ├── warmup
   ├── inference
   └── unload
```

---

# 43. Android 后台限制

语音会话期间需要：

```text
Audio Focus
Foreground Service
Wake Lock
```

但是只有真正进入持续语音会话时才使用，不要常驻后台。

---

# 44. 项目目录

```text
language-coach/
│
├── android/
│
├── ios/
│
├── lib/
│   ├── app/
│   │
│   ├── core/
│   │   ├── ai/
│   │   ├── audio/
│   │   ├── database/
│   │   ├── language/
│   │   └── model/
│   │
│   ├── features/
│   │   ├── chat/
│   │   ├── voice/
│   │   ├── practice/
│   │   ├── roleplay/
│   │   ├── history/
│   │   └── settings/
│   │
│   ├── rive/
│   │
│   └── widgets/
│
├── assets/
│   ├── rive/
│   └── icons/
│
└── native/
    ├── llama/
    ├── qwen_tts/
    └── sherpa/
```

---

# 45. Flutter 页面

V1：

```text
Home
 │
 ├── Chat
 │
 ├── Voice Input
 │
 └── Language Selector


Conversation
 │
 ├── Messages
 ├── Sentence Player
 ├── Voice
 └── Practice


History
 │
 ├── Conversations
 └── Search


Practice
 │
 ├── Repeat
 ├── Shadowing
 └── Correction


Settings
 │
 ├── Language
 ├── Voice
 ├── AI
 ├── Models
 └── Privacy
```

---

# 46. 第一阶段 MVP

不要一开始做全部。

> **开发顺序原则（2026-10-07）：优先使用并完善线上大模型 MiniMax / DeepSeek；本地 Qwen3 暂缓开发。**
> 在云端对话、结构化回复、解释质量和错误处理达到可用标准之前，不投入本地 LLM 的提示词、解析、推理性能或模型管理优化。现有本地模型代码保留，但不作为当前迭代的验收主路径。

### Phase 1

完成：

```text
Flutter
+
聊天框
+
文字输入
+
MiniMax
+
DeepSeek
```

目标：

> 先把“AI 对话”跑通。

验收与问题修复均以线上模型链路为先：

```text
MiniMax / DeepSeek
→ 结构化回复
→ 教学解释
→ 上下文连续性
→ 异常与重试
```

---

### Phase 2

加入：

```text
sherpa-onnx ASR
```

完成：

> 按住说话 → 识别 → AI 回答

---

### Phase 3

加入：

```text
Qwen3-TTS 0.6B
```

完成：

> AI 回复 → 自动说出来

---

### Phase 4

加入：

```text
Sentence Splitter
+
Sentence Audio Cache
+
Speed
```

完成：

> **逐句播放**

---

### Phase 5

加入：

```text
Rive
+
Voice Waveform
```

完成完整 AI 语音交互体验。

---

### Phase 6

加入：

```text
Practice
Roleplay
Correction
```

形成完整 Language Coach。

---

### Phase 7（暂缓）

在上述线上主链路稳定后，再恢复：

```text
Qwen3-0.6B 本地 LLM
+
本地提示词与结构化回复解析
+
端侧推理性能和内存优化
+
本地模型下载与管理体验
```

目标：

> 在不影响线上大模型体验迭代的前提下，补齐离线对话能力。

---

# 47. MVP 最终闭环

第一版真正可用的版本应该做到：

```text
用户
 │
 ▼
🎤 今天下雨，怎么用英语表达？
 │
 ▼
sherpa-onnx
 │
 ▼
中文文本
 │
 ▼
Conversation Engine
 │
 ▼
MiniMax / DeepSeek
 │
 ▼
It's raining today.
 │
 ▼
Qwen3-TTS
 │
 ▼
🔊 播放
 │
 ▼
逐句播放
 │
 ▼
聊天记录保存
```

同时：

```text
Settings
   ↓
Preferred Language
   ↓
English / Japanese / French / ...
```

---

# 48. V1 最终技术决策

| 模块          | 最终方案                          |
| ----------- | ----------------------------- |
| 项目          | **Language Coach**            |
| UI          | Flutter                       |
| Android     | Kotlin                        |
| Native      | C/C++                         |
| LLM 本地      | Qwen3-0.6B                    |
| LLM 云端      | **MiniMax + DeepSeek**        |
| LLM Router  | 自研                            |
| ASR         | **sherpa-onnx**               |
| VAD         | **sherpa-onnx**               |
| TTS         | **Qwen3-TTS**                 |
| TTS 默认      | 0.6B                          |
| TTS 高端      | 1.7B                          |
| TTS 多语言     | 支持                            |
| 默认语言        | **English**                   |
| 用户首选语言      | Settings 可修改                  |
| 临时目标语言      | 对话中可指定                        |
| 动画          | Rive                          |
| Waveform    | Flutter CustomPainter         |
| 语速          | 0.75x–1.5x                    |
| 逐句播放        | **V1 核心功能**                   |
| 聊天历史        | SQLite                        |
| 模型下载        | App-private storage           |
| LLM Runtime | llama.cpp                     |
| API         | OpenAI-compatible abstraction |
| Offline     | 支持                            |
| Cloud       | 支持                            |
| Voice 与 LLM | **完全解耦**                      |

---

# 49. 最终产品架构图

```text
                         ┌───────────────────┐
                         │  Language Coach   │
                         └─────────┬─────────┘
                                   │
                    ┌──────────────┼──────────────┐
                    │              │              │
                  Input          AI Core         Output
                    │              │              │
              ┌─────┴─────┐  ┌────┴─────┐  ┌─────┴─────┐
              │           │  │          │  │           │
             Text        Voice Intent   LLM TTS       UI
                          │     │        │   │          │
                          ▼     ▼        ▼   ▼          ▼
                       sherpa  Engine MiniMax Qwen3    Rive
                       ONNX            DeepSeek TTS  Waveform
                                       Qwen3
                                        Local
                                          │
                                          ▼
                                   Sentence Engine
                                          │
                               ┌──────────┼──────────┐
                               ▼          ▼          ▼
                             Audio     Learning   History
                               │          │          │
                               ▼          ▼          ▼
                            Playback   Practice    SQLite
```

这套方案已经可以进入**工程实现阶段**。其中最需要提前做技术验证的不是 Flutter，而是 **Android 上 Qwen3-TTS 0.6B 的实际推理速度、峰值 RAM、量化格式，以及它与 sherpa-onnx/ASR 同时工作时的内存竞争**。已有 Android Qwen3-TTS 0.6B Q4_K_M 的第三方实现说明这条本地路线具备可行性，但正式产品仍应以目标机型 benchmark 为准。([GitHub][4])

[1]: https://github.com/oseibonsu/qwen3-tts/blob/main/README.md?utm_source=chatgpt.com "qwen3-tts/README.md at main · oseibonsu/qwen3-tts · GitHub"
[2]: https://k2-fsa.github.io/sherpa/onnx/flutter/pre-built-app.html?utm_source=chatgpt.com "Pre-built Flutter Apps — sherpa 1.3 documentation"
[3]: https://api-docs.deepseek.com/quick_start/pricing-details-cny/?utm_source=chatgpt.com "Your First API Call | DeepSeek API Docs"
[4]: https://github.com/Danmoreng/qwen3-tts-android/blob/main/README.md?utm_source=chatgpt.com "qwen3-tts-android/README.md at main · Danmoreng/qwen3-tts-android · GitHub"
[5]: https://github.com/ggml-org/llama.cpp/blob/master/docs/android.md?utm_source=chatgpt.com "llama.cpp/docs/android.md at master · ggml-org/llama.cpp · GitHub"
