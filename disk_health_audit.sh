#!/usr/bin/env bash
# Приклад запуску:
#   sudo bash disk_health_audit.sh short
#
# Що робить цей файл:
#   - автоматично знаходить усі диски у системі;
#   - перевіряє/встановлює базові залежності для Debian/Ubuntu;
#   - не дає запускати кілька копій сценарію одночасно;
#   - чекає завершення вже запущеного SMART self-test на тому ж диску;
#   - запускає SMART short або long self-test;
#   - формує 2 підсумки:
#       1) короткий звіт для власника сервера;
#       2) розширений технічний звіт для детального аналізу;
#   - зберігає окрему папку на кожен запуск із датою та "latest";
#   - опційно відправляє короткий звіт і summary_user.txt у Telegram.
#
# Важливо:
#   - SMART self-test безпечний для даних, але long test може навантажувати HDD.
#   - Скрипт НЕ запускає badblocks автоматично, щоб не ризикувати системним диском.
#   - Для систем за межами Debian/Ubuntu auto-install залежностей може не спрацювати.
#
# Залежить від:
#   - bash, lsblk, findmnt, smartctl, awk, grep, sed, flock, date, dmesg, journalctl(опційно), curl(для Telegram)
#
# 🔍 Audit & recommendations
#   - Найцінніші лічильники: Reallocated, Pending, Offline_Uncorrectable, UDMA_CRC.
#   - Якщо UDMA_CRC росте, а секторні помилки нульові — під підозрою кабель/порт.
#   - Якщо ростуть Pending/Offline_Uncorrectable/Reallocated — під підозрою вже сам диск.
#
# ✅ Актуальність
#   - Підходить для регулярного контролю SATA/SAS/NVMe дисків у Debian/Ubuntu.
#
# 📦 Пропозиція
#   - Використовувати через cron/systemd timer:
#       short: щодня або раз на 2-3 дні
#       long : 1 раз на тиждень / 2 тижні

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
VERSION="1.1.0"

# ============================================================
# PATHS / PROJECT STRUCTURE
# ------------------------------------------------------------
# Тут зібрані всі головні шляхи проекту.
# Якщо в майбутньому треба буде перенести проект в іншу
# директорію, достатньо змінити цей блок, а не шукати шляхи
# по всьому скрипту.
# ============================================================

PROJECT_ROOT="${PROJECT_ROOT:-/opt/forprint-utils/disk-health-audit}"
CONFIG_DIR="${CONFIG_DIR:-$PROJECT_ROOT/config}"

# ============================================================
# OPTIONAL EXTERNAL CONFIG
# ------------------------------------------------------------
# Якщо існує зовнішній env-файл проекту, підвантажуємо його.
# Це дозволяє не редагувати сам скрипт при зміні налаштувань.
# ============================================================

ENV_FILE="${ENV_FILE:-$CONFIG_DIR/disk-health-audit.env}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

UTILS_DIR="${UTILS_DIR:-$PROJECT_ROOT/utils}"
DOCS_DIR="${DOCS_DIR:-$PROJECT_ROOT/docs}"
SYSTEMD_DIR="${SYSTEMD_DIR:-$PROJECT_ROOT/systemd}"

LOGS_DIR="${LOGS_DIR:-$PROJECT_ROOT/logs}"
RUNS_DIR="${RUNS_DIR:-$LOGS_DIR/runs}"
LATEST_LINK="${LATEST_LINK:-$LOGS_DIR/latest}"

# Lock-файл краще лишати в системному runtime-каталозі.
LOCK_FILE="${LOCK_FILE:-/run/lock/disk_health_audit.lock}"

# Назва компактного state-файлу з підсумком по дисках.
STATE_FILE_NAME="${STATE_FILE_NAME:-disk_state.tsv}"

# ============================================================
# GENERAL RUNTIME SETTINGS
# ------------------------------------------------------------
# Це основні робочі параметри запуску.
# Вони не стосуються Telegram і не стосуються шляхів.
# ============================================================

MODE="short"
NO_FILES="no"
WAIT_FOR_ACTIVE="yes"
WAIT_FOR_COMPLETION="yes"
POLL_SEC="${POLL_SEC:-60}"
STAGGER_SEC="${STAGGER_SEC:-5}"
AUTO_INSTALL="${AUTO_INSTALL:-yes}"
ONLY_DISKS=()
SKIP_SYSTEM_DISK="no"
MAX_WAIT_MINUTES="${MAX_WAIT_MINUTES:-0}"   # 0 = без ліміту

# Параметри retry для старту self-test.
# Скрипт має бути самодостатнім: якщо ці змінні не задані в env,
# використовуються дефолти нижче.
SELFTEST_START_RETRIES="${SELFTEST_START_RETRIES:-3}"
SELFTEST_START_RETRY_DELAY="${SELFTEST_START_RETRY_DELAY:-5}"

# Асоціативні масиви для фіксації, чи стартував self-test по кожному диску
# і якщо ні — чому саме.
declare -A SELFTEST_START_STATUS=()
declare -A SELFTEST_START_REASON=()

# ============================================================
# TELEGRAM SETTINGS
# ------------------------------------------------------------
# У цьому блоці зібрані всі параметри Telegram-сповіщень.
# Їх спеціально винесено окремо, щоб було візуально видно,
# де саме редагується інтеграція з Telegram.
# Якщо TELEGRAM_ENABLED=no, решта параметрів ігноруються.
# ============================================================

