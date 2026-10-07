# 对话模块 Bug Review 与完整实现方案

> 目标读者：MiniMax 开发代理  
> Review 基线：`8e6d82f`（2026-10-07）  
> 范围：普通对话、会话列表、历史恢复、目标语言、流式生成、消息持久化、TTS/ASR 联动  
> 本文是实现规格，不是现状说明的简单摘要。开发时应按“目标架构”和“验收标准”一次性收口，不要只给按钮增加 `setState`。

## 1. 结论

当前最主要的问题不是单个按钮失效，而是“当前会话”没有统一状态源：

- `ChatPage` 自己持有 `_currentConversationId`、`messages`、`isStreaming` 等状态；
- 抽屉和历史页只修改 `AppSettings.lastConversationId`；
- `ChatPage` 只在首次 `_hydrate()` 时读取一次 `lastConversationId`，后续不监听；
- 设置中的目标语言、数据库中的会话语言、单次请求的目标语言和模型返回的语言之间没有明确的权威关系。

直接结果：

1. 点击“新建对话”只把 `lastConversationId` 清空，页面中的旧 ID 和旧消息完全没变。
2. 点击历史会话只改设置，不加载被选会话。
3. 语言选择器虽然更新了全局设置，但已有会话的语言语义不明确；模型返回的 `targetLanguage` 还能覆盖客户端已经解析出的目标语言。
4. 流式请求完成时使用“此刻的当前会话 ID”保存结果，而不是请求开始时的会话 ID，切换会话后存在串写风险。

建议重构为一个 `ChatController`/`ChatSessionController`，由它独占当前会话、消息、加载状态和流式生命周期。UI、抽屉、历史页只能调用明确的 command：`newConversation()`、`openConversation(id)`、`send(text)`、`stop()`、`retry()`。

## 2. 已确认 Bug 清单

### P0-1：新建对话没有创建新对话

现状：

- `_ChatDrawer` 的新建按钮只调用 `setLastConversationId(null)`。
- `_ChatPageState._currentConversationId` 没有清空或重新生成。
- `messages` 没有清空。
- 正在进行的生成、TTS、ASR 没有停止。
- `_lastUserInput`、滚动位置和错误状态没有重置。

用户可见行为：点击成功提示后仍看到旧消息，下一条消息仍可能进入旧会话。

### P0-2：切换/恢复历史会话无效

现状：抽屉和 `HistoryPage` 都只更新 `lastConversationId`；`_hydrate()` 受 `_hydrated` 保护，只执行一次。关闭抽屉时的 `setState()` 只是重绘旧内存数据，不会重新查询数据库。

影响：

- 抽屉选择会话无效；
- 历史页“恢复该对话”无效；
- 删除全部历史后聊天页仍可能显示已经删除的消息；
- 冷启动能恢复，运行中切换不能恢复，行为不一致。

### P0-3：会话切换与流式回复存在串写竞态

`_persistAssistant()` 在回复完成时读取 `_currentConversationId`。如果请求 A 发出后用户切到会话 B，A 的回复可能被保存到 B。类似风险还包括旧加载请求晚于新加载请求返回，从而覆盖新会话消息。

要求：每个发送操作必须捕获不可变的 `conversationId + operationId/epoch`。回调先核对 epoch；持久化永远使用捕获的会话 ID，不能读取可变的“当前 ID”。切换或新建前必须停止/取消当前生成。

### P0-4：目标语言缺少端到端强约束

当前 HEAD 已在在线模型 user prompt 中加入 `required target language: <code>`，这比旧版本正确；因此用户设备上“切日语仍出英语”也可能包含旧 APK/旧构建未更新的因素。但当前实现仍有以下漏洞：

- `StructuredResponseParser` 优先采用模型返回的 `targetLanguage`，模型写错时会覆盖客户端确定的语言；
- 无输出语言校验，模型即使回答英语也会被当作日语结果展示和送入日语 TTS；
- 对话历史可能主要是英语，切换语言后模型容易受旧上下文影响；
- 会话表的 `preferred_language`/`target_language` 只在首次插入时写入，之后不更新，也没有在恢复会话时读回；
- 全局首选语言和会话目标语言混用，产品语义不明确；
- 显式语言指令会覆盖选择器，这是设计文档规定的“显式指定 > 首选语言 > 英语默认”，UI 应把本轮实际语言显示清楚，避免用户误以为选择器绝对覆盖输入。

