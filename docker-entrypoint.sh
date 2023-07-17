#!/bin/bash
set -euo pipefail

chown root:root /home
chmod 755 /home

cp /tempmounts/munge.key /etc/munge/munge.key
chown munge:munge /etc/munge/munge.key
chmod 600 /etc/munge/munge.key

if [ "$1" = "slurmdbd" ]
then
    echo "---> Starting the MUNGE Authentication service (munged) ..."
    gosu munge /usr/sbin/munged

    echo "---> Starting the Slurm Database Daemon (slurmdbd) ..."

    cp /tempmounts/slurmdbd.conf /etc/slurm/slurmdbd.conf
    echo "StoragePass=${StoragePass}" >> /etc/slurm/slurmdbd.conf
    chown slurm:slurm /etc/slurm/slurmdbd.conf
    chmod 600 /etc/slurm/slurmdbd.conf
    {
        . /etc/slurm/slurmdbd.conf
        until echo "SELECT 1" | mysql -h $StorageHost -u$StorageUser -p$StoragePass 2>&1 > /dev/null
        do
            echo "-- Waiting for database to become active ..."
            sleep 2
        done
    }
    echo "-- Database is now active ..."

    exec gosu slurm /usr/sbin/slurmdbd -Dvvv
fi

if [ "$1" = "slurmctld" ]
then
    echo "---> Starting the MUNGE Authentication service (munged) ..."
    gosu munge /usr/sbin/munged

    echo "---> Waiting for slurmdbd to become active before starting slurmctld ..."

    until 2>/dev/null >/dev/tcp/slurmdbd/6819
    do
        echo "-- slurmdbd is not available.  Sleeping ..."
        sleep 2
    done
    echo "-- slurmdbd is now active ..."

    echo "---> Setting permissions for state directory ..."
    chown slurm:slurm /var/spool/slurmctld

    echo "---> Setting up active nodes directory"
    mkdir -p /home/slurm/nodes
    chown slurm:slurm /home/slurm

    echo "---> Starting the Slurm Controller Daemon (slurmctld) ..."
    if /usr/sbin/slurmctld -V | grep -q '17.02' ; then
        exec gosu slurm /usr/sbin/slurmctld -Dvvv
    else
        exec gosu slurm /usr/sbin/slurmctld -i -Dvvv
    fi
fi

if [ "$1" = "slurmd" ]
then
    echo "---> Set shell resource limits ..."
    ulimit -l unlimited
    ulimit -s unlimited
    ulimit -n 131072
    ulimit -a

    echo "---> Starting the MUNGE Authentication service (munged) ..."
    gosu munge /usr/sbin/munged

    echo "---> Waiting for slurmctld to become active before starting slurmd..."

    until 2>/dev/null >/dev/tcp/slurmctld-0/6817
    do
        echo "-- slurmctld is not available.  Sleeping ..."
        sleep 2
    done
    echo "-- slurmctld is now active ..."

    echo "---> Writing IP to nodes directory"
    MY_IP_DATA=( $( cat /etc/hosts | grep $(hostname) ) )
    touch /home/slurm/nodes/$( hostname )
    echo ${MY_IP_DATA[0]} > /home/slurm/nodes/$( hostname )

    echo "---> Starting the Slurm Node Daemon (slurmd) ..."
    exec /usr/sbin/slurmd -Z -Dvvv
fi

if [ "$1" = "login" ]
then
    
    mkdir -p /home/rocky/.ssh
    cp tempmounts/authorized_keys /home/rocky/.ssh/authorized_keys

    echo "---> Setting permissions for user home directories"
    cd /home
    for DIR in */;
    do USER_TO_SET=$( echo $DIR | sed "s/.$//" ) && (chown -R $USER_TO_SET:$USER_TO_SET $USER_TO_SET || echo "Failed to take ownership of $USER_TO_SET") \
     && (chmod 700 /home/$USER_TO_SET/.ssh || echo "Couldn't set permissions for .ssh directory for $USER_TO_SET") \
     && (chmod 600 /home/$USER_TO_SET/.ssh/authorized_keys || echo "Couldn't set permissions for .ssh/authorized_keys for $USER_TO_SET");
    done
    echo "---> Complete"
    echo "Starting sshd"
    ssh-keygen -A
    /usr/sbin/sshd

    echo "---> Starting the MUNGE Authentication service (munged) ..."
    gosu munge /usr/sbin/munged -F
    echo "---> MUNGE Complete"
fi

if [ "$1" = "check-queue-hook" ]
then
    echo "---> Starting the MUNGE Authentication service (munged) ..."
    gosu munge /usr/sbin/munged
    echo "---> MUNGE Complete"

    RUNNING_JOBS=$(squeue --states=RUNNING,COMPLETING,CONFIGURING,RESIZING,SIGNALING,STAGE_OUT,STOPPED,SUSPENDED --noheader --array | wc --lines)

    if [[ $RUNNING_JOBS -eq 0 ]]
    then
            echo "No Slurm jobs in queue, can safely upgrade"
            exit 0
    else
            echo "Error: cannot upgrade chart - there are still Slurm jobs in the queue"
            exit 1
    fi
fi

if [ "$1" = "update-nodes-hook" ]
then
    
    echo "---> Starting the MUNGE Authentication service (munged) ..."
    gosu munge /usr/sbin/munged
    echo "---> MUNGE Complete"
    
    NODE_LIST=( $(sinfo --format=%n --noheader) )

    for VAR in ${NODE_LIST[@]}
    do
    NODE_DATA=( $(scontrol show node $VAR | grep NodeAddr) )
    export ${NODE_DATA[0]} #NodeAddr=...

    CURRENT_NODE_ADDR=$(cat /home/slurm/nodes/$VAR)

    if [ "$NodeAddr" = "$CURRENT_NODE_ADDR" ]; then
        echo "Addresses match"
    else
        echo "Address mismatch: "
        echo "OLD: $NodeAddr"
        echo "NEW: $CURRENT_NODE_ADDR"
        scontrol update NodeName="$VAR" State=DOWN Reason="Updating node IP"
        scontrol update NodeName="$VAR" NodeAddr=$CURRENT_NODE_ADDR
        scontrol update NodeName="$VAR" State=RESUME
    fi
    done
fi

exec "$@"
