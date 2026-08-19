#!/bin/sh
# The guest side of the power-loss rig (rove#103).
B=/bin/busybox
export PATH=/bin:/sbin
$B mkdir -p /proc /sys /dev /data
$B mount -t proc proc /proc; $B mount -t sysfs sys /sys; $B mount -t devtmpfs dev /dev
# Order is load-bearing: virtio_net links against net_failover, and insmod
# does no dependency resolution (that is modprobe's job, and modprobe needs a
# module tree this initramfs does not carry).
for m in virtio_blk failover net_failover virtio_net dm-mod dm-flakey; do
  [ -f /mods/$m.ko ] && { $B insmod /mods/$m.ko 2>&1 | $B sed "s/^/INSMOD $m: /"; }
done
$B sleep 1

# lo is DOWN in a bare initramfs, and nothing brings it up. Without this the
# worker listens on 0.0.0.0:8080 and curl to 127.0.0.1 fails to connect —
# reported by curl as status 000, which reads like a dead server.
$B ip link set lo up 2>/dev/null

# slirp's fixed topology — no DHCP client needed.
$B ip addr add 10.0.2.15/24 dev eth0 2>/dev/null
$B ip link set eth0 up 2>/dev/null
$B ip route add default via 10.0.2.2 2>/dev/null

SECTORS=$($B blockdev --getsz /dev/vda)
PHASE=$($B sed -n 's/.*phase=\([a-z]*\).*/\1/p' /proc/cmdline)
echo "GUEST phase=$PHASE sectors=$SECTORS"

# S3 + worker config arrives on the kernel cmdline (see the host driver).
for kv in $($B cat /proc/cmdline); do
  case "$kv" in
    ENV_*) eval "export $($B echo "$kv" | $B sed 's/^ENV_//')" ;;
  esac
done

start_worker() {
  # The worker opens a listener per core plus io_uring rings and LMDB envs;
  # busybox's inherited default (1024) is not enough and shows up as the
  # opaque `UserFdQuotaExceeded`.
  ulimit -n 65536 2>/dev/null
  $B mkdir -p /data/w
  REWIND_METRICS_PORT=0 /bin/rewind-worker /data/w 8080 > /worker.log 2>&1 &
  for i in $($B seq 1 60); do
    if $B grep -q "listening on" /worker.log 2>/dev/null; then echo "WORKER up"; return 0; fi
    if ! $B pidof rewind-worker > /dev/null; then
      echo "WORKER died:"; $B cat /worker.log; return 1
    fi
    $B sleep 1
  done
  echo "WORKER timeout:"; $B cat /worker.log; return 1
}

# Padding to push real VOLUME through the WAL. The segment target is 64 MiB
# and is not tunable, so the only way to exercise C3 — the segment roll's
# rename + parent-dir fsync — is to actually write past it.
PAD=""
mkpad() {
  n=${PL_VALUE_BYTES:-0}
  [ "$n" -gt 0 ] || return 0
  PAD=$($B dd if=/dev/zero bs=1 count=$n 2>/dev/null | $B tr '\0' 'x')
}

