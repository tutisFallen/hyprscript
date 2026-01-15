#!/usr/bin/env bash

# ==============================================================================
# MASTER SETUP SCRIPT v10.0 - GOLD MASTER (SHELLCHECK CLEAN)
# ==============================================================================

set -u
set -o pipefail

# --- Variáveis ---
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="/var/log/setup_master_${TIMESTAMP}.log"
SNAPSHOT_FILE="/var/log/pkg_snapshot_${TIMESTAMP}.txt"
TMP_DIR="$(mktemp -d -t setup-master.XXXXXXXXXX)"
AUR_HELPER=""
DRY_RUN=false

# Arrays para relatório final
INSTALLED_PKGS=()
FAILED_PKGS=()
SKIPPED_PKGS=()

# --- Cores ---
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# --- 1. Validação de Usuário & Ambiente ---

# Detecção segura de usuário real
if [ -n "${SUDO_USER:-}" ]; then
    REAL_USER="$SUDO_USER"
else
    REAL_USER=$(who am i | awk '{print $1}' 2>/dev/null || echo "root")
fi

if [ "$REAL_USER" == "root" ]; then
    echo -e "${YELLOW}[WARN] Executando como root direto (chroot?).${NC}"
fi

# --- 2. Infraestrutura ---

cleanup() {
    [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
    if [ -f "$LOG_FILE" ] && [ "$REAL_USER" != "root" ]; then
        chown root:"$REAL_USER" "$LOG_FILE"
        chmod 644 "$LOG_FILE"
    fi
}
trap cleanup EXIT

log() {
    local level=$1
    local msg=$2
    local ts
    ts=$(date +'%H:%M:%S')

    # Exibe no console
    case $level in
        "INFO") echo -e "${BLUE}[INFO] ${msg}${NC}" ;;
        "OK")   echo -e "${GREEN}[OK] ${msg}${NC}" ;;
        "WARN") echo -e "${YELLOW}[AVISO] ${msg}${NC}" ;;
        "ERR")  echo -e "${RED}[ERRO] ${msg}${NC}" ;;
        "DRY")  echo -e "${YELLOW}[DRY-RUN] ${msg}${NC}" ;;
    esac
    # Grava no arquivo
    echo "[$ts] [$level] $msg" >> "$LOG_FILE"
}

# Executor seguro com suporte a Dry-Run
execute() {
    local cmd="$*"
    if [ "$DRY_RUN" = true ]; then
        log "DRY" "Executaria: $cmd"
        return 0
    fi

    # Executa capturando erros
    eval "$cmd"
}

retry_command() {
    local max_attempts=3
    local cmd="$*"
    local attempt=1

    if [ "$DRY_RUN" = true ]; then
        log "DRY" "Tentaria (com retry): $cmd"
        return 0
    fi

    while [ $attempt -le $max_attempts ]; do
        if eval "$cmd"; then return 0; fi
        log "WARN" "Falha (Tentativa $attempt). Retentando..."
        sleep 2
        ((attempt++))
    done
    return 1
}

# --- 3. Pre-Flight Checks ---

check_system_health() {
    log "INFO" "Checando sistema..."

    # Validar binários críticos
    if ! command -v curl &>/dev/null; then
        log "ERR" "Comando 'curl' não encontrado. Instale-o manualmente."
        exit 1
    fi

    if [ "$DRY_RUN" = false ]; then
        # Internet
        if ! ping -c 1 8.8.8.8 &>/dev/null; then
            log "ERR" "Sem internet."
            exit 1
        fi

        # Disco (>5GB)
        local free
        free=$(df -k / | awk 'NR==2 {print $4}')
        if [ "$free" -lt 5000000 ]; then
            log "ERR" "Espaço insuficiente (<5GB)."
            exit 1
        fi
    fi
    log "OK" "Sistema saudável."
}

take_snapshot() {
    if [ "$DRY_RUN" = true ]; then return; fi
    log "INFO" "Criando snapshot..."
    if command -v pacman &>/dev/null; then pacman -Q > "$SNAPSHOT_FILE"; fi
    if command -v rpm &>/dev/null; then rpm -qa > "$SNAPSHOT_FILE"; fi
}

# --- 4. Detecção ---

detect_system() {
    DISTRO_BASE="unknown"
    if [ -f /etc/os-release ]; then
        local os_id
        os_id=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' || echo "unknown")
        local os_id_like
        os_id_like=$(grep -E '^ID_LIKE=' /etc/os-release | cut -d= -f2 | tr -d '"' || echo "unknown")

        case "$os_id" in
            arch|cachyos|manjaro|endeavouros|garuda) DISTRO_BASE="arch" ;;
            fedora|rhel|centos|nobara|ultramarine) DISTRO_BASE="fedora" ;;
        esac

        if [[ "$DISTRO_BASE" == "unknown" ]]; then
            [[ "$os_id_like" == *"arch"* ]] && DISTRO_BASE="arch"
            [[ "$os_id_like" == *"fedora"* ]] && DISTRO_BASE="fedora"
        fi
    fi

    if [[ "$DISTRO_BASE" == "unknown" ]]; then
        # Check binário
        command -v pacman &>/dev/null && DISTRO_BASE="arch"
        command -v dnf &>/dev/null && DISTRO_BASE="fedora"
    fi

    if [[ "$DISTRO_BASE" == "unknown" ]]; then
        log "ERR" "Distro não suportada."
        exit 1
    fi
    log "OK" "Base detectada: ${DISTRO_BASE^^}"
}

