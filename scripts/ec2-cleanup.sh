#!/usr/bin/env bash
#
# Stop or terminate the claude-remote EC2 spot instance.
# Run after your claude-remote session to save costs.
#

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

STATE_FILE="/tmp/claude-remote-ec2-instance-id"
REGION="${EC2_REGION:-eu-central-1}"

if [[ ! -f "$STATE_FILE" ]]; then
    echo "No active EC2 instance found."
    exit 0
fi

instance_id=$(cat "$STATE_FILE")

# Verify instance still exists
state=$(aws ec2 describe-instances \
    --instance-ids "$instance_id" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null) || state="not-found"

if [[ "$state" == "terminated" || "$state" == "not-found" ]]; then
    echo "Instance $instance_id is already terminated."
    rm -f "$STATE_FILE"
    exit 0
fi

if [[ "$state" == "stopped" ]]; then
    echo "Instance $instance_id is already stopped."
    read -p "Terminate it? [y/N] " answer </dev/tty
    case "${answer:-N}" in
        [Yy]*)
            # Cancel persistent spot request first
            sir=$(aws ec2 describe-instances \
                --instance-ids "$instance_id" \
                --region "$REGION" \
                --query 'Reservations[0].Instances[0].SpotInstanceRequestId' \
                --output text 2>/dev/null) || sir=""
            if [[ -n "$sir" && "$sir" != "None" ]]; then
                aws ec2 cancel-spot-instance-requests \
                    --spot-instance-request-ids "$sir" \
                    --region "$REGION" >/dev/null 2>&1 || true
            fi
            aws ec2 terminate-instances --instance-ids "$instance_id" --region "$REGION" >/dev/null
            echo "Instance terminated."
            rm -f "$STATE_FILE"
            ;;
        *)
            echo "Instance left stopped."
            ;;
    esac
    exit 0
fi

echo "Instance $instance_id is $state."
read -p "What to do? [S]top / [t]erminate / [n]othing: " answer </dev/tty
case "${answer:-S}" in
    [Ss]*|"")
        echo "Stopping instance $instance_id..."
        aws ec2 stop-instances --instance-ids "$instance_id" --region "$REGION" >/dev/null
        echo "Instance stopping. EBS volume preserved."
        ;;
    [Tt]*)
        echo "Terminating instance $instance_id..."
        sir=$(aws ec2 describe-instances \
            --instance-ids "$instance_id" \
            --region "$REGION" \
            --query 'Reservations[0].Instances[0].SpotInstanceRequestId' \
            --output text 2>/dev/null) || sir=""
        if [[ -n "$sir" && "$sir" != "None" ]]; then
            aws ec2 cancel-spot-instance-requests \
                --spot-instance-request-ids "$sir" \
                --region "$REGION" >/dev/null 2>&1 || true
            echo "Spot request cancelled."
        fi
        aws ec2 terminate-instances --instance-ids "$instance_id" --region "$REGION" >/dev/null
        echo "Instance terminated."
        rm -f "$STATE_FILE"
        ;;
    [Nn]*)
        echo "Instance left running. Remember to stop it manually!"
        ;;
esac
