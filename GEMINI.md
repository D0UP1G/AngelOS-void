# GEMINI.md — Портирование angelOS на Void Linux

> Этот файл — исчерпывающая инструкция для AI-ассистента (Gemini 2.5 Pro / 3.8).
> Читай его целиком перед любым изменением кода.

---

## 0. Контекст проекта

**angelOS** — dotfiles + desktop shell для Wayland-композитора **niri** на базе **Quickshell** (Qt6/QML).  
Репозиторий: `/home/dpg/Documents/AngelOS-void/`

Структура:
```
install.sh                  — точка входа, env-переменные, порядок шагов
installer/
  lib/core.sh               — step(), confirm(), preflight()
  lib/show.sh               — картинки, звук
  lib/tui.sh                — gum-меню, прогресс-бар
  steps/05-distro.sh        — проверка дистро (БЛОКИРУЕТ Void сейчас)
  steps/12-gaming.sh        — Steam, Proton
  steps/15-questions.sh     — интерактивные вопросы
  steps/20-apps-choice.sh   — выбор приложений
  steps/25-wallpapers.sh    — обои
  steps/30-packages.sh      — установка пакетов (ТОЛЬКО pacman сейчас)
  steps/35-voxtype.sh       — голосовой ввод
  steps/40-files.sh         — копирование конфигов (~HOME)
  steps/42-angel-niri.sh    — angel-niri (форк niri)
  steps/45-devices.sh       — udev-правило для заряда мышей
  steps/50-sddm.sh          — дисплей-менеджер (ТОЛЬКО systemctl сейчас)
  steps/55-follow.sh        — fish/chsh
  steps/60-shell.sh         — angelOS CLI, user-сервисы (ТОЛЬКО systemctl --user)
  steps/70-finish.sh        — итог
  steps/75-author.sh        — GitHub, QR-код
packages/
  pacman.txt                — базовые пакеты (Arch-имена)
  angelos.txt               — shell-пакеты (Arch-имена)
  tools.txt                 — утилиты (Arch-имена)
  fish.txt                  — fish-пакеты (часть — CachyOS-эксклюзивы)
  nvim.txt                  — LazyVim-зависимости
  sddm.txt                  — SDDM-тема
.config/quickshell/angelos/ — QML-оболочка
.config/systemd/user/       — юнит-файлы сервисов (НУЖНО переделать под runit)
```

---

## 1. Что заблокировано сейчас (нужно исправить первым)

### 1.1 `installer/steps/05-distro.sh` — блокировка Void

**Текущий код:**
```bash
case "$id" in arch|cachyos) return 0 ;; esac
# ...
die "Only Arch Linux and CachyOS are supported ..."
```

**Нужно:**
```bash
case "$id" in arch|cachyos|void) return 0 ;; esac
```

Также `DISTRO_ID` используется в `30-packages.sh` для `cachyos_repos()` — Void туда не попадёт, это правильно.

---

## 2. Абстракция менеджера пакетов

### 2.1 Создать `installer/lib/pkg.sh`

Этот файл должен sourced'иться из `install.sh` **до** шагов.  
Все функции работы с пакетами — только через него.

```bash
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
    xbps)   xbps-query -Rs "^${1}$" 2>/dev/null | grep -q "^\[" ;;
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
```

### 2.2 Подключить в `install.sh`

В `install.sh`, после `source installer/lib/core.sh`, добавить:
```bash
source "$ROOT/installer/lib/pkg.sh"
detect_pkg_manager
```

### 2.3 Изменить `preflight()` в `installer/lib/core.sh`

Текущий `preflight()` проверяет `command -v pacman`. Нужно убрать эту проверку —
она теперь в `detect_pkg_manager()`. Оставить только проверку sudo.

---

## 3. Файл `installer/steps/30-packages.sh` — полная замена

### 3.1 `available_only()` — фильтр недоступных пакетов

**Текущий (только pacman):**
```bash
available_only() {
  while IFS= read -r pkg; do
    if pacman -Si -- "$pkg" &>/dev/null || pacman -Q -- "$pkg" &>/dev/null; then
      echo "$pkg"
    else
      warn "..."
    fi
  done
}
```

**Нужно:**
```bash
available_only() {
  while IFS= read -r pkg; do
    if pkg_in_repos "$pkg" || pkg_is_installed "$pkg"; then
      echo "$pkg"
    else
      warn "..."
    fi
  done
}
```

### 3.2 `wanted_packages()` — выбор файла пакетов

