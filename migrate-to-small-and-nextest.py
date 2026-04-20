#!/usr/bin/env python3
"""
Migrate existing self-hosted runner workflows to:
  1. Route fmt jobs to the `small` runner tier (c7g.large), saving ~75% on
     those runner-hours.
  2. Replace `cargo test ...` with `cargo nextest run ...` (2-3× faster).

Detection:
  - fmt job: any job whose `steps:` include a `cargo fmt` invocation.
  - test step: any step whose `run:` (single- or multi-line) starts with
    `cargo test`. Doctest cases (`--doc`) and targeted-binary cases
    (`cargo test <name>`) are skipped.

Usage: python migrate-to-small-and-nextest.py <path>
"""
import re
import sys
from pathlib import Path


def parse_indent(line: str) -> int:
    return len(line) - len(line.lstrip())


def find_step_start(lines: list, run_line_idx: int) -> int | None:
    """Walk backward from a `run:` line to find the `- ` that starts the step.
    Returns the line index of the step's first line (the `- name:` or `- run:`)."""
    run_indent = parse_indent(lines[run_line_idx])
    # Step's first line has a hyphen — indent is the same as run's indent
    # (but run lives under a `- name:` on the previous line with same indent, OR
    # run IS the first line of a `- run:` step with one less indent than the body).
    # In practice, the step starts at the FIRST line going back with "- " at
    # an indent less than OR EQUAL to run_indent.
    for j in range(run_line_idx - 1, -1, -1):
        ln = lines[j]
        stripped = ln.lstrip()
        if stripped.startswith("- "):
            return j
        # If we walked outside this step (indent dropped below run's indent),
        # stop — something's off, return None.
        if ln.strip() and parse_indent(ln) < run_indent - 2:
            return None
    return None


def rewrite(src: str) -> tuple[str, dict]:
    lines = src.splitlines(keepends=False)
    stats = {"fmt_small": 0, "test_nextest": 0}

    # Pass 1: identify jobs containing `cargo fmt`
    fmt_jobs = set()  # job-start line indices
    current_job_start = None
    current_job_has_fmt = False

    def flush():
        nonlocal current_job_start, current_job_has_fmt
        if current_job_start is not None and current_job_has_fmt:
            fmt_jobs.add(current_job_start)
        current_job_start = None
        current_job_has_fmt = False

    for i, ln in enumerate(lines):
        m = re.match(r"^(  )([a-zA-Z_][\w-]*):\s*$", ln)
        if m:
            flush()
            current_job_start = i
        elif current_job_start is not None and "cargo fmt" in ln:
            current_job_has_fmt = True
    flush()

    # Pass 2: find which step indices (0-based from start of step's `- `) we
    # want to insert the nextest install step before. Also mark test-command
    # lines that need `cargo test` → `cargo nextest run`.
    install_before_step = []  # list of (step_start_idx, step_indent)
    replace_test_cmd = set()  # set of line indices where `cargo test` → nextest

    for i, ln in enumerate(lines):
        # Inline form: `run: cargo test ...`
        m_inline = re.match(r"^(\s*)run:\s*cargo test(\s|$)(.*)$", ln)
        if m_inline:
            rest = (m_inline.group(3) or "").strip()
            if "--doc" in rest:
                continue
            toks = rest.split()
            # First non-flag arg is a filter, which nextest handles, but
            # `cargo test my_binary` (positional) we skip.
            first = toks[0] if toks else ""
            if first and not first.startswith("-"):
                continue
            step_start = find_step_start(lines, i)
            if step_start is not None:
                install_before_step.append((step_start, parse_indent(lines[step_start])))
                replace_test_cmd.add(i)
            continue

        # Multi-line run block
        m_ml = re.match(r"^(\s*)run:\s*[|>][\s-]*$", ln)
        if m_ml:
            run_indent = parse_indent(ln)
            block_lines = []
            j = i + 1
            while j < len(lines):
                nxt = lines[j]
                if nxt.strip() == "" or parse_indent(nxt) > run_indent:
                    block_lines.append(j)
                    j += 1
                else:
                    break
            combined = "\n".join(lines[idx] for idx in block_lines)
            if re.search(r"\bcargo test\b", combined) and "--doc" not in combined:
                # Find the cargo test line inside the block for substitution
                for idx in block_lines:
                    if re.search(r"\bcargo test\b", lines[idx]):
                        replace_test_cmd.add(idx)
                        break
                step_start = find_step_start(lines, i)
                if step_start is not None:
                    install_before_step.append((step_start, parse_indent(lines[step_start])))
            continue

    # Deduplicate / sort insert points descending so we don't shift indices
    install_before_step = sorted(set(install_before_step), key=lambda x: -x[0])

    # Pass 3: build output
    # Convert `install_before_step` to a dict: line_idx -> step_indent
    install_map = {idx: ind for idx, ind in install_before_step}

    out = []
    current_job_start = None
    in_fmt_job = False

    for i, ln in enumerate(lines):
        # Enter new job?
        m = re.match(r"^(  )([a-zA-Z_][\w-]*):\s*$", ln)
        if m:
            current_job_start = i
            in_fmt_job = i in fmt_jobs

        # Insert nextest install step before this line?
        if i in install_map:
            indent = " " * install_map[i]
            out.append(f"{indent}- name: Install cargo-nextest")
            out.append(f"{indent}  run: curl -LsSf https://get.nexte.st/latest/linux-arm | tar -xzvf - -C ${{CARGO_HOME:-/opt/rust}}/bin")
            stats["test_nextest"] += 1

        # 1) Swap fmt job's runs-on: fast -> small
        if in_fmt_job:
            m_ro = re.match(r"^(\s*runs-on:\s*\[self-hosted,\s*linux,\s*arm64,\s*)fast(\s*\]\s*)$", ln)
            if m_ro:
                out.append(f"{m_ro.group(1)}small{m_ro.group(2)}")
                stats["fmt_small"] += 1
                continue

        # 2) Rewrite the cargo test invocation itself
        if i in replace_test_cmd:
            out.append(re.sub(r"\bcargo test\b", "cargo nextest run", ln, count=1))
            continue

        out.append(ln)

    return "\n".join(out) + ("\n" if src.endswith("\n") else ""), stats


def main():
    if len(sys.argv) != 2:
        print("usage: migrate-to-small-and-nextest.py <path>", file=sys.stderr)
        sys.exit(2)
    p = Path(sys.argv[1])
    src = p.read_text(encoding="utf-8")
    new, stats = rewrite(src)
    if new == src:
        print(f"no changes: {p}")
        return
    p.write_text(new, encoding="utf-8")
    print(f"migrated {p}: {stats}")


if __name__ == "__main__":
    main()
