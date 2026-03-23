#!/usr/bin/env bash
#
# Ensure a claude-remote EC2 spot instance is running and SSH-ready.
# Called by claude-remote.sh before launching Claude.
#

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.sh"
source "$CONFIG_FILE"

STATE_FILE="/tmp/claude-remote-ec2-instance-id"

if [[ "${EC2_ENABLED:-}" != "true" ]]; then
    exit 0
fi

if ! command -v aws &>/dev/null; then
    echo "Error: aws CLI not found. Install with: brew install awscli" >&2
    exit 1
fi

if ! aws sts get-caller-identity &>/dev/null; then
    echo "Error: AWS credentials not configured. Run: aws configure" >&2
    exit 1
fi

find_instance() {
    # Check saved instance ID first
    if [[ -f "$STATE_FILE" ]]; then
        local saved_id
        saved_id=$(cat "$STATE_FILE")
        local info
        info=$(aws ec2 describe-instances \
            --instance-ids "$saved_id" \
            --region "$EC2_REGION" \
            --query 'Reservations[].Instances[].[InstanceId,State.Name,PublicIpAddress]' \
            --output text 2>/dev/null) || true
        if [[ -n "$info" ]]; then
            local state
            state=$(echo "$info" | awk '{print $2}')
            if [[ "$state" == "running" || "$state" == "stopped" ]]; then
                echo "$info"
                return
            fi
        fi
        rm -f "$STATE_FILE"
    fi

    # Search by tag
    aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=$EC2_TAG_NAME" \
                  "Name=instance-state-name,Values=running,stopped" \
        --region "$EC2_REGION" \
        --query 'Reservations[].Instances[].[InstanceId,State.Name,PublicIpAddress]' \
        --output text 2>/dev/null | head -1
}

launch_spot_instance() {
    echo "Launching spot instance ($EC2_INSTANCE_TYPE in $EC2_REGION, max \$$EC2_MAX_SPOT_PRICE/hr)..."
    local instance_id
    instance_id=$(aws ec2 run-instances \
        --image-id "$EC2_AMI" \
        --instance-type "$EC2_INSTANCE_TYPE" \
        --key-name "$EC2_KEY_PAIR" \
        --security-group-ids "$EC2_SECURITY_GROUP" \
        --instance-market-options "{\"MarketType\":\"spot\",\"SpotOptions\":{\"MaxPrice\":\"$EC2_MAX_SPOT_PRICE\",\"SpotInstanceType\":\"persistent\",\"InstanceInterruptionBehavior\":\"stop\"}}" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$EC2_TAG_NAME}]" \
        --region "$EC2_REGION" \
        --query 'Instances[0].InstanceId' \
        --output text)

    if [[ -z "$instance_id" || "$instance_id" == "None" ]]; then
        echo "Error: Failed to launch spot instance" >&2
        exit 1
    fi

    echo "$instance_id" > "$STATE_FILE"
    echo "Instance $instance_id launching..."

    echo "Waiting for instance to start..."
    if ! aws ec2 wait instance-running \
        --instance-ids "$instance_id" \
        --region "$EC2_REGION" \
        --cli-read-timeout 300; then
        echo "Error: Instance did not start within 5 minutes" >&2
        exit 1
    fi

    # Get the public IP
    aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --region "$EC2_REGION" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text
}

wait_for_ssh() {
    local ip=$1
    local user=${EC2_SSH_USER:-ubuntu}
    local key_file="${EC2_KEY_FILE:-}"
    local ssh_opts="-o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
    if [[ -n "$key_file" ]]; then
        ssh_opts="$ssh_opts -i $key_file"
    fi

    # Remove old host key in case IP was reassigned
    ssh-keygen -R "$ip" 2>/dev/null || true

    echo "Waiting for SSH on $ip..."
    local attempts=0
    while [[ $attempts -lt 60 ]]; do
        if ssh $ssh_opts "${user}@${ip}" "exit 0" 2>/dev/null; then
            echo "SSH ready."
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 5
    done

    echo "Error: SSH not ready after 5 minutes" >&2
    return 1
}

update_config_host() {
    local ip=$1
    local user=${EC2_SSH_USER:-ubuntu}
    local key_file="${EC2_KEY_FILE:-}"
    local new_host="${user}@${ip}"

    sed -i '' "s|^REMOTE_HOST=.*|REMOTE_HOST=\"${new_host}\"|" "$CONFIG_FILE"
    export REMOTE_HOST="$new_host"

    # Update SSH config so all scripts (remote-shell, sync-start, etc.) can connect
    local ssh_config="$HOME/.ssh/config"
    local marker="# claude-remote-managed"
    if [[ -f "$ssh_config" ]] && grep -q "$marker" "$ssh_config"; then
        # Remove old managed block
        sed -i '' "/$marker/,/^$/d" "$ssh_config"
    fi
    if [[ -n "$key_file" ]]; then
        printf '\n%s\nHost %s\n  User %s\n  IdentityFile %s\n  StrictHostKeyChecking accept-new\n\n' \
            "$marker" "$ip" "$user" "$key_file" >> "$ssh_config"
    fi

    echo "Updated REMOTE_HOST to $new_host"
}

# --- Main ---

info=$(find_instance)

if [[ -n "$info" ]]; then
    instance_id=$(echo "$info" | awk '{print $1}')
    state=$(echo "$info" | awk '{print $2}')
    ip=$(echo "$info" | awk '{print $3}')

    echo "$instance_id" > "$STATE_FILE"

    if [[ "$state" == "stopped" ]]; then
        echo "Restarting stopped instance $instance_id..."
        aws ec2 start-instances --instance-ids "$instance_id" --region "$EC2_REGION" >/dev/null

        echo "Waiting for instance to start..."
        if ! aws ec2 wait instance-running \
            --instance-ids "$instance_id" \
            --region "$EC2_REGION" \
            --cli-read-timeout 300; then
            echo "Error: Instance did not start within 5 minutes" >&2
            exit 1
        fi

        # Get new IP (changes on restart)
        ip=$(aws ec2 describe-instances \
            --instance-ids "$instance_id" \
            --region "$EC2_REGION" \
            --query 'Reservations[0].Instances[0].PublicIpAddress' \
            --output text)
    fi

    echo "Using instance $instance_id ($ip)"
else
    ip=$(launch_spot_instance)
    instance_id=$(cat "$STATE_FILE")
fi

wait_for_ssh "$ip"
update_config_host "$ip"

# Clear any stale SSH control sockets for old IPs
rm -f /tmp/ssh-claude-* 2>/dev/null || true

echo "EC2 instance ready. Run 'ec2-cleanup' after your session to stop/terminate."
