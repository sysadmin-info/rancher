#!/bin/bash -e

REALUSER="${SUDO_USER:-${USER}}"
echo "$REALUSER"
# Remove files
cd /home/$REALUSER
rm -f *.srl *.yaml *.crt *.csr *.key *.pem rancher.c* rancher.k* tls.* *.conf *.txt 
rm -rf /tmp/ca

# Function to check for file existence and execute it
execute_if_exists() {
    local file_path="$1"
    local description="$2"
    if [ -f "$file_path" ]; then
        echo "Executing ${description}..."
        sh "$file_path"
    else
        echo "${description} does not exist in ${file_path%/*}."
    fi
}

# Function to configure iptables
configure_iptables() {
    iptables-save | awk '/^[*]/ { print $1 } /COMMIT/ { print $0; }' | sudo iptables-restore
    iptables -S
    iptables -F
    update-alternatives --set iptables /usr/sbin/iptables-legacy
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
}

# Check if the user is root
if [ "$UID" -ne 0 ]; then
    echo "You are not the root user."
    exit 1
fi

echo "You are the root user."

# Executions
execute_if_exists "/usr/local/bin/k3s-killall.sh" "k3s-killall.sh"
execute_if_exists "/usr/local/bin/k3s-uninstall.sh" "k3s-uninstall.sh"

# Check and remove helm
if [ -f "/usr/local/bin/helm" ]; then
    echo "Removing helm..."
    rm -f /usr/local/bin/helm
else
    echo "Helm does not exist in /usr/local/bin."
fi

# Configure iptables
configure_iptables
