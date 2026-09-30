#!/usr/bin/env bash
# 服务器端：部署 / 回滚 / 查看 mirasim 补丁版插件。本机不编译（资源不够），
# .so 在本地用 build-mirasim.sh 编好后上传到 dist/。
#
#   ./update-mirasim.sh deploy <dist/mirasim-vX.Y.Z.N.so>   热部署（不重启 CPA）+ 校验
#   ./update-mirasim.sh rollback                           撤下当前补丁版，回到上一个插件文件
#   ./update-mirasim.sh status                             当前生效插件、最近 30 分钟请求结果、官方最新 tag
#
# 文件名里的版本号决定加载优先级：带版本号的高于 mirasim.so，版本高的优先。
set -euo pipefail

ROOT=/root/mirasim-fix
PLUGIN_DIR=/etc/cliproxyapi/plugins
CONFIG=/etc/cliproxyapi/config.yaml
BACKUP_DIR=/opt/cliproxyapi/backups
UPSTREAM=https://github.com/KIDA-MNESIA/cpa-plugin-mirasim.git

log() { printf '\033[1;34m[mirasim]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[mirasim] %s\033[0m\n' "$*" >&2; exit 1; }

active_plugin_path() {
  local pid
  pid=$(systemctl show -p MainPID --value cliproxyapi)
  # 当前进程最后一条 load/hot reload 日志里的路径就是生效的插件
  journalctl -u cliproxyapi _PID="$pid" --no-pager -o cat 2>/dev/null \
    | grep -oE 'pluginhost: plugin (hot reloaded .*active_path|registered .*path)=[^ ]+' \
    | tail -1 | grep -oE '/[^ ]+\.so$' || true
}

# CPA 只在 config.yaml 内容哈希变化时重载，追加一行注释即可触发
touch_config() {
  echo "# mirasim plugin $1 ($(date '+%F %T'))" >> "$CONFIG"
}

cmd_deploy() {
  local src=${1:-}
  [ -n "$src" ] && [ -f "$src" ] || die "用法：$0 deploy <dist/mirasim-vX.Y.Z.N.so>"
  local name ver target ts since
  name=$(basename "$src")
  [[ $name =~ ^mirasim-v[0-9][0-9A-Za-z.+-]*\.so$ ]] || die "文件名必须是 mirasim-v<版本>.so：$name"
  ver=${name#mirasim-v}; ver=${ver%.so}
  file "$src" | grep -q 'ELF 64-bit LSB shared object, x86-64' || die "$name 不是 linux amd64 的 .so"
  target=$PLUGIN_DIR/$name

  if [ -e "$target" ]; then
    cmp -s "$src" "$target" && { log "$target 已存在且内容相同，无需部署"; return 0; }
    die "$target 已存在但内容不同。不能覆盖正在使用的同名文件，请在本地用 BUILD_NO=2 重新编译"
  fi

  ts=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$BACKUP_DIR"
  cp -a "$CONFIG" "$CONFIG.bak-mirasim-$ts"
  local cur; cur=$(active_plugin_path)
  [ -n "$cur" ] && [ -f "$cur" ] && cp -a "$cur" "$BACKUP_DIR/$(basename "$cur").bak-$ts"
  log "已备份 config 和当前插件（${cur:-未知}）"

  # 新文件 + rename，绝不覆盖写正在被 CPA 映射的 .so
  install -o cliproxyapi -g cliproxyapi -m 755 "$src" "$PLUGIN_DIR/.$name.tmp"
  mv "$PLUGIN_DIR/.$name.tmp" "$target"
  log "已放入 $target，触发热加载 ..."

  since=$(date '+%Y-%m-%d %H:%M:%S')
  touch_config "deploy $ver"
  for _ in $(seq 1 30); do
    sleep 2
    if journalctl -u cliproxyapi --since "$since" --no-pager -o cat \
        | grep -q "plugin hot reloaded plugin_id=mirasim active_version=$ver "; then
      journalctl -u cliproxyapi --since "$since" --no-pager -o cat | grep 'pluginhost:' | cut -c1-300
      log "热加载成功，当前生效版本 $ver（未重启 CPA）"
      return 0
    fi
  done
  journalctl -u cliproxyapi --since "$since" --no-pager -o cat | grep -i 'plugin' | cut -c1-300 || true
  die "60 秒内没看到热加载日志。文件已在插件目录：可 systemctl restart cliproxyapi 让它生效，或 $0 rollback 撤回"
}

cmd_rollback() {
  local cur ts since
  cur=$(active_plugin_path)
  [ -n "$cur" ] || die "无法确定当前生效的插件文件"
  case "$(basename "$cur")" in
    mirasim-v*.so) ;;
    *) die "当前生效的是 $cur，不是补丁版，无需回滚" ;;
  esac
  ts=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$BACKUP_DIR"
  mv "$cur" "$BACKUP_DIR/$(basename "$cur").rolledback-$ts"
  log "已移走 $cur → $BACKUP_DIR"
  since=$(date '+%Y-%m-%d %H:%M:%S')
  touch_config rollback
  sleep 10
  journalctl -u cliproxyapi --since "$since" --no-pager -o cat | grep 'pluginhost:' | cut -c1-300 || true
  log "当前生效：$(active_plugin_path)"
}

cmd_status() {
  log "插件目录："; ls -la "$PLUGIN_DIR"
  log "当前生效：$(active_plugin_path)"
  log "最近 30 分钟 mirasim 请求结果（模型 | 状态码 | 次数）："
  sudo -u postgres psql -P pager=off -d cpamp_usage -Atc \
    "select model, coalesce(fail_status_code,200), count(*) from cpamp_usage.usage_events
     where event_timestamp > now()-interval '30 minutes' and auth_file_snapshot like 'mirasim%'
     group by 1,2 order by 1,2" 2>/dev/null || true
  log "官方最新 tag：$(git ls-remote --tags --refs "$UPSTREAM" 'v*' 2>/dev/null | awk -F/ '{print $3}' | sort -V | tail -1)"
}

case "${1:-}" in
  deploy)   shift; cmd_deploy "${1:-}" ;;
  rollback) cmd_rollback ;;
  status)   cmd_status ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac
