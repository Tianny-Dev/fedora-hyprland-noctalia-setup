#!/usr/bin/env bash
#
# fedora-hyprland-noctalia-setup.sh
#
# Post-install automation for: Fedora (minimal) -> Hyprland + Noctalia Shell + Noctalia Greeter
# Companion script to fedora-minimal-hyprland-noctalia-setup.md — run this AFTER:
#   1. Installing Fedora from the Everything ISO with "Minimal Install" selected
#   2. First boot + `sudo dnf update -y && sudo reboot`
#
# Stack installed at the end:
#   - Hyprland          — the Wayland compositor, via the community
#                          lionheartp/Hyprland Copr (a fork of solopasha/hyprland
#                          that also packages Noctalia Shell + a meta package):
#                          https://copr.fedorainfracloud.org/coprs/lionheartp/Hyprland
#   - Noctalia Shell    — the bar/launcher/panels    (same Copr, or Fedora's
#                          default repos on 44+ — your choice at install time)
#   - Noctalia Greeter  — the greetd-based login screen (Fedora: Terra, noctalia-greeter)
#     https://docs.noctalia.dev
#
# Usage:
#   chmod +x fedora-hyprland-noctalia-setup.sh
#   ./fedora-hyprland-noctalia-setup.sh
#
#   Env vars (optional):
#     ASSUME_YES=1   Auto-answer "yes" to every prompt (unattended / reruns)
#
# Do NOT run this with sudo directly — it caches sudo itself and calls it
# only where needed (mirrors the pattern used by the XeroDora installer).
#
# What this script does NOT do (must be done by hand, they're inherently
# interactive/risky):
#   - The Fedora installer itself (ISO, partitioning, user creation)
#   - NVIDIA + Secure Boot MOK enrollment (needs a password + a reboot-time
#     screen you have to physically confirm) — the script does everything
#     up to that point and prints the exact remaining steps
#   - The script WILL disable your current display manager and enable greetd
#     for you (with a confirmation prompt) — keep a TTY or root shell handy
#     the first time you reboot, per Noctalia Greeter's own docs

set -uo pipefail

# ── Colours / small helpers ───────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

step()    { echo -e "${BLUE}➜${NC} ${CYAN}$1${NC}"; }
ok()      { echo -e "${GREEN}✓${NC} $1"; }
warn()    { echo -e "${YELLOW}⚠${NC} $1"; SKIPPED+=("$1"); }
err()     { echo -e "${RED}✗${NC} $1"; }
phase()   { echo ""; echo -e "${CYAN}════════════════════════════════════════════${NC}"; echo -e "${CYAN}▶ $1${NC}"; echo -e "${CYAN}════════════════════════════════════════════${NC}"; }

# Collected across the run so show_completion can print a recap.
SKIPPED=()
# Set to 1 once the Terra repo is successfully enabled. Noctalia Greeter and
# (optionally) Ghostty key off this on Fedora. Hyprland itself comes from the
# separate lionheartp/Hyprland Copr, not Terra.
TERRA_ENABLED=0
HYPRLAND_COPR_ENABLED=0

ask_yn() { # ask_yn "question" -> returns 0 for yes
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    echo -e "${GREEN}$1 ${NC}[auto-yes]"
    return 0
  fi
  local reply
  read -r -p "$(echo -e "${GREEN}$1 ${NC}[${GREEN}y${NC}/${RED}N${NC}]: ")" -n 1 reply </dev/tty
  echo ""
  [[ "$reply" =~ ^[Yy]$ ]]
}

