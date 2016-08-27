#!/usr/bin/env bash

# Add the (possibly) missing bits to the VM prepared by Netgen so that it can be accessed from the host machine
#
# To be run as root

ID="$(id -u)"
if [ $ID -ne 0 ]; then
    echo "Please run this script as root"
    exit 1
fi

# ssh

apt-get install -y -qq openssh-server samba

# firewall

ufw disable

# samba

cat <<EOT >> /etc/samba/smb.cfg

[www]
    path = /var/www
    browseable = yes
    read only = no
    force user = websc
    force group = www-websc
    create mask = 0664
    follow symlinks = yes
    wide links = yes

EOT

echo -ne "websc\nwebsc\n" | smbpasswd -a -s nwebsc

service smbd restart

# disabling default starting into GUI mode:

# see http://ask.xmodulo.com/boot-into-command-line-ubuntu-debian.html
