# zap-framework
Framework to build custom distribution images

## Quick start

### 0. Build environment

Setup clean CentOS7 distribution.

### 1. Install helper tools

```
# yum install qemu-img lvm2 git libnsl mock
```

### 2. Clone scripts

```
$ git clone https://github.com/bootforce-dev/zap-framework
```

### 3. Install VMWare ovftool

Originally found at VMWare web-site (registration required):

    https://www.vmware.com/support/developer/ovf/

```
# yum install ncurses-compat-libs
# sh ./VMware-ovftool-<version>-<build>-lin.x86_64.bundle
```

### 5. Prepare build

Build scripts retrieve `ram-framework` component using `git`.

### 6. Run the build

```
# cd zap-framework && make
```

## Usage

The `makefile` serves for all operations to do over OVA image and its parts.
Following `make` targets are implemented:

`make ready` -- initialize working directories  
`make split` -- break up appliance template  
`make block` -- attach disk image to loop device  
`make parts` -- setup devices for loop partitions
`make group` -- fix up lvm vg name if needed  
`make brief` -- show summary of lvm state  
`make mount` -- mount appliance tree hierarchy  
`make alive` -- fix up fstab and boot-loader  
`make prune` -- trim unused disk image blocks
`make shell` -- chroot to mounted tree hierarchy  
`make fetch` -- fetch external dependencies  
`make stage` -- run customization scripts  
`make image` -- rebuild appliance termplate  
`make build` -- (default) standard workflow  
`make umount` -- release all temporary resources  
`make clean` -- clean up all generated files  

### Workflows

Standard workflow run by `make build` or just `make` is the same as running:

```
# make stage
# make alive
# make prune
# make image
```

It's possible to run only a subset of these actions specifying them in a sequence, i.e.
to fix up boot-loader, prune disk images and rebuild new OVA (without running stage):

```
# make alive
# make prune
# make image
```

It's always a good idea to clean up previous build results before new rebuild with:

```
# make clean
# make
```

### LVM conflicts

LVM prevents multiple VGs with the same functioning on the system.
In case of conflicts between appliance VG and system one,
build scripts will rename appliance VG using `vgimportclone`.
Thus default `centos` VG name could become `centos1` or similar one.

The behavoir could be altered using following environment variables:

`LVM_GROUP` -- defines alternative base name for appliance VG.  
`LVM_EXACT` -- if set non-empty and name conflict arises,
build scripts will stop with an error instead of altering VG name.  

These variables are only take effect during `group` target,
thus following examples will virtually produce same results:


```
# make clean
# LVM_GROUP=zap LVM_EXACT=_ make group
# make
```

```
# make clean
# LVM_GROUP=zap LVM_EXACT=_ make
```

### Building RPMs

Running `make fetch` stage builds RPM package for `ram-framework` out of git repositories.

RPM build stage doesnt require `root` privileges. But non-root user should be a member of `mock` group in this case:

```
# usermod -a -G mock $USER
```

By default RPM specs are patched in order to inject build time stamps into RPM release metadata field.
Thus making built packages version ordered and able to be upgraded on iterative builds.

The behavoir could be altered using following environment variables:

`RPM_STAMP` -- if set empty, build scripts wont patch RPM specs with timestamps.

These variables are only take effect during `fetch` target,
thus following examples will virtually produce same results:

```
# make clean
# RPM_STAMP= make fetch
# make
```

```
# make clean
# RPM_STAMP= make
```

Please note that unpatched RPMs will have precedence (greater version) than patched ones.

In addition builds scripts employ `Vendor` RPM metadata field usually used by build scripts.
The value of this field is fullfiled with git repository path and commithash used for build.
