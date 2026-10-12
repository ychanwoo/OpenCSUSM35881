#!/usr/bin/env bash
# -----------------------------------------------------------------
#  CS 446 Midterm - OpenCSUSM
#  Name: Youngchan Woo
#  Campus ID: 202935881
#  Lane: cpu
# ----------------------------------------------------------------
#
#  WHY I CHOSE THIS LANE
#  I chose the cpu lane because my account's G and VT quota was zero,
#  while its Standard quota was 32 vCPUs, enough for this 8-vCPU instance.
#  A funded account does not bypass the quota, so the GPU lane would need
#  approval before I could launch it, while the CPU lane can launch now.
#  The c7i.2xlarge compute rate in us-east-1 is $0.357 per hour, compared
#  with $0.526 per hour for the suggested GPU instance.
#  At the CPU rate, $100 buys about 280 hours of compute, although EBS and
#  public IPv4 charges reduce the actual time available within that budget.
#  I use Ollama with qwen2.5:0.5b because its small quantized model is enough
#  for a short greeting and can run on the CPU without NVIDIA drivers.
#  I would use this instance only for the test and delete it afterward,
#  rather than spending the whole budget on unnecessary running time.
#
# ----------------------------------------------------------------
# These commands run on the laptop; the quoted SSH blocks run on EC2.
# Required locally: Bash, AWS CLI v2, Python 3, OpenSSH and curl.
# AWS credentials must permit the EC2, SSM, quota and pricing operations.
# A public subnet with an Internet Gateway and working network ACL is needed.
# Optional: export SUBNET_ID to select an existing public subnet explicitly.
# Running this file creates billable resources and deletes its own resources.
# Usage: bash Youngchan_Woo_CS446_Midterm.sh
#
# Stop on command failures, undefined variables and failures inside pipelines.
set -euo pipefail

# ------------------------------------------------- MY CHOICES
# Use the region whose quota, AMI and instance price are checked below.
REGION=us-east-1
# Use my lower-case last name in the resource ownership labels.
OWNER=woo
# Assign a unique key name so this run cannot replace an existing SSH key.
KEYNAME="opencsusm-${OWNER}-${RANDOM}-${RANDOM}-$$"
# Select the CPU instance with eight vCPUs used by the course CPU lane.
INSTANCE=c7i.2xlarge
# Record the assumed hourly compute rate separately from the live price check.
RATE=0.3570
# Use Ollama's local inference port on the remote instance.
PORT=11434
# Select the small quantized model that can perform the greeting test on CPU.
MODEL=qwen2.5:0.5b
# Allocate a 40-GB root volume for the operating system, engine and model.
DISK=40
# Match the engine version previously used for this project.
OLLAMA_VERSION=0.40.2
# Use the unique key name as this run's resource tag and EC2 client token.
RUN_ID="$KEYNAME"
# Prevent the AWS CLI from opening an interactive output pager.
export AWS_PAGER=""

# PART 2 - THE COMMANDS --------------------------------------------------
# Check local prerequisites before requesting any billable resources.
for tool in aws python3 ssh curl awk mktemp; do
  # Require each executable used by this script to be available on the laptop.
  command -v "$tool" >/dev/null
done
# Display the authenticated identity so the account used for this run is clear.
aws sts get-caller-identity --region "$REGION" --query Arn --output text
# Read the GPU quota in vCPUs, not instances: zero rules out the GPU lane, while one g4dn.xlarge would need four vCPUs.
aws service-quotas get-service-quota --region "$REGION" \
  --service-code ec2 --quota-code L-DB2E81BA \
  --query '{quota:Quota.QuotaName,vCPUs:Quota.Value}' --output table
# Read the Standard quota because the chosen CPU lane still needs capacity for eight vCPUs even though it does not use the GPU quota.
STANDARD_QUOTA=$(aws service-quotas get-service-quota --region "$REGION" \
  --service-code ec2 --quota-code L-1216C47A --query Quota.Value --output text)
