# Small helper scripts for common tasks

##
- `extract-users.py`: Obtain usernames from `compute_cluster.yaml` for use in other scripts, so that one doesn't have to
  update the list of users in multiple places, but **only** in the configuration YAML file
- `link-homes.sh`: Creates symlinks (if not existing) from `/mnt/home/$USER` to `/home/$USER` so that access to the
  mounted NFS can be achieved from the _typical_ home directory path users expect
- `run-puppet.sh`: Connect to compute nodes and login and management VMs and run `puppet agent -t`. Script also allows
  for some nodes to be excluded from the updates.
- `restart-BGFS.sh`: Restart BeeGFS service. The script will take care of the specific order that should be respected. 
  - Perquisites: 
    - Install `pdsh` on your local machine.
    - Able to ssh to all nodes password-less.
    - To have sudo access
  - Usage:
    - `./restart-BGFS.sh stop` to stop BeeGFS service.
    - `./restart-BGFS.sh start` to start BeeGFS service.

## Notes

- Shell scripts require `pdsh` for remote execution of commands on (multiple) hosts
- If `pdsh` gives exception: `rcmd: socket: Permission denied`, create `/etc/pdsh/rcmd_default` on your local machine
  and add "ssh" as text to it, e.g., `sudo echo "ssh" > /etc/pdsh/rcmd_default`
- `extract-users.py` requires `pyyaml` installed