SUDO_KEEPALIVE_PID=""
cleanup() { [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true; }
trap cleanup EXIT

setup_sudo() {
  if [[ ${EUID:-0} -eq 0 ]]; then
    err "Don't run this as root/with sudo. Run it as your normal user: ./fedora-hyprland-noctalia-setup.sh"
    exit 1
  fi
  step "Caching sudo credentials..."
  sudo -v || { err "sudo auth failed."; exit 1; }
  ( while true; do sleep 50; sudo -n true 2>/dev/null; done ) &
  SUDO_KEEPALIVE_PID=$!
}

setup_logging() {
  local logfile="$HOME/fedora-hyprland-noctalia-setup.log"
  exec > >(tee -a "$logfile") 2>&1
  step "Logging full output to $logfile"
}

check_fedora() {
  [[ -r /etc/os-release ]] || { err "/etc/os-release missing — not Fedora?"; exit 1; }
  . /etc/os-release
  if [[ "${ID:-}" != "fedora" ]]; then
    err "This is not Fedora (ID=${ID:-unknown}). Aborting."
    exit 1
  fi
  FEDORA_VER="$(rpm -E %fedora)"
  ok "Fedora ${FEDORA_VER} detected."
}

# install <name-for-log> pkg1 pkg2 ... — continues on individual failures
install() {
  local label="$1"; shift
  step "[$label] Installing: $*"
  if sudo dnf install -y "$@"; then
    ok "[$label] done"
  else
    warn "[$label] bulk install failed — retrying package-by-package"
    local failed=()
    for p in "$@"; do
      sudo dnf install -y "$p" || failed+=("$p")
    done
    [[ ${#failed[@]} -gt 0 ]] && warn "[$label] skipped: ${failed[*]}"
  fi
}

# ─────────────────────────────────────────────────────────────────────────
prompt_intro() {
  clear
  echo -e "${CYAN}Fedora minimal → Hyprland + Noctalia Shell setup${NC}"
  echo ""
  echo "This will:"
  echo "  • tune dnf, enable RPM Fusion (+ optional Terra)"
  echo "  • install polkit + a lightweight auth agent"
  echo "  • install NetworkManager, PipeWire, Bluetooth, XDG portals, keyring"
  echo "  • detect and set up your GPU driver (Intel/AMD/NVIDIA)"
  echo "  • install codecs + hardware video acceleration"
  echo "  • install Thunar + gvfs-smb + thumbnailers + an image viewer"
  echo "  • install daily CLI tools, fonts (incl. a Nerd Font for Noctalia Shell's bar icons), flatpak"
  echo "  • optionally install tealdeer (tldr)"
  echo "  • optionally set up fastfetch config (default or your GitHub config+logo)"
  echo "  • optionally install Chrome and/or Brave (Firefox is installed by default)"
  echo "  • set up zram swap and local network discovery (mDNS/avahi)"
  echo "  • optionally set up zsh + Oh My Zsh with fish-like plugins (autosuggestions, syntax-highlighting, fzf-tab)"
  echo "  • optionally install dev tools: build essentials, mise (node/python/go/rust), VS Code"
  echo "  • optionally install Neovim + LazyVim, and lazygit (via COPR)"
  echo "  • optionally install JetBrains Toolbox (downloaded + checksum-verified to ~/Applications)"
  echo "  • optionally install containers + VMs: Docker CE (Sail-ready), QEMU/KVM + virt-manager"
  echo "  • optionally install android-tools (adb/fastboot, for Expo/React Native)"
  echo "  • optionally install PHP 8.5 + Composer + the Laravel installer (via php.new), plus a 'sail' zsh alias"
  echo "  • choose a terminal emulator (Alacritty and/or Ghostty)"
  echo "  • optionally install raster/photo design apps: GIMP, Krita, RawTherapee"
  echo "  • apply a few small system tweaks (hostname, AppImage support, etc.)"
  echo "  • finally, install Hyprland (compositor, via the lionheartp/Hyprland Copr), Noctalia Shell, and Noctalia Greeter"
  echo "    (the Greeter requires the Terra repo on Fedora — enabled automatically at that step if needed)"
  echo ""
  ask_yn "Proceed?" || { warn "Cancelled by user."; exit 0; }
}

tune_dnf() {
  phase "Tuning dnf"
  sudo touch /etc/dnf/dnf.conf
  for kv in "max_parallel_downloads=10" "fastestmirror=True" "defaultyes=True" "keepcache=False"; do
    key="${kv%%=*}"
    if sudo grep -q "^${key}=" /etc/dnf/dnf.conf 2>/dev/null; then
      sudo sed -i "s|^${key}=.*|${kv}|" /etc/dnf/dnf.conf
    else
      echo "$kv" | sudo tee -a /etc/dnf/dnf.conf >/dev/null
    fi
  done
  # dnf5 is the default toolchain on modern Fedora; config-manager / some
  # group operations need the plugins package explicitly on a minimal image.
  install "dnf5 plugins" dnf5-plugins
  ok "dnf tuned."
}

enable_rpmfusion() {
  phase "RPM Fusion + system update"
  sudo dnf install -y \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VER}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VER}.noarch.rpm" \
    || { err "RPM Fusion enable failed."; exit 1; }
  sudo dnf group upgrade -y core || true
  sudo dnf upgrade --refresh -y || warn "system upgrade had errors — continuing"
  sudo dnf install -y rpmfusion-free-appstream-data rpmfusion-nonfree-appstream-data || true
  ok "RPM Fusion enabled and system updated."
}

enable_terra() {
  phase "Terra repo (optional)"
  ask_yn "Enable the Terra repo now (Fyra Labs — extra packages beyond Fedora/RPM Fusion; also required later for Noctalia Greeter, and optionally Ghostty)?" || { warn "Skipped Terra repo for now — it will be enabled automatically later if Noctalia Greeter needs it."; return; }
  do_enable_terra
}

# Actual enable logic, shared between the optional early step and the
# mandatory late one (Noctalia Greeter can't be skipped past Terra).
do_enable_terra() {
  # shellcheck disable=SC2016
  sudo dnf install -y --nogpgcheck --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' terra-release terra-gpg-keys \
    && sudo dnf makecache --repo terra \
    && { TERRA_ENABLED=1; ok "Terra enabled."; return 0; }
  warn "Terra repo install failed."
  return 1
}

setup_polkit() {
  phase "Polkit / pkexec"
  install "polkit" polkit
  pkexec --version || warn "pkexec not responding — check the polkit install."
  install "polkit agent" xfce-polkit
  ok "polkit + xfce-polkit agent installed."
  warn "Remember: once Hyprland is installed (final step), add 'exec-once = xfce-polkit' to ~/.config/hypr/hyprland.conf — unless Noctalia Shell already registers its own polkit agent (test first)."
}

core_system() {
  phase "Core system packages"
  install "core" which wget pciutils usbutils linux-firmware xdg-user-dirs fuse-libs
  xdg-user-dirs-update
  install "network" NetworkManager NetworkManager-wifi
  sudo systemctl enable --now NetworkManager
  nmcli device status || true
}

setup_network_discovery() {
  phase "Local network discovery (mDNS / Avahi)"
  ask_yn "Set up Avahi/mDNS (needed for reliable SMB browsing, local hostname discovery, casting, etc.)?" || { warn "Skipped Avahi/mDNS setup."; return; }
  install "avahi" avahi nss-mdns
  sudo systemctl enable --now avahi-daemon
  if ask_yn "Move the default firewalld zone to 'home' (trusts your LAN — only do this on a personal network)?"; then
    sudo firewall-cmd --set-default-zone=home && ok "Default firewalld zone set to home." \
      || warn "Failed to change firewalld zone."
  fi
}

setup_zram() {
  phase "zram swap"
  ask_yn "Set up zram-backed swap (compressed RAM swap — recommended, especially on lower-RAM machines)?" || { warn "Skipped zram."; return; }
  install "zram" zram-generator
  sudo tee /etc/systemd/zram-generator.conf >/dev/null <<'EOF'
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
EOF
  sudo systemctl daemon-reload
  sudo systemctl start systemd-zram-setup@zram0.service || warn "zram0 service didn't start — check 'systemctl status systemd-zram-setup@zram0.service' after reboot."
  ok "zram swap configured (see /etc/systemd/zram-generator.conf)."
}

setup_graphics() {
  phase "Graphics drivers"
  install "mesa" mesa-dri-drivers mesa-vulkan-drivers mesa-libGL mesa-demos vulkan-tools

  local gpu_info
  gpu_info="$(lspci | grep -Ei 'vga|3d|display' || true)"
  echo -e "${CYAN}Detected GPU(s):${NC}\n$gpu_info"

  if echo "$gpu_info" | grep -qi nvidia; then
    warn "NVIDIA GPU detected."
    local sb_state
    sb_state="$(mokutil --sb-state 2>/dev/null || echo 'mokutil not available')"
    echo "Secure Boot state: $sb_state"

    echo ""
    echo "NVIDIA kernel module options:"
    echo "  1) Open kernel modules  (akmod-nvidia-open — recommended for Turing/RTX 20-series and newer)"
    echo "  2) Proprietary modules  (akmod-nvidia — required for Pascal/GTX 10-series and older)"
    echo "  3) Skip NVIDIA driver install"
    read -r -p "Choice [1]: " nv_choice </dev/tty
    local nvpkg="akmod-nvidia-open"
    case "${nv_choice:-1}" in
      2) nvpkg="akmod-nvidia" ;;
      3) nvpkg="" ;;
      *) nvpkg="akmod-nvidia-open" ;;
    esac

    if [[ -n "$nvpkg" ]]; then
      install "nvidia" "$nvpkg" xorg-x11-drv-nvidia-cuda
      if echo "$sb_state" | grep -qi "SecureBoot enabled"; then
        warn "Secure Boot is ON. The akmod won't load until you sign + enroll a MOK key."
        install "mok tools" kmodtool akmods mokutil openssl
        sudo kmodgenca -a || warn "kmodgenca reported an issue — check output above (may need --force if a key already exists)."
        echo ""
        echo -e "${YELLOW}ACTION NEEDED (can't be scripted — needs your input + a reboot):${NC}"
        echo "  1. Run:  sudo mokutil --import /etc/pki/akmods/certs/public_key.der"
        echo "     (it will ask you to set a one-time password — remember it)"
        echo "  2. Reboot. On the blue MOK Manager screen: Enroll MOK -> Continue -> Yes -> enter that password"
        echo "  3. After it reboots back in, confirm the driver built: modinfo -F version nvidia"
      else
        echo "Secure Boot is off — the akmod should build and load on its own (~5 min, check with: modinfo -F version nvidia)."
      fi
    else
      warn "Skipped NVIDIA driver install by choice."
    fi
  fi

  # VA-API / VDPAU hardware video acceleration
  install "va-api base" ffmpeg-libs libva libva-utils
  if echo "$gpu_info" | grep -qi intel; then
    sudo dnf swap -y libva-intel-media-driver intel-media-driver --allowerasing || warn "intel-media-driver swap failed"
  fi
  if echo "$gpu_info" | grep -qi -E 'amd|radeon'; then
    install "amd va-api/vdpau" mesa-va-drivers-freeworld mesa-vdpau-drivers-freeworld
  fi
}

setup_audio() {
  phase "Audio (PipeWire)"
  sudo dnf group upgrade -y multimedia --exclude=PackageKit-gstreamer-plugin || true
  install "pipewire" pipewire pipewire-pulseaudio pipewire-alsa wireplumber alsa-sof-firmware
  systemctl --user enable --now pipewire pipewire-pulse wireplumber || warn "user audio services may need a fresh login session to start"
}

