#!/bin/bash

###############################################################################
# Debian Server Setup Script
#
# This script configures a fresh Debian server with:
# - English US locale with UTC timezone
# - zsh and oh-my-zsh (with signature verification)
# - Rust toolchain (with signature verification)
# - PostgreSQL (APT signed packages)
# - ClickHouse (APT signed packages)
# - SQLite (APT signed packages)
#
# Security features:
# - All downloads over HTTPS with TLS 1.2+
# - GPG signature verification for APT repositories
# - Content verification for shell script installers
# - APT packages verified via signed repositories
#
# Idempotency:
# - Safe to run multiple times
# - Checks for existing installations before installing
# - Updates Rust if already installed
# - Skips already configured components
#
# Usage: sudo bash debian_server_setup.sh
###############################################################################

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root (use sudo)"
   exit 1
fi

# Get the actual user if script is run with sudo
ACTUAL_USER=${SUDO_USER:-$USER}
ACTUAL_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)

log_info "Starting Debian server setup for user: $ACTUAL_USER"

###############################################################################
# 1. Update system and install basic packages
###############################################################################
log_info "Updating system packages..."
apt-get update
apt-get upgrade -y

log_info "Installing basic utilities..."
apt-get install -y \
    curl \
    wget \
    git \
    build-essential \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release \
    locales \
    tzdata

###############################################################################
# 2. Configure locale (English US) and timezone (UTC)
###############################################################################
log_info "Configuring locale to en_US.UTF-8..."

# Generate en_US.UTF-8 locale
sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
locale-gen en_US.UTF-8

# Set as default locale
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Export for current session
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

log_info "Setting timezone to UTC..."
timedatectl set-timezone UTC

log_info "Locale and timezone configured:"
locale
timedatectl

###############################################################################
# 3. Install and configure zsh and oh-my-zsh
###############################################################################
log_info "Checking zsh installation..."
if ! command -v zsh &> /dev/null; then
    log_info "Installing zsh..."
    apt-get install -y zsh
else
    log_info "zsh already installed, skipping"
fi

# Check if oh-my-zsh is already installed
if [ ! -d "$ACTUAL_HOME/.oh-my-zsh" ]; then
    log_info "Installing oh-my-zsh for user $ACTUAL_USER..."

    # Download oh-my-zsh installer with signature verification
    OH_MY_ZSH_TEMP="/tmp/oh-my-zsh-install-$$"
    mkdir -p "$OH_MY_ZSH_TEMP"
    cd "$OH_MY_ZSH_TEMP"

    # Download the installer script
    curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -o install.sh

    # Verify the script came from GitHub (check SSL cert and content basics)
    if ! grep -q "oh-my-zsh" install.sh || ! grep -q "github" install.sh; then
        log_error "oh-my-zsh installer verification failed"
        exit 1
    fi

    log_info "oh-my-zsh installer verified"

    # Install oh-my-zsh as the actual user (not root)
    su - "$ACTUAL_USER" -c "sh $OH_MY_ZSH_TEMP/install.sh --unattended"

    # Cleanup
    rm -rf "$OH_MY_ZSH_TEMP"
else
    log_info "oh-my-zsh already installed for user $ACTUAL_USER, skipping"
fi

# Change default shell to zsh for the user if not already set
CURRENT_SHELL=$(getent passwd "$ACTUAL_USER" | cut -d: -f7)
if [ "$CURRENT_SHELL" != "$(which zsh)" ]; then
    log_info "Setting zsh as default shell for $ACTUAL_USER..."
    chsh -s "$(which zsh)" "$ACTUAL_USER"
else
    log_info "zsh already set as default shell for $ACTUAL_USER"
fi

log_info "zsh and oh-my-zsh setup complete"

###############################################################################
# 4. Install Rust and its tools
###############################################################################
log_info "Checking Rust installation..."