# Reject an insufficient Standard limit before launching; existing instances can also consume this quota.
awk -v quota="$STANDARD_QUOTA" 'BEGIN { if (quota < 8) { print "Standard quota must be at least 8 vCPUs." > "/dev/stderr"; exit 1 } }'
# Query the live Linux shared-tenancy On-Demand price for the selected instance and region rather than assuming the recorded rate is current.
aws pricing get-products --region us-east-1 --service-code AmazonEC2 \
  --filters "Type=TERM_MATCH,Field=instanceType,Value=$INSTANCE" \
    "Type=TERM_MATCH,Field=regionCode,Value=$REGION" \
    "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
    "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
    "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
    "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
  --output json | python3 -c 'import json,sys; d=json.load(sys.stdin); rates=[x["pricePerUnit"]["USD"] for p in d["PriceList"] for t in json.loads(p)["terms"]["OnDemand"].values() for x in t["priceDimensions"].values() if x["unit"] == "Hrs"]; assert rates, "No hourly price found"; print("Live compute price: $"+rates[0]+" / hour")'
# Show the approximate compute-only budget and distinguish it from disk and public IPv4 charges.
awk -v rate="$RATE" 'BEGIN { printf "Assumed rate: $%.3f/hour; $100 buys about %.0f compute hours; EBS and IPv4 are extra.\n", rate, 100/rate }'

# Resolve Canonical's current Ubuntu 24.04 AMD64 AMI instead of using an image ID from my previous instance.
AMI=$(aws ssm get-parameter --region "$REGION" \
  --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query Parameter.Value --output text)
# Verify that the resolved image belongs to Canonical and uses the architecture expected by c7i.2xlarge.
IMAGE_CHECK=$(aws ec2 describe-images --region "$REGION" --image-ids "$AMI" \
  --query 'Images[0].[OwnerId,Architecture]' --output text)
# Stop if the selected image is not the expected official x86_64 image.
[[ "$IMAGE_CHECK" == $'099720109477\tx86_64' ]]
# Read the image's root-device name so the disk mapping targets the actual root volume.
ROOT_DEVICE=$(aws ec2 describe-images --region "$REGION" --image-ids "$AMI" \
  --query 'Images[0].RootDeviceName' --output text)
# List available existing subnets, or examine only the explicitly requested subnet.
if [[ -n "${SUBNET_ID:-}" ]]; then
  # Restrict network selection to the supplied subnet instead of silently choosing another.
  CANDIDATES=$(aws ec2 describe-subnets --region "$REGION" --subnet-ids "$SUBNET_ID" \
    --query 'Subnets[?State==`available` && AvailableIpAddressCount>`0`].SubnetId' --output text)
else
  # Consider existing subnets with address capacity, including those in a non-default VPC.
  CANDIDATES=$(aws ec2 describe-subnets --region "$REGION" \
    --query 'Subnets[?State==`available` && AvailableIpAddressCount>`0`].SubnetId' --output text)
