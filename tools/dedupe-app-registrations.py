#!/usr/bin/env python3
"""让 LaunchServices 里只剩 `/Applications` 那份，并清掉会变成"第二个图标"的产物。

**规则**（不是清一次）：同一个 bundle id（ai.gmgn.radio）在注册表里**只允许**
`/Applications/gmgn radio.app` 这一条，其余路径一律注销。三个已知来源：

  1. 构建产物 `apps/macos/Build.noindex/Build/Products/<配置>/gmgn radio.app` —— 现在
     DerivedData 带 `.noindex` 后缀，Spotlight 不进这棵子树、mdworker 不会注册它
     （2026-10-02 实测）；这一条仍留在扫描列表里，好让"注册表只允许一条"的断言
     不被路径改名绕过。`make install` 拷完会删、`make build` 末尾也会注销。
  2. `~/Library/Developer/Xcode/DerivedData/*/Build/Products/*/gmgn radio.app` ——
     `make test` 走的是**默认** DerivedData，而且 TEST_HOST 会真的启动那个产物，
     启动即注册。这条 `make build` 末尾的注销管不到。
  3. 装机留下的回滚备份 `/Applications/.gmgn-install-*/previous.backup` —— 隐藏目录，
     当前**没有**被注册（Spotlight 与 LaunchServices 都不进隐藏目录：2026-10-02 实测
     dump 里 0 条、`mdls` 也读不出 bundle id），但里面是一份同 id 的**完整可启动 bundle**：
     谁把它索引一次、点开一次、`lsregister -f` 一次，它就是第二个 "gmgn radio"。
     所以它不是"当前凶手"，是**潜在凶手** —— 必须从形态上根治（去掉 Info.plist），
     而它并不会因为 `prune_install_workspaces` 保留一个就无害。

**为什么 `make build` 末尾那条注销不够**（2026-10-02 本机实测，探针用一次性 bundle id）：
把一个新 bundle 放进 `$HOME` 下、**完全不碰 `lsregister`**，30 s 内 Spotlight 的索引
就把它注册进了 LaunchServices（`mdls` 认得、`lsregister -dump` 多一条）。也就是说只要
产物**文件还在**、位置又会被索引，注销就是暂时的、会被 mdworker 撤销。所以这里除了注销，
还要**删掉**产物文件 —— 文件消失才是吸引子的根。
（2026-10-02 已落地：DerivedData 换成带 `.noindex` 后缀的 `apps/macos/Build.noindex`，
实测整个子树不进索引、从而不被注册 —— 裸 `make build` 之后等 60 s 注册表仍只有
`/Applications` 一条。本脚本因此从"吸引子的根"退成第二层：管的是老路径、别的
DerivedData、以及任何被手工挪到会被索引的位置的同 id 副本。）

顺序：**先注销再删**。文件还在的注册 `lsregister -u` 能清掉；文件已经不在的死注册
（删产物之后留下的）只能重建数据库 —— 那一步由
`install-macos.ensure_single_registration` 负责。

退出码：默认模式只有"收敛 + 删除之后注册表仍不是唯一正规路径"才非 0（这就是防复发
断言，注入一份同 id 的副本必须能把它顶红）；删不掉 / 注销不掉本身不算失败。
`--check` 只读体检（不改任何东西），`--dry-run` 只报告将要做的动作。
"""
from __future__ import annotations

import argparse
import importlib.util
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
APP = Path('/Applications/gmgn radio.app')
PRODUCTS = REPO / 'apps/macos/Build.noindex/Build/Products'
DEFAULT_DERIVED_DATA = Path.home() / 'Library/Developer/Xcode/DerivedData'


