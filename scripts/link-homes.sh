#!/bin/bash

# Recreate USERS file
SCRIPTS_DIR="$(dirname "$(readlink -f "$0")")"
python3 "$SCRIPTS_DIR"/extract-users.py
USER_FILE="USERS"

# Read the file into an array
mapfile -t users <"$USER_FILE"

# Define the source and target directories
source_dir="/mnt/home"
target_dir="/home"

# Define nodes on which to run the command
# These have to be all compute nodes, such that the `/home/<user>` directories are available, because `/home` on the
# compute nodes is a local directory that is not shared
compute_nodes=()
node_prefix='thor'
node_appendix="psi.ch"
num_nodes=10

for i in $(seq 1 $num_nodes); do
    compute_nodes+=("${node_prefix}${i}.${node_appendix}")
done

# Other nodes and exclude_nodes
other_nodes=( "lms-login.psi.ch" )  # "lms-mgmt.psi.ch"

all_nodes=("${compute_nodes[@]}" "${other_nodes[@]}")

exclude_nodes=()  # e.g. ("thor3.psi.ch")

# Print all nodes for verification
echo "Nodes:" "${all_nodes[@]}"

# Filter out the nodes to be excluded
final_nodes=()
for node in "${all_nodes[@]}"; do
    exclude=false
    for exclude_node in "${exclude_nodes[@]}"; do
        if [[ "$node" == "$exclude_node" ]]; then
            exclude=true
            break
        fi
    done
    if [[ "$exclude" == false ]]; then
        final_nodes+=("$node")
    fi
done

# Iterate over nodes and users and link `/mnt/home/<user>` to `/home/<user>`
for node in "${final_nodes[@]}"; do
    # Prepare the command to create symlinks
    echo "On node: $node"
    for user in "${users[@]}"; do
        echo "Creating symlink for user: $user"
        # Construct the full source and target paths
        src="$source_dir/$user"
        tgt="$target_dir/$user"

        # Build the command to create symlink with robust existence check
        cmd='if [ ! -L "'"$tgt"'" ] && [ ! -e "'"$tgt"'" ]; then sudo ln -s "'"$src"'" "'"$tgt"'"; else echo "Skipping '"$user"': Target exists or is already a symlink"; fi'

        # Use pdsh to run the symlink creation command on all nodes
        pdsh -l "$USER" -w "$node" "$cmd" || true

    done
done
