#!/bin/bash

# S'assurer que le script est exécuté en tant que root
if [ "$EUID" -ne 0 ]; then
    echo "Script must be executed as root"
    exit 1
fi

# VARIABLES DE PARTITIONNEMENT
DISK="/dev/sda"
HOSTNAME="arch-vm"

# FICHIER LOG POUR VÉRIFIER LES INSTALLS
LOGFILE="/var/log/install_script.log"
exec > >(tee -a "$LOGFILE") 2>&1

setup_partitions() {
    echo "=== Nettoyage des partitions existantes ==="
    for mount in /mnt/share /mnt/vbox /mnt/boot /mnt; do
        umount -f $mount 2>/dev/null || true
    done

    lvchange -an /dev/vg0/* 2>/dev/null || true
    vgchange -an 2>/dev/null || true
    vgremove -f vg0 2>/dev/null || true
    pvremove -f /dev/mapper/cryptlvm 2>/dev/null || true

    cryptsetup close cryptlvm 2>/dev/null || true

    partprobe $DISK
    sleep 2

    echo "=== Effacement des partitions existantes ==="
    dd if=/dev/zero of=$DISK bs=512 count=2048
    wipefs -af $DISK
    sgdisk -Z $DISK
    partprobe $DISK
    sleep 2

    echo "=== Création des nouvelles partitions ==="
    parted -s $DISK mklabel gpt
    sgdisk -n 1:0:+512M -t 1:ef00 $DISK
    sgdisk -n 2:0:0 -t 2:8e00 $DISK
    partprobe $DISK
    sleep 2

    mkfs.fat -F32 "${DISK}1"

    echo -n "azerty123" | cryptsetup luksFormat "${DISK}2" -
    echo -n "azerty123" | cryptsetup open "${DISK}2" cryptlvm -

    pvcreate -ff /dev/mapper/cryptlvm
    vgcreate vg0 /dev/mapper/cryptlvm

    lvcreate -y -L 10G vg0 -n lvroot
    lvcreate -y -L 10G vg0 -n lvvbox
    lvcreate -y -L 5G vg0 -n lvshare

    mkfs.ext4 -F /dev/vg0/lvroot
    mkfs.ext4 -F /dev/vg0/lvvbox
    mkfs.ext4 -F /dev/vg0/lvshare

    mkdir -p /mnt /mnt/boot /mnt/vbox /mnt/share

    mount /dev/vg0/lvroot /mnt || true
    mount "${DISK}1" /mnt/boot || true
    mount /dev/vg0/lvvbox /mnt/vbox || true
    mount /dev/vg0/lvshare /mnt/share || true
}

setup_base_system() {
    echo "=== Installation du système de base ==="
    pacstrap /mnt base linux linux-firmware base-devel
    genfstab -U /mnt >> /mnt/etc/fstab
    echo "Base system installed, fstab generated."
}

setup_config() {
echo "=== Configuration du système (chroot) ==="
cat <<EOF | arch-chroot /mnt /bin/bash
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc

sed -i 's/^#fr_FR.UTF-8 UTF-8/fr_FR.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=fr_FR.UTF-8" > /etc/locale.conf
echo "KEYMAP=fr" > /etc/vconsole.conf

echo "$HOSTNAME" > /etc/hostname
echo "127.0.0.1   localhost" >> /etc/hosts
echo "::1         localhost" >> /etc/hosts
echo "127.0.1.1   $HOSTNAME" >> /etc/hosts

echo "root:azerty123" | chpasswd

sed -i 's/^HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)/HOOKS=(base udev autodetect modconf block encrypt lvm2 filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

pacman -S --noconfirm grub efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
UUID_LUKS=\$(blkid -s UUID -o value ${DISK}2)
sed -i "s|^GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=\$UUID_LUKS:cryptlvm root=/dev/vg0/lvroot\"|" /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

pacman -S --noconfirm sudo
useradd -m -G wheel -s /bin/bash papa
echo "papa:azerty123" | chpasswd
useradd -m -s /bin/bash fils
echo "fils:azerty123" | chpasswd

sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Installer les paquets minimaux + I3
pacman -S --noconfirm nano git htop firefox virtualbox i3 dmenu xorg xorg-xinit 

# Config de i3 pour papa
mkdir -p /home/papa/.config/i3
cat <<EOCFG > /home/papa/.config/i3/config
exec --no-startup-id dmenu_run
EOCFG
chown -R papa:papa /home/papa/.config

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
