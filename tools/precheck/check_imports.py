#!/usr/bin/env python3
"""检查项目内 Dart import 的两类问题（analyzer 会报 error，但本机没有 dart 工具链）。

1) **路径不存在** —— import 指向的文件真的在吗？
2) **未使用导入** —— 被 import 的文件里导出的顶层符号，body 里一个都没用到？
   （Dart 的 unused_import 是 analyzer error，本项目 CI 判失败）

⚠️ Windows 注意事项：`package:xxx/yyy.dart` 不能直接 `Path.joinpath`，
必须按 `/` 逐段拼，否则全部误报「路径不存在」。

用法：
    python tools/precheck/check_imports.py [根目录]
"""
from __future__ import annotations

import pathlib
import re
import sys

PKG_PREFIX = "package:feiniu_tv_music/"

# package: URI 的根是包根，不是仓库根 —— `package:foo/a.dart` 实际在 `<root>/lib/a.dart`
LIB_DIR = "lib"


def exported_symbols(path: pathlib.Path) -> set[str]:
    """提取一个文件里定义的顶层符号。"""
    src = path.read_text(encoding="utf-8")
    syms: set[str] = set()
    syms |= set(re.findall(r"^(?:abstract\s+)?class\s+(\w+)", src, re.M))
    syms |= set(re.findall(r"^enum\s+(\w+)", src, re.M))
    syms |= set(re.findall(r"^extension\s+(\w+)", src, re.M))
    syms |= set(re.findall(r"^mixin\s+(\w+)", src, re.M))
    syms |= set(re.findall(r"^(\w+)\s*\(", src, re.M))  # 顶层函数
    syms |= set(re.findall(r"^const\s+\w+\s+(\w+)\s*=", src, re.M))
    syms |= set(re.findall(r"^final\s+\w+\s+(\w+)\s*=", src, re.M))
    return syms


def body_without_imports_and_comments(lines: list[str]) -> str:
    out: list[str] = []
    in_block = False
    for line in lines:
        s = line.strip()
        if s.startswith("import "):
            continue
        if s.startswith("///") or s.startswith("//"):
            continue
        if s.startswith("/*"):
            in_block = not in_block
            continue
        if in_block:
            continue
        out.append(line)
    return "\n".join(out)


def resolve(root: pathlib.Path, dart_file: pathlib.Path, uri: str) -> pathlib.Path:
    """把 import URI 解析成真实路径。

    ⚠️ `package:foo/a/b.dart` 指向的是 **`<repo>/lib/a/b.dart`**（包根 = lib/），
    不是 `<repo>/a/b.dart`。踩过这个坑：全部误报「路径不存在」。
    """
    if uri.startswith(PKG_PREFIX):
        target = root / LIB_DIR
        for part in uri[len(PKG_PREFIX):].split("/"):
            target = target / part
        return target
    target = dart_file.parent
    for part in uri.split("/"):
        if part == "..":
            target = target.parent
        elif part != ".":
            target = target / part
    return target


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    problems: list[str] = []

    for dart in sorted(root.rglob("*.dart")):
        rel = dart.relative_to(root)
        if str(rel).startswith((".dart_tool", "build")):
            continue
        lines = dart.read_text(encoding="utf-8").split("\n")

        imports: list[tuple[int, str]] = []
        for i, line in enumerate(lines, 1):
            m = re.match(r"import\s+'([^']+)';", line.strip())
            if m:
                imports.append((i, m.group(1)))

        body = body_without_imports_and_comments(lines)

        for lineno, uri in imports:
            if uri.startswith("dart:"):
                continue
            if uri.startswith("package:") and not uri.startswith(PKG_PREFIX):
                continue  # 第三方包，本脚本不管
            target = resolve(root, dart, uri)
            if not target.exists():
                problems.append(f"{rel}:{lineno} [路径不存在] {uri}")
                continue
            syms = exported_symbols(target)
            if not syms:
                continue
            used = [s for s in syms if re.search(r"\b" + re.escape(s) + r"\b", body)]
            if not used:
                problems.append(f"{rel}:{lineno} [未使用任何符号] {uri}")

    if problems:
        print("发现 %d 个 import 问题：" % len(problems))
        for p in problems:
            print("  ⚠️", p)
        return 1
    print("[ OK ] 全部 import 路径正确且被使用")
    return 0


if __name__ == "__main__":
    sys.exit(main())