### P0-5：发送给模型的上下文包含重复和无效消息

`send()` 先把本轮 `userMsg` 和空 assistant placeholder 加入 `messages`，然后 `_recentContext()` 把它们作为历史传入 provider；provider 又追加当前 `request.text`。因此：

- 本轮用户输入出现两次；
- 空 assistant placeholder 被加入上下文；
- 错误消息也可能被映射为空 assistant 消息；
- 简单按最后 20 条截断可能从半个 turn 开始。

这会影响语言遵循、回答质量和 token 使用量。

### P1-1：历史列表不会在新消息或自动标题后及时刷新

保存用户/助手消息、修改自动标题后没有 invalidate/refresh `historyControllerProvider`。抽屉可能持续显示旧列表、旧排序、旧标题和旧 preview。

### P1-2：删除当前会话后的选择和页面状态未清理

`HistoryController.deleteConversation()` 只删除数据库并刷新列表：

- 不判断删除的是否为当前会话；
- 不清除 `lastConversationId`；
- 不通知聊天状态创建空白 draft；
- 聊天页仍显示已删除的内存消息；
- 后续发送可能用同一个 ID 通过 `ensureConversation()` 把它“复活”。

### P1-3：重试语义错误

`retryLast()` 把 `_lastUserInput` 再次放进输入框并调用 `send()`，会新增一条重复用户消息和新的回答，同时保留旧错误/旧回答。它不是“重新生成最后一条回答”。

正确语义：定位最后一个 user turn，移除/替换其后的失败或 assistant turn，在同一 user turn 上重新生成；数据库更新必须与 UI 一致。

### P1-4：停止生成后的持久化和展示不一致

取消时只在部分 JSON 可解析且非截断时保存；截断占位只存在内存，重启后消失。应明确产品规则：推荐将取消状态作为消息状态保存，或者彻底移除空 assistant placeholder；不能让运行时和恢复后的对话结构不同。

### P1-5：会话与语言元数据模型不完整

数据库已经有 `preferred_language`、`target_language`，但 repository 的 `findById()` 只返回 id/title/updatedAt，无法恢复语言。语言变更后 `ensureConversation()` 对已有记录也不更新元数据。

### P1-6：保存设置采用无序 fire-and-forget，存在覆盖竞态

每个 setter 都 `unawaited(_persist())`，而 `_persist()` 读取执行时的 `state`。快速执行“切语言 → 新建/切换会话”等操作时会产生多个并发写。虽然很多情况下都读取最新 state，但没有顺序、错误处理或完成保证，不适合作为会话切换协议的一部分。

### P1-7：历史页恢复流程体验不完整

历史页点击后只 toast“请回到对话页查看”，不主动切回 Chat tab；而当前实现回去也不会加载。应由 Home 层提供导航 command，点击历史项后执行 `openConversation(id)` 并切换到 Chat tab。

### P2-1：输入长度只显示超限，不阻止发送

UI 在超过 500 字时只改变计数颜色，`send()` 没有长度校验，发送按钮也没有禁用。

### P2-2：空白会话和持久化时机没有明确规则

建议“新建”先创建内存 draft ID，不立即写数据库；第一条用户消息落库时才创建会话，避免连续点击新建产生大量空会话。ID 一旦生成，在该 draft 生命周期内保持稳定。

### P2-3：ASR 输入语言默认跟随学习目标语言，容易造成识别错误

目前没有显式 ASR 输入语言时，直接使用目标语言。中国用户把目标切到日语后用中文提问，系统 ASR 会按日语识别。虽然代码注释说明两者应独立，但默认策略与典型使用场景冲突。建议默认 `auto`/系统自动识别，或单独持久化“输入语言”。

## 3. 目标行为定义

### 3.1 新建对话

调用 `newConversation()` 后必须原子完成：

1. 取消 LLM 流；停止 TTS；取消 ASR（如正在录音）。
2. 增加 session epoch，使所有旧异步回调失效。
3. 创建新的 draft conversation ID。
4. 清空 messages、错误、last user turn、loading/streaming 状态和输入框。
5. 设置并持久化 `lastConversationId` 为新 ID；若采用 lazy draft，可允许 ID 尚未出现在 conversations 表。
6. UI 立即显示空状态。
7. 第一条消息发送后创建 DB conversation，并刷新历史列表。