# --- 5. Configuração ---

setup_arch_env() {
    log "INFO" "Configurando Arch..."
    if [ "$DRY_RUN" = true ]; then return; fi

    # Backup Pacman Conf
    if [ -f /etc/pacman.conf ]; then
        cp /etc/pacman.conf "/etc/pacman.conf.bak.${TIMESTAMP}"
    fi

    # Configurações (com verificação)
    if grep -q "^#Color" /etc/pacman.conf; then
        sed -i 's/^#Color/Color\nILoveCandy/' /etc/pacman.conf
    fi
    sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 10/' /etc/pacman.conf

    if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
        echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf
    fi

    log "INFO" "Atualizando sistema (Atomic)..."
    retry_command "pacman -Sy --noconfirm archlinux-keyring"
    retry_command "pacman -Syu --noconfirm"

    # Detecção AUR Helper (Sem instalação automática)
    if sudo -u "$REAL_USER" command -v paru &>/dev/null; then AUR_HELPER="paru"
    elif sudo -u "$REAL_USER" command -v yay &>/dev/null; then AUR_HELPER="yay"
    else
        log "WARN" "Nenhum helper AUR encontrado (paru/yay)."
        log "WARN" "Pacotes do AUR (ex: Vivaldi, Cava) serão PULADOS."
    fi
}

setup_fedora_env() {
    log "INFO" "Configurando Fedora..."
    if [ "$DRY_RUN" = true ]; then return; fi

    execute "dnf install -y https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-\$(rpm -E %fedora).noarch.rpm https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-\$(rpm -E %fedora).noarch.rpm"

    if [ ! -f /etc/yum.repos.d/vivaldi.repo ]; then
        execute "dnf config-manager --add-repo https://repo.vivaldi.com/archive/vivaldi-fedora.repo"
    fi

    # Verifica COPRs antes de habilitar
    log "INFO" "Configurando COPRs..."
    execute "dnf copr enable -y solopasha/hyprland" || log "WARN" "COPR solopasha falhou."
    execute "dnf copr enable -y avengemedia/dms-git" || log "WARN" "COPR avengemedia falhou."

    execute "dnf update -y"
}

# --- 6. Instalação Inteligente (Com Progresso) ---

