FTP Server Setup
----------------

 * Download Ubuntu server ISO.
 * Create Virtualbox VM.

   * 1024 MB of RAM
   * 2.5 GB disk
   * 128 MB of video memory
   * Bridged network adapter
   * Make sure MAC address is unique

 * Install Ubuntu

   * Encrypt home directory
   * Partitioning scheme - guided, use entire disk and set up LVM

     * Use maximum size (max)

   * Disable automatic updates
   * Install no software
   * No spaces in password

 * Install FTP server

   * sudo apt-get install vsftpd
   * Edit /etc/vsftpd.conf

     * anonymous_enable=NO
     * local_enable=YES
     * write_enable=YES

   * sudo /etc/init.d/vsftpd restart to start the server the first time
   * After initial start, it can be started and stopped with:

     * sudo start vsftpd
     * sudo stop vsftpd


Relay Setup
-----------

 * Ensure relay machine has a DHCP IP address reserved and the correct ports are
   forwarded to that address.
 * Boot relay with Tor-ramdisk CD.
 * Set up network access and make sure the relay machine received the correct IP
   address.
 * Start Tor.

   * Generate a new torrc and secret key.

 * Start FTP server.
 * Export torrc and key.
