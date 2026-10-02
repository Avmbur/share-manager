#!/usr/bin/env bash
# Общие папки: NFS для Linux и SMB для Windows.
set -u
set -o pipefail

if [[ "${SHARE_MANAGER_TEST_MODE:-}" == 1 ]]; then
  EXPORTS_FILE="${SHARE_MANAGER_EXPORTS_FILE:-/etc/exports}"
  SMB_CONF="${SHARE_MANAGER_SMB_CONF:-/etc/samba/smb.conf}"
  SMB_INC="${SHARE_MANAGER_SMB_INC:-/etc/samba/share-manager.conf}"
else
  EXPORTS_FILE="/etc/exports"
  SMB_CONF="/etc/samba/smb.conf"
  SMB_INC="/etc/samba/share-manager.conf"
fi

MARKER="SHARE-MANAGER"
SMB_LOADED=0
SNAP_DIR=""
SNAP_COUNT=0

parsed_path=""
parsed_clients=()
parsed_opts=()
share_numbers=()
share_texts=()
smb_names=()
smb_paths=()
smb_readonly=()
smb_hosts=()
smb_extra=()
host_items=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

umask 022
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none
export LANG="${LANG:-C.UTF-8}"

if [[ "${BASH_SOURCE[0]}" == "$0" && ${EUID} -ne 0 ]]; then
  exec sudo bash "$0" "$@" || exit 1
fi

pause() {
  echo
  read_reply "Нажмите Enter для продолжения..." || true
}

header() {
  clear 2>/dev/null || true
  echo -e "${CYAN}============================================================${NC}"
  echo -e "${BOLD}              SHARE MANAGER — Ubuntu${NC}"
  echo -e "${CYAN}         NFS для Linux, SMB для Windows${NC}"
  echo -e "${CYAN}============================================================${NC}"
  echo
}

read_reply() {
  local prompt="$1"
  REPLY=""
  if ! read -erp "$prompt" REPLY; then
    return 1
  fi
  REPLY="${REPLY//$'\r'/}"
}

confirm_default_yes() {
  read_reply "$1 [Y/n]: " || return 1
  case "${REPLY:-Y}" in
    y|Y|yes|YES|д|Д|да|Да|ДА|"") return 0 ;;
    *) return 1 ;;
  esac
}

confirm_default_no() {
  read_reply "$1 [y/N]: " || return 1
  case "$REPLY" in
    y|Y|yes|YES|д|Д|да|Да|ДА) return 0 ;;
    *) return 1 ;;
  esac
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s\n' "$s"
}

say_red() {
  printf '%b%s%b\n' "$RED" "$*" "$NC" >&2
}

say_green() {
  printf '%b%s%b\n' "$GREEN" "$*" "$NC"
}

say_yellow() {
  printf '%b%s%b\n' "$YELLOW" "$*" "$NC"
}

valid_ipv4() {
  local ip="$1" octet
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for octet in "${BASH_REMATCH[@]:1}"; do
    ((10#$octet <= 255)) || return 1
  done
}

validate_share_path() {
  local path="$1"
  if [[ -z "$path" ]]; then
    say_red "Путь не указан."
    return 1
  fi
  if [[ "$path" != /* ]]; then
    say_red "Нужен абсолютный путь, например /srv/share."
    return 1
  fi
  if [[ "$path" == *[[:space:]]* || "$path" == *"#"* || "$path" == *"("* || "$path" == *")"* || "$path" == *"\\"* || "$path" == *"\""* || "$path" == *"'"* ]]; then
    say_red "В пути нельзя использовать пробелы, кавычки, #, скобки и обратный слэш."
    return 1
  fi
  if [[ -e "$path" && ! -d "$path" ]]; then
    say_red "Это не папка: $path"
    return 1
  fi
  if [[ "$path" == "/" ]]; then
    say_yellow "Корень / открывает всю файловую систему."
    confirm_default_no "Всё равно использовать /?" || return 1
  fi
}

normalize_share_path() {
  local path="$1" resolved=""
  if [[ "$path" != "/" ]]; then
    path="${path%/}"
  fi
  if [[ -d "$path" ]] && command -v realpath >/dev/null 2>&1; then
    resolved=$(realpath -m -- "$path" 2>/dev/null || true)
    if [[ -n "$resolved" ]]; then
      printf '%s\n' "$resolved"
      return
    fi
  fi
  printf '%s\n' "$path"
}

validate_share_name() {
  local name="$1" lower
  if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
    say_red "Имя шары: латиница, цифры, точка, _ и -. До 64 символов, без пробелов."
    return 1
  fi
  lower="${name,,}"
  case "$lower" in
    global|printers|homes|ipc\$|print\$)
      say_red "Имя «${name}» зарезервировано Samba."
      return 1
      ;;
  esac
}

validate_client() {
  local client="$1" host prefix
  if [[ -z "$client" ]]; then
    say_red "IP или подсеть не указаны."
    return 1
  fi
  if [[ "$client" == "*" ]]; then
    return 0
  fi
  if [[ "$client" == *[[:space:]]* || "$client" == *"#"* || "$client" == *"("* || "$client" == *")"* || "$client" == *","* || "$client" == *"\\"* || "$client" == *"\""* || "$client" == *"'"* ]]; then
    say_red "В адресе клиента есть недопустимые символы."
    return 1
  fi
  if [[ "$client" == *:* && "$client" != "["* ]]; then
    say_red "IPv6 записывайте в квадратных скобках, например [2001:db8::1]."
    return 1
  fi
  if [[ "$client" =~ ^\[([0-9A-Fa-f:]+)\](/([0-9]{1,3}))?$ ]]; then
    if [[ -n "${BASH_REMATCH[3]}" && $((10#${BASH_REMATCH[3]})) -gt 128 ]]; then
      say_red "Префикс IPv6 больше 128."
      return 1
    fi
    return 0
  fi
  if [[ "$client" == */* ]]; then
    host="${client%%/*}"
    prefix="${client#*/}"
    if ! [[ "$prefix" =~ ^[0-9]+$ && $((10#$prefix)) -le 32 ]]; then
      say_red "Некорректный префикс сети."
      return 1
    fi
    if ! valid_ipv4 "$host"; then
      say_red "Некорректный IP."
      return 1
    fi
    return 0
  fi
  if [[ "$client" =~ ^[0-9.]+$ ]]; then
    if ! valid_ipv4 "$client"; then
      say_red "Некорректный IP."
      return 1
    fi
    return 0
  fi
  if ! [[ "$client" =~ ^[@*?A-Za-z0-9._-]+$ ]]; then
    say_red "Некорректное имя клиента."
    return 1
  fi
}

validate_smb_host() {
  local client="$1"
  if [[ "$client" == "*" || "${client,,}" == "all" ]]; then
    say_red "Звёздочка не нужна. Удалите все IP — шара откроется всей сети."
    return 1
  fi
  validate_client "$client"
}

validate_firewall_client() {
  local client="$1" host prefix
  if [[ "$client" == "*" || "$client" == *"*"* ]]; then
    say_red "Для UFW нужен IPv4, подсеть CIDR или имя без звёздочки."
    return 1
  fi
  if [[ "$client" == */* ]]; then
    host="${client%%/*}"
    prefix="${client#*/}"
    valid_ipv4 "$host" || {
      say_red "Для UFW нужна IPv4-подсеть, например 192.168.10.0/24."
      return 1
    }
    [[ "$prefix" =~ ^[0-9]+$ && $((10#$prefix)) -le 32 ]] || {
      say_red "Некорректный префикс сети."
      return 1
    }
    return 0
  fi
  if valid_ipv4 "$client"; then
    return 0
  fi
  if [[ "$client" =~ ^[A-Za-z0-9._-]+$ ]]; then
    return 0
  fi
  say_red "Для UFW нужен IPv4, подсеть CIDR или имя без звёздочки."
  return 1
}

anon_ids() {
  local uid gid
  uid=$(id -u nobody 2>/dev/null || true)
  gid=$(id -g nobody 2>/dev/null || true)
  [[ -n "$uid" ]] || uid=65534
  [[ -n "$gid" ]] || gid=65534
  printf '%s %s\n' "$uid" "$gid"
}

default_options() {
  local mode="$1" uid gid
  read -r uid gid < <(anon_ids)
  printf '%s,sync,no_subtree_check,all_squash,anonuid=%s,anongid=%s\n' "$mode" "$uid" "$gid"
}

access_mode_of() {
  local rest="$1" part mode="rw"
  while [[ -n "$rest" ]]; do
    part="${rest%%,*}"
    if [[ "$part" == "ro" || "$part" == "rw" ]]; then
      mode="$part"
    fi
    if [[ "$rest" == *,* ]]; then
      rest="${rest#*,}"
    else
      rest=""
    fi
  done
  printf '%s\n' "$mode"
}

mode_label() {
  case "$1" in
    rw) printf 'чтение и запись (rw)' ;;
    *) printf 'только чтение (ro)' ;;
  esac
}

set_access_mode() {
  local opts="$1" mode="$2" rest="$1" part item out
  local -a kept=()
  while [[ -n "$rest" ]]; do
    part="${rest%%,*}"
    if [[ -n "$part" && "$part" != "ro" && "$part" != "rw" ]]; then
      kept+=("$part")
    fi
    if [[ "$rest" == *,* ]]; then
      rest="${rest#*,}"
    else
      rest=""
    fi
  done
  out="$mode"
  for item in "${kept[@]}"; do
    out+=",$item"
  done
  printf '%s\n' "$out"
}

ask_mode() {
  local current="${1:-}" title="$2" answer
  echo "1) Только чтение (ro)" >&2
  echo "2) Чтение и запись (rw)" >&2
  if [[ -n "$current" ]]; then
    echo "Сейчас: $(mode_label "$current"). Enter оставляет этот режим." >&2
    read_reply "${title}: " || return 1
    answer="$REPLY"
    case "$answer" in
      "") printf '%s\n' "$current" ;;
      1) printf 'ro\n' ;;
      2) printf 'rw\n' ;;
      *)
        say_red "Неизвестный режим."
        return 1
        ;;
    esac
    return 0
  fi
  read_reply "${title} [1]: " || return 1
  answer="${REPLY:-1}"
  case "$answer" in
    1) printf 'ro\n' ;;
    2) printf 'rw\n' ;;
    *)
      say_red "Неизвестный режим."
      return 1
      ;;
  esac
}

server_ipv4() {
  local ip=""
  ip=$(hostname -I 2>/dev/null | awk 'NF { print $1; exit }') || ip=""
  if [[ -n "$ip" ]]; then
    printf '%s\n' "$ip"
    return 0
  fi
  return 1
}

unc_for() {
  local name="$1" ip=""
  ip=$(server_ipv4 || true)
  if [[ -n "$ip" ]]; then
    printf '\\\\%s\\%s\n' "$ip" "$name"
  else
    printf '\\\\IP-сервера\\%s\n' "$name"
  fi
}

split_share_line() {
  local line="$1" rest token
  parsed_path=""
  parsed_clients=()
  parsed_opts=()
  if [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]]; then
    return 1
  fi
  if ! [[ "$line" =~ ^([^[:space:]]+)[[:space:]]+(.+)$ ]]; then
    return 1
  fi
  parsed_path="${BASH_REMATCH[1]}"
  rest="${BASH_REMATCH[2]}"
  local -a tokens=()
  read -r -a tokens <<< "$rest"
  if [[ ${#tokens[@]} -eq 0 ]]; then
    return 1
  fi
  local token_re='^([^()]+)[(](.*)[)]$'
  for token in "${tokens[@]}"; do
    if ! [[ "$token" =~ $token_re ]]; then
      parsed_path=""
      parsed_clients=()
      parsed_opts=()
      return 1
    fi
    parsed_clients+=("${BASH_REMATCH[1]}")
    parsed_opts+=("${BASH_REMATCH[2]}")
  done
}

build_share_line() {
  local out="$parsed_path" index
  for index in "${!parsed_clients[@]}"; do
    out+=" ${parsed_clients[$index]}(${parsed_opts[$index]})"
  done
  printf '%s\n' "$out"
}

client_index() {
  local want="$1" index
  for index in "${!parsed_clients[@]}"; do
    if [[ "${parsed_clients[$index]}" == "$want" ]]; then
      printf '%s\n' "$index"
      return 0
    fi
  done
  return 1
}

pkg_installed() {
  local package="$1" status
  case "$package" in
    nfs-kernel-server)
      case "${SHARE_MANAGER_FORCE_NFS:-}" in
        installed) return 0 ;;
        missing) return 1 ;;
      esac
      ;;
    samba)
      case "${SHARE_MANAGER_FORCE_SMB:-}" in
        installed) return 0 ;;
        missing) return 1 ;;
      esac
      ;;
  esac
  status=$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)
  [[ "$status" == "install ok installed" ]]
}

