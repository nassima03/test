#!/bin/bash

# ✅ Vérification si le script est exécuté en root
if [ "$EUID" -ne 0 ]; then
    echo "Ce script doit être exécuté en tant que root."
    exit 1
fi

# 🔹 Définition des variables
DISK="/dev/sda"
PASSWORD="azerty123"
HOSTNAME="arch-vm"

# ✅ Partitionnement du disque
parted --script $DISK mklabel gpt
parted --script $DISK mkpart primary fat32 1MiB 513MiB
parted --script $DISK set 1 esp on
parted --script $DISK mkpart primary ext4 513MiB 1GiB
parted --script $DISK mkpart primary 1GiB 100%

# ✅ Chiffrement de la partition principale
echo -n "$PASSWORD" | cryptsetup luksFormat --type luks2 ${DISK}3 -
echo -n "$PASSWORD" | cryptsetup open ${DISK}3 cryptlvm

# 📌 Vérification : Est-ce que cryptlvm est bien ouvert ?
ls /dev/mapper/
if [ ! -e "/dev/mapper/cryptlvm" ]; then
    echo "Erreur : Le chiffrement LUKS a échoué."
    exit 1
fi

# ✅ Création du volume LVM
pvcreate /dev/mapper/cryptlvm
vgcreate vg0 /dev/mapper/cryptlvm
lvcreate -L 30G -n root vg0
lvcreate -L 8G -n swap vg0
lvcreate -L 10G -n encrypted vg0
lvcreate -L 5G -n shared vg0
lvcreate -L 10G -n vbox vg0
lvcreate -l 100%FREE -n home vg0

# ✅ Formatage des partitions
mkfs.fat -F32 ${DISK}1
mkfs.ext4 ${DISK}2
mkfs.ext4 /dev/vg0/root
mkfs.ext4 /dev/vg0/home
mkfs.ext4 /dev/vg0/shared
mkfs.ext4 /dev/vg0/vbox
mkswap /dev/vg0/swap
swapon /dev/vg0/swap

# ✅ Montage des partitions
mount /dev/vg0/root /mnt
mkdir -p /mnt/boot
mount ${DISK}2 /mnt/boot
mkdir -p /mnt/boot/efi
mount ${DISK}1 /mnt/boot/efi
mkdir -p /mnt/home
mount /dev/vg0/home /mnt/home
mkdir -p /mnt/shared
mount /dev/vg0/shared /mnt/shared
mkdir -p /mnt/vbox
mount /dev/vg0/vbox /mnt/vbox

# 📌 Vérification : Tout est bien monté ?
lsblk -f

# ✅ Installation du système de base
pacstrap /mnt base linux linux-firmware lvm2 vim networkmanager

# ✅ Génération du fichier fstab
genfstab -U /mnt >> /mnt/etc/fstab

# ✅ Configuration du système
arch-chroot /mnt /bin/bash <<EOF

# ✅ Configuration du fuseau horaire et horloge
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc

# ✅ Configuration de la langue et de la console
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "$HOSTNAME" > /etc/hostname
echo "127.0.0.1 localhost" >> /etc/hosts
echo "::1       localhost" >> /etc/hosts
echo "127.0.1.1 $HOSTNAME.localdomain $HOSTNAME" >> /etc/hosts

# ✅ Activation du réseau
systemctl enable NetworkManager
systemctl start NetworkManager

# ✅ Création des utilisateurs
echo "root:$PASSWORD" | chpasswd
useradd -m -G wheel -s /bin/bash papa
echo "papa:$PASSWORD" | chpasswd
useradd -m -s /bin/bash fils
echo "fils:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

# ✅ Installation des paquets essentiels
pacman -Syu --noconfirm
pacman -S sudo virtualbox virtualbox-host-dkms linux-headers firefox gcc make htop neofetch git base-devel xorg-server xorg-xinit i3 dmenu alacritty --noconfirm

# ✅ Configuration de i3 pour l’utilisateur papa
mkdir -p /home/papa/.config/i3
cat <<EOCFG > /home/papa/.config/i3/config
# i3 minimal config
exec --no-startup-id nm-applet
exec --no-startup-id feh --bg-scale /usr/share/backgrounds/archlinux.png
bindsym \$mod+Enter exec alacritty
bindsym \$mod+d exec dmenu_run
EOCFG
chown -R papa:papa /home/papa/.config

# ✅ Installation de GRUB et génération du fichier de configuration
pacman -S grub efibootmgr --noconfirm
echo "GRUB_CMDLINE_LINUX=\"cryptdevice=${DISK}3:cryptlvm root=/dev/mapper/vg0-root\"" >> /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# ✅ Correction de initramfs
sed -i 's/^HOOKS=(.*/HOOKS=(base udev autodetect modconf block encrypt lvm2 filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

EOF

# ✅ Vérifications finales avant redémarrage
lsblk -f > /mnt/install_check.txt
cat /mnt/etc/fstab >> /mnt/install_check.txt

# ✅ Nettoyage et démontage
umount -R /mnt
swapoff -a
cryptsetup close cryptlvm

echo "Installation terminée ! Vérifie le fichier /mnt/install_check.txt avant de redémarrer."