put() {  # put <key> <value> → prints the HTTP status
  /bin/curl -s -o /dev/null -w "%{http_code}" -m 10 --http2-prior-knowledge \
    -X POST "http://127.0.0.1:8080/_system/admin-kv" \
    -H "Host: admin.localhost" -H "Authorization: Bearer $REWIND_ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    --data "{\"pairs\":[{\"key\":\"$1\",\"value\":\"$2$PAD\"}]}"
}

get() {  # get <key> → prints the HTTP body
  /bin/curl -s -m 10 --http2-prior-knowledge \
    "http://127.0.0.1:8080/_system/v2-kv?tenant=__admin__&key=$1" \
    -H "X-Rewind-Move-Secret: $REWIND_MOVE_SECRET"
}

if [ "$PHASE" = "net" ]; then
  echo "NET ip: $($B ip -4 addr show eth0 2>&1 | $B tr '\n' ' ')"
  echo "NET route: $($B ip route 2>&1 | $B tr '\n' ' ')"
  echo "NET dns: $($B cat /etc/resolv.conf)"
  echo "NET s3 head: $(/bin/curl -s -o /dev/null -w '%{http_code} %{time_total}s' -m 20 "$S3_ENDPOINT" 2>&1)"
  echo "NET s3 bucket: $(/bin/curl -s -o /dev/null -w '%{http_code}' -m 20 "$S3_ENDPOINT/$S3_BUCKET" 2>&1)"
  $B poweroff -f
fi

if [ "$PHASE" = "one" ]; then
  /sbin/dmsetup create pl --table "0 $SECTORS flakey /dev/vda 0 1 0"
  $B mkfs.ext2 -q -F /dev/mapper/pl
  $B mount /dev/mapper/pl /data
  start_worker || { $B poweroff -f; }
  echo "ONE put status=$(put one/1 hello)"
  echo "ONE get body=$(get one/1)"
  echo "--- worker log tail ---"
  $B tail -25 /worker.log
  $B poweroff -f
fi

if [ "$PHASE" = "cut" ]; then
  /sbin/dmsetup create pl --table "0 $SECTORS flakey /dev/vda 0 1 0" && echo "DM up"
  $B mkfs.ext2 -q -F /dev/mapper/pl && echo "MKFS ok"
  $B mount /dev/mapper/pl /data && echo "MOUNT ok"
  start_worker || { $B poweroff -f; }
  mkpad
  echo "PAD bytes=${#PAD}"
  N=${PL_WRITES:-400}
  # The writer runs in the BACKGROUND so the cut lands mid-flight. A cut that
  # only ever fires after the last ack proves almost nothing: there is no
  # un-fsynced data left to lose, so "everything survived" would hold even on
  # a device that never dropped anything.
  (
    i=1
    while [ $i -le $N ]; do
      code=$(put "pl/$i" "value-$i")
      # ⭐ The durable record of what was ACKED leaves by SERIAL PORT, to a
      #    file on the host — the one channel the power cut cannot reach.
      #    Comparing it against what the rebooted worker serves IS the test.
      [ "$code" = "204" ] && echo "ACK pl/$i"
      i=$(($i + 1))
    done
    echo "WRITER-FINISHED"
  ) &
  $B sleep ${PL_CUT_AFTER_S:-6}

  # NEGATIVE CONTROL: touched and never fsynced. If this survives, the device
  # did not actually drop anything and every other result in the run is void.
  echo "unsynced-sentinel" > /data/sentinel

  # ⭐ the cut. Every write from here is swallowed, so anything the worker had
  #    not already fsynced is gone — what a PSU failure leaves behind.
  # --noflush --nolockfs is the whole difference between a power cut and a
  # clean shutdown. A plain `suspend` QUIESCES the device: it flushes
  # outstanding I/O and freezes the filesystem (which syncs it), so everything
  # in the page cache reaches the platter before the table swap — and the
  # negative control survives, proving the run dropped nothing.
  /sbin/dmsetup suspend --noflush --nolockfs pl
  /sbin/dmsetup reload pl --table "0 $SECTORS flakey /dev/vda 0 0 600 1 drop_writes"
  /sbin/dmsetup resume pl
  echo "CUT"
  $B poweroff -f
else
  /sbin/dmsetup create pl --table "0 $SECTORS flakey /dev/vda 0 1 0" && echo "DM up"
  $B mount /dev/mapper/pl /data && echo "MOUNT ok"
  echo "SENTINEL $($B cat /data/sentinel 2>/dev/null || echo ABSENT)"
  echo "WALFILES $($B ls -la /data/w/raft-wal* 2>/dev/null | $B awk '{print $NF"="$5}' | $B tr '\n' ' ')"
  start_worker || { echo "VERIFY-ABORT worker would not start after the cut"; $B poweroff -f; }
  N=${PL_WRITES:-400}
  i=1
  while [ $i -le $N ]; do
    echo "READ pl/$i = $(get pl/$i | $B cut -c1-16)"
    i=$(($i + 1))
  done
  echo "VERIFY-DONE"
  $B poweroff -f
fi
