#!/bin/sh

BUSYBOX=busybox-1.20.2
TOR=tor-0.2.3.25
NTPD=openntpd-3.9p1
OPENSSH=openssh-6.1p1

KVERSION=3.6.7
LINUX=linux-3.6.7
PATCHES=hardened-patches-3.6.7-1.extras

################################################################################

set_start()
{
	[ "x$CLEAN" = "xyes" ] && rm -rf release
	[ "x$DEBUG" = "x" ] && unset DEBUG
}

################################################################################

set_target()
{
	[ "x$TARGET" = "x" ] && TARGET="x86"
	[ "x$TARGET" != "xx86" -a "x$TARGET" != "xx86_64" ] && echo "Unknown ARCH" && exit
}

################################################################################

set_release()
{
	[ "x$RELEASE" = "x" ] && RELEASE="testing"
}

################################################################################

start_build()
{
	mkdir -p release
	cd release
	WORKING=$(pwd)
}

################################################################################

get_configs()
{
	cd $WORKING/..
	mkdir -p configs
	cd configs

	if [ "x$DEBUG" = "xyes" ] ; then
		[ ! -f $BUSYBOX.debug.config ] && echo "Missing busybox config" && exit
	else
		[ ! -f $BUSYBOX.config ] && echo "Missing busybox config" && exit
	fi
	[ ! -f setup ] && echo "Missing setup script" && exit
	[ ! -f kernel-$KVERSION.$TARGET.config ] && echo "Missing kernel config" && exit
}

################################################################################

get_sources()
{
	cd $WORKING/..
	mkdir -p sources
	cd sources

	[ ! -f $BUSYBOX.tar.bz2 ] && wget http://www.busybox.net/downloads/$BUSYBOX.tar.bz2
	[ ! -f $TOR.tar.gz ] && wget http://www.torproject.org/dist/$TOR.tar.gz
	[ ! -f $NTPD.tar.gz ] && wget ftp://ftp.openbsd.org/pub/OpenBSD/OpenNTPD/$NTPD.tar.gz
	[ ! -f $LINUX.tar.bz2 ] && wget http://www.kernel.org/pub/linux/kernel/v3.x/$LINUX.tar.bz2
	[ ! -f $PATCHES.tar.bz2 ] && wget http://dev.gentoo.org/~blueness/hardened-sources/hardened-patches/$PATCHES.tar.bz2 
	[ ! -f $OPENSSH.tar.gz ] && wget ftp://ftp.openbsd.org/pub/OpenBSD/OpenSSH/portable/$OPENSSH.tar.gz
}

################################################################################

build_busybox()
{
	cd $WORKING
	[ -f $BUSYBOX/busybox ] && return 0
	tar jxvf $WORKING/../sources/$BUSYBOX.tar.bz2
	cd $BUSYBOX
	for i in $WORKING/../configs/busybox-*.patch; do patch -p 1 < $i ; done
	if [ "x$DEBUG" = "xyes" ] ; then
		cp $WORKING/../configs/$BUSYBOX.debug.config .config
	else
		cp $WORKING/../configs/$BUSYBOX.config .config
	fi
	make
}

################################################################################

build_tor()
{
	cd $WORKING
	[ -f $TOR/src/or/tor ] && return 0
	tar zxvf $WORKING/../sources/$TOR.tar.gz
	cd $TOR
	for i in $WORKING/../configs/tor-*.patch; do patch -p 1 < $i ; done
	./configure --prefix= --enable-gcc-hardening --enable-linker-hardening
	make
	strip src/or/tor
}

################################################################################

build_ntpd()
{
	cd $WORKING
	[ -f $NTPD/ntpd ] && return 0
	tar zxvf $WORKING/../sources/$NTPD.tar.gz
	cd $NTPD
	sed -i '/NTPD_USER/s:_ntp:ntp:' ntpd.h
	./configure --with-privsep-user=ntp --prefix=
	make
	strip ntpd
}