Добавить поддержку `packages/void.txt`:
```bash
wanted_packages() {
  # Выбираем файл пакетов по дистро
  local base_list
  if [[ "$PKG_MANAGER" == xbps ]] && [[ -f "$ROOT/packages/void.txt" ]]; then
    base_list="$ROOT/packages/void.txt"
  else
    base_list="$ROOT/packages/pacman.txt"
  fi
  local list="$base_list" packages=()
  mapfile -t packages < <(grep -Ev '^[[:space:]]*(#|$)' "$list")
  # ... остальная логика без изменений, но angelos.txt/tools.txt тоже
  # нужны void-варианты: packages/void-angelos.txt, packages/void-tools.txt
  # (или единый void.txt со всем содержимым)
}
```

### 3.3 `pacman_install()` → `install_packages()`

Переименовать функцию и заменить все вызовы pacman:

```bash
install_packages() {
  local pkg packages=()
  wanted_packages   # заполняет PACKAGES=()
  packages=("${PACKAGES[@]}")
  ((${#packages[@]})) || return 0

  say "$(_ 'Updating and installing packages…' 'Обновление и установка пакетов…')"

  if [[ "$PKG_MANAGER" == xbps ]]; then
    sudo xbps-install -Suy || true
    for pkg in "${packages[@]}"; do
      pkg_is_installed "$pkg" && continue
      sudo xbps-install -y -- "$pkg" || PKG_FAILED+=("$pkg")
    done
  else
    # pacman — старая логика (без изменений)
    local noconfirm=()
    ((INTERACTIVE)) || noconfirm=(--noconfirm)
    if ! sudo pacman -Syu --needed "${noconfirm[@]}" "${packages[@]}"; then
      warn "..."
      sudo pacman -Syu --noconfirm || true
      for pkg in "${packages[@]}"; do
        pacman -Q -- "$pkg" &>/dev/null && continue
        sudo pacman -S --needed --noconfirm -- "$pkg" &>/dev/null || PKG_FAILED+=("$pkg")
      done
    fi
  fi

  # Группа input (одинаково для обоих дистро)
  [[ "$DESKTOP_SHELL" == angelos ]] && ! id -nG "$(id -un)" | grep -qw input \
    && sudo usermod -aG input "$(id -un)" || true

  # Bluetooth — Void: runit, Arch: systemd
  if [[ "$DESKTOP_SHELL" == angelos ]] && compgen -G '/sys/class/bluetooth/*' >/dev/null; then
    if [[ "$PKG_MANAGER" == xbps ]]; then
      [[ -e /var/service/bluetoothd ]] \
        || sudo ln -s /etc/sv/bluetoothd /var/service/ 2>/dev/null || true
    else
      ! systemctl is-enabled bluetooth.service &>/dev/null \
        && sudo systemctl enable --now bluetooth.service &>/dev/null || true
    fi
  fi

  # udev-правило для uinput (одинаково — udev есть в обоих дистро)
  local rule=/etc/udev/rules.d/70-angelos-uinput.rules
  if [[ "$DESKTOP_SHELL" == angelos && ! -f "$rule" ]]; then
    printf '# angelOS: the input group makes virtual input devices (mouse-coalesce)\nKERNEL=="uinput", SUBSYSTEM=="misc", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"\n' \
      | sudo tee "$rule" >/dev/null \
      && sudo udevadm control --reload 2>/dev/null \
      && sudo udevadm trigger --name-match=uinput 2>/dev/null || true
  fi
}

step 10 install_packages "packages" "пакеты"
```

---

## 4. Файл `installer/steps/50-sddm.sh` — runit вместо systemd

### 4.1 `sddm_enable()` — полная замена

```bash
sddm_enable() {
  if [[ "$PKG_MANAGER" == xbps ]]; then
    # Void: runit
    # Отключить текущий DM если есть
    for candidate in gdm lightdm ly greetd emptty; do
      if [[ -e "/var/service/$candidate" ]]; then
        say "$(_ "Disabling $candidate" "Отключаю $candidate")"
        sudo rm -f "/var/service/$candidate" || true
      fi
    done
    # Включить SDDM
    [[ -d /etc/sv/sddm ]] || {
      warn "$(_ 'sddm service not found in /etc/sv/' 'Сервис sddm не найден в /etc/sv/')"
      return 0
    }
    [[ -e /var/service/sddm ]] && { say "$(_ 'SDDM already enabled' 'SDDM уже включён')"; return 0; }
    sudo ln -s /etc/sv/sddm /var/service/ || {
      warn "$(_ 'Could not enable SDDM' 'Не удалось включить SDDM')"
      return 0
    }
    SDDM_STATUS=enabled
    say "$(_ 'SDDM will start on the next boot' 'SDDM запустится при следующей загрузке')"
  else
    # Arch/CachyOS: старый код с systemctl (без изменений)
    command -v systemctl &>/dev/null || { warn "..."; return 0; }
    # ... существующий код ...
  fi
}
```

