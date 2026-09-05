#!/usr/bin/env python3
"""Mechanical Java -> Scala 3 conversion for twilic core sources."""

from __future__ import annotations

import re
import sys
from pathlib import Path

UTIL_NAMES = (
    "ArrayList",
    "List",
    "Map",
    "Set",
    "HashMap",
    "HashSet",
    "TreeSet",
    "Arrays",
)


def convert_imports(lines: list[str]) -> tuple[list[str], list[str]]:
    util: set[str] = set()
    other: list[str] = []
    out: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        m = re.match(r"import\s+java\.util\.(\w+);", line)
        if m and m.group(1) in UTIL_NAMES:
            util.add(m.group(1))
            i += 1
            continue
        m = re.match(r"import\s+([\w.]+);", line)
        if m:
            other.append(f"import {m.group(1)}")
            i += 1
            continue
        if line.startswith("package "):
            out.append(line.replace(";", ""))
            i += 1
            continue
        break
    if util:
        out.append("import java.util.{"
                   + ", ".join(sorted(util))
                   + "}")
    out.extend(other)
    return out, lines[i:]


def convert_types(text: str) -> str:
    text = text.replace("byte[]", "Array[Byte]")
    text = text.replace("new byte[0]", "Array.emptyByteArray")
    text = re.sub(r"\bint\b", "Int", text)
    text = re.sub(r"\bboolean\b", "Boolean", text)
    text = re.sub(r"\blong\b", "Long", text)
    text = re.sub(r"\bdouble\b", "Double", text)
    text = re.sub(r"List<(\w+)>", r"java.util.List[\1]", text)
    text = re.sub(r"Map<(\w+),\s*(\w+)>", r"java.util.Map[\1, \2]", text)
    text = re.sub(r"Set<(\w+)>", r"java.util.Set[\1]", text)
    text = re.sub(r"ArrayList<(\w+)>", r"java.util.ArrayList[\1]", text)
    text = re.sub(r"HashMap<(\w+),\s*(\w+)>", r"java.util.HashMap[\1, \2]", text)
    text = re.sub(r"HashSet<(\w+)>", r"java.util.HashSet[\1]", text)
    text = re.sub(r"TreeSet<(\w+)>", r"java.util.TreeSet[\1]", text)
    text = text.replace("new ArrayList<>()", "new java.util.ArrayList()")
    text = text.replace("new HashMap<>()", "new java.util.HashMap()")
    text = text.replace("new HashSet<>()", "new java.util.HashSet()")
    text = re.sub(r";(\s*)$", r"\1", text, flags=re.MULTILINE)
    return text


METHOD_RE = re.compile(
    r"^(\s*)((?:public |private |protected )?)(?:static )?"
    r"([\w.<>\[\], ]+)\s+(\w+)\s*\(([^)]*)\)\s*(\{|throws)"
)


def convert_methods(text: str, class_name: str | None) -> str:
    lines = text.split("\n")
    out: list[str] = []
    for line in lines:
        if re.match(r"^\s*private\s+\w+\(\)\s*\{\s*\}\s*$", line):
            continue
        if re.match(r"^\s*private\s+\w+\(\)\s*\{\s*$", line):
            continue
        m = METHOD_RE.match(line)
        if m:
            indent, vis, ret, name, params, brace = m.groups()
            if name == class_name:
                continue
            if name in ("if", "while", "for", "switch", "catch"):
                out.append(line)
                continue
            ret = ret.strip()
            if ret == "void":
                ret = "Unit"
            vis = vis or ""
            out.append(f"{indent}{vis}def {name}({params}): {ret} {brace}")
        else:
            out.append(line)
    return "\n".join(out)


def convert_class_fields(text: str) -> str:
    lines = text.split("\n")
    out: list[str] = []
    depth = 0
    for line in lines:
        if "{" in line:
            depth += line.count("{")
        if "}" in line:
            depth -= line.count("}")
        m = re.match(
            r"^(\s+)((?:public |private )?)([\w.<>\[\]]+)\s+(\w+)(\s*=.*)?$",
            line,
        )
        if (
            depth > 0
            and m
            and m.group(3) not in ("def", "class", "object", "enum", "if", "for", "return")
            and not m.group(4)[0].isupper()
            and "(" not in line
            and "def " not in line
        ):
            indent, vis, typ, name, init = m.groups()
            init = init or ""
            out.append(f"{indent}{vis}var {name}: {typ}{init}")
        else:
            out.append(line)
    return "\n".join(out)


STATIC_OBJECTS = {
    "Codec",
    "Dictionary",
    "Api",
    "Session",
    "Twilic",
    "Version",
    "EmitRustClientFixtures",
    "DecodeRustServerFixtures",
}


def convert(content: str, filename: str) -> str:
    if "module io.twilic" in content:
        return ""
    lines = content.split("\n")
    header, body = convert_imports(lines)
    text = "\n".join(header + body)

    class_name = None
    m = re.search(r"final class (\w+)", text)
    if m:
        class_name = m.group(1)

    text = convert_types(text)
    text = re.sub(r"public\s+final\s+class\s+", "final class ", text)
    text = re.sub(r"public\s+final\s+enum\s+", "enum ", text)
    text = re.sub(r"public\s+enum\s+", "enum ", text)
    text = re.sub(r"public\s+static\s+", "", text)
    text = re.sub(r"public\s+", "", text)
    text = re.sub(r"private\s+static\s+", "private ", text)
    text = re.sub(r"\brecord\s+", "case class ", text)

    if class_name in STATIC_OBJECTS:
        text = text.replace(f"final class {class_name}", f"object {class_name}")

    text = convert_class_fields(text)
    text = convert_methods(text, class_name)

    if class_name == "MessageKind":
        text = re.sub(
            r"enum MessageKind \{([^}]+)static MessageKind fromByte\(Int b\) \{",
            r"enum MessageKind:\1\n\nobject MessageKind:\n  def fromByte(b: Int): MessageKind = {",
            text,
            flags=re.DOTALL,
        )
        text = text.replace("values().length", "values.length")
        text = text.replace("values()[idx]", "values(idx)")

    if class_name == "Value":
        text = text.replace("final class Value {", "object Value {")
        text = re.sub(r"^(\s+)def (of\w+)\(", r"\1def \2(", text, flags=re.MULTILINE)

    if class_name == "SessionEncoder":
        pass  # keep as class

    # case class fields
    text = re.sub(
        r"case class (\w+)\(([^)]+)\)",
        lambda m: m.group(0),
        text,
    )

    return text


def main() -> None:
    src_root = Path(sys.argv[1])
    dst_root = Path(sys.argv[2])
    for java in sorted(src_root.rglob("*.java")):
        rel = java.relative_to(src_root)
        scala = dst_root / rel.with_suffix(".scala")
        scala.parent.mkdir(parents=True, exist_ok=True)
        converted = convert(java.read_text(), scala.name)
        if converted.strip():
            scala.write_text(converted)
            print(scala)


if __name__ == "__main__":
    main()
