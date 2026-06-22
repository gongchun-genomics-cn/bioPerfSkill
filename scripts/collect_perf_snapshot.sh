#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "用法: $0 <command...>" >&2
  exit 2
fi

echo "## 系统"
date
uname -a
echo

echo "## CPU"
lscpu 2>/dev/null | sed -n '1,25p' || true
echo

echo "## 内存"
free -h 2>/dev/null || true
echo

echo "## 命令"
printf '%q ' "$@"
echo
echo

echo "## /usr/bin/time -v"
/usr/bin/time -v "$@"
