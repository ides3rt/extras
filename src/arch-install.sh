#!/usr/bin/env bash

# Load my keymaps
URL=https://raw.githubusercontent.com/ides3rt/colemak-dhk/master/src/colemak-dhk.map
curl -O "$URL"; gzip "${URL##*/}"
loadkeys "${URL##*/}".gz
unset -v URL

# Partition, format, and mount the drive
PS3='Select your disk: '
select Disk in $(lsblk -dno PATH); do
	[[ -z $Disk ]] && continue

	parted "$Disk" mklabel gpt
	sgdisk "$Disk" -n=1:0:+512M -t=1:ef00
	sgdisk "$Disk" -n=2:0:0

	[[ $Disk == *nvme* ]] && P=p
	mkfs.fat -F 32 -n EFI "$Disk$P"1
	mkfs.btrfs -f -L Arch "$Disk$P"2

	mount "$Disk$P"2 /mnt
	for Subvol in @ @home @opt @root @srv @local \
		@cache @log @spool @tmp
	do
		btrfs su cr "$Subvol"
	done; unset -v Subvol
	umount /mnt

	mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,autodefrag,subvol=@ "$Disk$P"2 /mnt
	mkdir -p /mnt/{home,opt,root,srv,usr/local}
	mkdir -p /mnt/var/{cache,log,spool,tmp}
	mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,autodefrag,subvol=@home "$Disk$P"2 /mnt/home
	mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,autodefrag,subvol=@opt "$Disk$P"2 /mnt/opt
	mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,autodefrag,subvol=@root "$Disk$P"2 /mnt/root
	mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,autodefrag,subvol=@srv "$Disk$P"2 /mnt/srv
	mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,autodefrag,subvol=@local "$Disk$P"2 /mnt/usr/local
	mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,autodefrag,subvol=@cache "$Disk$P"2 /mnt/var/cache
	mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,autodefrag,subvol=@log "$Disk$P"2 /mnt/var/log
	mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,autodefrag,subvol=@spool "$Disk$P"2 /mnt/var/spool
	mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,autodefrag,subvol=@tmp "$Disk$P"2 /mnt/var/tmp

	mkdir /mnt/boot
	mount -o nosuid,nodev,noexec,noatime,fmask=0177,dmask=0077 "$Disk$P"2 /mnt/boot

done
export Disk

# Detect CPU
while read VendorID; do
	[[ "$VendorID" == *vendor_id* ]] && break
done < /proc/cpuinfo
case "$VendorID" in
	*AMD*)
		export CPU=amd ;;
	*Intel*)
		export CPU=intel ;;
esac
unset -v VendorID

# Install base packages
pacstrap /mnt base base-devel linux linux-firmware neovim "$CPU"-ucode

# Generate FSTAB
genfstab -U /mnt > /mnt/etc/fstab
echo 'tmpfs /tmp tmpfs nosuid,nodev,noatime,size=6G 0 0' >> /mnt/etc/fstab
echo 'tmpfs /dev/shm tmpfs nosuid,nodev,noexec,noatime,size=1G 0 0' >> /mnt/etc/fstab
echo 'proc /proc proc nosuid,nodev,noexec,gid=proc,hidepid=2 0 0' >> /mnt/etc/fstab

