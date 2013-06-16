#!/bin/bash

RELEASE=ar7161.testing

BUSYBOX=busybox-1.20.2
TOR=tor-0.2.3.25
NTPD=openntpd-3.9p1
OPENSSH=openssh-6.1p1

################################################################################

set_start()
{
	[[ "x$CLEAN" = "xyes" ]] && rm -rf release
	[[ "x$DEBUG" = "x" ]] && unset DEBUG
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

	if [[ "x$DEBUG" = "xyes" ]] ; then
		[[ ! -f $BUSYBOX.debug.config ]] && echo "Missing busybox config" && exit
	else
		[[ ! -f $BUSYBOX.config ]] && echo "Missing busybox config" && exit
	fi
	[[ ! -f setup ]] && echo "Missing setup script" && exit
}

################################################################################

get_sources()
{
	cd $WORKING/..
	mkdir -p sources
	cd sources

	[[ ! -f $BUSYBOX.tar.bz2 ]] && wget http://www.busybox.net/downloads/$BUSYBOX.tar.bz2
	[[ ! -f $TOR.tar.gz ]] && wget http://www.torproject.org/dist/$TOR.tar.gz
	[[ ! -f $NTPD.tar.gz ]] && wget ftp://ftp.openbsd.org/pub/OpenBSD/OpenNTPD/$NTPD.tar.gz
	[[ ! -f $OPENSSH.tar.gz ]] && wget ftp://ftp.openbsd.org/pub/OpenBSD/OpenSSH/portable/$OPENSSH.tar.gz
}

################################################################################

build_busybox()
{
	cd $WORKING
	[[ -f $BUSYBOX/busybox ]] && return 0
	tar jxvf $WORKING/../sources/$BUSYBOX.tar.bz2
	cd $BUSYBOX
	for i in $WORKING/../configs/busybox-*.patch; do patch -p 1 < $i ; done
	if [[ "x$DEBUG" = "xyes" ]] ; then
		cp $WORKING/../configs/$BUSYBOX.debug.config .config
	else
		cp $WORKING/../configs/$BUSYBOX.config .config
	fi
	#CFLAGS="${CFLAGS} -w" make
	make
}

################################################################################

build_tor()
{
	cd $WORKING
	[[ -f $TOR/src/or/tor ]] && return 0
	tar zxvf $WORKING/../sources/$TOR.tar.gz
	cd $TOR
	for i in $WORKING/../configs/tor-*.patch; do patch -p 1 < $i ; done
	./configure --prefix=
	make
	strip src/or/tor
}

################################################################################

build_ntpd()
{
	cd $WORKING
	[[ -f $NTPD/ntpd ]] && return 0
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
	[[ -f $OPENSSH/ssh && -f $OPENSSH/scp ]] && return 0
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

get_needed()
{
	local A=$(readelf && $1 | grep NEEDED | sed -e 's/^.*library://' -e 's/\[[//' -e 's/\]]//')
	echo $A
}

populate_lib()
{
	cd $WORKING/initramfs/lib
	for i in busybox ntpd ssh tor; do
		A=$(get_needed ../bin/$i)
		for j in $A ; do
			[[ -e /lib/$j ]] && cp -f /lib/$j .
			[[ -e /usr/lib/$j ]] && cp -f /usr/lib/$j .
		done
	done

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

cat << EOF > inittab
::sysinit:/etc/rcS
ttyS0::respawn:/bin/setup
null::respawn:/bin/ntpd -s -d
EOF

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

	mknod -m 660 ttyS0 c 4 64
	mknod -m 660 ttyS1 c 4 65
	mknod -m 660 ttyS2 c 4 66
	mknod -m 660 ttyS3 c 4 67

	for i in $(seq 0 7) ; do mknod -m 660 ram$i b 1 $i ; done
}

################################################################################

set_start
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