### 3.2 打开历史会话

调用 `openConversation(id)` 后：

1. 若已经是当前会话，可直接关闭抽屉，不重复加载。
2. 取消当前生成/播放/录音并增加 epoch。
3. 进入 loading 状态，查询 conversation metadata 和 messages。
4. 只有请求 epoch 仍然有效时才提交加载结果。
5. 更新 `lastConversationId`。
6. 按产品规则恢复该会话的目标语言；推荐恢复 `conversation.targetLanguage`，同时不强制修改用户的全局默认语言。
7. 滚动到底部，并关闭抽屉/切换到 Chat tab。
8. ID 不存在时进入可恢复错误状态，并新建空白 draft，不能静默保留旧消息。

### 3.3 语言规则

定义三个不同概念，禁止再混用：

- `defaultTargetLanguage`：用户全局默认，来自设置页。
- `conversationTargetLanguage`：当前会话选择器显示的语言，新会话初始值取全局默认。
- `resolvedTurnTargetLanguage`：单次请求最终语言，规则为“用户文本显式指定 > 当前会话语言 > 英语兜底”。

每次发送时把 `resolvedTurnTargetLanguage` 捕获到 turn/request 中。后续模型请求、响应标准化、消息标签和 TTS 全部使用同一个值。

在线和本地 provider 都必须收到明确语言代码及可读名称。解析完成后强制：

```dart
response.copyWith(targetLanguage: request.targetLanguage.code)
```

模型返回的 `targetLanguage` 只能用于诊断日志，不能成为权威值。

建议增加轻量脚本校验：当目标为日语但 `primary` 完全没有假名且大部分为拉丁字母时，将其标记为 `languageMismatch`，提供“一键重新生成”；不要自动无限重试。

### 3.4 上下文规则

构造请求上下文时：

- 只使用已完成并持久化/稳定的历史 turn；
- 排除当前新建的 user message，因为 request 已单独携带它；
- 排除 placeholder、error、cancelled-empty 消息；
- 以完整 turn 为单位截断；
- 若会话刚切换目标语言，在 system/user metadata 中明确“从本轮开始使用 X”；
- provider 层只负责序列化，不再猜测哪些 UI 消息有效。

## 4. 推荐状态模型

新增不可变状态（命名可调整）：

```dart
class ChatState {
  final String conversationId;
  final bool isDraft;
  final CoachLanguage conversationLanguage;
  final List<ChatMessage> messages;
  final ChatLoadStatus loadStatus; // initial/loading/ready/error
  final bool isStreaming;
  final String? streamingMessageId;
  final String? lastUserMessageId;
  final Object? error;
  final int epoch;
}
```

新增 `ChatController extends AsyncNotifier/Notifier<ChatState>`，至少提供：

```dart
Future<void> initialize();
Future<void> newConversation();
Future<void> openConversation(String id);
Future<void> setConversationLanguage(CoachLanguage language);
Future<void> send(String text);
Future<void> regenerateLast();
Future<void> stopGeneration();
Future<void> handleConversationDeleted(String id);
```

原则：`ChatPage` 不再拥有消息数组、当前会话 ID 或 subscription。Widget 只保留真正的视图状态，如 `TextEditingController`、`ScrollController`。

## 5. Repository 与数据结构调整

### 5.1 引入完整 Conversation 实体

不要继续用不同的 Dart record 丢字段。新增：

```dart
class Conversation {
  final String id;
  final String title;
  final CoachLanguage preferredLanguage;
  final CoachLanguage targetLanguage;
  final DateTime createdAt;
  final DateTime updatedAt;
}
```

Repository 增加/调整：

```dart
Future<Conversation?> getConversation(String id);
Future<void> createConversation(Conversation conversation);
Future<void> updateConversationLanguage(String id, CoachLanguage language);
Future<void> replaceAssistantForTurn(...); // 支持 regenerate
```

### 5.2 消息状态

建议给 assistant message 增加 `status`：`streaming/completed/failed/cancelled`。若不迁移数据库，至少保证仅 `completed` 消息进入上下文，并为取消消息制定稳定的落库规则。