fi
# Start with no selected network so a missing public route causes a clear failure.
SELECTED_SUBNET=""
# Examine each candidate's effective route table before selecting a network.
for candidate in $CANDIDATES; do
  # Retrieve the candidate's VPC so the security group will be created in that same VPC.
  CANDIDATE_VPC=$(aws ec2 describe-subnets --region "$REGION" --subnet-ids "$candidate" \
    --query 'Subnets[0].VpcId' --output text)
  # Prefer a route table explicitly associated with this subnet over the VPC's main table.
  ROUTE_TABLE=$(aws ec2 describe-route-tables --region "$REGION" \
    --filters "Name=association.subnet-id,Values=$candidate" \
    --query 'RouteTables[0].RouteTableId' --output text)
  # Use the main route table only when this subnet has no explicit association.
  if [[ "$ROUTE_TABLE" == None || -z "$ROUTE_TABLE" ]]; then
    # Resolve the main route table for this candidate's VPC.
    ROUTE_TABLE=$(aws ec2 describe-route-tables --region "$REGION" \
      --filters "Name=vpc-id,Values=$CANDIDATE_VPC" "Name=association.main,Values=true" \
      --query 'RouteTables[0].RouteTableId' --output text)
  fi
  # Read an active IPv4 default route from the effective table, not from another subnet's table.
  GATEWAY=$(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$ROUTE_TABLE" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0` && State==`active`].GatewayId | [0]' --output text)
  # Accept only a direct Internet Gateway route so SSH and model downloads can use the assigned public IP.
  if [[ "$GATEWAY" == igw-* ]]; then
    # Save the selected subnet for the instance launch command.
    SELECTED_SUBNET="$candidate"
    # Save its VPC for the security group creation command.
    VPC_ID="$CANDIDATE_VPC"
    # Stop searching once a suitable existing network is found.
    break
  fi
done
# Fail before resource creation if no usable public subnet exists.
[[ -n "$SELECTED_SUBNET" ]] || {
  # Explain the missing prerequisite without modifying an existing network.
  printf 'No public subnet found; provide SUBNET_ID with an active Internet Gateway default route.\n' >&2
  # End the run because a private subnet cannot satisfy the planned public SSH connection.
  exit 1
}
# Discover the laptop's current public IPv4 address for the single permitted SSH source.
MYIP=$(curl -4 -fsS --connect-timeout 10 --max-time 20 https://checkip.amazonaws.com)
# Validate the address before passing it into the security-group ingress rule.
python3 -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' "$MYIP"
# Create private temporary storage for this run's key and SSH host fingerprints.
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/opencsusm-woo.XXXXXX")
# Store the generated key inside the private temporary directory.
KEYFILE="$WORK_DIR/$KEYNAME.pem"
# Initialize the security group ID so cleanup also handles failures before launch.
SG=""
# Initialize the instance ID so cleanup can report a partially completed run.
ID=""
# Initialize the tunnel PID so cleanup never kills an unrelated process.
TUNNEL_PID=""
# Restrict permissions on newly created key and request files.
umask 077

# Release only resources tagged for this run, including after a failed installation or request.
cleanup_resources() {
  # Close this run's SSH tunnel before stopping its remote destination.
  if [[ -n "$TUNNEL_PID" ]]; then
    # Send the tunnel process a termination signal without touching other SSH sessions.
    kill "$TUNNEL_PID" 2>/dev/null || true
    # Reap the tunnel process even when it already exited.
    wait "$TUNNEL_PID" 2>/dev/null || true
    # Mark the tunnel as closed so a second cleanup attempt is harmless.
    TUNNEL_PID=""
  fi
  # Discover this run's instances by its unique tag, including a launch interrupted before ID was saved.
  REMAINING_IDS=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:OpenCSUSMRun,Values=$RUN_ID" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
    --query 'Reservations[].Instances[].InstanceId' --output text) || return 1
  # Terminate only this run's instances when the tagged query returns an ID.
  if [[ -n "$REMAINING_IDS" && "$REMAINING_IDS" != None ]]; then
    # Release the compute instance and its auto-assigned public IP; the root disk is marked for deletion on termination.
    aws ec2 terminate-instances --region "$REGION" --instance-ids $REMAINING_IDS --output table || return 1
    # Wait for termination before deleting resources still attached to the instance.
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids $REMAINING_IDS || return 1
  fi
  # Allow AWS time to remove the tagged root volume after termination.
  for attempt in {1..60}; do
    # Query this run's volumes so an attached or still-deleting disk cannot be mistaken for completed cleanup.
    LEFT_VOLUMES=$(aws ec2 describe-volumes --region "$REGION" \
      --filters "Name=tag:OpenCSUSMRun,Values=$RUN_ID" --query 'Volumes[].VolumeId' --output text) || return 1
    # Stop waiting when the root disk and any tagged leftover volumes have disappeared.
    if [[ -z "$LEFT_VOLUMES" || "$LEFT_VOLUMES" == None ]]; then
      # Finish the volume check once there are no tagged disks.
      break
    fi
    # Find only unattached tagged volumes so existing or attached disks are never deleted.
    AVAILABLE_VOLUMES=$(aws ec2 describe-volumes --region "$REGION" \
      --filters "Name=tag:OpenCSUSMRun,Values=$RUN_ID" "Name=status,Values=available" \
      --query 'Volumes[].VolumeId' --output text) || return 1
    # Delete a tagged disk only after AWS reports that it is available.
    for volume in $AVAILABLE_VOLUMES; do
      # Remove the detached leftover disk to stop its storage charges.
      aws ec2 delete-volume --region "$REGION" --volume-id "$volume" || return 1
    done
    # Pause briefly for AWS resource deletion to become visible.
    sleep 2
  done
  # Refuse to claim successful teardown if a tagged disk remains after the wait.
  [[ -z "$LEFT_VOLUMES" || "$LEFT_VOLUMES" == None ]] || return 1
  # Find the dedicated group by its tag so even an interrupted group creation can be recovered.
  LEFT_GROUPS=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=tag:OpenCSUSMRun,Values=$RUN_ID" --query 'SecurityGroups[].GroupId' --output text) || return 1
  # Delete only dedicated groups belonging to this execution.
  for group in $LEFT_GROUPS; do
    # Retry while the terminated instance's network interface is still releasing the group.
    for attempt in {1..30}; do
      # Remove this run's security group once no network interface depends on it.
      if aws ec2 delete-security-group --region "$REGION" --group-id "$group" 2>"$WORK_DIR/group-error.txt"; then
        # Stop retrying after successful group deletion.
        break
      fi
      # Wait briefly for network interface cleanup before another deletion attempt.
      sleep 2
    done
    # Confirm the tagged group is gone rather than treating an exhausted retry loop as success.
    GROUP_COUNT=$(aws ec2 describe-security-groups --region "$REGION" \
      --filters "Name=tag:OpenCSUSMRun,Values=$RUN_ID" --query 'length(SecurityGroups)' --output text) || return 1
    # Report incomplete cleanup if AWS still has this run's group.
    [[ "$GROUP_COUNT" == 0 ]] || return 1
  done
  # Locate only this run's tagged key pair instead of deleting a pre-existing personal key.
  LEFT_KEYS=$(aws ec2 describe-key-pairs --region "$REGION" \
    --filters "Name=tag:OpenCSUSMRun,Values=$RUN_ID" --query 'KeyPairs[].KeyName' --output text) || return 1
  # Remove the AWS key pair registrations generated by this execution.
  for key in $LEFT_KEYS; do
    # Delete the dedicated AWS key registration after its instance has been terminated.
    aws ec2 delete-key-pair --region "$REGION" --key-name "$key" || return 1
  done
}

# Preserve the original exit status and retain recovery details if AWS cleanup fails.
finish() {
  # Remember whether the normal command sequence or an earlier command failed.
  status=$?
  # Disable the traps during cleanup to avoid recursive error handling.
  trap - EXIT INT TERM
  # Make a best effort to remove this run's resources after any premature exit.
  if ! cleanup_resources; then
    # Print resource identifiers and the private working directory for manual recovery without revealing key contents.
    printf 'Cleanup incomplete: region=%s run=%s instance=%s group=%s key=%s; recovery files: %s\n' \
      "$REGION" "$RUN_ID" "$ID" "$SG" "$KEYNAME" "$WORK_DIR" >&2
    # Return failure so incomplete teardown is never presented as a successful run.
    exit 1
  fi
  # Delete only the temporary directory created by this execution after successful cloud cleanup.
  rm -rf "$WORK_DIR"
  # Return the original failure code even if the cleanup itself succeeded.
  exit "$status"
}
# Register cleanup for normal completion, command failure and explicit script exits.
trap finish EXIT
# Convert an interrupt into a failing exit that invokes the cleanup trap.
trap 'exit 130' INT
# Convert a termination signal into a failing exit that invokes the cleanup trap.
trap 'exit 143' TERM

# Create a dedicated RSA key pair, tag it for cleanup and save its private material locally without printing it.
aws ec2 create-key-pair --region "$REGION" --key-name "$KEYNAME" --key-type rsa \
  --tag-specifications "ResourceType=key-pair,Tags=[{Key=OpenCSUSMRun,Value=$RUN_ID},{Key=Owner,Value=$OWNER}]" \
  --query KeyMaterial --output text > "$KEYFILE"
# Make the saved private key readable only by the local user.
chmod 600 "$KEYFILE"
# Create an empty dedicated security group in the selected subnet's VPC, tagged with my name and this run.
SG=$(aws ec2 create-security-group --region "$REGION" --vpc-id "$VPC_ID" \
  --group-name "$RUN_ID" --description 'CS446 OpenCSUSM SSH from one IPv4 address' \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=OpenCSUSMRun,Value=$RUN_ID},{Key=Owner,Value=$OWNER},{Key=Student,Value='Youngchan Woo'}]" \
  --query GroupId --output text)
