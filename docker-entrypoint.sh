#!/bin/bash
set -euo pipefail

cp /tempmounts/munge.key /etc/munge/munge.key
chown 998:998 /etc/munge/munge.key
chmod 600 /etc/munge/munge.key

if [ "$1" = "slurmdbd" ]
then
    echo "---> Starting the MUNGE Authentication service (munged) ..."
    gosu munge /usr/sbin/munged

    echo "---> Starting the Slurm Database Daemon (slurmdbd) ..."

    cp /tempmounts/slurmdbd.conf /etc/slurm/slurmdbd.conf
    echo "StorageUser=${StorageUser}" >> /etc/slurm/slurmdbd.conf
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

    echo "---> Starting the Slurm Controller Daemon (slurmctld) ..."
    if /usr/sbin/slurmctld -V | grep -q '17.02' ; then
        exec gosu slurm /usr/sbin/slurmctld -Dvvv
    else
        exec gosu slurm /usr/sbin/slurmctld -i -Dvvv
    fi
fi

if [ "$1" = "slurmd" ]
then
    echo "---> Starting the MUNGE Authentication service (munged) ..."
    gosu munge /usr/sbin/munged

    echo "---> Waiting for slurmctld to become active before starting slurmd..."

    until 2>/dev/null >/dev/tcp/slurmctld/6817
    do
        echo "-- slurmctld is not available.  Sleeping ..."
        sleep 2
    done
    echo "-- slurmctld is now active ..."

    echo "---> Starting the Slurm Node Daemon (slurmd) ..."
    exec /usr/sbin/slurmd -Z -Dvvv
fi

if [ "$1" = "login" ]
then
    echo "---> Starting the MUNGE Authentication service (munged) ..."
    gosu munge /usr/sbin/munged
    echo "---> MUNGE Complete"

    echo "---> Setting permissions for user home directories"
    cd /home
    for DIR in */;
    do USER=$( echo $DIR | sed "s/.$//" ) && (chown -R $USER:$USER $USER || echo "Failed to take ownership of $USER") && (chmod 600 /home/$USER/.ssh/authorized_keys || echo "Couldn't set permissions for .ssh keys for $USER");
    done
    echo "---> Complete"
    echo "Starting sshd"
    ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key
    ssh-keygen -t dsa -f /etc/ssh/ssh_host_dsa_key
    ssh-keygen -t ecdsa -f /etc/ssh/ssh_host_ecdsa_key
    /usr/sbin/sshd -D
fi

exec "$@"
