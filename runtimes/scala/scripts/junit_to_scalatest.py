#!/usr/bin/env python3
"""Convert JUnit 5 Java tests to ScalaTest FunSuite."""

from __future__ import annotations

import re
import sys
from pathlib import Path


def convert(content: str, class_name: str) -> str:
    content = content.replace("package io.twilic.internal.core;", "package io.twilic.internal.core")
    content = re.sub(r"import org\.junit\.jupiter\.api\.Assertions;\n", "", content)
    content = re.sub(r"import org\.junit\.jupiter\.api\.Test;\n", "", content)
    content = re.sub(
        r"import org\.junit\.jupiter\.api\.Assumptions;\n",
        "import org.scalatest.Assumptions.assume\n",
        content,
    )
    if "Assumptions.assumeTrue" in content:
        content = content.replace("Assumptions.assumeTrue", "assume")
    content = content.replace(
        "import io.twilic.Twilic;",
        "import io.twilic.Twilic\nimport org.scalatest.funsuite.AnyFunSuite\nimport org.scalatest.matchers.should.Matchers\n",
    )
    content = re.sub(
        rf"final class {class_name} \{{",
        f"class {class_name} extends AnyFunSuite with Matchers {{",
        content,
    )
    content = re.sub(
        r"@Test\s+void (\w+)\(\) \{",
        r'test("\1") {',
        content,
    )
    content = content.replace("Assertions.assertEquals(", "")
    # assertEquals(a, b) -> a shouldBe b  (simplified - handle manually for complex)
    content = re.sub(
        r"Assertions\.assertEquals\(([^,]+),\s*([^)]+)\)",
        r"\1 shouldBe \2",
        content,
    )
    content = re.sub(
        r"Assertions\.assertTrue\(([^)]+)\)",
        r"\1 shouldBe true",
        content,
    )
    content = re.sub(
        r"Assertions\.assertNotNull\(([^)]+)\)",
        r"\1 should not be null",
        content,
    )
    content = re.sub(
        r"Assertions\.assertInstanceOf\(([^,]+),\s*([^)]+)\)",
        r"\2 shouldBe a[\1]",
        content,
    )
    content = re.sub(r";(\s*)$", r"\1", content, flags=re.MULTILINE)
    content = content.replace("List.of(", "java.util.List.of(")
    content = content.replace("List<", "java.util.List[")
    content = content.replace("new ArrayList<>()", "new java.util.ArrayList()")
    content = content.replace("new ArrayList<", "new java.util.ArrayList[")
    content = content.replace("void ", "def ")
    return content


def main() -> None:
    src = Path(sys.argv[1])
    dst = Path(sys.argv[2])
    for java in src.rglob("*.java"):
        name = java.stem
        if name == "TestHelpers":
            continue
        text = convert(java.read_text(), name)
        out = dst / java.relative_to(src).with_suffix(".scala")
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text)
        print(out)


if __name__ == "__main__":
    main()
