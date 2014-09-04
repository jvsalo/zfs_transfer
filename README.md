zfs_transfer
============

Maintain a mirror of ZFS pools over the network.

Best used together with https://github.com/zfsonlinux/zfs-auto-snapshot
set up on the remote host. It should be possible to chain multiple ZFS
hosts.

Below is a crontab usage example. Here the various datasets
and snapshots from the host 192.168.1.14 are replicated to our local
ZFS pool, using SSH (-o Compression=no -c arcfour) and caching (mbuffer)
optimizations.

Parent datasets are automatically created before the initial synch,
when you add a dataset.

We use 'zfs hold' to implement locking that prevents destruction of
remote snapshots, that would put the synchronization process in danger.

This allows for laid-back snapshot expiry management on the remote host,
since a lot of force (you need to remove the hold tag) is required to
destroy the latest mutually known snapshot.

The script should be quite tolerant against various failure conditions.
If you can make it better, please do!

In below crontab, the remote pool is called "backuppool", and the local site
is "offsite".

The "Keep days" parameter only destroys local (offsite) snapshots. It
makes sure that a hold is released, if exists, on the remote host before
it goes on to destroy a local snapshot. Failure to do so, would disturb
snapshot expiry on the remote host indefinitely!

```
MAILTO="user@host.com"
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

0 0  1   *   *     zpool scrub offsite

#                                    Hostname            Remote dataset                          Local dataset                          Hold tag       Keep days
# m h  dom mon dow   command         ------------        --------------------------------------- -------------------------------------- -------------- ------------
0 */6 *  *   *     zfs_replicate   -h 192.168.1.14    -r backuppool/virt/machines             -l offsite/virt/machines               -t offsite     -k 30
10 */6 *  *   *     zfs_replicate   -h 192.168.1.14    -r backuppool/backuppc                  -l offsite/backuppc                    -t offsite     -k 30
20 */6 *  *   *     zfs_replicate   -h 192.168.1.14    -r backuppool/timemachine               -l offsite/timemachine                 -t offsite     -k 30
50 */6 *  *   *     zfs_replicate   -h 192.168.1.14    -r backuppool/vdp                       -l offsite/vdp                         -t offsite     -k 30
```
