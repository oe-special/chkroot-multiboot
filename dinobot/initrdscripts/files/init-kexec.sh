#!/bin/sh

echo "[init] Starting custom init script"

# Basic mounts
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev

# Default root and boot device
#ROOT="/dev/mmcblk0p10"
#BOOT="/dev/mmcblk0p11"

for i in /sys/block/mmcblk0/mmcblk0p*; do
  if [ -f "$i/uevent" ]; then
    partname=$(grep '^PARTNAME=' "$i/uevent" | cut -d '=' -f 2)
    devname=`cat /$i/uevent | grep DEVNAME | cut -d '=' -f 2`

    case "$partname" in
      rootfs|exrootfs)
        ROOT="/dev/$devname"
        ORIGINAL_ROOT="$ROOT"
        ;;
      others)
        BOOT="/dev/$devname"
        ;;
      other2)
        echo 0 > /sys/block/mmcblk0boot1/force_ro
        BOOT="/dev/mmcblk0boot1"
        ;;
    esac
  fi
done

# Wait for root device to appear
mdev -s
while [ ! -b "$ROOT" ]; do
  echo "[init] Waiting for $ROOT..."
  sleep 0.2
  mdev -s
done

echo "[init] ROOT found:$ROOT"
echo "[init] BOOT found:$BOOT"
ROOTSUBDIR=""
HAS_STARTUP=0
HAS_MOVEROOT=0


#wait for USB switch to initialize
sleep 2
mdev -s
RECOVERY_STARTUP=""
for device in mmcblk1 mmcblk1p1 sda sda1 sdb sdb1 sdc sdc1 sdd sdd1
do
  if [ ! -b /dev/$device ]; then
      continue
  fi
  mkdir -p /tmp/$device
  mount -n /dev/$device /tmp/$device 2>/dev/null
  [ -f /tmp/$device/STARTUP_RECOVERY ];
  RC=$?
  if [ $RC = 0 ]; then
    echo "[init]STARTUP_RECOVERY found on /dev/$device"
    RECOVERY_STARTUP=$(cat /tmp/$device/STARTUP_RECOVERY)
    umount /tmp/$device
    break
  fi
  umount /tmp/$device 2>/dev/null
done

mkdir -p /boot
if mount -t vfat "$BOOT" /boot 2>/dev/null; then
  echo "[init] $BOOT mounted as FAT"

  if [ -n "$RECOVERY_STARTUP" ]; then
    echo "[init] Using STARTUP_RECOVERY content"
    for x in $RECOVERY_STARTUP; do
      case "$x" in
        root=*)
          ROOT="${x#root=}"
          echo "[init] Overriding ROOT from RECOVERY: $ROOT"
          ;;
        rootsubdir=*)
          ROOTSUBDIR="${x#rootsubdir=}"
          HAS_STARTUP=1
          echo "[init] Setting ROOTSUBDIR from RECOVERY: $ROOTSUBDIR"
          ;;
      esac
    done
  elif [ -f /boot/STARTUP ]; then
    echo "[init] Reading /boot/STARTUP"
    for x in $(cat /boot/STARTUP); do
      case "$x" in
        root=*)
          ROOT="${x#root=}"
          echo "[init] Overriding ROOT: $ROOT"
          ;;
        rootsubdir=*)
          ROOTSUBDIR="${x#rootsubdir=}"
          HAS_STARTUP=1
          echo "[init] Setting ROOTSUBDIR: $ROOTSUBDIR"
          ;;
      esac
    done
  else
    echo "[init] No STARTUP file found — using default ROOT: $ROOT"
  fi

  umount /boot
else
  echo "[init] Failed to mount $BOOT — skipping STARTUP check"
fi

# Mount the root filesystem
mkdir -p /newroot
if ! mount -n "$ROOT" /newroot; then
  echo "[init] Failed to mount $ROOT"
  exec sh
fi

# Skip the root move if no STARTUP file is found
if [ "$HAS_STARTUP" -eq 1 ]; then
  # Handle initial move if necessary
  if [ ! -d "/newroot/linuxrootfs1" ]; then
    echo "[init] Moving root contents to /newroot/linuxrootfs1"
    mkdir -p /newroot/linuxrootfs1
    rsync -aAX --remove-source-files --exclude=linuxrootfs1 /newroot/ /newroot/linuxrootfs1/
    echo "[init] Root contents moved to /newroot/linuxrootfs1"
    
    # Clean up the moved directories in /newroot
    find /newroot/ -mindepth 1 -maxdepth 1 ! -name linuxrootfs1 -exec rm -rf {} +
    HAS_MOVEROOT=1
  fi
else
  echo "[init] Skipping root move, no STARTUP file"
fi

NEWROOT=""
IMAGE_FOUND=0
IMAGE_NUMBER="1"