### 5.3 事务边界

第一条消息应在一个事务中完成：创建 conversation、插入 user message、更新 `lastConversationId` 所需的数据操作。assistant 完成后单独事务写入并更新 conversation `updated_at`。标题更新后统一触发 history refresh。

## 6. 分文件实施建议

### `lib/features/chat/application/`

- 新增 `chat_controller.dart` 和 `chat_state.dart`。
- 把 `ChatPage` 中的 hydrate/send/retry/stop/persist/open/new 逻辑迁入 controller。
- controller 注入 conversation repository、settings controller、conversation engine、TTS/ASR controller。

### `lib/features/chat/chat_page.dart`

- 删除 `_currentConversationId`、`messages`、`_hydrated`、`replySubscription`、`isStreaming`、`_streamingMessageId`、`_lastUserInput`。
- watch `chatControllerProvider` 渲染。
- 新建按钮调用 `newConversation()`。
- 抽屉条目调用 `openConversation(id)`。
- 语言选择器调用 `setConversationLanguage(lang)`，不要直接把会话内选择器等同于全局设置。
- 超过 500 字时禁用发送并给出明确提示。

### `lib/features/history/`

- 打开会话时调用同一个 `chatController.openConversation(id)`。
- 通过 Home 回调或共享 navigation state 自动切到 Chat tab。
- 删除当前会话后调用 `handleConversationDeleted(id)`。
- 保存消息、自动标题、删除后都 invalidate 历史 provider。

### `lib/core/ai/conversation_engine.dart`

- `replyStream` 不要隐式依赖构造时的全局 settings 来确定本轮语言；让调用方传入已捕获的 conversation/default language，或直接传完整 `CoachRequest`。
- 保留显式语言解析优先级，并增加中英日混合、否定表达和语言名称边界测试。

### `lib/core/ai/openai_compatible_provider.dart`

- 保留当前 HEAD 已加入的 request metadata。
- system prompt 也明确“必须使用指定目标语言，历史消息不得覆盖本轮 metadata”。
- 完成解析后强制覆盖 response target language 为 request language。
- 仅序列化 controller 提供的有效历史 turn。

### `lib/core/ai/structured_response_parser.dart`

- 将 `'targetLanguage': parsed[...] ?? requested` 改为始终使用 requested。
- 同理评估 intent：客户端已解析的 intent 应是权威，模型字段只作辅助，避免 UI 行为被模型任意改变。

### `lib/core/repositories/sqlite_conversation_repository.dart`

- 返回完整 Conversation metadata。
- 提供显式 update language API。
- 为 regenerate 提供清晰的数据更新方式。
- 删除操作返回是否删除当前会话所需的信息，或由 controller 在调用前比较 ID。

### `lib/features/settings/application/settings_controller.dart`

- 将持久化操作串行化，或提供可 await 的 setter/command。
- 区分全局默认语言和当前会话语言。
- 持久化失败至少记录并暴露错误，不要完全静默。

## 7. 实施顺序

### 阶段 A：先修正确性（必须同一 PR 完成）

1. 建立 `ChatState + ChatController`。
2. 实现 initialize/new/open，并接通抽屉和历史页。
3. 实现 epoch/cancellation，消除跨会话串写。
4. 把 send/stop/regenerate 移入 controller。
5. 修正上下文重复和 placeholder 污染。
6. 在解析后强制请求目标语言。

### 阶段 B：数据一致性

1. 引入 Conversation entity，恢复会话语言元数据。
2. 修复当前会话删除、delete all、历史刷新和自动标题刷新。
3. 串行化 settings 持久化。
4. 明确 cancelled/failed message 的落库策略。

### 阶段 C：体验与防御

1. 历史页打开后自动回 Chat tab。
2. 目标语言不匹配检测与重新生成入口。
3. 输入长度硬限制。
4. ASR 输入语言与学习目标语言解耦。

## 8. 必须补充的测试

### Controller 单元测试

