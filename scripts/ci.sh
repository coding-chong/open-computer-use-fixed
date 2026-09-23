#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"${repo_root}/scripts/check-docs.sh"
"${repo_root}/scripts/check-repo-hygiene.sh"
"${repo_root}/scripts/check-action-pinning.sh"
"${repo_root}/scripts/tests/install-dsh-mcp.test.sh"

while IFS= read -r file; do
  bash -n "$file"
done < <(find "${repo_root}/scripts" -type f -name '*.sh' | sort)

while IFS= read -r file; do
  node --check "$file"
done < <(find "${repo_root}/scripts" -type f -name '*.mjs' | sort)

node --test "${repo_root}"/scripts/node-repl/*.test.mjs

# A python3 on PATH is not enough: the Microsoft Store app-execution alias exists
# but exits 49 without running anything, so probe the interpreter before using it.
if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys' >/dev/null 2>&1; then
  (
    cd "${repo_root}/apps/OpenComputerUseLinux"
    python3 -m unittest -v runtime_test.py
  )
else
  echo "跳过 Linux python 单测（没有可用的 python3）"
fi

if command -v go >/dev/null 2>&1; then
  (
    cd "${repo_root}/apps/OpenComputerUseWindows"
    go test ./...
  )
  # The Linux app is Linux-only (syscall.Stat_t, /proc) and has no build tag, so its
  # tests do not even compile on Windows; run them where the host is the target.
  if [[ "$(uname -s)" == "Linux" ]]; then
    (
      cd "${repo_root}/apps/OpenComputerUseLinux"
      go test ./...
    )
  else
    echo "跳过 Linux Go 测试（仅可在 Linux 上构建；当前 $(uname -s)）"
  fi
fi

# Interactive desktop fixture smoke, opt-in: it drives real windows on the current
# desktop, so the default run must not depend on one. The Chromium core cases need
# the fixture's own -IncludeChromium switch; this hook deliberately does not pass it.
if [[ "${OCU_RUN_WINDOWS_FIXTURE_SMOKE:-0}" != "1" ]]; then
  echo "跳过交互 fixture smoke（需要交互桌面；设 OCU_RUN_WINDOWS_FIXTURE_SMOKE=1 开启）"
elif ! command -v pwsh >/dev/null 2>&1; then
  echo "跳过交互 fixture smoke（OCU_RUN_WINDOWS_FIXTURE_SMOKE=1 但未找到 pwsh）"
else
  pwsh -NoProfile -ExecutionPolicy Bypass -File "${repo_root}/apps/OpenComputerUseWindows/fixtures/run-interactive-smoke.ps1"
fi

echo "基础 CI 检查通过"