################################################################################

build_scp()
{
	cd $WORKING
	[ -f $OPENSSH/ssh -a -f $OPENSSH/scp ] && return 0
	tar zxvf $WORKING/../sources/$OPENSSH.tar.gz
	cd $OPENSSH
	./configure --prefix=
	make
	strip ssh
	strip scp
}

################################################################################

prepare_initramfs()
{
	cd $WORKING
	rm -rf initramfs
	mkdir initramfs
	cd $WORKING/initramfs
	mkdir -p bin dev etc/tor lib proc tmp usr var/empty var/tor/keys
	chmod 1777 tmp
	chown -R 500:500 var/tor
	chmod -R 700 var/tor
	ln -s bin sbin
	ln -s ../bin usr/bin
	ln -s ../bin usr/sbin
	ln -s ../lib usr/lib
}

################################################################################

populate_bin()
{
	cd $WORKING/initramfs/bin
	cp $WORKING/$BUSYBOX/busybox .
	cp $WORKING/$TOR/src/or/tor .
	cp $WORKING/$NTPD/ntpd .
	cp $WORKING/$OPENSSH/ssh .
	cp $WORKING/$OPENSSH/scp .
	cp $WORKING/../configs/setup .
	chmod 755 setup
}

################################################################################

populate_lib()
{
	cd $WORKING/initramfs/lib
	for i in $(ldd ../bin/busybox | awk '{print $3}') ; do cp -f $i . ; done
	for i in $(ldd ../bin/ntpd | awk '{print $3}') ; do cp -f $i . ; done
	for i in $(ldd ../bin/ssh | awk '{print $3}') ; do cp -f $i . ; done
	for i in $(ldd ../bin/tor | awk '{print $3}') ; do cp -f $i . ; done

	cd $WORKING/initramfs
	ln -s bin/busybox init
	chroot . /bin/busybox --install -s
}

################################################################################

populate_etc()
{
cd $WORKING/initramfs/etc

cat << EOF > fstab
/dev/ram0     /           ext2    defaults   0 0
none          /proc       proc    defaults   0 0
EOF

if [ "x$DEBUG" = "xyes" ] ; then
cat << EOF > inittab
::sysinit:/etc/rcS
tty1::respawn:/bin/setup
tty2::respawn:/bin/nmeter '%79c'
tty3::respawn:/bin/ntpd -s -d
tty4::askfirst:-/bin/sh
tty5::askfirst:-/bin/sh
tty6::askfirst:-/bin/sh
EOF
else
cat << EOF > inittab
::sysinit:/etc/rcS
tty1::respawn:/bin/setup
tty2::respawn:/bin/nmeter '%79c'
tty3::respawn:/bin/ntpd -s -d
EOF
fi

cat << EOF > rcS
#!/bin/sh
/bin/mount -t proc proc /proc
/bin/mount -o remount,rw /dev/ram0 /
/sbin/ifconfig lo 127.0.0.1
EOF

chmod 755 rcS

cat << EOF > udhcpc
#!/bin/sh

/sbin/ifconfig \$interface \$ip

for i in \$router ; do
	/sbin/route add default gw \$i dev \$interface
done

for i in \$dns ; do
	echo "nameserver \$i" >> /etc/resolv.conf
done
EOF

chmod 755 udhcpc

cat << EOF > udhcpc.nodns
#!/bin/sh

/sbin/ifconfig \$interface \$ip

for i in \$router ; do
	/sbin/route add default gw \$i dev \$interface
done
EOF

chmod 755 udhcpc.nodns

cat << EOF > resolv.conf
nameserver 127.0.0.1
EOF

cat << EOF > ntpd.conf
servers pool.ntp.org
EOF

cat << EOF > services
ntp 123/tcp
ntp 123/udp
EOF

cat << EOF > protocols
ip   0  
icmp 1  
tcp  6  
udp  17 
EOF

cat << EOF > group
root:x:0:
tor:x:500:
ntp:x:501:
EOF

cat << EOF > gshadow
root:*::
tor:*::
ntp:*::
EOF

cat << EOF > passwd
root:x:0:0:,,,:/:/bin/sh
tor:x:500:500:,,,:/var/empty:
ntp:x:501:501:,,,:/var/empty:
EOF

cat << EOF > shadow
root:*:14000:0:99999:7::
tor:*:14000:0:99999:7::
ntp:*:14000:0:99999:7::
EOF
}