Postinstall() {
	# Set date and time
	printf '%s\n' "Date/time format is 'yyyy-mm-dd HH:nn:ss'..."
	read -p 'Enter your current date/time: ' Date
	hwclock --set --date="$Date"
	hwclock --hctosys
	unset -v Date

	# Set locale
	echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
	locale-gen
	echo 'LANG=en_US.UTF-8' > /etc/locale.conf

	# Hostname
	read -p 'Your hostname: ' Hostname
	echo "$Hostname" > /etc/hostname
	unset -v Hostname

	# Networking
	echo '127.0.0.1 localhost' >> /etc/hosts
	echo '::1 localhost' >> /etc/hosts
	systemctl enable systemd-networkd systemd-resolved

	while read; do
		printf '%s\n' "$REPLY"
	done <<-EOF > /etc/systemd/network/20-dhcp.network
		[Match]
		Name=*

		[Network]
		DHCP=yes
		IPv6AcceptRA=true
		DNSOverTLS=yes
		DNSSEC=yes
		DNS=45.90.28.0#3579e8.dns1.nextdns.io
		DNS=2a07:a8c0::#3579e8.dns1.nextdns.io

		[DHCP]
		UseDNS=false

		[IPv6AcceptRA]
		UseDNS=false
	EOF

	# Install bootloader
	echo "ParallelDownloads = $(( $(nproc) + 1 ))" >> /etc/pacman.conf
	pacman -S --noconfirm efibootmgr dosfstools opendoas

	if [[ $Disk == *nvme* ]]; then
		Modules=nvme
	else
		Modules='ahci sd_mod'
	fi

	while read; do
		printf '%s\n' "$REPLY"
	done <<-EOF > /etc/mkinitcpio.d/linux.preset
		# mkinitcpio preset file for the 'linux' package

		ALL_config="/etc/mkinitcpio.conf"
		ALL_kver="/boot/vmlinuz-linux"

		PRESETS=('default')

		default_image="/boot/initramfs-linux.img"

		fallback_image="/boot/initramfs-linux-fallback.img"
		fallback_options="-S autodetect"
	EOF

	while read; do
		printf '%s\n' "$REPLY"
	done <<-EOF > /etc/mkinitcpio.conf
		MODULES=($Modules btrfs)
		BINARIES=()
		FILES=()
		HOOKS=(base modconf)
		COMPRESSION="xz"
		COMMPRESSION_OPTIONS=(-9 -e -T0)
	EOF

	rm -f /boot/initramfs-linux-fallback.img
	mkinitcpio -P

	# Install Zram
	URL=https://raw.githubusercontent.com/ides3rt/extras/master/src/zram-setup.sh
	curl -O "$URL"; bash "${URL##*/}"
	unset -v URL

	# Install bootloader to UEFI
	System=$(findmnt -o UUID / | tail -n 1)
	efibootmgr --disk "$Disk" --part 1 --create \
		--label 'Arch Linux' \
		--loader '\vmlinuz-linux' \
		--unicode "root=UUID=$System rootflags=subvolid=256 ro initrd=\\$CPU-ucode.img initrd=\\initramfs-linux.img quiet libahci.ignore_sss=1 zswap.enabled=0"
	unset -v System ESPPosition FSSys Disk Modules CPU

	PS3='Select your GPU [1-3]: '
	select GPU in xf86-video-amdgpu xf86-video-intel nvidia; do
		[[ -n $GPU ]] && break
	done

	# Install additional packages
	pacman -S dash "$GPU" linux-headers xorg-server xorg-xinit xorg-xsetroot \
		xorg-xrandr git wget man-db htop ufw bspwm man-pages rxvt-unicode feh \
		maim exfatprogs picom rofi pipewire mpv pigz pacman-contrib aria2 \
		arc-solid-gtk-theme papirus-icon-theme terminus-font zip unzip p7zip \
		pbzip2 fzf pv rsync bc yt-dlp dunst rustup sccache xdotool xcape pwgen \
		dbus-broker tmux links perl-image-exiftool firefox-developer-edition \
		archiso sxhkd xclip
	pacman -S --asdeps qemu edk2-ovmf memcached libnotify \
		pipewire-pulse bash-completion
	unset -v GPU

	# Configuration1
	ufw enable
	systemctl disable dbus
	systemctl enable dbus-broker fstrim.timer avahi-daemon ufw
	systemctl --global enable dbus-broker pipewire-pulse
	ln -sf bin /usr/local/sbin
	ln -sf /usr/share/fontconfig/conf.avail/10-hinting-slight.conf /etc/fonts/conf.d/
	ln -sf /usr/share/fontconfig/conf.avail/10-sub-pixel-rgb.conf /etc/fonts/conf.d/
	ln -sf /usr/share/fontconfig/conf.avail/11-lcdfilter-default.conf /etc/fonts/conf.d/

	# Configuration2
	ln -sfT dash /bin/sh
	groupadd -r doas; groupadd -r fstab
	echo 'permit nolog :doas' > /etc/doas.conf
	chmod 640 /etc/doas.conf /etc/fstab
	chown :doas /etc/doas.conf; chown :fstab /etc/fstab
	sed -i '/required/s/#//' /etc/pam.d/su
	sed -i '/required/s/#//' /etc/pam.d/su-l

	# Define groups
	Groups='proc,games,dbus,scanner,fstab,doas,users'
	Groups+=',video,render,lp,kvm,input,audio,wheel'

	# Create user
	while :; do
		read -p 'Your username: ' Username
		useradd -mG "$Groups" "$Username"
		passwd "$Username" && break
	done
	unset -v Groups

	# Download my keymaps
	URL=https://raw.githubusercontent.com/ides3rt/colemak-dhk/master/installer.sh
	curl -O "$URL"; bash "${URL##*/}"
	unset -v URL

	# My keymap
	File=/etc/vconsole.conf
	echo 'KEYMAP=colemak-dhk' > "$File"
	echo 'FONT=ter-118b' >> "$File"
	unset -v File
}

arch-chroot /mnt <<-EOF
	Postinstall
EOF
