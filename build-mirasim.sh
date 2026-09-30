#!/usr/bin/env bash
# 本地（Windows Git Bash）编译 mirasim 补丁版插件，服务器不编译。
#
#   ./build-mirasim.sh [tag]            拉官方代码 → 打 patches/*.patch → 测试 → 交叉编译 linux .so
#   ./build-mirasim.sh [tag] --upload   编译后上传到服务器 /root/mirasim-fix/dist/
#   ./build-mirasim.sh [tag] --deploy   上传后在服务器执行 update-mirasim.sh deploy（热加载，不重启 CPA）
#
# tag 省略取官方最新（如 v1.3.2）。产物 out/mirasim-v<版本>.<BUILD_NO>.so，默认 BUILD_NO=1。
# 工具链（Go、zig）是便携版，放在 D:/tools/mirasim-build，删掉该目录即卸载。
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TOOLS=/d/tools/mirasim-build
PATCH_DIR=$HERE/patches
OUT_DIR=$HERE/out
REPO=$TOOLS/src/cpa-plugin-mirasim
UPSTREAM=https://github.com/KIDA-MNESIA/cpa-plugin-mirasim.git
SSH_HELPER=/d/运维开发记录/ssh_run.py
BUILD_NO=${BUILD_NO:-1}
# 服务器是 Ubuntu 22.04（glibc 2.35），按它链接
ZIG_TARGET=x86_64-linux-gnu.2.35
PROXY=http://127.0.0.1:7897   # Clash；不可用时直连

log() { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[build] %s\033[0m\n' "$*" >&2; exit 1; }

TAG="" UPLOAD=0 DEPLOY=0
for arg in "$@"; do
  case "$arg" in
    --upload) UPLOAD=1 ;;
    --deploy) UPLOAD=1; DEPLOY=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) TAG=$arg ;;
  esac
done

if curl -s -m 5 -x "$PROXY" -o /dev/null https://proxy.golang.org; then
  export HTTPS_PROXY=$PROXY HTTP_PROXY=$PROXY
  log "经 Clash 代理下载"
fi

# 1. 官方源码（LF 行尾，否则补丁打不上）
if [ ! -d "$REPO/.git" ]; then
  mkdir -p "$(dirname "$REPO")"
  git -c core.autocrlf=false clone -q "$UPSTREAM" "$REPO"
  git -C "$REPO" config core.autocrlf false