**Важно**: функцию `systemctl set-default graphical.target` на Void пропустить.  
На Void runlevel настраивается иначе — при установке SDDM через xbps он сам добавляет сервис в `/etc/sv/`.

---

## 5. Файл `installer/steps/60-shell.sh` — runit user-сервисы

### 5.1 Текущие сервисы (angelOS запускает 5)

```
niri-game-mode.service      — игровой режим мыши
mouse-coalesce.service      — сглаживание мыши в играх
polkit-agent-guard.service  — агент polkit
voxtype.service             — голосовой ввод
voxtype-indicator.service   — индикатор голосового ввода
```

Юнит-файлы лежат в `.config/systemd/user/` в репозитории.

### 5.2 Создать runit run-скрипты

Добавить директорию `.config/runit/sv/` в репозиторий рядом с `.config/systemd/user/`:

```
.config/runit/sv/
  niri-game-mode/
    run          ← исполняемый, делает exec, НЕ &
  mouse-coalesce/
    run
  polkit-agent-guard/
    run
  voxtype/
    run
  voxtype-indicator/
    run
```

Пример `run`-скрипта (`niri-game-mode/run`):
```bash
#!/bin/sh
exec "$HOME/.local/bin/niri-game-mode" 2>&1
```

**Правило**: `run` ОБЯЗАН делать `exec`, а не запускать процесс в фоне. Иначе runit не отследит PID и перезапустит навсегда.

### 5.3 `enable_services()` — замена на runit

```bash
enable_services() {
  [[ "$ENABLE_SERVICES" == 1 ]] || return 0

  if [[ "$PKG_MANAGER" == xbps ]]; then
    command -v runsvdir &>/dev/null || {
      warn "$(_ 'runsvdir not found; user services not enabled' \
               'runsvdir не найден; user-сервисы не включены')"
      return 0
    }
    local svc_dir="$HOME_DIR/.config/runit/sv"
    local enabled_dir="$HOME_DIR/.local/share/runit/service"
    mkdir -p "$enabled_dir"

    enable_runit_svc() {
      local name="$1" src="$svc_dir/$name"
      [[ -d "$src" ]] || return 0
      chmod +x "$src/run" 2>/dev/null || true
      [[ -L "$enabled_dir/$name" ]] || ln -sfn "$src" "$enabled_dir/$name"
      say "$(_ "service enabled: $name" "сервис включён: $name")"
    }

    enable_runit_svc niri-game-mode
    enable_runit_svc mouse-coalesce
    [[ -d "$svc_dir/polkit-agent-guard" ]] && enable_runit_svc polkit-agent-guard
    if [[ -x "$HOME_DIR/.local/bin/voxtype" ]]; then
      enable_runit_svc voxtype
      enable_runit_svc voxtype-indicator
    fi

    # runsvdir нужно запустить из сессии niri
    local niri_user_cfg="$HOME_DIR/.config/niri/cfg/user.kdl"
    if [[ -f "$niri_user_cfg" ]] && ! grep -q "runsvdir" "$niri_user_cfg"; then
      cat >> "$niri_user_cfg" <<'KDL'

// angelOS runit user services (Void Linux)
spawn-at-startup "runsvdir" { arg "-P"; arg "$HOME/.local/share/runit/service"; }
KDL
      say "$(_ 'Added runsvdir to niri startup' 'runsvdir добавлен в автозапуск niri')"
    fi

  else
    # Arch/CachyOS: старый systemctl --user код (без изменений)
    command -v systemctl &>/dev/null || { warn "..."; return 0; }
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable niri-game-mode.service || true
    systemctl --user enable mouse-coalesce.service || true
    [[ -f "$HOME_DIR/.config/systemd/user/polkit-agent-guard.service" ]] \
      && { systemctl --user enable polkit-agent-guard.service || true; }
    if [[ -x "$HOME_DIR/.local/bin/voxtype" ]]; then
      systemctl --user enable voxtype.service voxtype-indicator.service || true
    fi
  fi
}
```

### 5.4 `install_minimize_hook()` — dropin для niri.service

На Void нет `niri.service` у пользователя — niri стартует напрямую из SDDM.  
`~/.local/bin/niri` (symlink на angel-niri) подхватывается из PATH раньше `/usr/bin/niri`.  
Dropin не нужен.

