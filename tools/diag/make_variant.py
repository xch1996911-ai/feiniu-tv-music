#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成「渲染后端 × 插件注册」诊断变体的构建配置。

## 为什么需要它

海信 E7N Pro / VIDDA 实机现象：启动后只看到 launch_background 的深蓝
`#14213D`，从未出现 BootApp 的「三步初始化」文字，然后闪退
⇒ **Flutter 第一帧之前就失败了**。

第一帧之前能出问题的环节有三个，必须**分离变量**逐个排除：
  1. Renderer（Impeller 默认后端 / 强制 OpenGL ES / 关闭 Impeller）
  2. Plugin Registration（GeneratedPluginRegistrant 在 native 层注册插件）
  3. Debug Engine 与 Release Engine 的差异

因此本脚本产出一组**只差一个变量**的构建配置，外加一个正式发布候选 G
（默认后端 + release）。

## 2026-10-03 实机收口

E/F（默认后端，极简 Dart）双双画出第一帧，B/C（业务代码，默认 / GLES
后端）也双双成功进入登录页 ⇒ 引擎、渲染后端、ABI、插件注册四项全部排除，
A/B/C/D 的对照价值随之下降，G 成为正式交付候选。

## 只改构建配置，绝不碰业务代码

本脚本只修改两处，且都是「构建配置」而非业务逻辑：

  android/app/src/main/AndroidManifest.xml
    · 渲染后端 meta-data（两个 DIAG_RENDERER_ANCHOR 之间）
    · `<application android:label>`（便于在电视桌面/启动器上区分是哪个 APK）
    · 启动 Activity 类名（无插件版本指向 DiagSmokeActivity）
  android/app/build.gradle.kts
    · applicationId（各 APK 可同时安装、各自独立 boot.log，免去反复卸载重装）