TELEGRAM_ENABLED="${TELEGRAM_ENABLED:-no}"
TELEGRAM_SEND_DOCUMENT="${TELEGRAM_SEND_DOCUMENT:-yes}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
TELEGRAM_API_URL="${TELEGRAM_API_URL:-https://api.telegram.org}"
TELEGRAM_DISABLE_NOTIFICATION="${TELEGRAM_DISABLE_NOTIFICATION:-true}"

# ============================================================
# RUNTIME VARIABLES
# ------------------------------------------------------------
# Це внутрішні службові змінні поточного запуску.
# Вони формуються автоматично і зазвичай не редагуються вручну.
# ============================================================

RUN_TS="$(date +%F_%H-%M-%S)"
RUN_DIR=""

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2
}

stage() {
  local title="$1"
  log "========== $title =========="
}

progress() {
  local phase="$1"
  local current="$2"
  local total="$3"
  local disk="$4"

  log "[$phase $current/$total] $disk | $(get_model "$disk") | SN=$(get_serial "$disk")"
}

die() {
  log "ERROR: $*"
  exit 1
}

usage() {
  cat <<'EOF'
Використання:
  sudo bash disk_health_audit.sh [probe|short|long|collect|install] [опції]

Режими:
  probe                Нічого не створювати і не запускати self-test; лише прочитати стан диска у stdout
  install              Встановити залежності і вийти
  collect              Не запускати self-test, лише зібрати звіт
  short                Запустити short SMART self-test, дочекатися завершення і зібрати звіт
  long                 Запустити long SMART self-test, дочекатися завершення і зібрати звіт

Опції:
  --poll-sec N         Інтервал опитування активного тесту, сек. За замовчуванням 60
  --stagger-sec N      Пауза між стартом тестів на різних дисках, сек. За замовчуванням 5
  --no-wait            Не чекати завершення вже активного тесту і не чекати новий тест до кінця
  --no-wait-completion Після старту тесту не чекати його завершення; зібрати лише поточний стан
  --disk /dev/sdX      Тестувати лише конкретний диск. Опцію можна повторювати
  --skip-system-disk   Пропустити диск, з якого змонтовано /
  --no-auto-install    Не встановлювати залежності автоматично
  --telegram           Увімкнути відправку короткого звіту в Telegram
  --no-telegram        Вимкнути відправку в Telegram
  --max-wait-min N     Максимум хвилин очікування активного тесту. 0 = без ліміту
  -h, --help           Довідка

Приклади:
	sudo bash disk_health_audit.sh install
	sudo bash disk_health_audit.sh collect --disk /dev/sda
	sudo bash disk_health_audit.sh short --disk /dev/sda
	sudo bash disk_health_audit.sh long --disk /dev/sda --poll-sec 120
	sudo TELEGRAM_ENABLED=yes TELEGRAM_BOT_TOKEN=xxx TELEGRAM_CHAT_ID=123 bash disk_health_audit.sh short
EOF
}

# ------------------------------------------------------------
# Повертає повний рядок статусу виконання self-test з smartctl -c.
# Наприклад:
#   Self-test execution status:      (   0) The previous self-test routine completed
# ------------------------------------------------------------

get_selftest_execution_line() {
  local disk="$1"
  { smartctl -c "$disk" 2>/dev/null || true; } | \
    awk '/Self-test execution status:/ {print; exit}'
}

# ------------------------------------------------------------
# Визначає, чи self-test реально активний.
# Логіка:
#   - якщо в рядку є "in progress" -> тест активний
#   - якщо в рядку є "completed", "no self-test has ever been run",
#     "aborted" або код ( 0 ) -> тест НЕ активний
# ------------------------------------------------------------
is_selftest_active() {
  local disk="$1"
  local line
  line="$(get_selftest_execution_line "$disk")"

  [[ -z "$line" ]] && return 1

  if echo "$line" | grep -qi "in progress"; then
    return 0
  fi

  if echo "$line" | grep -qiE "completed|aborted|no self-test has ever been run|\( *0\)"; then
    return 1
  fi

  return 1
}

ensure_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Скрипт треба запускати від root."
}

acquire_lock() {
  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    die "Інша копія $SCRIPT_NAME вже працює. Lock: $LOCK_FILE"
  fi
}

parse_args() {
  local arg
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      probe|short|long|collect|install)
        MODE="$1"
        shift
        ;;
      --poll-sec)
        POLL_SEC="$2"
        shift 2
        ;;
      --stagger-sec)
        STAGGER_SEC="$2"
        shift 2
        ;;
      --disk)
        ONLY_DISKS+=("$2")
        shift 2
        ;;
      --skip-system-disk)
        SKIP_SYSTEM_DISK="yes"
        shift
        ;;
      --no-wait)
        WAIT_FOR_ACTIVE="no"
        WAIT_FOR_COMPLETION="no"
        shift
        ;;
      --no-wait-completion)
        WAIT_FOR_COMPLETION="no"
        shift
        ;;
      --no-auto-install)
        AUTO_INSTALL="no"
        shift
        ;;
      --telegram)
        TELEGRAM_ENABLED="yes"
        shift
        ;;
      --no-telegram)
        TELEGRAM_ENABLED="no"
        shift
        ;;
      --max-wait-min|--max-wait-minutes)
        MAX_WAIT_MINUTES="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Невідома опція: $1"
        ;;
    esac
  done
}

install_dependencies() {
  local missing=()
  local deps=(smartctl lsblk findmnt awk grep sed flock date dmesg curl)
  local dep
  for dep in "${deps[@]}"; do
    command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
  done

  # flock зазвичай приходить з util-linux; smartctl зі smartmontools.
  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi

  [[ "$AUTO_INSTALL" == "yes" ]] || die "Бракує залежностей: ${missing[*]}. Дозвіл на auto-install вимкнено."

  if command -v apt-get >/dev/null 2>&1; then
    log "Встановлюю залежності через apt..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y smartmontools util-linux gawk grep sed coreutils findutils procps curl
  else
    die "Не знайшла apt-get. Встанови вручну: smartmontools util-linux gawk grep sed coreutils"
  fi
}

