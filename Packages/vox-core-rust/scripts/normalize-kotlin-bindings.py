#!/usr/bin/env python3
"""Normalize UniFFI Kotlin for Android/JNA and a module-internal generated surface."""
import re
import sys
from pathlib import Path

CHECKSUM_PATTERN = re.compile(
    r"if \(lib\.(uniffi_[A-Za-z0-9_]+_checksum_[A-Za-z0-9_]+)\(\) != ([0-9]+)\) \{"
)

# Kotlin declaration shapes that UniFFI emits now or may emit for records, enums, errors,
# callback interfaces, and functions. Top-level generated declarations must not be reachable
# around the handwritten Android boundary.
DECLARATION = (
    r"(?:(?:open|abstract|data|enum|sealed|value|annotation|inline|const|lateinit|suspend)\s+)*"
    r"(?:class|interface|object|fun|typealias|val|var)"
)
PUBLIC_COLUMN_ZERO = re.compile(rf"(?m)^public\s+(?={DECLARATION}\b)")
DEFAULT_COLUMN_ZERO = re.compile(rf"(?m)^({DECLARATION}\b)")
ANNOTATED_EXPORTED_FUNCTION = re.compile(
    r"(?m)^(\s+@Throws\([^\n)]+::class\) )(?:public )?fun (`core[A-Za-z0-9]+`)"
)
UNANNOTATED_EXPORTED_FUNCTION = re.compile(
    r"(?m)^(\s+)(?:public )?fun (`core[A-Za-z0-9]+`)"
)
FORBIDDEN_COLUMN_ZERO = re.compile(rf"(?m)^(?:public\s+)?{DECLARATION}\b")
FORBIDDEN_EXPORTED_FUNCTION = re.compile(
    r"(?m)^\s+(?:@Throws\([^\n)]+::class\) )?(?:public )?fun `core[A-Za-z0-9]+`"
)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: normalize-kotlin-bindings.py <root>")
    bindings = sorted(Path(sys.argv[1]).rglob("*uniffi.kt"))
    if not bindings:
        raise SystemExit("no generated Kotlin binding found")
    for path in bindings:
        text = path.read_text()
        normalized, checksum_count = CHECKSUM_PATTERN.subn(
            r"if ((lib.\1() and 0xffff) != \2) {", text
        )
        if not checksum_count:
            raise SystemExit(f"no UniFFI checksum calls found in {path}")

        # UniFFI 0.32 has no Kotlin visibility option. Prefix every generated column-zero
        # declaration and every indented top-level `core*` function with `internal`. Members are
        # indented and therefore retain their generated visibility.
        visibility_count = 0
        normalized, count = PUBLIC_COLUMN_ZERO.subn("internal ", normalized)
        visibility_count += count
        normalized, count = DEFAULT_COLUMN_ZERO.subn(r"internal \1", normalized)
        visibility_count += count
        normalized, count = ANNOTATED_EXPORTED_FUNCTION.subn(r"\1internal fun \2", normalized)
        visibility_count += count
        normalized, count = UNANNOTATED_EXPORTED_FUNCTION.subn(r"\1internal fun \2", normalized)
        visibility_count += count
        if visibility_count < 20:
            raise SystemExit(f"incomplete UniFFI visibility normalization in {path}")

        forbidden = FORBIDDEN_COLUMN_ZERO.search(normalized) or FORBIDDEN_EXPORTED_FUNCTION.search(normalized)
        if forbidden:
            line = normalized.count("\n", 0, forbidden.start()) + 1
            raise SystemExit(f"generated Kotlin public top-level declaration at {path}:{line}")
        for required in (
            "internal open class CoreMaterializationSession",
            "internal data class CoreBuildInfo",
            "internal sealed class VoxCoreException",
            "internal fun `corePrepare`",
        ):
            if required not in normalized:
                raise SystemExit(f"missing internalized UniFFI declaration {required!r} in {path}")
        path.write_text(normalized)


if __name__ == "__main__":
    main()
