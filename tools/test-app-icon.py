#!/usr/bin/env python3
"""给**本机构建产物**的 app bundle 换"测试 logo"：原 logo 去色成**黑白**，不加任何角标。

**为什么需要**（用户 2026-10-02）：「两个 gmgn radio 图标」的根治是
`DERIVED_DATA = apps/macos/Build.noindex`（`.noindex` 让 Spotlight 够不到产物，
见 Makefile 顶部）。但这是**路径级**的保证：产物一旦被手工拷到别处、被别的
DerivedData 产出、或者哪天 `.noindex` 约定变了，聚焦/启动台里仍会冒出**同名**的
第二份。黑白 logo 是第二重身份标识：**只看图标**就知道哪份是构建产物。

**改哪一份**（这是本工具的语义，别搞反）：

    make build     → 把 `$(PRODUCT_APP)`（DerivedData 里那份）的 icns 换成黑白
    make install   → 拷进 /Applications **之前**用 `--restore` 还原原始彩色 icns

所以 `/Applications/gmgn radio.app` 的 logo 始终是原来那张彩色图，只有"裸构建产物"
是黑白的。装进 /Applications 的那份本来就是这个产物拷过去的 —— 不还原的话，用户的
日常图标会天天是黑白的，那就不是"区分"而是"污染"了。

**只去色，不画任何东西**：按亮度转灰度（Rec.601 权重，Pillow 的 `convert('L'）`），
**保留 alpha 通道**（图标圆角透明区不能被填成黑）。没有角标、没有文字、没有描边。

**不改仓库里的原始 icns**：`apps/macos/Resources/AppIcon.icns` 只被读，黑白版本是从它
现场生成的（iconutil 拆成 iconset → Pillow 去色 → iconutil 合回 icns），写进目标
bundle 的 `Contents/Resources/<CFBundleIconFile>.icns`；`--restore` 则把原始文件
逐字节放回。

依赖：`iconutil`（macOS 自带）+ Pillow（`python3 -c "import PIL"` 可用）。
Pillow 缺失时打印 `FAIL:` 并以非 0 退出；Makefile 里换 logo 这一步**不改变 build 的
退出码**（外观问题不该让编译失败），但日志里会留下 FAIL 行。

用法
----
    python3 tools/test-app-icon.py --apply   <bundle.app>   # 换成黑白测试 logo
    python3 tools/test-app-icon.py --restore <bundle.app>   # 还原原始彩色 logo
    python3 tools/test-app-icon.py --self-test              # 临时目录里跑一遍，仓库不动

退出码：0 = 做完了 / 没有什么可做；1 = 真出错（bundle 里没有 icns、iconutil 失败…）。
`--restore` 在 bundle **不存在**时只打一行 note 并返回 0（让 install 走到它自己那句
更清楚的报错上去）；bundle 在但 icns 不在时会把原始 icns 补上。
"""
from __future__ import annotations

import argparse
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
SOURCE_ICNS = REPO / 'apps/macos/Resources/AppIcon.icns'


def die(message: str) -> 'None':
    print('FAIL: ' + message, file=sys.stderr)
    sys.exit(1)


def note(message: str) -> None:
    print('note: ' + message, file=sys.stderr)


def load_pillow():
    try:
        from PIL import Image
    except ImportError as error:  # pragma: no cover - 环境问题
        die('缺 Pillow（%s）：黑白 logo 需要 `python3 -m pip install pillow`，'
            '或把 PYTHON 指向带 Pillow 的解释器' % error)
    from PIL import Image
    return Image


def bundle_icon_path(bundle: Path) -> Path:
    """按 Info.plist 的 CFBundleIconFile 找 bundle 里的 icns（默认 AppIcon.icns）。"""
    name = 'AppIcon'
    info = bundle / 'Contents' / 'Info.plist'
    if info.is_file():
        try:
            with info.open('rb') as handle:
                plist = plistlib.load(handle)
            name = str(plist.get('CFBundleIconFile') or name)
        except (OSError, ValueError):
            pass
    if not name.lower().endswith('.icns'):
        name += '.icns'
    return bundle / 'Contents' / 'Resources' / name