setup_codecs() {
  phase "Multimedia codecs"
  sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing || warn "ffmpeg swap failed"
  sudo dnf group install -y multimedia --setopt="install_weak_deps=False" --exclude=PackageKit-gstreamer-plugin || true
  sudo dnf group install -y sound-and-video || true
  install "gstreamer" \
    gstreamer1-plugins-base gstreamer1-plugins-good gstreamer1-plugins-good-extras \
    gstreamer1-plugins-bad-free gstreamer1-plugins-bad-free-extras \
    gstreamer1-plugins-bad-freeworld gstreamer1-plugins-ugly-free gstreamer1-plugins-ugly \
    gstreamer1-plugin-openh264 gstreamer1-libav libavcodec-freeworld lame lame-libs

  if ask_yn "Install OpenH264 for Firefox too?"; then
    install "openh264" openh264 mozilla-openh264
    sudo dnf config-manager setopt fedora-cisco-openh264.enabled=1 || warn "Could not enable fedora-cisco-openh264 repo — enable it manually if Firefox H264 playback fails."
    echo "Remember to enable the OpenH264 plugin inside Firefox: Settings -> General -> DRM Content."
  else
    warn "Skipped OpenH264 for Firefox."
  fi
}

setup_bluetooth() {
  phase "Bluetooth"
  install "bluetooth" bluez blueman
  sudo systemctl enable --now bluetooth
  sudo rfkill unblock bluetooth 2>/dev/null || true
}

setup_portals_keyring() {
  phase "XDG portals + keyring"
  install "portals" xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-wlr
  mkdir -p ~/.config/xdg-desktop-portal
  cat > ~/.config/xdg-desktop-portal/portal.conf <<'EOF'
[preferred]
default=gtk
org.freedesktop.impl.portal.Screenshot=wlr
org.freedesktop.impl.portal.ScreenCast=wlr
org.freedesktop.impl.portal.Secret=gnome-keyring
EOF
  install "keyring" gnome-keyring gnome-keyring-pam seahorse
  ok "Portal config written to ~/.config/xdg-desktop-portal/portal.conf"
  warn "Note: xdg-desktop-portal-hyprland (installed alongside Hyprland in the final step) is the recommended screenshot/screen-share backend for Hyprland specifically — if screen sharing is flaky with the wlr portal above, switch org.freedesktop.impl.portal.Screenshot/ScreenCast in this file to 'hyprland' instead of 'wlr'."
}

setup_power() {
  phase "Power management"
  ask_yn "Is this a laptop? (installs power-profiles-daemon, brightnessctl, thermald)" || { warn "Skipped laptop power tools."; return; }
  install "power" power-profiles-daemon brightnessctl thermald
  sudo systemctl enable --now power-profiles-daemon thermald || true
}

setup_file_manager() {
  phase "File manager + graphics-team collaboration tools"
  install "thunar stack" thunar thunar-volman thunar-archive-plugin \
    tumbler ffmpegthumbnailer raw-thumbnailer \
    gvfs gvfs-mtp gvfs-gphoto2 gvfs-smb xarchiver xdg-utils

  xdg-mime default thunar.desktop inode/directory 2>/dev/null \
    && ok "Thunar set as the default handler for folders." \
    || warn "Could not set Thunar as default folder handler — set it manually later if needed."

  echo ""
  echo "Image viewer options:"
  echo "  1) Gwenview  (recommended — RAW support, fast review; DMS already needs Qt, so no extra weight)"
  echo "  2) qimgv     (lightweight GTK option)"
  echo "  3) imv       (lightest — Wayland-native, no toolkit overhead)"
  echo "  4) Skip"
  read -r -p "Choice [1]: " choice </dev/tty
  case "${choice:-1}" in
    2) install "image viewer" qimgv ;;
    3) install "image viewer" imv ;;
    4) warn "Skipped image viewer." ;;
    *) install "image viewer" gwenview ;;
  esac

  if ask_yn "Also install Dolphin (heavier, better previews for design file thumbnails like .psd)?"; then
    install "dolphin" dolphin
  else
    warn "Skipped Dolphin."
  fi
}

setup_daily_utils() {
  phase "Daily utilities"
  install "base utils" firefox playerctl grim slurp wl-clipboard cliphist \
    btop htop ncdu fastfetch ripgrep fzf fd-find unzip zip trash-cli

  install "cli quality-of-life" bat eza zoxide tmux duf
  install "archives" p7zip p7zip-plugins unrar zstd
  install "cross-platform mounts" ntfs-3g exfatprogs dosfstools cifs-utils nfs-utils sshfs
  install "disk health/backup" smartmontools timeshift
  install "system info" inxi lm_sensors
  install "gparted" gparted

  install "fonts" google-noto-sans-fonts google-noto-emoji-color-fonts jetbrains-mono-fonts \
    fontawesome-fonts fira-code-fonts adobe-source-sans-pro-fonts adobe-source-code-pro-fonts
  fc-cache -fv >/dev/null

  install "flatpak" flatpak
  flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true

  if ask_yn "Add a fastfetch-on-terminal-launch hook to ~/.bashrc?"; then
    if ! grep -qF "clear && fastfetch" ~/.bashrc 2>/dev/null; then
      printf '\n%s\n%s\n' "# Fastfetch on terminal start" "clear && fastfetch" >> ~/.bashrc
      ok "Hook added to ~/.bashrc"
    else
      ok "Hook already present."
    fi
  else
    warn "Skipped fastfetch shell hook."
  fi
}

setup_terminal() {
  phase "Terminal emulator"
  echo "Terminal options:"
  echo "  1) Alacritty  (GPU-accelerated, in Fedora's default repos)"
  echo "  2) Ghostty    (fast, native, modern config — via Terra if enabled, else its own Copr)"
  echo "  3) Both"
  echo "  4) Skip"
  read -r -p "Choice [1]: " term_choice </dev/tty
  case "${term_choice:-1}" in
    2) install_ghostty ;;
    3) install "alacritty" alacritty; install_ghostty ;;
    4) warn "Skipped terminal emulator install — pick one later, e.g. 'sudo dnf install alacritty'." ;;
    *) install "alacritty" alacritty ;;
  esac
}

install_ghostty() {
  if [[ "$TERRA_ENABLED" == "1" ]]; then
    install "ghostty (Terra)" ghostty
  else
    step "Terra isn't enabled yet — using the scottames/ghostty Copr for Ghostty instead."
    sudo dnf copr enable -y scottames/ghostty || { warn "Failed to enable scottames/ghostty Copr — skipping Ghostty."; return; }
    install "ghostty (Copr)" ghostty
  fi
}

setup_tealdeer() {
  phase "tealdeer (tldr)"
  ask_yn "Install tealdeer (fast tldr client — quick command examples/cheatsheets)?" || { warn "Skipped tealdeer."; return; }
  install "tealdeer" tealdeer
  step "Fetching tldr page cache..."
  tldr --update && ok "tealdeer installed, cache populated. Try: tldr tar" || warn "tldr --update failed — run it manually later."
}

setup_fastfetch_config() {
  phase "fastfetch config"
  ask_yn "Generate the default fastfetch config (fastfetch --gen-config — safe, won't overwrite an existing one)?" && {
    fastfetch --gen-config \
      && ok "Default config generated at ~/.config/fastfetch/config.jsonc" \
      || warn "fastfetch --gen-config failed."
  } || warn "Skipped default fastfetch config generation."

  ask_yn "Download your custom fastfetch config + logo from github.com/Tianny-Dev/fastfetch-config instead?" && {
    mkdir -p "$HOME/.config/fastfetch"

    if [[ -f "$HOME/.config/fastfetch/config.jsonc" ]]; then
      local backup_suffix
      backup_suffix="$(date +%Y%m%d%H%M%S)"
      cp "$HOME/.config/fastfetch/config.jsonc" "$HOME/.config/fastfetch/config.jsonc.bak.${backup_suffix}"
      warn "Existing config backed up to config.jsonc.bak.${backup_suffix}"
    fi

    if curl -fsSL -o "$HOME/.config/fastfetch/config.jsonc" \
        "https://raw.githubusercontent.com/Tianny-Dev/fastfetch-config/main/config.jsonc"; then
      ok "Custom config downloaded to ~/.config/fastfetch/config.jsonc"
    else
      warn "Failed to download config.jsonc — check the filename/branch in the repo matches this URL."
    fi

    if curl -fsSL -o "$HOME/.config/fastfetch/logo.png" \
        "https://raw.githubusercontent.com/Tianny-Dev/fastfetch-config/main/logo.png"; then
      ok "Logo downloaded to ~/.config/fastfetch/logo.png"
    else
      warn "Failed to download logo.png — check the filename in the repo matches this URL (this script assumed 'logo.png')."
    fi
  } || warn "Skipped custom fastfetch config download."
}

