#!/usr/bin/env bash

# Cores para output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

set -e

echo -e "${BLUE}Iniciando instalação do setup Arch Linux + Hyprland...${NC}"

# 1. Atualização do Sistema e Instalação de Pacotes
echo -e "${BLUE}Atualizando sistema e instalando pacotes base...${NC}"
sudo pacman -Syu --noconfirm
sudo pacman -S --needed --noconfirm $(cat packages.txt)

# 1.1 Verificar/Instalar AUR Helper (yay) para pacotes que podem não estar no repo oficial
if ! command -v yay &> /dev/null; then
    echo -e "${BLUE}Instalando yay (AUR helper)...${NC}"
    sudo pacman -S --needed --noconfirm base-devel git
    git clone https://aur.archlinux.org/yay.git /tmp/yay
    cd /tmp/yay && makepkg -si --noconfirm && cd -
fi

# 2. Configuração do ZSH e Oh My Zsh
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    echo -e "${BLUE}Instalando Oh My Zsh...${NC}"
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi

# Mudar shell para ZSH
if [ "$SHELL" != "/bin/zsh" ]; then
    echo -e "${BLUE}Alterando shell padrão para ZSH...${NC}"
    sudo chsh -s /bin/zsh $USER
fi

# 3. Spaceship Prompt
SPACESHIP_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/spaceship-prompt"
if [ ! -d "$SPACESHIP_DIR" ]; then
    echo -e "${BLUE}Instalando Spaceship Prompt...${NC}"
    git clone https://github.com/spaceship-prompt/spaceship-prompt.git "$SPACESHIP_DIR" --depth=1
    ln -sf "$SPACESHIP_DIR/spaceship.zsh-theme" "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/spaceship.zsh-theme"
fi

# 4. LazyVim Setup
echo -e "${BLUE}Configurando LazyVim...${NC}"
if [ -d "$HOME/.config/nvim" ]; then
    mv "$HOME/.config/nvim" "$HOME/.config/nvim.bak.$(date +%Y%m%d_%H%M%S)"
fi
git clone https://github.com/LazyVim/starter ~/.config/nvim

# 5. Aplicar Configurações Customizadas
echo -e "${BLUE}Aplicando arquivos de configuração...${NC}"
mkdir -p ~/.config/{kitty,yazi,helix,zsh}

# Copiar arquivos de config
cp config/kitty/* ~/.config/kitty/
cp config/yazi/* ~/.config/yazi/
cp config/helix/* ~/.config/helix/
cp config/nvim/init.lua ~/.config/nvim/lua/config/init.lua 2>/dev/null || cp config/nvim/init.lua ~/.config/nvim/init.lua
cp config/zsh/.zshrc ~/.zshrc

echo -e "${GREEN}Instalação concluída com sucesso!${NC}"
echo -e "${BLUE}Por favor, reinicie sua sessão para aplicar todas as alterações.${NC}"
