# shellcheck shell=bash
# angelOS installer — sourced by install.sh in name order (see installer/README.md)

install_quickshell() {
  [[ "$PKG_MANAGER" == xbps ]] || return 0
  command -v qs &>/dev/null && { say "$(_ 'Quickshell already installed' 'Quickshell уже установлен')"; return 0; }
  say "$(_ 'Building Quickshell from source (5-15 min)…' 'Сборка Quickshell из исходников (5-15 мин)…')"

  local webview=ON
  [[ "${VOID_LIBC:-glibc}" == musl ]] && webview=OFF

  sudo xbps-install -y cmake ninja gcc pkgconf git \
    qt6-base-devel qt6-declarative-devel qt6-declarative-private-devel \
    qt6-shadertools-devel qt6-qt5compat-devel qt6-wayland-devel qt6-svg-devel \
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

step 14 install_quickshell "Quickshell" "Quickshell"
