# gmgn radio Marble 空间舞台设计

## 目标

让 gmgn radio 的舞台能够进入 Marble 生成的完整房间。用户用 WASD
移动、鼠标拖拽观察，DJ 可以通过工具切换 DJ House / Cosy Wood House、
改变天气和移动镜头。唱片机、壁炉、家具与灯光属于空间本体。

## 产品边界

空间由三层组成：Marble SPZ 是持续存在的完整房间；本地环境层只负责雨、
雷电等即时氛围；gmgn 原有歌词、封面点阵和播放控制继续位于最上层。
屏幕前景不再绘制二维唱片机或二维火炉。

改变建筑、地形或完整美术风格时，后续再交给 Marble 后台生成新版本。生成过程
不会阻塞 DJ 对话，完成后由 DJ 提示用户切换。

## 舞台结构

```text
StageContentView
  ├─ 视频背景（可选）
  ├─ MarbleSpatialView（SPZ 空间）
  ├─ MetalStageView（天气、封面点阵）
  ├─ 歌词与 DJ 字幕
  └─ 播放与节目控制
```

`MarbleSpatialView` 使用 MetalSplatter 渲染 SPZ。空间开启时，原舞台背景降为
透明，只保留音乐响应点阵和环境特效。SPZ 优先加载 500k；内存或下载失败时回退
100k。文件以 `world_id + 质量档位` 缓存在本机。

## 镜头

- W / S：沿视线地面投影前进、后退。
- A / D：向左、向右平移。
- 鼠标拖拽：改变 yaw 和 pitch。
- Shift：加速。
- 双击：回到世界入口。
- 当前输入焦点位于文本框时不移动。

第一版使用 Marble 的比例和地面偏移约束移动高度。碰撞网格先保存并预留接口，
不在首个渲染闭环中实现完整物理碰撞。

## 环境工具

DJ 获得两个工具：

1. `set_spatial_environment`
   - `scene`: `dj_house`、`cosy_wood_house`
   - `weather`: `clear`、`rain`、`thunderstorm`
2. `move_spatial_camera`
   - `direction`: `forward`、`backward`、`left`、`right`、`reset`
   - `distance`: 米数，限制在 0.5 到 10 米

雨和雷电由 Metal 粒子及曝光闪光完成。DJ House 内含真实 DJ 台、唱机、音箱、
城市夜景和节拍灯光；Cosy Wood House 内含木屋、壁炉、黑胶角和雨夜窗景。
缺少预设空间时通过 Marble 后台异步生成，完成后热切换 SPZ，不阻塞音乐播放。

## Marble 数据与密钥

应用从权限为 600 的本地配置文件读取 World Labs API Key，不写入源码，也不使用
钥匙串。API 用于列出和读取用户已有世界、生成两个 gmgn 房间预设、下载 SPZ
与碰撞网格。生成任务在视觉选择器中明确显示状态，已有空间不会重复生成。

## 错误处理

- 密钥缺失：空间页显示配置缺失，普通舞台继续工作。
- API 失败：使用本地缓存；没有缓存时退回原点阵舞台。
- 500k 加载失败：自动尝试 100k。
- SPZ 解码失败：保留当前空间，不清空正在播放的音乐和歌词。
- MetalSplatter 不可用：隐藏空间模式，不影响播放器功能。

## 验证

单元测试覆盖世界 JSON 解码、质量选择、镜头移动、环境状态和 DJ 工具参数。
编译测试验证 MetalSplatter 依赖和渲染接线。自动验证不启动应用、不恢复真实账号、
不访问钥匙串；运行效果由用户手动打开舞台确认。