################################################################################

populate_dev()
{
	cd $WORKING/initramfs/dev

	mkdir shm ; chmod 1777 shm

	mkfifo initctl ; chmod 600 initctl

	mknod -m 660     mem c 1  1
	mknod -m 660    kmem c 1  2
	mknod -m 666    null c 1  3
	mknod -m 660    port c 1  4
	mknod -m 666    zero c 1  5
	mknod -m 666    full c 1  7
	mknod -m 666  random c 1  8
	mknod -m 666 urandom c 1  9
	mknod -m 660    kmsg c 1 11

	mknod -m 666     tty c 5 0
	mknod -m 666 console c 5 1

	for i in $(seq 0 31) ; do mknod -m 660 tty$i c 4 $i ; done

	for i in $(seq 0 7) ; do mknod -m 660 ram$i b 1 $i ; done

	ln -s /proc/self/fd fd
	ln -s fd/0 stdin
	ln -s fd/1 stdout
	ln -s fd/2 stderr
}

################################################################################

finish_initramfs()
{
	cd $WORKING/initramfs
	find . | cpio -H newc -o | gzip -9 > ../initramfs.igz
}

################################################################################

compile_kernel()
{
	cd $WORKING
	[ -f $LINUX/arch/$TARGET/boot/bzImage ] && return 0
	tar jxvf $WORKING/../sources/$LINUX.tar.bz2
	tar jxvf $WORKING/../sources/$PATCHES.tar.bz2 
	cd $LINUX
	for i in ../$KVERSION/4* ; do patch -p 1 < $i ; done 
	for i in $WORKING/../configs/kernel-*.patch; do patch -p 1 < $i ; done

	cd $WORKING/$LINUX
	cp $WORKING/../configs/kernel-$KVERSION.$TARGET.config .config
	ARCH=$TARGET make
}

################################################################################

make_iso()
{
	cd $WORKING
	mkdir -p iso.tor/boot/grub
	cp /lib/grub/i386-pc/stage2_eltorito iso.tor/boot/grub/
	cp $WORKING/initramfs.igz iso.tor/boot
	cp $WORKING/$LINUX/arch/$TARGET/boot/bzImage iso.tor/boot/kernel.tor 

	cd $WORKING
cat << EOF > iso.tor/boot/grub/menu.lst
hiddenmenu
timeout 0
title tor-ramdisk
kernel /boot/kernel.tor root=/dev/ram0
initrd /boot/initramfs.igz
EOF

	mkisofs -R -b boot/grub/stage2_eltorito -no-emul-boot -boot-load-size 4 -boot-info-table -o tor.iso iso.tor

	if [ "x$DEBUG" = "xyes" ] ; then
		mv tor.iso tor.uclibc.$TARGET.debug.$RELEASE.iso
		md5sum tor.uclibc.$TARGET.debug.$RELEASE.iso > tor.uclibc.$TARGET.debug.$RELEASE.iso.md5
	else
		mv tor.iso tor.uclibc.$TARGET.$RELEASE.iso
		md5sum tor.uclibc.$TARGET.$RELEASE.iso > tor.uclibc.$TARGET.$RELEASE.iso.md5
	fi
}

################################################################################

set_start
set_target
set_release
start_build
get_configs
get_sources
build_busybox
build_tor
build_ntpd
build_scp
prepare_initramfs
populate_bin
populate_lib
populate_etc
populate_dev
finish_initramfs
compile_kernel
make_iso
