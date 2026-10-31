#!/usr/bin/env bash
# cb-config.sh — 看/改配置文件，不用手工编辑 JSON
#
# 为什么需要它：配置散在两处（环境变量优先、文件次之），出问题时最常见的
# 一句是"我明明设了"。这个脚本把"当前生效的值是哪来的"直接打出来。
#
# 用法:
#   cb-config.sh                 # 等于 show
#   cb-config.sh show [--json]   # 所有键 + 当前生效值 + 来源（env/file/默认）
#   cb-config.sh get <键>        # 只取值，给别的脚本用（没有则退出码 3）
#   cb-config.sh set <键> <值>   # 原子写入，文件 600、目录 700
#   cb-config.sh unset <键>      # 删掉一个键
#   cb-config.sh path            # 只打印配置文件路径
#
# 键名与对应环境变量:
#   portfolio_id  COINBASE_PORTFOLIO_ID
#   key_file      COINBASE_KEY_FILE
#
# 退出码: 0 成功 / 2 用法错 / 3 键不存在或没有配置文件

set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
for cand in "$HERE/lib/config.sh" "$HERE/../scripts/lib/config.sh"; do
  [ -f "$cand" ] && { . "$cand"; break; }
done
[ -n "${CB_LIB_VERSION:-}" ] || { echo "错误: 找不到 lib/config.sh" >&2; exit 2; }

# 键 -> 环境变量名。加新键只改这里。
env_of() {
  case "$1" in
    portfolio_id) printf '%s' "COINBASE_PORTFOLIO_ID" ;;
    key_file)     printf '%s' "COINBASE_KEY_FILE" ;;
    *)            printf '' ;;
  esac
}

usage() {
  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

MODE="show"; JSON=0; KEY=""; VAL=""
while [ $# -gt 0 ]; do
  case "$1" in
    show|get|set|unset|path) MODE=$1; shift ;;
    --json)  JSON=1; shift ;;
    -h|--help) usage 0 ;;
    -*) printf '错误: 未知参数 %s（--help 看用法）\n' "$1" >&2; exit 2 ;;
    *)
      if [ -z "$KEY" ]; then KEY=$1
      elif [ -z "$VAL" ]; then VAL=$1
      else printf '错误: 多余参数 %s\n' "$1" >&2; exit 2
      fi
      shift ;;
  esac
done

CFG=$(cb_config_path)

case "$MODE" in
  path)
    printf '%s\n' "$CFG"
    ;;

  get)
    [ -n "$KEY" ] || { printf '错误: get 需要键名\n' >&2; exit 2; }
    e=$(env_of "$KEY")
    if [ -n "$e" ]; then
      v=$(eval "printf '%s' \"\${$e:-}\"")
      [ -n "$v" ] && { printf '%s\n' "$v"; exit 0; }
    fi
    if v=$(cb_cfg_raw "$KEY"); then printf '%s\n' "$v"; exit 0; fi
    printf '错误: 没有配置项 %s\n' "$KEY" >&2
    exit 3
    ;;

  set)
    [ -n "$KEY" ] || { printf '错误: set 需要 <键> <值>\n' >&2; exit 2; }
    if [ -z "$VAL" ]; then printf '错误: set 需要 <键> <值>\n' >&2; exit 2; fi
    case "$KEY" in
      portfolio_id)
        # 空值等于删掉；UUID 形状先校验一下，省得把拼错的 UUID 存进去天天 403
        case "$VAL" in
          ''|YOUR_PORTFOLIO_UUID) cb_cfg_unset "$KEY" >/dev/null 2>&1 || true
                                  cb_info "已清除 $KEY"; exit 0 ;;
          *-*-*-*-*) ;;
          *) printf '错误: portfolio_id 看着不像 UUID：%s\n' "$VAL" >&2; exit 2 ;;
        esac ;;
      key_file)
        [ -f "$VAL" ] || { printf '警告: %s 现在不存在（先记下来也行）\n' "$VAL" >&2; } ;;
      "") ;;
      *) printf '错误: 未知键 %s（可用：portfolio_id, key_file）\n' "$KEY" >&2; exit 2 ;;
    esac
    cb_cfg_set "$KEY" "$VAL" || { printf '错误: 写配置失败：%s\n' "$CFG" >&2; exit 3; }
    cb_info "已写入 $KEY = $VAL"
    cb_dim "文件：$CFG" >&2
    ;;

  unset)
    [ -n "$KEY" ] || { printf '错误: unset 需要键名\n' >&2; exit 2; }
    if cb_cfg_unset "$KEY" >/dev/null 2>&1; then
      cb_info "已删除 $KEY"
    else
      printf '错误: 配置里没有 %s\n' "$KEY" >&2
      exit 3
    fi
    ;;

  show)
    KEYS="portfolio_id key_file"
    if [ "$JSON" -eq 1 ]; then
      # 只输出"当前生效"的 JSON，方便别的脚本直接吃
      printf '{'
      first=1
      for k in $KEYS; do
        e=$(env_of "$k")
        v=""; src="none"
        if [ -n "$e" ]; then
          v=$(eval "printf '%s' \"\${$e:-}\"")
          [ -n "$v" ] && src="env"
        fi
        if [ "$src" = "none" ]; then
          if v2=$(cb_cfg_raw "$k"); then v=$v2; src="file"; fi
        fi
        [ -n "$v" ] || continue
        [ "$first" -eq 1 ] || printf ','
        first=0
        printf '"%s":"%s"' "$k" "$(printf '%s' "$v" | sed 's/\\/\\\\/g; s/"/\\"/g')"
      done
      printf '}\n'
      exit 0
    fi

    cb_info "配置文件: $CFG"
    if [ -f "$CFG" ]; then
      perms=$(stat -c '%a' "$CFG" 2>/dev/null || stat -f '%Lp' "$CFG" 2>/dev/null || echo '?')
      case "$perms" in
        600|400) cb_dim "权限: $perms" >&2 ;;
        *)       cb_warn "$CFG 的权限是 ${perms}，建议 chmod 600" ;;
      esac
    else
      cb_dim "（文件还不存在；用 set 或 cb-portfolio.sh --save 创建）" >&2
    fi
    cb_hr
    for k in $KEYS; do
      e=$(env_of "$k")
      v=""; src=""
      if [ -n "$e" ]; then
        v=$(eval "printf '%s' \"\${$e:-}\"")
        [ -n "$v" ] && src="env $e"
      fi
      if [ -z "$src" ]; then
        if v2=$(cb_cfg_raw "$k"); then v=$v2; src="file"; fi
      fi
      if [ -z "$src" ]; then
        printf '%-14s %s\n' "$k" "${CB_C_DIM}—${CB_C_OFF}"
      else
        printf '%-14s %s  %s\n' "$k" "$v" "${CB_C_DIM}($src)${CB_C_OFF}"
      fi
    done
    cb_hr
    cb_dim "优先级：命令行参数 > 环境变量 > 配置文件" >&2
    ;;
esac
exit 0
