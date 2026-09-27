# 居民自主找参考图并交给许愿机（2026-09-12）

用户明确要求：文字提出制作需求后，居民自己找图，工具必须真实提供给 agent，不要求
用户先上传图片或提供链接。本轮按 `docs/plans/2026-09-12-wish-web-reference-design.md`
补齐受控登记入口。

## 交付

| 位置 | 内容 |
| --- | --- |
| `Agent/ResidentWishReferenceTools.swift`（新） | `search_wish_reference_images(query)` 与 `register_wish_reference_image(image_url, display_name)` 两个真实 `ResidentWorldToolSession.AdditionalTool`。固定 Wikimedia Commons `URLComponents` 查询，最多 5 条 `image_url` / `source_page_url` / `title`，附版权未核验声明，无结果返回空列表且从不拼造链接。登记走可注入闭包，下载后校验 PNG 魔数与 ≤8 MiB，写入私有目录 0700 / 文件 0600，再经协调器主机专用方法登记。 |
| `Presence/WishMachineCoordinator.swift` | 最小新增主机专用 `registerWebReference(_:imageURL:authorizationID:worldID:residentScope:source:)` 与只读 `webReference(attachmentID:)`；新增 `ResidentWebReference` 持久来源。追加语义：同 run 授权 ≤4、已有任务（已消耗）不得扩、世界/居民 scope 不匹配拒绝、重复登记幂等。`submit` / `retry` 使用逐图来源，网页图不再记为用户上传。 |
| `Agent/ResidentWishMachineTools.swift` | `read_wish_generation` 空参数发现登记图并返回 `source_kind` / `source_image_url` / `license_verified`；提交与查询描述更新为「没图先搜索登记再生成」。 |
| `App/GMGNRadioApp.swift` | `authorizeWishImages` 对无附件的真实人类文字回合返回 `input.runID`，不再因空附件返回 nil 卡住新入口；`makeResidentWorldTools` 把新工具真实追加进 `session.additionalTools`；许愿机提示更新为搜索→登记→生成、不要求用户找图、不得凭空声称已见/已完成。 |
| `Agent/AgentConversationService.swift` | Codex 工具会话作用域 `.tools.v7` → `.tools.v8`（旧线程不复用）；世界观提示补充找图与真实性约束。 |
| `Agent/ResidentDSHConfiguration.swift` | DSH persona 补充「用户没给图时自行检索并登记、登记不等于生成、不得凭空声称已见图或已完成」。 |
| `Presence/ResidentWebImageDownloader.swift`（新） | 有界 HTTPS 读取与图片归一化；公开地址逐跳验证及固定连接地址；通用 JSON 读取与图片解码分开。固定 curl 参数、不继承环境或无关文件描述符；单一进程回收者与可取消管道读取。 |
| `Presence/ResidentWebImagePublicDNSResolver.swift`（新） | 固定公共 DNS HTTPS 端点及 IP，拒绝私网、保留段和混合解析，不把本机代理 fake-IP 加入允许名单。 |
| `tools/test-resident-wish-reference-tools.swift`（新） | 分层验收（见下）。 |
| `tools/test-resident-codex-agent.swift`、`test-resident-conversation-tools.swift`、`test-resident-image-transport.swift` | 跟随 `.tools.v8` 更新，并新增「旧 v7 会话不复用」。 |
| `GMGNRadio.xcodeproj/project.pbxproj` | 随 `make build` 的 XcodeGen 步骤生成，包含三个新增生产源文件。 |

## 验收（真实代码链路，非 grep）

`swift tools/test-resident-wish-reference-tools.swift`：主代理复跑 61 项通过、0 失败。用**真实**
`ResidentWorldToolSession`（真实 schema / `call` 账本 / 并发合并）与**真实**
`WishMachineCoordinator` + 假 daemon 只做本地受理：

- 假 Commons 响应 → 搜索返回结构化直链与来源页、版权未核验、无结果为诚实空列表、失败为显式错误；
- 登记的 `image_url` 只允许 https 标准端口；模型自带 `authorization_id` / `world_id` / `path` 被拒绝；
- 下载真实 PNG → 私有 0700/0600 → 重启后仍在原 scope、跨 scope 不可见；
- 空参数 `read_wish_generation` 发现登记图并保留 `public_web_reference` 来源；
- `submit_wish_generation` 经真实协调器/假 daemon 仅本地受理，daemon 收到网页来源而非用户上传；
- 同 callID 幂等、不同参冲突、同 URL 并发去重一次下载；
- 失败 / 非 PNG / 切 scope 不登记且清自身临时文件；已消耗 run 授权不能扩；
- 无附件文字回合可先登记再获得生成授权；4 张上限；后台无 host 授权不能登记。
- 后台先建会话与人类回合使用相同 schema；调用者直接取消会传播到下载任务，无迟到登记；
- 文件权限设置失败清理自身文件；持久化失败回滚内存授权与来源；同 ID 冲突先校验；
- API 错误与非 JSON MIME 明确失败，不冒充无搜索结果。

真实 DSH：`bash tools/test-resident-dsh-wish-reference-assembly.sh` → 32 项通过、
`WISH REFERENCE ASSEMBLY EXIT=0`（真实 `AgentConversationService.send` + 真实 ACP runtime
+ loopback mock provider，验证 `gmgn_search_wish_reference_images` /
`gmgn_register_wish_reference_image` / `gmgn_submit_wish_generation` 同会话类型化调用）。