nfs_installed() {
  pkg_installed nfs-kernel-server
}

smb_installed() {
  pkg_installed samba
}

ensure_exports_file() {
  if [[ -e "$EXPORTS_FILE" && ! -f "$EXPORTS_FILE" ]]; then
    say_red "$EXPORTS_FILE существует, но это не обычный файл."
    return 1
  fi
  if [[ ! -f "$EXPORTS_FILE" ]]; then
    install -m 644 /dev/null "$EXPORTS_FILE" 2>/dev/null || : > "$EXPORTS_FILE" || return 1
    chmod 644 "$EXPORTS_FILE" 2>/dev/null || true
  fi
}

# Временный снимок на время записи. Если применить конфиг не удалось,
# файл возвращается. Отдельные backup-копии и пункт меню не ведутся.
begin_snapshots() {
  drop_snapshots
  SNAP_DIR=$(mktemp -d) || return 1
  SNAP_COUNT=0
}

drop_snapshots() {
  if [[ -n "${SNAP_DIR:-}" && -d "$SNAP_DIR" ]]; then
    rm -rf -- "$SNAP_DIR"
  fi
  SNAP_DIR=""
  SNAP_COUNT=0
}

snap_file() {
  local target="$1" id
  [[ -n "$SNAP_DIR" ]] || return 1
  id="$SNAP_COUNT"
  printf '%s\n' "$target" > "${SNAP_DIR}/name_${id}" || return 1
  if [[ -e "$target" ]]; then
    cp -a -- "$target" "${SNAP_DIR}/data_${id}" || return 1
  else
    : > "${SNAP_DIR}/missing_${id}" || return 1
  fi
  SNAP_COUNT=$((SNAP_COUNT + 1))
}

rollback_snapshots() {
  local id target dir_name
  [[ -n "${SNAP_DIR:-}" && -d "$SNAP_DIR" ]] || return 1
  for ((id = 0; id < SNAP_COUNT; id++)); do
    target=$(cat "${SNAP_DIR}/name_${id}") || return 1
    if [[ -f "${SNAP_DIR}/missing_${id}" ]]; then
      rm -f -- "$target"
    else
      dir_name=$(dirname -- "$target")
      mkdir -p -- "$dir_name" || return 1
      cat -- "${SNAP_DIR}/data_${id}" > "$target" || return 1
    fi
  done
  drop_snapshots
}

load_shares() {
  share_numbers=()
  share_texts=()
  [[ -f "$EXPORTS_FILE" ]] || return 0
  local raw
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw="${raw//$'\r'/}"
    if [[ "$raw" =~ ^([0-9]+):(.*)$ ]]; then
      share_numbers+=("${BASH_REMATCH[1]}")
      share_texts+=("${BASH_REMATCH[2]}")
    fi
  done < <(grep -nEv '^[[:space:]]*(#|$)' "$EXPORTS_FILE" || true)
}

