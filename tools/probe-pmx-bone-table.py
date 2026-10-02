#!/usr/bin/env python3
"""只读探针：直接解析真机那份 PMX 的**骨表**，回答"候选骨名在文件里到底存不存在"。

为什么必须解析文件而不是搜字节：PMX 的字符串是"长度前缀 + UTF-16LE"，搜字节只能证明
"这串字符在文件的**某个**位置出现过"（可能是材质名、注释、变形名），不能证明它是一根**骨头**。
这个探针按 PMX 2.0/2.1 的格式逐段跳过顶点/面/贴图/材质，走到骨表那一段再取名字。

用法：
    python3 tools/probe-pmx-bone-table.py [<path.pmx>] [候选骨名 ...]

不带参数时用真机那份 PMX 与挂点表里的候选骨名。
"""
import hashlib
import os
import struct
import sys

DEFAULT_PMX = os.path.expanduser(
    "~/Library/Application Support/gmgn radio/PresencePackages/"
    "pmx.2b-miss-0414-standard/na_2b_0414.pmx"
)
# 与 `PropAttachmentSlots.boneNameCandidates(for:)` 同一份候选表（探针只读，不改生产语义）。
DEFAULT_CANDIDATES = [
    "右手首", "bone009",                    # rightHand
    "上半身2", "bone002", "上半身", "bone001",  # back
    "腰", "下半身", "bone014", "センター", "bone000",  # waist
]
# `acceptsAttachmentRig` 要求的三根标准骨
RIG_REQUIRED = ["センター", "上半身", "右手首"]
# 骨表锚点：第一根骨的名字（PMX 作者命名习惯固定，长度前缀前 4 字节就是 boneCount）。
ANCHOR_BONE = "全ての親"


class Reader:
    def __init__(self, data: bytes):
        self.data = data
        self.pos = 0

    def take(self, count: int) -> bytes:
        chunk = self.data[self.pos:self.pos + count]
        if len(chunk) != count:
            raise EOFError(f"文件在 offset {self.pos} 处提前结束（要 {count} 字节）")
        self.pos += count
        return chunk

    def u8(self) -> int:
        return self.take(1)[0]

    def i32(self) -> int:
        return struct.unpack("<i", self.take(4))[0]

    def f32(self) -> float:
        return struct.unpack("<f", self.take(4))[0]

    def skip(self, count: int) -> None:
        self.take(count)

    def index(self, size: int) -> int:
        raw = self.take(size)
        value = int.from_bytes(raw, "little", signed=True)
        return value

    def skip_index(self, size: int) -> None:
        self.skip(size)


def decode_text(raw: bytes, encoding: int) -> str:
    if encoding == 0:
        return raw.decode("utf-16-le", errors="replace")
    return raw.decode("utf-8", errors="replace")


def read_text(reader: Reader, encoding: int) -> str:
    length = reader.i32()
    if length < 0:
        raise ValueError(f"负的字符串长度 {length} @ {reader.pos}")
    return decode_text(reader.take(length), encoding)