```bash
install_minimize_hook() {
  # Void: niri стартует не через systemd, dropin не нужен
  [[ "$PKG_MANAGER" == xbps ]] && return 0
  # ... существующий код для Arch ...
}
```

---

## 6. Файл `installer/steps/15-questions.sh` — определение DM

### 6.1 Текущий код (2 места, строки 37 и 147):
```bash
dm="$(basename "$(readlink /etc/systemd/system/display-manager.service 2>/dev/null)" .service 2>/dev/null)"
```

### 6.2 Замена (добавить функцию в начало файла):
```bash
detect_current_dm() {
  if [[ "$PKG_MANAGER" == xbps ]]; then
    local dm=""
    for candidate in gdm lightdm ly greetd emptty sddm; do
      [[ -e "/var/service/$candidate" ]] && { dm="$candidate"; break; }
    done
    echo "$dm"
  else
    basename "$(readlink /etc/systemd/system/display-manager.service 2>/dev/null)" .service 2>/dev/null
  fi
}
```

Заменить оба вхождения на `dm="$(detect_current_dm)"`.

---

## 7. Файл `installer/steps/12-gaming.sh` — Steam на Void

Steam на Void есть только для **glibc** и требует включения `multilib`.  
Скрипт `game-setup.sh` полностью завязан на pacman.

```bash
install_gaming() {
  [[ "$INSTALL_GAMING" == 1 && "$SKIP_PACKAGES" != 1 ]] || return 0
  if [[ "$PKG_MANAGER" == xbps ]]; then
    warn "$(_ 'Gaming setup (game-setup.sh) is Arch-only. Install Steam manually: sudo xbps-install steam' \
             'Игровая настройка (game-setup.sh) только для Arch. Steam вручную: sudo xbps-install steam')"
    return 0
  fi
  # Arch/CachyOS: старый код без изменений
  command -v pacman &>/dev/null || return 0
  local -a run=(env HOME="$HOME_DIR" ANGELOS_LANG="$UI" bash "$ROOT/.config/quickshell/angelos/scripts/game-setup.sh")
  if ((INTERACTIVE)); then "${run[@]}"; else "${run[@]}" </dev/null; fi || warn "..."
}
```

---

## 8. Файл `installer/steps/40-files.sh` — пропустить systemd на Void

В `install_configs()` есть ветка `*.config/systemd/user/*)`. На Void эти файлы бесполезны.

Добавить проверку перед копированием файла (найти цикл по файлам в `install_configs`):
```bash
# Пропустить systemd unit-файлы на Void
if [[ "$PKG_MANAGER" == xbps && "$rel" == .config/systemd/* ]]; then
  ((N_UNCHANGED++)); continue
fi
```

Вместо этого `40-files.sh` должен копировать `.config/runit/sv/` — оно уже будет в репозитории и скопируется автоматически как обычные файлы (не требует специальной обработки).

---

## 9. `scripts/angel-niri-install.sh` — исправить сборку

При fallback на сборку из исходников скрипт делает:
```bash
sudo -n pacman -S --needed --noconfirm rust clang &>/dev/null || return 1
```

**Нужно заменить:**
```bash
if command -v xbps-install &>/dev/null; then
  sudo xbps-install -y rust cargo clang &>/dev/null || return 1
else
  sudo -n pacman -S --needed --noconfirm rust clang &>/dev/null || return 1
fi
```

**Dropin** `~/.config/systemd/user/niri.service.d/angel-niri.conf` — пропустить на Void:
```bash
# В функции, создающей dropin:
if ! command -v xbps-install &>/dev/null; then
  mkdir -p "$(dirname "$DROPIN")"
  printf '[Service]\nExecStart=\nExecStart=%s\n' "$LIB/niri" > "$DROPIN"
fi
```

---

## 10. `packages/void.txt` — полный файл пакетов Void

Создать `packages/void.txt` с именами пакетов Void Linux.  
Полная таблица соответствия (Arch → Void):