find_share_by_path() {
  local want="$1" index found="" saved_path="$parsed_path"
  local -a saved_clients=() saved_opts=()
  if ((${#parsed_clients[@]})); then
    saved_clients=("${parsed_clients[@]}")
    saved_opts=("${parsed_opts[@]}")
  fi
  load_shares
  for index in "${!share_texts[@]}"; do
    if split_share_line "${share_texts[$index]}" && [[ "$parsed_path" == "$want" ]]; then
      found="$index"
      break
    fi
  done
  parsed_path="$saved_path"
  parsed_clients=()
  parsed_opts=()
  if ((${#saved_clients[@]})); then
    parsed_clients=("${saved_clients[@]}")
    parsed_opts=("${saved_opts[@]}")
  fi
  if [[ -n "$found" ]]; then
    printf '%s\n' "$found"
    return 0
  fi
  return 1
}

read_file_line() {
  local number="$1" index=0 line
  while IFS= read -r line || [[ -n "$line" ]]; do
    index=$((index + 1))
    if [[ "$index" -eq "$number" ]]; then
      printf '%s\n' "$line"
      return 0
    fi
  done < "$EXPORTS_FILE"
  return 1
}

write_temp_over() {
  local tmp="$1" target="$2"
  cat -- "$tmp" > "$target"
}

replace_line_number() {
  local number="$1" replacement="$2" tmp index=0 line replaced=0
  tmp=$(mktemp) || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    index=$((index + 1))
    if [[ "$index" -eq "$number" ]]; then
      printf '%s\n' "$replacement"
      replaced=1
    else
      printf '%s\n' "$line"
    fi
  done < "$EXPORTS_FILE" > "$tmp" || {
    rm -f -- "$tmp"
    return 1
  }
  if [[ "$replaced" -ne 1 ]]; then
    rm -f -- "$tmp"
    say_red "Строка ${number} в ${EXPORTS_FILE} не найдена."
    return 1
  fi
  write_temp_over "$tmp" "$EXPORTS_FILE" || {
    rm -f -- "$tmp"
    return 1
  }
  rm -f -- "$tmp"
}

delete_line_number() {
  local number="$1" tmp index=0 line removed=0
  tmp=$(mktemp) || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    index=$((index + 1))
    if [[ "$index" -eq "$number" ]]; then
      removed=1
      continue
    fi
    printf '%s\n' "$line"
  done < "$EXPORTS_FILE" > "$tmp" || {
    rm -f -- "$tmp"
    return 1
  }
  if [[ "$removed" -ne 1 ]]; then
    rm -f -- "$tmp"
    say_red "Строка ${number} в ${EXPORTS_FILE} не найдена."
    return 1
  fi
  write_temp_over "$tmp" "$EXPORTS_FILE" || {
    rm -f -- "$tmp"
    return 1
  }
  rm -f -- "$tmp"
}

remove_orphan_markers() {
  local tmp
  [[ -f "$EXPORTS_FILE" ]] || return 0
  tmp=$(mktemp) || return 1
  awk -v marker="# $MARKER" '
    { lines[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (lines[i] == marker) {
          j = i + 1
          while (j <= NR && lines[j] ~ /^[[:space:]]*$/) j++
          if (j > NR || lines[j] ~ /^[[:space:]]*#/) continue
        }
        print lines[i]
      }
    }
  ' "$EXPORTS_FILE" > "$tmp" || {
    rm -f -- "$tmp"
    return 1
  }
  write_temp_over "$tmp" "$EXPORTS_FILE" || {
    rm -f -- "$tmp"
    return 1
  }
  rm -f -- "$tmp"
}

append_share_line() {
  local line="$1"
  if [[ -s "$EXPORTS_FILE" ]]; then
    printf '\n# %s\n%s\n' "$MARKER" "$line" >> "$EXPORTS_FILE"
  else
    printf '# %s\n%s\n' "$MARKER" "$line" >> "$EXPORTS_FILE"
  fi
}

nfs_reload() {
  if [[ "${SHARE_MANAGER_TEST_MODE:-}" == 1 ]]; then
    [[ "${SHARE_MANAGER_NFS_FAIL:-}" == 1 ]] && return 1
    return 0
  fi
  if ! nfs_installed || ! command -v exportfs >/dev/null 2>&1; then
    say_yellow "Сервер NFS не установлен: строка записана и пока не применена."
    return 0
  fi
  exportfs -ra || return 1
  if systemctl is-active --quiet nfs-kernel-server; then
    systemctl reload nfs-kernel-server 2>/dev/null || systemctl restart nfs-kernel-server || return 1
  else
    systemctl enable --now nfs-kernel-server || return 1
  fi
}

reapply_runtime() {
  if [[ "${SHARE_MANAGER_TEST_MODE:-}" == 1 ]]; then
    return 0
  fi
  if nfs_installed && command -v exportfs >/dev/null 2>&1; then
    if [[ -f "$EXPORTS_FILE" ]]; then
      exportfs -ra >/dev/null 2>&1 || say_red "Повторное применение NFS тоже завершилось ошибкой."
    else
      exportfs -ua >/dev/null 2>&1 || true
    fi
  fi
  if smb_installed && [[ -f "$SMB_CONF" ]]; then
    systemctl reload smbd >/dev/null 2>&1 || systemctl restart smbd >/dev/null 2>&1 || true
  fi
}

fail_nfs_apply() {
  say_red "Ошибка применения NFS."
  if rollback_snapshots; then
    say_yellow "Файлы возвращены к прежнему состоянию."
    reapply_runtime
  else
    say_red "Вернуть прежние файлы не удалось."
  fi
  return 1
}

commit_nfs_change() {
  if ! nfs_reload; then
    fail_nfs_apply
    return 1
  fi
  drop_snapshots
}

smb_name_taken() {
  local want="${1,,}" except="${2:-}" index name
  for index in "${!smb_names[@]}"; do
    name="${smb_names[$index],,}"
    [[ "$name" == "$want" ]] || continue
    if [[ -n "$except" && "$name" == "${except,,}" ]]; then
      continue
    fi
    return 0
  done
  return 1
}

smb_path_taken() {
  local want="$1" except_name="${2:-}" index
  for index in "${!smb_names[@]}"; do
    [[ "${smb_paths[$index]}" == "$want" ]] || continue
    if [[ -n "$except_name" && "${smb_names[$index]}" == "$except_name" ]]; then
      continue
    fi
    return 0
  done
  return 1
}

load_smb() {
  local line section="" key val idx=-1
  SMB_LOADED=0
  smb_names=()
  smb_paths=()
  smb_readonly=()
  smb_hosts=()
  smb_extra=()
  [[ -f "$SMB_INC" ]] || {
    SMB_LOADED=1
    return 0
  }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//$'\r'/}"
    if [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*[#\;] ]]; then
      continue
    fi
    if [[ "$line" =~ ^\[([^]]+)\][[:space:]]*$ ]]; then
      section="${BASH_REMATCH[1]}"
      smb_names+=("$section")
      smb_paths+=("")
      smb_readonly+=("yes")
      smb_hosts+=("")
      smb_extra+=("")
      idx=$((${#smb_names[@]} - 1))
      continue
    fi
    if [[ "$idx" -lt 0 ]]; then
      say_red "В ${SMB_INC} есть параметр вне шары."
      return 1
    fi
    if [[ ! "$line" =~ ^[[:space:]]*([^=]+)=[[:space:]]*(.*)$ ]]; then
      say_red "Не понял строку SMB: $line"
      return 1
    fi
    key=$(trim "${BASH_REMATCH[1]}")
    val=$(trim "${BASH_REMATCH[2]}")
    if [[ "$val" =~ ^\"(.*)\"$ ]]; then
      val="${BASH_REMATCH[1]}"
    fi
    case "$key" in
      path) smb_paths[$idx]="$val" ;;
      "read only")
        case "${val,,}" in
          no|false|0) smb_readonly[$idx]="no" ;;
          *) smb_readonly[$idx]="yes" ;;
        esac
        ;;
      writable)
        case "${val,,}" in
          yes|true|1) smb_readonly[$idx]="no" ;;
          no|false|0) smb_readonly[$idx]="yes" ;;
        esac
        ;;
      "hosts allow") smb_hosts[$idx]="$val" ;;
      browseable|"guest ok"|"guest only"|"force user"|"force group"|"create mask"|"directory mask")
        ;;
      *)
        if [[ -n "${smb_extra[$idx]}" ]]; then
          smb_extra[$idx]+=$'\n'
        fi
        smb_extra[$idx]+="   ${key} = ${val}"
        ;;
    esac
  done < "$SMB_INC"
  for idx in "${!smb_names[@]}"; do
    if [[ -z "${smb_paths[$idx]}" ]]; then
      say_red "У SMB-шары ${smb_names[$idx]} не указан path."
      return 1
    fi
  done
  SMB_LOADED=1
}

write_smb_file() {
  local tmp index extra dir_name
  [[ "$SMB_LOADED" == 1 ]] || {
    say_red "Список SMB-шар не прочитан, файл не перезаписан."
    return 1
  }
  tmp=$(mktemp) || return 1
  {
    printf '# %s\n' "$MARKER"
    printf '# Файл ведёт share-manager. Меню перезаписывает шары в этом файле.\n'
    for index in "${!smb_names[@]}"; do
      printf '\n[%s]\n' "${smb_names[$index]}"
      printf '   path = %s\n' "${smb_paths[$index]}"
      printf '   browseable = yes\n'
      printf '   guest ok = yes\n'
      printf '   guest only = yes\n'
      if [[ "${smb_readonly[$index]}" == "no" ]]; then
        printf '   read only = no\n'
        printf '   writable = yes\n'
      else
        printf '   read only = yes\n'
      fi
      printf '   force user = nobody\n'
      printf '   force group = nogroup\n'
      printf '   create mask = 0664\n'
      printf '   directory mask = 0775\n'
      if [[ -n "${smb_hosts[$index]}" ]]; then
        printf '   hosts allow = %s\n' "${smb_hosts[$index]}"
      fi
      extra="${smb_extra[$index]}"
      if [[ -n "$extra" ]]; then
        printf '%s\n' "$extra"
      fi
    done
    printf '\n'
  } > "$tmp" || {
    rm -f -- "$tmp"
    return 1
  }
  dir_name=$(dirname -- "$SMB_INC")
  mkdir -p -- "$dir_name" || {
    rm -f -- "$tmp"
    return 1
  }
  cat -- "$tmp" > "$SMB_INC" || {
    rm -f -- "$tmp"
    return 1
  }
  chmod 644 "$SMB_INC" 2>/dev/null || true
  rm -f -- "$tmp"
}

smb_global_exact() {
  local key="$1" value="$2" line found_key found_val
  [[ -f "$SMB_CONF" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*([^=]+)=[[:space:]]*(.*)$ ]] || continue
    found_key=$(trim "${BASH_REMATCH[1]}")
    found_val=$(trim "${BASH_REMATCH[2]}")
    if [[ "$found_key" == "$key" && "$found_val" == "$value" ]]; then
      return 0
    fi
  done < "$SMB_CONF"
  return 1
}

smb_global_present() {
  local key="$1" line found_key
  [[ -f "$SMB_CONF" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*([^=]+)=[[:space:]]*(.*)$ ]] || continue
    found_key=$(trim "${BASH_REMATCH[1]}")
    [[ "$found_key" == "$key" ]] && return 0
  done < "$SMB_CONF"
  return 1
}

set_smb_global() {
  local key="$1" value="$2" tmp
  [[ -f "$SMB_CONF" ]] || {
    say_red "Нет файла $SMB_CONF. Сначала установите Samba."
    return 1
  }
  if smb_global_exact "$key" "$value"; then
    return 0
  fi
  tmp=$(mktemp) || return 1
  if smb_global_present "$key"; then
    awk -v key="$key" -v value="$value" '
      BEGIN { pat = "^[[:space:]]*" key "[[:space:]]*=" }
      $0 ~ pat { print "   " key " = " value; next }
      { print }
    ' "$SMB_CONF" > "$tmp" || {
      rm -f -- "$tmp"
      return 1
    }
  else
    awk -v key="$key" -v value="$value" '
      { print }
      /^\[global\][[:space:]]*$/ && !done {
        print "   " key " = " value
        done = 1
      }
      END { if (!done) exit 2 }
    ' "$SMB_CONF" > "$tmp" || {
      rm -f -- "$tmp"
      say_red "В $SMB_CONF нет секции [global]."
      return 1
    }
  fi
  cat -- "$tmp" > "$SMB_CONF" || {
    rm -f -- "$tmp"
    return 1
  }
  rm -f -- "$tmp"
  if [[ "$key" == "obey pam restrictions" ]]; then
    say_yellow "Для входа Windows без пароля параметр obey pam restrictions установлен в no."
  fi
}

