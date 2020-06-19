# kvm-backup
Perform efficient live disk backups using "active blockcommit"

Script requires an updated QEMU package from the CentOS Virt repository:

```
[virt-kvm-common]
name=CentOS-$releasever - Virt kvm-common
baseurl=http://mirror.centos.org/centos/7/virt/x86_64/kvm-common/
enabled=1
gpgcheck=0
```

Installation:
```
$ sudo yum clean all && sudo yum repolist
$ sudo yum update qemu-kvm-ev qemu-img-ev
```

More info about live snapshots:

https://wiki.libvirt.org/page/Live-disk-backup-with-active-blockcommit