# ------------------------------------------------------------
# Створює структуру звітів для поточного запуску.
# Що робить:
#   - гарантує існування LOGS_DIR і RUNS_DIR;
#   - створює окрему папку поточного запуску;
#   - оновлює симлінк latest на останній запуск.
# ------------------------------------------------------------
init_report_dir() {
  mkdir -p "$LOGS_DIR" "$RUNS_DIR"
  RUN_DIR="$RUNS_DIR/$RUN_TS"
  mkdir -p "$RUN_DIR"
  ln -sfn "$RUN_DIR" "$LATEST_LINK"
}

cleanup_old_runs() {
  local cleanup_enabled retention_days old_dir

  cleanup_enabled="${RUNS_CLEANUP_ENABLED:-yes}"
  retention_days="${RUNS_RETENTION_DAYS:-180}"

  [[ "$cleanup_enabled" == "yes" ]] || return 0

  if ! [[ "$retention_days" =~ ^[0-9]+$ ]]; then
    log "Очистка старих звітів пропущена: RUNS_RETENTION_DAYS має бути числом."
    return 0
  fi

  find "$RUNS_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$retention_days" -print0 2>/dev/null |
    while IFS= read -r -d '' old_dir; do
      [[ "$old_dir" == "$RUN_DIR" ]] && continue
      log "Видаляю старий каталог звітів: $old_dir"
      rm -rf -- "$old_dir"
    done
}

root_source() {
  findmnt -n -o SOURCE / 2>/dev/null || true
}

