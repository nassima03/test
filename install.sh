#!/bin/bash
# Script d'installation Arch Linux avec LUKS, LVM et une partition /boot séparée

# Vérification root
if [ "$EUID" -ne 0 ]; then
  echo "Veuillez exécuter ce script en tant que root."
  exit 1
fi

# Définition du disque
DISK="/dev/sda"

# Partitionnement
parted --script $DISK mklabel gpt
parted --script $DISK mkpart primary fat32 1MiB 513MiB
parted --script $DISK set 1 esp on
parted --script $DISK mkpart primary ext4 513MiB 1GiB
parted --script $DISK mkpart primary 1GiB 100%

# Cryptsetup
echo -n "azerty123" | cryptsetup luksFormat --type luks2 ${DISK}3 -
echo -n "azerty123" | cryptsetup open ${DISK}3 cryptroot

# LVM
pvcreate /dev/mapper/cryptroot
vgcreate vg0 /dev/mapper/cryptroot
lvcreate -L 30G -n root vg0
lvcreate -L 8G -n swap vg0
lvcreate -L 10G -n encrypted vg0
lvcreate -L 5G -n shared vg0
lvcreate -l 100%FREE -n home vg0

# Formatage
mkfs.fat -F32 ${DISK}1
mkfs.ext4 ${DISK}2
mkfs.ext4 /dev/vg0/root
mkfs.ext4 /dev/vg0/home
mkfs.ext4 /dev/vg0/shared
mkswap /dev/vg0/swap
swapon /dev/vg0/swap

# Partition chiffrée supplémentaire
echo -n "azerty123" | cryptsetup luksFormat --type luks2 /dev/vg0/encrypted -
echo -n "azerty123" | cryptsetup open /dev/vg0/encrypted encrypted_volume
mkfs.ext4 /dev/mapper/encrypted_volume
cryptsetup close encrypted_volume

# Montage
mount /dev/vg0/root /mnt
mkdir -p /mnt/boot
mount ${DISK}2 /mnt/boot
mkdir -p /mnt/efi
mount ${DISK}1 /mnt/efi
mkdir -p /mnt/home
mount /dev/vg0/home /mnt/home
mkdir -p /mnt/shared
mount /dev/vg0/shared /mnt/shared

# Installation base
pacstrap /mnt base linux linux-firmware lvm2 vim networkmanager

# Fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Configuration système
arch-chroot /mnt /bin/bash <<EOF
# Région
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc

# Langue
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Réseau
echo "archbox" > /etc/hostname
echo "127.0.0.1 localhost" >> /etc/hosts
echo "::1       localhost" >> /etc/hosts
echo "127.0.1.1 archbox.localdomain archbox" >> /etc/hosts
systemctl enable NetworkManager

# Utilisateurs
echo "root:azerty123" | chpasswd
useradd -m -G wheel colleague
echo "colleague:azerty123" | chpasswd
useradd -m son
echo "son:azerty123" | chpasswd

# Sudo
pacman -S sudo --noconfirm
echo '%wheel ALL=(ALL) ALL' >> /etc/sudoers

# Paquets supplémentaires
pacman -Syu --noconfirm
pacman -S virtualbox virtualbox-host-dkms linux-headers firefox gcc make htop neofetch git base-devel xorg-server xorg-xinit hyprland wayland xorg-xwayland alacritty --noconfirm

# Dossier partagé
groupadd shared
usermod -aG shared colleague
usermod -aG shared son
chown :shared /shared
chmod 770 /shared

# GRUB
pacman -S grub efibootmgr --noconfirm
echo "GRUB_CMDLINE_LINUX=\\"cryptdevice=${DISK}3:cryptroot root=/dev/mapper/vg0-root\\"" >> /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Initramfs
sed -i 's/^HOOKS=(.*)/HOOKS=(base udev autodetect keyboard keymap modconf block encrypt lvm2 filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

EOF

# Nettoyage
umount -R /mnt
swapoff -a

echo "Installation terminée ! Redémarrez le système."
