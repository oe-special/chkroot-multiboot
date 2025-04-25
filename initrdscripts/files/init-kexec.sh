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
      rootfs)
        ROOT="/dev/$devname"
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

echo "[init] ROOT found:$ROOT"
echo "[init] BOOT found:$BOOT"
ROOTSUBDIR=""
HAS_STARTUP=0
HAS_MOVEROOT=0

# Try mounting BOOT partition (FAT expected)
mkdir -p /boot
if mount -t vfat "$BOOT" /boot 2>/dev/null; then
  echo "[init] $BOOT mounted as FAT"

  # If STARTUP file exists, read it
  if [ -f /boot/STARTUP ]; then
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

# Wait for root device to appear
mdev -s
while [ ! -b "$ROOT" ]; do
  echo "[init] Waiting for $ROOT..."
  sleep 0.2
  mdev -s
done

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

# Check if /sbin/init exists in ROOT
if [ ! -f "/newroot/sbin/init.sysvinit" ]; then
  echo "[init] /sbin/init not found in root, checking ROOTSUBDIR and alternate roots"

  # If ROOTSUBDIR is specified, check /newroot/$ROOTSUBDIR first
  if [ -n "$ROOTSUBDIR" ] && [ -d "/newroot/$ROOTSUBDIR" ] && [ -f "/newroot/$ROOTSUBDIR/sbin/init.sysvinit" ]; then
    echo "[init] Found /sbin/init in /newroot/$ROOTSUBDIR"
    NEWROOT="/newroot/$ROOTSUBDIR"
  else
    # Check linuxrootfs1 to linuxrootfs4
    for i in 1 2 3 4; do
      if [ -d "/newroot/linuxrootfs$i" ] && [ -f "/newroot/linuxrootfs$i/sbin/init.sysvinit" ]; then
        echo "[init] Fallback Found valid root at /newroot/linuxrootfs$i"
        NEWROOT="/newroot/linuxrootfs$i"
        break
      fi
    done
  fi
  
  if [ ! -z ${ROOTSUBDIR+x} ];
  then
    if [ -d /newroot/$ROOTSUBDIR ];
    then
      echo "Mount bind $ROOTSUBDIR"
      NEWROOT="/newroot_ext"
      mount --bind /newroot/$ROOTSUBDIR /newroot_ext
      umount /newroot
    else
      echo "[init] $ROOTSUBDIR is not present or no directory. Fallback to root."
    fi
  fi
fi

# Ensure we have a valid NEWROOT
if [ -z "$NEWROOT" ]; then
  NEWROOT="/newroot"
fi

# Check if /sbin/init exists in the selected NEWROOT
if [ ! -f "$NEWROOT/sbin/init.sysvinit" ]; then
  echo "[init] /sbin/init not found in NEWROOT:$NEWROOT — dropping to shell"
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