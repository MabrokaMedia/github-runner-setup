#!/usr/bin/env python3
"""
Migrate a GitHub Actions workflow file from Swatinem/rust-cache@v2 to
MabrokaMedia/github-runner-setup/rust-s3-cache (split restore + save).

Handles two patterns:
  A) with `workspaces: <name>` and/or `cache-on-failure: true` inputs
  B) no `workspaces:` input (workspace defaults to ".")

For each Swatinem block:
 - Replace with the restore action
 - Insert the save action right after the first `run: cargo ...` step that
   follows (or at end-of-job if there isn't one)

Usage:
  python migrate-workflow.py <path-to-.yml>
"""
import re
import sys
from pathlib import Path

RESTORE_TEMPLATE = """{indent}- id: rust-cache
{indent}  uses: MabrokaMedia/github-runner-setup/rust-s3-cache/restore@main
{indent}  with:
{indent}    workspace: {workspace}"""

SAVE_TEMPLATE = """{indent}- if: always()
{indent}  uses: MabrokaMedia/github-runner-setup/rust-s3-cache/save@main
{indent}  with:
{indent}    workspace: {workspace}
{indent}    key: ${{{{ steps.rust-cache.outputs.key }}}}
{indent}    cache-hit: ${{{{ steps.rust-cache.outputs.cache-hit }}}}"""


def migrate(src: str) -> str:
    lines = src.splitlines(keepends=False)
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        # Two patterns:
        #   A)   - uses: Swatinem/rust-cache@v2
        #   B)   - name: ...
        #          uses: Swatinem/rust-cache@v2
        indent = None
        name_line_consumed = False
        m_a = re.match(r"^(\s*)- uses: Swatinem/rust-cache@v2\s*$", line)
        if m_a:
            indent = m_a.group(1)
            start = i + 1
        else:
            m_b = re.match(r"^(\s*)- name:\s+.+$", line)
            if m_b and i + 1 < len(lines):
                candidate = lines[i + 1]
                if re.match(
                    rf"^{m_b.group(1)}\s+uses: Swatinem/rust-cache@v2\s*$", candidate
                ):
                    indent = m_b.group(1)
                    name_line_consumed = True
                    start = i + 2

        if indent is None:
            out.append(line)
            i += 1
            continue

        # Gather the `with:` block that follows (if any)
        j = start
        workspace = "."
        while j < len(lines):
            ln = lines[j]
            if re.match(rf"^{indent}\s+with:\s*$", ln):
                j += 1
                continue
            m2 = re.match(rf"^{indent}\s+workspaces:\s*(.+?)\s*$", ln)
            if m2:
                raw = m2.group(1).strip()
                # `rust -> target` → workspace is "rust"
                workspace = raw.split("->")[0].strip()
                j += 1
                continue
            if re.match(rf"^{indent}\s+cache-on-failure:.*$", ln):
                j += 1
                continue
            break

        # Emit restore
        out.append(RESTORE_TEMPLATE.format(indent=indent, workspace=workspace))

        # Walk forward copying steps until we find a `run: cargo ...` line.
        # When we find it, copy through the end of its block, then insert save.
        k = j
        cargo_emitted = False
        while k < len(lines):
            ln = lines[k]

            # Stop BEFORE appending if we hit another Swatinem block — the
            # outer loop will pick it up. Handle both patterns:
            #   A)   - uses: Swatinem/rust-cache@v2
            #   B)   - name: ...
            #          uses: Swatinem/rust-cache@v2
            if re.match(r"^(\s*)- uses: Swatinem/rust-cache@v2\s*$", ln):
                break
            if re.match(r"^(\s*)- name:\s+.+$", ln) and k + 1 < len(lines):
                m_bi = re.match(r"^(\s*)- name:\s+.+$", ln)
                if re.match(
                    rf"^{m_bi.group(1)}\s+uses: Swatinem/rust-cache@v2\s*$",
                    lines[k + 1],
                ):
                    break

            out.append(ln)
            stripped = ln.strip()

            if not cargo_emitted and stripped.startswith("run: cargo"):
                # Inline cargo call — save goes right after this line.
                k += 1
                out.append(SAVE_TEMPLATE.format(indent=indent, workspace=workspace))
                cargo_emitted = True
                continue

            if not cargo_emitted and stripped in ("run: |", "run: >"):
                # Multi-line run block — capture it, then check for cargo.
                run_indent = len(ln) - len(ln.lstrip())
                k += 1
                saw_cargo = False
                while k < len(lines):
                    nxt = lines[k]
                    if nxt.strip() == "" or (
                        len(nxt) - len(nxt.lstrip()) > run_indent
                    ):
                        out.append(nxt)
                        if "cargo" in nxt:
                            saw_cargo = True
                        k += 1
                    else:
                        break
                if saw_cargo:
                    out.append(SAVE_TEMPLATE.format(indent=indent, workspace=workspace))
                    cargo_emitted = True
                continue

            k += 1

        if not cargo_emitted:
            # No cargo step found after restore — append save at end of what
            # we copied so cache still saves on failure.
            out.append(SAVE_TEMPLATE.format(indent=indent, workspace=workspace))

        i = k

    return "\n".join(out) + ("\n" if src.endswith("\n") else "")


def main():
    if len(sys.argv) != 2:
        print("usage: migrate-workflow.py <path>", file=sys.stderr)
        sys.exit(2)
    p = Path(sys.argv[1])
    src = p.read_text(encoding="utf-8")
    if "Swatinem/rust-cache@v2" not in src:
        print(f"no Swatinem/rust-cache@v2 in {p}", file=sys.stderr)
        sys.exit(0)
    new = migrate(src)
    p.write_text(new, encoding="utf-8")
    print(f"migrated {p}")


if __name__ == "__main__":
    main()
