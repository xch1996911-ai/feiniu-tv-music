#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Dart 源码轻量静态自检（无 Dart 工具链时的兜底预检）。

检查项：
  1. 括号/方括号/花括号配对（跳过字符串与注释）
  2. 字符串字面量是否闭合（含三引号、raw 字符串、插值陷阱）
  3. 字符串插值 `$` 后必须跟标识符或 `{`（`$/` 这类会直接
     `Expected an identifier` 编译失败 —— 2026-10-02 CI 真实踩过）
  4. 同类引号嵌套（如 '...${x ?? 'a'}'）
  5. ⚠️ 枚举值列表末尾漏 `;`（增强枚举）—— analyzer 会报一堆**与分号
     毫不相关**的错（`constant_identifier_names: The constant name 'String'
     isn't a lowerCamelCase identifier` + 若干 `expected_token`），
     2026-10-03 CI 真实白烧一轮。
  6. ⚠️ 构造函数体里以**裸名**引用了「同名的形参」——
     形参在构造函数体内可见并**遮蔽同名字段**，于是「初始化列表里的归一化」
     看起来生效、实际构造体内拿到的还是原始值。analyzer 与以上 5 项都查不出来，
     只能靠测试抓（2026-10-03 CI 真实白烧一轮）。本项是 WARN 级提醒，不改变退出码。
  7. ⚠️ 同一个 `Column` 里堆了两行 `Text`，却没有显式 `TextStyle.height`。
     M3 主题给 `DefaultTextStyle` 的行高是 20/14 ≈ 1.43（不是直觉的 1.0），
     在 `ListView.itemExtent` / 网格 `mainAxisExtent` 这类**固定行高**里
     必然 `RenderFlex overflowed`（电视上就是黄黑条纹）。
     另外「字号 × height 必须落在整数上」—— Flutter 逐行把行盒高度**向上取整**，
     `19 × 1.2 = 22.8 → 23`，算式上「刚好等于行高」也会被判溢出 `0.400 pixels`。
     本项是 WARN 级提醒，不改变退出码。

