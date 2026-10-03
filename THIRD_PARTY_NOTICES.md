# Third-party notices

## Folia

gmgn radio 的歌词场景运行时和视觉场景参考并改写自
[chthollyphile/folia-major](https://github.com/chthollyphile/folia-major)，
当前基准版本为提交 `002b581bb2580566937f1023a3c875d2b799dbbe`。

- 原项目许可证：GNU Affero General Public License v3.0
- 改写范围：场景注册、歌词时间推进、字词状态、语义着色、音频分频、
  双明暗主题、场景生命周期和三维镜台
- 主要修改：TypeScript、React、Three.js 的实现被改写为
  Swift、SwiftUI、AVFoundation 和 Metal；适配了 gmgn radio 的
  DJ 节目、实时语音和原生音频管线
- 修改日期：2026-07-31

## Mineradio

gmgn radio 的部分点阵形态参考并改写自
[XxHuberrr/Mineradio](https://github.com/XxHuberrr/Mineradio)，
当前基准版本为提交 `411bce4e4a8e5add3d1f76ac4a9c19306f6a10df`。

- 原项目许可证：GNU General Public License v3.0
- 改写范围：封面点阵采样、封面浮雕与柱状律动、分层星河、手动滚筒与留白预设
- 主要修改：Three.js、GLSL 和 Electron 的实现被改写为 Swift、Metal
  和 AppKit；歌词样式与点阵形态保持独立，DJ 负责协调色彩、节奏和场景
- 未纳入范围：骷髅模型及引用外部作品的壁纸、音拓场景
- 修改日期：2026-07-31

## VRMMetalKit

gmgn radio 使用
[VRMMetalKit](https://github.com/arkavo-org/VRMMetalKit)
加载和渲染 VRM 0.x / 1.0 桌宠模型。

- 版本：1.0.0
- 原项目许可证：Apache License 2.0
- 使用范围：MToon 材质、表情、视线、Spring Bone 和 Metal 渲染

## Studio Groove VRMA

gmgn radio 内置 `StudioGroove.vrma`，用于 VRM 角色的全身循环动作。

- 来源：[VRMMetalKit `VRMA_01.vrma`](https://github.com/arkavo-org/VRMMetalKit/blob/main/VRMA_01.vrma)
- 来源提交：`2a6e961fb5bfcd2117c434fe818afaa0c68062fb`
- 原项目许可证：Apache License 2.0
- 修改：仅重命名资源文件；播放时关闭根位移并按 DJ 状态调整速度

## Arisu Maid VRM

gmgn radio 内置 `ArisuMaid.vrm`，用于首次安装时的默认 VRM 桌宠。

- 模型名称：波覇ありす Ver.1.4
- 作者：keiichiisozaki
- 内嵌许可：允许所有用户使用、修改、商业使用和再分发，无需署名
- 许可地址：<https://hub.vroid.com/license?allowed_to_use_user=everyone&characterization_allowed_user=everyone&corporate_commercial_use=allow&credit=unnecessary&modification=allow&personal_commercial_use=profit&redistribution=allow&sexual_expression=allow&version=1&violent_expression=allow>

## nanoem core

gmgn radio 使用 [nanoem](https://github.com/hkrn/nanoem) 的 C 核心读取
PMX、PMD 和 VMD 数据。

- 来源提交：`30acffaa29f5d2eb9e997d69418f2e4b97b5894f`
- 原项目许可证：MIT License
- 使用范围：模型、动作和 Shift-JIS 名称解析
- 未纳入范围：MPL 2.0 的 `emapp`、Sokol 图形后端和编辑器代码
- 本地许可文本：`apps/macos/Packages/NanoemCore/LICENSE.MIT`

## MMDSceneKit

gmgn radio 使用并维护本地版本的
[MMDSceneKit](https://github.com/magicien/MMDSceneKit)，用于在共享 Metal
渲染通道中播放 PMX 模型和 VMD 动作。

- 来源提交：`53f0c043e90f6537e2519f3e7d6061028687b8bd`
- 原项目许可证：MIT License
- 修改：SwiftPM 封装、Xcode 26.6 兼容、二进制读取内存安全修复、
  PMX/VMD 文件头检测和回归测试
- 本地许可文本：`apps/macos/Packages/MMDSceneKit/LICENSE`

## I Love Slap Bass 动作

gmgn radio 内置 `iluvslapbass_motion.vmd`，用于 2B 的 MMD 舞蹈动作。

- 动作署名：`Motion: Aileen_71`
- 原始说明：`apps/macos/Resources/MMDMotions/Aileen_71-Readme.txt`
- 使用条件：不得用于 18+ 内容，不得用于收费委托；公开作品必须按上述格式署名
- 动作作者声明该动作长期免费配布；该动作资源仍遵循作者原始说明，不随 gmgn radio 的开源许可证重新授权

## Text-To-VRMA 与 NVIDIA ARDY

gmgn radio 的可选离线动作工厂可以连接
[Text-To-VRMA](https://github.com/Kirakun0328/text-to-vrma) 提供的 ARDY HTTP
服务。该服务和模型权重不随 macOS 应用分发，客户端运行也不依赖它们。

- Text-To-VRMA 源码许可证：MIT License
- NVIDIA ARDY 代码许可证：Apache License 2.0
- NVIDIA ARDY 模型权重：NVIDIA Open Model Agreement
- Meta Llama 3 文本编码器：Meta Llama 3 Community License
- FuguMT 日英翻译模型：CC BY-SA 4.0
- 使用范围：Linux/DGX 离线生成动作 JSON；gmgn radio 自有发布器将其转换为经过校验的 VRMA 下载资源
- 未纳入应用：ARDY、Llama、FuguMT 的代码、运行环境和模型权重

## BONES-SEED 动作数据

gmgn radio 的离线动作导入工具支持经过授权的
[BONES Motion Capture Dataset](https://huggingface.co/datasets/bones-studio/seed)。

- 署名：[Motion Data by Bones Studio](https://bones.studio/)
- 数据许可：BONES Motion Capture Dataset License（需要先接受访问条款）
- 使用范围：从 SOMA BVH 生成经过重定向和校验的 VMD、VRMA 动作结果
- 仓库内容：仅包含动作导入代码和由官方 SOMA 模板提取的数值化绑定姿态配置
- 未纳入仓库及应用：原始 BVH、USDA、完整数据集和查看器缓存
- 分发限制：不得通过生成结果恢复或重新取得原始数据；面向产品或第三方发布前需确认许可范围

## 内置 Rust helper

`gmgn radio.app/Contents/Helpers/` 里有本仓库自己编译的两个 Rust 可执行文件：

- `gmgn-taskd`：世界状态与许愿任务的唯一写入者（服务端）。
- `gmgn-mcpd`：通过 stdio 暴露 MCP 工具面的服务器；它只读/转发到同一个
  `gmgn-taskd`，不是第二个权威。

两者都由 Xcode 构建阶段从本仓库的 `services/` 源码编译（`tools/build-taskd-helper.sh`、
`tools/build-mcpd-helper.sh`），各自随包写入 `<name>.sha256`；
`tools/verify-helper-manifest.py`（`make verify-helper-manifest`）在装机前独立复算摘要，
清单为空或不一致时 fail-closed。

- `gmgn-mcpd` 依赖 Rust MCP SDK [rmcp](https://github.com/modelcontextprotocol/rust-sdk) 3.5（Apache-2.0 / MIT 双许可）。
- 两个 helper 的其余依赖见仓库根目录 `Cargo.lock`。

原项目和本项目的完整许可证均可在仓库根目录的 `LICENSE` 中查看。
本项目对应源码随应用公开提供。