| Arch/CachyOS | Void Linux | Примечание |
|---|---|---|
| `niri` | `niri` | ✓ |
| `nautilus` | `nautilus` | ✓ |
| `nautilus-python` | `nautilus-python` | ✓ |
| `eog` | `eog` | ✓ |
| `mpv` | `mpv` | ✓ |
| `neovim` | `neovim` | ✓ |
| `kitty` | `kitty` | ✓ |
| `alacritty` | `alacritty` | ✓ |
| `foot` | `foot` | ✓ |
| `fastfetch` | `fastfetch` | ✓ |
| `fuzzel` | `fuzzel` | ✓ |
| `nwg-displays` | `nwg-displays` | проверить наличие |
| `xwayland-satellite` | `xwayland-satellite` | проверить наличие |
| `xdg-desktop-portal-gnome` | `xdg-desktop-portal-gnome` | ✓ |
| `xdg-desktop-portal-gtk` | `xdg-desktop-portal-gtk` | ✓ |
| `gnome-keyring` | `gnome-keyring` | ✓ |
| `grim` | `grim` | ✓ |
| `slurp` | `slurp` | ✓ |
| `wf-recorder` | `wf-recorder` | ✓ |
| `gpu-screen-recorder` | — | **НЕТ В VOID** — пропустить |
| `wl-clipboard` | `wl-clipboard` | ✓ |
| `wtype` | `wtype` | ✓ |
| `libnotify` | `libnotify` | ✓ |
| `gtk-layer-shell` | `gtk-layer-shell` | ✓ |
| `playerctl` | `playerctl` | ✓ |
| `brightnessctl` | `brightnessctl` | ✓ |
| `cliphist` | `cliphist` | ✓ |
| `tesseract` | `tesseract-ocr` | **ИМЯ ДРУГОЕ** |
| `tesseract-data-eng` | `tesseract-ocr-eng` | **ИМЯ ДРУГОЕ** |
| `translate-shell` | `translate-shell` | ✓ |
| `python` | `python3` | **ИМЯ ДРУГОЕ** |
| `python-cairo` | `python3-cairo` | **ИМЯ ДРУГОЕ** |
| `python-gobject` | `python3-gobject` | **ИМЯ ДРУГОЕ** |
| `pipewire` | `pipewire` | ✓ |
| `pipewire-pulse` | `pipewire-pulse` | ✓ |
| `wireplumber` | `wireplumber` | ✓ |
| `fontconfig` | `fontconfig` | ✓ |
| `noto-fonts` | `noto-fonts-ttf` | **ИМЯ ДРУГОЕ** |
| `noto-fonts-emoji` | `noto-fonts-emoji` | ✓ |
| `noto-fonts-cjk` | `noto-fonts-cjk` | ✓ |
| `ttf-meslo-nerd` | `nerd-fonts` | **ИМЯ ДРУГОЕ** |
| `ttf-dejavu` | `dejavu-fonts-ttf` | **ИМЯ ДРУГОЕ** |
| `ttf-liberation` | `liberation-fonts-ttf` | **ИМЯ ДРУГОЕ** |
| `quickshell` | — | **НЕТ В VOID** — собирать (этап D) |
| `qt6-declarative` | `qt6-declarative` | ✓ |
| `qt6-5compat` | `qt6-5compat` | ✓ |
| `qt6-imageformats` | `qt6-imageformats` | ✓ |
| `appmenu-gtk-module` | — | **НЕТ В VOID** — пропустить |
| `qt6-multimedia` | `qt6-multimedia` | ✓ |
| `qt6-multimedia-ffmpeg` | `qt6-multimedia-ffmpeg` | проверить |
| `qt6-webengine` | `qt6-webengine` | **только glibc Void** |
| `cmake` | `cmake` | ✓ |
| `gcc` | `gcc` | ✓ |
| `pkgconf` | `pkgconf` | ✓ |
| `patch` | `patch` | ✓ |
| `jq` | `jq` | ✓ |
| `networkmanager` | `NetworkManager` | **ИМЯ ДРУГОЕ** |
| `bluez` | `bluez` | ✓ |
| `bluez-utils` | `bluez` | входит в один пакет |
| `python-evdev` | `python3-evdev` | **ИМЯ ДРУГОЕ** |
| `headsetcontrol` | — | **НЕТ В VOID** — собирать вручную или пропустить |
| `socat` | `socat` | ✓ |
| `bubblewrap` | `bubblewrap` | ✓ |
| `python-pillow` | `python3-Pillow` | **ИМЯ ДРУГОЕ** |
| `python-numpy` | `python3-numpy` | **ИМЯ ДРУГОЕ** |
| `hunspell` | `hunspell` | ✓ |
| `cava` | `cava` | ✓ |
| `wlsunset` | `wlsunset` | ✓ |
| `speedtest-cli` | `speedtest-cli` | ✓ |
| `imagemagick` | `ImageMagick` | **ИМЯ ДРУГОЕ** |
| `zenity` | `zenity` | ✓ |
| `librsvg` | `librsvg` | ✓ |
| `pciutils` | `pciutils` | ✓ |
| `qt6ct` | `qt6ct` | ✓ |
| `xsettingsd` | `xsettingsd` | ✓ |
| `hyprpolkitagent` | `polkit-gnome` | **ЗАМЕНА** |
| `flatpak` | `flatpak` | ✓ |
| `xdg-user-dirs` | `xdg-user-dirs` | ✓ |
| `adw-gtk-theme` | — | **НЕТ В VOID** — скачать из GitHub Releases |
| `github-cli` | `github-cli` | ✓ |
| `qrencode` | `qrencode` | ✓ |
| `sddm` | `sddm` | ✓ |
| `fish` | `fish-shell` | **ИМЯ ДРУГОЕ** |
| `fisher` | — | устанавливать через `curl` |
| `fzf` | `fzf` | ✓ |
| `eza` | `eza` | ✓ |
| `bat` | `bat` | ✓ |
| `tealdeer` | `tealdeer` | ✓ |
| `pkgfile` | — | **НЕТ В VOID** — пропустить |
| `expac` | — | **НЕТ В VOID** — пропустить |
| `btop` | `btop` | ✓ |
| `glances` | `glances` | ✓ |
| `duf` | `duf` | ✓ |
| `ncdu` | `ncdu` | ✓ |
| `lsd` | `lsd` | ✓ |
| `ripgrep` | `ripgrep` | ✓ |
| `tree` | `tree` | ✓ |
| `micro` | `micro` | ✓ |
| `less` | `less` | ✓ |
| `man-db` | `man-db` | ✓ |
| `man-pages` | `man-pages` | ✓ |
| `plocate` | `plocate` | проверить наличие |
| `pv` | `pv` | ✓ |
| `rsync` | `rsync` | ✓ |
| `wget` | `wget` | ✓ |
| `unzip` | `unzip` | ✓ |
| `unrar` | `unrar` | ✓ |
| `yt-dlp` | `yt-dlp` | ✓ |
| `ffmpegthumbnailer` | `ffmpegthumbnailer` | ✓ |
| `pavucontrol` | `pavucontrol` | ✓ |
| `helvum` | `helvum` | ✓ |
| `mission-center` | `gnome-system-monitor` | **ЗАМЕНА** |
| `meld` | `meld` | ✓ |
| `scrcpy` | `scrcpy` | ✓ |
| `ark` | `ark` | ✓ |
| `pacman-contrib` | — | **НЕТ В VOID** — пропустить |
| `bash-completion` | `bash-completion` | ✓ |
| `cachyos-fish-config` | — | CachyOS-эксклюзив — пропустить |
| `fish-pure-prompt` | — | через `fisher install pure-fish/pure` |
| `fish-autopair` | — | через `fisher install jorgebucaran/autopair.fish` |

