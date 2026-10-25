#!/usr/bin/env bash
# Usage: db-tunnel.sh [command...]
#
# Launches a throwaway EC2 instance, forwards 127.0.0.1:<db port> to the
# private database through it and runs the command. Without a command the
# tunnel stays open until Ctrl-C. The instance is terminated on exit.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cloud_config="$root/scripts/db-tunnel.cloud-config.yaml"
ssh_options=(
	-i "$root/ssh_key.pem"
	-o StrictHostKeyChecking=no
	-o UserKnownHostsFile=/dev/null
	-o LogLevel=ERROR
	-o ConnectTimeout=5
)

infra_output() {
	terraform -chdir="$root/tf/infra" output "$@"
}

ec2() {
	aws ec2 --region "$region" "$@"
}

log() {
	echo "db-tunnel: $*" >&2
}

ensure_port_free() {
	local listener
	if listener="$(lsof -nP -iTCP:"$db_port" -sTCP:LISTEN)"; then
		log "local port $db_port is already in use, stop this first:"
		echo "$listener" >&2
		return 1
	fi
}

launch_instance() {
	local launch ami subnet_id key_name security_group_ids
	launch="$(infra_output -json db_tunnel)"
	read -r ami subnet_id key_name <<<"$(jq -r '"\(.ami) \(.subnet_id) \(.key_name)"' <<<"$launch")"
	read -ra security_group_ids <<<"$(jq -r '.security_group_ids | join(" ")' <<<"$launch")"

	ec2 run-instances \
		--image-id "$ami" \
		--instance-type t2.micro \
		--subnet-id "$subnet_id" \
		--security-group-ids "${security_group_ids[@]}" \
		--key-name "$key_name" \
		--instance-initiated-shutdown-behavior terminate \
		--user-data "file://$cloud_config" \
		--tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=db-tunnel},{Key=Role,Value=db-tunnel}]' \
		--query 'Instances[0].InstanceId' --output text
}

public_ip() {
	ec2 describe-instances --instance-ids "$instance_id" \
		--query 'Reservations[0].Instances[0].PublicIpAddress' --output text
}

wait_for_ssh() {
	for _ in {1..60}; do
		ssh -n "${ssh_options[@]}" "$target" true 2>/dev/null && return
		sleep 5
	done
	log "timed out waiting for SSH on $target"
	return 1
}

open_tunnel() {
	ssh "${ssh_options[@]}" -M -S "$control_socket" -fN \
		-o ExitOnForwardFailure=yes \
		-L "127.0.0.1:$db_port:$db_address:$db_port" "$target"
}

hold_tunnel() {
	log "tunnel open on 127.0.0.1:$db_port, press Ctrl-C to close it and terminate the instance"
	while ssh -S "$control_socket" -O check "$target" 2>/dev/null; do
		sleep 5
	done
	log "tunnel closed unexpectedly"
	return 1
}

cleanup() {
	trap '' INT TERM
	if [[ -S "$control_socket" ]]; then
		ssh -S "$control_socket" -O exit "$target" 2>/dev/null || true
	fi
	if [[ -n "$instance_id" ]]; then
		log "terminating $instance_id"
		ec2 terminate-instances --instance-ids "$instance_id" >/dev/null
		ec2 wait instance-terminated --instance-ids "$instance_id"
	fi
	rm -rf "$tmp_dir"
}

main() {
	region="$(infra_output -raw aws_region)"
	db_address="$(infra_output -raw db_address)"
	db_port="$(infra_output -raw db_port)"
	ensure_port_free
	tmp_dir="$(mktemp -d)"
	control_socket="$tmp_dir/control"
	instance_id=""
	target=""
	trap cleanup EXIT
	trap 'exit 130' INT TERM

	log "launching instance"
	instance_id="$(launch_instance)"
	ec2 wait instance-running --instance-ids "$instance_id"
	target="ubuntu@$(public_ip)"
	log "waiting for SSH on $target"
	wait_for_ssh
	open_tunnel

	if (($#)); then
		"$@"
	else
		hold_tunnel
	fi
}

main "$@"
