#!/usr/bin/env bash
#----------------------------------------------------------------------------
#
# Pre-install script 
#
#----------------------------------------------------------------------------

cd /root
git clone https://github.com/Neilpang/acme.sh.git

echo "Create directories..."

mkdir /etc/acme
mkdir /var/log/acme

echo "Copy files..."

cp /root/acme.sh/acme.sh /usr/local/bin
cp /root/acmemgr.sh/acmemgr.sh /usr/local/bin
cp /root/acmemgr.sh/acmemgr.db /etc/acme
cp /root/acmemgr.sh/examples/*.certops /etc/acme
cp /root/acmemgr.sh/examples/*.reload /etc/acme

echo "Populate files..."

cat <<EOF >/etc/logrotate.d/acme
/var/log/acme/acmemgr.log {
  rotate 12
  monthly
  compress
  missingok
  notifempty
}
EOF

#----------------------------------------------------------------------------
# EOF
#----------------------------------------------------------------------------