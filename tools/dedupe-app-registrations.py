#!/usr/bin/env python3
"""让 LaunchServices 里只剩 /Applications 那份，顺手删掉仓库里的构建产物。

**为什么需要这个**：`Build/Build/Products/<配置>/gmgn radio.app` 是一个可启动的
bundle，Xcode 一写出来 LaunchServices 就自动注册它 —— 于是"打开方式"/聚焦里会
出现**第二个 gmgn radio**（2026-09-29 用户实际看到两次）。`make install` 在把产物
拷进 /Applications 之后会删掉它，但 `make test-all`、以及任何一次验证用的
`make build` 也会生成一份，所以清理必须是**独立动作**（`make dedupe`），而不是
只挂在安装流程里。

顺序很重要：**先注销再删**。已经不在磁盘上的注册用 `lsregister -u` 是删不掉的
（它会报 "Bundle node not found on disk"），只能重建数据库 —— 那一步由
`install-macos.ensure_single_registration` 负责，所以这里删完文件后直接调它。

退出码恒为 0：这是收尾清理，清不掉不该让 `make` 失败。
"""
from __future__ import annotations

import importlib.util
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
APP = Path('/Applications/gmgn radio.app')
PRODUCTS = REPO / 'apps/macos/Build/Build/Products'


def load_installer():
    spec = importlib.util.spec_from_file_location('gmgn_install_macos', HERE / 'install-macos.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    installer = load_installer()
    removed = []
    # 先让安装器把"同一 bundle id 的其它注册"清掉（它知道怎么重建数据库），
    # 再删除产物文件 —— 反过来的话注册就成了删不掉的死条目。
    if APP.exists():
        installer.ensure_single_registration(APP)
    for product in sorted(PRODUCTS.glob('*/gmgn radio.app')):
        try:
            shutil.rmtree(product)
            removed.append(str(product.relative_to(REPO)))
        except OSError as error:
            print(f'  删不掉 {product}: {error}', file=sys.stderr)
    if APP.exists():
        installer.ensure_single_registration(APP)
    print(f'  已删构建产物 {len(removed)} 份' + (f'：{", ".join(removed)}' if removed else ''))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
