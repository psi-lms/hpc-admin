#!/bin/bash

# Define computer nodes
compute_nodes=()
node_prefix='thor'
node_appendix="psi.ch"
num_nodes=10

for i in $(seq 1 $num_nodes); do
    compute_nodes+=("${node_prefix}${i}.${node_appendix}")
done

# Other nodes and exclude_nodes
other_nodes=("lms-login.psi.ch" "lms-mgmt.psi.ch")

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

# Run puppet agent on all nodes using pdsh
for node in "${final_nodes[@]}"; do
    echo "Running puppet on $node"

    # Use absolute path, as `sudo` uses a restricted $PATH, and the puppet dir is not part of it.
    # Could modify it via `sudo visudo` and add it to the restricted $PATH.
    # Keeping solution with full, absolute path instead for now.
    pdsh -l "$USER" -w "$node" sudo /opt/puppetlabs/bin/puppet agent -t

    # Old solution using ssh instead of `pdsh`
    # ssh "$USER"@"$node" 'sudo bash -i -c "puppet agent -t"'
done
