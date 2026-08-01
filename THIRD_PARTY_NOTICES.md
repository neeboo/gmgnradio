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

原项目和本项目的完整许可证均可在仓库根目录的 `LICENSE` 中查看。
本项目对应源码随应用公开提供。
