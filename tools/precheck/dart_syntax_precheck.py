#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Dart 源码轻量静态自检（无 Dart 工具链时的兜底预检）。

检查项：
  1. 括号/方括号/花括号配对（跳过字符串与注释）
  2. 字符串字面量是否闭合（含三引号、raw 字符串、插值陷阱）
  3. 字符串插值 `$` 后必须跟标识符或 `{`（`$/` 这类会直接
     `Expected an identifier` 编译失败 —— 2026-10-02 CI 真实踩过）
  4. 同类引号嵌套（如 '...${x ?? 'a'}'）

这些是本项目历史上真实踩过的坑（单引号嵌套、字符串未闭合、`$/` 插值）。
不替代 dart analyze，只用于在推送 CI 前拦掉最蠢的错误。
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent

_IDENT_START = set('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_$')


def _is_raw_prefix(text: str, quote_index: int) -> bool:
    """判断 quote_index 处的引号是否带 r/R 前缀（raw 字符串不解析转义与插值）。"""
    if quote_index == 0:
        return False
    prev = text[quote_index - 1]
    if prev not in 'rR':
        return False
    if quote_index >= 2 and (text[quote_index - 2].isalnum() or text[quote_index - 2] in '_$'):
        return False
    return True


def strip_code(text: str) -> tuple[str, list[str]]:
    """把字符串内容和注释替换成占位符，只留下结构字符。返回 (结构文本, 错误列表)。"""
    errors: list[str] = []
    out: list[str] = []
    i = 0
    n = len(text)
    line = 1
    while i < n:
        c = text[i]
        if c == '\n':
            line += 1
            out.append(c)
            i += 1
            continue

        # 行注释
        if c == '/' and i + 1 < n and text[i + 1] == '/':
            while i < n and text[i] != '\n':
                i += 1
            continue

        # 块注释（Dart 支持嵌套）
        if c == '/' and i + 1 < n and text[i + 1] == '*':
            depth = 1
            i += 2
            while i < n and depth > 0:
                if text[i] == '\n':
                    line += 1
                if text[i] == '/' and i + 1 < n and text[i + 1] == '*':
                    depth += 1
                    i += 2
                    continue
                if text[i] == '*' and i + 1 < n and text[i + 1] == '/':
                    depth -= 1
                    i += 2
                    continue
                i += 1
            if depth != 0:
                errors.append(f'L{line}: 块注释未闭合')
            out.append(' ')
            continue

        # 字符串
        if c == "'" or c == '"':
            quote = c
            triple = text[i:i + 3] == quote * 3
            raw = _is_raw_prefix(text, i)
            start_line = line
            i += 3 if triple else 1
            closed = False
            while i < n:
                ch = text[i]
                if ch == '\n':
                    line += 1
                    if not triple:
                        break  # 单引号字符串里出现裸换行 → 未闭合
                if not raw and ch == '\\':
                    # 转义下一个字符（三引号里的 \ 换行续行会少记一行，可接受）
                    i += 2
                    continue
                if not raw and ch == '$':
                    nxt = text[i + 1] if i + 1 < n else ''
                    if nxt == '{':
                        # 跳过插值表达式（内部可能含字符串/花括号）
                        depth = 1
                        i += 2
                        while i < n and depth > 0:
                            c2 = text[i]
                            if c2 == '\n':
                                line += 1
                            elif c2 == '{':
                                depth += 1
                            elif c2 == '}':
                                depth -= 1
                            elif c2 in '\'"':
                                q2 = c2
                                i += 1
                                while i < n and text[i] != q2:
                                    if text[i] == '\n':
                                        line += 1
                                    i += 1
                            i += 1
                        continue
                    if nxt not in _IDENT_START:
                        errors.append(
                            f'L{line}: 字符串插值 "$" 后缺少标识符或 "{{"'
                            f'（得到 "{nxt}"；需写成 \\$ 或 ${{...}}）')
                        i += 1
                        continue
                    # 普通 $identifier 插值：整段跳过
                    while i < n and (text[i].isalnum() or text[i] in '_$'):
                        i += 1
                    continue
                if triple:
                    if text[i:i + 3] == quote * 3:
                        i += 3
                        closed = True
                        break
                    i += 1
                    continue
                if ch == quote:
                    i += 1
                    closed = True
                    break
                i += 1
            if not closed:
                errors.append(f'L{start_line}: 字符串字面量未闭合（引号 {quote}）')
            out.append('""')
            continue

        out.append(c)
        i += 1
    return ''.join(out), errors


def check_balance(structure: str, path: Path) -> list[str]:
    pairs = {')': '(', ']': '[', '}': '{'}
    opens = set(pairs.values())
    stack: list[tuple[str, int]] = []
    line = 1
    errors = []
    for c in structure:
        if c == '\n':
            line += 1
        elif c in opens:
            stack.append((c, line))
        elif c in pairs:
            if not stack:
                errors.append(f'L{line}: 多余的 "{c}"')
            elif stack[-1][0] != pairs[c]:
                errors.append(
                    f'L{line}: "{c}" 与 L{stack[-1][1]} 的 "{stack[-1][0]}" 不匹配')
                stack.pop()
            else:
                stack.pop()
    for c, ln in stack:
        errors.append(f'L{ln}: "{c}" 未闭合')
    return errors


def main() -> int:
    if len(sys.argv) == 1:
        targets = [ROOT]
    else:
        targets = [Path(p) for p in sys.argv[1:]]

    files: list[Path] = []
    for t in targets:
        if t.is_dir():
            files.extend(sorted(t.rglob('*.dart')))
        else:
            files.append(t)

    total_errors = 0
    checked = 0
    for f in files:
        posix = f.as_posix()
        if '/build/' in posix or '/.dart_tool/' in posix:
            continue
        checked += 1
        text = f.read_text(encoding='utf-8')
        structure, errs = strip_code(text)
        errs += check_balance(structure, f)
        if errs:
            total_errors += len(errs)
            print(f'[FAIL] {f}')
            for e in errs:
                print(f'       {e}')
        else:
            print(f'[ OK ] {f}')
    print()
    print(f'扫描 {checked} 个文件，问题 {total_errors} 处')
    return 1 if total_errors else 0


if __name__ == '__main__':
    raise SystemExit(main())