fi
git -C "$REPO" fetch -q --tags origin
[ -n "$TAG" ] || TAG=$(git -C "$REPO" tag -l 'v*' --sort=-v:refname | head -1)
[ -n "$TAG" ] || die "没找到官方 tag"
VER=${TAG#v}
OUT_VER=$VER.$BUILD_NO
OUT=$OUT_DIR/mirasim-v$OUT_VER.so
SRC=$TOOLS/build/$TAG
log "官方版本 $TAG → 产物 $(basename "$OUT")"

git -C "$REPO" worktree remove -f "$SRC" 2>/dev/null || rm -rf "$SRC"
git -C "$REPO" worktree prune
mkdir -p "$TOOLS/build"
git -C "$REPO" worktree add -q -f --detach "$SRC" "$TAG"

# 2. 打补丁
shopt -s nullglob
patches=("$PATCH_DIR"/*.patch)
[ ${#patches[@]} -gt 0 ] || die "$PATCH_DIR 下没有补丁"
for p in "${patches[@]}"; do
  if git -C "$SRC" apply --check "$p" 2>/dev/null; then
    git -C "$SRC" apply "$p"
    log "已应用补丁 $(basename "$p")"
  elif git -C "$SRC" apply --check --reverse "$p" 2>/dev/null; then
    log "补丁 $(basename "$p") 的改动官方已包含，跳过"
  elif ! grep -q 'output_config.effort", "off"' "$SRC/internal/thinking/applier.go"; then
    die "补丁 $(basename "$p") 打不上，且官方代码里已没有 effort=off，可能官方已修复——请人工确认是否还需要补丁"
  else
    die "补丁 $(basename "$p") 打不上（官方改了相关代码），需要人工调整补丁"
  fi
done

# 3. 按 go.mod 选择 Go 版本（缺了自动下载 Windows 便携版）
GOVER=$(awk '/^toolchain go/{sub("toolchain go","");print;exit}' "$SRC/go.mod")
[ -n "$GOVER" ] || GOVER=$(awk '/^go /{print $2;exit}' "$SRC/go.mod")
GOROOT_DIR=$TOOLS/go$GOVER
if [ ! -x "$GOROOT_DIR/bin/go.exe" ]; then
  log "下载 Go $GOVER ..."
  curl -fsSL -m 600 -o "$TOOLS/go.zip" "https://go.dev/dl/go$GOVER.windows-amd64.zip"
  (cd "$TOOLS" && unzip -q go.zip && mv go "go$GOVER" && rm go.zip)
fi
[ -x "$TOOLS/zig/zig.exe" ] || die "缺少 $TOOLS/zig/zig.exe（从 https://ziglang.org/download/ 下载 x86_64-windows 解压为 zig/）"
export GOROOT=$(cygpath -w "$GOROOT_DIR") GOPATH=$(cygpath -w "$TOOLS/gopath") GOCACHE=$(cygpath -w "$TOOLS/gocache")
export GOTOOLCHAIN=local GOFLAGS=-mod=mod
GO=$GOROOT_DIR/bin/go.exe
ZIG=$(cygpath -m "$TOOLS/zig/zig.exe")
log "使用 $("$GO" version)"

cd "$SRC"
# 4. 测试（Windows 本机跑；cmd/mirasim 是 cgo ABI 层，只能在 linux 上测，这里跳过）
log "运行测试 ..."
CGO_ENABLED=0 "$GO" test ./internal/... > "$TOOLS/build/test-$TAG.log" 2>&1 \
  || { tail -40 "$TOOLS/build/test-$TAG.log"; die "测试失败，日志 $TOOLS/build/test-$TAG.log"; }
log "测试通过"

# 5. 交叉编译（与官方 release 相同参数，C 编译器用 zig）
log "编译 linux/amd64 c-shared ..."
mkdir -p "$OUT_DIR"
CGO_ENABLED=1 GOOS=linux GOARCH=amd64 \
  CC="$ZIG cc -target $ZIG_TARGET" CXX="$ZIG c++ -target $ZIG_TARGET" \
  "$GO" build -trimpath -buildmode=c-shared \
    -ldflags "-s -w -X main.pluginVersion=$OUT_VER -extldflags=-Wl,--strip-all" \
    -o "$(cygpath -w "$OUT")" ./cmd/mirasim
rm -f "${OUT%.so}.h"
log "编译完成：$OUT ($(stat -c %s "$OUT") bytes)"

[ "$UPLOAD" = 1 ] || exit 0

# 6. 上传 / 部署（复用 ssh_run.py 里的连接信息）
log "上传到服务器 ..."
MSYS_NO_PATHCONV=1 python - "$(cygpath -w "$OUT")" <<'PY'
import sys, os
sys.path.insert(0, r"D:\运维开发记录")
import ssh_run
cli, *_ = ssh_run.connect("relay")
sftp = cli.open_sftp()
local = sys.argv[1]
remote = "/root/mirasim-fix/dist/" + os.path.basename(local)
sftp.put(local, remote + ".part")
try:
    sftp.remove(remote)
except IOError:
    pass
sftp.rename(remote + ".part", remote)
sftp.close(); cli.close()
print("uploaded", remote)
PY

if [ "$DEPLOY" = 1 ]; then
  MSYS_NO_PATHCONV=1 python "$SSH_HELPER" relay "/root/mirasim-fix/update-mirasim.sh deploy /root/mirasim-fix/dist/$(basename "$OUT")"
else
  log "如需部署：python $SSH_HELPER relay \"/root/mirasim-fix/update-mirasim.sh deploy /root/mirasim-fix/dist/$(basename "$OUT")\""
fi
