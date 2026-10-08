# 正式包构建与安装

在当前 worktree 根目录执行：

```sh
make release-install
```

默认读取 `config/release.env`，其中统一维护版本号、Cargo 构建选项和安装路径。
发布新版本前递增 `GMGN_RELEASE_BUILD`。此文件采用 Make 语法，包含空格的路径不加引号。
自定义本机配置时可执行 `make release-install BUILD_ENV=/absolute/path/local.env`。
配置文件不存储凭据。

其他入口：

- `make release`：只构建、封印和签名正式包。
- `make install-built`：校验并安装已有候选，不重新编译。

默认安装到 `~/Applications/gmgn radio.app`，保留现有生产数据目录。
安装程序校验签名、组件和后台服务，并保留可恢复的旧包。
这些入口不自动启动主应用，不运行音频测试；安装成功不代表界面验收完成。