# Add the group's only inbound rule: TCP port 22 from the laptop's current public IPv4 address, leaving port 11434 closed.
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG" \
  --protocol tcp --port 22 --cidr "$MYIP/32"
# Launch one Ubuntu CPU instance with the dedicated key, public IP, encrypted 40-GB gp3 root disk, name tags and automatic root-disk deletion on termination.
ID=$(aws ec2 run-instances --region "$REGION" --image-id "$AMI" \
  --instance-type "$INSTANCE" --key-name "$KEYNAME" --count 1 \
  --network-interfaces "[{\"DeviceIndex\":0,\"SubnetId\":\"$SELECTED_SUBNET\",\"Groups\":[\"$SG\"],\"AssociatePublicIpAddress\":true,\"DeleteOnTermination\":true}]" \
  --block-device-mappings "[{\"DeviceName\":\"$ROOT_DEVICE\",\"Ebs\":{\"VolumeSize\":$DISK,\"VolumeType\":\"gp3\",\"Encrypted\":true,\"DeleteOnTermination\":true}}]" \
  --metadata-options HttpTokens=required,HttpEndpoint=enabled \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=opencsusm-$OWNER},{Key=Student,Value='Youngchan Woo'},{Key=Course,Value=CS446},{Key=Project,Value=OpenCSUSM},{Key=Owner,Value=$OWNER},{Key=OpenCSUSMRun,Value=$RUN_ID}]" \
    "ResourceType=volume,Tags=[{Key=Owner,Value=$OWNER},{Key=OpenCSUSMRun,Value=$RUN_ID}]" \
  --client-token "$RUN_ID" --query 'Instances[0].InstanceId' --output text)