parent_disk_of() {
  local src="$1"
  local pk
  if [[ -z "$src" ]]; then
    return 0
  fi
  if [[ "$src" == /dev/* ]]; then
    pk="$(lsblk -no PKNAME "$src" 2>/dev/null || true)"
    if [[ -n "$pk" ]]; then
      printf '/dev/%s\n' "$pk"
      return 0
    fi
    printf '%s\n' "$src"
    return 0
  fi
}

discover_disks() {
  local disks=()
  local disk

  # Безпечний режим адаптації під FreeBSD:
  # у probe не робимо автопошук, лише явно задані диски.
  if [[ "$MODE" == "probe" ]]; then
    [[ ${#ONLY_DISKS[@]} -gt 0 ]] || die "Для режиму probe вкажи диск явно: --disk /dev/ada0"

    for disk in "${ONLY_DISKS[@]}"; do
      [[ -c "$disk" || -b "$disk" ]] || die "Диск не знайдено: $disk"
      disks+=("$disk")
    done

    printf '%s\n' "${disks[@]}"
    return 0
  fi

  # Стара Linux-логіка поки лишається без змін для collect/short/long
  if [[ ${#ONLY_DISKS[@]} -gt 0 ]]; then
    for disk in "${ONLY_DISKS[@]}"; do
      [[ -b "$disk" ]] || die "Диск не знайдено або це не block device: $disk"
      disks+=("$disk")
    done
  else
    while read -r disk; do
      [[ -n "$disk" ]] && disks+=("$disk")
    done < <(lsblk -dn -o PATH,TYPE | awk '$2=="disk"{print $1}')
  fi

  local sys_disk=""
  sys_disk="$(parent_disk_of "$(root_source)")"

  if [[ "$SKIP_SYSTEM_DISK" == "yes" && -n "$sys_disk" ]]; then
    local filtered=()
    for disk in "${disks[@]}"; do
      [[ "$disk" == "$sys_disk" ]] && continue
      filtered+=("$disk")
    done
    disks=("${filtered[@]}")
  fi

  [[ ${#disks[@]} -gt 0 ]] || die "Не знайдено жодного диска для обробки."
  printf '%s\n' "${disks[@]}"
}

# smart_info_file() {
#   local disk="$1"
#   local out="$RUN_DIR/$(basename "$disk")_smart_info.txt"
#   smartctl -i "$disk" >"$out" 2>&1 || true
#   printf '%s\n' "$out"
# }

# smart_caps_file() {
#   local disk="$1"
#   local out="$RUN_DIR/$(basename "$disk")_smart_caps.txt"
#   smartctl -c "$disk" >"$out" 2>&1 || true
#   printf '%s\n' "$out"
# }

# smart_full_file() {
#   local disk="$1"
#   local out="$RUN_DIR/$(basename "$disk")_smart_full.txt"
#   smartctl -x "$disk" >"$out" 2>&1 || true
#   printf '%s\n' "$out"
# }

# smart_attr_file() {
#   local disk="$1"
#   local out="$RUN_DIR/$(basename "$disk")_smart_attr.txt"
#   smartctl -A "$disk" >"$out" 2>&1 || true
#   printf '%s\n' "$out"
# }

# smart_selftest_file() {
#   local disk="$1"
#   local out="$RUN_DIR/$(basename "$disk")_selftest.txt"
#   smartctl -l selftest "$disk" >"$out" 2>&1 || true
#   printf '%s\n' "$out"
# }

# smart_error_file() {
#   local disk="$1"
#   local out="$RUN_DIR/$(basename "$disk")_errorlog.txt"
#   smartctl -l error "$disk" >"$out" 2>&1 || true
#   printf '%s\n' "$out"
# }

# write_inventory() {
#   {
#     echo "Script: $SCRIPT_NAME"
#     echo "Version: $VERSION"
#     echo "Mode: $MODE"
#     echo "Run timestamp: $RUN_TS"
#     echo "Hostname: $(hostname 2>/dev/null || true)"
#     echo "Kernel: $(uname -r)"
#     echo "Root source: $(root_source)"
#     echo
#     echo "== lsblk -d =="
#     lsblk -d -o PATH,NAME,SIZE,MODEL,SERIAL,ROTA,TRAN,TYPE
#     echo
#     echo "== lsblk -f =="
#     lsblk -f
#   } > "$RUN_DIR/inventory.txt"
# }

# write_kernel_logs() {
#   {
#     echo "== dmesg disk-related lines =="
#     dmesg -T 2>/dev/null | grep -Ei 'ata|nvme|error|fail|reset|I/O|uncorrectable|medium error|end_request|crc' || true
#     echo
#     if command -v journalctl >/dev/null 2>&1; then
#       echo "== journalctl -k -b disk-related lines =="
#       journalctl -k -b --no-pager 2>/dev/null | grep -Ei 'ata|nvme|error|fail|reset|I/O|uncorrectable|medium error|end_request|crc' || true
#     fi
#   } > "$RUN_DIR/kernel_disk_logs.txt"
# }

# get_model() {
#   local disk="$1"
#   lsblk -dn -o MODEL "$disk" 2>/dev/null | sed 's/[[:space:]]\+$//' || true
# }

# get_serial() {
#   local disk="$1"
#   lsblk -dn -o SERIAL "$disk" 2>/dev/null | sed 's/[[:space:]]\+$//' || true
# }

# get_size() {
#   local disk="$1"
#   lsblk -dn -o SIZE "$disk" 2>/dev/null | sed 's/[[:space:]]\+$//' || true
# }

# get_transport() {
#   local disk="$1"
#   lsblk -dn -o TRAN "$disk" 2>/dev/null | sed 's/[[:space:]]\+$//' || true
# }

# get_label_list() {
#   local disk="$1"
#   { lsblk -nr -o LABEL "$disk" 2>/dev/null || true; } | awk 'NF' | paste -sd ',' - || true
# }

# get_uuid_list() {
#   local disk="$1"
#   { lsblk -nr -o UUID "$disk" 2>/dev/null || true; } | awk 'NF' | paste -sd ',' - || true
# }

# get_mount_summary() {
#   local disk="$1"
#   { lsblk -nr -o PATH,MOUNTPOINT "$disk" 2>/dev/null || true; } | \
#     awk '$2 != "" {print $1 " -> " $2}' | paste -sd ';' - || true
# }

# smartctl_attr_value() {
#   local disk="$1"
#   local attr_name="$2"
#   { smartctl -A "$disk" 2>/dev/null || true; } | \
#     awk -v name="$attr_name" '$2==name {print $10; found=1} END{if(!found) print ""}'
# }

# smart_overall_health() {
#   local disk="$1"
#   local line
#   line="$(smartctl -H "$disk" 2>/dev/null | grep -E 'SMART overall-health|SMART Health Status|SMART overall.*result|SMART overall.*PASSED|SMART.*FAILED' | head -n1 || true)"
#   if [[ -n "$line" ]]; then
#     echo "$line" | sed 's/^[[:space:]]*//'
#   else
#     echo "SMART health line not found"
#   fi
# }

# smart_device_error_count() {
#   local disk="$1"
#   { smartctl -x "$disk" 2>/dev/null || true; } | \
#     awk -F': *' '/Device Error Count:/ {print $2; found=1} END{if(!found) print ""}'
# }

# smart_selftest_last_status() {
#   local disk="$1"
#   { smartctl -l selftest "$disk" 2>/dev/null || true; } | \
#     awk 'NR>4 && $1=="#" {print substr($0, index($0,$2)); exit}'
# }

# selftest_progress_line() {
#   local disk="$1"
#   { smartctl -c "$disk" 2>/dev/null || true; } | \
#     awk '
#       /Self-test execution status:/ {
#         line=$0
#         low=tolower($0)
#         if (low ~ /in progress/) {
#           print line
#         }
#         exit
#       }
#     '
# }

# selftest_poll_minutes() {
#   local disk="$1"
#   local mode="$2"
#   local patt
#   if [[ "$mode" == "short" ]]; then
#     patt='Short self-test routine recommended polling time:'
#   else
#     patt='Extended self-test routine recommended polling time:'
#   fi

#   { smartctl -c "$disk" 2>/dev/null || true; } | \
#     awk -v patt="$patt" '
#       index($0,patt) {
#         if (match($0, /\([[:space:]]*[0-9]+[[:space:]]*\)/)) {
#           val=substr($0, RSTART+1, RLENGTH-2)
#           gsub(/[[:space:]]/, "", val)
#           print val
#           found=1
#           exit
#         }
#       }
#       END{if(!found) print ""}
#     '
# }

# wait_until_no_active_test() {
#   local disk="$1"
#   local start_ts elapsed_min line
#   start_ts="$(date +%s)"

#   [[ "$WAIT_FOR_ACTIVE" == "yes" ]] || return 0

#   while is_selftest_active "$disk"; do
#     line="$(get_selftest_execution_line "$disk")"
#     log "$disk: чекаю завершення активного self-test... ${line:-невідомий статус}"

#     if [[ "$MAX_WAIT_MINUTES" =~ ^[0-9]+$ ]] && (( MAX_WAIT_MINUTES > 0 )); then
#       elapsed_min=$(( ($(date +%s) - start_ts) / 60 ))
#       if (( elapsed_min >= MAX_WAIT_MINUTES )); then
#         log "$disk: перевищено ліміт очікування ${MAX_WAIT_MINUTES} хв."
#         return 1
#       fi
#     fi

#     sleep "$POLL_SEC"
#   done

#   return 0
# }

# start_selftest() {
#   local disk="$1"
#   local start_out="$RUN_DIR/$(basename "$disk")_start_${MODE}.txt"
#   local attempt=1
#   local success="no"
#   local reason=""

#   if ! wait_until_no_active_test "$disk"; then
#     reason="active self-test already running or wait limit exceeded"
#     SELFTEST_START_STATUS["$disk"]="SKIPPED"
#     SELFTEST_START_REASON["$disk"]="$reason"
#     echo "SKIPPED: $reason" > "$start_out"
#     return 0
#   fi

#   while (( attempt <= SELFTEST_START_RETRIES )); do
#     if smartctl -t "$MODE" "$disk" >"$start_out" 2>&1; then
#       success="yes"
#       break
#     fi

#     reason="$(tail -n 1 "$start_out" 2>/dev/null || echo "smartctl -t failed")"
#     reason="${reason//$'\t'/ }"
#     reason="${reason//$'\n'/ }"

#     log "$disk: не вдалося стартувати $MODE self-test (спроба $attempt/$SELFTEST_START_RETRIES): ${reason:-невідома причина}"

#     if (( attempt < SELFTEST_START_RETRIES )); then
#       sleep "$SELFTEST_START_RETRY_DELAY"
#     fi

#     ((attempt++))
#   done

#   if [[ "$success" == "yes" ]]; then
#     SELFTEST_START_STATUS["$disk"]="STARTED"
#     SELFTEST_START_REASON["$disk"]="started"
#   else
#     SELFTEST_START_STATUS["$disk"]="NOT_STARTED"
#     SELFTEST_START_REASON["$disk"]="${reason:-start failed}"
#   fi

#   {
#     echo "SELFTEST_START_STATUS=${SELFTEST_START_STATUS[$disk]}"
#     echo "SELFTEST_START_REASON=${SELFTEST_START_REASON[$disk]}"
#   } > "$RUN_DIR/$(basename "$disk")_start_status.txt"

#   return 0
# }

smart_info_text() {
  local disk="$1"
  smartctl -i "$disk" 2>/dev/null || true
}

trim_trailing_spaces() {
  sed 's/[[:space:]]\+$//'
}

get_model() {
  local disk="$1"
  smart_info_text "$disk" | awk -F': *' '
    /^(Device Model|Model Number|Product):/ {
      print $2
      exit
    }
  ' | trim_trailing_spaces
}

get_serial() {
  local disk="$1"
  smart_info_text "$disk" | awk -F': *' '
    /^Serial Number:/ {
      print $2
      exit
    }
  ' | trim_trailing_spaces
}

get_size() {
  local disk="$1"
  smart_info_text "$disk" | awk -F': *' '
    /^(User Capacity|Total NVM Capacity):/ {
      print $2
      exit
    }
  ' | sed 's/ \[.*$//' | trim_trailing_spaces
}

get_transport() {
  local disk="$1"
  local info
  info="$(smart_info_text "$disk")"

  if echo "$info" | grep -qi 'NVMe'; then
    echo "NVMe"
  elif echo "$info" | grep -qi 'SATA'; then
    echo "SATA"
  elif echo "$info" | grep -qi 'SAS'; then
    echo "SAS"
  elif echo "$info" | grep -qi 'USB'; then
    echo "USB"
  else
    echo ""
  fi
}

wait_for_started_tests_to_finish() {
  local -a disks=("$@")
  local active=0
  local line
  local disk

  [[ "$WAIT_FOR_COMPLETION" == "yes" ]] || return 0

  while true; do
    active=0

    for disk in "${disks[@]}"; do
      [[ "${SELFTEST_START_STATUS[$disk]:-UNKNOWN}" == "STARTED" ]] || continue

      line="$(selftest_progress_line "$disk")"
      if [[ -n "$line" ]]; then
        active=1
        log "$disk: self-test ще триває... $line"
      fi
    done

    [[ "$active" -eq 0 ]] && break
    log "Наступна перевірка активних self-test через ${POLL_SEC} сек."
    sleep "$POLL_SEC"
  done
}

last_state_file() {
  local previous
  previous="$(find "$RUNS_DIR" -maxdepth 2 -type f -name "$STATE_FILE_NAME" ! -path "$RUN_DIR/*" 2>/dev/null | sort | tail -n1 || true)"
  printf '%s\n' "$previous"
}

previous_state_row_by_serial() {
  local serial="$1"
  local prev="$2"
  [[ -f "$prev" && -n "$serial" ]] || return 0
  awk -F'\t' -v s="$serial" '$2==s {print; exit}' "$prev"
}

assess_disk_state() {
  local disk="$1"
  local overall reallocated pending offunc crc selftest_last dev_errors
  overall="$(smart_overall_health "$disk")"
  reallocated="$(smartctl_attr_value "$disk" Reallocated_Sector_Ct)"
  pending="$(smartctl_attr_value "$disk" Current_Pending_Sector)"
  offunc="$(smartctl_attr_value "$disk" Offline_Uncorrectable)"
  crc="$(smartctl_attr_value "$disk" UDMA_CRC_Error_Count)"
  selftest_last="$(smart_selftest_last_status "$disk")"
  dev_errors="$(smart_device_error_count "$disk")"

  reallocated="${reallocated:-0}"
  pending="${pending:-0}"
  offunc="${offunc:-0}"
  crc="${crc:-0}"
  dev_errors="${dev_errors:-0}"

  if echo "$overall" | grep -Eqi 'FAIL|BAD|FAILED'; then
    echo "CRITICAL"
    return
  fi
  if [[ "$pending" =~ ^[0-9]+$ ]] && (( pending > 0 )); then
    echo "CRITICAL"
    return
  fi
  if [[ "$offunc" =~ ^[0-9]+$ ]] && (( offunc > 0 )); then
    echo "CRITICAL"
    return
  fi
  if echo "$selftest_last" | grep -Eqi 'Completed: read failure|Interrupted \(host reset\)|Completed: electrical failure|Completed: unknown failure|fatal'; then
    echo "CRITICAL"
    return
  fi
  if [[ "$reallocated" =~ ^[0-9]+$ ]] && (( reallocated > 0 )); then
    echo "WARNING"
    return
  fi
  if [[ "$crc" =~ ^[0-9]+$ ]] && (( crc > 0 )); then
    echo "WARNING"
    return
  fi
  if [[ "$dev_errors" =~ ^[0-9]+$ ]] && (( dev_errors > 0 )); then
    echo "WARNING"
    return
  fi
  echo "OK"
}

append_state_row() {
  local disk="$1"
  local state_file="$RUN_DIR/$STATE_FILE_NAME"
  local model serial size tran label uuid overall reallocated pending offunc crc hours selftest_last dev_errors status mounts
  local selftest_start_status selftest_start_reason

  model="$(get_model "$disk")"
  serial="$(get_serial "$disk")"
  size="$(get_size "$disk")"
  tran="$(get_transport "$disk")"
  label="$(get_label_list "$disk")"
  uuid="$(get_uuid_list "$disk")"
  overall="$(smart_overall_health "$disk")"
  reallocated="$(smartctl_attr_value "$disk" Reallocated_Sector_Ct)"
  pending="$(smartctl_attr_value "$disk" Current_Pending_Sector)"
  offunc="$(smartctl_attr_value "$disk" Offline_Uncorrectable)"
  crc="$(smartctl_attr_value "$disk" UDMA_CRC_Error_Count)"
  hours="$(smartctl_attr_value "$disk" Power_On_Hours)"
  selftest_last="$(smart_selftest_last_status "$disk")"
  dev_errors="$(smart_device_error_count "$disk")"
  status="$(assess_disk_state "$disk")"
  mounts="$(get_mount_summary "$disk")"

  selftest_start_status="${SELFTEST_START_STATUS[$disk]:-N/A}"
  selftest_start_reason="${SELFTEST_START_REASON[$disk]:-N/A}"

  selftest_start_reason="${selftest_start_reason//$'\t'/ }"
  selftest_start_reason="${selftest_start_reason//$'\n'/ }"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$disk" "$serial" "$model" "$size" "$tran" "${label:-}" "${uuid:-}" "$status" "$selftest_start_status" "$selftest_start_reason" \
    "${reallocated:-}" "${pending:-}" "${offunc:-}" "${crc:-}" "${hours:-}" "${dev_errors:-}" "${selftest_last:-}" "${overall:-}" \
    >> "$state_file"

  printf '%s\t%s\n' "$disk" "$mounts" >> "$RUN_DIR/mounts.tsv"
}

write_state_headers() {
  printf 'disk_path\tserial\tmodel\tsize\ttransport\tlabel\tuuid\tstatus\tselftest_start_status\tselftest_start_reason\treallocated\tpending\toffline_uncorrectable\tcrc\tpower_on_hours\tdevice_error_count\tlast_selftest\toverall_health\n' > "$RUN_DIR/$STATE_FILE_NAME"
  printf 'disk_path\tmounts\n' > "$RUN_DIR/mounts.tsv"
}

delta_or_same() {
  local current="$1"
  local previous="$2"
  if [[ -z "$previous" || -z "$current" ]]; then
    echo "n/a"
    return
  fi
  if [[ "$current" =~ ^[0-9]+$ && "$previous" =~ ^[0-9]+$ ]]; then
    local delta=$(( current - previous ))
    if (( delta > 0 )); then
      printf '+%s' "$delta"
    elif (( delta < 0 )); then
      printf '%s' "$delta"
    else
      echo '0'
    fi
    return
  fi
  echo "n/a"
}

write_user_summary() {
  local prev state row serial prev_row
  local disk model size tran status realloc pending offunc crc hours derr selftest overall
  prev="$(last_state_file)"

  {
    echo "Короткий підсумок перевірки дисків"
    echo "Дата: $RUN_TS"
    echo "Режим: $MODE"
    echo "Папка звіту: $RUN_DIR"
    echo

    if [[ -n "$prev" ]]; then
      echo "Порівняння з попереднім станом: $prev"
    else
      echo "Попередній state-файл не знайдено; це перший або ізольований запуск."
    fi
    echo

    while IFS=$'\t' read -r disk serial model size tran label uuid status selftest_start_status selftest_start_reason realloc pending offunc crc hours derr selftest overall; do
      [[ "$disk" == "disk_path" ]] && continue

      prev_row="$(previous_state_row_by_serial "$serial" "$prev")"
      local prev_realloc="" prev_pending="" prev_offunc="" prev_crc=""
      if [[ -n "$prev_row" ]]; then
        prev_realloc="$(echo "$prev_row" | awk -F'\t' '{print $11}')"
        prev_pending="$(echo "$prev_row" | awk -F'\t' '{print $12}')"
        prev_offunc="$(echo "$prev_row" | awk -F'\t' '{print $13}')"
        prev_crc="$(echo "$prev_row" | awk -F'\t' '{print $14}')"
      fi

      echo "[$status] $model | serial=$serial | path=$disk"
      echo "  Size=$size | transport=${tran:-unknown}"
      echo "  LABEL=${label:-немає} | UUID=${uuid:-немає}"
      echo "  SMART: $overall"
      echo "  Self-test start: ${selftest_start_status:-N/A} | reason: ${selftest_start_reason:-N/A}"
      echo "  Reallocated=$realloc (Δ $(delta_or_same "$realloc" "$prev_realloc")) | Pending=$pending (Δ $(delta_or_same "$pending" "$prev_pending")) | Offline_Uncorrectable=$offunc (Δ $(delta_or_same "$offunc" "$prev_offunc")) | CRC=$crc (Δ $(delta_or_same "$crc" "$prev_crc"))"
      echo "  Power_On_Hours=$hours | Device_Error_Count=$derr"
      echo "  Last self-test: ${selftest:-немає запису}"

      if [[ "$selftest_start_status" == "NOT_STARTED" || "$selftest_start_status" == "SKIPPED" ]]; then
        echo "  Примітка: активний self-test для цього диска не був виконаний."
      fi

      if [[ "$status" == "CRITICAL" ]]; then
        echo "  Висновок: диск вже виглядає небезпечним, важливі дані тільки з резервною копією."
      elif [[ "$status" == "WARNING" ]]; then
        echo "  Висновок: диск не аварійний, але є ознаки ризику. Перевір кабель/порт/живлення або історію ремапів."
      else
        echo "  Висновок: критичних SMART-ознак зараз не видно."
      fi
      echo
    done < "$RUN_DIR/$STATE_FILE_NAME"
  } > "$RUN_DIR/summary_user.txt"
}

write_assistant_summary() {
  {
    echo "ASSISTANT DISK REPORT"
    echo "Run timestamp: $RUN_TS"
    echo "Mode: $MODE"
    echo "Report directory: $RUN_DIR"
    echo

    echo "== Inventory =="
    cat "$RUN_DIR/inventory.txt"
    echo

    echo "== Compact state =="
    cat "$RUN_DIR/$STATE_FILE_NAME"
    echo

    echo "== Kernel disk logs =="
    cat "$RUN_DIR/kernel_disk_logs.txt"
    echo

    local disk
    while read -r disk; do
      [[ -n "$disk" ]] || continue
      echo
      echo "=============================="
      echo "DISK: $disk"
      echo "MODEL: $(get_model "$disk")"
      echo "SERIAL: $(get_serial "$disk")"
      echo "SIZE: $(get_size "$disk")"
      echo "TRANSPORT: $(get_transport "$disk")"
      echo "STATUS: $(assess_disk_state "$disk")"
      echo
      echo "--- smartctl -H ---"
      smartctl -H "$disk" 2>&1 || true
      echo
      echo "--- Selected attributes ---"
      smartctl -A "$disk" 2>/dev/null | egrep 'Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|UDMA_CRC_Error_Count|Power_On_Hours|Media_Wearout_Indicator|Percentage Used|Available Spare' || true
      echo
      echo "--- Last self-test log ---"
      smartctl -l selftest "$disk" 2>&1 || true
      echo
      echo "--- SMART error log ---"
      smartctl -l error "$disk" 2>&1 || true
      echo
      echo "--- Full smartctl -x ---"
      cat "$RUN_DIR/$(basename "$disk")_smart_full.txt"
      echo
    done < <(discover_disks)
  } > "$RUN_DIR/summary_assistant.txt"
}

telegram_is_configured() {
  [[ "$TELEGRAM_ENABLED" == "yes" ]] || return 1
  [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]] || return 1
  command -v curl >/dev/null 2>&1 || return 1
}

build_telegram_message() {
  local status_count_ok=0 status_count_warn=0 status_count_critical=0
  local disk serial model size tran status realloc pending offunc crc hours derr selftest overall
  local lines=()

  while IFS=$'\t' read -r disk serial model size tran label uuid status selftest_start_status selftest_start_reason realloc pending offunc crc hours derr selftest overall; do
    [[ "$disk" == "disk_path" ]] && continue

    case "$status" in
      OK) ((status_count_ok+=1)) ;;
      WARNING) ((status_count_warn+=1)) ;;
      CRITICAL) ((status_count_critical+=1)) ;;
    esac

    lines+=("[$status] ${model} SN=${serial} path=${disk} | ST=${selftest_start_status:-N/A} | R=${realloc:-0} P=${pending:-0} O=${offunc:-0} CRC=${crc:-0}")
done < "$RUN_DIR/$STATE_FILE_NAME"

  {
    echo "disk_health_audit"
    echo "Host: $(hostname 2>/dev/null || echo unknown)"
    echo "Mode: $MODE"
    echo "Date: $RUN_TS"
    echo "Summary: OK=${status_count_ok} WARNING=${status_count_warn} CRITICAL=${status_count_critical}"
    echo "Report: $RUN_DIR"
    echo
    printf '%s\n' "${lines[@]}"
  } | awk 'length($0) > 3900 { print substr($0,1,3900); exit } { print }'
}

send_telegram_report() {
  telegram_is_configured || {
    log "Telegram: пропускаю відправку (вимкнено або не задані TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID)."
    return 0
  }

  local api_base="${TELEGRAM_API_URL%/}/bot${TELEGRAM_BOT_TOKEN}"
  local msg_file="$RUN_DIR/telegram_message.txt"
  build_telegram_message > "$msg_file"

  if ! curl -sS --fail --retry 2 --retry-delay 2 \
    -X POST "$api_base/sendMessage" \
    --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
    --data-urlencode "text@${msg_file}" \
    --data "disable_notification=$TELEGRAM_DISABLE_NOTIFICATION" \
    > "$RUN_DIR/telegram_sendMessage.json" 2> "$RUN_DIR/telegram_sendMessage.err"; then
    log "Telegram: не вдалося відправити короткий текстовий звіт. Дивись $RUN_DIR/telegram_sendMessage.err"
    return 1
  fi

  if [[ "$TELEGRAM_SEND_DOCUMENT" == "yes" && -f "$RUN_DIR/summary_user.txt" ]]; then
    curl -sS --fail --retry 2 --retry-delay 2 \
      -X POST "$api_base/sendDocument" \
      -F "chat_id=$TELEGRAM_CHAT_ID" \
      -F "disable_notification=$TELEGRAM_DISABLE_NOTIFICATION" \
      -F "caption=disk_health_audit ${MODE} ${RUN_TS} $(hostname 2>/dev/null || echo unknown)" \
      -F "document=@$RUN_DIR/summary_user.txt;type=text/plain" \
      > "$RUN_DIR/telegram_sendDocument.json" 2> "$RUN_DIR/telegram_sendDocument.err" || {
        log "Telegram: текст пішов, але summary_user.txt не вдалося прикріпити. Дивись $RUN_DIR/telegram_sendDocument.err"
        return 0
      }
  fi

  log "Telegram: короткий звіт відправлено."
}

collect_for_disk() {
  local disk="$1"
  smart_info_file "$disk" >/dev/null
  smart_caps_file "$disk" >/dev/null
  smart_attr_file "$disk" >/dev/null
  smart_selftest_file "$disk" >/dev/null
  smart_error_file "$disk" >/dev/null
  smart_full_file "$disk" >/dev/null
  append_state_row "$disk"
}

run_main() {
  parse_args "$@"
  ensure_root
  
  if [[ "$MODE" == "probe" ]]; then
    NO_FILES="yes"
    AUTO_INSTALL="no"
    TELEGRAM_ENABLED="no"
    WAIT_FOR_ACTIVE="no"
    WAIT_FOR_COMPLETION="no"
    RUNS_CLEANUP_ENABLED="no"
  else
    acquire_lock
  fi


  if [[ "$MODE" == "install" ]]; then
    stage "INSTALL: перевірка і встановлення залежностей"
    install_dependencies
    echo "Залежності встановлені."
    exit 0
  fi

  local -a disks=()
  mapfile -t disks < <(discover_disks)
  local total_disks="${#disks[@]}"
  log "Знайдено диски ($total_disks): ${disks[*]}"

  if [[ "$MODE" == "probe" ]]; then
    stage "PROBE: безпечне читання SMART без створення файлів"

    local disk idx=0
    for disk in "${disks[@]}"; do
      ((idx+=1))
      progress "PROBE" "$idx" "$total_disks" "$disk"

      echo "=============================="
      echo "DISK: $disk"
      echo "MODEL: $(get_model "$disk")"
      echo "SERIAL: $(get_serial "$disk")"
      echo "SIZE: $(get_size "$disk")"
      echo "TRANSPORT: $(get_transport "$disk")"
      echo "STATUS: $(assess_disk_state "$disk")"
      echo
      echo "--- smartctl -H ---"
      smartctl -H "$disk" 2>&1 || true
      echo
      echo "--- smartctl -A ---"
      smartctl -A "$disk" 2>&1 || true
      echo
      echo "--- smartctl -l selftest ---"
      smartctl -l selftest "$disk" 2>&1 || true
      echo
      echo "--- smartctl -l error ---"
      smartctl -l error "$disk" 2>&1 || true
      echo
    done

    exit 0
  fi

  stage "1/7 Підготовка середовища"
  install_dependencies
  init_report_dir
  cleanup_old_runs

  log "Режим: $MODE"
  log "Каталог запуску: $RUN_DIR"
  log "Очікування активного тесту: $WAIT_FOR_ACTIVE"
  log "Очікування завершення: $WAIT_FOR_COMPLETION"
  log "Poll interval: ${POLL_SEC}s"
  log "Stagger interval: ${STAGGER_SEC}s"

  stage "2/7 Інвентаризація системи"
  write_inventory

  stage "3/7 Збір системних логів по дисках"
  write_kernel_logs

  stage "4/7 Підготовка state-файлів"
  write_state_headers

  local -a disks=()
  mapfile -t disks < <(discover_disks)
  local total_disks="${#disks[@]}"
  log "Знайдено диски ($total_disks): ${disks[*]}"

  local disk idx

  if [[ "$MODE" == "short" || "$MODE" == "long" ]]; then
    stage "5/7 Старт $MODE self-test"
    idx=0
    for disk in "${disks[@]}"; do
      ((idx+=1))
      progress "SELFTEST" "$idx" "$total_disks" "$disk"
      start_selftest "$disk" || true
      sleep "$STAGGER_SEC"
    done

    stage "6/7 Очікування завершення активних self-test"
    wait_for_started_tests_to_finish "${disks[@]}"
  fi

  stage "6/7 Збір SMART-звітів"
  idx=0
  for disk in "${disks[@]}"; do
    ((idx+=1))
    progress "COLLECT" "$idx" "$total_disks" "$disk"
    collect_for_disk "$disk"
  done

  stage "7/7 Формування підсумків"
  write_user_summary
  write_assistant_summary
  send_telegram_report || true

  log "Готово. Короткий звіт: $RUN_DIR/summary_user.txt"
  log "Розширений звіт: $RUN_DIR/summary_assistant.txt"
  log "Повний каталог запуску: $RUN_DIR"
}

run_main "$@"
