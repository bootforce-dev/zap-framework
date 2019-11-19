DIR ?= $(CURDIR)

OLD ?= $(DIR)/zap-dev.x86_64.ova
NEW ?= $(DIR)/zap-dev.x86_64.ova

TMP ?= $(DIR)/tmp

STAMPDIR = $(TMP)/stamp
BUILDDIR = $(TMP)/build
CACHEDIR = $(TMP)/cache

VPATH = $(STAMPDIR)

export _ZAP_TRACE ?= $(if $(ZAP_DEBUG),-x,+x)
export _ZAP_FLAGS ?= set $(_ZAP_TRACE) -euo pipefail

export _ZAP_FILES = /var/lib/zap

_BLOCK_DEV ?= $(shell cat "$(STAMPDIR)/block" 2>/dev/null)
_BLOCK_DEV_ = $(subst /dev,/dev/mapper,$(_BLOCK_DEV))
_LVM_GROUP ?= $(shell cat "$(STAMPDIR)/group" 2>/dev/null)
_LVM_GROUP_ = $(subst -,--,$(_LVM_GROUP))

.PHONY: dirty build clean umount brief shell alive_ prune_

build:

ready:
	mkdir -p "$(STAMPDIR)/"
	mkdir -p "$(CACHEDIR)/"
	mkdir -p "$(BUILDDIR)/"
	touch "$(STAMPDIR)/ready"

split: ready
	$(MAKE) umount
	rm -f "$(STAMPDIR)/group"
	mkdir -p "$(BUILDDIR)/ova"
	ovftool --overwrite "$(OLD)" "$(BUILDDIR)/ova/latest.ovf"
	qemu-img convert -p -O raw "$(BUILDDIR)/ova/latest-disk1.vmdk" "$(BUILDDIR)/ova/latest-disk1.disk"
	touch "$(STAMPDIR)/split"

block: split
	losetup --find --show "$(BUILDDIR)/ova/latest-disk1.disk" | tee "$(STAMPDIR)/block"

parts: block
	kpartx -av "$(_BLOCK_DEV)"
	touch "$(STAMPDIR)/parts"
	vgscan --cache || vgscan

group: _LVM_GROUP = $(if $(LVM_GROUP),$(LVM_GROUP),$(shell LVM_SUPPRESS_FD_WARNINGS=1 pvs "$(_BLOCK_DEV_)p2" --noheadings -o vg_name | xargs))
group: _LVM_EXACT = $(LVM_EXACT)
group: parts
	test "$(_LVM_GROUP)" == "$$(pvs "$(_BLOCK_DEV_)p2" --noheadings -o vg_name | xargs)" || \
		vgrename "$$(pvs "$(_BLOCK_DEV_)p2" --noheadings -o vg_uuid | xargs)" "$(_LVM_GROUP)"
	test "$(_LVM_GROUP)" == "$$(pvs "$(_BLOCK_DEV_)p2" --noheadings -o vg_name | xargs)" && vgs "$(_LVM_GROUP)" &>/dev/null || \
		( test -z "$(_LVM_EXACT)" && vgimportclone -n "$(_LVM_GROUP)" "$(_BLOCK_DEV_)p2" )
	pvs "$(_BLOCK_DEV_)p2" --noheadings -o vg_name | xargs | tee "$(STAMPDIR)/group"
	diff "$(STAMPDIR)/group" "$(STAMPDIR)/alive" >/dev/null || rm -f "$(STAMPDIR)/alive"

brief:
	@echo 'losetup:'; losetup -a; echo
	@echo 'pvs:'; pvs; echo
	@echo 'vgs:'; vgs; echo
	@echo 'lvs:'; lvs; echo

mount: group
	vgchange -ay "$(_LVM_GROUP)"
	mkdir -p "$(BUILDDIR)/mnt"
	mount "/dev/mapper/$(_LVM_GROUP_)-root" "$(BUILDDIR)/mnt"
	# custom mounts
	mount "/dev/mapper/$(_LVM_GROUP_)-home" "$(BUILDDIR)/mnt/home"
	mount "/dev/mapper/$(_LVM_GROUP_)-usr" "$(BUILDDIR)/mnt/usr"
	mount "/dev/mapper/$(_LVM_GROUP_)-tmp" "$(BUILDDIR)/mnt/tmp"
	mount "/dev/mapper/$(_LVM_GROUP_)-var" "$(BUILDDIR)/mnt/var"
	mount "/dev/mapper/$(_LVM_GROUP_)-var_log" "$(BUILDDIR)/mnt/var/log"
	mount "/dev/mapper/$(_LVM_GROUP_)-var_log_audit" "$(BUILDDIR)/mnt/var/log/audit"
	mount "$(_BLOCK_DEV_)p1" "$(BUILDDIR)/mnt/boot"
	mount -t devtmpfs dev "$(BUILDDIR)/mnt/dev"
	mount -t proc proc "$(BUILDDIR)/mnt/proc"
	mount -t sysfs syc "$(BUILDDIR)/mnt/sys"
	mkdir -p "$(BUILDDIR)/mnt/usr/lib/zap/"
	mkdir -p "$(BUILDDIR)/mnt/var/lib/zap/"
	mount --bind "$(CACHEDIR)" "$(BUILDDIR)/mnt/var/lib/zap"
	mount --bind "$(CURDIR)/zap" "$(BUILDDIR)/mnt/usr/lib/zap"
	touch "$(STAMPDIR)/mount"

