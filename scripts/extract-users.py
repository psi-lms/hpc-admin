#!/usr/bin/env python3

"""
Little helper script that extracts the users from a specified YAML configuration file
for use in our additional configuration scripts, such that we don't have to update
user lists in multiple places.
"""

import argparse
from pathlib import Path

try:
    import yaml
except ImportError:
    import sys
    import warnings
    msg = "PyYAML package is not installed. Please install it using 'pip3 install pyyaml'"
    warnings.warn(msg, UserWarning)
    sys.exit(1)

# Parse command-line arguments
parser = argparse.ArgumentParser(description="Extract users from a YAML configuration file.")
parser.add_argument(
    "-p", "--path",
    type=Path,
    default=Path(__file__).resolve().parent.parent.parent / 'data-lms' / 'compute_cluster.yaml',
    help="Path to the YAML configuration file. Defaults to 'compute_cluster.yaml' in the parent directory."
)
args = parser.parse_args()

config_file = args.path
exclude_users = {"buchel_k", "software", "sala", "ebner", "sharap_b"}

try:
    with open(config_file, 'r') as f:
        config_data = yaml.safe_load(f)

    # Extract the lists of admins and users
    admins = config_data.get('aaa::admins', [])
    users = config_data.get('aaa::users', [])

    # Combine both lists into a set to eliminate duplicates, and remove excluded users
    all_users = sorted(list(set(admins + users) - exclude_users))

    # Write to file
    user_file = Path(__file__).resolve().parent / 'USERS'
    user_file.write_text('\n'.join(all_users))

    # Print the combined set for debugging
    print(f"Combined set of admins and users {all_users} written to file `{user_file}`.")

except FileNotFoundError:
    print(f"Error: The file {config_file} was not found.")
except yaml.YAMLError as e:
    print(f"Error parsing YAML file: {e}")
