#!/bin/bash

# This script is used to restart the BeeGFS cluster.
# Order of operations:
# To stop: 1) Clients 2) Storage 3) Metadata 4) Management
# To start: 1) Management 2) Metadata 3) Storage 4) Clients

if [ "$1" == "stop" ]; then
    echo "Stopping BeeGFS clients..."
    pdsh -w lms-login,thor[1-10] sudo systemctl stop beegfs-client

    echo "Stopping BeeGFS storage servers..."
    pdsh -w thor[1-10] sudo systemctl stop beegfs-storage

    echo "Stopping BeeGFS metadata servers..."
    pdsh -w thor[1-2] sudo systemctl stop beegfs-meta

    echo "Stopping BeeGFS management service..."
    pdsh -w lms-mgmt sudo systemctl stop beegfs-mgmtd

elif [ "$1" == "start" ]; then
    echo "Starting BeeGFS management service..."
    pdsh -w lms-mgmt sudo systemctl start beegfs-mgmtd

    echo "Starting BeeGFS metadata servers..."
    pdsh -w thor[1-2] sudo systemctl start beegfs-meta

    echo "Starting BeeGFS storage servers..."
    pdsh -w thor[1-10] sudo systemctl start beegfs-storage

    echo "Starting BeeGFS clients..."
    pdsh -w lms-login,thor[1-10] sudo systemctl start beegfs-client

else
    echo "Usage: $0 {start|stop}"
    exit 1
fi
