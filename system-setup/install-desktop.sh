# TigerVNC Server Installation and Configuration Script

sudo apt install dbus-x11 tigervnc-standalone-server xfce4 xfce4-terminal

sudo apt purge dosfstools eject exfatprogs gnome-accessibility-themes gnome-themes-extra gnome-themes-extra-data gnu-utils ipp-usb libgpg-error-l10n libgphoto2-l10n sane-airscan sane-utils usbmuxd xserver-xorg-legacy

vncpasswd

mkdir -p ~/.config/tigervnc
cat <<EOF > ~/.config/tigervnc/config
session=xfce
geometry=1920x1080
depth=24
securitytypes=VncAuth
localhost=no
alwaysshared
EOF

mkdir -p ~/.vnc
cat <<EOF > ~/.vnc/xstartup
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4
EOF

chmod +x ~/.vnc/xstartup

sudo tee /etc/tigervnc/vncserver.users > /dev/null <<EOF
:1=${USER}
EOF

sudo systemctl enable --now tigervncserver@:1.service

# XRDP Installation and Configuration

sudo apt install xrdp xorgxrdp xfce4 xfce4-terminal dbus-x11
sudo adduser xrdp ssl-cert

Edit /etc/xrdp/startwm.sh and replace the last line with:

    #!/bin/sh
    if [ -r /etc/default/locale ]; then
        . /etc/default/locale
        export LANG LANGUAGE
    fi

    unset DBUS_SESSION_BUS_ADDRESS
    unset XDG_RUNTIME_DIR

    exec startxfce4


sudo mkdir -p /etc/xrdp/certs
sudo openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout /etc/xrdp/certs/key.pem -out /etc/xrdp/certs/cert.pem \
    -days 365 -subj "/CN=$(hostname)"
sudo chown -R xrdp:xrdp /etc/xrdp/certs
sudo chmod 0600 /etc/xrdp/certs/key.pem


Edit /etc/xrdp/xrdp.ini and set the following parameters:

    security_layer=tls
    certificate=/etc/xrdp/certs/cert.pem
    key_file=/etc/xrdp/certs/key.pem
    ssl_protocols=TLSv1.2, TLSv1.3


sudo systemctl enable --now xrdp
