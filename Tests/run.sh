#!/bin/sh
# 回归测试。编译非界面代码，在一个临时的假 Home 里跑，结束后自动删除，不碰真实文件。
# 用法：./Tests/run.sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/TidyPaw"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

xcrun swiftc -swift-version 5 -O -o "$WORK/tests" \
    "$ROOT/Tests/main.swift" \
    "$SRC/Models.swift" "$SRC/PathSafety.swift" "$SRC/SystemCommand.swift" \
    "$SRC/FileScanner.swift" "$SRC/FileClassifier.swift" "$SRC/LeftoverScanner.swift" \
    "$SRC/ScanEngine.swift" "$SRC/UninstallScanner.swift" "$SRC/UninstallEngine.swift" \
    "$SRC/WeChatScanner.swift" "$SRC/PrivacyScanners.swift" \
    "$SRC/PhoneTransferCore.swift" "$SRC/PhoneTransferBackends.swift" "$SRC/PhoneTransferManager.swift"

mkdir "$WORK/home"
CFFIXED_USER_HOME="$WORK/home" "$WORK/tests"