---

## 11. Пакеты без аналога — стратегии

### 11.1 `quickshell` — САМЫЙ КРИТИЧНЫЙ

Quickshell — весь UI angelOS. На Void его нет, нужно собирать.

**Зависимости для сборки на Void:**
```
cmake ninja gcc pkgconf git
qt6-base qt6-declarative qt6-5compat qt6-imageformats
qt6-multimedia qt6-svg qt6-wayland
wayland-devel wayland-protocols
```

**Сборка:**
```bash
git clone https://github.com/quickshell-mirror/quickshell.git /tmp/qs-src
cd /tmp/qs-src
cmake -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr/local \
  -DQUICKSHELL_WEBVIEW=OFF    # OFF если musl или нет qt6-webengine
cmake --build build -j$(nproc)
sudo cmake --install build
```

**Добавить шаг `installer/steps/28-quickshell.sh`:**
```bash
# shellcheck shell=bash
install_quickshell() {
  [[ "$PKG_MANAGER" == xbps ]] || return 0
  command -v qs &>/dev/null && { say "$(_ 'Quickshell already installed' 'Quickshell уже установлен')"; return 0; }
  say "$(_ 'Building Quickshell from source (5-15 min)…' 'Сборка Quickshell из исходников (5-15 мин)…')"

  local webview=ON
  [[ "${VOID_LIBC:-glibc}" == musl ]] && webview=OFF

  sudo xbps-install -y cmake ninja gcc pkgconf git \
    qt6-base qt6-declarative qt6-5compat qt6-imageformats \
    qt6-multimedia qt6-svg qt6-wayland \
    wayland-devel wayland-protocols || {
    warn "$(_ 'Could not install Quickshell build deps' 'Не удалось поставить зависимости Quickshell')"
    return 0
  }
  local src="${XDG_CACHE_HOME:-$HOME_DIR/.cache}/quickshell-src"
  if [[ -d "$src/.git" ]]; then
    git -C "$src" pull --quiet || true
  else
    git clone --quiet https://github.com/quickshell-mirror/quickshell.git "$src" || {
      warn "$(_ 'Could not clone Quickshell' 'Не удалось клонировать Quickshell')"
      return 0
    }
  fi
  cmake -B "$src/build" -G Ninja -S "$src" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DQUICKSHELL_WEBVIEW="$webview" || { warn "Quickshell: cmake failed"; return 0; }
  cmake --build "$src/build" -j"$(nproc)" || { warn "Quickshell: build failed"; return 0; }
  sudo cmake --install "$src/build" || { warn "Quickshell: install failed"; return 0; }
  say "$(_ 'Quickshell installed to /usr/local' 'Quickshell установлен в /usr/local')"
}
step 28 install_quickshell "Quickshell" "Quickshell"
```