install_list_generic() {
    local cmd_install="$1"
    local check_cmd="$2"
    shift 2
    local list=("$@")
    local total=${#list[@]}
    local current=0

    for pkg in "${list[@]}"; do
        ((current++))
        # Verifica se já está instalado (Otimização)
        if [ "$DRY_RUN" = false ] && eval "$check_cmd $pkg" &>/dev/null; then
            log "OK" "[$current/$total] $pkg já instalado."
            INSTALLED_PKGS+=("$pkg")
            continue
        fi

        log "INFO" "[$current/$total] Instalando: $pkg"
        if execute "$cmd_install $pkg"; then
            INSTALLED_PKGS+=("$pkg")
        else
            log "ERR" "Falha ao instalar $pkg"
            FAILED_PKGS+=("$pkg")
        fi
    done
}

process_install() {
    local profile=$1
    log "INFO" "Iniciando perfil: $profile"

    # Definição de Listas
    # ARCH: Vivaldi movido para AUR
    local arch_base=(git base-devel neovim zsh wget curl htop steam corectrl flatpak sddm networkmanager)
    local arch_aur_base=(vivaldi vivaldi-ffmpeg-codecs)
    local arch_hypr=(hyprland nautilus qt5ct qt6ct cliphist xdg-desktop-portal-hyprland)
    local arch_aur_hypr=(dms-shell-git quickshell-git matugen-bin cava)

    local fedora_base=(git neovim zsh wget curl htop vivaldi-stable steam corectrl flatpak sddm NetworkManager)
    local fedora_hypr=(hyprland nautilus qt5ct qt6ct cliphist xdg-desktop-portal-hyprland dms quickshell-git matugen cava)

    if [[ "$DISTRO_BASE" == "arch" ]]; then
        # Instala Base
        install_list_generic "pacman -S --needed --noconfirm" "pacman -Qi" "${arch_base[@]}"

        # Instala AUR Base (Se helper existir)
        if [[ -n "$AUR_HELPER" ]]; then
            local flags="-S --needed --noconfirm"
            install_list_generic "sudo -u $REAL_USER $AUR_HELPER $flags" "pacman -Qi" "${arch_aur_base[@]}"
        else
            SKIPPED_PKGS+=("${arch_aur_base[@]}")
        fi

        if [[ "$profile" == "hyprland" ]]; then
            install_list_generic "pacman -S --needed --noconfirm" "pacman -Qi" "${arch_hypr[@]}"
            if [[ -n "$AUR_HELPER" ]]; then
                install_list_generic "sudo -u $REAL_USER $AUR_HELPER $flags" "pacman -Qi" "${arch_aur_hypr[@]}"
            else
                SKIPPED_PKGS+=("${arch_aur_hypr[@]}")
            fi
        fi

    elif [[ "$DISTRO_BASE" == "fedora" ]]; then
        install_list_generic "dnf install -y" "rpm -q" "${fedora_base[@]}"

        if [[ "$profile" == "hyprland" ]]; then
            install_list_generic "dnf install -y" "rpm -q" "${fedora_hypr[@]}"
        fi
    fi
}

# --- 7. Finalização ---

finalize() {
    log "INFO" "Ajustes finais..."
    if [ "$DRY_RUN" = true ]; then return; fi

    # Flathub e Overrides
    if command -v flatpak &>/dev/null; then
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
        flatpak override --filesystem=xdg-config/gtk-4.0
        flatpak override --filesystem=~/.themes
    fi

    # Polkit
    mkdir -p /etc/polkit-1/rules.d/
    cat << EOF > /etc/polkit-1/rules.d/90-corectrl.rules
polkit.addRule(function(action, subject) {
    if ((action.id == "org.corectrl.helper.init" || action.id == "org.corectrl.helperkiller.init") && subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
EOF

    # Serviços (com verificação)
    systemctl enable sddm || log "WARN" "Falha ao habilitar SDDM"
    systemctl enable NetworkManager || log "WARN" "Falha ao habilitar NetworkManager"

    # Validação Pós-Instalação
    if systemctl is-enabled sddm &>/dev/null; then log "OK" "Serviço SDDM ativo."; else log "ERR" "SDDM não está habilitado."; fi
}

show_report() {
    echo -e "\n${BOLD}=== RELATÓRIO FINAL ===${NC}"
    echo "Sucesso: ${#INSTALLED_PKGS[@]}"
    echo "Falhas : ${#FAILED_PKGS[@]}"
    echo "Pulados: ${#SKIPPED_PKGS[@]}"

    if [ ${#FAILED_PKGS[@]} -gt 0 ]; then
        echo -e "${RED}Pacotes com erro: ${FAILED_PKGS[*]}${NC}"
    fi
    if [ ${#SKIPPED_PKGS[@]} -gt 0 ]; then
        echo -e "${YELLOW}Pacotes pulados (Falta AUR Helper): ${SKIPPED_PKGS[*]}${NC}"
    fi
    echo "Log completo: $LOG_FILE"
}

show_help() {
    echo "Uso: sudo ./script.sh [OPÇÕES]"
    echo "  --install      Instalação automática (Hyprland)"
    echo "  --base         Instalação automática (Apenas Base)"
    echo "  --dry-run      Simula a execução sem alterar nada"
    echo "  --help         Mostra esta ajuda"
}

# --- Main ---

if [ "$EUID" -ne 0 ]; then
    echo "Execute com sudo."
    exit 1
fi

# Parse Flags
AUTO_PROFILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --install) AUTO_PROFILE="hyprland"; shift ;;
        --base)    AUTO_PROFILE="base"; shift ;;
        --help)    show_help; exit 0 ;;
        *)         shift ;;
    esac
done

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}!!! MODO DRY-RUN ATIVO - NENHUMA ALTERAÇÃO SERÁ FEITA !!!${NC}"
fi

check_system_health
take_snapshot
detect_system

# Fluxo de decisão
if [[ -n "$AUTO_PROFILE" ]]; then
    [[ "$DISTRO_BASE" == "arch" ]] && setup_arch_env
    [[ "$DISTRO_BASE" == "fedora" ]] && setup_fedora_env
    process_install "$AUTO_PROFILE"
    finalize
    show_report
else
    # Menu Interativo
    echo -e "\n${BOLD}MASTER SETUP v10.0${NC}"
    echo "1) Instalar Hyprland + DMS"
    echo "2) Instalar Apenas Base"
    echo "3) Sair"
    read -r -p "Opção: " OPT

    case $OPT in
        1)
            [[ "$DISTRO_BASE" == "arch" ]] && setup_arch_env
            [[ "$DISTRO_BASE" == "fedora" ]] && setup_fedora_env
            process_install "hyprland"
            finalize
            show_report
            ;;
        2)
            [[ "$DISTRO_BASE" == "arch" ]] && setup_arch_env
            [[ "$DISTRO_BASE" == "fedora" ]] && setup_fedora_env
            process_install "base"
            finalize
            show_report
            ;;
        *) exit 0 ;;
    esac
fi