setup_browsers() {
  phase "Additional browsers"
  ask_yn "Install Google Chrome?" && {
    install "google chrome" https://dl.google.com/linux/direct/google-chrome-stable_current_x86_64.rpm
    ok "Chrome installed (its own repo was registered automatically for future updates)."
  } || warn "Skipped Google Chrome."

  ask_yn "Install Brave Browser?" && {
    step "Running Brave's official install script..."
    curl -fsS https://dl.brave.com/install.sh | sh \
      && ok "Brave installed." \
      || warn "Brave install script failed."
  } || warn "Skipped Brave Browser."
}

setup_zsh() {
  phase "Zsh + Oh My Zsh (fish-like, CachyOS-style)"
  ask_yn "Install zsh + Oh My Zsh with autosuggestions/syntax-highlighting/fzf-tab (fish-like completion, like CachyOS's default)?" || { warn "Skipped zsh/Oh My Zsh."; return; }

  install "zsh" zsh util-linux-user
  install "git (required by Oh My Zsh installer + plugin clones)" git

  if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
    step "Installing Oh My Zsh (unattended)..."
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c \
      "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
      || { warn "Oh My Zsh install script failed."; return; }
  else
    ok "Oh My Zsh already installed."
  fi

  local zsh_custom="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
  local -A plugin_repos=(
    [zsh-autosuggestions]="https://github.com/zsh-users/zsh-autosuggestions"
    [zsh-syntax-highlighting]="https://github.com/zsh-users/zsh-syntax-highlighting.git"
    [zsh-completions]="https://github.com/zsh-users/zsh-completions"
    [fzf-tab]="https://github.com/Aloxaf/fzf-tab"
  )
  for plugin in "${!plugin_repos[@]}"; do
    local dest="$zsh_custom/plugins/$plugin"
    if [[ -d "$dest" ]]; then
      ok "$plugin already present."
    else
      step "Cloning $plugin..."
      git clone --depth=1 "${plugin_repos[$plugin]}" "$dest" 2>/dev/null \
        && ok "$plugin cloned." \
        || warn "Failed to clone $plugin — plugin skipped."
    fi
  done

  [[ -f "$HOME/.zshrc" ]] || cp "$HOME/.oh-my-zsh/templates/zshrc.zsh-template" "$HOME/.zshrc"

  # Fish-like plugin set: autosuggestions + syntax-highlighting are the big two;
  # fzf-tab gives fish-style fuzzy tab-completion menus; sudo/extract are QoL.
  # NOTE: syntax-highlighting must be the LAST plugin loaded, per its own docs.
  local plugin_line='plugins=(git sudo colored-man-pages extract history-substring-search zsh-completions fzf-tab zsh-autosuggestions zsh-syntax-highlighting)'
  if grep -q '^plugins=' "$HOME/.zshrc"; then
    sed -i "s|^plugins=.*|$plugin_line|" "$HOME/.zshrc"
  else
    echo "$plugin_line" >> "$HOME/.zshrc"
  fi
  ok "Plugin list set in ~/.zshrc."

  # Fish-like QoL: history substring search on up/down, and reuse the CLI
  # replacements already installed (eza/bat/zoxide) as aliases.
  if ! grep -qF '# fedora-hyprland-noctalia-setup: zsh QoL block' "$HOME/.zshrc"; then
    cat >> "$HOME/.zshrc" <<'EOF'

# fedora-hyprland-noctalia-setup: zsh QoL block
bindkey '^[[A' history-substring-search-up 2>/dev/null
bindkey '^[[B' history-substring-search-down 2>/dev/null
alias ls='eza --icons --group-directories-first'
alias ll='eza -lh --icons --group-directories-first'
alias la='eza -lah --icons --group-directories-first'
alias cat='bat --paging=never'
command -v zoxide >/dev/null && eval "$(zoxide init zsh)"
EOF
    ok "Added fish-like QoL block (eza/bat/zoxide aliases, history-substring-search binds) to ~/.zshrc."
  fi

  if ask_yn "Add a fastfetch-on-terminal-launch hook to ~/.zshrc too?"; then
    if ! grep -qF "clear && fastfetch" "$HOME/.zshrc" 2>/dev/null; then
      printf '\n%s\n%s\n' "# Fastfetch on terminal start" "clear && fastfetch" >> "$HOME/.zshrc"
      ok "Hook added to ~/.zshrc"
    else
      ok "Hook already present."
    fi
  else
    warn "Skipped fastfetch hook in ~/.zshrc."
  fi

  if ask_yn "Install Starship prompt (cross-shell, common in fish-like rice setups — optional, Oh My Zsh themes work fine without it)?"; then
    curl -fsSL https://starship.rs/install.sh | sh -s -- -y \
      && { grep -qF 'starship init zsh' "$HOME/.zshrc" || echo 'eval "$(starship init zsh)"' >> "$HOME/.zshrc"; ok "Starship installed and wired into ~/.zshrc."; } \
      || warn "Starship install failed."
  else
    warn "Skipped Starship prompt."
  fi

  if ask_yn "Set zsh as your default login shell now?"; then
    chsh -s "$(command -v zsh)" "$USER" \
      && { ok "Default shell set to zsh."; warn "Log out/in (or reboot) for the shell change to take effect."; } \
      || warn "chsh failed — set it manually with: chsh -s \$(command -v zsh)"
  else
    warn "Skipped setting zsh as default shell — run 'chsh -s \$(command -v zsh)' later."
  fi
}

setup_nerd_fonts() {
  phase "Nerd Fonts (icon glyphs for Noctalia Shell / Hyprland status bar)"
  echo "jetbrains-mono-fonts from dnf is NOT patched with Nerd Font glyphs."
  echo "Noctalia Shell's bar (workspace icons, battery, network, etc.) expects a patched font."
  ask_yn "Download and install JetBrainsMono Nerd Font into ~/.local/share/fonts?" || { warn "Skipped Nerd Font install — Noctalia Shell icons/glyphs may render as boxes."; return; }

  local ver tmpdir
  tmpdir="$(mktemp -d)"
  # Get latest release tag from GitHub; fall back to a known-good pinned version.
  ver="$(curl -fsSL https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest 2>/dev/null \
        | grep -m1 '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')"
  [[ -z "$ver" ]] && ver="v3.2.1"

  step "Downloading JetBrainsMono Nerd Font ($ver)..."
  if curl -fsSL -o "$tmpdir/JetBrainsMono.zip" \
      "https://github.com/ryanoasis/nerd-fonts/releases/download/${ver}/JetBrainsMono.zip"; then
    mkdir -p ~/.local/share/fonts/JetBrainsMonoNerdFont
    unzip -oq "$tmpdir/JetBrainsMono.zip" -d ~/.local/share/fonts/JetBrainsMonoNerdFont
    fc-cache -f ~/.local/share/fonts >/dev/null
    ok "JetBrainsMono Nerd Font installed to ~/.local/share/fonts/JetBrainsMonoNerdFont"
  else
    warn "Nerd Font download failed — install manually from https://github.com/ryanoasis/nerd-fonts/releases"
  fi
  rm -rf "$tmpdir"
}

