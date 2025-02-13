#!/bin/bash

# S'assurer que le script est exécuté en tant que root
if [ "$EUID" -ne 0 ]; then
    echo "Script must be executed as root"
    exit 1
fi

# VARIABLES DE PARTITIONNEMENT
DISK="/dev/sda"
HOSTNAME="arch-vm"

# PROGRAMME D'INSTALLATION
setup_partitions() {
    # NETTOYAGE DES MONTAGES EXISTANTS ET LVM
    # Démonter tout d'abord
    for mount in /mnt/share /mnt/vbox /mnt/boot /mnt; do
        umount -f $mount 2>/dev/null || true
    done

    # Désactiver et supprimer LVM
    lvchange -an /dev/vg0/* 2>/dev/null || true
    vgchange -an 2>/dev/null || true
    vgremove -f vg0 2>/dev/null || true
    pvremove -f /dev/mapper/cryptlvm 2>/dev/null || true

    # Fermer LUKS
    cryptsetup close cryptlvm 2>/dev/null || true

    # Forcer le noyau à relire la table de partitions
    partprobe $DISK
    sleep 2

    # EFFACER LES PARTITIONS EXISTANTES
    dd if=/dev/zero of=$DISK bs=512 count=2048
    wipefs -af $DISK
    sgdisk -Z $DISK
    partprobe $DISK
    sleep 2

    # CRÉER LA TABLE DE PARTITIONS
    parted -s $DISK mklabel gpt

    # CRÉER LA PARTITION EFI (512MB)
    sgdisk -n 1:0:+512M -t 1:ef00 $DISK

    # CRÉER LA DEUXIÈME PARTITION POUR LUKS/LVM
    sgdisk -n 2:0:0 -t 2:8e00 $DISK
    partprobe $DISK
    sleep 2

    # FORMATER LA PARTITION EFI
    mkfs.fat -F32 "${DISK}1"

    # CONFIGURER LUKS SUR LA DEUXIÈME PARTITION
    echo -n "azerty123" | cryptsetup luksFormat "${DISK}2" -
    echo -n "azerty123" | cryptsetup open "${DISK}2" cryptlvm -

    # CONFIGURER LVM
    pvcreate -ff /dev/mapper/cryptlvm
    vgcreate vg0 /dev/mapper/cryptlvm

    # CRÉER LES VOLUMES LOGIQUES AVEC TAILLES SPÉCIFIÉES
    lvcreate -y -L 10G vg0 -n lvroot
    lvcreate -y -L 10G vg0 -n lvvbox
    lvcreate -y -L 5G vg0 -n lvshare

    # FORMATER LES VOLUMES LOGIQUES
    mkfs.ext4 -F /dev/vg0/lvroot
    mkfs.ext4 -F /dev/vg0/lvvbox
    mkfs.ext4 -F /dev/vg0/lvshare

    # CRÉER LES POINTS DE MONTAGE
    mkdir -p /mnt /mnt/boot /mnt/vbox /mnt/share

    # MONTER LES SYSTÈMES DE FICHIERS
    mount /dev/vg0/lvroot /mnt || true
    mount "${DISK}1" /mnt/boot || true
    mount /dev/vg0/lvvbox /mnt/vbox || true
    mount /dev/vg0/lvshare /mnt/share || true
}


setup_base_system() {
    # CONFIGURATION DU SYSTÈME DE BASE
	echo "===  Installation du système de base ==="

    # 1) Installer Arch Linux de base dans /mnt
    pacstrap /mnt base linux linux-firmware base-devel

    # 2) Générer fstab
    genfstab -U /mnt >> /mnt/etc/fstab

    echo "Base system installed, fstab generated."
	
}

setup_config() {
echo "===  Configuration du système (chroot) ==="
cat <<EOF | arch-chroot /mnt /bin/bash
# 1) Timezone, horloge
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc

# 2) Locale (fr_FR, si besoin)
sed -i 's/^#fr_FR.UTF-8 UTF-8/fr_FR.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=fr_FR.UTF-8" > /etc/locale.conf
echo "KEYMAP=fr" > /etc/vconsole.conf

# 3) Hostname et /etc/hosts
echo "$HOSTNAME" > /etc/hostname
echo "127.0.0.1   localhost" >> /etc/hosts
echo "::1         localhost" >> /etc/hosts
echo "127.0.1.1   $HOSTNAME" >> /etc/hosts

# 4) Mot de passe root
echo "root:azerty123" | chpasswd

# 5) mkinitcpio (chiffrement + LVM)
sed -i 's/^HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)/HOOKS=(base udev autodetect modconf block encrypt lvm2 filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# 6) Installer GRUB (UEFI)
pacman -S --noconfirm grub efibootmgr

# Installer GRUB sur la partition EFI
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB

# On ajoute l'option cryptdevice (pour déchiffrer /dev/sda2)
UUID_LUKS=\$(blkid -s UUID -o value ${DISK}2)
sed -i "s|^GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=\$UUID_LUKS:cryptlvm root=/dev/vg0/lvroot\"|" /etc/default/grub

grub-mkconfig -o /boot/grub/grub.cfg

# 7) Utilisateurs: papa, fils
pacman -S --noconfirm sudo
useradd -m -G wheel -s /bin/bash papa
echo "papa:azerty123" | chpasswd
useradd -m -s /bin/bash fils
echo "fils:azerty123" | chpasswd

# Droits sudo au groupe wheel
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# 8) Paquets supplémentaires
pacman -S --noconfirm nano git htop firefox virtualbox hyprland waybar wofi \
    xorg-server-xwayland xdg-desktop-portal-hyprland

# 9) Config de Hyprland (pour papa)
mkdir -p /home/papa/.config/hypr
cat <<EOCFG > /home/papa/.config/hypr/hyprland.conf
# Hyprland minimal config
monitor=,preferred,auto,1
exec=waybar
exec=wofi
EOCFG
chown -R papa:papa /home/papa/.config

# 10) Dossier partagé
groupadd sharedusers
usermod -aG sharedusers papa
usermod -aG sharedusers fils
chown root:sharedusers /share
chmod 770 /share

EOF

    echo "=== Fin du chroot. Démontage et fermeture LUKS ==="
    umount -R /mnt
    cryptsetup close cryptlvm

    echo "Installation terminée ! Vous pouvez redémarrer la VM."
}

# APPEL DES FONCTIONS
setup_partitions
setup_base_system
setup_config
