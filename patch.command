#!/bin/bash
set -euo pipefail

# ANSI color codes
BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${BOLD}${CYAN}====================================================${NC}"
echo -e "${BOLD}${CYAN}   No Man's Sky Mac (Cracked) Gamepad Fix Installer ${NC}"
echo -e "${BOLD}${CYAN}====================================================${NC}\n"

# Verify repo assets
BIN_DIR="$SCRIPT_DIR/bin"
SETTINGS_DIR="$SCRIPT_DIR/steam_settings"

if [ ! -f "$BIN_DIR/libsteam_api.dylib" ] || [ ! -f "$BIN_DIR/libsteam_emu.dylib" ]; then
    echo -e "${YELLOW}[*] Prebuilt binaries missing or incomplete. Building from source...${NC}"
    if [ -f "$SCRIPT_DIR/build.sh" ]; then
        "$SCRIPT_DIR/build.sh"
    else
        echo -e "${RED}[-] Error: Cannot build. Missing $BIN_DIR/libsteam_api.dylib and $BIN_DIR/libsteam_emu.dylib${NC}"
        exit 1
    fi
fi

if [ ! -d "$SETTINGS_DIR/controller" ]; then
    echo -e "${RED}[-] Error: Missing steam_settings/controller in $SCRIPT_DIR!${NC}"
    exit 1
fi

APP_PATH=""