# Display the new instance ID and remind the operator that running resources incur charges.
printf 'Created %s; compute, EBS and public IPv4 charges start now.\n' "$ID"
# Wait for the instance to enter the running state before connecting over SSH.
aws ec2 wait instance-running --region "$REGION" --instance-ids "$ID"
# Read the auto-assigned public IP instead of relying on a previous instance's address or VPC DNS settings.
PUBLIC_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
# Refuse to proceed when the instance has no usable public IPv4 address.
[[ -n "$PUBLIC_IP" && "$PUBLIC_IP" != None ]]
# Apply identical key, timeout and dedicated host-fingerprint settings to each SSH connection.
SSH_OPTIONS=(-i "$KEYFILE" -o BatchMode=yes -o ConnectTimeout=10 \
  -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$WORK_DIR/known_hosts" \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3)
# Poll SSH because an instance may be running before its SSH server is ready.
for attempt in {1..40}; do
  # Test authentication to the new instance without making remote changes.
  if ssh "${SSH_OPTIONS[@]}" "ubuntu@$PUBLIC_IP" true 2>/dev/null; then
    # Stop polling once an authenticated SSH command succeeds.
    break
  fi
  # Wait briefly before checking the SSH server again.
  sleep 3
done
# Require a successful final SSH connection before attempting engine installation.
ssh "${SSH_OPTIONS[@]}" "ubuntu@$PUBLIC_IP" true
# Install the selected Ollama version on EC2 and restrict its service listener to the instance's loopback interface.
ssh "${SSH_OPTIONS[@]}" "ubuntu@$PUBLIC_IP" "bash -s -- '$OLLAMA_VERSION'" <<'ON_INSTANCE'
# Stop remote installation if a command or pipeline fails.
set -euo pipefail
# Track cloud-init's completion status so recoverable warnings do not abort an otherwise usable instance.
CLOUD_INIT_STATUS=0
# Wait for Ubuntu's initial provisioning and preserve its exit code for the distinction between warnings and fatal errors.
sudo cloud-init status --wait || CLOUD_INIT_STATUS=$?
# Continue after recoverable warnings but reject a fatal provisioning failure.
if [[ "$CLOUD_INIT_STATUS" == 2 ]]; then
  # Make recoverable provisioning warnings visible before checking package and service installation separately.
  printf 'cloud-init completed with recoverable warnings; checking installation next.\n' >&2
elif [[ "$CLOUD_INIT_STATUS" != 0 ]]; then
  # Abort the remote block on a fatal provisioning error so the laptop cleans up this run.
  exit "$CLOUD_INIT_STATUS"
fi
# Refresh the instance's package metadata before installing download dependencies.
sudo apt-get update -qq
# Install the HTTPS certificates, downloader and decompressor used by Ollama's installer.
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates zstd
# Download the official installer and pass the selected version to its installation process.
curl -fsSL --connect-timeout 20 --max-time 120 https://ollama.com/install.sh | OLLAMA_VERSION="$1" sh
# Create the systemd override directory for the Ollama service installed by the installer.
sudo mkdir -p /etc/systemd/system/ollama.service.d
# Set Ollama's listener to EC2's loopback address so the model is reachable only from that instance or the SSH tunnel.
printf '[Service]\nEnvironment="OLLAMA_HOST=127.0.0.1:11434"\n' | sudo tee /etc/systemd/system/ollama.service.d/opencsusm.conf >/dev/null
# Reload systemd so it recognizes the service's loopback override.
sudo systemctl daemon-reload
# Keep the installed Ollama service enabled after an instance restart.
sudo systemctl enable ollama
# Restart Ollama to apply the loopback listener setting.
sudo systemctl restart ollama
# Confirm that the Ollama service is active before downloading the model.
systemctl is-active ollama
ON_INSTANCE
# Pull the model over SSH; the installer already started Ollama's service, but it cannot answer this model's requests until the weights are downloaded.
ssh "${SSH_OPTIONS[@]}" "ubuntu@$PUBLIC_IP" "bash -s -- '$MODEL'" <<'ON_INSTANCE'
# Stop this remote model preparation block if a download or readiness check fails.
set -euo pipefail
# Wait for the restarted service to accept loopback HTTP requests.
for attempt in {1..30}; do
  # Check the engine's model-list endpoint without exposing any public inference port.
  if curl -4 --noproxy '*' -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:11434/api/tags >/dev/null; then
    # Stop waiting once Ollama's HTTP service is ready.
    break
  fi
  # Allow the service two more seconds to initialize before checking again.
  sleep 2
done
# Require a ready loopback service after polling instead of attempting the model download after an exhausted readiness wait.
curl -4 --noproxy '*' -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:11434/api/tags >/dev/null
# Download the selected small model into the running Ollama service's model store.
ollama pull "$1"
# Show the installed models to verify that the selected model was downloaded.
ollama list
# Verify that the OpenAI-compatible model-list endpoint responds on the instance's loopback port.
curl -4 --noproxy '*' -fsS --connect-timeout 2 --max-time 10 http://127.0.0.1:11434/v1/models
# Separate the model-list response from later terminal output.
printf '\n'
ON_INSTANCE

# Ask the operating system for an unused loopback port so an existing local Ollama cannot accidentally answer the EC2 test.
LOCAL_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
# Forward the laptop's loopback port through SSH to EC2's localhost:11434; the left address is the laptop and the destination localhost is the instance.
ssh "${SSH_OPTIONS[@]}" -N -o ExitOnForwardFailure=yes \
  -L "127.0.0.1:$LOCAL_PORT:localhost:$PORT" "ubuntu@$PUBLIC_IP" \
  >"$WORK_DIR/tunnel.out" 2>"$WORK_DIR/tunnel.err" &
# Save only this script's background SSH PID for readiness checks and cleanup.
TUNNEL_PID=$!
# Track readiness independently from the retry count so an exhausted wait cannot be treated as success.
TUNNEL_READY=0
# Wait for the forwarded endpoint before sending the greeting request.
for attempt in {1..30}; do
  # Stop with the tunnel's diagnostic output if the SSH forwarding process exits early.
  if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
    # Print the SSH error message without printing private key contents.
    cat "$WORK_DIR/tunnel.err" >&2
    # Trigger resource cleanup because the tunnel failed.
    exit 1
  fi
  # Check the remote model endpoint through localhost on the laptop.
  if curl -4 --noproxy '*' -fsS --connect-timeout 2 --max-time 5 "http://localhost:$LOCAL_PORT/v1/models" >/dev/null; then
    # Mark the SSH-forwarded endpoint as ready only after an HTTP check succeeds.
    TUNNEL_READY=1
    # Stop waiting once the SSH-forwarded inference endpoint responds.
    break
  fi
  # Give the forwarding connection another second to become ready.
  sleep 1
done
# Reject a readiness timeout before sending the actual test request.
if [[ "$TUNNEL_READY" != 1 ]]; then
  # Explain why this run is being cleaned up instead of silently proceeding to inference.
  printf 'SSH-forwarded model endpoint did not become ready.\n' >&2
  # Exit through the cleanup handler when the forwarded endpoint remains unavailable.
  exit 1
fi
# Verify that the forwarding process is still alive before sending the greeting.
kill -0 "$TUNNEL_PID"
# Send the requested name through the SSH tunnel using a 20-token limit and temperature zero, then print the actual server response.
curl -4 --noproxy '*' -fsS --connect-timeout 10 --max-time 180 "http://localhost:$LOCAL_PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"system\",\"content\":\"Greet the user by their full name. Reply with the greeting only.\"},{\"role\":\"user\",\"content\":\"I am John\"}],\"max_tokens\":20,\"temperature\":0,\"stream\":false}"
# Separate the actual model response from the teardown output.
printf '\n'
# Close the forwarding process before stopping the instance it connects to.
kill "$TUNNEL_PID"
# Reap the SSH process; termination by the signal above is an expected nonzero exit.
wait "$TUNNEL_PID" 2>/dev/null || true
# Mark the tunnel as closed so the exit handler does not signal it again.
TUNNEL_PID=""

# Stop the instance to end compute charges, while recognizing that its retained EBS disk can still incur storage charges.
aws ec2 stop-instances --region "$REGION" --instance-ids "$ID" --output table
# Wait until compute is stopped before proceeding to permanent deletion.
aws ec2 wait instance-stopped --region "$REGION" --instance-ids "$ID"
# Terminate this run's instance and delete its disk, security group and key registration, preserving the pre-existing VPC and subnet.
cleanup_resources
# Display nonterminated instances tagged to this run; an empty result indicates no running or stopped instance remains.
aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:OpenCSUSMRun,Values=$RUN_ID" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
  --query 'Reservations[].Instances[].InstanceId' --output text
# Display remaining tagged disks; an empty result confirms this run no longer has EBS storage to bill.
aws ec2 describe-volumes --region "$REGION" --filters "Name=tag:OpenCSUSMRun,Values=$RUN_ID" \
  --query 'Volumes[].VolumeId' --output text
# Display remaining tagged security groups; an empty result confirms the dedicated group was removed.
aws ec2 describe-security-groups --region "$REGION" --filters "Name=tag:OpenCSUSMRun,Values=$RUN_ID" \
  --query 'SecurityGroups[].GroupId' --output text
# Display remaining tagged key pairs; an empty result confirms the dedicated AWS key registration was removed.
aws ec2 describe-key-pairs --region "$REGION" --filters "Name=tag:OpenCSUSMRun,Values=$RUN_ID" \
  --query 'KeyPairs[].KeyName' --output text
# Report successful completion only after the test and tagged resource teardown commands have succeeded.
printf 'Completed the request and teardown; the four resource queries above should be empty.\n'