1. 初始化时恢复最后会话及消息。
2. `newConversation()` 生成不同 ID、清空所有旧状态且不立即产生空 DB row。
3. 新建后第一条消息写入新 ID，不写入旧 ID。
4. `openConversation(B)` 加载 B，不能保留 A 的任何消息。
5. A 的慢加载晚于 B 返回时，A 不能覆盖 B。
6. A 的流式回复在切换 B 后完成，不能写入 B，也不能更新 B 的 UI。
7. 删除当前会话后进入新 draft；删除非当前会话不影响当前页面。
8. regenerate 不新增重复 user message。
9. history context 不包含当前 user 两次、不包含 placeholder/error。
10. 保存消息与标题后历史列表刷新。

### 语言测试

1. 选择日语 + 中文普通问题 → request target 为 `ja`。
2. 选择日语 + “用英语怎么说” → 按既定规则 request target 为 `en`。
3. provider 返回 `targetLanguage=en`，request 为 `ja` → 最终 response 必须为 `ja`。
4. 切换日语后，在线 MiniMax/DeepSeek 和本地 Qwen 的 prompt 都包含 `ja`。
5. 日语 response 的 TTS request 使用 `ja` 和日语 voice，而不是当前全局设置的其他语言。
6. 打开旧会话后恢复该会话语言；新建会话使用全局默认语言。

### Widget/集成测试

1. 页面有旧消息时点“新建对话”，立即出现空状态。
2. 抽屉依次选择两个会话，消息列表分别正确。
3. 历史页点会话，自动切到 Chat tab 并显示对应消息。
4. 生成中点新建/切换，旧流停止且不串消息。
5. 切换 English → 日本語 后，selector、请求捕获、回答标签一致。
6. 删除正在查看的会话后不会被下一次发送复活。
7. 超过 500 字发送按钮不可用。

### Repository 测试

1. Conversation metadata 完整 round-trip。
2. 更新 target language 不修改 createdAt。
3. 删除 conversation 级联 messages/sentences；如音频文件不能由 SQLite 外键删除，要验证文件清理服务被调用。
4. regenerate 的 DB 结果与 UI turn 数量一致。

## 9. 验收标准

以下全部满足才算完成：

- 连续点击“新建对话”后，每次 UI 都立即为空；第一条消息只属于最后一个 draft。
- 任意切换 20 次历史会话，无串消息、无旧加载覆盖、无错误选中态。
- 生成中切会话或新建，旧回复不会出现在新会话或写进新会话数据库。
- 选择日语后发不含显式语言的中文问题，MiniMax、DeepSeek、本地 Qwen 的 request 均为 `ja`，最终 message/TTS 也为 `ja`。
- 输入显式要求英语时按产品规则转为英语，UI 显示本轮实际目标语言。
- 新消息、自动标题和删除操作在抽屉及历史页立即一致。
- 删除当前会话后不会恢复或“复活”该会话。
- 所有新增单元、widget、repository 测试通过；`flutter analyze` 无新增问题。

## 10. 不建议的临时修法

不要采用以下方式作为最终实现：

- 关闭抽屉时调用一次 `setState()` 再手工清空 messages；
- 在 `ChatPage.build()` 中监听 `lastConversationId` 后直接发起数据库查询；
- 只给新建按钮生成一个 UUID，却不取消旧流和隔离异步回调；
- 只修改 system prompt，不强制标准化最终 `targetLanguage`；
- 切换语言时清空所有上下文但不定义会话语言；
- 用多个 widget 分别维护“当前会话 ID”。

这些做法能暂时改善演示，但会保留竞态和数据串写。

## 11. 给 MiniMax 的执行指令

可直接附上以下要求：

> 按本文阶段 A、B、C 实施，不要只修两个表面按钮。先建立单一 ChatController 状态源，再迁移 UI。所有异步加载和流式生成必须使用 epoch/token 防止旧任务覆盖新会话；每次请求捕获 conversationId 和 resolved target language。模型返回的 targetLanguage 不得覆盖客户端请求值。实现后补齐本文第 8 节测试并运行 `dart format`、`flutter analyze`、相关 `flutter test`。不要修改与对话模块无关的现有用户改动。

## 12. Review 限制

本次为静态代码审查。尝试执行 `flutter analyze` 和目标测试时，本机已有多个长期运行的 Dart/Flutter 进程，命令在无输出状态下等待超过 90 秒，因此已中止，没有把“测试通过”作为结论。开发完成后必须在无 Flutter tool lock 的环境重新执行验证。
