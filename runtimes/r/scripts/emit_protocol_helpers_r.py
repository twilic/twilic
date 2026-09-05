#!/usr/bin/env python3
"""Emit R/protocol_helpers.R from twilic-python protocol.py helper functions."""

from __future__ import annotations

import ast
import re
from pathlib import Path

PY = Path(__file__).resolve().parents[2] / "python" / "src" / "twilic" / "protocol.py"
OUT = Path(__file__).resolve().parents[1] / "R" / "protocol_helpers.R"

SKIP = {
    "new_twilic_codec",
    "twilic_codec_with_options",
    "new_session_encoder",
    "reset_encode_shape_observation",
}


def py_expr_to_r(node: ast.AST, src: str) -> str:
    if isinstance(node, ast.Constant):
        if node.value is True:
            return "TRUE"
        if node.value is False:
            return "FALSE"
        if node.value is None:
            return "NULL"
        if isinstance(node.value, str):
            return repr(node.value)
        return repr(node.value)
    if isinstance(node, ast.Name):
        mapping = {
            "True": "TRUE",
            "False": "FALSE",
            "None": "NULL",
        }
        return mapping.get(node.id, node.id)
    if isinstance(node, ast.Attribute):
        base = py_expr_to_r(node.value, src)
        attr = node.attr
        # Enum style
        if base in ("MessageKind", "ValueKind", "VectorCodec", "ElementType", "NullStrategy", "PatchOpcode", "ControlStreamCodec"):
            return f"{base}{attr.upper()}" if attr.islower() else f"{base}{attr}"
        return f"{base}${attr}"
    if isinstance(node, ast.Call):
        fn = py_expr_to_r(node.func, src)
        args = ", ".join(py_expr_to_r(a, src) for a in node.args)
        if fn == "len":
            return f"length({args})"
        if fn == "min":
            return f"min({args})"
        if fn == "max":
            return f"max({args})"
        if fn == "sum":
            return f"sum({args})"
        if fn == "abs":
            return f"abs({args})"
        if fn == "all":
            return f"all({args})"
        if fn == "any":
            return f"any({args})"
        if fn == "sorted":
            return f"sort({args})"
        if fn == "range":
            return f"seq({args})"
        if fn == "list":
            return f"as.list({args})"
        if fn == "bytes":
            return f"as.raw({args})"
        if fn in ("invalid_data", "invalid_tag", "unknown_reference", "stateless_retry_required"):
            return f"{fn}({args})"
        if fn == "entry":
            return f"entry({args})"
        if fn.endswith(".clone"):
            base = fn[:-6]
            return f"value_clone({base})"
        if fn.startswith("new_"):
            return f"{fn}({args})"
        return f"{fn}({args})"
    if isinstance(node, ast.BinOp):
        left = py_expr_to_r(node.left, src)
        right = py_expr_to_r(node.right, src)
        op = {ast.Add: "+", ast.Sub: "-", ast.Mult: "*", ast.Div: "/", ast.FloorDiv: "%/%", ast.Mod: "%%", ast.BitAnd: "&", ast.BitOr: "|", ast.BitXor: "^", ast.LShift: "<<", ast.RShift: ">>"}
        return f"({left} {op.get(type(node.op), '?')} {right})"
    if isinstance(node, ast.UnaryOp):
        val = py_expr_to_r(node.operand, src)
        if isinstance(node.op, ast.Not):
            return f"!{val}"
        if isinstance(node.op, ast.USub):
            return f"-{val}"
    if isinstance(node, ast.Compare):
        left = py_expr_to_r(node.left, src)
        parts = [left]
        for op, comp in zip(node.ops, node.comparators):
            rop = {ast.Eq: "==", ast.NotEq: "!=", ast.Lt: "<", ast.LtE: "<=", ast.Gt: ">", ast.GtE: ">=", ast.In: "%in%", ast.Is: "identical", ast.IsNot: "!identical"}
            parts.append(f"{rop.get(type(op), '?')} {py_expr_to_r(comp, src)}")
        return " ".join(parts)
    if isinstance(node, ast.BoolOp):
        join = " && " if isinstance(node.op, ast.And) else " || "
        return join.join(f"({py_expr_to_r(v, src)})" for v in node.values)
    if isinstance(node, ast.IfExp):
        return f"if ({py_expr_to_r(node.test, src)}) {py_expr_to_r(node.body, src)} else {py_expr_to_r(node.orelse, src)}"
    if isinstance(node, ast.List):
        items = ", ".join(py_expr_to_r(e, src) for e in node.elts)
        return f"list({items})"
    if isinstance(node, ast.Tuple):
        items = ", ".join(py_expr_to_r(e, src) for e in node.elts)
        return f"list({items})"
    if isinstance(node, ast.Subscript):
        return f"{py_expr_to_r(node.value, src)}[[{py_expr_to_r(node.slice, src)} + 1L]]"
    if isinstance(node, ast.Index):  # py3.8
        return py_expr_to_r(node.value, src)
    if isinstance(node, ast.Slice):
        return "..."  # fallback
    # fallback to source
    return ast.get_source_segment(src, node) or "NULL"


