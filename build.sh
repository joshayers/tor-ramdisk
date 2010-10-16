#!/bin/sh

RELEASE=testing
#DEBUG=yes

BUSYBOX=busybox-1.17.2
TOR=tor-0.2.1.26
NTPD=openntpd-3.9p1
DROPBEAR=dropbear-0.52

KVERSION=2.6.32
LINUX=linux-2.6.32.23
PATCHES=hardened-patches-2.6.32-22.extras

################################################################################

clean_start()
{
	rm -rf release
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

	if [ "x$DEBUG" == "xyes" ] ; then
		[ ! -f $BUSYBOX.debug.config ] && wget http://opensource.dyc.edu/pub/tor-ramdisk/archives/scripts.$RELEASE/configs/$BUSYBOX.debug.config
	else
		[ ! -f $BUSYBOX.config ] && wget http://opensource.dyc.edu/pub/tor-ramdisk/archives/scripts.$RELEASE/configs/$BUSYBOX.config
	fi
	[ ! -f setup ] && wget http://opensource.dyc.edu/pub/tor-ramdisk/archives/scripts.$RELEASE/configs/setup
	[ ! -f kernel-$KVERSION.config ] && wget http://opensource.dyc.edu/pub/tor-ramdisk/archives/scripts.$RELEASE/configs/kernel-$KVERSION.config
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
	[ ! -f $LINUX.tar.bz2 ] && wget http://www.kernel.org/pub/linux/kernel/v2.6/$LINUX.tar.bz2
	[ ! -f $PATCHES.tar.bz2 ] && wget http://cheshire.dyc.edu/pub/gentoo/distfiles/$PATCHES.tar.bz2 
	[ ! -f $DROPBEAR.tar.gz ] && wget http://matt.ucc.asn.au/dropbear/$DROPBEAR.tar.gz
}

################################################################################

build_busybox()
{
	cd $WORKING
	[ -f $BUSYBOX/busybox ] && return 0
	tar jxvf $WORKING/../sources/$BUSYBOX.tar.bz2
	cd $BUSYBOX
	if [ "x$DEBUG" == "xyes" ] ; then
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
	./configure --prefix=
	sed -i 's/^CFLAGS =/CFLAGS = -static/' src/or/Makefile
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
	CFLAGS="-static" ./configure --with-privsep-user=ntp --prefix=
	make
	strip ntpd
}

################################################################################

build_dropbear()
{
	cd $WORKING
	[ -f $DROPBEAR/dbclient -a -f $DROPBEAR/scp ] && return 0
	tar zxvf $WORKING/../sources/$DROPBEAR.tar.gz
	cd $DROPBEAR
	./configure --prefix=
	STATIC=1 PROGRAMS="dbclient scp" make
	strip dbclient
	strip scp
}

################################################################################

prepare_initramfs()
{
	cd $WORKING
	rm -rf initramfs
	mkdir initramfs
	cd $WORKING/initramfs
	mkdir -p bin dev etc/tor proc tmp usr var/empty var/tor/keys
	chmod 1777 tmp
	chown -R 500:500 var/tor
	chmod -R 700 var/tor
	ln -s bin sbin
	ln -s ../bin usr/bin
	ln -s ../bin usr/sbin
}

################################################################################

populate_bin()
{
	cd $WORKING/initramfs/bin
	cp $WORKING/$BUSYBOX/busybox .
	cp $WORKING/$TOR/src/or/tor .
	cp $WORKING/$NTPD/ntpd .
	cp $WORKING/$DROPBEAR/dbclient .
	cp $WORKING/$DROPBEAR/scp .
	cp $WORKING/../configs/setup .
	chmod 755 setup

	cd $WORKING/initramfs
	chroot . /bin/busybox --install -s

	cd $WORKING/initramfs
	ln -s bin/busybox init
}

################################################################################

populate_etc()
{
cd $WORKING/initramfs/etc

cat << EOF > fstab
/dev/ram0     /           ext2    defaults   0 0
none          /proc       proc    defaults   0 0
EOF

if [ "x$DEBUG" == "xyes" ] ; then
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
ntp:x:500:
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
	[ -f $LINUX/arch/i386/boot/bzImage ] && return 0
	tar jxvf ../sources/$LINUX.tar.bz2
	tar jxvf ../sources/$PATCHES.tar.bz2 
	cd $LINUX
	for i in ../$KVERSION/* ; do patch -p 1 < $i ; done 

	cd $WORKING/$LINUX
	cp $WORKING/../configs/kernel-$KVERSION.config .config
	make
}

################################################################################

make_iso()
{
	cd $WORKING
	mkdir -p iso.tor/boot/grub
	cp /lib/grub/i386-gentoo/stage2_eltorito iso.tor/boot/grub/
	cp $WORKING/initramfs.igz iso.tor/boot
	cp $WORKING/$LINUX/arch/i386/boot/bzImage iso.tor/boot/kernel.tor 

	cd $WORKING
cat << EOF > iso.tor/boot/grub/menu.lst
hiddenmenu
timeout 0
title tor-ramdisk
kernel /boot/kernel.tor root=/dev/ram0
initrd /boot/initramfs.igz
EOF

	mkisofs -R -b boot/grub/stage2_eltorito -no-emul-boot -boot-load-size 4 -boot-info-table -o tor.iso iso.tor

	if [ "x$DEBUG" == "xyes" ] ; then
		mv tor.iso tor.uclibc.i686.debug.$RELEASE.iso
		md5sum tor.uclibc.i686.debug.$RELEASE.iso > tor.uclibc.i686.debug.$RELEASE.iso.md5
	else
		mv tor.iso tor.uclibc.i686.$RELEASE.iso
		md5sum tor.uclibc.i686.$RELEASE.iso > tor.uclibc.i686.$RELEASE.iso.md5
	fi
}

################################################################################

[[ $CLEAN == 1 ]] && clean_start
start_build
get_configs
get_sources
build_busybox
build_tor
build_ntpd
build_dropbear
prepare_initramfs
populate_bin
populate_etc
populate_dev
finish_initramfs
compile_kernel
make_iso

