set -eu
IP=54.200.204.171; A="ssh -i $HOME/.ssh/cloakvpn_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes admin@$IP"; W="ssh -o BatchMode=yes root@5.78.203.171"
R="$HOME/Documents/Claude/Projects/Cloak VPN App - Business Opportunity/cloak-vpn/server/cnsa2-ca"
echo "== packages"
$A 'sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-venv wireguard-tools unattended-upgrades >/dev/null 2>&1; echo "installed: $(dpkg -l python3-venv wireguard-tools unattended-upgrades | grep -c ^ii)/3"; sudo fallocate -l 512M /swapfile 2>/dev/null && sudo chmod 600 /swapfile && sudo mkswap -q /swapfile && sudo swapon /swapfile && echo "/swapfile none swap sw 0 0" | sudo tee -a /etc/fstab >/dev/null; free -m | awk "/Swap:/{print \"swap MB:\", \$2}"'
echo "== files"
$A 'sudo install -d -m 755 /opt/lattice-ca /opt/lattice-ca/certs; sudo install -d -m 700 /etc/lattice-ca; sudo useradd --system --home /var/lib/lattice-ca --shell /usr/sbin/nologin latticeca 2>/dev/null || true; sudo install -d -m 700 -o latticeca -g latticeca /var/lib/lattice-ca; mkdir -p /tmp/up'
scp -q -i $HOME/.ssh/cloakvpn_ed25519 -o IdentitiesOnly=yes "$R/latticeca.py" "$R/signing_service.py" "$R/certs/root-ca.pem" "$R/certs/issuing-ca.pem" admin@$IP:/tmp/up/
$A 'sudo install -m 644 /tmp/up/latticeca.py /tmp/up/signing_service.py /opt/lattice-ca/ && sudo install -m 644 /tmp/up/root-ca.pem /tmp/up/issuing-ca.pem /opt/lattice-ca/certs/ && rm -rf /tmp/up; sudo python3 -m venv /opt/lattice-ca/venv && sudo /opt/lattice-ca/venv/bin/pip install -q boto3 2>&1 | tail -1; /opt/lattice-ca/venv/bin/python -c "import boto3; print(\"boto3\", boto3.__version__)"; sha256sum /opt/lattice-ca/certs/root-ca.pem | cut -c1-16'
echo "== private link keys"
SPUB=$($A 'sudo sh -c "umask 077; [ -f /etc/wireguard/wgca.key ] || wg genkey > /etc/wireguard/wgca.key; wg pubkey < /etc/wireguard/wgca.key"')
WPUB=$($W 'umask 077; [ -f /etc/wireguard/wgsigner.key ] || wg genkey > /etc/wireguard/wgsigner.key; wg pubkey < /etc/wireguard/wgsigner.key' 2>/dev/null | tail -1)
echo "signer pub ${SPUB:0:8}... api pub ${WPUB:0:8}..."
$A "sudo sh -c 'umask 077; cat > /etc/wireguard/wgca.conf <<C
# Private link to the account API server (us-west-1). Nothing else may connect.
[Interface]
Address = 10.200.0.2/30
ListenPort = 51821
PostUp = wg set %i private-key /etc/wireguard/wgca.key
[Peer]
PublicKey = $WPUB
AllowedIPs = 10.200.0.1/32
C
systemctl enable -q --now wg-quick@wgca; wg show wgca | head -3'"
$W "umask 077; cat > /etc/wireguard/wgsigner.conf <<C
# Private link from the account API to the CNSA 2.0 signing service on AWS.
# Separate from wg0 (customer tunnel); carries only API-to-signer requests.
[Interface]
Address = 10.200.0.1/30
PostUp = wg set %i private-key /etc/wireguard/wgsigner.key
[Peer]
PublicKey = $SPUB
Endpoint = $IP:51821
AllowedIPs = 10.200.0.2/32
PersistentKeepalive = 25
C
systemctl enable -q --now wg-quick@wgsigner; sleep 3; echo \"link ping: \$(ping -c 3 -W 2 10.200.0.2 | grep -o '[0-9]* received')\"; echo \"wg0 untouched: peers \$(wg show wg0 | grep -c '^peer'), regionsvc \$(systemctl is-active regionsvc), api \$(systemctl is-active cloakvpn-api)\"" 2>&1 | grep -v Pseudo
