# installer/lib/pkg.sh
# shellcheck shell=bash

PKG_MANAGER=""
detect_pkg_manager() {
  if command -v xbps-install &>/dev/null; then
    PKG_MANAGER=xbps
  elif command -v pacman &>/dev/null; then
    PKG_MANAGER=pacman
  else
    die "$(_ 'No supported package manager found (pacman or xbps-install)' \
             'Менеджер пакетов не найден (нужен pacman или xbps-install)')"
  fi
}

# Установить пакеты. Аргументы — имена пакетов.
pkg_install() {
  case "$PKG_MANAGER" in
    xbps)   sudo xbps-install -y "$@" ;;
    pacman) sudo pacman -S --needed --noconfirm -- "$@" ;;
  esac
}

# Обновить систему И установить пакеты.
pkg_sysupgrade() {
  case "$PKG_MANAGER" in
    xbps)   sudo xbps-install -Suy && sudo xbps-install -y "$@" ;;
    pacman) sudo pacman -Syu --needed --noconfirm -- "$@" ;;
  esac
}

# Проверить, установлен ли пакет. 0 = установлен.
pkg_is_installed() {
  case "$PKG_MANAGER" in
    xbps)   xbps-query "$1" &>/dev/null ;;
    pacman) pacman -Q -- "$1" &>/dev/null ;;
  esac
}

# Проверить, есть ли пакет в репозиториях. 0 = есть.
pkg_in_repos() {
  case "$PKG_MANAGER" in
    xbps)   xbps-query -R "$1" &>/dev/null || { xbps-query -Rs "^${1}$" 2>/dev/null | grep -q "^\["; } ;;
    pacman) pacman -Si -- "$1" &>/dev/null ;;
  esac
}

# Размер загрузки пакетов в МБ (приблизительно).
pkg_download_size_mb() {
  case "$PKG_MANAGER" in
    xbps)
      # xbps не даёт точный размер до загрузки, возвращаем 0
      echo 0 ;;
    pacman)
      pacman -Sp --needed --print-format '%s' "$@" 2>/dev/null \
        | awk '{s+=$1} END {printf "%d", s/1048576}' ;;
  esac
}
