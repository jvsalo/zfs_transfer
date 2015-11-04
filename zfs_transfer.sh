#!/bin/bash

# The MIT License (MIT)

# Copyright (c) 2014-2015 Jaakko Salo

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# Mandatory options:
# --remote-host <host> - remote host
# --remote-fs <fs> - filesystem on remote host
# --local-fs <fs> - filesystem on local host
# --tag <tag> - ZFS hold tag
# --keep-days <days> - preserved history length
#
# Optional options:
# --mbuffer <bufsz> - mbuffer buffer size, default 4G
# --port <port> - custom SSH port, default 22
# --no-pigz - disable pigz

# Snapshot part of snapshot name
snapof() {
    echo $1 | cut -d'@' -f 2
}

# Dataset part of snapshot name
datasetof() {
    echo $1 | cut -d'@' -f 1
}

# Script begins here

sopts="h:r:l:k:b:p:t:n"
lopts="remote-host:,remote-fs:,local-fs:,keep-days:,mbuffer:,port:,tag:,no-pigz"

if ! options=$(getopt -o $sopts -l $lopts -- "$@") ; then
    echo "Invalid options."
    exit 1
fi

while [ $# -gt 0 ]
do
    case $1 in
    --remote-host | -h) remote_host="$2"; shift;;
    --remote-fs | -r) remote_fs="$2"; shift;;
    --local-fs | -l) local_fs="$2"; shift;;
    --keep-days | -k) keep_days="$2"; shift;;
    --mbuffer | -b) bufsz="$2"; shift;;
    --port | -p) port="$2"; shift;;
    --tag | -t) tag="$2"; shift;;
    --no-pigz | -n) pigz="cat"; gunzip="cat" ;;
    (-*) echo "$0: error - unrecognized option $1" 1>&2; exit 1;;
    (*) break;;
    esac
    shift
done

if [ -z "$remote_host" ] || [ -z "$remote_fs" ] || [ -z "$local_fs" ]\
    || [ -z "$keep_days" ] || [ -z "$tag" ] ; then
    echo "Mandatory option missing."
    exit 1
fi

# Defaults if no parameter given
[ -n "$port" ] || port=22
[ -n "$bufsz" ] || bufsz="4G"
[ -n "$pigz" ] || pigz="pigz"
[ -n "$gunzip" ] || gunzip="gunzip"

ssh="ssh -n -x -p${port} -o Compression=no -c arcfour ${remote_host}"
mbuffer="mbuffer -q -m ${bufsz}"
keep_secs="$(($keep_days * 24*60*60))"

# Disable SSH if operating locally
if [ "$remote_host" = "localhost" ] ; then
        echo "Skipping SSH, --remote-host is localhost."
        ssh="bash -c"
fi

# Generate lockfile based on target dataset name
lockf=/var/lock/zfs_replicate_$(echo "$remote_host" "$remote_fs" | md5sum | \
    cut -d' ' -f 1) || exit 1

(
    if ! flock -n -x 9; then
        exit 0
    fi

    # Get remote snapshots, extract most recent snapshot
    remote_list=$($ssh "zfs list -H -r -d 1 -t snapshot -o name \
        -s creation \"$remote_fs\"")

    if [ $? -ne "0" ] || [ -z "$remote_list" ]; then
        echo "Unable to get remote snapshots."
        exit 1
    fi

    remote_tip=$(echo "$remote_list" | tail -n 1)

    # Get local snapshots, if available
    local_list=$(zfs list -H -r -d 1 -t snapshot -o name -s creation \
        "$local_fs")

    # Receive full stream or incremental?
    if [ $? -ne 0 ] || [ -z "$local_list" ] ; then
        echo "Can't get local snapshots. Attempting initial send+receive..."

        # Create subdatasets if needed, then send+receive full stream
        zfs create -p "$local_fs" || \
            { echo "Can't create local filesystem."; exit 1; }

        $ssh "zfs send -R \"$remote_tip\" | $pigz" | $mbuffer | $gunzip | \
            zfs receive -F -u "$local_fs" || \
            { echo "send/receive failed. Unable to continue."; exit 1; }

        # Put the remote tip on hold after successful receive. If this fails,
        # you should retry after creating new snapshot(s) on the remote site.
        # Alternatively, you should destroy the recently received snapshot on
        # local site, that does not have a hold on the remote server. Otherwise,
        # you risk snapshot tip expiring on remote site.

        $ssh "zfs hold -r $tag \"$remote_tip\"" || \
            { echo "*** WARNING! *** Couldn't hold remote snapshot. Please" \
                "re-run to fix this."; exit 1; }

        exit 0
    else
        # Local latest snapshot and corresponding snapshot on remote site.
        local_tip=$(echo "$local_list" | tail -n 1)
        remote_source="$(datasetof "$remote_tip")@$(snapof "$local_tip")"

        # No new snapshots?
        [ "$(snapof "$local_tip")" == "$(snapof "$remote_tip")" ] && exit 0

        # Send+receive incremental, put remote tip on hold.
        if ! $ssh "zfs send -R -i \"$remote_source\" \"$remote_tip\" | $pigz" |\
            $mbuffer | $gunzip | zfs receive -u "$local_fs" ; then
            echo "send/receive failed. Destroying partially received data (in" \
                 "case children got updated) and exiting. Most errors below" \
                 "are OK.";

            zfs list -r -H -o name "$local_fs" | while read dataset ; do
                zfs rollback -r "${dataset}@$(snapof "$local_tip")"
            done
            exit 1
        fi

        # Above comment about the warning applies here too.
        $ssh "zfs hold -r $tag \"$remote_tip\"" || \
            { echo "*** WARNING! *** Couldn't hold remote snapshot. Please" \
                "re-run to fix this."; exit 1; }

        # Drop the hold from previous snapshot. If connectivity fails here, it
        # will still be destroyed before the local snapshot is destroyed
        # (next loop).
        $ssh "zfs release -r $tag \"$remote_source\""

        # Destroy expired snapshots from local site after ensuring there is no
        # hold on the remote server.
        now=$(date '+%s')

        echo "$local_list" | while read snap; do
            remote_snap="$(datasetof "$remote_tip")@$(snapof "$snap")"

            # If snapshot creation time is not old enough, do nothing.
            creation=$(zfs get -Hp -o value creation "$snap")
            [ $? -ne 0 ] || [ -z "$creation" ] && break
            [ "$(($now - $creation))" -gt $keep_secs ] || break

            # If snap should be destroyed, make sure there is no hold on
            # remote site. First test if the snapshot exists at all. Note that
            # ssh might fail, but that must not be interpreted as
            # "snapshot doesn't exist on remote site"!

            res=$($ssh \
                "zfs list \"$remote_snap\" >/dev/null 2>&1 && echo Y || echo N"\
                ) || break

            if [ "$res" == "Y" ] ; then
                $ssh "zfs release -r $tag \"$remote_snap\"" >/dev/null 2>&1
                holds="$($ssh "zfs holds -H \"$remote_snap\"")" || continue
                echo "$holds" | awk '{print $2}' | grep "^${tag}\$" \
                    > /dev/null && continue
            fi

            # Now the snapshot is 1. expired and 2. not held on remote host
            zfs destroy -r "$snap"
        done
    fi
) 9>$lockf
