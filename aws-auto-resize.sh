#!/bin/bash

echo "[INFO] Starting AWS disk auto-resize..."

DISK_USAGE_THRESHOLD=95
RESIZE_PERCENT=1
MIN_INCREMENT=1
SLEEP_DURATION=10

# Get AWS metadata (IMDSv2)
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)

echo "[INFO] Instance: $INSTANCE_ID | Region: $REGION"

# Function to map device → volume ID
get_volume_id() {
  device=$1

  if [[ "$device" == *"nvme"* ]]; then
    nvme id-ctrl -v "$device" | grep sn | awk '{print $3}'
  else
    aws ec2 describe-volumes \
      --region "$REGION" \
      --filters Name=attachment.instance-id,Values=$INSTANCE_ID \
      --query "Volumes[*].VolumeId" \
      --output text | head -n 1
  fi
}

resize_disk() {
  device=$1
  fstype=$2
  size_kb=$3
  use_percent=$4
  mount_point=$5

  echo "[INFO] Processing $device ($use_percent%)"

  if [[ "$device" == "/dev/root" ]]; then
    device=$(findmnt -n -o SOURCE /)
    echo "[INFO] Mapped /dev/root → $device"
  fi

  volume_id=$(get_volume_id "$device")

  if [[ -z "$volume_id" ]]; then
    echo "[ERROR] Could not map volume for $device"
    return
  fi

  current_size=$(aws ec2 describe-volumes \
    --volume-ids "$volume_id" \
    --region "$REGION" \
    --query "Volumes[0].Size" \
    --output text)

  increase=$((current_size * RESIZE_PERCENT / 100))
  [[ $increase -lt $MIN_INCREMENT ]] && increase=$MIN_INCREMENT

  new_size=$((current_size + increase))

  echo "[INFO] Volume $volume_id: $current_size → $new_size GB (increase: $increase GB)"

  if (( new_size <= current_size )); then
    echo "[INFO] No resize needed"
    return
  fi

  echo "[INFO] Resizing EBS volume..."
  aws ec2 modify-volume \
    --volume-id "$volume_id" \
    --size "$new_size" \
    --region "$REGION"

  echo "[INFO] Waiting for AWS resize..."
  sleep $SLEEP_DURATION

  base_device="/dev/$(lsblk -no PKNAME $device)"
  partition_number=$(echo "$device" | grep -o '[0-9]*$')

  echo "[INFO] Base device: $base_device | Partition: $partition_number"

  # Expand partition
  growpart "$base_device" "$partition_number"

  # Expand filesystem
  if [[ "$fstype" == "xfs" ]]; then
    xfs_growfs "$mount_point"
  elif [[ "$fstype" == "ext4" ]]; then
    resize2fs "$device"
  else
    echo "[WARN] Unsupported FS: $fstype"
  fi

  echo "[SUCCESS] Resized $device"
}

# Scan ALL disks
df -T | awk 'NR>1' | while read -r line; do
  device=$(echo "$line" | awk '{print $1}')
  fstype=$(echo "$line" | awk '{print $2}')
  size_kb=$(echo "$line" | awk '{print $3}')
  use_percent=$(echo "$line" | awk '{print $6}' | tr -d '%')
  mount_point=$(echo "$line" | awk '{print $7}')

  [[ "$device" != /dev/* ]] && continue
  [[ "$device" == *"loop"* ]] && continue

  if (( use_percent > DISK_USAGE_THRESHOLD )); then
    resize_disk "$device" "$fstype" "$size_kb" "$use_percent" "$mount_point"
  fi
done
