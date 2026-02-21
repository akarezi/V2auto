# V2auto

[![Linux Compatible](https://img.shields.io/badge/platform-linux-lightgrey.svg)](https://www.linux.org/)
[![Bash Script](https://img.shields.io/badge/language-bash-4EAA25.svg)](https://www.gnu.org/software/bash/)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**V2auto** is a high-performance, automated V2Ray/Xray configuration tester and subscription manager. It streamlines the process of fetching, validating, and deploying proxy configurations directly into **3x-ui** environments, ensuring your VPN infrastructure always remains active with the best available nodes.

---

## Table of Contents
- [Features](#-features)
- [How It Works](#-how-it-works)
- [Requirements](#-requirements)
- [One-Line Install](#-one-line-install-command)
- [Standard Installation](#-standard-installation)
- [Alternative Installation](#-alternative-installation-via-zip)
- [Usage Guide](#-usage-guide)
- [Project Structure](#-project-structure)
- [Update Instructions](#-update-instructions)
- [Uninstall Instructions](#-uninstall-instructions)
- [Security Notice](#-security-notice)
- [Contributing](#-contributing)
- [License](#-license)

---

## ✨ Features

- **Automated Testing**: Multi-threaded engine for rapid latency and availability checks.
- **Protocol Support**: Handles VMess, VLess, Trojan, and Shadowsocks configurations.
- **Smart Filtering**: Automatically filters working nodes based on latency and success rate.
- **3x-ui Integration**: Direct injection of working configurations into the 3x-ui SQLite database.
- **Daemon Mode**: Continuous monitoring with automated refreshes at configurable intervals.
- **Clean Output**: Generates a unified subscription file and individual working configuration lists.
- **Self-Contained**: Automatically manages its own Xray-core binary and system dependencies.

---

## ⚙️ How It Works

V2auto operates as a modular pipeline:
1. **Ingestion**: Fetches raw configurations from subscription URLs or local files defined in `subs.txt`.
2. **Parsing**: Normalizes various proxy formats into a standard internal JSON representation.
3. **Validation**: Spawns multiple Xray instances to perform real-world connectivity tests.
4. **Optimization**: Ranks nodes by performance and selects the "Top-N" best-performing configurations.
5. **Deployment**: Updates the 3x-ui database and restarts the proxy service to apply changes.

---

## 📦 Requirements

- **Operating System**: Ubuntu 22.04+ or Debian 11+ (Recommended).
- **Architecture**: x86_64 (amd64).
- **Privileges**: Root access is required for installation and service management.
- **Pre-requisites**: [3x-ui](https://github.com/MHSanaei/3x-ui) should be installed and configured.

---

## 🚀 One-Line Install Command

Run the following command to clone the repository and start the automated installation:

```bash
git clone https://github.com/akarezi/V2auto.git && cd V2auto && chmod +x install.sh && sudo ./install.sh
```

---

## 🛠 Standard Installation

For users who prefer a manual step-by-step approach:

1. **Clone the repository**:
   ```bash
   git clone https://github.com/akarezi/V2auto.git
   cd V2auto
   ```

2. **Run the installer**:
   ```bash
   chmod +x install.sh
   sudo ./install.sh
   ```

3. **Configure your sources**:
   Edit the subscription file to add your links:
   ```bash
   nano /opt/v2auto/subs.txt
   ```

---

## 📦 Alternative Installation via ZIP

If `git` is not available on your system:

```bash
wget https://github.com/akarezi/V2auto/archive/refs/heads/main.zip
unzip main.zip
cd V2auto-main
chmod +x install.sh
sudo ./install.sh
```

---

## 🧭 Usage Guide

### Manual Execution
To run a one-time check and deployment:
```bash
/opt/v2auto/v2auto.sh
```

### Dry Run (Test Only)
To test configurations without deploying to 3x-ui:
```bash
/opt/v2auto/v2auto.sh --dry-run -v
```

### Service Management
V2auto installs a systemd service that runs in the background:

- **Start Service**: `systemctl start V2auto`
- **Stop Service**: `systemctl stop V2auto`
- **Enable on Boot**: `systemctl enable V2auto`
- **Check Logs**: `journalctl -u V2auto -f`

---

## 📁 Project Structure

```text
/opt/v2auto/
├── core/               # Modular engine components
│   ├── health_monitor.sh
│   ├── input_engine.sh
│   ├── logger.sh
│   ├── optimizer.sh
│   ├── parser_engine.sh
│   └── test_engine.sh
├── output/             # Generated working configurations
├── logs/               # Execution and system logs
├── backup/             # Automatic database backups
├── v2auto.sh           # Main orchestrator script
├── install.sh          # System installer
├── subs.txt            # Your subscription sources
└── xray                # Managed Xray-core binary
```

---

## 🔄 Update Instructions

To update V2auto to the latest version, pull the latest changes and re-run the installer:

```bash
cd ~/V2auto  # Navigate to your clone directory
git pull
sudo ./install.sh
```
*Note: The installer is designed to preserve your `subs.txt` during updates.*

---

## 🗑 Uninstall Instructions

To remove V2auto from your system:

1. **Stop and disable the service**:
   ```bash
   sudo systemctl stop V2auto
   sudo systemctl disable V2auto
   ```

2. **Remove system files**:
   ```bash
   sudo rm /etc/systemd/system/V2auto.service
   sudo rm /etc/logrotate.d/v2auto
   sudo systemctl daemon-reload
   ```

3. **Delete the installation directory**:
   ```bash
   sudo rm -rf /opt/v2auto
   ```

---

## 🔐 Security Notice

- **Root Privileges**: This script requires root access to interact with `systemd` and the `3x-ui` database. Always review the source code before running scripts with sudo.
- **Privacy**: V2auto does not collect or transmit any personal data. All testing and processing occur locally on your VPS.
- **Database Safety**: The script performs an automatic backup of your 3x-ui database before every deployment.

---

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request. For major changes, please open an issue first to discuss what you would like to change.

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

---

## 📜 License

Distributed under the MIT License. See `LICENSE` for more information.

```text
Copyright (c) 2024 akarezi

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:
...
```
