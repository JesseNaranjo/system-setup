# gnome dconf

Use `dconf dump /` to export the current configuration.

And use `dconf load / < dconf-settings.ini` to load the file back in.

## dconf-settings.ini
```ini
[org/gnome/calculator]
button-mode='advanced'
number-format='automatic'
show-thousands=true

[org/gnome/desktop/background]
color-shading-type='solid'
picture-options='zoom'
primary-color='#ac5e0b'
secondary-color='#000000'

[org/gnome/desktop/interface]
clock-format='12h'
clock-show-weekday=true
color-scheme='prefer-dark'
enable-hot-corners=true
font-antialiasing='rgba'
font-hinting='full'
locate-pointer=true
show-battery-percentage=true

[org/gnome/desktop/media-handling]
autorun-never=true
autorun-x-content-ignore=@as []
autorun-x-content-open-folder=@as []
autorun-x-content-start-app=['x-content/ostree-repository']

[org/gnome/desktop/peripherals/mouse]
speed=0.6

[org/gnome/desktop/peripherals/touchpad]
natural-scroll=false
speed=0.4
tap-to-click=true
two-finger-scrolling-enabled=true

[org/gnome/desktop/privacy]
disable-camera=true
old-files-age=uint32 30
recent-files-max-age=-1
remove-old-temp-files=true
remove-old-trash-files=true
report-technical-problems=true

[org/gnome/desktop/screensaver]
color-shading-type='solid'
picture-options='zoom'
primary-color='#ac5e0b'
secondary-color='#000000'

[org/gnome/desktop/wm/keybindings]
cycle-group=['<Super>grave']
cycle-group-backward=['<Shift><Super>grave']
minimize=['<Super>m']
switch-group=@as []
switch-group-backward=@as []

[org/gnome/desktop/wm/preferences]
button-layout='close,minimize,maximize:appmenu'
num-workspaces=1

[org/gnome/mutter]
dynamic-workspaces=false
workspaces-only-onprimary=false

[org/gnome/settings-daemon/plugins/power]
power-button-action='nothing'
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'

[org/gnome/shell]
enabled-extensions=['places-menu@gnome-shell-extensions.gcampax.github.com', 'dash-to-dock@micxgx.gmail.com']

[org/gnome/shell/extensions/dash-to-dock]
apply-custom-theme=true
background-opacity=0.80000000000000004
custom-theme-shrink=false
dash-max-icon-size=48
dock-position='BOTTOM'
extend-height=false
height-fraction=0.90000000000000002
hot-keys=false
icon-size-fixed=false
intellihide-mode='FOCUS_APPLICATION_WINDOWS'
middle-click-action='launch'
preferred-monitor=-2
preferred-monitor-by-connector='DP-2'
preview-size-scale=0.0
require-pressure-to-show=false
shift-click-action='minimize'
shift-middle-click-action='launch'
show-apps-at-top=true
show-mounts=false

[org/gnome/shell/keybindings]
toggle-message-tray=@as []

[org/gnome/shell/world-clocks]
locations=@av []

[org/gnome/software]
allow-updates=false
download-updates=false

[org/gnome/system/location]
enabled=false

[org/gnome/terminal/legacy]
menu-accelerator-enabled=false
mnemonics-enabled=false
new-terminal-mode='tab'
theme-variant='dark'

[org/gnome/terminal/legacy/profiles:/:b1dcc9dd-5262-4d8d-a863-c897e6d979b9]
default-size-columns=132
default-size-rows=30
visible-name='Default'

[org/gtk/gtk4/settings/file-chooser]
show-hidden=true
sort-directories-first=true
```
