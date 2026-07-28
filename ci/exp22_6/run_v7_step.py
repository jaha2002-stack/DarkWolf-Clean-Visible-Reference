#!/usr/bin/env python3
"""Extract and execute one exact PowerShell run block from the pinned EXP22.6 v7 workflow."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile

STEP_PREFIX = "      - name: "
RUN_MARKER = "        run: |"
SHELL_PREFIX = "        shell: "
WORKDIR_PREFIX = "        working-directory: "
SCRIPT_INDENT = "          "


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workflow", required=True, type=Path)
    parser.add_argument("--step", required=True)
    parser.add_argument("--workspace", required=True, type=Path)
    parser.add_argument("--scope-diff-check", action="store_true")
    return parser.parse_args()


def extract_step(workflow: Path, step_name: str) -> tuple[str, str | None, str]:
    text = workflow.read_text(encoding="utf-8")
    lines = text.splitlines(keepends=True)
    target = f"{STEP_PREFIX}{step_name}"

    matches = [index for index, line in enumerate(lines) if line.rstrip("\r\n") == target]
    if len(matches) != 1:
        raise RuntimeError(f"Expected exactly one step named {step_name!r}; found {len(matches)}")

    start = matches[0]
    end = len(lines)
    for index in range(start + 1, len(lines)):
        if lines[index].startswith(STEP_PREFIX):
            end = index
            break

    block = lines[start:end]
    shell = None
    working_directory = None
    run_index = None

    for index, line in enumerate(block):
        stripped = line.rstrip("\r\n")
        if stripped.startswith(SHELL_PREFIX):
            shell = stripped[len(SHELL_PREFIX):].strip()
        elif stripped.startswith(WORKDIR_PREFIX):
            working_directory = stripped[len(WORKDIR_PREFIX):].strip().strip("'\"")
        elif stripped == RUN_MARKER:
            run_index = index

    if shell is None:
        raise RuntimeError(f"Step {step_name!r} does not declare a shell")
    if shell.lower() not in {"pwsh", "powershell"}:
        raise RuntimeError(f"Step {step_name!r} uses unsupported shell {shell!r}")
    if run_index is None:
        raise RuntimeError(f"Step {step_name!r} does not contain a literal run block")

    script_lines: list[str] = []
    for line in block[run_index + 1:]:
        if line.strip() == "":
            script_lines.append("\n")
            continue
        if not line.startswith(SCRIPT_INDENT):
            raise RuntimeError(
                f"Unexpected indentation inside run block for {step_name!r}: {line!r}"
            )
        script_lines.append(line[len(SCRIPT_INDENT):])

    script = "".join(script_lines)
    if not script.strip():
        raise RuntimeError(f"Step {step_name!r} produced an empty script")
    return shell, working_directory, script


def main() -> int:
    args = parse_args()
    workflow = args.workflow.resolve()
    workspace = args.workspace.resolve()

    if not workflow.is_file():
        raise FileNotFoundError(f"Workflow not found: {workflow}")
    if not workspace.is_dir():
        raise NotADirectoryError(f"Workspace not found: {workspace}")

    shell, working_directory, script = extract_step(workflow, args.step)

    if args.scope_diff_check:
        old = "git diff --check\n"
        new = "git diff --check -- $sourceFiles\n"
        old_count = script.count(old)
        new_count = script.count(new)
        if old_count == 1 and new_count == 0:
            script = script.replace(old, new, 1)
        elif old_count == 0 and new_count == 1:
            pass
        else:
            raise RuntimeError(
                "Unexpected exact-patch diff-check markers: "
                f"old_count={old_count} new_count={new_count}"
            )

    cwd = workspace if not working_directory else (workspace / working_directory).resolve()
    if not cwd.is_dir():
        raise NotADirectoryError(f"Step working directory does not exist: {cwd}")

    digest = hashlib.sha256(script.encode("utf-8")).hexdigest().upper()
    safe_name = "".join(character if character.isalnum() else "_" for character in args.step)
    script_path = Path(tempfile.gettempdir()) / f"exp226_v8_{safe_name}.ps1"
    script_path.write_text(script, encoding="utf-8", newline="\n")

    print(f"EXP22_6_V8_EXTRACTED_STEP={args.step}")
    print(f"EXP22_6_V8_STEP_SHELL={shell}")
    print(f"EXP22_6_V8_STEP_WORKDIR={cwd}")
    print(f"EXP22_6_V8_STEP_SHA256={digest}")
    sys.stdout.flush()

    completed = subprocess.run(
        ["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(script_path)],
        cwd=str(cwd),
        env=os.environ.copy(),
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"Extracted step {args.step!r} failed with exit code {completed.returncode}"
        )

    print(f"EXP22_6_V8_STEP=PASS NAME={args.step}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"EXP22_6_V8_STEP=FAIL ERROR={exc}", file=sys.stderr)
        raise