setup_dev_tools() {
  phase "Developer tools (optional)"
  ask_yn "Install base dev tools (build-essential-equivalent, git, cmake, system python)?" || { warn "Skipped base dev tools."; return; }
  install "dev tools" @development-tools git curl wget pkgconf-pkg-config cmake ninja-build openssl-devel
  install "system python" python3 python3-pip python3-virtualenv
  echo "Language runtimes (node/python/go/rust versions) are handled by mise in the next step — this system python is just for scripts/tooling that expect /usr/bin/python3."
}

setup_mise() {
  phase "mise — polyglot runtime/version manager"
  ask_yn "Install mise and set up managed runtimes (node, python, go, rust)?" || { warn "Skipped mise / language runtimes."; return; }

  if ! command -v mise >/dev/null 2>&1 && [[ ! -x "$HOME/.local/bin/mise" ]]; then
    step "Installing mise..."
    curl -fsSL https://mise.run | sh || { warn "mise install script failed."; return; }
  else
    ok "mise already installed."
  fi

  local mise_bin="$HOME/.local/bin/mise"
  [[ -x "$mise_bin" ]] || mise_bin="$(command -v mise || true)"
  [[ -z "$mise_bin" ]] && { warn "Could not locate mise binary after install."; return; }

  if ! grep -qF 'mise activate bash' ~/.bashrc 2>/dev/null; then
    printf '\n%s\n%s\n' '# mise (polyglot runtime manager)' 'eval "$('"$mise_bin"' activate bash)"' >> ~/.bashrc
    ok "Added mise shell activation to ~/.bashrc."
  fi
  if [[ -f "$HOME/.zshrc" ]] && ! grep -qF 'mise activate zsh' "$HOME/.zshrc" 2>/dev/null; then
    printf '\n%s\n%s\n' '# mise (polyglot runtime manager)' 'eval "$('"$mise_bin"' activate zsh)"' >> "$HOME/.zshrc"
    ok "Added mise shell activation to ~/.zshrc."
  fi

  echo ""
  echo "Which runtimes should mise install and set as global defaults?"
  local runtimes=()
  ask_yn "  node (latest LTS)?" && runtimes+=("node@lts")
  ask_yn "  bun (latest)?"     && runtimes+=("bun@latest")
  ask_yn "  python (latest)?"  && runtimes+=("python@latest")
  ask_yn "  go (latest)?"      && runtimes+=("go@latest")
  ask_yn "  rust (latest, via mise's rust core plugin)?" && runtimes+=("rust@latest")
  ask_yn "  java temurin-17 (JDK 17 — needed for Expo/React Native Android builds)?" && runtimes+=("java@temurin-17")

  if [[ ${#runtimes[@]} -gt 0 ]]; then
    step "Installing + setting global: ${runtimes[*]}"
    "$mise_bin" use -g "${runtimes[@]}" || warn "mise runtime install had errors — check 'mise doctor' after reboot/relogin."
    ok "Runtimes installed. Corepack (pnpm/yarn) ships with mise's node — enable with: corepack enable"
    [[ " ${runtimes[*]} " == *"java@temurin-17"* ]] && echo "mise sets JAVA_HOME automatically for the active java version — no manual export needed for Expo/Gradle builds."
  else
    warn "No mise runtimes selected — mise itself is installed, add runtimes later with 'mise use -g node@lts' etc."
  fi
}

setup_android_tools() {
  phase "Android platform tools (adb/fastboot)"
  ask_yn "Install android-tools (adb, fastboot — for Expo/React Native device debugging)?" || { warn "Skipped android-tools."; return; }

  install "android-tools" android-tools
  # Note: Arch's setup needs a separate 'android-udev' package for the device
  # rules; Fedora doesn't have (or need) one — android-tools' own package already
  # ships /usr/lib/udev/rules.d/51-android.rules, using udev's uaccess tag so the
  # currently logged-in seat gets device access automatically (no plugdev group
  # needed on modern systemd-udev). Still worth reloading rules explicitly:
  sudo udevadm control --reload-rules
  sudo udevadm trigger
  ok "android-tools installed, udev rules reloaded. Plug in a device with USB debugging enabled and check: adb devices"

  if [[ -f "$HOME/.zshrc" ]]; then
    if ! grep -qF "ANDROID_HOME" "$HOME/.zshrc" 2>/dev/null; then
      cat >> "$HOME/.zshrc" <<'EOF'

# Android SDK
export ANDROID_HOME=$HOME/Android/Sdk
export ANDROID_SDK_ROOT=$ANDROID_HOME

export PATH=$PATH:$ANDROID_HOME/platform-tools
export PATH=$PATH:$ANDROID_HOME/emulator
export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin
EOF
      ok "Added ANDROID_HOME/ANDROID_SDK_ROOT + PATH exports to ~/.zshrc."
    else
      ok "ANDROID_HOME already configured in ~/.zshrc."
    fi
    warn "These paths assume the SDK lands at ~/Android/Sdk (Android Studio's default) — this script doesn't install the SDK itself, just the env vars pointing at it."
  else
    warn "~/.zshrc not found (zsh setup was skipped earlier) — add the ANDROID_HOME/PATH exports manually if you set up zsh later."
  fi
}

setup_containers_vms() {
  phase "Containers + VMs"
  ask_yn "Install Docker CE (Engine + Compose v2 + Buildx, via Docker's official repo — recommended for Laravel Sail)?" && {
    install "dnf-plugins-core" dnf-plugins-core
    sudo dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo \
      || warn "Failed to add Docker's official repo."
    install "docker" docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo systemctl enable --now docker
    sudo usermod -aG docker "$USER"
    warn "Added $USER to the docker group — log out/in (or reboot) for this to take effect (until then, use 'sudo docker')."
    warn "Security note (per Docker's own docs): the docker group is root-equivalent, not a lesser privilege level. The daemon runs as root, and anyone who can talk to it can bind-mount your entire host filesystem into a container unrestricted — being in the docker group is functionally the same as passwordless sudo. Only add users you'd trust with root. Details: https://docs.docker.com/engine/security/#docker-daemon-attack-surface"
    ok "Docker installed. 'docker compose' (used by Sail's ./vendor/bin/sail) is ready to go — no SELinux volume-label or rootless-port workarounds needed."
  } || warn "Skipped Docker."

  ask_yn "Install virtualization support (QEMU/KVM + virt-manager, for full VMs)?" && {
    if ! egrep -q '(vmx|svm)' /proc/cpuinfo; then
      warn "CPU virtualization extensions (VT-x/AMD-V) not detected — VMs will be slow or fail. Check BIOS/UEFI settings if this is unexpected."
    fi
    install "virtualization" qemu-kvm libvirt virt-install virt-manager virt-viewer bridge-utils edk2-ovmf
    sudo systemctl enable --now libvirtd
    sudo usermod -aG libvirt "$USER"
    warn "Added $USER to the libvirt group — log out/in (or reboot) for this to take effect."
  } || warn "Skipped virtualization (QEMU/KVM)."
}

setup_php_laravel() {
  phase "PHP + Composer + Laravel installer"
  ask_yn "Install PHP 8.5, Composer, and the Laravel installer (via Laravel's official php.new script)?" || { warn "Skipped PHP/Composer/Laravel installer."; return; }

  step "Running php.new installer..."
  /bin/bash -c "$(curl -fsSL https://php.new/install/linux/8.5)" \
    && ok "PHP 8.5, Composer, and the Laravel installer are installed." \
    || { warn "php.new install script failed."; return; }

  # php.new's own installer only writes its PATH/PHP_INI_SCAN_DIR exports to the
  # FIRST profile file it finds in its list (usually ~/.bashrc), then breaks out
  # of its loop — so ~/.zshrc never gets them even though it exists. Add them here.
  local php_install_dir="$HOME/.config/herd-lite/bin"
  if [[ -f "$HOME/.zshrc" ]]; then
    if ! grep -qF "$php_install_dir" "$HOME/.zshrc" 2>/dev/null; then
      cat >> "$HOME/.zshrc" <<EOF

# PHP (herd-lite, installed via php.new)
export PATH="$php_install_dir:\$PATH"
export PHP_INI_SCAN_DIR="$php_install_dir:\$PHP_INI_SCAN_DIR"
EOF
      ok "Added PHP PATH/PHP_INI_SCAN_DIR exports to ~/.zshrc."
    else
      ok "PHP PATH exports already present in ~/.zshrc."
    fi
  else
    warn "~/.zshrc not found (zsh setup was skipped earlier) — add these manually if you set up zsh later: export PATH=\"$php_install_dir:\$PATH\" / export PHP_INI_SCAN_DIR=\"$php_install_dir:\$PHP_INI_SCAN_DIR\""
  fi

  if [[ -f "$HOME/.zshrc" ]]; then
    if ! grep -qF "alias sail=" "$HOME/.zshrc" 2>/dev/null; then
      cat >> "$HOME/.zshrc" <<'EOF'

# Laravel Sail shortcut (run from a project root, whether Sail is published or still in vendor/bin)
alias sail='sh $([ -f sail ] && echo sail || echo vendor/bin/sail)'
EOF
      ok "Added 'sail' alias to ~/.zshrc."
    else
      ok "'sail' alias already present in ~/.zshrc."
    fi
  else
    warn "~/.zshrc not found (zsh setup was skipped earlier) — add this alias manually if you set up zsh later: alias sail='sh \$([ -f sail ] && echo sail || echo vendor/bin/sail)'"
  fi
}

setup_vscode() {
  phase "VS Code"
  ask_yn "Install VS Code (via Microsoft's official repo)?" || { warn "Skipped VS Code."; return; }
  sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
  sudo tee /etc/yum.repos.d/vscode.repo >/dev/null <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
  install "vscode" code

  if ask_yn "Install a starter set of VS Code extensions (GitLens, Docker, EditorConfig, Even Better TOML, Error Lens)?"; then
    for ext in eamodio.gitlens ms-azuretools.vscode-docker editorconfig.editorconfig tamasfe.even-better-toml usernamehw.errorlens; do
      code --install-extension "$ext" --force || warn "Failed to install VS Code extension: $ext"
    done
  fi
}

setup_lazyvim() {
  phase "Neovim + LazyVim"
  ask_yn "Install Neovim (latest) + LazyVim starter config?" || { warn "Skipped LazyVim."; return; }

  install "lazyvim deps" \
    git curl wget unzip tar gcc gcc-c++ make cmake \
    ripgrep fd-find fzf \
    tree-sitter-cli \
    luarocks

  install "neovim + python3-neovim (Python remote plugin provider)" neovim python3-neovim

  # LazyVim needs Neovim >= 0.9 (0.10+ recommended). Fedora's dnf package is
  # usually current enough, but fall back to the official prebuilt release
  # if it's too old rather than leaving LazyVim half-broken.
  local nvim_ver nvim_major nvim_minor
  nvim_ver="$(nvim --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
  nvim_major="$(echo "${nvim_ver:-0.0.0}" | cut -d. -f1)"
  nvim_minor="$(echo "${nvim_ver:-0.0.0}" | cut -d. -f2)"
  if [[ -z "$nvim_ver" ]] || (( nvim_major == 0 && nvim_minor < 9 )); then
    warn "Neovim ${nvim_ver:-not found} is older than LazyVim's minimum (0.9+) — fetching the official prebuilt release instead."
    local tmpdir
    tmpdir="$(mktemp -d)"
    if curl -fsSL -o "$tmpdir/nvim.tar.gz" "https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz" \
        || curl -fsSL -o "$tmpdir/nvim.tar.gz" "https://github.com/neovim/neovim/releases/latest/download/nvim-linux64.tar.gz"; then
      sudo rm -rf /opt/nvim
      sudo tar -xzf "$tmpdir/nvim.tar.gz" -C /opt
      sudo mv /opt/nvim-linux-x86_64 /opt/nvim 2>/dev/null || sudo mv /opt/nvim-linux64 /opt/nvim 2>/dev/null
      sudo ln -sf /opt/nvim/bin/nvim /usr/local/bin/nvim
      ok "Installed official Neovim release to /opt/nvim, symlinked to /usr/local/bin/nvim."
    else
      warn "Failed to download official Neovim release — LazyVim may not work correctly with the dnf-packaged version."
    fi
    rm -rf "$tmpdir"
  else
    ok "Neovim $nvim_ver detected — meets LazyVim's minimum version."
  fi

  local backup_suffix
  backup_suffix="$(date +%Y%m%d%H%M%S)"
  for d in "$HOME/.config/nvim" "$HOME/.local/share/nvim" "$HOME/.local/state/nvim" "$HOME/.cache/nvim"; do
    [[ -e "$d" ]] && mv "$d" "${d}.bak.${backup_suffix}" && warn "Existing $d backed up to ${d}.bak.${backup_suffix}"
  done

  git clone https://github.com/LazyVim/starter "$HOME/.config/nvim" \
    && rm -rf "$HOME/.config/nvim/.git" \
    && ok "LazyVim starter cloned to ~/.config/nvim — plugins install automatically the first time you run 'nvim'." \
    || warn "Failed to clone LazyVim starter config."

  echo "After first launch, run ':checkhealth' (or ':LazyHealth') inside nvim to verify everything's green."
  echo "Note: the 'node' provider check needs a Node.js on PATH — if you installed Node via mise, make sure this shell has 'eval \"\$(mise activate ...)\"' sourced (a fresh terminal after this script finishes should have it)."
}

setup_lazygit() {
  phase "lazygit (via COPR)"
  ask_yn "Install lazygit (terminal Git UI, via atim/lazygit COPR)?" || { warn "Skipped lazygit."; return; }
  sudo dnf copr enable -y atim/lazygit || { warn "Failed to enable the atim/lazygit COPR."; return; }
  install "lazygit" lazygit
  ok "lazygit installed. LazyVim has a built-in lazygit integration (default keybind: <leader>gg)."
}

setup_jetbrains_toolbox() {
  phase "JetBrains Toolbox"
  ask_yn "Install JetBrains Toolbox (download latest, verify checksum, extract to ~/Applications)?" || { warn "Skipped JetBrains Toolbox."; return; }

  # Per JetBrains' docs (jetbrains.com/help/toolbox-app/installation.html), officially
  # supported desktop environments are GNOME and KDE Plasma — Hyprland isn't listed, so this
  # is unofficial/untested territory, though the app itself doesn't depend on anything
  # compositor-specific (standard GTK/X11-via-XWayland), so it should still run fine.
  install "toolbox runtime deps" tar fontconfig gtk3 libXi libXrender libXtst xcb-util-keysyms jq

  step "Querying JetBrains releases API for the latest Toolbox build..."
  local api_json dl_url sha_url
  api_json="$(curl -fsSL 'https://data.services.jetbrains.com/products/releases?code=TBA&latest=true&type=release')" \
    || { warn "Failed to query JetBrains releases API."; return; }
  dl_url="$(echo "$api_json" | jq -r '.TBA[0].downloads.linux.link')"
  sha_url="$(echo "$api_json" | jq -r '.TBA[0].downloads.linux.checksumLink')"
  local version
  version="$(echo "$api_json" | jq -r '.TBA[0].version')"

  if [[ -z "$dl_url" || "$dl_url" == "null" || -z "$sha_url" || "$sha_url" == "null" ]]; then
    warn "Could not parse download/checksum URLs from the JetBrains API response."
    return
  fi
  ok "Latest Toolbox version: $version"

  local tmpdir tarball shafile
  tmpdir="$(mktemp -d)"
  tarball="$tmpdir/$(basename "$dl_url")"
  shafile="$tmpdir/$(basename "$sha_url")"

  step "Downloading $(basename "$dl_url")..."
  curl -fsSL -o "$tarball" "$dl_url" || { warn "Toolbox download failed."; rm -rf "$tmpdir"; return; }
  curl -fsSL -o "$shafile" "$sha_url" || warn "Checksum file download failed."

  if [[ -f "$shafile" ]]; then
    step "Verifying checksum..."
    if ( cd "$tmpdir" && sha256sum -c "$(basename "$shafile")" >/dev/null 2>&1 ); then
      ok "Checksum verified against JetBrains' published .sha256."
    else
      warn "Checksum verification FAILED — refusing to install. Files left in $tmpdir for inspection."
      return
    fi
  else
    warn "Skipping checksum verification (file unavailable) — proceeding anyway."
  fi

  mkdir -p "$HOME/Applications/jetbrains-toolbox"
  tar -xzf "$tarball" -C "$HOME/Applications/jetbrains-toolbox"
  rm -rf "$tmpdir"
  ok "Extracted to ~/Applications/jetbrains-toolbox"

  echo ""
  echo "One manual step left — there is no silent/headless install on Linux (this is JetBrains' own design, not a script limitation):"
  echo "  ~/Applications/jetbrains-toolbox/bin/jetbrains-toolbox"
  echo "Running that IS the install step: first launch initializes ~/.local/share/JetBrains/Toolbox and creates its own .desktop entry in ~/.local/share/applications automatically. After that, it behaves like a normal installed app (launcher, autostart toggle, etc.)."
}

setup_postman() {
  phase "Postman"
  ask_yn "Install Postman (API client)?" || { warn "Skipped Postman."; return; }

  if [[ -x /opt/Postman/Postman ]]; then
    ok "Postman already installed at /opt/Postman — skipping download."
  else
    local tmpdir
    tmpdir="$(mktemp -d)"
    step "Downloading Postman..."
    if wget -q "https://dl.pstmn.io/download/latest/linux64" -O "$tmpdir/postman-linux-x64.tar.gz"; then
      sudo tar -xzf "$tmpdir/postman-linux-x64.tar.gz" -C /opt \
        && ok "Postman extracted to /opt/Postman." \
        || { warn "Failed to extract Postman archive."; rm -rf "$tmpdir"; return; }
    else
      warn "Postman download failed."
      rm -rf "$tmpdir"
      return
    fi
    rm -rf "$tmpdir"
  fi

  sudo ln -sf /opt/Postman/Postman /usr/local/bin/postman
  ok "Symlinked /usr/local/bin/postman -> /opt/Postman/Postman"

  # Icon location has moved between Postman releases, so search for it
  # instead of hardcoding a path that might not exist in the current build.
  local icon
  icon="$(find /opt/Postman -maxdepth 6 -iname 'icon.png' 2>/dev/null | head -n1)"
  [[ -z "$icon" ]] && icon="/opt/Postman/app/resources/app/assets/icon.png"

  mkdir -p ~/.local/share/applications
  cat > ~/.local/share/applications/postman.desktop <<EOF
[Desktop Entry]
Name=Postman
GenericName=API Client
X-GNOME-FullName=Postman API Client
Comment=Make and view REST API calls and responses
Keywords=api;
Exec=/opt/Postman/Postman
Terminal=false
Type=Application
Icon=${icon}
Categories=Development;Utilities;
EOF
  ok "Desktop entry written to ~/.local/share/applications/postman.desktop"
}

setup_design_apps() {
  phase "Design apps (raster/photo)"
  ask_yn "Install raster/photo design apps (GIMP, Krita, RawTherapee) + supporting tools?" || { warn "Skipped design apps."; return; }
  install "raster/photo apps" gimp krita rawtherapee
  install "design support tools" ImageMagick perl-Image-ExifTool gcolor3 font-manager
  echo "Note: RAW thumbnail previews in Thunar are already covered by raw-thumbnailer (installed earlier)."
  echo "Not installed (say the word if you want these too): Inkscape (vector), Blender (3D), colord/argyllcms + Wacom tablet input (color-managed/tablet workflow)."
}

setup_small_tweaks() {
  phase "Small system tweaks (optional)"

  if ask_yn "Set a custom hostname now?"; then
    read -r -p "Enter hostname: " hn </dev/tty
    [[ -n "$hn" ]] && sudo hostnamectl set-hostname "$hn" && ok "Hostname set to $hn"
  else
    warn "Skipped hostname change."
  fi

  if ask_yn "Set hardware clock to UTC (only matters if you dual-boot Windows)?"; then
    sudo timedatectl set-local-rtc 0 && ok "RTC set to UTC."
  else
    warn "Skipped RTC change."
  fi

  if ask_yn "Disable NetworkManager-wait-online.service for faster boot?"; then
    sudo systemctl disable NetworkManager-wait-online.service && ok "Disabled."
  else
    warn "Skipped disabling NetworkManager-wait-online.service."
  fi

  if ask_yn "Run firmware updates now (fwupdmgr — SSD/UEFI/peripheral firmware via LVFS)?"; then
    fwupdmgr refresh --force || true
    fwupdmgr get-updates || true
    fwupdmgr update || true
  else
    warn "Skipped firmware updates."
  fi

  if ask_yn "Add a GUI AppImage manager (Gearlever, via Flatpak)?"; then
    flatpak install -y flathub it.mijorus.gearlever || warn "Gearlever install failed"
  else
    warn "Skipped Gearlever (AppImage manager)."
  fi
}

finalize() {
  phase "Finalizing"
  sudo systemctl set-default graphical.target || warn "Could not set default target"
  ok "Default target = graphical.target"
}

# ── Hyprland + Noctalia Shell + Noctalia Greeter ───────────────────────────

# Installs the greetd-based Noctalia Greeter session config. Doesn't touch
# which display manager is currently active — see switch_display_manager.
configure_greetd() {
  local greeter_cmd
  greeter_cmd="$(command -v noctalia-greeter-session || true)"
  if [[ -z "$greeter_cmd" ]]; then
    warn "noctalia-greeter-session not found on PATH — is noctalia-greeter installed correctly? Skipping greetd config."
    return 1
  fi
  ok "Found noctalia-greeter-session at $greeter_cmd"

  install "greetd" greetd

  sudo mkdir -p /etc/greetd
  local cfg="/etc/greetd/config.toml"

  if [[ -f "$cfg" ]]; then
    local backup="${cfg}.bak.$(date +%Y%m%d%H%M%S)"
    sudo cp "$cfg" "$backup"
    warn "Existing greetd config backed up to $backup"

    if sudo grep -q '^\[default_session\]' "$cfg"; then
      # Rewrite only the command= line inside the [default_session] section,
      # leaving everything else (including a custom `user =`) untouched.
      sudo awk -v cmd="$greeter_cmd" '
        BEGIN { insec = 0 }
        /^\[default_session\]/ { insec = 1; print; next }
        /^\[/ { insec = 0 }
        insec && /^command[[:space:]]*=/ { print "command = \"" cmd "\""; next }
        { print }
      ' "$cfg" > "/tmp/greetd-config.toml.$$" \
        && sudo cp "/tmp/greetd-config.toml.$$" "$cfg" \
        && rm -f "/tmp/greetd-config.toml.$$" \
        && ok "Updated [default_session] command in $cfg to noctalia-greeter-session."
    else
      printf '\n[default_session]\ncommand = "%s"\nuser = "greeter"\n' "$greeter_cmd" \
        | sudo tee -a "$cfg" >/dev/null
      ok "Appended a [default_session] section to $cfg."
    fi
  else
    printf '[default_session]\ncommand = "%s"\nuser = "greeter"\n' "$greeter_cmd" \
      | sudo tee "$cfg" >/dev/null
    ok "Created $cfg with noctalia-greeter-session as the default session."
  fi
}

# Disables whatever is currently behind display-manager.service and enables
# greetd instead. Always confirms first — this can break graphical login if
# something's misconfigured, per Noctalia Greeter's own docs.
switch_display_manager() {
  local current_dm
  current_dm="$(systemctl show -p Id --value display-manager.service 2>/dev/null || true)"

  if [[ -z "$current_dm" ]]; then
    warn "Could not read display-manager.service — check/enable greetd manually: sudo systemctl enable greetd"
    return
  fi

  echo "Current display-manager.service points at: $current_dm"

  if [[ "$current_dm" == "greetd.service" ]]; then
    ok "greetd is already the active display manager."
  else
    echo -e "${YELLOW}This only changes which display manager starts on your NEXT boot — it does NOT touch your current session.${NC}"
    echo "$current_dm keeps running exactly as-is until you reboot, so it's safe to run this from inside your current desktop session (no --now, nothing gets stopped right now)."
    if ask_yn "Disable $current_dm and enable greetd (Noctalia Greeter) for the next boot?"; then
      # Deliberately no --now: stopping the active display manager mid-session
      # kills the graphical session (and this script's own terminal) instantly.
      sudo systemctl disable "$current_dm" || warn "Failed to disable $current_dm — disable it manually before rebooting, or it and greetd will fight over the login screen."
    else
      warn "Left $current_dm enabled — Noctalia Greeter won't appear until you disable it yourself (sudo systemctl disable $current_dm) and enable greetd."
      return
    fi
  fi

  install "greetd (dbus dep)" dbus-daemon
  # Also no --now here, for the same reason — greetd will take over on next boot.
  sudo systemctl enable greetd || warn "Failed to enable greetd — check: systemctl status greetd"
  ok "greetd enabled — it will take over the login screen on your next reboot, current session untouched."
}

run_noctalia_setup() {
  phase "Installing Hyprland + Noctalia Shell + Noctalia Greeter"
  echo "Hyprland isn't in Fedora's official repos, so this uses the community"
  echo "lionheartp/Hyprland Copr (a fork of solopasha/hyprland that also builds"
  echo "Noctalia Shell and a meta package pairing the two):"
  echo "  https://copr.fedorainfracloud.org/coprs/lionheartp/Hyprland"
  echo ""
  echo "This installs:"
  echo "  • Hyprland                     — the Wayland compositor        (lionheartp Copr)"
  echo "  • xdg-desktop-portal-hyprland   — screenshot/screen-share backend for Hyprland"
  echo "  • Noctalia Shell                — bar / launcher / panels      (Fedora repos on 44+, else same Copr)"
  echo "  • Noctalia Greeter              — the greetd-based login screen (Terra: noctalia-greeter)"
  echo ""
  ask_yn "Proceed with the Hyprland + Noctalia install?" || { warn "Skipped Hyprland/Noctalia install — install manually later, see https://copr.fedorainfracloud.org/coprs/lionheartp/Hyprland and https://docs.noctalia.dev"; return; }

  step "Enabling the lionheartp/Hyprland Copr..."
  if sudo dnf copr enable -y lionheartp/Hyprland; then
    HYPRLAND_COPR_ENABLED=1
    ok "lionheartp/Hyprland Copr enabled."
  else
    err "Failed to enable lionheartp/Hyprland Copr — cannot install Hyprland."
    warn "Skipped Hyprland/Noctalia install (Copr unavailable) — retry manually: sudo dnf copr enable lionheartp/Hyprland"
    return
  fi

  if ask_yn "Install via the noctalia-hyprland-meta package (bundles Hyprland + Noctalia Shell + a starter hyprland.conf that launches the Noctalia Setup Wizard on first login — recommended)?"; then
    install "noctalia-hyprland-meta" noctalia-hyprland-meta
  else
    install "hyprland" hyprland xdg-desktop-portal-hyprland
    # Noctalia Shell: prefer Fedora's own repo package on 44+, otherwise the
    # same Copr already enabled above carries a git-snapshot build.
    if (( FEDORA_VER >= 44 )); then
      install "noctalia" noctalia
    else
      warn "Fedora $FEDORA_VER < 44 — Noctalia's dnf package isn't available yet; using the lionheartp Copr git snapshot instead."
      install "noctalia (git snapshot)" noctalia-git
    fi
  fi

  # Noctalia Greeter (Terra-only on Fedora — a separate repo from the Hyprland Copr above)
  if [[ "$TERRA_ENABLED" != "1" ]]; then
    step "Terra is required for Noctalia Greeter on Fedora — enabling it now."
    if ! do_enable_terra; then
      err "Terra repo enable failed — cannot install Noctalia Greeter without it."
      warn "Skipped Noctalia Greeter (Terra unavailable) — Hyprland + Noctalia Shell are still installed; retry the greeter later: sudo dnf install --nogpgcheck --repofrompath 'terra,https://repos.fyralabs.com/terra\$releasever' terra-release && sudo dnf install noctalia-greeter"
      return
    fi
  fi
  install "noctalia-greeter" noctalia-greeter

  if configure_greetd; then
    switch_display_manager
  else
    warn "greetd wasn't configured — set it up manually per https://docs.noctalia.dev/greeter/installation/ before rebooting."
  fi

  echo ""
  echo "Next, as your normal user (not root):"
  if [[ ! -f "$HOME/.config/hypr/hyprland.conf" ]]; then
    echo "If noctalia-hyprland-meta didn't already drop one in for you, log into a Hyprland"
    echo "session with no ~/.config/hypr/hyprland.conf present — it should greet you with"
    echo "the Noctalia Setup Wizard automatically."
  fi
  echo "Make sure Noctalia Shell and xfce-polkit are launched from hyprland.conf, e.g.:"
  echo '  exec-once = xfce-polkit'
  echo '  exec-once = noctalia-shell   # only if the wizard/meta package hasn'"'"'t already wired this up'
}

show_completion() {
  phase "Done"
  echo -e "${GREEN}Base system + Hyprland/Noctalia setup complete (or ready, if you skipped that step).${NC}"
  echo ""
  echo "Before you consider this fully finished:"
  echo "  - If NVIDIA + Secure Boot: finish the MOK enrollment steps printed above, then reboot."
  echo "  - Confirm a polkit prompt actually appears when a GUI app needs privilege escalation."
  echo "  - Confirm ~/.config/hypr/hyprland.conf exists and exec-once's both xfce-polkit and Noctalia Shell (see the note printed above)."
  echo "  - If you skipped the Hyprland/Noctalia install step: run it later, then reboot."
  echo "  - First reboot after switching display managers: keep a TTY handy in case Noctalia Greeter doesn't come up."
  echo ""
  if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    echo -e "${YELLOW}Things skipped or that had issues this run (recap):${NC}"
    local seen=()
    for w in "${SKIPPED[@]}"; do
      echo "  - $w"
    done
    echo ""
  fi
  echo "Full log saved to: $HOME/fedora-hyprland-noctalia-setup.log"
  echo ""
  echo "Reboot when ready:"
  echo -e "  ${YELLOW}sudo systemctl reboot${NC}"
}

# ── Main ────────────────────────────────────────────────────────────────
setup_sudo
setup_logging
check_fedora
prompt_intro
tune_dnf
enable_rpmfusion
enable_terra
setup_polkit
core_system
setup_network_discovery
setup_zram
setup_graphics
setup_audio
setup_codecs
setup_bluetooth
setup_portals_keyring
setup_power
setup_file_manager
setup_daily_utils
setup_terminal
setup_tealdeer
setup_fastfetch_config
setup_browsers
setup_zsh
setup_nerd_fonts
setup_dev_tools
setup_mise
setup_android_tools
setup_containers_vms
setup_php_laravel
setup_vscode
setup_lazyvim
setup_lazygit
setup_jetbrains_toolbox
setup_postman
setup_design_apps
setup_small_tweaks
finalize
run_noctalia_setup
show_completion
