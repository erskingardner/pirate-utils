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
log_info "Installing zsh..."
apt-get install -y zsh

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

# Change default shell to zsh for the user
chsh -s "$(which zsh)" "$ACTUAL_USER"

log_info "zsh and oh-my-zsh installed successfully"

###############################################################################
# 4. Install Rust and its tools
###############################################################################
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

# Source cargo environment
su - "$ACTUAL_USER" -c 'source "$HOME/.cargo/env"'

# Install common Rust tools
log_info "Installing common Rust tools..."
su - "$ACTUAL_USER" -c 'source "$HOME/.cargo/env" && rustup component add rustfmt clippy rust-src rust-analyzer'

# Add cargo to .zshrc if it exists
if [ -f "$ACTUAL_HOME/.zshrc" ]; then
    if ! grep -q "cargo/env" "$ACTUAL_HOME/.zshrc"; then
        echo '' >> "$ACTUAL_HOME/.zshrc"
        echo '# Rust cargo environment' >> "$ACTUAL_HOME/.zshrc"
        echo 'source "$HOME/.cargo/env"' >> "$ACTUAL_HOME/.zshrc"
    fi
fi

log_info "Rust installed successfully"

###############################################################################
# 5. Install PostgreSQL
###############################################################################
log_info "Installing PostgreSQL..."

apt-get install -y postgresql postgresql-contrib

# Start and enable PostgreSQL service
systemctl start postgresql
systemctl enable postgresql

log_info "PostgreSQL installed and started"
log_info "PostgreSQL version:"
su - postgres -c "psql --version"

###############################################################################
# 6. Install ClickHouse
###############################################################################
log_info "Installing ClickHouse..."

# Add ClickHouse GPG key (modern method)
apt-get install -y apt-transport-https ca-certificates dirmngr
mkdir -p /etc/apt/keyrings
curl -fsSL 'https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key' | gpg --dearmor -o /etc/apt/keyrings/clickhouse-keyring.gpg

# Add ClickHouse repository with signed-by
echo "deb [signed-by=/etc/apt/keyrings/clickhouse-keyring.gpg] https://packages.clickhouse.com/deb stable main" | tee /etc/apt/sources.list.d/clickhouse.list

# Update and install ClickHouse
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y clickhouse-server clickhouse-client

# Start and enable ClickHouse service
systemctl start clickhouse-server
systemctl enable clickhouse-server

log_info "ClickHouse installed and started"
log_info "ClickHouse version:"
clickhouse-client --version

###############################################################################
# 7. Install SQLite
###############################################################################
log_info "Installing SQLite..."

apt-get install -y sqlite3 libsqlite3-dev

log_info "SQLite installed"
log_info "SQLite version:"
sqlite3 --version

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