def atomic_copy(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(prefix='.test-icon-', dir=str(destination.parent))
    os.close(handle)
    temporary = Path(temporary)
    try:
        shutil.copyfile(source, temporary)
        os.chmod(temporary, 0o644)
        os.replace(temporary, destination)
    finally:
        if temporary.exists():
            temporary.unlink()


def desaturate_png(path: Path) -> None:
    """就地把一张 iconset PNG 去色成黑白，**保留 alpha**（圆角透明区不能变黑）。"""
    Image = load_pillow()
    with Image.open(path) as opened:
        image = opened.convert('RGBA')
    red, green, blue, alpha = image.split()
    luminance = Image.merge('RGB', (red, green, blue)).convert('L')
    Image.merge('RGBA', (luminance, luminance, luminance, alpha)).save(path, format='PNG')


def apply_test_icon(bundle: Path, source: Path) -> None:
    if not bundle.is_dir():
        die('bundle 不存在：%s' % bundle)
    if not source.is_file():
        die('原始 icns 不存在：%s' % source)
    destination = bundle_icon_path(bundle)
    if not destination.parent.is_dir():
        die('bundle 里没有 Contents/Resources：%s' % bundle)

    with tempfile.TemporaryDirectory(prefix='gmgn-test-icon-') as temporary:
        iconset = Path(temporary) / 'AppIcon.iconset'
        _run_iconutil(['iconutil', '-c', 'iconset', '-o', str(iconset), str(source)],
                      'iconutil 拆 iconset 失败')
        pngs = sorted(iconset.glob('*.png'))
        if not pngs:
            die('iconset 是空的：%s' % iconset)
        for png in pngs:
            desaturate_png(png)
        rewritten = Path(temporary) / 'AppIcon.icns'
        _run_iconutil(['iconutil', '-c', 'icns', '-o', str(rewritten), str(iconset)],
                      'iconutil 合 icns 失败')
        atomic_copy(rewritten, destination)
    print('OK: 黑白测试 logo -> %s' % destination)


def restore_icon(bundle: Path, source: Path) -> None:
    if not source.is_file():
        die('原始 icns 不存在：%s' % source)
    if not bundle.is_dir():
        note('bundle 不存在，跳过还原：%s' % bundle)
        return
    destination = bundle_icon_path(bundle)
    atomic_copy(source, destination)
    print('OK: 还原原始彩色 logo -> %s' % destination)


def _run_iconutil(command, message: str) -> None:
    try:
        completed = subprocess.run(command, capture_output=True, text=True)
    except OSError as error:
        die('%s：%s' % (message, error))
    if completed.returncode != 0:
        die('%s（%s）：%s' % (message, completed.returncode, completed.stderr.strip()))


def _count_colored(image, tolerance: int) -> int:
    """alpha != 0 且 |R-G| 或 |G-B| 超过容差的像素个数（用 tobytes 避开 Pillow 弃用 API）。"""
    raw = image.tobytes()
    colored = 0
    for index in range(0, len(raw), 4):
        red, green, blue, alpha = raw[index], raw[index + 1], raw[index + 2], raw[index + 3]
        if alpha and (abs(red - green) > tolerance or abs(green - blue) > tolerance):
            colored += 1
    return colored


def _count_transparent(image) -> int:
    raw = image.tobytes()
    return sum(1 for index in range(3, len(raw), 4) if raw[index] == 0)


def self_test(source: Path) -> int:
    Image = load_pillow()
    # iconutil 合 icns 时会对 16/32 那两个尺寸重新量化，实测有 1 个像素通道差 25；
    # 所以「直接产物」用 0 容差钉死，「最终 icns」允许每张 ≤4 个像素、通道差 ≤64。
    quantization_tolerance = 64
    with tempfile.TemporaryDirectory(prefix='gmgn-test-icon-selftest-') as temporary:
        bundle = Path(temporary) / 'gmgn radio.app'
        resources = bundle / 'Contents' / 'Resources'
        resources.mkdir(parents=True)
        with (bundle / 'Contents' / 'Info.plist').open('wb') as handle:
            plistlib.dump({'CFBundleIconFile': 'AppIcon'}, handle)
        target = resources / 'AppIcon.icns'
        shutil.copyfile(source, target)
        original = target.read_bytes()

        # 1) 直接钉 desaturate_png：逐像素必须 R == G == B，alpha 一个不少。
        iconset = Path(temporary) / 'direct.iconset'
        _run_iconutil(['iconutil', '-c', 'iconset', '-o', str(iconset), str(source)],
                      'self-test：拆原始 icns 失败')
        direct = sorted(iconset.glob('*.png'))
        if not direct:
            die('self-test：原始 icns 拆不出任何图标')
        transparency_by_name = {}
        for png in direct:
            with Image.open(png) as opened:
                before = opened.convert('RGBA')
            transparency_by_name[png.name] = _count_transparent(before)
            desaturate_png(png)
            with Image.open(png) as opened:
                after = opened.convert('RGBA')
            if after.size != before.size:
                die('self-test：去色改变了尺寸 %s' % png.name)
            colored = _count_colored(after, 0)
            if colored:
                die('self-test：%s 去色后仍有 %d 个彩色像素' % (png.name, colored))
            if _count_transparent(after) != _count_transparent(before):
                die('self-test：%s 去色改变了透明像素' % png.name)

        # 2) 整体 apply：最终 icns 仍合法，且（允许量化噪声后）仍然没有颜色。
        apply_test_icon(bundle, source)
        restyled = target.read_bytes()
        if restyled == original:
            die('self-test：--apply 之后 icns 与原始字节相同')
        check_dir = Path(temporary) / 'check.iconset'
        _run_iconutil(['iconutil', '-c', 'iconset', '-o', str(check_dir), str(target)],
                      'self-test：黑白后的 icns 不是合法 icns')
        pngs = sorted(check_dir.glob('*.png'))
        if not pngs:
            die('self-test：黑白后的 icns 拆不出任何图标')
        for png in pngs:
            with Image.open(png) as opened:
                image = opened.convert('RGBA')
            colored = _count_colored(image, quantization_tolerance)
            if colored > 4:
                die('self-test：%s 里有 %d 个彩色像素（超过量化噪声）' % (png.name, colored))
            # alpha 必须与**原始**那一张逐个数一致（有些尺寸本来就是不透明的整块方块）。
            if _count_transparent(image) != transparency_by_name.get(png.name, 0):
                die('self-test：%s 的 alpha 与原始不一致' % png.name)

        restore_icon(bundle, source)
        if target.read_bytes() != original:
            die('self-test：--restore 之后 icns 与原始字节不同')

        missing = Path(temporary) / 'nope.app'
        restore_icon(missing, source)  # 不存在时必须是 note + 返回 0，不能炸
        print('OK: self-test 通过（去色后无彩色像素、alpha 保留、restore 逐字节还原）')
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description='把本机构建产物的 app logo 换成黑白测试 logo')
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument('--apply', action='store_true', help='换成黑白测试 logo')
    actions.add_argument('--restore', action='store_true', help='还原原始彩色 logo')
    actions.add_argument('--self-test', action='store_true', help='在临时目录里自检')
    parser.add_argument('--source', default=str(SOURCE_ICNS), help='原始 icns（默认仓库里的 AppIcon.icns）')
    parser.add_argument('bundle', nargs='?', help='目标 .app 路径')
    args = parser.parse_args()

    source = Path(args.source)
    if args.self_test:
        return self_test(source)
    if not args.bundle:
        parser.error('--apply/--restore 需要一个 .app 路径')
    bundle = Path(args.bundle)
    if args.apply:
        apply_test_icon(bundle, source)
    else:
        restore_icon(bundle, source)
    return 0


if __name__ == '__main__':
    sys.exit(main())