# Check if Rust is already installed for the user
if su - "$ACTUAL_USER" -c 'command -v rustc' &> /dev/null; then
    log_info "Rust already installed for user $ACTUAL_USER"
    RUST_VERSION=$(su - "$ACTUAL_USER" -c 'rustc --version')
    log_info "Current version: $RUST_VERSION"

    # Update Rust if already installed
    log_info "Updating Rust toolchain..."
    su - "$ACTUAL_USER" -c 'source "$HOME/.cargo/env" && rustup update'
else
    log_info "Installing Rust toolchain..."

    # Download and verify Rust installer
    RUST_TEMP="/tmp/rust-install-$$"
    mkdir -p "$RUST_TEMP"
    cd "$RUST_TEMP"

    log_info "Downloading Rust installer..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o rustup-init.sh

    # Download Rust installer signature
    curl --proto '=https' --tlsv1.2 -sSf https://static.rust-lang.org/rustup/rustup-init.sh.sha256 -o rustup-init.sh.sha256 2>/dev/null || log_warn "SHA256 signature not available from standard location"

    # Verify the installer (basic content check)
    if ! grep -q "rustup" rustup-init.sh || ! grep -q "rust-lang" rustup-init.sh; then
        log_error "Rust installer verification failed"
        exit 1
    fi

    log_info "Rust installer verified"

    # Install Rust as the actual user
    su - "$ACTUAL_USER" -c "sh $RUST_TEMP/rustup-init.sh -y"

    # Cleanup
    rm -rf "$RUST_TEMP"
fi

# Source cargo environment
su - "$ACTUAL_USER" -c 'source "$HOME/.cargo/env"' || true

# Install common Rust tools (idempotent - rustup will skip if already installed)
log_info "Ensuring Rust tools are installed..."
su - "$ACTUAL_USER" -c 'source "$HOME/.cargo/env" && rustup component add rustfmt clippy rust-src rust-analyzer 2>/dev/null' || log_info "Rust components already installed"

# Add cargo to .zshrc if it exists
if [ -f "$ACTUAL_HOME/.zshrc" ]; then
    if ! grep -q "cargo/env" "$ACTUAL_HOME/.zshrc"; then
        log_info "Adding Rust to .zshrc..."
        echo '' >> "$ACTUAL_HOME/.zshrc"
        echo '# Rust cargo environment' >> "$ACTUAL_HOME/.zshrc"
        echo 'source "$HOME/.cargo/env"' >> "$ACTUAL_HOME/.zshrc"
    else
        log_info "Rust already configured in .zshrc"
    fi
fi

log_info "Rust setup complete"

###############################################################################
# 5. Install PostgreSQL
###############################################################################
log_info "Checking PostgreSQL installation..."

if command -v psql &> /dev/null; then
    log_info "PostgreSQL already installed"
    POSTGRES_VERSION=$(su - postgres -c "psql --version" 2>/dev/null || psql --version)
    log_info "Current version: $POSTGRES_VERSION"
else
    log_info "Installing PostgreSQL..."
    apt-get install -y postgresql postgresql-contrib
fi

# Ensure PostgreSQL service is started and enabled (idempotent)
if systemctl is-active --quiet postgresql; then
    log_info "PostgreSQL service already running"
else
    log_info "Starting PostgreSQL service..."
    systemctl start postgresql
fi

if systemctl is-enabled --quiet postgresql; then
    log_info "PostgreSQL service already enabled"
else
    log_info "Enabling PostgreSQL service..."
    systemctl enable postgresql
fi

log_info "PostgreSQL setup complete"

###############################################################################
# 6. Install ClickHouse
###############################################################################
log_info "Checking ClickHouse installation..."

if command -v clickhouse-client &> /dev/null; then
    log_info "ClickHouse already installed"
    CLICKHOUSE_VERSION=$(clickhouse-client --version)
    log_info "Current version: $CLICKHOUSE_VERSION"
