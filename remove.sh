#!/usr/bin/env bash
# Uninstaller for angelOS
# Removes files, services, SDDM themes, and packages installed by install.sh

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
HOME_DIR="${HOME:?HOME is not set}"
if [[ -n "${SUDO_USER:-}" && "$EUID" -eq 0 ]]; then
  HOME_DIR="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
fi

# Language selection
UI="en"
if [[ "${LANG:-}" =~ ^ru ]] || [[ "${ANGELOS_LANG:-}" == ru ]]; then
  UI="ru"
fi
_() { if [[ "$UI" == ru ]]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

# Colors
if [[ -t 1 ]]; then
  C_SAY=$'\033[1;38;2;255;143;199m'
  C_WARN=$'\033[1;38;2;255;214;120m'
  C_ERR=$'\033[1;38;2;255;79;163m'
  C_DIM=$'\033[38;2;201;167;255m'
  C_OFF=$'\033[0m'
else
  C_SAY="" C_WARN="" C_ERR="" C_DIM="" C_OFF=""
fi

say()  { printf '%s[angelOS]%s %s\n' "$C_SAY" "$C_OFF" "$*"; }
warn() { printf '%s[angelOS] WARNING:%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%s[angelOS] ERROR:%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }
hr()   { printf '%s──────────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_OFF"; }

confirm() {
  local prompt="$1" default="${2:-n}" hint answer
  [[ "$default" == y ]] && hint="[Y/n]" || hint="[y/N]"
  if ((YES_ALL)); then
    [[ "$default" == y ]] && return 0 || return 1
  fi
  read -r -p "$prompt $hint " answer || true
  answer="${answer:-$default}"
  [[ "$answer" =~ ^([yYдД]|yes|да|Да)$ ]]
}

# Detect package manager
source "$ROOT/installer/lib/pkg.sh" 2>/dev/null || {
  PKG_MANAGER=""
  if command -v xbps-install &>/dev/null; then PKG_MANAGER=xbps;
  elif command -v pacman &>/dev/null; then PKG_MANAGER=pacman; fi
}
[[ -n "$PKG_MANAGER" ]] || detect_pkg_manager

# CLI Flags
YES_ALL=0
OPT_DOTFILES=0
OPT_SERVICES=0
OPT_SDDM=0
OPT_PACKAGES=0
OPT_RESTORE=0

usage() {
  cat <<EOF
Usage: ./remove.sh [OPTIONS]

Options:
  -y, --yes          Run without interactive confirmation (uses safe defaults)
  --all              Remove dotfiles, services, SDDM theme and configs
  --dotfiles         Remove user configuration files and scripts
  --services         Stop and remove background services (runit/systemd)
  --sddm             Remove SDDM login theme and disable SDDM service
  --packages         Remove system packages installed for angelOS
  --restore          Restore backed-up configurations (*.bak.*)
  -h, --help         Show this help message
EOF
}

stop_services() {
  say "$(_ 'Stopping angelOS processes and user services…' 'Остановка процессов и сервисов angelOS…')"
  killall -9 qs quickshell niri-game-mode mouse-coalesce polkit-agent-guard 2>/dev/null || true
  killall -9 voxtype voxtype-indicator 2>/dev/null || true

  if [[ "$PKG_MANAGER" == xbps ]]; then
    rm -rf "$HOME_DIR/.local/share/runit/service"/* 2>/dev/null || true
    # Clean runsvdir from niri user.kdl
    if [[ -f "$HOME_DIR/.config/niri/cfg/user.kdl" ]]; then
      sed -i '/runsvdir.*runit\/service/d' "$HOME_DIR/.config/niri/cfg/user.kdl" 2>/dev/null || true
      sed -i '/angelOS runit user services/d' "$HOME_DIR/.config/niri/cfg/user.kdl" 2>/dev/null || true
    fi
  else
    if command -v systemctl &>/dev/null; then
      systemctl --user stop niri-game-mode.service mouse-coalesce.service polkit-agent-guard.service \
        voxtype.service voxtype-indicator.service 2>/dev/null || true
      systemctl --user disable niri-game-mode.service mouse-coalesce.service polkit-agent-guard.service \
        voxtype.service voxtype-indicator.service 2>/dev/null || true
      rm -f "$HOME_DIR/.config/systemd/user/"{niri-game-mode,mouse-coalesce,polkit-agent-guard,voxtype,voxtype-indicator}.service 2>/dev/null || true
      systemctl --user daemon-reload 2>/dev/null || true
    fi
  fi
}

restore_backups() {
  say "$(_ 'Restoring backup configurations…' 'Восстановление резервных копий…')"
  local backup_dir="$HOME_DIR/.local/state/angelos/backups"
  if [[ -d "$backup_dir" ]]; then
    for b in "$backup_dir"/*; do
      [[ -d "$b" ]] || continue
      say "$(_ "Restoring from $b" "Восстановление из $b")"
      cp -a "$b/." "$HOME_DIR/.config/" 2>/dev/null || true
    done
  fi

  find "$HOME_DIR/.config" -name "*.bak.*" -type f 2>/dev/null | while read -r bak; do
    local orig="${bak%%.bak.*}"
    say "$(_ "Restoring $orig" "Восстановление $orig")"
    mv -f "$bak" "$orig" 2>/dev/null || true
  done
}

remove_dotfiles() {
  say "$(_ 'Removing dotfiles and user scripts…' 'Удаление пользовательских файлов и скриптов…')"

  local manifest="$HOME_DIR/.local/state/angelos/installed-files.sha256"
  if [[ -f "$manifest" ]]; then
    awk '{print $2}' "$manifest" | while read -r rel; do
      [[ -n "$rel" ]] || continue
      rm -f "$HOME_DIR/$rel" 2>/dev/null || true
    done
  fi

  rm -rf "$HOME_DIR/.config/quickshell" 2>/dev/null || true
  rm -rf "$HOME_DIR/.config/runit" 2>/dev/null || true
  rm -rf "$HOME_DIR/.local/share/runit" 2>/dev/null || true
  rm -rf "$HOME_DIR/.local/share/angelos" 2>/dev/null || true
  rm -rf "$HOME_DIR/.local/share/themes/adw-gtk3" 2>/dev/null || true
  rm -rf "$HOME_DIR/.cache/angelos" 2>/dev/null || true
  rm -rf "$HOME_DIR/.cache/quickshell" 2>/dev/null || true
  rm -rf "$HOME_DIR/.local/state/angelos" 2>/dev/null || true

  rm -f "$HOME_DIR/.local/bin/angelos" 2>/dev/null || true
  rm -f "$HOME_DIR/.local/bin/niri-"* 2>/dev/null || true
  rm -f "$HOME_DIR/.local/bin/mouse-coalesce" 2>/dev/null || true
  rm -f "$HOME_DIR/.local/bin/polkit-agent-guard" 2>/dev/null || true
  rm -f "$HOME_DIR/.local/bin/voxtype"* 2>/dev/null || true

  if [[ -f "$HOME_DIR/.profile" ]]; then
    sed -i '/LIBSEAT_BACKEND/d' "$HOME_DIR/.profile" 2>/dev/null || true
    sed -i '/dbus-run-session/d' "$HOME_DIR/.profile" 2>/dev/null || true
    sed -i '/SDDM_USER_SHELL/d' "$HOME_DIR/.profile" 2>/dev/null || true
    sed -i '/angelOS/d' "$HOME_DIR/.profile" 2>/dev/null || true
    if ! grep -q '[^[:space:]]' "$HOME_DIR/.profile" 2>/dev/null; then
      rm -f "$HOME_DIR/.profile"
    fi
  fi

  if [[ -f "$HOME_DIR/.bash_profile" ]]; then
    sed -i '/\.profile/d' "$HOME_DIR/.bash_profile" 2>/dev/null || true
  fi
}

remove_sddm() {
  say "$(_ 'Removing SDDM theme and system rules (requires sudo)…' \
           'Удаление темы SDDM и системных правил (нужен sudo)…')"

  if [[ "$PKG_MANAGER" == xbps ]]; then
    sudo rm -f /var/service/sddm 2>/dev/null || true
    sudo rm -f /var/service/seatd 2>/dev/null || true
  else
    if command -v systemctl &>/dev/null; then
      sudo systemctl disable sddm.service 2>/dev/null || true
    fi
  fi

  sudo rm -rf /usr/share/sddm/themes/angelos 2>/dev/null || true
  sudo rm -f /etc/sddm.conf.d/zz-angelos.conf 2>/dev/null || true
  sudo rm -f /etc/udev/rules.d/70-angelos-uinput.rules 2>/dev/null || true
  sudo rm -rf /usr/lib/qt6/qml/QtTest 2>/dev/null || true
  sudo udevadm control --reload 2>/dev/null || true

  local niri_sess="/usr/share/wayland-sessions/niri.desktop"
  if [[ -f "$niri_sess" ]] && grep -q '^Exec=dbus-run-session niri --session' "$niri_sess"; then
    sudo sed -i 's|^Exec=dbus-run-session niri --session|Exec=/usr/bin/niri --session|' "$niri_sess" 2>/dev/null || true
  fi
}

remove_packages() {
  say "$(_ 'Removing installed system packages…' 'Удаление системных пакетов…')"

  local -a pkgs_to_remove=()
  local pkg_file=""
  if [[ "$PKG_MANAGER" == xbps && -f "$ROOT/packages/void.txt" ]]; then
    pkg_file="$ROOT/packages/void.txt"
  elif [[ -f "$ROOT/packages/pacman.txt" ]]; then
    pkg_file="$ROOT/packages/pacman.txt"
  fi

  if [[ -n "$pkg_file" ]]; then
    while IFS= read -r p; do
      [[ -z "$p" || "$p" =~ ^[[:space:]]*# ]] && continue
      pkg_is_installed "$p" && pkgs_to_remove+=("$p")
    done < "$pkg_file"
  fi

  if ((${#pkgs_to_remove[@]})); then
    say "$(_ "Found ${#pkgs_to_remove[@]} installed package(s) to remove." \
             "Найдено ${#pkgs_to_remove[@]} установленных пакетов для удаления.")"
    if confirm "$(_ 'Proceed with package removal?' 'Продолжить удаление пакетов?')" y; then
      if [[ "$PKG_MANAGER" == xbps ]]; then
        sudo xbps-remove -R -o -y "${pkgs_to_remove[@]}" || true
      else
        sudo pacman -Rns --noconfirm "${pkgs_to_remove[@]}" || true
      fi
    fi
  else
    say "$(_ 'No matching packages found to remove.' 'Нет пакетов для удаления.')"
  fi
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes)      YES_ALL=1; shift ;;
      --all)         OPT_DOTFILES=1; OPT_SERVICES=1; OPT_SDDM=1; shift ;;
      --dotfiles)    OPT_DOTFILES=1; shift ;;
      --services)    OPT_SERVICES=1; shift ;;
      --sddm)        OPT_SDDM=1; shift ;;
      --packages)    OPT_PACKAGES=1; shift ;;
      --restore)     OPT_RESTORE=1; shift ;;
      -h|--help)     usage; exit 0 ;;
      *) die "$(_ "Unknown option: $1 (see --help)" "Неизвестный параметр: $1 (см. --help)")" ;;
    esac
  done

  hr
  say "$(_ 'angelOS Uninstaller' 'Удаление angelOS')"
  hr

  local interactive=0
  if [[ $OPT_DOTFILES -eq 0 && $OPT_SERVICES -eq 0 && $OPT_SDDM -eq 0 && $OPT_PACKAGES -eq 0 && $OPT_RESTORE -eq 0 ]]; then
    interactive=1
  fi

  if ((interactive)); then
    if confirm "$(_ 'Stop running angelOS processes and disable user services?' \
                   'Остановить запущенные процессы и службы пользователя angelOS?')" y; then
      OPT_SERVICES=1
    fi

    if confirm "$(_ 'Restore previous backup configurations (~/.local/state/angelos/backups)?' \
                   'Восстановить резервные копии старых конфигов (~/.local/state/angelos/backups)?')" n; then
      OPT_RESTORE=1
    fi

    if confirm "$(_ 'Remove angelOS configuration files and scripts from HOME?' \
                   'Удалить конфигурационные файлы и скрипты angelOS из домашней папки?')" y; then
      OPT_DOTFILES=1
    fi

    if confirm "$(_ 'Remove SDDM login screen theme and disable SDDM service?' \
                   'Удалить тему экрана входа SDDM и отключить службу SDDM?')" y; then
      OPT_SDDM=1
    fi

    if confirm "$(_ 'Remove system packages installed for angelOS (Niri, Quickshell, tools)?' \
                   'Удалить системные пакеты angelOS (Niri, Quickshell, утилиты)?')" n; then
      OPT_PACKAGES=1
    fi
    hr
  fi

  [[ $OPT_SERVICES -eq 1 ]] && stop_services
  [[ $OPT_RESTORE -eq 1 ]]  && restore_backups
  [[ $OPT_DOTFILES -eq 1 ]] && remove_dotfiles
  [[ $OPT_SDDM -eq 1 ]]     && remove_sddm
  [[ $OPT_PACKAGES -eq 1 ]] && remove_packages

  hr
  say "$(_ 'angelOS has been successfully removed.' 'angelOS успешно удален.')"
  hr
}

main "$@"