# 1. Check if path was passed via argument
if [ $# -ge 1 ] && [ -n "$1" ]; then
    APP_PATH="$1"
fi

# Clean trailing slash if any
APP_PATH="${APP_PATH%/}"

# 2. If no argument, try to auto-detect
if [ -z "$APP_PATH" ]; then
    echo -e "${CYAN}[*] Searching for No Man's Sky.app...${NC}"
    CANDIDATES=()
    
    # Check current and parent directory
    [ -d "$SCRIPT_DIR/No Man's Sky.app" ] && CANDIDATES+=("$SCRIPT_DIR/No Man's Sky.app")
    [ -d "$SCRIPT_DIR/../No Man's Sky.app" ] && CANDIDATES+=("$SCRIPT_DIR/../No Man's Sky.app")
    
    # Check /Applications and ~/Applications
    [ -d "/Applications/No Man's Sky.app" ] && CANDIDATES+=("/Applications/No Man's Sky.app")
    [ -d "$HOME/Applications/No Man's Sky.app" ] && CANDIDATES+=("$HOME/Applications/No Man's Sky.app")
    
    # Check external volumes
    for vol_app in /Volumes/*/No\ Man\'s\ Sky.app; do
        if [ -d "$vol_app" ]; then
            CANDIDATES+=("$vol_app")
        fi
    done

    if [ ${#CANDIDATES[@]} -eq 1 ]; then
        APP_PATH="${CANDIDATES[0]}"
        echo -e "${GREEN}[+] Auto-detected game at: ${BOLD}$APP_PATH${NC}"
    elif [ ${#CANDIDATES[@]} -gt 1 ]; then
        echo -e "${YELLOW}[!] Multiple installations found:${NC}"
        for i in "${!CANDIDATES[@]}"; do
            echo "  $((i+1))) ${CANDIDATES[$i]}"
        done
        read -rp "Select installation (1-${#CANDIDATES[@]}): " CHOICE
        IDX=$((CHOICE-1))
        if [ "$IDX" -ge 0 ] && [ "$IDX" -lt "${#CANDIDATES[@]}" ]; then
            APP_PATH="${CANDIDATES[$IDX]}"
        fi
    fi
fi

# 3. If still not found, prompt with GUI file chooser or terminal drag-and-drop
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo -e "${YELLOW}[*] Opening file picker to locate No Man's Sky.app...${NC}"
    GUI_CHOICE=$(osascript -e '
        try
            set chosenFile to choose file with prompt "Select No Man'\''s Sky.app" of type {"app"}
            return POSIX path of chosenFile
        on error
            return ""
        end try
    ' 2>/dev/null || true)
    
    if [ -n "$GUI_CHOICE" ] && [ -d "$GUI_CHOICE" ]; then
        APP_PATH="${GUI_CHOICE%/}"
    else
        echo -e "${YELLOW}[?] Please drag and drop No Man's Sky.app into this window and press Enter:${NC}"
        read -r APP_PATH
        # Strip quotes and escape characters
        APP_PATH=$(echo "$APP_PATH" | sed -e "s/^['\"]//" -e "s/['\"]$//" -e 's/\\ / /g')
        APP_PATH="${APP_PATH%/}"
    fi
fi

# Final validation
if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}[-] Error: Application bundle not found at '$APP_PATH'${NC}"
    exit 1
fi

MACOS_DIR="$APP_PATH/Contents/MacOS"
if [ ! -d "$MACOS_DIR" ]; then
    echo -e "${RED}[-] Error: '$APP_PATH' does not appear to be a valid macOS application bundle (missing Contents/MacOS).${NC}"
    exit 1
fi

echo -e "\n${CYAN}[*] Target game:${NC} ${BOLD}$APP_PATH${NC}"

# Backup original dylib if needed
if [ -f "$MACOS_DIR/libsteam_api.dylib" ] && [ ! -f "$MACOS_DIR/libsteam_api.dylib.orig_backup" ]; then
    echo -e "${CYAN}[*] Creating backup of original libsteam_api.dylib...${NC}"
    cp "$MACOS_DIR/libsteam_api.dylib" "$MACOS_DIR/libsteam_api.dylib.orig_backup"
fi

# Copy dylibs
echo -e "${CYAN}[*] Installing libsteam_api.dylib (universal gamepad bridge)...${NC}"
cp "$BIN_DIR/libsteam_api.dylib" "$MACOS_DIR/libsteam_api.dylib"
chmod +x "$MACOS_DIR/libsteam_api.dylib"

echo -e "${CYAN}[*] Installing libsteam_emu.dylib (Goldberg Steam emulator)...${NC}"
cp "$BIN_DIR/libsteam_emu.dylib" "$MACOS_DIR/libsteam_emu.dylib"
chmod +x "$MACOS_DIR/libsteam_emu.dylib"

# Remove legacy steam_settings inside Contents/MacOS if present (prevents macOS codesign bundle errors)
if [ -d "$MACOS_DIR/steam_settings" ]; then
    rm -rf "$MACOS_DIR/steam_settings"
fi

# Copy steam_settings to Contents/Resources
RESOURCES_DIR="$APP_PATH/Contents/Resources"
echo -e "${CYAN}[*] Installing steam_settings and controller mappings into Contents/Resources...${NC}"
mkdir -p "$RESOURCES_DIR/steam_settings"
cp -R "$SETTINGS_DIR/"* "$RESOURCES_DIR/steam_settings/"

# Fix permissions
chmod -R u+rwX "$RESOURCES_DIR/steam_settings"

# Code sign only modified binaries and top-level app bundle (avoids slow deep scanning of 20GB PAKs)
echo -e "${CYAN}[*] Applying ad-hoc code signature...${NC}"
codesign --force -s - "$MACOS_DIR/libsteam_api.dylib"
codesign --force -s - "$MACOS_DIR/libsteam_emu.dylib"
codesign --force -s - "$APP_PATH"

# Remove quarantine attribute if present
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

echo -e "\n${BOLD}${GREEN}====================================================${NC}"
echo -e "${BOLD}${GREEN}   [✓] GAMEPAD PATCH SUCCESSFULLY INSTALLED!       ${NC}"
echo -e "${BOLD}${GREEN}====================================================${NC}"
echo -e "${GREEN}1. Turn on your controller (Xbox, PS4/PS5, Switch Pro, etc. via Bluetooth or USB).${NC}"
echo -e "${GREEN}2. Launch No Man's Sky.${NC}"
echo -e "${GREEN}3. Your gamepad will work immediately in menus and gameplay!${NC}\n"

if [ -t 0 ] && [ -z "${CI:-}" ]; then
    read -rp "Press [Enter] to exit..." _dummy || true
fi
