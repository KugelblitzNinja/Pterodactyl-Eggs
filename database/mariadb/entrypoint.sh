#!/bin/bash

# Check if in Docker container; exit if not
cd /home/container || exit

# Set internal Docker IP address
export INTERNAL_IP=$(ip route get 1 | awk '{print $(NF-2);exit}')
echo "INTERNAL_IP: ${INTERNAL_IP}"

#Variables set in into the panal egg verables 
#   RESTIC_START_DELAY
#   RESTIC_LOOP_COOLDOWN
#   RESTIC_PASSWORD
#   RESTIC_REST_USERNAME
#   RESTIC_REST_PASSWORD
#   RESTIC_REST_URL

# Variables
KEEP_ALL_WITHIN="1d"
KEEP_WITHIN_HOURLY="7d"
KEEP_WITHIN_DAILY="1m"
KEEP_WITHIN_WEEKLY="1y"
KEEP_WITHIN_MONTHLY="10y"
KEEP_WITHIN_YEARLY="100y"
ENABLE_RESTIC=true
ENABLE_RESTIC_FORGET=false
MAIN_PROCESS_NAME="mariadbd"

# Sets the restic save location
export RESTIC_REPOSITORY="rest:https://${RESTIC_REST_URL}/${RESTIC_REST_USERNAME}/${P_SERVER_UUID}/"
export GOMAXPROCS=1
export RESTIC_PACK_SIZE=64

# Replace Startup Variables
MODIFIED_STARTUP=$(echo "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')
echo ":/home/container$ ${MODIFIED_STARTUP}"

# Function to check if main prosses is running, this gets call by backgrond tasks to see if they need to stop
mainProcessExists() {
    if pgrep "${MAIN_PROCESS_NAME}" >/dev/null; then
        return 0  # mariadbd process is running
    else
        return 1  # mariadbd process is not running
    fi
}

# Function to run online restic backups
resticOnline() {
    if [[ ${ENABLE_RESTIC} == false ]]; then
        return 0
    fi

    # Wait for the main process to start
    sleep 5


    for i in $(seq ${RESTIC_START_DELAY}); do
        if ! mainProcessExists; then
            return 0
        fi
        sleep 1
    done

    # Create restic repository if missing
    restic snapshots >/dev/null || restic init
    restic unlock
    restic snapshots
    restic cache --cleanup

    
    nice -n 19 ionice -c 3 restic repair index
    nice -n 19 ionice -c 3 restic repair snapshots --forget

    # Remove old backups
    if [[ ${ENABLE_RESTIC_FORGET} == true ]]; then
        restic forget --tag Offline --prune --max-unused unlimited \
            --keep-within ${KEEP_ALL_WITHIN} \
            --keep-within-hourly ${KEEP_WITHIN_HOURLY} \
            --keep-within-daily ${KEEP_WITHIN_DAILY} \
            --keep-within-weekly ${KEEP_WITHIN_WEEKLY} \
            --keep-within-monthly ${KEEP_WITHIN_MONTHLY} \
            --keep-within-yearly ${KEEP_WITHIN_YEARLY}

        restic forget --tag Online --prune --max-unused unlimited \
            --keep-within ${KEEP_ALL_WITHIN} \
            --keep-within-hourly ${KEEP_WITHIN_HOURLY} \
            --keep-within-daily ${KEEP_WITHIN_DAILY} \
            --keep-within-weekly ${KEEP_WITHIN_WEEKLY} \
            --keep-within-monthly ${KEEP_WITHIN_MONTHLY} \
            --keep-within-yearly ${KEEP_WITHIN_YEARLY}
    fi

    #Now its time to do our "online" backups on a loop

    while mainProcessExists; do

        #Just a loop that waits X amout of time before continuing, also keeps ckecking if the Main Process Exists as there is no point in waiting to do the next online backup if there is no Main Process
        for i in $(seq ${RESTIC_LOOP_COOLDOWN}); do
            if ! mainProcessExists; then
                return 0
            fi
            sleep 1
        done

        #This mariadbBackupPrep function is only here because you can not backup a running mariadb server, so we must make a shadow clone of it.
        mariadbBackupPrep

        restic unlock
        ionice -c 3 restic backup /home/container \
            --exclude-if-present nobackup \
            --exclude="/home/container/.mariadb/data" \
            --tag Online
        restic snapshots
    done
}

# Function to prepare MariaDB backup
mariadbBackupPrep() {
    MARIADB_DATA=/home/container/.mariadb

    #If there is no full copy of the mariadb server data then we need to make one
    if ! [ -d "${MARIADB_DATA}/data.bk" ]; then
        echo "[MariaDBBackupPrep] Creating ${MARIADB_DATA}/data.bk for full MySQL backup"
        mkdir "${MARIADB_DATA}/data.bk"
        mariadb-backup \
            --backup \
            --user=root \
            --password="${MARIADB_PASSWORD}" \
            --open_files_limit=65535 \
            --target-dir "${MARIADB_DATA}/data.bk" \
            --log-innodb-page-corruption
        mariadb-backup \
            --prepare \
            --user=root \
            --password="${MARIADB_PASSWORD}" \
            --open_files_limit=65535 \
            --target-dir "${MARIADB_DATA}/data.bk"
    fi

    #We cant use any old copy of incremental backups
    if [ -d "${MARIADB_DATA}/data.ibk" ]; then
        rm -r "${MARIADB_DATA}/data.ibk"
    fi

    ionice -c 3 mariadb-backup \
        --backup \
        --user=root \
        --password="${MARIADB_PASSWORD}" \
        --open_files_limit=65535 \
        --target-dir "${MARIADB_DATA}/data.ibk" \
        --incremental-basedir "${MARIADB_DATA}/data.bk" \
        --log-innodb-page-corruption

    ionice -c 3 mariadb-backup \
        --prepare \
        --user=root \
        --password="${MARIADB_PASSWORD}" \
        --open_files_limit=65535 \
        --target-dir "${MARIADB_DATA}/data.bk"

    ionice -c 3 mariadb-backup \
        --prepare \
        --user=root \
        --password="${MARIADB_PASSWORD}" \
        --open_files_limit=65535 \
        --target-dir "${MARIADB_DATA}/data.bk" \
        --incremental-dir "${MARIADB_DATA}/data.ibk"

    rm -r "${MARIADB_DATA}/data.ibk"
}

# Function to perform offline restic backup
resticOffline() {
    restic unlock

    ionice -c 3 restic backup /home/container \
                    --exclude-if-present nobackup \
                    --exclude="/home/container/.mariadb/data.bk" \
                    --tag offline

    restic snapshots
}

# Main function to execute modified startup
MainFunction() {
    eval "${MODIFIED_STARTUP}"
}

# Start resticOnline in the background, execute our MainFunction, wait or both to exit, then perform resticOffline
resticOnline &
MainFunction
wait
resticOffline