def stmt_to_r(stmt: ast.stmt, src: str, indent: int = 2) -> list[str]:
    sp = " " * indent
    out: list[str] = []
    if isinstance(stmt, ast.Return):
        val = py_expr_to_r(stmt.value, src) if stmt.value else "NULL"
        if isinstance(stmt.value, ast.Tuple):
            out.append(f"{sp}return({val})")
        else:
            out.append(f"{sp}return({val})")
    elif isinstance(stmt, ast.Raise):
        if isinstance(stmt.exc, ast.Call):
            out.append(f"{sp}twilic_stop({py_expr_to_r(stmt.exc, src)})")
        else:
            out.append(f"{sp}stop('error')")
    elif isinstance(stmt, ast.Assign):
        targets = ", ".join(py_expr_to_r(t, src) for t in stmt.targets)
        out.append(f"{sp}{targets} <- {py_expr_to_r(stmt.value, src)}")
    elif isinstance(stmt, ast.AnnAssign):
        out.append(f"{sp}{py_expr_to_r(stmt.target, src)} <- {py_expr_to_r(stmt.value, src)}")
    elif isinstance(stmt, ast.If):
        out.append(f"{sp}if ({py_expr_to_r(stmt.test, src)}) {{")
        for s in stmt.body:
            out.extend(stmt_to_r(s, src, indent + 2))
        if stmt.orelse:
            out.append(f"{sp}}} else {{")
            for s in stmt.orelse:
                out.extend(stmt_to_r(s, src, indent + 2))
        out.append(f"{sp}}}")
    elif isinstance(stmt, ast.For):
        target = py_expr_to_r(stmt.target, src)
        iter_ = py_expr_to_r(stmt.iter, src)
        if isinstance(stmt.iter, ast.Call) and py_expr_to_r(stmt.iter.func, src) == "range":
            out.append(f"{sp}for ({target} in {iter_}) {{")
        elif isinstance(stmt.iter, ast.Name):
            out.append(f"{sp}for ({target} in {iter_}) {{")
        else:
            out.append(f"{sp}for ({target} in seq_along({iter_})) {{")
        for s in stmt.body:
            out.extend(stmt_to_r(s, src, indent + 2))
        out.append(f"{sp}}}")
    elif isinstance(stmt, ast.While):
        out.append(f"{sp}while ({py_expr_to_r(stmt.test, src)}) {{")
        for s in stmt.body:
            out.extend(stmt_to_r(s, src, indent + 2))
        out.append(f"{sp}}}")
    elif isinstance(stmt, ast.Pass):
        pass
    elif isinstance(stmt, ast.Expr):
        out.append(f"{sp}{py_expr_to_r(stmt.value, src)}")
    elif isinstance(stmt, ast.Match):
        out.append(f"{sp}# TODO match statement")
    else:
        seg = ast.get_source_segment(src, stmt)
        if seg:
            out.append(f"{sp}# {seg.strip()}")
    return out


def func_to_r(fn: ast.FunctionDef, src: str) -> list[str]:
    args = []
    for a in fn.args.args:
        if a.arg == "self":
            continue
        args.append(a.arg)
    lines = [f"{fn.name} <- function({', '.join(args)}) {{"]
    for stmt in fn.body:
        lines.extend(stmt_to_r(stmt, src))
    lines.append("}")
    return lines


def main() -> None:
    src = PY.read_text()
    tree = ast.parse(src)
    out = [
        "# Ported from twilic-python protocol.py (module helpers)",
        "",
        "TAG_NULL <- 0L",
        "TAG_BOOL_FALSE <- 1L",
        "TAG_BOOL_TRUE <- 2L",
        "TAG_I64 <- 3L",
        "TAG_U64 <- 4L",
        "TAG_F64 <- 5L",
        "TAG_STRING <- 6L",
        "TAG_BINARY <- 7L",
        "TAG_ARRAY <- 8L",
        "TAG_MAP <- 9L",
        "",
    ]
    started = False
    for node in tree.body:
        if isinstance(node, ast.FunctionDef):
            if node.name == "typed_vector_len":
                started = True
            if not started or node.name in SKIP:
                continue
            out.extend(func_to_r(node, src))
            out.append("")
    OUT.write_text("\n".join(out) + "\n")
    print(f"wrote {OUT} ({len(out)} lines)")


if __name__ == "__main__":
    main()