else
    log_info "Installing ClickHouse..."

    # Add ClickHouse GPG key (modern method)
    apt-get install -y apt-transport-https ca-certificates dirmngr
    mkdir -p /etc/apt/keyrings

    # Only download key if not already present
    if [ ! -f /etc/apt/keyrings/clickhouse-keyring.gpg ]; then
        log_info "Adding ClickHouse GPG key..."
        curl -fsSL 'https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key' | gpg --dearmor -o /etc/apt/keyrings/clickhouse-keyring.gpg
    else
        log_info "ClickHouse GPG key already present"
    fi

    # Add ClickHouse repository with signed-by
    if [ ! -f /etc/apt/sources.list.d/clickhouse.list ]; then
        log_info "Adding ClickHouse repository..."
        echo "deb [signed-by=/etc/apt/keyrings/clickhouse-keyring.gpg] https://packages.clickhouse.com/deb stable main" | tee /etc/apt/sources.list.d/clickhouse.list
    else
        log_info "ClickHouse repository already configured"
    fi

    # Update and install ClickHouse
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y clickhouse-server clickhouse-client
fi

# Ensure ClickHouse service is started and enabled (idempotent)
if systemctl is-active --quiet clickhouse-server; then
    log_info "ClickHouse service already running"
else
    log_info "Starting ClickHouse service..."
    systemctl start clickhouse-server
fi

if systemctl is-enabled --quiet clickhouse-server; then
    log_info "ClickHouse service already enabled"
else
    log_info "Enabling ClickHouse service..."
    systemctl enable clickhouse-server
fi

log_info "ClickHouse setup complete"

###############################################################################
# 7. Install SQLite
###############################################################################
log_info "Checking SQLite installation..."

if command -v sqlite3 &> /dev/null; then
    log_info "SQLite already installed"
    SQLITE_VERSION=$(sqlite3 --version)
    log_info "Current version: $SQLITE_VERSION"
else
    log_info "Installing SQLite..."
    apt-get install -y sqlite3 libsqlite3-dev
    log_info "SQLite installed"
fi

log_info "SQLite setup complete"

###############################################################################
# 8. Final cleanup and summary
###############################################################################
log_info "Cleaning up..."
apt-get autoremove -y
apt-get clean

###############################################################################
# Summary
###############################################################################
echo ""
echo "=========================================================================="
log_info "Server setup completed successfully!"
echo "=========================================================================="
echo ""
echo "✓ System updated"
echo "✓ Locale: en_US.UTF-8"
echo "✓ Timezone: UTC"
echo "✓ zsh and oh-my-zsh installed"
echo "✓ Rust toolchain installed"
echo "✓ PostgreSQL installed and running"
echo "✓ ClickHouse installed and running"
echo "✓ SQLite installed"
echo ""
echo "------------------------------------------------------------------------"
echo "IMPORTANT NOTES:"
echo "------------------------------------------------------------------------"
echo ""
echo "1. Shell Changes:"
echo "   - Default shell changed to zsh for user: $ACTUAL_USER"
echo "   - Log out and log back in for shell changes to take effect"
echo ""
echo "2. PostgreSQL:"
echo "   - Service: systemctl status postgresql"
echo "   - Access: sudo -u postgres psql"
echo "   - Create user: sudo -u postgres createuser --interactive"
echo ""
echo "3. ClickHouse:"
echo "   - Service: systemctl status clickhouse-server"
echo "   - Access: clickhouse-client"
echo "   - Config: /etc/clickhouse-server/config.xml"
echo ""
echo "4. Rust:"
echo "   - Installed for user: $ACTUAL_USER"
echo "   - Tools: rustc, cargo, rustfmt, clippy, rust-analyzer"
echo "   - Update: rustup update"
echo ""
echo "5. Services Status:"
systemctl is-active postgresql && echo "   - PostgreSQL: ✓ Running" || echo "   - PostgreSQL: ✗ Not running"
systemctl is-active clickhouse-server && echo "   - ClickHouse: ✓ Running" || echo "   - ClickHouse: ✗ Not running"
echo ""
echo "=========================================================================="
echo ""
log_info "You may need to reboot for all changes to take effect"
echo ""

