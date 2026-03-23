# Claude Remote Configuration
# Copy this file to config.sh and edit with your values

# SSH connection to remote machine
REMOTE_HOST="ubuntu@your-ec2-instance.amazonaws.com"

# Directory on remote machine where commands will execute
REMOTE_DIR="/home/ubuntu/Projects"

# Local mount point for remote filesystem
LOCAL_MOUNT="$HOME/Projects/remote"

# EC2 Spot Instance Management (optional -- leave empty to skip)
# EC2_ENABLED="true"
# EC2_REGION="eu-central-1"
# EC2_INSTANCE_TYPE="t4g.small"
# EC2_AMI="ami-xxxxxxxxxxxxxxx"
# EC2_KEY_PAIR="your-key-pair-name"
# EC2_SECURITY_GROUP="sg-xxxxxxxxxxxxxxx"
# EC2_MAX_SPOT_PRICE="0.02"
# EC2_TAG_NAME="claude-remote"
# EC2_SSH_USER="ubuntu"
# EC2_KEY_FILE="$HOME/.ssh/your-key.pem"