主代理独立复跑 Codex 新 scope 189 项通过（`.tools.v8` 且 `.tools.v7` 不复用）。
主代理独立复跑安全下载 159 项通过（Swift 6），公开 DNS 106 项通过。
下载检查包括并发即时退出、非零退出、自然退出期间取消、后代进程持有 stdout、
超时回收、无关文件描述符隔离、私网与重定向拒绝、传输上限及元数据剥离。
实现代理修复轮报告协调器纯 CPU 回归 185 项通过，未将其写成主代理独立复跑结果。
早期实现代理报告中曾列入 `test-wish-machine-delivery-loop`；该项不计入本轮验收，
主代理没有运行该 GPU 相关测试，也没有取得窗口视觉或声音证据。

## 默认公网路径检查

主代理使用实际 `ResidentWebImageDownloader()` 默认配置，未注入网络替身：

- 通用 JSON 契约检查 `--offline-json-contract` 从修复前拒绝 `application/json`
  变为通过，确认搜索响应不再进入图片解码。
- `swift tools/probe-resident-wish-reference-public.swift --allow-public-network`
  成功返回 3 个候选，下载 `thumb.wikimedia.org` 的 `File:Coffee machine 2022.jpg`，
  归一化 PNG 为 1,641,546 字节。
- PNG SHA-256：`6c0421f0ebb9a98f313d46c997a1f547f75bf08369ee09bba3b560932e95da1e`。
- 首次公网尝试曾返回 `transportFailure("malformed-response")`；随后相同生产配置重跑通过。
  固定 DNS 端点的直接 TLS 请求也返回 200。该次瞬时失败原因未单独确证，不将一次成功
  扩大为网络稳定性保证。

检查只读取公开搜索 API、下载参考图并验证 PNG；没有调用模型、生成服务或用户后台。

最终单一回收者及文件描述符隔离版本再次通过同一公网探针；探针以 Swift 6 编译。
结果仍为上述 3 个候选、1,641,546 字节 PNG 和相同 SHA-256。

## 构建

`make build` 退出 0，`BUILD SUCCEEDED`。日志：
`/tmp/gmgn-wish-reference-build-20260912.log`。
项目使用 Swift 6 严格并发检查，无签名编译；没有运行 `xcodebuild test`。
最终下载器源码 SHA-256：
`fe8997c7bc60abdd693d8423eed40c255aeac55ddc7d79ebc2cf1ff4e992e888`。

## 边界与残留

- 已完成无签名整包构建及下述统一安装；未启动 App；
  未触发真实付费生成。离线业务测试使用假公开 API 响应、假 daemon 本地受理与 loopback DSH；
  真实公开网络探针单独记录于上节。
- 工具业务测试注入假公开 API 和下载响应；搜索 seam 同时保留 MIME 与 Data。
  它不能替代生产下载器检查。默认公网路径已通过上面的独立探针，
  进程退出、取消与超时回归另行记录，不能替代窗口与真实生成验收。
- `test-living-resident-loop` 此前被报告存在宏沙箱错误及测试接口漂移。本次实际复现
  未出现宏沙箱错误，确认缺少 `presentResidentReply` / `residentMemoryTurnSlot` /
  `registerResidentMemoryTurn` / `residentTurnSourceByRunID`，现已修复测试接口，见下节。

## 继续推进：本机安装与后台只读核验

- 统一安装测试 12 项通过，`make install` 退出 0；日志
  `/tmp/gmgn-wish-reference-install-20260912.log`。
- 新应用已安装到 `/Applications/gmgn radio.app`；安装回执
  `daemon_verified=true`、`app_stopped=false`、`open_app_manually=true`。
- 主动态库 SHA-256：`3c4fe6987ef7e2aae006bbc65f98a8fdfb7ec0090f70c19302a39055daec0823`；
  后台 SHA-256：`493876f38b3f686f24dfcea1d39a2dcf5ea713cec78fe4f3ae8f445df73ae205`。
  两者均与本次构建产物相同；双向 `rsync -rclni` 只读校验也无任何差异，包含框架符号链接。
- 安装后额外以唯一空探针 scope 调用有效 `memory_status`，返回
  `memory=null`、`pendingTurns=0`、`orchestration.state=idle`。套接字对端 PID `89265`
  对应安装目录下的新版后台，未读取用户记忆正文或写入记忆。
- provider 标志均为 false：App 尚未启动和配置后台 provider，不能由该探针声称真实模型
  或长期记忆压缩已经运行。没有读取、配置或打印凭据，没有触发生成服务。
- 旧版保留于 `/Applications/.gmgn-install-8xe_v54g/previous.backup`，可恢复。
- CPU 宿主回归已恢复：主代理执行 `swift tools/test-living-resident-loop.swift`，退出 0，
  `PASS: 199 resident conversation checks, 0 failures`。
  保留真实 App 方法抽取，补入真实记忆登记、呈现、确认逻辑及可控 Speech 完成回调；
  完整工具清单断言为 33 项，包含两项参考图工具。
  验证当前回复交付以及取消/切换空间后的抑制，未绑定记忆时不伪造确认。
  日志 `/tmp/gmgn-living-resident-loop-20260912.log`，只改测试文件，已安装生产二进制未变。
