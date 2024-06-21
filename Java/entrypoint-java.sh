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
#   ENABLE_RESTIC
#   ENABLE_RESTIC_FORGET
#   RESTIC_ONLINE
#   RESTIC_OFFLINE
#   RESTIC_PREP

# Variables
KEEP_ALL_WITHIN="1d"
KEEP_WITHIN_HOURLY="7d"
KEEP_WITHIN_DAILY="1m"
KEEP_WITHIN_WEEKLY="1y"
KEEP_WITHIN_MONTHLY="10y"
KEEP_WITHIN_YEARLY="100y"
MAIN_PROCESS_NAME="java"


# Sets the restic save location
export RESTIC_REPOSITORY="rest:https://${RESTIC_REST_URL}/${RESTIC_REST_USERNAME}/${P_SERVER_UUID}/"
#export GOMAXPROCS=4
export RESTIC_PACK_SIZE=64
export RESTIC_READ_CONCURRENCY=8
# Replace Startup Variables
MODIFIED_STARTUP="ionice -c 2 -n 0 $(echo "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')"
echo ":/home/container$ ${MODIFIED_STARTUP}"

# Function to check if main prosses is running, this gets call by backgrond tasks to see if they need to stop
mainProcessExists() {
    if pgrep "${MAIN_PROCESS_NAME}" >/dev/null; then
        return 0
    else
        return 1
    fi
}

startMainProcess() {
    eval "${MODIFIED_STARTUP}"
    pkill restic
}

startBackupProcess() {
    #Check if we should start the Backup Process
    if [[ ${ENABLE_RESTIC} == false ]]; then
        return 0
    fi

    #Check and prepaire for our restic repostrey
    restic snapshots >/dev/null || restic init
    restic unlock
    restic snapshots
    restic cache --cleanup
    restic repair index


    # Wait for the main process to start
    sleep 5
    #May need to wait for a while before continue to the main part of the backup prosess
    for i in $(seq ${RESTIC_START_DELAY}); do
        #We keep checking if the main prosess has died here, or the script can spend time looping when when it just needs to exit due to death of main prosess
        if ! mainProcessExists; then
            return 0
        fi
        sleep 1
    done

    resticOnline
}

cleanupBackups() {
    # Remove old backups
    if [[ ${ENABLE_RESTIC_FORGET} == true ]]; then
        restic forget --tag Offline \
            --keep-within ${KEEP_ALL_WITHIN} \
            --keep-within-hourly ${KEEP_WITHIN_HOURLY} \
            --keep-within-daily ${KEEP_WITHIN_DAILY} \
            --keep-within-weekly ${KEEP_WITHIN_WEEKLY} \
            --keep-within-monthly ${KEEP_WITHIN_MONTHLY} \
            --keep-within-yearly ${KEEP_WITHIN_YEARLY}

        restic forget --tag Online \
            --keep-within ${KEEP_ALL_WITHIN} \
            --keep-within-hourly ${KEEP_WITHIN_HOURLY} \
            --keep-within-daily ${KEEP_WITHIN_DAILY} \
            --keep-within-weekly ${KEEP_WITHIN_WEEKLY} \
            --keep-within-monthly ${KEEP_WITHIN_MONTHLY} \
            --keep-within-yearly ${KEEP_WITHIN_YEARLY}

        restic prune --no-cache
    fi
}

# Function to run online restic backups
resticOnline() {

    if [[ ${RESTIC_ONLINE} == false ]]; then
        return 0
    fi

    while mainProcessExists; do

        #Just a loop that waits X amout of time before continuing, also keeps ckecking if the Main Process Exists as there is no point in waiting to do the next online backup if there is no Main Process
        for i in $(seq ${RESTIC_LOOP_COOLDOWN}); do
            if ! mainProcessExists; then
                return 0
            fi
            sleep 1
        done

        restic unlock
        ionice -c 3 restic backup /home/container \
            --exclude-if-present nobackup \
            --tag Online
        restic snapshots

        cleanupBackups
    done    
}

# Function to perform offline restic backup
resticOffline() {

    if [[ ${RESTIC_OFFLINE} == false ]]; then
        return 0
    fi

    restic unlock

    ionice -c 2 -n 1 restic backup /home/container \
                    --exclude-if-present nobackup \
                    --tag Offline

    restic snapshots
}

resticPreparations() {
    if [[ ${RESTIC_PREP} == false ]]; then
        return 0
    fi

    #No prep commands are need for a minecraft server
}

# Start resticOnline in the background, execute our MainFunction, wait or both to exit, then perform resticOffline
startBackupProcess &
startMainProcess
wait
resticOffline