这些是本项目历史上真实踩过的坑（单引号嵌套、字符串未闭合、`$/` 插值、
形参遮蔽、枚举漏分号、固定行高溢出）。
不替代 dart analyze，只用于在推送 CI 前拦掉最蠢的错误。
"""
from __future__ import annotations

import re
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
    """把字符串内容和注释替换成占位符，只留下结构字符。返回 (结构文本, 错误列表)。

    ⚠️ **行数必须与原文一致**：每个占位符后面会把该 token 内部吃掉的换行补回来
    （块注释、三引号字符串都可能跨行）。否则结构文本里的行列号全部错位，
    [check_fixed_height_text] 报出来的行号就是假的。
    [main] 里有 `structure.count('\\n') == text.count('\\n')` 的自检。
    """
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

        line0 = line  # 本 token 起始行：token 内吃掉的换行要在收尾时补回

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
            out.append(' ' + '\n' * (line - line0))
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
            out.append('""' + '\n' * (line - line0))
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


def _match_pair(text: str, start: int, open_ch: str, close_ch: str) -> int:
    """返回 text[start]（应为 open_ch）之后与它配对的 close_ch 的下标。

    找不到配对时返回 len(text)。不做字符串/注释跳过 —— 形参与初始化列表里
    出现裸括号字面量的概率极低，宁可漏报也不要误判。
    """
    depth = 0
    for i in range(start, len(text)):
        c = text[i]
        if c == open_ch:
            depth += 1
        elif c == close_ch:
            depth -= 1
            if depth == 0:
                return i
    return len(text)


def _split_top_level(text: str) -> list[str]:
    """按顶层逗号切分（忽略括号内的逗号）。"""
    parts: list[str] = []
    buf: list[str] = []
    depth = 0
    for c in text:
        if c in '([{<':
            depth += 1
        elif c in ')]}>':
            depth -= 1
        if c == ',' and depth <= 0:
            parts.append(''.join(buf))
            buf = []
            continue
        buf.append(c)
    if buf:
        parts.append(''.join(buf))
    return parts


def _param_names(params: str) -> set[str]:
    """从形参文本里取出「普通形参」的名字（跳过 this.x / super.x 这类初始化形参）。

    ⚠️ 必须先剥掉具名参数的外层 `{}`（或可选位置参数的 `[]`）再按逗号切分 ——
    否则整串 `{ a, b }` 会被当成**一个**参数，只取到最后一个名字。
    """
    inner = params.strip()
    if len(inner) >= 2 and inner[0] in '{[' and inner[-1] in '}]':
        inner = inner[1:-1]

    names: set[str] = set()
    for raw in _split_top_level(inner):
        part = raw.strip()
        if not part or part.startswith('this.') or part.startswith('super.'):
            continue
        part = part.split('=')[0]  # 去掉默认值
        ids = re.findall(r'[A-Za-z_$][\w$]*', part)
        if ids:
            names.add(ids[-1])
    return names


def check_ctor_param_shadowing(text: str, path: Path) -> list[str]:
    """构造函数体里的裸名若与形参同名，极可能是遮蔽笔误。

    真实案例（2026-10-03，CI 白烧一轮，analyze 全绿但 1 条测试失败）：

        FnosClient({required String baseUrl, ...})
            : baseUrl = normalizeBaseUrl(baseUrl),   // 归一化确实写进了字段
              _deviceId = deviceId {
          _dio = Dio(BaseOptions(baseUrl: baseUrl, ...));  // ← 拿到的是形参！
        }

    启发式规则：**既在初始化列表里被赋值、又在构造函数体里以裸名出现**的形参，
    几乎一定是想写 `this.x`。只报 WARN，交给人判断。
    """
    warnings: list[str] = []
    for m in re.finditer(r'(?m)^([ \t]*)([A-Z]\w*)\(', text):
        name = m.group(2)
        open_paren = m.end() - 1
        close_paren = _match_pair(text, open_paren, '(', ')')
        if close_paren >= len(text):
            continue

        # 构造函数的标志：形参之后（可能隔着初始化列表）紧跟 `{` 体。
        cursor = close_paren + 1
        while cursor < len(text) and text[cursor] in ' \t\r\n':
            cursor += 1
        init_text = ''
        if cursor < len(text) and text[cursor] == ':':
            brace = text.find('{', cursor)
            if brace == -1:
                continue
            init_text = text[cursor + 1:brace]
            cursor = brace
        if cursor >= len(text) or text[cursor] != '{':
            continue  # 是抽象/getter 声明或方法调用，不是带体的构造函数

        body_start = cursor + 1
        body_end = _match_pair(text, cursor, '{', '}')
        body = text[body_start:body_end]

        params = _param_names(text[open_paren + 1:close_paren])
        assigned = set(re.findall(r'([A-Za-z_$][\w$]*)\s*=', init_text))
        for shared in sorted(params & assigned):
            # 体内以裸名出现（排除 this.x / obj.x / 更长标识符）
            pat = re.compile(rf'(?<![\w$.]){re.escape(shared)}(?![\w$])')
            for hit in pat.finditer(body):
                # 紧邻 `:` 的是**具名实参的标签 / map 键**，不是变量读取
                # （正确写法 `baseUrl: this.baseUrl` 就属于这种，别误报）。
                if body[hit.end():hit.end() + 1] == ':':
                    continue
                line = text.count('\n', 0, body_start + hit.start()) + 1
                warnings.append(
                    f'L{line}: 构造函数体里的 `{shared}` 是**形参**（会遮蔽同名字段），'
                    f'而初始化列表已把字段 `{shared}` 赋过值；'
                    f'想用字段请写 `this.{shared}`（{name} 的构造函数）')
                break
    return warnings


def check_enum_semicolon(structure: str, path: Path) -> list[str]:
    """枚举值列表末尾漏 `;` —— 增强枚举最经典的语法错误。

    真实案例（2026-10-03，CI 白烧一轮）：`LyricRepository` 里的

        enum LyricOrigin {
          none,
          nas,
          online,
          manual,          // ← 少了 `;`

          String get label => switch (this) { ... };
        }

    analyzer 报的是 5 条**看着毫不相关**的错
    （`constant_identifier_names: The constant name 'String' isn't a
    lowerCamelCase identifier` + 3 条 `expected_token`），
    外加测试里 2 条 `instance_access_to_static_member` ——
    根因却只是「少了一个分号」。本脚本当时完全没拦住。

    启发式规则：只看枚举体**顶层**里**第一个 `;` 之前**的文本 ——
    那一段本来应该**只有枚举值**。若其中出现成员声明特征
    （`get` / `set` / `=`）就说明值列表没有被 `;` 收尾。
    （纯值列表里不会出现这些字符，所以「纯值枚举」与「写对了的增强枚举」
    都不会误报；已经写过 `;` 的成员部分在 `;` 之后，天然被排除。）

    ⚠️ 不能简单地「只要顶层有 `;` 就放行」：成员方法体自己的结尾 `;`
    也落在顶层（`=> switch (this) { ... };` 的花括号闭合后深度回到 0），
    那样就会漏掉真正的漏分号。

    传入的是 [strip_code] 处理过的结构文本：字符串已变成 `""`、注释已删除，
    因此不会把注释里的 `get` 当成成员。
    """
    errors: list[str] = []
    member_pat = re.compile(r'\bget\b|\bset\b|=')
    for m in re.finditer(r'\benum\s+([A-Za-z_$][\w$]*)\s*\{', structure):
        open_brace = m.end() - 1
        close_brace = _match_pair(structure, open_brace, '{', '}')
        if close_brace >= len(structure):
            continue

        # 只取枚举体的**顶层**字符（跳过嵌套的 () [] {}）
        depth = 0
        top: list[str] = []
        for c in structure[open_brace + 1:close_brace]:
            if c in '([{':
                depth += 1
            elif c in ')]}':
                depth -= 1
            if depth == 0:
                top.append(c)
        top_text = ''.join(top)

        semicolon = top_text.find(';')
        head = top_text if semicolon < 0 else top_text[:semicolon]
        if not member_pat.search(head):
            continue  # 值列表干净（或已正确收尾）→ 合法

        line = structure.count('\n', 0, open_brace) + 1
        errors.append(
            f'L{line}: enum {m.group(1)} 的枚举值列表末尾缺少 `;` —— '
            f'枚举值后面还有 `get` / 成员定义，必须先写 `;` 结束值列表'
            f'（否则 analyzer 会报一堆与分号毫不相关的错）')
    return errors


def _direct_text_children(inner: str) -> list[str]:
    """取出 `children: <Widget>[ ... ]` 里**直接就是 `Text(...)`** 的子项文本。

    只看直接子项：嵌套 widget（如 `_SectionHeader(...)`）里的 Text 不算 ——
    它们的行高不由这个 Column 决定，算进来就是误报。
    """
    idx = inner.find('children:')
    if idx < 0:
        return []
    lb = inner.find('[', idx)
    if lb < 0:
        return []
    rb = _match_pair(inner, lb, '[', ']')
    if rb >= len(inner):
        return []

    out: list[str] = []
    for raw in _split_top_level(inner[lb + 1:rb]):
        stripped = re.sub(r'^const\s+', '', raw.strip())
        if stripped.startswith('Text('):
            out.append(stripped)
    return out


def check_fixed_height_text(structure: str, path: Path) -> list[str]:
    """`Column` 里堆了两行 `Text` 却没写 `style.height` —— 固定行高里必溢出。

    真实案例（2026-10-03，两条用例连续烧掉两轮 CI）：

      a. `queue_sheet.dart` 的队列行（`ListView.itemExtent = 74`）：
         18 号字继承 M3 的 1.43 行高 → 占 26px，14 号字占 20px，
         加 2px 间距共 48px，而行内容区只有 46px
         → `RenderFlex overflowed by 2.0 pixels`。

      b. `overview_page.dart` 的专辑瓦片：写对了 `height: 1.2`，但
         19 × 1.2 = 22.8、14 × 1.2 = 16.8 → Flutter 逐行**向上取整**成 23 / 17，
         于是「算式上刚好等于行高」的布局被判
         `RenderFlex overflowed by 0.400 pixels`（0.2 + 0.2）。

    因此本项同时提醒两件事：① 必须显式写 `height`（M3 默认 1.43，不是 1.0）；
    ② 字号 × height 应落在整数上。

    启发式规则（**两道门都要过**才报，否则这种「两行文字堆叠」的写法满仓库都是）：
      1. 文件里出现了固定行高的写法 —— `ListView.itemExtent:` 或
         网格 / `SliverGridDelegateWithFixedCrossAxisCount` 的 `mainAxisExtent:`；
      2. 某个 `Column` 的**直接**子项里 ≥2 个是 `Text(...)`，
         且其中有 `TextStyle` 写了 `fontSize` 却没有 `height`。

    仍无法判断那个 Column 是否真的落在固定行高里，所以只报 WARN。
    传入的是 [strip_code] 处理过的结构文本：字符串已变成 `""`，
    数字（`fontSize: 21` / `height: 1.2`）仍然可见，也不会被引号干扰配对。
    """
    # 门 1：整个文件都没有固定行高写法 → 不可能触发本类溢出，直接不查。
    if not re.search(r'\b(?:itemExtent|mainAxisExtent)\s*:', structure):
        return []

    warnings: list[str] = []
    for m in re.finditer(r'\bColumn\s*\(', structure):
        open_paren = m.end() - 1
        close_paren = _match_pair(structure, open_paren, '(', ')')
        if close_paren >= len(structure):
            continue
        inner = structure[open_paren + 1:close_paren]

        texts = _direct_text_children(inner)
        if len(texts) < 2:
            continue

        missing = False
        for child in texts:
            for sm in re.finditer(r'TextStyle\s*\(', child):
                sp = sm.end() - 1
                se = _match_pair(child, sp, '(', ')')
                body = child[sp + 1:se]
                if 'fontSize' in body and 'height' not in body:
                    missing = True
                    break
            if missing:
                break
        if not missing:
            continue

        line = structure.count('\n', 0, open_paren) + 1
        warnings.append(
            f'L{line}: 该 Column 叠了 {len(texts)} 行 Text，且本文件用了固定行高'
            f'（itemExtent / mainAxisExtent）—— 若它落在那个固定行高的行/瓦片里，'
            f'就必须显式写 TextStyle.height：M3 默认行高是 1.43，'
            f'且「字号 × height」要为整数（Flutter 逐行向上取整）。'
            f'（确认不在固定行高内可忽略本条 —— 词法上无法判断，故只提醒）')
    return warnings


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
    total_warnings = 0
    checked = 0
    parity_broken: list[str] = []
    for f in files:
        posix = f.as_posix()
        if '/build/' in posix or '/.dart_tool/' in posix:
            continue
        checked += 1
        text = f.read_text(encoding='utf-8')
        structure, errs = strip_code(text)
        # 自检：结构文本必须与原文行数一致，否则报出来的行号全是假的。
        if structure.count('\n') != text.count('\n'):
            parity_broken.append(
                f'{f}: 结构文本 {structure.count(chr(10))} 行 '
                f'!= 原文 {text.count(chr(10))} 行')
        errs += check_balance(structure, f)
        errs += check_enum_semicolon(structure, f)
        warns = check_ctor_param_shadowing(text, f)
        warns += check_fixed_height_text(structure, f)
        if errs:
            total_errors += len(errs)
            print(f'[FAIL] {f}')
            for e in errs:
                print(f'       {e}')
        else:
            print(f'[ OK ] {f}')
        if warns:
            total_warnings += len(warns)
            for w in warns:
                print(f'       [WARN] {w}')
    if parity_broken:
        total_errors += len(parity_broken)
        print()
        print('[FAIL] 预检脚本自身失准：结构文本与原文行数不一致（行号会错位）')
        for p in parity_broken:
            print(f'       {p}')
    print()
    suffix = f'，另有 {total_warnings} 条提醒（不阻断）' if total_warnings else ''
    print(f'扫描 {checked} 个文件，问题 {total_errors} 处{suffix}')
    # 提醒级问题不改变退出码：这是启发式判断，需要人来确认。
    return 1 if total_errors else 0


if __name__ == '__main__':
    raise SystemExit(main())
