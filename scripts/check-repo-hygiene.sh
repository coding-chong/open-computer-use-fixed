#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Files this repository maintains itself and must always carry.
required_files=(
  ".gitignore"
  ".gitattributes"
  "CODEOWNERS"
  "CONTRIBUTING.md"
  "SECURITY.md"
  ".github/workflows/release.yml"
  "scripts/check-action-pinning.sh"
)

# Governance files upstream/main is missing as well (it ships only
# .github/workflows/release.yml, and neither .editorconfig nor .markdownlint.json
# exists there, so a hard requirement for this set cannot be satisfied by anyone).
# This fork does not publish the GitHub governance workflows either, so their
# absence is reported without failing the check.
advisory_files=(
  ".editorconfig"
  ".markdownlint.json"
  ".github/PULL_REQUEST_TEMPLATE.md"
  ".github/dependency-review-config.yml"
  ".github/ISSUE_TEMPLATE/bug_report.yml"
  ".github/ISSUE_TEMPLATE/feature_request.yml"
  ".github/ISSUE_TEMPLATE/config.yml"
  ".github/workflows/ci.yml"
  ".github/workflows/docs-check.yml"
  ".github/workflows/repo-hygiene.yml"
  ".github/workflows/supply-chain-security.yml"
)

failed=0

for path in "${required_files[@]}"; do
  if [[ ! -f "${repo_root}/${path}" ]]; then
    echo "缺少必要文件: ${path}"
    failed=1
  fi
done

for path in "${advisory_files[@]}"; do
  if [[ ! -f "${repo_root}/${path}" ]]; then
    echo "缺少（建议，不致命）: ${path}"
  fi
done

if grep -q $'\r' "${repo_root}/README.md"; then
  echo "README.md 含有 CRLF 换行"
  failed=1
fi

if ! grep -q "make check-docs" "${repo_root}/CONTRIBUTING.md"; then
  echo "CONTRIBUTING.md 应明确提到 make check-docs"
  failed=1
fi

if [[ "${failed}" -ne 0 ]]; then
  exit 1
fi

echo "仓库基础卫生检查通过"
