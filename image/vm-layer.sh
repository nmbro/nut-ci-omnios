#!/bin/sh
# Runs inside the OmniOS VM as root (layer.sh pipes it in):
#   sh -s install <adduser:true|false> <FMRI>...
#     install the pinned packages, write /var/tmp/layer/{pkgs,files}.txt
#   sh -s seal
#     make the disk ready to close as a layer: lists and package downloads
#     gone, no package history, cloud-init reset, freed blocks TRIMmed
set -e
out=/var/tmp/layer
if [ "$1" = seal ]; then
    rm -rf "$out" /var/pkg/publisher/*/file/*
    pkg purge-history >/dev/null
    # per-machine identity and the DHCP lease: made anew by each clone
    rm -f /var/lib/dbus/machine-id /etc/dhcp/*.dhc
    cloud-init clean --logs >/dev/null 2>&1 || true
    sync
    zpool trim rpool
    while ! zpool status -t rpool | grep -q 'trimmed, completed'; do sleep 2; done
    echo "vm-layer: rpool alloc $(zpool list -H -o alloc rpool)"
    exit 0
fi
[ "$1" = install ] || { echo "vm-layer: unknown command '$1'" >&2; exit 2; }
adduser=$2; shift 2
rm -rf "$out"; mkdir -p "$out"
t0=$(date +%s)
# exit 4: nothing to do (already installed)
pkg install -q --accept "$@" || [ $? = 4 ]
if [ "$adduser" = true ]; then
    # NUT CI builds as an unprivileged user, like the farm's agents
    mkdir -p /export/home
    id abuild >/dev/null 2>&1 || useradd -m -d /export/home/abuild -s /bin/bash abuild
fi
echo "vm-layer: install took $(( $(date +%s) - t0 )) s"

pkg list -Hv | awk '{print $1}' | sort > "$out/pkgs.txt"

# cloud-init's default user (with our build key) is made per instance: each
# clone gets its own, so none goes into the image
if getent passwd omnios >/dev/null; then userdel omnios; fi
# its home is a ZFS dataset of its own (/home is autofs)
if zfs list -H rpool/home/omnios >/dev/null 2>&1; then zfs destroy -r rpool/home/omnios; fi
rm -f /etc/sudoers.d/90-cloud-init-users /etc/user_attr.d/cloud-init-users

# Every regular file with mode, owner and content hash, so two builds from
# the same pins can be compared. Skipped: paths that change on every boot by
# design (logs, package and service state, host keys, boot archive and its
# index, DHCP lease, machine-id, and shadow/oshadow, whose "last changed"
# field is the build day). Normalised ("n:" hash): files whose only
# varying part is a "created/changed on <date>" comment line.
perl -MFile::Find -MDigest::SHA -e '
    my $skip = qr{^/(?:proc|system|dev|devices|tmp|var/tmp|var/run|etc/svc/volatile
        |var/(?:pkg|log|adm|svc/log|fm|cron|sadm|saf|lib/cloud|lib/dbus/machine-id|mail|spool|crash)
        |etc/ssh/ssh_host_|etc/svc/repository|etc/saf/zsmon/_pid|etc/dhcp/|root/\.)
        |^/platform/.*/boot_archive|^/boot/solaris/filestat\.ramdisk
        |^/etc/(?:mnttab|zfs/zpool\.cache|o?shadow|nodename|path_to_inst
        |devices/|dev/|dladm/|ipadm/|inet/hosts|resolv\.conf|hostname\.)}x;
    my $norm = qr{^/(?:etc/user_attr|etc/ouser_attr|usr/sadm/defadduser)$};
    my $stamp = qr{^#.*(?:Created by cloud-init v\.|Default values for useradd\.).*\d{4}};
    my @rows;
    for my $root (map { chomp; $_ } `zfs list -H -o mountpoint -t filesystem | grep "^/"`) {
        my $dev = (lstat $root)[0];
        find({ no_chdir => 1, wanted => sub {
            my $p = $File::Find::name;
            my @s = lstat($p);
            # one pass per dataset: do not walk into the ones mounted below
            if ($s[0] != $dev || $p =~ $skip) { $File::Find::prune = 1 if -d _; return; }
            return unless -f _;
            my $h;
            if ($p =~ $norm && open(my $f, "<", $p)) {
                my $d = Digest::SHA->new(256);
                while (<$f>) { $d->add($_) unless /$stamp/ }
                $h = "n:" . $d->hexdigest;
            } else {
                $h = eval { Digest::SHA->new(256)->addfile($p, "b")->hexdigest } // "unreadable";
            }
            push @rows, sprintf("%s %04o %d %d %s", $h, $s[2] & 07777, $s[4], $s[5], $p);
        } }, $root);
    }
    print "$_\n" for sort { (split " ", $a)[-1] cmp (split " ", $b)[-1] } @rows;
' > "$out/files.txt"
echo "vm-layer: $(wc -l < "$out/pkgs.txt") packages, $(wc -l < "$out/files.txt") files listed"