# Check if /sbin/ldconfig exists in ROOT
if [ ! -f "/newroot/sbin/ldconfig" ]; then
  echo "[init] /sbin/ldconfig not found in root, checking ROOTSUBDIR and alternate roots"

  # If ROOTSUBDIR is specified, check /newroot/$ROOTSUBDIR first
  if [ -n "$ROOTSUBDIR" ] && [ -d "/newroot/$ROOTSUBDIR" ] && [ -f "/newroot/$ROOTSUBDIR/sbin/ldconfig" ]; then
    echo "[init] Found /sbin/ldconfig in /newroot/$ROOTSUBDIR"
    NEWROOT="/newroot/$ROOTSUBDIR"
    IMAGE_FOUND=1
    IMAGE_NUMBER=$(echo "$ROOTSUBDIR" | sed -n 's/.*linuxrootfs\([0-9]\+\).*/\1/p')
  else
    # Check linuxrootfs1 to linuxrootfs4
    for i in $(seq 1 20); do
      if [ -d "/newroot/linuxrootfs$i" ] && [ -f "/newroot/linuxrootfs$i/sbin/ldconfig" ]; then
        echo "[init] Fallback: Found valid root at /newroot/linuxrootfs$i"
        NEWROOT="/newroot/linuxrootfs$i"
        ROOTSUBDIR="linuxrootfs$i"
        IMAGE_FOUND=1
        IMAGE_NUMBER=$i
        break
      fi
    done
  fi

  # If NEWROOT from ROOTSUBDIR needs to be mounted
  if [ ! -z "${ROOTSUBDIR+x}" ]; then
    if [ -d "/newroot/$ROOTSUBDIR" ]; then
      echo "[init] Mount bind $ROOTSUBDIR"
      NEWROOT="/newroot_ext"
      mount --bind "/newroot/$ROOTSUBDIR" "$NEWROOT"
      umount /newroot
    else
      echo "[init] $ROOTSUBDIR is not present or no directory — fallback to root"
    fi
  fi

  # Wenn gültiges Image gefunden, dann STARTUP anpassen
  if [ "$IMAGE_FOUND" = "1" ]; then
    echo "[init] Adjusting STARTUP for found image (Image number: $IMAGE_NUMBER)"
    if mount -t vfat "$BOOT" /boot 2>/dev/null; then
      if [ -n "$IMAGE_NUMBER" ] && [ -f "/boot/STARTUP_$IMAGE_NUMBER" ]; then
        echo "[init] Copying STARTUP_$IMAGE_NUMBER to STARTUP"
        cp "/boot/STARTUP_$IMAGE_NUMBER" /boot/STARTUP
      elif [ -f "/boot/STARTUP_1" ]; then
        echo "[init] No subdir detected, copying default STARTUP_1 to STARTUP"
        cp "/boot/STARTUP_1" /boot/STARTUP
      else
        echo "[init] No matching STARTUP_X file found — keeping existing STARTUP"
      fi
      sync
      umount /boot
    else
      echo "[init] Failed to mount BOOT to update STARTUP"
    fi
  else
    echo "[init] No valid root found — retrying original root device"
    mount -n "$ORIGINAL_ROOT" /newroot
    if [ -f "/newroot/sbin/ldconfig" ]; then
      echo "[init] Found valid root on original device"
      NEWROOT="/newroot"
      IMAGE_FOUND=1
    else
      echo "[init] No valid root found even on original device — dropping to shell"
      exec sh
    fi
  fi
else
  # /sbin/ldconfig found at first mount
  NEWROOT="/newroot"
fi

# guest Detection
if [ ! -f /etc/.guest ] && [ "$IMAGE_NUMBER" != "1" ]; then
    echo "[init] prepare Target OS."
    mkdir -p /newroot/oldroot
    mount -n "$ORIGINAL_ROOT" /newroot/oldroot
    if [ -d "/newroot/oldroot/linuxrootfs1/lib/modules/" ]; then
        rm -rf $NEWROOT/lib/modules/*
        rsync -aAX /newroot/oldroot/linuxrootfs1/lib/modules/ $NEWROOT/lib/modules/
        cp -af /newroot/oldroot/linuxrootfs1/usr/bin/multiboot-selector.sh $NEWROOT/usr/bin/multiboot-selector.sh
    elif [ -d "/newroot/oldroot/lib/modules/" ]; then
        rm -rf $NEWROOT/lib/modules/*
        rsync -aAX /newroot/oldroot/lib/modules/ $NEWROOT/lib/modules/
        cp -af /newroot/oldroot/usr/bin/multiboot-selector.sh $NEWROOT/usr/bin/multiboot-selector.sh
    fi
    umount /newroot/oldroot
    touch $NEWROOT/etc/.guest
fi

# Final checks before switch_root
if [ -z "$NEWROOT" ]; then
  echo "[init] No NEWROOT set — dropping to shell"
  exec sh
fi

if [ ! -f "$NEWROOT/sbin/ldconfig" ]; then
  echo "[init] /sbin/ldconfig not found in NEWROOT:$NEWROOT — dropping to shell"
  exec sh
fi

# Prepare final root environment
for d in proc sys dev; do
  mkdir -p "$NEWROOT/$d"
  mount --move "/$d" "$NEWROOT/$d"
done

echo "[init] Executing switch_root to $NEWROOT (ROOT: $ROOT)"
exec switch_root "$NEWROOT" /sbin/init

echo "[init] switch_root failed — dropping to shell"
exec sh