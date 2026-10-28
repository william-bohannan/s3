

uname -m

# Example for x86_64 (amd64) — replace version with the latest from GitHub releases
curl -fLO https://github.com/rustfs/cli/releases/download/v0.1.36/rustfs-cli-linux-amd64-v0.1.36.tar.gz
tar -xzf rustfs-cli-linux-amd64-v0.1.36.tar.gz
sudo install -m 0755 rc /usr/local/bin/rc

# Confirm installation
rc --version
rc --help

# Set an alias (replace with your endpoint and credentials)
rc alias set local http://your-rustfs-host:9000 ACCESS_KEY SECRET_KEY

# Test
rc alias list
rc admin info cluster local