### 11.2 `adw-gtk-theme` — GitHub Releases

```bash
install_adw_theme() {
  [[ "$PKG_MANAGER" == xbps ]] || return 0
  [[ -d /usr/share/themes/adw-gtk3 || -d "$HOME_DIR/.local/share/themes/adw-gtk3" ]] && return 0
  say "$(_ 'Downloading adw-gtk3 theme…' 'Скачиваю тему adw-gtk3…')"
  local tag url
  tag=$(curl -sL https://api.github.com/repos/lassekongo83/adw-gtk3/releases/latest \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])' 2>/dev/null) || return 0
  url="https://github.com/lassekongo83/adw-gtk3/releases/download/$tag/adw-gtk3-$tag.tar.xz"
  mkdir -p "$HOME_DIR/.local/share/themes"
  curl -L "$url" | tar -xJ -C "$HOME_DIR/.local/share/themes/" 2>/dev/null \
    && say "$(_ 'adw-gtk3 theme installed to ~/.local/share/themes/' 'Тема adw-gtk3 установлена в ~/.local/share/themes/')" \
    || warn "$(_ 'Could not download adw-gtk3 theme' 'Не удалось скачать тему adw-gtk3')"
}
```

### 11.3 `hyprpolkitagent` → `polkit-gnome`

На Void используется `polkit-gnome`. Бинарник:  
`/usr/libexec/polkit-gnome-authentication-agent-1` (путь может отличаться, проверить в Void).

Нужно обновить:
1. `packages/void.txt` — добавить `polkit-gnome`
2. `.local/bin/polkit-agent-guard` — добавить поиск gnome-агента:
```bash
# Искать в таком порядке:
for agent in \
  /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 \
  /usr/libexec/polkit-gnome-authentication-agent-1 \
  /usr/bin/hyprpolkitagent; do
  [[ -x "$agent" ]] && exec "$agent" "$@"
done
```
3. `runit/sv/polkit-agent-guard/run` — аналогично.

### 11.4 `gpu-screen-recorder`

Пропустить. Функция мгновенного повтора (instant replay) будет недоступна на Void до появления пакета в репозитории. `wf-recorder` остаётся как основной инструмент записи.

### 11.5 `headsetcontrol`

Собирать из исходников или пропустить:
```bash
# Зависимости: cmake, hidapi-devel
git clone https://github.com/nicola02nb/HeadsetControl.git /tmp/headsetcontrol
cd /tmp/headsetcontrol && cmake -B build && cmake --build build && sudo cmake --install build
```

---

## 12. glibc vs musl Void — критические различия

| Компонент | glibc Void | musl Void |
|---|---|---|
| Prebuilt angel-niri | ✓ работает | ✗ не запустится |
| Quickshell без WebEngine | ✓ | ✓ (флаг -DQUICKSHELL_WEBVIEW=OFF) |
| Quickshell с WebEngine | ✓ | ✗ (QtWebEngine не компилируется на musl) |
| Steam | ✓ (с multilib) | ✗ |
| Voxtype (prebuilt) | ✓ | ✗ (нужна пересборка) |
| adw-gtk-theme | ✓ | ✓ |

**Вывод**: Для полного опыта angelOS — **только glibc Void**.

Определить вариант в установщике (добавить в `install.sh` после `detect_pkg_manager`):
```bash
VOID_LIBC=""
if [[ "$PKG_MANAGER" == xbps ]]; then
  ldd --version 2>&1 | grep -qi musl && VOID_LIBC=musl || VOID_LIBC=glibc
  if [[ "$VOID_LIBC" == musl ]]; then
    warn "$(_ 'musl Void Linux: angel-niri prebuilt and Steam will not work; Quickshell will be built without WebEngine' \
             'musl Void Linux: prebuilt angel-niri и Steam не работают; Quickshell будет собран без WebEngine')"
  fi
fi
```

