#!/bin/bash

echo "[INFO] Starting disk usage check and resize process..."

# Install postfix if needed
sudo DEBIAN_FRONTEND=noninteractive apt install postfix -y
sleep 5

# Constants
METADATA_URL="http://169.254.169.254/openstack/latest/meta_data.json"
JQ_CMD="jq -r"
HCL_CMD="hcloud"
DISK_USAGE_THRESHOLD=88
RESIZE_PERCENT=10
SLEEP_DURATION=10

# Init Huawei CLI Metadata
#echo "[INFO] Initializing Huawei Cloud CLI Metadata..."
#$HCL_CMD --cli-region=la-north-2 meta init

# Get ID_SERIAL
get_id_serial() {
  local device=$1
  local base_device="${device##*/}"
  local id_serial=$(find /dev/disk/by-id/ -type l -lname "*$base_device" -exec readlink -f {} \; | xargs -I{} basename $(dirname {})/$(basename {}))
  id_serial=$(echo "$id_serial" | head -n 1)
  if [[ -z "$id_serial" || "$id_serial" == "$base_device" ]]; then
    id_serial=$(find /dev/disk/by-id/ -type l -lname "*$base_device" -exec basename {} \; | grep -v "$base_device" | head -n 1)
  fi
  if [[ "$id_serial" =~ ^virtio-(.{20})-part[0-9]+$ ]]; then
    id_serial="${BASH_REMATCH[1]}"
  elif [[ "$id_serial" =~ ^virtio-(.{20}) ]]; then
    id_serial="${BASH_REMATCH[1]}"
  else
    id_serial=""
  fi
  echo "[INFO] Extracted ID_SERIAL for $device is: $id_serial"
  echo "$id_serial"
}

resize_disk() {
  local device=$1
  local fstype=$2
  local size_kb=$3
  local use_percent=$4
  local mount_point=$5

  PROJECTID=$(curl -s "$METADATA_URL" | $JQ_CMD '.project_id')
  INSTANCEID=$(curl -s "$METADATA_URL" | $JQ_CMD '.uuid')
  REGION=$(curl -s "$METADATA_URL" | $JQ_CMD '.region_id')

  echo "[INFO] Project ID: $PROJECTID"
  echo "[INFO] Instance ID: $INSTANCEID"
  echo "[INFO] Region: $REGION"

  echo "[INFO] Fetching volume attachments..."
  raw_attachments=$($HCL_CMD ECS ListServerVolumeAttachments --cli-region="$REGION" --project_id="$PROJECTID" --server_id="$INSTANCEID")
  echo "[DEBUG] Raw attachment response:"
  echo "$raw_attachments"

  # Validate JSON before parsing
  if ! echo "$raw_attachments" | jq empty 2>/dev/null; then
    echo "[ERROR] Invalid JSON response from Huawei CLI. Skipping resize."
    echo "$raw_attachments"
    return
  fi

  ATTACHMENTS=$(echo "$raw_attachments" | $JQ_CMD '.volumeAttachments[] | "\(.device): \(.id)"')
  echo "[INFO] Attachments: $ATTACHMENTS"

  base_device=$(echo "$device" | sed 's/[0-9]$//')
  id_serial=$(get_id_serial "$device")

  potential_volume_ids=$(echo "$ATTACHMENTS" | grep "${id_serial}" | cut -d' ' -f2)
  volume_id=$(echo "$potential_volume_ids" | head -n 1)

  echo "[INFO] Matching Volume ID: $volume_id"
  if [[ -z "$volume_id" ]]; then
    echo "[ERROR] No volume matched by ID_SERIAL. Skipping."
    return
  fi

  current_size=$((size_kb / 1024 / 1024))
  new_size=$((current_size + (current_size * $RESIZE_PERCENT / 100)))

  volume_details=$($HCL_CMD EVS ShowVolume --cli-region="$REGION" --project_id="$PROJECTID" --volume_id="$volume_id")
  current_volume_size_gb=$(echo "$volume_details" | $JQ_CMD '.volume.size')

  echo "[INFO] Current Size: ${current_size}GB, Target Size: ${new_size}GB"
  echo "[INFO] Volume API reports size: ${current_volume_size_gb}GB"

  if (( new_size <= current_volume_size_gb )); then
    echo "[INFO] Target size not larger than current volume. Skipping resize."
    return
  fi

  echo "[INFO] Resizing volume $volume_id to $new_size GB..."
  response=$($HCL_CMD EVS ResizeVolume --cli-region="$REGION" --os-extend.new_size="$new_size" --project_id="$PROJECTID" --volume_id="$volume_id")
  echo "$response" | grep -qi error && { echo "[ERROR] Resize failed: $response"; return; }

  sleep $SLEEP_DURATION

  if [[ "$fstype" == "xfs" ]]; then
    echo "[INFO] Growing XFS filesystem..."
    growpart "$base_device" 1
    xfs_growfs "$mount_point"
  elif [[ "$fstype" == "ext4" ]]; then
    echo "[INFO] Growing ext4 filesystem..."
    growpart "$base_device" 1
    resize2fs "$device"
  else
    echo "[WARN] Unsupported FS type: $fstype"
  fi

  echo "[SUCCESS] Volume $device resized and filesystem grown."
}

# Check usage
echo "[INFO] Scanning disks over $DISK_USAGE_THRESHOLD% usage..."
df -T | awk 'NR>1' | while read -r line; do
  device=$(echo "$line" | awk '{print $1}')
  fstype=$(echo "$line" | awk '{print $2}')
  size_kb=$(echo "$line" | awk '{print $3}')
  use_percent=$(echo "$line" | awk '{print $6}' | tr -d '%')
  mount_point=$(echo "$line" | awk '{print $7}')

  [[ -z "$use_percent" || ! "$use_percent" =~ ^[0-9]+$ ]] && continue

  if (( use_percent > DISK_USAGE_THRESHOLD )); then
    echo "[INFO] Disk $device is using ${use_percent}%, triggering resize..."
    resize_disk "$device" "$fstype" "$size_kb" "$use_percent" "$mount_point"
  fi
done