def load_installer():
    spec = importlib.util.spec_from_file_location('gmgn_install_macos', HERE / 'install-macos.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def product_candidates(products_dirs):
    """会变成第二个图标的构建产物：仓库 DerivedData + 默认 DerivedData。

    只在这两个根下面找，而且逐个校验 bundle id（`--products` 传进来的目录也一样）——
    绝不删不属于这个应用的路径。
    """
    roots = [Path(directory) for directory in products_dirs] or [PRODUCTS]
    candidates = []
    for root in roots:
        candidates += sorted(root.glob('*/gmgn radio.app'))
    candidates += sorted(DEFAULT_DERIVED_DATA.glob('*/Build/Products/*/gmgn radio.app'))
    seen, unique = set(), []
    for candidate in candidates:
        resolved = candidate.resolve()
        if resolved == APP.resolve() or resolved in seen:
            continue
        seen.add(resolved)
        unique.append(candidate)
    return unique


def running_bundles():
    """正在运行的 gmgn radio 进程所属的 bundle 路径（不删正在用的产物）。"""
    try:
        output = subprocess.check_output(['/bin/ps', '-axo', 'command='], text=True)
    except (OSError, subprocess.SubprocessError):
        return set()
    marker = '/Contents/MacOS/gmgn radio'
    bundles = set()
    for line in output.splitlines():
        if line.strip().endswith(marker):
            bundles.add(Path(line.strip()[: -len(marker)]))
    return bundles


def fail(others):
    """把"注册表里不止一条"说清楚，并给出可执行的下一步。"""
    print(f'FAIL: 注册表里 {APP} 的 bundle id 不止一条注册 —— 正规路径只有 {APP}',
          file=sys.stderr)
    for index, path in enumerate(others, 1):
        state = ('文件仍在（聚焦/"打开方式"里会出现第二个 gmgn radio）' if path.exists()
                 else '文件已消失（死注册，只能靠重建数据库清掉）')
        print(f'FAIL:   多出来的第 {index} 条：{path} —— {state}', file=sys.stderr)
    print('FAIL: 跑一次 `python3 tools/dedupe-app-registrations.py`（或 `make dedupe`）收敛它。',
          file=sys.stderr)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--check', action='store_true',
                        help='只复核注册表（只读），不改任何东西')
    parser.add_argument('--dry-run', action='store_true',
                        help='打印将要注销/删除的绝对路径，不做修改')
    parser.add_argument('--products', action='append', default=[], metavar='DIR',
                        help='额外的构建产物根目录（默认：仓库 DerivedData + 默认 DerivedData）')
    args = parser.parse_args(argv)

    installer = load_installer()
    identifier = installer.bundle_identifier(APP)

    if args.check:
        ok, others = installer.audit_single_registration(APP)
        if ok:
            print(f'  OK 注册表里 {identifier} 只剩 {APP}')
            return 0
        fail(others)
        return 1

    workspaces = sorted(APP.parent.glob('.gmgn-install-*')) if APP.parent.exists() else []
    if args.dry_run:
        registrations = installer.registered_paths(APP)
        foreign = [path for path in registrations if path != APP]
        print(f'  dry-run：{identifier} 当前注册 {len(registrations)} 条，'
              f'除正规路径外有 {len(foreign)} 条会被注销')
        for path in foreign:
            print(f'  将注销（不删文件）{path}')
        for workspace in workspaces:
            backup = workspace / 'previous.backup'
            state = '已是封口形态' if not (backup / 'Contents/Info.plist').is_file() else '将被封口（去掉 Info.plist，字节不动）'
            print(f'  回滚备份 {backup} —— {state}')
        for product in product_candidates(args.products):
            print(f'  将删除构建产物 {product}')
        return 0

    # 1) 形态根治：装机遗留的回滚备份去掉 Info.plist（字节不动，回滚只需改回名字）。
    #    排在收敛之前：封口之后这个路径已经不是 bundle，注销它只是清理残迹。
    for backup in installer.seal_install_workspaces(APP.parent):
        print(f'  已封口回滚备份（字节未改，回滚步骤见 {backup}/{installer.ROLLBACK_NOTES}）：'
              f'{backup}')

    # 2) 规则：除正规安装外，同 bundle id 的**每一条**注册都注销。回滚备份即使已经
    #    是封口形态（不可能是 bundle）也无条件注销一次 —— 规则里它是第二份候选。
    backups = [workspace / 'previous.backup' for workspace in workspaces]
    remaining = installer.ensure_single_registration(APP, extra_paths=backups)

    # 3) 删掉产物文件：只要文件还在，mdworker 索引它时会再把注册加回来（见模块注释）。
    running = running_bundles()
    removed = 0
    for product in product_candidates(args.products):
        if installer.bundle_identifier(product) != installer.BUNDLE_IDENTIFIER:
            print(f'  跳过（bundle id 不是 {installer.BUNDLE_IDENTIFIER}）：{product}')
            continue
        if product.resolve() in running:
            print(f'  跳过（正在运行）：{product}')
            continue
        try:
            shutil.rmtree(product)
            removed += 1
            print(f'  已删构建产物 {product}')
        except OSError as error:
            print(f'  删不掉 {product}: {error}', file=sys.stderr)
    if not removed:
        print('  没有需要删除的构建产物')

    # 4) 防复发断言：收敛 + 删除之后，注册表必须只剩正规安装这一条。
    ok, others = installer.audit_single_registration(APP)
    if ok:
        print(f'  OK 注册表里 {identifier} 只剩 {APP}'
              + (f'（本轮清掉 {len(remaining)} 条残留注册）' if remaining else ''))
        return 0
    fail(others)
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