---

## 13. `installer/steps/70-finish.sh` — проверка DM

В `70-finish.sh` есть:
```bash
if systemctl is-enabled display-manager.service &>/dev/null; then
```

На Void заменить:
```bash
if { [[ "$PKG_MANAGER" == xbps ]] && [[ -e /var/service/sddm ]]; } \
   || { [[ "$PKG_MANAGER" != xbps ]] && systemctl is-enabled display-manager.service &>/dev/null; }; then
```

---

## 14. Тестирование

### Быстрый тест конфигов (без пакетов)
```bash
docker run -it --rm voidlinux/voidlinux bash -c "
  xbps-install -Suy
  xbps-install -y git bash sudo python3
  git clone <repo> /tmp/dots && cd /tmp/dots
  SKIP_PACKAGES=1 DOTFILES_FORCE_DISTRO=1 bash install.sh
"
```

### Проверка маппинга пакетов
```bash
while IFS= read -r pkg; do
  [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue
  xbps-query -Rs "^${pkg}$" 2>/dev/null | grep -q "^\[" \
    && echo "✓ $pkg" || echo "✗ MISSING: $pkg"
done < packages/void.txt
```

### Проверка runit run-скриптов
```bash
# run-скрипт обязан делать exec, иначе runit зациклится:
head -3 .config/runit/sv/*/run | grep -v exec && echo "WARN: missing exec"
```

---

## 15. Порядок реализации (чеклист)

### Этап A — Минимум для запуска конфигов без пакетов
- [ ] `installer/steps/05-distro.sh` — добавить `void` в whitelist
- [ ] `installer/lib/pkg.sh` — создать файл с абстракцией `PKG_MANAGER`
- [ ] `install.sh` — source `lib/pkg.sh`, вызвать `detect_pkg_manager()`
- [ ] `installer/lib/core.sh` — убрать `command -v pacman` из `preflight()`
- [ ] **Тест**: `SKIP_PACKAGES=1 DOTFILES_FORCE_DISTRO=1 bash install.sh`

### Этап B — Установка пакетов
- [ ] `packages/void.txt` — создать (маппинг из раздела 10)
- [ ] `installer/steps/30-packages.sh` — заменить все `pacman` на `pkg_*`
- [ ] `installer/steps/12-gaming.sh` — заглушка для Void

### Этап C — Сервисы и DM
- [ ] `.config/runit/sv/*/run` — создать run-скрипты для 5 сервисов
- [ ] `installer/steps/60-shell.sh` — runit в `enable_services()`
- [ ] `installer/steps/50-sddm.sh` — runit в `sddm_enable()`
- [ ] `installer/steps/15-questions.sh` — `detect_current_dm()` (2 места)
- [ ] `installer/steps/70-finish.sh` — проверка DM для Void

### Этап D — Сборка отсутствующих пакетов
- [ ] `installer/steps/28-quickshell.sh` — создать шаг сборки Quickshell
- [ ] adw-gtk-theme — функция скачивания из GitHub Releases (в `40-files.sh` или отдельный шаг)
- [ ] `packages/void.txt` — `hyprpolkitagent` → `polkit-gnome`
- [ ] `.local/bin/polkit-agent-guard` — поддержка gnome-агента
- [ ] `VOID_LIBC` — определение glibc/musl в `install.sh`

### Этап E — Финальные исправления
- [ ] `scripts/angel-niri-install.sh` — заменить `pacman -S rust clang` на `xbps-install`
- [ ] `scripts/angel-niri-install.sh` — пропустить dropin на Void
- [ ] `installer/steps/40-files.sh` — пропустить `.config/systemd/` на Void
- [ ] **Тест**: полный прогон в Docker (glibc Void)

---

## 16. Файлы, которые НЕ нужно менять

- `installer/steps/35-voxtype.sh` — Voxtype скачивается бинарником, glibc-совместим
- `installer/steps/45-devices.sh` — udev одинаков в Void и Arch
- `installer/steps/25-wallpapers.sh` — curl/wget, универсально
- `installer/steps/20-apps-choice.sh` — логика выбора, универсально
- `installer/lib/show.sh`, `lib/tui.sh` — TUI-инфраструктура
- `installer/steps/75-author.sh` — GitHub CLI
- `.config/niri/` — конфиги niri одинаковы
- `.config/fish/`, `.config/nvim/`, `.config/kitty/` и все остальные dotfiles
- `.local/bin/*` — скрипты универсальны (кроме `polkit-agent-guard`)