lib/**、test/**、tools/fnos_api_probe/** 一个字节都不会被改动。

## 用法

  python3 tools/diag/make_variant.py --list              # 打印矩阵
  python3 tools/diag/make_variant.py A                    # 应用变体 A 的配置
  eval "$(python3 tools/diag/make_variant.py A --emit shell)"   # 供 CI 取值
  python3 tools/diag/make_variant.py --write-manifest dist # 校验产物 + 写清单
  python3 tools/diag/make_variant.py --revert              # 还原为默认配置
"""

from __future__ import annotations

import argparse
import hashlib
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "android/app/src/main/AndroidManifest.xml"
GRADLE = ROOT / "android/app/build.gradle.kts"

ANCHOR_OPEN = "<!-- ▼ DIAG_RENDERER_ANCHOR -->"
ANCHOR_CLOSE = "<!-- ▲ DIAG_RENDERER_ANCHOR_END -->"

BASE_APPLICATION_ID = "com.feiniu.tv.music"

# 只打包 ARM：Android TV / 电视盒子都是 ARM，x86_64 只服务模拟器。
# 去掉它能让每个 APK 小约 1/3，全部包的总下载量因此可接受；
# 该设置对所有变体完全一致，不会成为混淆变量。
PLATFORMS = "android-arm,android-arm64"

RENDERER_BLOCKS: dict[str, tuple[str, ...]] = {
    # 关掉 Impeller
    "no_impeller": (
        "        <meta-data",
        '            android:name="io.flutter.embedding.android.EnableImpeller"',
        '            android:value="false" />',
    ),
    # 什么都不写 = 让 Flutter 自己选默认后端
    "default": (),
    # 把 Impeller 后端钉在 OpenGL ES
    "gles": (
        "        <meta-data",
        '            android:name="io.flutter.embedding.android.ImpellerBackend"',
        '            android:value="opengles" />',
    ),
}

RENDERER_DESC: dict[str, str] = {
    "no_impeller": "EnableImpeller=false（关闭 Impeller）",
    "default": "无任何后端 meta-data（Flutter 默认后端）",
    "gles": "ImpellerBackend=opengles",
}


@dataclass(frozen=True)
class Variant:
    key: str
    label: str
    artifact: str
    renderer: str
    plugins: bool
    build: str
    entry: str
    application_id: str
    diag_tag: str


VARIANTS: dict[str, Variant] = {
    "A": Variant(
        key="A",
        label="飞牛A·关Impeller",
        artifact="app-hisense-no-impeller-debug.apk",
        renderer="no_impeller",
        plugins=True,
        build="debug",
        entry="lib/main.dart",
        application_id=f"{BASE_APPLICATION_ID}.diaga",
        diag_tag="",
    ),
    "B": Variant(
        key="B",
        label="飞牛B·默认后端",
        artifact="app-hisense-impeller-default-debug.apk",
        renderer="default",
        plugins=True,
        build="debug",
        entry="lib/main.dart",
        application_id=f"{BASE_APPLICATION_ID}.diagb",
        diag_tag="",
    ),
    "C": Variant(
        key="C",
        label="飞牛C·GLES后端",
        artifact="app-hisense-impeller-gles-debug.apk",
        renderer="gles",
        plugins=True,
        build="debug",
        entry="lib/main.dart",
        application_id=f"{BASE_APPLICATION_ID}.diagc",
        diag_tag="",
    ),
    "D": Variant(
        key="D",
        label="飞牛D·Rel关Impeller",
        artifact="app-hisense-no-impeller-release.apk",
        renderer="no_impeller",
        plugins=True,
        build="release",
        entry="lib/main.dart",
        application_id=f"{BASE_APPLICATION_ID}.diagd",
        diag_tag="",
    ),
    # 引擎冒烟：与业务代码完全无关，只验证「能否画出第一帧」。
    # 刻意用「默认后端」——这是最接近原生 Flutter 模板的基线配置。
    "E": Variant(
        key="E",
        label="Smoke·插件版",
        artifact="app-hisense-engine-smoke.apk",
        renderer="default",
        plugins=True,
        build="debug",
        entry="lib/main_engine_smoke.dart",
        application_id=f"{BASE_APPLICATION_ID}.smoke",
        diag_tag="smoke-plugins",
    ),
    # 与 E 的唯一差异：插件不参与自动注册（DiagSmokeActivity 不调用
    # super.configureFlutterEngine）。用来判断 GeneratedPluginRegistrant
    # 是否是 native 崩溃点。
    "F": Variant(
        key="F",
        label="Smoke·无插件",
        artifact="app-hisense-engine-smoke-no-plugins.apk",
        renderer="default",
        plugins=False,
        build="debug",
        entry="lib/main_engine_smoke.dart",
        application_id=f"{BASE_APPLICATION_ID}.smokenp",
        diag_tag="smoke-no-plugins",
    ),
    # ── 正式发布候选：**默认后端 + release**（2026-10-03 新增） ──────────
    #
    # 实机结论（海信 E7N Pro / VIDDA）：
    #   · E/F（默认后端，极简 Dart）画出第一帧 ⇒ 引擎 / 渲染 / ABI / 插件注册全部排除
    #   · B/C（业务代码，默认 / GLES 后端）**都**成功进入登录页
    # ⇒ 正式包取「默认后端 + release」：最贴近 Flutter 官方默认，且真机已验证
    #   业务启动路径可用。D（no_impeller + release）保留作对照，不用于发布。
    "G": Variant(
        key="G",
        label="飞牛·正式版",
        artifact="app-hisense-release.apk",
        renderer="default",
        plugins=True,
        build="release",
        entry="lib/main.dart",
        application_id=f"{BASE_APPLICATION_ID}.rel",
        diag_tag="",
    ),
}

ORDER = ["A", "B", "C", "D", "E", "F", "G"]


# ── 文件读写（显式 utf-8 / 禁用换行转换，避免污染 diff 或引入 CRLF） ──────


def _read(path: Path) -> str:
    # newline='' —— 关闭通用换行转换。否则 `read_text()` 会把整个文件的
    # CRLF 悄悄改写成 LF，虽然内容「看起来一样」，却会让 diff 变成整文件改写。
    # 这里要求：除目标改动外，文件其余部分字节完全不变。
    with path.open("r", encoding="utf-8", newline="") as handle:
        return handle.read()


def _write(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8", newline="")


def _detect_nl(text: str) -> str:
    """探测文件原有换行符。

    仓库已有 `.gitattributes`（`* text=auto eol=lf`），索引里一律是 LF；
    但本机 `core.autocrlf=true`，检出后工作区文件仍可能是 CRLF。
    脚本对两者都必须成立，否则锚点会匹配不上、diff 会变成整文件改写。
    """
    return "\r\n" if "\r\n" in text else "\n"


def _sub_once(text: str, pattern: str, repl: str, what: str) -> str:
    new, n = re.subn(pattern, repl, text, count=1)
    if n != 1:
        raise SystemExit(f"[FAIL] 未能在 {what} 中唯一定位替换目标：/{pattern}/（命中 {n} 次）")
    return new


# ── 应用变体 ─────────────────────────────────────────────────────────────


def apply_variant(v: Variant) -> None:
    if not MANIFEST.is_file():
        raise SystemExit(f"[FAIL] 找不到清单文件：{MANIFEST}")
    if not GRADLE.is_file():
        raise SystemExit(f"[FAIL] 找不到构建脚本：{GRADLE}")

    manifest = _read(MANIFEST)
    gradle = _read(GRADLE)

    # 1) 渲染后端：替换两个锚点之间的内容（正则对 CRLF / LF 都成立）
    anchor_re = re.compile(
        r"([ \t]*" + re.escape(ANCHOR_OPEN) + r"[ \t]*\r?\n)(.*?)([ \t]*" + re.escape(ANCHOR_CLOSE) + r")",
        re.S,
    )
    if not anchor_re.search(manifest):
        raise SystemExit(f"[FAIL] 清单里找不到渲染后端锚点 {ANCHOR_OPEN}")
    nl = _detect_nl(manifest)
    block_lines = RENDERER_BLOCKS[v.renderer]
    inner = nl.join(block_lines) + nl if block_lines else ""
    manifest = anchor_re.sub(lambda m: m.group(1) + inner + m.group(3), manifest, count=1)

    # 2) 桌面显示名：多个包同装时，这是唯一能让用户在电视上分辨的依据
    manifest = _sub_once(
        manifest, r'android:label="[^"]*"', f'android:label="{v.label}"', "AndroidManifest.xml 的 android:label"
    )

    # 3) 启动 Activity：插件注册的开关就在 Activity 里（见 DiagSmokeActivity 注释）
    if v.plugins:
        activity = ".MainActivity"
    else:
        activity = ".DiagSmokeActivity"
    manifest = _sub_once(
        manifest,
        r'android:name="\.(?:MainActivity|DiagSmokeActivity)"',
        f'android:name="{activity}"',
        "AndroidManifest.xml 的启动 Activity",
    )

    # 4) applicationId：让各包可同时安装（免去每轮卸载重装 + 各自独立 boot.log）
    gradle = _sub_once(
        gradle,
        r'applicationId = "[^"]*"',
        f'applicationId = "{v.application_id}"',
        "app/build.gradle.kts 的 applicationId",
    )

    _write(MANIFEST, manifest)
    _write(GRADLE, gradle)

    print(f"=== 变体 {v.key} 配置已应用 ===")
    print(f"  artifact        : {v.artifact}")
    print(f"  桌面显示名      : {v.label}")
    print(f"  applicationId   : {v.application_id}")
    print(f"  Renderer        : {RENDERER_DESC[v.renderer]}")
    print(f"  插件自动注册    : {'是（MainActivity）' if v.plugins else '否（DiagSmokeActivity，不调用 super）'}")
    print(f"  构建类型        : {v.build}")
    print(f"  Dart 入口       : {v.entry}")
    print(f"  ABI             : {PLATFORMS}")
    if v.diag_tag:
        print(f"  --dart-define   : DIAG_TAG={v.diag_tag}")


def revert() -> None:
    """用 git 还原被改写的构建配置（只涉及 android/ 下两个文件）。"""
    files = [
        str(MANIFEST.relative_to(ROOT)),
        str(GRADLE.relative_to(ROOT)),
    ]
    result = subprocess.run(["git", "checkout", "--", *files], cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"[FAIL] git checkout 失败：{result.stderr.strip()}")
    print(f"[OK] 已还原：{', '.join(files)}")


# ── 输出 ─────────────────────────────────────────────────────────────────


def emit_shell(v: Variant) -> None:
    """供 CI 用 eval 取值。全部为 ASCII、无空格，故无需引号。"""
    defines = f"--dart-define=DIAG_TAG={v.diag_tag}" if v.diag_tag else ""
    for key, value in (
        ("VARIANT", v.key),
        ("ARTIFACT", v.artifact),
        ("BUILD_TYPE", v.build),
        ("ENTRY", v.entry),
        ("APPLICATION_ID", v.application_id),
        ("DART_DEFINES", defines),
        ("PLATFORMS", PLATFORMS),
    ):
        print(f"{key}={value}")


def print_matrix() -> None:
    out = []
    out.append("诊断变体矩阵（同一 commit、同一份 Dart 业务代码，只差构建配置）")
    out.append("=" * 108)
    out.append(
        f"{'变体':<4} {'artifact':<44} {'Renderer':<38} {'插件注册':<9} {'类型':<8}"
    )
    out.append("-" * 108)
    for key in ORDER:
        v = VARIANTS[key]
        out.append(
            f"{key:<4} {v.artifact:<44} {RENDERER_DESC[v.renderer]:<38} "
            f"{'是' if v.plugins else '否':<9} {v.build:<8}"
        )
    out.append("-" * 108)
    out.append(f"ABI: {PLATFORMS}（不含 x86_64，电视无需）")
    out.append("")
    out.append("每个 APK 的 applicationId / 桌面显示名（可同时安装，互不覆盖）：")
    for key in ORDER:
        v = VARIANTS[key]
        out.append(f"  {key}  {v.application_id:<34} {v.label}")
    out.append("")
    out.append("boot.log 路径：/storage/emulated/0/Android/data/<applicationId>/files/bootlog/boot.log")
    print("\n".join(out))


def write_manifest(dist: Path) -> int:
    """校验全部 APK 是否齐全，并写出 MANIFEST.txt（大小 + sha256 + 配置）。"""
    missing = [VARIANTS[k].artifact for k in ORDER if not (dist / VARIANTS[k].artifact).is_file()]
    if missing:
        print("[FAIL] 缺少以下产物：")
        for name in missing:
            print(f"  - {name}")
        return 1

    lines = [
        "海信 E7N Pro / VIDDA 诊断包（渲染后端 × 插件注册）+ 正式发布候选",
        "=" * 96,
        "",
        "所有 APK 来自同一 commit、同一份 Dart 业务代码，只有构建配置不同。",
        "",
    ]
    for key in ORDER:
        v = VARIANTS[key]
        path = dist / v.artifact
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        lines += [
            f"[{key}] {v.artifact}",
            f"    字节数          : {path.stat().st_size:,}",
            f"    sha256          : {digest}",
            f"    applicationId   : {v.application_id}",
            f"    桌面显示名      : {v.label}",
            f"    Renderer        : {RENDERER_DESC[v.renderer]}",
            f"    插件自动注册    : {'是（MainActivity）' if v.plugins else '否（DiagSmokeActivity）'}",
            f"    构建类型        : {v.build}",
            f"    Dart 入口       : {v.entry}",
            f"    ABI             : {PLATFORMS}",
            f"    DIAG_TAG        : {v.diag_tag or '(无)'}",
            "",
        ]

    lines += [
        "boot.log 路径（每个包独立）",
        "-" * 96,
        *[f"  {VARIANTS[k].application_id:<34} /storage/emulated/0/Android/data/{VARIANTS[k].application_id}/files/bootlog/boot.log" for k in ORDER],
        "",
        "判读要点",
        "-" * 96,
        "  · boot.log 里连一行 [dart] 都没有  ⇒ Dart 根本没执行，问题在引擎/渲染/插件注册层",
        "  · 有 [dart] runApp after 但没有 first frame callback ⇒ 引擎/渲染层问题",
        "  · boot.log 没有异常堆栈 ≠ 没有 native crash",
        "    （UncaughtExceptionHandler 只抓 Java/Kotlin 异常，抓不到 SIGSEGV/libflutter.so/GPU 驱动崩溃）",
        "",
    ]
    text = "\n".join(lines)
    (dist / "MANIFEST.txt").write_text(text, encoding="utf-8", newline="")
    print(text)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="生成渲染后端/插件注册诊断变体的构建配置")
    parser.add_argument("variant", nargs="?", choices=ORDER, help="要应用的变体")
    parser.add_argument("--list", action="store_true", help="打印变体矩阵")
    parser.add_argument("--emit", choices=["shell"], help="以 KEY=VALUE 输出变体信息（供 CI eval）")
    parser.add_argument("--write-manifest", metavar="DIST_DIR", help="校验产物并写 MANIFEST.txt")
    parser.add_argument("--revert", action="store_true", help="还原被改写的构建配置")
    args = parser.parse_args()

    if args.list:
        print_matrix()
        return 0
    if args.revert:
        revert()
        return 0
    if args.write_manifest:
        return write_manifest(Path(args.write_manifest))

    if not args.variant:
        parser.print_help()
        return 2

    v = VARIANTS[args.variant]
    if args.emit == "shell":
        emit_shell(v)
    else:
        apply_variant(v)
    return 0


if __name__ == "__main__":
    sys.exit(main())