include_present() {
  local line val
  [[ -f "$SMB_CONF" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*include[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
    val=$(trim "${BASH_REMATCH[1]}")
    [[ "$val" == "$SMB_INC" ]] && return 0
  done < "$SMB_CONF"
  return 1
}

ensure_smb_include() {
  [[ -f "$SMB_CONF" ]] || return 1
  if include_present; then
    return 0
  fi
  printf '\n# %s\ninclude = %s\n' "$MARKER" "$SMB_INC" >> "$SMB_CONF"
}

prepare_smb_globals() {
  set_smb_global "map to guest" "Bad User" || return 1
  set_smb_global "obey pam restrictions" "no" || return 1
  if [[ -f "$SMB_INC" ]]; then
    ensure_smb_include || return 1
  fi
}

smb_reload() {
  local out
  if [[ "${SHARE_MANAGER_TEST_MODE:-}" == 1 ]]; then
    [[ "${SHARE_MANAGER_SMB_FAIL:-}" == 1 ]] && return 1
    return 0
  fi
  if ! smb_installed || ! command -v testparm >/dev/null 2>&1; then
    say_yellow "Samba не установлена: шара записана и пока не применена."
    return 0
  fi
  out=$(mktemp) || return 1
  if ! testparm -s "$SMB_CONF" >"$out" 2>&1; then
    say_red "Samba отклонила конфигурацию:"
    cat -- "$out"
    rm -f -- "$out"
    return 1
  fi
  rm -f -- "$out"
  if systemctl is-active --quiet smbd; then
    systemctl reload smbd 2>/dev/null || systemctl restart smbd || return 1
  else
    systemctl enable --now smbd || return 1
  fi
}

fail_smb_apply() {
  say_red "Ошибка применения SMB."
  if rollback_snapshots; then
    say_yellow "Файлы возвращены к прежнему состоянию."
    reapply_runtime
  else
    say_red "Вернуть прежние файлы не удалось."
  fi
  return 1
}

commit_smb_change() {
  if ! smb_reload; then
    fail_smb_apply
    return 1
  fi
  drop_snapshots
}

dir_writable_by_anon() {
  local path="$1" why="${2:-nfs}" uid gid owner group perm owner_bits group_bits other_bits
  read -r uid gid < <(anon_ids)
  owner=$(stat -c '%u' -- "$path") || return 1
  group=$(stat -c '%g' -- "$path") || return 1
  perm=$(stat -c '%a' -- "$path") || return 1
  perm=$((10#$perm))
  owner_bits=$(((perm / 100) % 10))
  group_bits=$(((perm / 10) % 10))
  other_bits=$((perm % 10))
  # NFS с all_squash пишет от nobody и видит бит владельца.
  # Samba для uid nobody бит владельца не применяет: нужен бит группы или «остальных».
  if [[ "$why" != "smb" && "$why" != "both" ]]; then
    if [[ "$owner" == "$uid" && $((owner_bits & 2)) -ne 0 ]]; then
      return 0
    fi
  fi
  if [[ "$group" == "$gid" && $((group_bits & 2)) -ne 0 ]]; then
    return 0
  fi
  if [[ $((other_bits & 2)) -ne 0 ]]; then
    return 0
  fi
  return 1
}

offer_anon_write() {
  local path="$1" why="${2:-nfs}" uid gid mode="755"
  if [[ "$why" == "smb" || "$why" == "both" ]]; then
    mode="775"
  fi
  if dir_writable_by_anon "$path" "$why"; then
    say_green "Папка уже доступна на запись пользователю nobody."
    return 0
  fi
  read -r uid gid < <(anon_ids)
  case "$why" in
    smb) say_yellow "SMB пишет от пользователя nobody (uid ${uid})." ;;
    both) say_yellow "NFS и SMB пишут от пользователя nobody (uid ${uid})." ;;
    *) say_yellow "NFS пишет от пользователя nobody (uid ${uid})." ;;
  esac
  if [[ "$mode" == "775" ]]; then
    echo "Режима 755 мало: Samba не применяет бит владельца к nobody и смотрит на группу nogroup."
    echo "Нужен режим 775, иначе клиент Windows не сможет записывать файлы."
  else
    echo "Запись идёт от пользователя nobody. Без смены владельца клиент не сможет создавать файлы."
  fi
  if confirm_default_yes "Сделать владельцем nobody и поставить chmod ${mode}?"; then
    chown "${uid}:${gid}" -- "$path" || {
      say_red "Не удалось сменить владельца."
      return 1
    }
    chmod "$mode" -- "$path" || {
      say_red "Не удалось сменить права."
      return 1
    }
    say_green "Права обновлены: владелец nobody, группа nogroup, режим ${mode}."
  else
    if [[ "$mode" == "775" ]]; then
      say_yellow "Запись с клиента не заработает, пока у группы nogroup нет права записи."
    else
      say_yellow "Запись с клиента не заработает, пока владельцем папки не станет nobody."
    fi
  fi
}

prepare_directory() {
  local path="$1"
  if [[ -d "$path" ]]; then
    return 0
  fi
  if confirm_default_no "Папки нет. Создать папку?"; then
    mkdir -p -- "$path" || {
      say_red "Не удалось создать папку."
      return 1
    }
    say_green "Папка создана."
  else
    say_yellow "Папка не создана."
    return 1
  fi
}

show_service_status() {
  if ! nfs_installed; then
    echo -e "NFS сервер: ${YELLOW}НЕ УСТАНОВЛЕН${NC}"
  elif systemctl is-active --quiet nfs-kernel-server; then
    echo -e "NFS сервер: ${GREEN}РАБОТАЕТ${NC}"
  else
    echo -e "NFS сервер: ${RED}НЕ РАБОТАЕТ${NC}"
  fi
  if ! smb_installed; then
    echo -e "SMB сервер: ${YELLOW}НЕ УСТАНОВЛЕН${NC}"
  elif systemctl is-active --quiet smbd; then
    printf '%bSMB сервер: РАБОТАЕТ%b (Windows: \\\\IP\\имя-шары)\n' "$GREEN" "$NC"
  else
    echo -e "SMB сервер: ${RED}НЕ РАБОТАЕТ${NC}"
  fi
}

print_share_human() {
  local line="$1" index mode
  if ! split_share_line "$line"; then
    printf '%s\n' "$line"
    return
  fi
  echo -e "${BOLD}${parsed_path}${NC}"
  for index in "${!parsed_clients[@]}"; do
    mode=$(access_mode_of "${parsed_opts[$index]}")
    echo "    ${parsed_clients[$index]} — $(mode_label "$mode")"
  done
}

print_smb_clients() {
  local hosts="$1" item count
  hosts_to_array "$hosts"
  if [[ ${#host_items[@]} -eq 0 ]]; then
    echo "    клиенты: вся сеть"
    return
  fi
  echo "    клиенты:"
  count=1
  for item in "${host_items[@]}"; do
    echo "      ${count}) ${item}"
    count=$((count + 1))
  done
}

hosts_to_array() {
  local raw="$1"
  host_items=()
  [[ -n "$raw" ]] || return 0
  read -r -a host_items <<< "$raw"
}

print_smb_human() {
  local index="$1" mode
  if [[ "${smb_readonly[$index]}" == "no" ]]; then
    mode="rw"
  else
    mode="ro"
  fi
  echo -e "${BOLD}${smb_names[$index]}${NC}"
  echo "    путь: ${smb_paths[$index]}"
  echo "    доступ: $(mode_label "$mode")"
  print_smb_clients "${smb_hosts[$index]}"
  printf '    с Windows: %s\n' "$(unc_for "${smb_names[$index]}")"
}

show_shares() {
  local index line
  header
  echo -e "${BOLD}NFS-шары (Linux):${NC}"
  echo
  load_shares
  if [[ ${#share_texts[@]} -eq 0 ]]; then
    say_yellow "NFS-шар нет."
  else
    for index in "${!share_texts[@]}"; do
      line="${share_texts[$index]}"
      echo -e "${GREEN}[$((index + 1))]${NC}"
      print_share_human "$line"
      echo
    done
  fi
  echo -e "${BOLD}SMB-шары (Windows):${NC}"
  echo
  if ! load_smb; then
    say_red "Файл SMB-шар не разобран."
  elif [[ ${#smb_names[@]} -eq 0 ]]; then
    say_yellow "SMB-шар нет."
  else
    for index in "${!smb_names[@]}"; do
      echo -e "${GREEN}[$((index + 1))]${NC}"
      print_smb_human "$index"
      echo
    done
  fi
  echo -e "${BOLD}Активные экспорты NFS:${NC}"
  echo
  if command -v exportfs >/dev/null 2>&1 && nfs_installed; then
    exportfs -v 2>/dev/null || true
  else
    say_yellow "exportfs недоступен."
  fi
  echo
  show_service_status
  pause
}

install_packages() {
  local -a pkgs=("$@")
  local pkg
  ((${#pkgs[@]})) || return 0
  echo "Ставлю пакеты: ${pkgs[*]}"
  echo "Это может занять несколько минут."
  if command -v debconf-set-selections >/dev/null 2>&1; then
    printf '%s\n' \
      'samba-common samba-common/workgroup string WORKGROUP' \
      'samba-common samba-common/dhcp boolean false' \
      'samba-common samba-common/do_debconf boolean true' \
      | debconf-set-selections || true
  fi
  apt-get update || {
    say_red "apt-get update не выполнен."
    return 1
  }
  apt-get install -y \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    "${pkgs[@]}" || {
    say_red "Установка не удалась."
    return 1
  }
  hash -r
  for pkg in "${pkgs[@]}"; do
    case "$pkg" in
      nfs-kernel-server)
        nfs_installed || {
          say_red "Пакет nfs-kernel-server не установился."
          return 1
        }
        systemctl enable --now nfs-kernel-server || {
          say_red "Не удалось запустить NFS."
          return 1
        }
        ;;
      samba)
        smb_installed || {
          say_red "Пакет samba не установился."
          return 1
        }
        systemctl enable --now smbd || {
          say_red "Не удалось запустить smbd."
          return 1
        }
        ;;
    esac
  done
  say_green "Пакеты установлены."
}

ensure_packages_for() {
  local do_nfs="$1" do_smb="$2"
  local -a pkgs=()
  if [[ "$do_nfs" == 1 ]] && ! nfs_installed; then
    pkgs+=(nfs-kernel-server)
  fi
  if [[ "$do_smb" == 1 ]] && ! smb_installed; then
    pkgs+=(samba)
  fi
  if [[ ${#pkgs[@]} -eq 0 ]]; then
    return 0
  fi
  echo "Для выбранного доступа нужны пакеты: ${pkgs[*]}"
  confirm_default_yes "Установить пакеты?" || return 1
  install_packages "${pkgs[@]}"
}

pick_nfs_share() {
  local index choice number
  load_shares
  if [[ ${#share_texts[@]} -eq 0 ]]; then
    say_yellow "NFS-шар нет."
    pause
    return 1
  fi
  echo "NFS-шары:"
  for index in "${!share_texts[@]}"; do
    echo "$((index + 1)))"
    print_share_human "${share_texts[$index]}"
  done
  echo "0) Отмена"
  read_reply "Номер шары: " || return 1
  choice="$REPLY"
  if [[ "$choice" == "0" ]]; then
    return 1
  fi
  if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
    say_red "Нужен номер из списка."
    pause
    return 1
  fi
  number=$((10#$choice))
  if [[ "$number" -lt 1 || "$number" -gt ${#share_texts[@]} ]]; then
    say_red "Нет пункта ${choice}."
    pause
    return 1
  fi
  PICK_OFFSET=$((number - 1))
  PICK_LINE="${share_numbers[$PICK_OFFSET]}"
  PICK_TEXT="${share_texts[$PICK_OFFSET]}"
}

pick_smb_share() {
  local index choice number
  load_smb || {
    pause
    return 1
  }
  if [[ ${#smb_names[@]} -eq 0 ]]; then
    say_yellow "SMB-шар нет."
    pause
    return 1
  fi
  echo "SMB-шары:"
  for index in "${!smb_names[@]}"; do
    echo "$((index + 1)))"
    print_smb_human "$index"
  done
  echo "0) Отмена"
  read_reply "Номер шары: " || return 1
  choice="$REPLY"
  if [[ "$choice" == "0" ]]; then
    return 1
  fi
  if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
    say_red "Нужен номер из списка."
    pause
    return 1
  fi
  number=$((10#$choice))
  if [[ "$number" -lt 1 || "$number" -gt ${#smb_names[@]} ]]; then
    say_red "Нет пункта ${choice}."
    pause
    return 1
  fi
  SMB_PICK="${smb_names[$((number - 1))]}"
}

ask_directory() {
  local entered
  read_reply "Путь к папке: " || return 1
  entered="$REPLY"
  validate_share_path "$entered" || return 1
  entered=$(normalize_share_path "$entered")
  prepare_directory "$entered" || return 1
  entered=$(normalize_share_path "$entered")
  SHARE_PATH="$entered"
}

add_share() {
  local proto do_nfs=0 do_smb=0 nfs_client="" nfs_mode="" smb_name="" smb_mode="" smb_host=""
  local why="nfs" options line restrict="no"
  header
  echo "Куда открыть доступ?"
  echo "1) NFS — для Linux"
  echo "2) SMB — для Windows"
  echo "3) NFS и SMB"
  echo "0) Отмена"
  read_reply "Протокол: " || return
  proto="$REPLY"
  case "$proto" in
    0) return ;;
    1) do_nfs=1 ;;
    2) do_smb=1 ;;
    3) do_nfs=1; do_smb=1 ;;
    *)
      say_red "Неизвестный пункт."
      pause
      return
      ;;
  esac
  ensure_packages_for "$do_nfs" "$do_smb" || {
    pause
    return
  }
  ask_directory || {
    pause
    return
  }
  if [[ "$do_nfs" == 1 ]] && find_share_by_path "$SHARE_PATH" >/dev/null; then
    say_red "Эта папка уже есть в NFS. Добавьте IP через пункт «Изменить шару»."
    pause
    return
  fi
  if [[ "$do_smb" == 1 ]]; then
    load_smb || {
      pause
      return
    }
    if smb_path_taken "$SHARE_PATH"; then
      say_red "Эта папка уже есть в SMB. Измените её через пункт «Изменить шару»."
      pause
      return
    fi
  fi
  ls -ld -- "$SHARE_PATH"
  if [[ "$do_nfs" == 1 ]]; then
    echo
    echo "Клиент NFS — это IP, подсеть (192.168.10.0/24) или *. Звезда открывает шару всем."
    read_reply "IP или подсеть NFS: " || return
    nfs_client="$REPLY"
    validate_client "$nfs_client" || {
      pause
      return
    }
    nfs_mode=$(ask_mode "" "Режим NFS") || {
      pause
      return
    }
  fi
  if [[ "$do_smb" == 1 ]]; then
    echo
    echo "Имя SMB видно в Windows в адресе \\\\IP\\имя."
    read_reply "Имя SMB-шары: " || return
    smb_name="$REPLY"
    validate_share_name "$smb_name" || {
      pause
      return
    }
    if smb_name_taken "$smb_name"; then
      say_red "Шара с таким именем уже есть."
      pause
      return
    fi
    smb_mode=$(ask_mode "" "Режим SMB") || {
      pause
      return
    }
    echo "Без ограничения шара открыта всей сети, пароль Windows не спрашивает."
    if confirm_default_no "Ограничить SMB по IP?"; then
      restrict="yes"
      read_reply "IP или подсеть SMB: " || return
      smb_host="$REPLY"
      validate_smb_host "$smb_host" || {
        pause
        return
      }
    fi
  fi
  if [[ "$do_nfs" == 1 && "$do_smb" == 1 ]]; then
    why="both"
  elif [[ "$do_smb" == 1 ]]; then
    why="smb"
  else
    why="nfs"
  fi
  if [[ "$nfs_mode" == "rw" || "$smb_mode" == "rw" ]]; then
    offer_anon_write "$SHARE_PATH" "$why" || {
      pause
      return
    }
  elif confirm_default_no "Поставить chmod 755?"; then
    chmod 755 -- "$SHARE_PATH" || {
      say_red "Не удалось сменить права."
      pause
      return
    }
  fi
  echo
  echo "Будет записано:"
  if [[ "$do_nfs" == 1 ]]; then
    options=$(default_options "$nfs_mode")
    echo "  NFS: ${SHARE_PATH} ${nfs_client}(${options})"
  fi
  if [[ "$do_smb" == 1 ]]; then
    echo "  SMB: ${smb_name}"
    echo "       путь: ${SHARE_PATH}"
    echo "       доступ: $(mode_label "$smb_mode")"
    if [[ "$restrict" == "yes" ]]; then
      echo "       клиенты: ${smb_host}"
    else
      echo "       клиенты: вся сеть"
    fi
    printf '       с Windows: %s\n' "$(unc_for "$smb_name")"
  fi
  echo
  confirm_default_yes "Записать шару?" || return
  begin_snapshots || {
    pause
    return
  }
  if [[ "$do_nfs" == 1 ]]; then
    snap_file "$EXPORTS_FILE" || {
      drop_snapshots
      pause
      return
    }
    ensure_exports_file || {
      rollback_snapshots || true
      pause
      return
    }
    options=$(default_options "$nfs_mode")
    parsed_path="$SHARE_PATH"
    parsed_clients=("$nfs_client")
    parsed_opts=("$options")
    line=$(build_share_line)
    append_share_line "$line" || {
      say_red "Не удалось записать $EXPORTS_FILE."
      rollback_snapshots || true
      pause
      return
    }
  fi
  if [[ "$do_smb" == 1 ]]; then
    snap_file "$SMB_CONF" || {
      rollback_snapshots || say_red "Откат не удался."
      pause
      return
    }
    snap_file "$SMB_INC" || {
      rollback_snapshots || say_red "Откат не удался."
      pause
      return
    }
    if [[ "$SMB_LOADED" != 1 ]]; then
      load_smb || {
        rollback_snapshots || true
        pause
        return
      }
    fi
    smb_names+=("$smb_name")
    smb_paths+=("$SHARE_PATH")
    if [[ "$smb_mode" == "rw" ]]; then
      smb_readonly+=("no")
    else
      smb_readonly+=("yes")
    fi
    if [[ "$restrict" == "yes" ]]; then
      smb_hosts+=("$smb_host")
    else
      smb_hosts+=("")
    fi
    smb_extra+=("")
    write_smb_file || {
      say_red "Не удалось записать $SMB_INC."
      rollback_snapshots || true
      pause
      return
    }
    prepare_smb_globals || {
      rollback_snapshots || true
      pause
      return
    }
  fi
  if [[ "$do_nfs" == 1 ]]; then
    if ! nfs_reload; then
      fail_nfs_apply || true
      pause
      return
    fi
  fi
  if [[ "$do_smb" == 1 ]]; then
    if ! smb_reload; then
      fail_smb_apply || true
      pause
      return
    fi
  fi
  drop_snapshots
  if [[ "$do_nfs" == 1 && "$do_smb" == 1 ]]; then
    say_green "NFS-шара и SMB-шара записаны."
  elif [[ "$do_nfs" == 1 ]]; then
    say_green "NFS-шара записана."
  else
    say_green "SMB-шара записана."
  fi
  pause
}

delete_nfs_share() {
  pick_nfs_share || return
  echo
  echo "Будет удалена NFS-шара целиком, со всеми клиентами:"
  print_share_human "$PICK_TEXT"
  echo
  confirm_default_no "Удалить эту шару?" || return
  begin_snapshots || {
    pause
    return
  }
  snap_file "$EXPORTS_FILE" || {
    drop_snapshots
    pause
    return
  }
  delete_line_number "$PICK_LINE" || {
    rollback_snapshots || true
    pause
    return
  }
  remove_orphan_markers || {
    rollback_snapshots || true
    pause
    return
  }
  commit_nfs_change || {
    pause
    return
  }
  say_green "NFS-шара удалена."
  pause
}

delete_smb_share() {
  local index name new_names=() new_paths=() new_ro=() new_hosts=() new_extra=() cursor
  pick_smb_share || return
  index=$(smb_index_of "$SMB_PICK") || {
    say_red "Шара не найдена."
    pause
    return
  }
  name="${smb_names[$index]}"
  echo
  echo "Будет удалена SMB-шара:"
  print_smb_human "$index"
  echo
  confirm_default_no "Удалить эту шару?" || return
  for cursor in "${!smb_names[@]}"; do
    if [[ "$cursor" -eq "$index" ]]; then
      continue
    fi
    new_names+=("${smb_names[$cursor]}")
    new_paths+=("${smb_paths[$cursor]}")
    new_ro+=("${smb_readonly[$cursor]}")
    new_hosts+=("${smb_hosts[$cursor]}")
    new_extra+=("${smb_extra[$cursor]}")
  done
  smb_names=()
  smb_paths=()
  smb_readonly=()
  smb_hosts=()
  smb_extra=()
  if ((${#new_names[@]})); then
    smb_names=("${new_names[@]}")
    smb_paths=("${new_paths[@]}")
    smb_readonly=("${new_ro[@]}")
    smb_hosts=("${new_hosts[@]}")
    smb_extra=("${new_extra[@]}")
  fi
  begin_snapshots || {
    pause
    return
  }
  snap_file "$SMB_CONF" || {
    drop_snapshots
    pause
    return
  }
  snap_file "$SMB_INC" || {
    drop_snapshots
    pause
    return
  }
  write_smb_file || {
    rollback_snapshots || true
    pause
    return
  }
  prepare_smb_globals || {
    rollback_snapshots || true
    pause
    return
  }
  commit_smb_change || {
    pause
    return
  }
  say_green "SMB-шара ${name} удалена."
  pause
}

smb_index_of() {
  local want="$1" index
  for index in "${!smb_names[@]}"; do
    if [[ "${smb_names[$index]}" == "$want" ]]; then
      printf '%s\n' "$index"
      return 0
    fi
  done
  return 1
}

delete_share() {
  local section
  header
  echo "Что удалить?"
  echo "1) NFS-шару"
  echo "2) SMB-шару"
  echo "0) Отмена"
  read_reply "Что удалить: " || return
  section="$REPLY"
  case "$section" in
    1) delete_nfs_share ;;
    2) delete_smb_share ;;
    0) return ;;
    *)
      say_red "Неизвестный пункт."
      pause
      ;;
  esac
}

print_nfs_editor() {
  local index mode
  header
  echo -e "${BOLD}Изменение NFS-шары${NC}"
  echo
  echo "Путь: ${parsed_path}"
  echo
  echo "Клиенты этой шары:"
  for index in "${!parsed_clients[@]}"; do
    mode=$(access_mode_of "${parsed_opts[$index]}")
    echo "  $((index + 1))) ${parsed_clients[$index]}"
    echo "     доступ: $(mode_label "$mode")"
    echo "     опции: ${parsed_opts[$index]}"
  done
  echo
  echo "Строка в ${EXPORTS_FILE}:"
  build_share_line
  echo
  echo "1) Добавить IP или подсеть"
  echo "2) Удалить IP или подсеть"
  echo "3) Заменить IP или подсеть"
  echo "4) Сменить режим ro/rw у клиента"
  echo "5) Сменить путь к папке"
  echo "0) Назад"
  echo
  echo "Удаление всей шары — пункт 3 главного меню."
}

print_smb_editor() {
  local index mode
  index=$(smb_index_of "$SMB_PICK") || return 1
  if [[ "${smb_readonly[$index]}" == "no" ]]; then
    mode="rw"
  else
    mode="ro"
  fi
  header
  echo -e "${BOLD}Изменение SMB-шары${NC}"
  echo
  print_smb_human "$index"
  echo
  echo "1) Добавить IP или подсеть"
  echo "2) Удалить IP или подсеть"
  echo "3) Заменить IP или подсеть"
  echo "4) Сменить режим ro/rw"
  echo "5) Сменить путь к папке"
  echo "6) Сменить имя шары"
  echo "0) Назад"
  echo
  echo "Если клиентов нет, шара открыта всей сети."
  echo "Удаление всей шары — пункт 3 главного меню."
}

pick_client_index() {
  local choice number index
  if [[ ${#parsed_clients[@]} -eq 1 ]]; then
    printf '0\n'
    return 0
  fi
  echo "Клиенты:" >&2
  for index in "${!parsed_clients[@]}"; do
    echo "  $((index + 1))) ${parsed_clients[$index]}" >&2
  done
  echo "  0) Отмена" >&2
  read_reply "Номер клиента: " || return 1
  choice="$REPLY"
  if [[ "$choice" == "0" ]]; then
    return 3
  fi
  if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
    say_red "Нужен номер из списка."
    return 1
  fi
  number=$((10#$choice))
  if [[ "$number" -lt 1 || "$number" -gt ${#parsed_clients[@]} ]]; then
    say_red "Нет клиента ${choice}."
    return 1
  fi
  printf '%s\n' "$((number - 1))"
}

save_nfs_parsed() {
  local line
  line=$(build_share_line)
  begin_snapshots || return 1
  snap_file "$EXPORTS_FILE" || {
    drop_snapshots
    return 1
  }
  replace_line_number "$PICK_LINE" "$line" || {
    say_red "Не удалось записать $EXPORTS_FILE."
    rollback_snapshots || true
    return 1
  }
  commit_nfs_change
}

editor_nfs_add() {
  local client mode options
  read_reply "Новый IP или подсеть: " || return 1
  client="$REPLY"
  validate_client "$client" || return 1
  if client_index "$client" >/dev/null; then
    say_red "Такой клиент в этой шаре уже есть."
    return 1
  fi
  mode=$(ask_mode "" "Режим NFS") || return 1
  echo "Будет добавлен ${client} — $(mode_label "$mode")"
  confirm_default_yes "Добавить этого клиента?" || return 3
  if [[ "$mode" == "rw" ]]; then
    offer_anon_write "$parsed_path" nfs || return 1
  fi
  options=$(default_options "$mode")
  parsed_clients+=("$client")
  parsed_opts+=("$options")
  save_nfs_parsed
}

editor_nfs_remove() {
  local index=0 choice_index new_clients=() new_opts=() cursor
  choice_index=$(pick_client_index) || return $?
  index=$((10#$choice_index))
  echo "Будет удалён клиент ${parsed_clients[$index]} из ${parsed_path}."
  if [[ ${#parsed_clients[@]} -eq 1 ]]; then
    say_yellow "Это последний клиент. NFS-шара исчезнет из экспорта."
  fi
  confirm_default_no "Удалить этого клиента?" || return 3
  if [[ ${#parsed_clients[@]} -eq 1 ]]; then
    begin_snapshots || return 1
    snap_file "$EXPORTS_FILE" || {
      drop_snapshots
      return 1
    }
    delete_line_number "$PICK_LINE" || {
      rollback_snapshots || true
      return 1
    }
    remove_orphan_markers || {
      rollback_snapshots || true
      return 1
    }
    commit_nfs_change || return 1
    say_green "Клиент удалён, NFS-шара снята."
    return 2
  fi
  for cursor in "${!parsed_clients[@]}"; do
    if [[ "$cursor" -eq "$index" ]]; then
      continue
    fi
    new_clients+=("${parsed_clients[$cursor]}")
    new_opts+=("${parsed_opts[$cursor]}")
  done
  parsed_clients=("${new_clients[@]}")
  parsed_opts=("${new_opts[@]}")
  save_nfs_parsed
}

editor_nfs_replace() {
  local index client
  index=$(pick_client_index) || return $?
  index=$((10#$index))
  read_reply "IP или подсеть на замену: " || return 1
  client="$REPLY"
  [[ -n "$client" ]] || client="${parsed_clients[$index]}"
  validate_client "$client" || return 1
  if [[ "$client" != "${parsed_clients[$index]}" ]] && client_index "$client" >/dev/null; then
    say_red "Такой клиент в этой шаре уже есть."
    return 1
  fi
  echo "Клиент ${parsed_clients[$index]} будет заменён на ${client}. Режим и опции сохранятся."
  confirm_default_no "Заменить клиента?" || return 3
  parsed_clients[$index]="$client"
  save_nfs_parsed
}

editor_nfs_mode() {
  local index current new_mode
  index=$(pick_client_index) || return $?
  index=$((10#$index))
  current=$(access_mode_of "${parsed_opts[$index]}")
  echo "Клиент: ${parsed_clients[$index]}"
  new_mode=$(ask_mode "$current" "Новый режим NFS") || return 1
  parsed_opts[$index]=$(set_access_mode "${parsed_opts[$index]}" "$new_mode")
  echo "Новые опции: ${parsed_opts[$index]}"
  confirm_default_no "Сохранить режим NFS?" || return 3
  if [[ "$new_mode" == "rw" ]]; then
    offer_anon_write "$parsed_path" nfs || return 1
  fi
  save_nfs_parsed
}

editor_nfs_path() {
  local new_path index mode
  read_reply "Новый путь: " || return 1
  new_path="$REPLY"
  [[ -n "$new_path" ]] || new_path="$parsed_path"
  validate_share_path "$new_path" || return 1
  new_path=$(normalize_share_path "$new_path")
  prepare_directory "$new_path" || return 1
  new_path=$(normalize_share_path "$new_path")
  if [[ "$new_path" != "$parsed_path" ]] && find_share_by_path "$new_path" >/dev/null; then
    say_red "Такая папка уже экспортируется другой строкой NFS."
    return 1
  fi
  echo "Путь ${parsed_path} будет заменён на ${new_path}. Клиенты сохранятся."
  confirm_default_no "Сохранить путь NFS?" || return 3
  for index in "${!parsed_opts[@]}"; do
    mode=$(access_mode_of "${parsed_opts[$index]}")
    if [[ "$mode" == "rw" ]]; then
      offer_anon_write "$new_path" nfs || return 1
      break
    fi
  done
  parsed_path="$new_path"
  save_nfs_parsed
}

edit_nfs_share() {
  local action result line
  pick_nfs_share || return
  while true; do
    line=$(read_file_line "$PICK_LINE") || {
      say_yellow "NFS-шара уже удалена."
      pause
      return
    }
    if ! split_share_line "$line"; then
      say_yellow "Эту строку скрипт не разбирает. Её можно удалить целиком пунктом 3."
      printf '%s\n' "$line"
      pause
      return
    fi
    print_nfs_editor
    read_reply "Действие с NFS: " || return
    action="$REPLY"
    result=0
    case "$action" in
      1) editor_nfs_add || result=$? ;;
      2) editor_nfs_remove || result=$? ;;
      3) editor_nfs_replace || result=$? ;;
      4) editor_nfs_mode || result=$? ;;
      5) editor_nfs_path || result=$? ;;
      0) return ;;
      *)
        say_red "Неизвестный пункт."
        result=1
        ;;
    esac
    if [[ "$result" -eq 2 ]]; then
      pause
      return
    fi
    if [[ "$result" -eq 0 && "$action" =~ ^[1-5]$ ]]; then
      say_green "Изменение NFS сохранено."
      pause
    elif [[ "$result" -eq 1 ]]; then
      pause
    fi
  done
}

save_smb_current() {
  begin_snapshots || return 1
  snap_file "$SMB_CONF" || {
    drop_snapshots
    return 1
  }
  snap_file "$SMB_INC" || {
    drop_snapshots
    return 1
  }
  write_smb_file || {
    say_red "Не удалось записать $SMB_INC."
    rollback_snapshots || true
    return 1
  }
  prepare_smb_globals || {
    rollback_snapshots || true
    return 1
  }
  commit_smb_change
}

pick_smb_host_index() {
  local choice number index
  hosts_to_array "${smb_hosts[$1]}"
  if [[ ${#host_items[@]} -eq 0 ]]; then
    say_yellow "Список IP пуст: шара открыта всей сети."
    return 1
  fi
  if [[ ${#host_items[@]} -eq 1 ]]; then
    printf '0\n'
    return 0
  fi
  echo "Клиенты SMB:" >&2
  for index in "${!host_items[@]}"; do
    echo "  $((index + 1))) ${host_items[$index]}" >&2
  done
  echo "  0) Отмена" >&2
  read_reply "Номер клиента: " || return 1
  choice="$REPLY"
  if [[ "$choice" == "0" ]]; then
    return 3
  fi
  if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
    say_red "Нужен номер из списка."
    return 1
  fi
  number=$((10#$choice))
  if [[ "$number" -lt 1 || "$number" -gt ${#host_items[@]} ]]; then
    say_red "Нет клиента ${choice}."
    return 1
  fi
  printf '%s\n' "$((number - 1))"
}

smb_host_exists() {
  local want="$1" item
  hosts_to_array "$2"
  for item in "${host_items[@]}"; do
    [[ "$item" == "$want" ]] && return 0
  done
  return 1
}

editor_smb_add() {
  local index client hosts
  index=$(smb_index_of "$SMB_PICK") || return 1
  read_reply "Новый IP или подсеть: " || return 1
  client="$REPLY"
  validate_smb_host "$client" || return 1
  if smb_host_exists "$client" "${smb_hosts[$index]}"; then
    say_red "Такой адрес в этой шаре уже есть."
    return 1
  fi
  hosts="${smb_hosts[$index]}"
  if [[ -z "$hosts" ]]; then
    say_yellow "Сейчас шара открыта всей сети. После добавления останется только ${client}."
    confirm_default_no "Ограничить доступ этим IP?" || return 3
    smb_hosts[$index]="$client"
  else
    echo "Будет добавлен ${client}."
    confirm_default_yes "Добавить этот IP в SMB?" || return 3
    smb_hosts[$index]="${hosts} ${client}"
  fi
  save_smb_current
}

editor_smb_remove() {
  local index choice last="no" kept="" item cursor
  index=$(smb_index_of "$SMB_PICK") || return 1
  hosts_to_array "${smb_hosts[$index]}"
  if [[ ${#host_items[@]} -eq 0 ]]; then
    say_yellow "Шара и так открыта всей сети. Чтобы ограничить доступ, добавьте IP."
    return 1
  fi
  choice=$(pick_smb_host_index "$index") || return $?
  choice=$((10#$choice))
  if [[ ${#host_items[@]} -eq 1 ]]; then
    last="yes"
    echo "Это последний IP (${host_items[$choice]})."
    echo "1) Удалить IP и открыть шару всей сети"
    echo "2) Оставить как есть"
    read_reply "Что сделать с последним IP: " || return 1
    case "$REPLY" in
      1) ;;
      *) return 3 ;;
    esac
  else
    echo "Будет удалён ${host_items[$choice]}."
    confirm_default_no "Удалить этот IP из SMB?" || return 3
  fi
  if [[ "$last" == "yes" ]]; then
    smb_hosts[$index]=""
  else
    for cursor in "${!host_items[@]}"; do
      if [[ "$cursor" -eq "$choice" ]]; then
        continue
      fi
      item="${host_items[$cursor]}"
      if [[ -n "$kept" ]]; then
        kept+=" "
      fi
      kept+="$item"
    done
    smb_hosts[$index]="$kept"
  fi
  save_smb_current
}

editor_smb_replace() {
  local index choice client kept="" item cursor old
  index=$(smb_index_of "$SMB_PICK") || return 1
  hosts_to_array "${smb_hosts[$index]}"
  if [[ ${#host_items[@]} -eq 0 ]]; then
    say_yellow "Шара открыта всей сети. Сначала добавьте IP, если нужно ограничение."
    return 1
  fi
  choice=$(pick_smb_host_index "$index") || return $?
  choice=$((10#$choice))
  old="${host_items[$choice]}"
  read_reply "IP или подсеть на замену: " || return 1
  client="$REPLY"
  [[ -n "$client" ]] || client="$old"
  validate_smb_host "$client" || return 1
  if [[ "$client" != "$old" ]] && smb_host_exists "$client" "${smb_hosts[$index]}"; then
    say_red "Такой адрес в этой шаре уже есть."
    return 1
  fi
  echo "Адрес ${old} будет заменён на ${client}."
  confirm_default_no "Заменить этот IP в SMB?" || return 3
  for cursor in "${!host_items[@]}"; do
    if [[ "$cursor" -eq "$choice" ]]; then
      item="$client"
    else
      item="${host_items[$cursor]}"
    fi
    if [[ -n "$kept" ]]; then
      kept+=" "
    fi
    kept+="$item"
  done
  smb_hosts[$index]="$kept"
  save_smb_current
}

editor_smb_mode() {
  local index current new_mode
  index=$(smb_index_of "$SMB_PICK") || return 1
  if [[ "${smb_readonly[$index]}" == "no" ]]; then
    current="rw"
  else
    current="ro"
  fi
  new_mode=$(ask_mode "$current" "Новый режим SMB") || return 1
  echo "Новый доступ: $(mode_label "$new_mode")"
  confirm_default_no "Сохранить режим SMB?" || return 3
  if [[ "$new_mode" == "rw" ]]; then
    offer_anon_write "${smb_paths[$index]}" smb || return 1
    smb_readonly[$index]="no"
  else
    smb_readonly[$index]="yes"
  fi
  save_smb_current
}

editor_smb_path() {
  local index new_path mode
  index=$(smb_index_of "$SMB_PICK") || return 1
  read_reply "Новый путь: " || return 1
  new_path="$REPLY"
  [[ -n "$new_path" ]] || new_path="${smb_paths[$index]}"
  validate_share_path "$new_path" || return 1
  new_path=$(normalize_share_path "$new_path")
  prepare_directory "$new_path" || return 1
  new_path=$(normalize_share_path "$new_path")
  if [[ "$new_path" != "${smb_paths[$index]}" ]] && smb_path_taken "$new_path" "$SMB_PICK"; then
    say_red "Такая папка уже отдана другой SMB-шарой."
    return 1
  fi
  echo "Путь ${smb_paths[$index]} будет заменён на ${new_path}."
  confirm_default_no "Сохранить путь SMB?" || return 3
  if [[ "${smb_readonly[$index]}" == "no" ]]; then
    mode="rw"
  else
    mode="ro"
  fi
  if [[ "$mode" == "rw" ]]; then
    offer_anon_write "$new_path" smb || return 1
  fi
  smb_paths[$index]="$new_path"
  save_smb_current
}

editor_smb_name() {
  local index new_name
  index=$(smb_index_of "$SMB_PICK") || return 1
  read_reply "Новое имя SMB-шары: " || return 1
  new_name="$REPLY"
  [[ -n "$new_name" ]] || new_name="${smb_names[$index]}"
  validate_share_name "$new_name" || return 1
  if [[ "${new_name,,}" != "${smb_names[$index],,}" ]] && smb_name_taken "$new_name" "$SMB_PICK"; then
    say_red "Шара с таким именем уже есть."
    return 1
  fi
  echo "Имя ${smb_names[$index]} будет заменено на ${new_name}."
  printf 'Новый адрес Windows: %s\n' "$(unc_for "$new_name")"
  confirm_default_no "Сохранить имя?" || return 3
  smb_names[$index]="$new_name"
  if save_smb_current; then
    SMB_PICK="$new_name"
    return 0
  fi
  return 1
}

edit_smb_share() {
  local action result
  pick_smb_share || return
  while true; do
    load_smb || {
      pause
      return
    }
    if ! smb_index_of "$SMB_PICK" >/dev/null; then
      say_yellow "SMB-шара уже удалена."
      pause
      return
    fi
    print_smb_editor || {
      pause
      return
    }
    read_reply "Действие с SMB: " || return
    action="$REPLY"
    result=0
    case "$action" in
      1) editor_smb_add || result=$? ;;
      2) editor_smb_remove || result=$? ;;
      3) editor_smb_replace || result=$? ;;
      4) editor_smb_mode || result=$? ;;
      5) editor_smb_path || result=$? ;;
      6) editor_smb_name || result=$? ;;
      0) return ;;
      *)
        say_red "Неизвестный пункт."
        result=1
        ;;
    esac
    if [[ "$result" -eq 0 && "$action" =~ ^[1-6]$ ]]; then
      say_green "Изменение SMB сохранено."
      pause
    elif [[ "$result" -eq 1 ]]; then
      pause
    fi
  done
}

edit_share() {
  local section
  header
  echo "Что изменить?"
  echo "1) NFS-шару: клиенты, режим, путь"
  echo "2) SMB-шару: клиенты, режим, путь, имя для Windows"
  echo "0) Отмена"
  read_reply "Что изменить: " || return
  section="$REPLY"
  case "$section" in
    1) edit_nfs_share ;;
    2) edit_smb_share ;;
    0) return ;;
    *)
      say_red "Неизвестный пункт."
      pause
      ;;
  esac
}

check_config() {
  header
  show_service_status
  echo
  if [[ -f "$EXPORTS_FILE" ]]; then
    echo -e "${BOLD}Файл ${EXPORTS_FILE}:${NC}"
    cat -n -- "$EXPORTS_FILE"
  else
    say_yellow "${EXPORTS_FILE} пока нет."
  fi
  echo
  if nfs_installed && command -v exportfs >/dev/null 2>&1; then
    echo "Проверка NFS заново применяет экспорт (exportfs -ra)."
    echo
    exportfs -v 2>/dev/null || true
    echo
    if exportfs -ra; then
      say_green "Конфигурация NFS корректна."
    else
      say_red "Ошибка конфигурации NFS."
    fi
  else
    say_yellow "NFS не установлен, экспорт не проверялся."
  fi
  echo
  if [[ -f "$SMB_INC" ]]; then
    echo -e "${BOLD}Файл ${SMB_INC}:${NC}"
    cat -n -- "$SMB_INC"
  else
    say_yellow "Файла SMB-шар пока нет."
  fi
  echo
  if smb_installed && command -v testparm >/dev/null 2>&1 && [[ -f "$SMB_CONF" ]]; then
    echo "Проверка SMB читает конфигурацию (testparm) и не перезапускает службу."
    echo
    if testparm -s "$SMB_CONF"; then
      say_green "Конфигурация SMB корректна."
    else
      say_red "Ошибка конфигурации SMB."
    fi
  else
    say_yellow "Samba не установлена, SMB не проверялся."
  fi
  pause
}

start_if_stopped() {
  local unit="$1" title="$2" prompt="$3"
  if systemctl is-active --quiet "$unit"; then
    say_green "${title} уже работает."
    return 0
  fi
  confirm_default_yes "$prompt" || return 0
  if systemctl enable --now "$unit"; then
    say_green "${title} запущен."
  else
    say_red "Не удалось запустить ${title}."
    return 1
  fi
}

install_menu() {
  local choice
  local -a missing=()
  local start_nfs=0 start_smb=0
  header
  show_service_status
  echo
  echo "1) NFS"
  echo "2) SMB (Samba, для Windows)"
  echo "3) Обе службы"
  echo "0) Назад"
  read_reply "Какую службу: " || return
  choice="$REPLY"
  case "$choice" in
    0) return ;;
    1|2|3) ;;
    *)
      say_red "Неизвестный пункт."
      pause
      return
      ;;
  esac
  if [[ "$choice" == "1" || "$choice" == "3" ]]; then
    if nfs_installed; then
      start_nfs=1
    else
      missing+=(nfs-kernel-server)
    fi
  fi
  if [[ "$choice" == "2" || "$choice" == "3" ]]; then
    if smb_installed; then
      start_smb=1
    else
      missing+=(samba)
    fi
  fi
  if ((${#missing[@]})); then
    echo "Будут установлены: ${missing[*]}"
    if confirm_default_yes "Установить пакеты?"; then
      install_packages "${missing[@]}" || true
    else
      say_yellow "Установка отменена."
    fi
  fi
  if [[ "$start_nfs" == 1 ]]; then
    start_if_stopped nfs-kernel-server "NFS" "Запустить NFS?" || true
  fi
  if [[ "$start_smb" == 1 ]]; then
    start_if_stopped smbd "SMB" "Запустить SMB?" || true
  fi
  echo
  show_service_status
  pause
}

open_ufw_port() {
  local client="$1" port="$2" proto="$3"
  if ufw allow from "$client" to any port "$port" proto "$proto"; then
    say_green "Открыто: ${port}/${proto} для ${client}"
    return 0
  fi
  say_red "Не удалось открыть ${port}/${proto}."
  return 1
}

configure_firewall() {
  local client kind rc=0 opened=0 spec port proto
  local -a specs=()
  header
  if ! command -v ufw >/dev/null 2>&1; then
    say_yellow "UFW не установлен."
    pause
    return
  fi
  if ufw status 2>/dev/null | grep -q 'Status: inactive'; then
    say_yellow "UFW сейчас выключен. Правило запишется и заработает после включения UFW."
    echo
  fi
  echo "Какой доступ открыть?"
  echo "1) NFS — порты 2049 и 111"
  echo "2) SMB — порт 445 (Windows)"
  echo "3) NFS и SMB"
  echo "0) Отмена"
  read_reply "Какой доступ открыть: " || return
  kind="$REPLY"
  case "$kind" in
    0) return ;;
    1) specs=(2049/tcp 2049/udp 111/tcp 111/udp) ;;
    2) specs=(445/tcp) ;;
    3) specs=(2049/tcp 2049/udp 111/tcp 111/udp 445/tcp) ;;
    *)
      say_red "Неизвестный пункт."
      pause
      return
      ;;
  esac
  read_reply "IP или подсеть для UFW: " || return
  client="$REPLY"
  if [[ -z "$client" ]]; then
    return
  fi
  validate_firewall_client "$client" || {
    pause
    return
  }
  echo "Будут открыты порты для ${client}:"
  for spec in "${specs[@]}"; do
    echo "  ${spec}"
  done
  confirm_default_no "Добавить правила UFW?" || return
  for spec in "${specs[@]}"; do
    port="${spec%/*}"
    proto="${spec#*/}"
    if open_ufw_port "$client" "$port" "$proto"; then
      opened=$((opened + 1))
    else
      rc=1
    fi
  done
  if [[ "$rc" -ne 0 ]]; then
    say_red "Часть правил не добавлена."
  elif [[ "$opened" -eq ${#specs[@]} ]]; then
    say_green "Правила UFW добавлены."
  fi
  pause
}

clear_exports_file() {
  if [[ -e "$EXPORTS_FILE" && ! -f "$EXPORTS_FILE" ]]; then
    say_red "$EXPORTS_FILE не обычный файл, не очищаю."
    return 1
  fi
  if [[ -f "$EXPORTS_FILE" ]]; then
    : > "$EXPORTS_FILE" || return 1
  fi
}

strip_smb_include() {
  local tmp
  [[ -f "$SMB_CONF" ]] || return 0
  tmp=$(mktemp) || return 1
  awk -v inc="$SMB_INC" -v marker="# $MARKER" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    {
      if ($0 == marker) next
      line = trim($0)
      if (line ~ /^include[[:space:]]*=/) {
        val = line
        sub(/^include[[:space:]]*=[[:space:]]*/, "", val)
        val = trim(val)
        if (val == inc) next
      }
      print
    }
  ' "$SMB_CONF" > "$tmp" || {
    rm -f -- "$tmp"
    return 1
  }
  cat -- "$tmp" > "$SMB_CONF" || {
    rm -f -- "$tmp"
    return 1
  }
  rm -f -- "$tmp"
}

remove_selected_servers() {
  local -a pkgs=()
  if [[ "$REMOVE_NFS" == 1 ]] && nfs_installed; then
    pkgs+=(nfs-kernel-server)
  fi
  if [[ "$REMOVE_SMB" == 1 ]] && smb_installed; then
    pkgs+=(samba)
  fi
  if [[ "$REMOVE_NFS" == 1 ]] && nfs_installed; then
    if command -v exportfs >/dev/null 2>&1; then
      exportfs -ua || true
    fi
    systemctl disable --now nfs-kernel-server || true
  fi
  if [[ "$REMOVE_SMB" == 1 ]] && smb_installed; then
    systemctl disable --now smbd nmbd || true
  fi
  if ((${#pkgs[@]})); then
    apt-get remove -y \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold \
      "${pkgs[@]}" || {
      say_red "Не удалось удалить пакеты: ${pkgs[*]}"
      return 1
    }
    hash -r
  fi
  if [[ "$REMOVE_NFS" == 1 && "$CLEAR_NFS" == 1 ]]; then
    clear_exports_file || say_red "Пакет NFS снят, но очистить ${EXPORTS_FILE} не удалось."
  fi
  if [[ "$REMOVE_SMB" == 1 && "$CLEAR_SMB" == 1 ]]; then
    strip_smb_include || say_red "Не удалось убрать include из ${SMB_CONF}."
    rm -f -- "$SMB_INC" || say_red "Не удалось удалить ${SMB_INC}."
  fi
  if [[ "$REMOVE_NFS" == 1 ]]; then
    if nfs_installed; then
      say_red "Пакет nfs-kernel-server всё ещё установлен."
    else
      say_green "NFS-сервер удалён."
    fi
  fi
  if [[ "$REMOVE_SMB" == 1 ]]; then
    if smb_installed; then
      say_red "Пакет samba всё ещё установлен."
    else
      say_green "SMB-сервер удалён."
    fi
  fi
}

ask_clear_choice() {
  local title="$1" prompt="$2"
  echo "$title" >&2
  echo "1) Оставить настройки" >&2
  echo "2) Очистить настройки" >&2
  echo "0) Отмена" >&2
  read_reply "$prompt" || return 1
  case "$REPLY" in
    0) return 1 ;;
    1) printf 'keep\n' ;;
    2) printf 'clear\n' ;;
    *)
      say_red "Неизвестный пункт."
      return 1
      ;;
  esac
}

remove_server() {
  local choice nfs_choice smb_choice
  header
  echo "Удаляется пакет службы. Настройки можно оставить или очистить."
  echo
  echo "1) NFS-сервер"
  echo "2) SMB-сервер (Samba)"
  echo "3) Оба"
  echo "0) Отмена"
  read_reply "Какой сервер удалить: " || return
  choice="$REPLY"
  REMOVE_NFS=0
  REMOVE_SMB=0
  CLEAR_NFS=0
  CLEAR_SMB=0
  case "$choice" in
    0) return ;;
    1) REMOVE_NFS=1 ;;
    2) REMOVE_SMB=1 ;;
    3) REMOVE_NFS=1; REMOVE_SMB=1 ;;
    *)
      say_red "Неизвестный пункт."
      pause
      return
      ;;
  esac
  if [[ "$REMOVE_NFS" == 1 ]] && ! nfs_installed && [[ ! -f "$EXPORTS_FILE" ]]; then
    say_yellow "NFS-сервер не установлен, файл экспорта не найден."
    REMOVE_NFS=0
  fi
  if [[ "$REMOVE_SMB" == 1 ]] && ! smb_installed && [[ ! -f "$SMB_INC" ]]; then
    say_yellow "SMB-сервер не установлен, файл шар не найден."
    REMOVE_SMB=0
  fi
  if [[ "$REMOVE_NFS" == 0 && "$REMOVE_SMB" == 0 ]]; then
    pause
    return
  fi
  if [[ "$REMOVE_NFS" == 1 ]]; then
    if ! nfs_installed; then
      say_yellow "Пакета NFS нет. Можно только очистить ${EXPORTS_FILE}."
    fi
    nfs_choice=$(ask_clear_choice "Настройки NFS (${EXPORTS_FILE}):" "Настройки NFS: ") || {
      pause
      return
    }
    [[ "$nfs_choice" == "clear" ]] && CLEAR_NFS=1
  fi
  if [[ "$REMOVE_SMB" == 1 ]]; then
    if ! smb_installed; then
      say_yellow "Пакета Samba нет. Можно только очистить шары share-manager."
    fi
    smb_choice=$(ask_clear_choice "Настройки SMB (${SMB_INC}):" "Настройки SMB: ") || {
      pause
      return
    }
    [[ "$smb_choice" == "clear" ]] && CLEAR_SMB=1
  fi
  echo
  echo "Будет выполнено:"
  if [[ "$REMOVE_NFS" == 1 ]]; then
    if [[ "$CLEAR_NFS" == 1 ]]; then
      echo "  NFS: удалить пакет и очистить экспорт"
    else
      echo "  NFS: удалить пакет, файл экспорта оставить"
    fi
  fi
  if [[ "$REMOVE_SMB" == 1 ]]; then
    if [[ "$CLEAR_SMB" == 1 ]]; then
      echo "  SMB: удалить пакет и очистить шары share-manager"
    else
      echo "  SMB: удалить пакет, шары оставить"
    fi
  fi
  confirm_default_no "Удалить выбранное?" || return
  remove_selected_servers || true
  echo
  show_service_status
  pause
}

main() {
  local choice
  while true; do
    header
    show_service_status
    echo
    echo "1) Показать шары"
    echo "2) Добавить шару (NFS, SMB или оба)"
    echo "3) Удалить шару"
    echo "4) Изменить шару: IP, режим, путь, имя Windows"
    echo "5) Проверить конфигурацию"
    echo "6) Установить или запустить серверы"
    echo "7) Разрешить клиент в UFW"
    echo "8) Удалить сервер"
    echo "0) Выход"
    echo
    read_reply "Пункт меню: " || {
      echo
      exit 0
    }
    choice="$REPLY"
    case "$choice" in
      1) show_shares ;;
      2) add_share ;;
      3) delete_share ;;
      4) edit_share ;;
      5) check_config ;;
      6) install_menu ;;
      7) configure_firewall ;;
      8) remove_server ;;
      0) exit 0 ;;
      *)
        say_red "Неизвестный пункт."
        pause
        ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
fi