def parse_bones(path: str):
    """解析骨表。

    为什么不用"从头逐段跳过顶点/面/贴图/材质"那种写法：PMX 材料段的**面顶点数**
    在本文件里与"面的顶点索引个数"对不上（按那个读法会在材料段尾部跑偏），
    而骨表本身有更强的锚点 —— 第一根骨的名字（`全ての親`）在文件里唯一，
    它的 TextBuf 长度前缀前面 4 字节就是 `boneCount`。于是这里**从锚点起步**，
    再按格式**顺序走完 `boneCount` 根骨**并断言恰好走完，走不齐就报错（fail-closed）。

    骨名就是 SceneKit 节点名：`MMDPMXReader.readBone` 里那一行
    `boneNode.name = getTextBuffer()`（`MMDSceneKit/MMDPMXReader.swift:741`）。
    所以这份骨表回答的正是"`childNode(withName:recursively:)` 找不找得到"。
    """
    with open(path, "rb") as handle:
        data = handle.read()
    magic = data[:4]
    if magic != b"PMX ":
        raise ValueError(f"不是 PMX 文件（magic={magic!r}）")
    version = struct.unpack("<f", data[4:8])[0]
    globals_count = data[8]
    encoding = data[9]
    bone_index_size = data[9 + 5]

    anchor = data.find(ANCHOR_BONE.encode("utf-16-le"))
    if anchor < 0:
        raise ValueError(f"找不到骨表锚点 {ANCHOR_BONE!r}，无法定位骨表")
    length_pos = anchor - 4
    if struct.unpack("<i", data[length_pos:length_pos + 4])[0] != len(ANCHOR_BONE.encode("utf-16-le")):
        raise ValueError("锚点前面不是 TextBuf 长度前缀，文件格式与预期不符")
    count_pos = length_pos - 4
    bone_count = struct.unpack("<i", data[count_pos:count_pos + 4])[0]
    if not (0 < bone_count < 100000):
        raise ValueError(f"骨数不合理：{bone_count}")

    reader = Reader(data)
    reader.pos = length_pos
    bones = []
    for index in range(bone_count):
        name = read_text(reader, encoding)
        name_en = read_text(reader, encoding)
        x, y, z = struct.unpack("<fff", reader.take(12))
        parent = struct.unpack("<h", reader.take(2))[0]
        reader.skip(4)  # layer
        flags = struct.unpack("<H", reader.take(2))[0]
        if flags & 0x0001:
            reader.skip(2)
        else:
            reader.skip(12)
        if flags & 0x0300:
            reader.skip(6)
        if flags & 0x0400:
            reader.skip(12)
        if flags & 0x0800:
            reader.skip(24)
        if flags & 0x2000:
            reader.skip(4)
        if flags & 0x0020:
            reader.skip(2 + 4 + 4)
            link_count = struct.unpack("<i", reader.take(4))[0]
            for _ in range(link_count):
                reader.skip(2)
                has_limit = reader.u8()
                if has_limit:
                    reader.skip(24)
        bones.append({"index": index, "name": name, "name_en": name_en,
                      "position": (x, y, z), "parent": parent, "flags": flags})
    return {
        "path": path, "sha256": hashlib.sha256(data).hexdigest(),
        "bytes": len(data), "version": version, "encoding": encoding,
        "bone_index_size": bone_index_size, "bone_count": bone_count,
        "model_name": "", "model_name_en": "", "bones": bones,
    }


def main() -> int:
    args = sys.argv[1:]
    path = args[0] if args and args[0].endswith(".pmx") else DEFAULT_PMX
    candidates = args[1:] if args and args[0].endswith(".pmx") else args
    if not candidates:
        candidates = DEFAULT_CANDIDATES

    if not os.path.exists(path):
        print(f"FAIL: 找不到真机 PMX：{path}")
        return 1
    table = parse_bones(path)
    names = [bone["name"] for bone in table["bones"]]
    name_set = set(names)

    print(f"PMX            : {table['path']}")
    print(f"sha256         : {table['sha256']}")
    print(f"bytes          : {table['bytes']}")
    print(f"format version : {table['version']}")
    print(f"text encoding  : {table['encoding']} (0=UTF-16LE, 1=UTF-8)")
    print(f"bone_count     : {table['bone_count']}")
    print(f"bones in table : {len(names)}")
    print()
    print("== 骨表里前 40 根（索引 名字 静止坐标 父索引）==")
    for bone in table["bones"][:40]:
        x, y, z = bone["position"]
        print(f"  [{bone['index']:3d}] {bone['name']:<24} y={y:9.4f} x={x:8.4f} z={z:8.4f} parent={bone['parent']}")
    print()
    print("== 候选骨名在**骨表**里存不存在 ==")
    for candidate in candidates:
        mark = "YES" if candidate in name_set else "NO "
        detail = ""
        if candidate in name_set:
            bone = table["bones"][names.index(candidate)]
            detail = f" (索引 {bone['index']}, y={bone['position'][1]:.4f}, 父 {bone['parent']})"
        print(f"  {mark}  {candidate}{detail}")
    print()
    print("== acceptsAttachmentRig 要求的三根 ==")
    for required in RIG_REQUIRED:
        print(f"  {'YES' if required in name_set else 'NO '}  {required}")
    print()
    missing = [c for c in candidates if c not in name_set]
    print(f"骨表里没有的候选：{missing if missing else '（无，全部存在）'}")
    # 退出码只反映"探针本身跑通了"；缺席与否由调用方断言。
    return 0


if __name__ == "__main__":
    sys.exit(main())