alive_: group
	$(MAKE) mount
	$(MAKE) dirty
	chroot "$(BUILDDIR)/mnt" yum install -y epel-release
	chroot "$(BUILDDIR)/mnt" yum install -y pigz
	chroot "$(BUILDDIR)/mnt" package-cleanup -y --oldkernels
	chroot "$(BUILDDIR)/mnt" sed -i "s?^/dev/mapper/[[:alnum:]]*-?/dev/mapper/$(_LVM_GROUP_)-?g" /etc/fstab
	chroot "$(BUILDDIR)/mnt" sed -i "/^GRUB_CMDLINE_LINUX=/ s?/dev/mapper/[[:alnum:]]*-?/dev/mapper/$(_LVM_GROUP_)-?g" /etc/default/grub
	chroot "$(BUILDDIR)/mnt" sed -i "/^GRUB_CMDLINE_LINUX=/ s?\<rd\.lvm\>[^[:space:]\"\']*??g" /etc/default/grub
	chroot "$(BUILDDIR)/mnt" grub2-mkconfig -o '/boot/grub2/grub.cfg'
	chroot "$(BUILDDIR)/mnt" sed -i 's/linuxefi/linux16/g; s/initrdefi/initrd16/g;' /boot/grub2/grub.cfg
	chroot "$(BUILDDIR)/mnt" dracut --force --regenerate-all --no-hostonly
	cp "$(STAMPDIR)/group" "$(STAMPDIR)/alive"

alive:
	$(MAKE) alive_

prune_: group
	$(MAKE) mount
	$(MAKE) dirty
	findmnt -clno source -R "$(BUILDDIR)/mnt" | \
		grep -e "^/dev/mapper/$(_LVM_GROUP_)-\<" -e "^$(_BLOCK_DEV_)p[[:digit:]]*" | \
		xargs -rn1 findmnt -clno target | grep "^$(BUILDDIR)/mnt" | \
		xargs -rn1 fstrim -v
	touch "$(STAMPDIR)/prune"

prune:
	$(MAKE) prune_

umount:
	findmnt -clno target -R "$(BUILDDIR)/mnt" | tac | xargs -rn1 umount
	find "$(BUILDDIR)/mnt" -maxdepth 0 | xargs -r rmdir
	vgchange -an "$(_LVM_GROUP)" || :
	rm -f "$(STAMPDIR)/mount"
	kpartx -dv "$(_BLOCK_DEV)" || :
	vgscan --cache || vgscan
	rm -f "$(STAMPDIR)/parts"
	losetup --detach "$(_BLOCK_DEV)" || :
	rm -f "$(STAMPDIR)/block"

fetch: ready
	rm -rf "$(CACHEDIR)"/*
	for stage in `ls -1 "$(CURDIR)/zap"`; do \
		mkdir -p "$(CACHEDIR)/$$stage"; \
		cd "$(CACHEDIR)/$$stage"; \
		_ZAP_STAGE=$$stage "$(CURDIR)/zap/$$stage/fetch"; \
	done
	touch "$(STAMPDIR)/fetch"

shell: split
	$(MAKE) mount
	$(MAKE) dirty
	chroot "$(BUILDDIR)/mnt"

stage: fetch split
	$(MAKE) mount
	$(MAKE) dirty
	for stage in `chroot "$(BUILDDIR)/mnt/" ls -1 "/usr/lib/zap"`; do \
		_ZAP_STAGE=$$stage chroot "$(BUILDDIR)/mnt" "/usr/lib/zap/$$stage/stage"; \
	done
	touch "$(STAMPDIR)/stage"

build:
	$(MAKE) stage
	$(MAKE) alive
	$(MAKE) prune
	$(MAKE) image

dirty:
	rm -f "$(STAMPDIR)/prune"
	rm -f "$(STAMPDIR)/image"

image: split
	$(MAKE) umount
	qemu-img convert -p -O vmdk -o compat6 "$(BUILDDIR)/ova/latest-disk1.disk" "$(BUILDDIR)/ova/latest-disk1.vmdk"
	ovftool --schemaValidate "$(BUILDDIR)/ova/latest.ovf"
	ovftool --overwrite --shaAlgorithm=SHA1 --skipManifestCheck "$(BUILDDIR)/ova/latest.ovf" "$(NEW)"
	mkdir -p "$(BUILDDIR)/vmx"
	ovftool --overwrite --acceptAllEulas "$(NEW)" "$(BUILDDIR)/vmx/system.vmx"
	rm -rf "$(BUILDDIR)/vmx"
	chmod a+r "$(NEW)"
	touch "$(STAMPDIR)/image"

clean:
	$(MAKE) umount
	rm -rf "$(BUILDDIR)" "$(STAMPDIR)" "$(CACHEDIR)" "$(NEW)" "$(DIR)/tmp"
