# Marble 图生世界工具

Node 内置模块，无需安装依赖。密钥从 `WLT_API_KEY` 或应用已有的本地文件读取：

`/Users/ghostcorn/Library/Application Support/ai.gmgn.radio/secrets/world-labs-api-key`

工具不访问钥匙串，不输出密钥或签名上传地址。余额和查询只读；上传发送用户指定图片；生成会消耗 World Labs 额度。

## 命令

```sh
node tools/marble/world.mjs credits
node tools/marble/world.mjs upload reference-empty.png --out upload.json
node tools/marble/world.mjs generate --media-id MEDIA_ID --prompt-file prompt.txt --out operation.json
node tools/marble/world.mjs poll --operation-id OPERATION_ID --out operation.json
node tools/marble/world.mjs download --world-file operation.json --out-dir assets
node --test tools/marble/world.test.mjs
```

上传结果返回 `media_asset_id`。默认使用 `marble-1.1`，输入为普通图片，直接采用提示词，不重新生成图片描述。每次 `generate` 只提交一次：请求前以独占方式创建 `submitting` 记录，请求成功后保存操作编号。已有记录时拒绝重新提交。

若网络断开且记录仍为 `submitting`，不要删除记录重试。先在服务端确认该次请求是否已建立任务，取得操作编号后用 `poll` 恢复，避免重复扣费。工具不会自动重试任何请求。

每次 `poll` 只查一次任务。完成后另查世界详情，完整结果保存在 `operation.json` 的 `world` 字段，保留原始请求、操作状态与成本字段。下载命令也接受独立的世界详情 JSON。

下载内容为 `world-500k.spz`、`world-100k.spz`、`collider.glb`，以及服务端提供的缩略图和全景图。下载为串行流式写入，不拉取完整精度 SPZ 或付费高精网格。`downloads.json` 记录本地路径。失败时 `.partial` 保留为不完整文件，下次执行下载可覆盖恢复。

## 官方协议依据

- [上传准备](https://docs.worldlabs.ai/api/reference/media-assets/prepare-upload)
- [生成世界](https://docs.worldlabs.ai/api/reference/worlds/generate)
- [查询世界](https://docs.worldlabs.ai/api/reference/worlds/get)

字段以接口参考为准。快速入门中部分旧示例仍使用 `id`；工具在读取任务完成响应时兼容 `world_id` 与 `id`，上传使用正式的 `media_asset.media_asset_id`。
