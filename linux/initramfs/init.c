/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * init.c -- PID 1 for the blitsCRT_Mister boot proof-of-concept.
 *
 * The whole job is to prove our own kernel booted. It brings up the pseudo
 * filesystems, mounts the card's FAT partition at /media/fat, and appends one
 * stamped record -- name, version, kernel string, time -- then flushes and
 * unmounts. After the warm reboot there is a file on the card that only this
 * kernel could have written.
 *
 * No busybox and no shell are required: everything here is libc and syscalls,
 * so the initramfs is just this one static binary plus empty mount points. If a
 * /bin/sh ever is present it hands off to it; otherwise it idles, because PID 1
 * returning panics the kernel.
 *
 * NAME and VERSION are injected at compile time (-D) so the Makefile stays the
 * single source of truth for both this log and the kernel's LOCALVERSION.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/wait.h>

#ifndef BLITSCRT_NAME
#define BLITSCRT_NAME "BlitsCRT"
#endif
#ifndef BLITSCRT_VERSION
#define BLITSCRT_VERSION "0.0"
#endif
/* Kernel image revision, bumped whenever anything baked into the zImage changes.
 * Printed here as well as riding in LOCALVERSION, so the boot log says which
 * image is running without needing uname. */
#ifndef BLITSCRT_KREV
#define BLITSCRT_KREV "k0"
#endif

#define FATDIR  "/media/fat"
#define LOGPATH FATDIR "/blitscrt-boot.log"

/* write(2) is marked warn_unused_result under -Wextra; consume it once here. */
static void wr(int fd, const void *buf, size_t n)
{
	ssize_t r = write(fd, buf, n);
	(void)r;
}

/* The console is stdout/stderr thanks to console=ttyS0 in bootargs. */
static void say(const char *s)
{
	wr(2, s, strlen(s));
}

/* Read a whole small file into buf, NUL-terminated. Returns length or -1. */
static int slurp(const char *path, char *buf, int cap)
{
	int fd = open(path, O_RDONLY);
	if (fd < 0)
		return -1;
	int n = read(fd, buf, cap - 1);
	close(fd);
	if (n < 0)
		return -1;
	buf[n] = '\0';
	return n;
}

/*
 * Read the first sector of a block device raw, so we can tell a corrupted read
 * from a filesystem the driver just won't mount. If these bytes are a sane FAT
 * boot record -- jump byte plus the 0x55AA signature -- the media and the reads
 * are fine and the problem is the mount; if they are garbage, the SD read path
 * itself is wrong (MMC timing / device tree), not the card.
 */
static void probe_dev(const char *dev)
{
	unsigned char b[512];
	char line[192];
	int fd = open(dev, O_RDONLY);
	if (fd < 0) {
		say("  ");
		say(dev);
		say(": cannot open\n");
		return;
	}
	int n = read(fd, b, sizeof b);
	close(fd);
	if (n < 512) {
		say("  ");
		say(dev);
		say(": short read\n");
		return;
	}
	int p = snprintf(line, sizeof line, "  %s:", dev);
	for (int i = 0; i < 16; i++)
		p += snprintf(line + p, sizeof line - p, " %02x", b[i]);
	p += snprintf(line + p, sizeof line - p, " | sig %02x%02x%s\n",
		b[510], b[511],
		((b[0] == 0xEB || b[0] == 0xE9) && b[510] == 0x55 && b[511] == 0xAA)
			? "  looks-like-FAT" : "");
	wr(2, line, (size_t)(p > 0 ? p : 0));
}

/*
 * Mount the card's FAT partition. The MMC block device probes asynchronously, so
 * retry a few times while it settles -- but only a few, because every failing
 * mount makes the kernel reprint a boot-sector error. If it will not mount, dump
 * what the block layer actually returns and stop, so the console shows the cause
 * instead of a scrolling wall of the same message.
 */
static int mount_fat(void)
{
	static const char *cands[] = {
		"/dev/mmcblk0p1", "/dev/mmcblk0p2",
		"/dev/mmcblk1p1", "/dev/mmcblk1p2", NULL
	};
	/* MiSTer formats cards over 32 GB as exFAT and smaller ones as FAT32, so
	 * try exFAT first -- a hit there means we never attempt vfat on it and the
	 * kernel never prints its bogus-sector complaint. */
	static const char *types[] = { "exfat", "vfat", NULL };

	mkdir("/media", 0755);
	mkdir(FATDIR, 0755);

	for (int sweep = 0; sweep < 8; sweep++) {           /* ~4 s */
		for (int i = 0; cands[i]; i++) {
			for (int t = 0; types[t]; t++) {
				if (mount(cands[i], FATDIR, types[t],
					  MS_NOATIME, NULL) == 0) {
					say("blitscrt: mounted ");
					say(cands[i]);
					say(" as ");
					say(types[t]);
					say(" -> " FATDIR "\n");
					return 0;
				}
			}
		}
		usleep(500000);                                 /* 500 ms */
	}

	say("blitscrt: could not mount " FATDIR
	    " -- dumping what the block layer sees:\n");
	{
		char pt[1024];
		if (slurp("/proc/partitions", pt, sizeof pt) > 0) {
			say("  /proc/partitions:\n");
			say(pt);
		}
	}
	probe_dev("/dev/mmcblk0");
	for (int i = 0; cands[i]; i++)
		probe_dev(cands[i]);
	return -1;
}

/*
 * Drop to an interactive busybox shell on the console so the card can be poked
 * at live -- dmesg, cat /proc/partitions, hexdump /dev/mmcblk0p1, blkid, or a
 * manual mount with different options. busybox is built standalone, so applets
 * work by name without symlinks. PID 1 must never return, so the shell runs in a
 * child and is respawned if it exits.
 */
static void debug_shell(void)
{
	/* Ensure stdin/out/err are the console so the shell is interactive. */
	int c = open("/dev/console", O_RDWR);
	if (c < 0)
		c = open("/dev/ttyS0", O_RDWR);
	if (c >= 0) {
		dup2(c, 0);
		dup2(c, 1);
		dup2(c, 2);
		if (c > 2)
			close(c);
	}
	setenv("PATH", "/bin:/sbin", 1);
	setenv("HOME", "/", 1);
	setenv("TERM", "vt100", 1);
	setenv("PS1", BLITSCRT_NAME "# ", 1);

	for (;;) {
		pid_t pid = fork();
		if (pid == 0) {
			/*
			 * Inherit init's descriptors and nothing more.
			 *
			 * An earlier version called setsid() and tried to claim
			 * /dev/console as a controlling terminal, to silence the
			 * "can't access tty; job control turned off" notice. That
			 * was a mistake: setsid() detaches unconditionally, so if
			 * the open or the TIOCSCTTY then failed the shell was
			 * left with no controlling terminal at all and would not
			 * take input -- worse than the cosmetic warning it was
			 * meant to remove. Job control off is harmless; a shell
			 * that ignores the keyboard during bring-up is not.
			 */
			execl("/bin/busybox", "sh", "-i", (char *)NULL);
			_exit(127);
		}
		if (pid > 0) {
			int st;
			waitpid(pid, &st, 0);
		}
		say("\nblitscrt: shell exited -- respawning ('exit' starts a new one).\n");
		sleep(1);       /* avoid a tight loop if the console has no input */
	}
}

/*
 * Stage the USB gadget before the daemon starts.
 *
 * gadget-setup.sh creates the configfs gadget and mounts FunctionFS; the daemon
 * then opens ep0, writes its descriptors and binds the UDC itself. Split that
 * way because only the daemon knows when the descriptors are in, and binding
 * earlier offers a host a device with no endpoints behind it.
 *
 * A card copy wins so the script can be changed without rebuilding the kernel.
 * Returns non-zero if FunctionFS came up, which is what decides whether the
 * daemon runs with the gadget or falls back to --no-gadget.
 */
/* Anything in the kernel command line. Cheap, and it means a bad boot can be
 * recovered by editing blitsenv.txt on the card rather than reflashing. */
static int cmdline_has(const char *word)
{
	char buf[1024];
	if (slurp("/proc/cmdline", buf, sizeof buf) < 0)
		return 0;
	return strstr(buf, word) != NULL;
}

static int stage_gadget(void)
{
	/* blitscrt.nogadget on the kernel command line skips all of this and
	 * boots the way it did before M4: fabric, daemon, shell. Worth having
	 * while the gadget path is new -- if staging ever wedges the boot, the
	 * way out should not be a rebuild. */
	if (cmdline_has("blitscrt.nogadget")) {
		say("blitscrt: blitscrt.nogadget set; skipping the USB gadget.\n");
		return 0;
	}

	static const char *paths[] = {
		"/media/fat/blitscrt/gadget-setup.sh",
		"/bin/gadget-setup.sh",
		NULL
	};
	const char *sh = NULL;
	pid_t pid;
	int status = 0;

	for (int i = 0; paths[i]; i++)
		if (access(paths[i], R_OK) == 0) { sh = paths[i]; break; }
	if (!sh) {
		say("blitscrt: no gadget-setup.sh; running without the USB gadget.\n");
		return 0;
	}

	pid = fork();
	if (pid == 0) {
		int fd = open("/media/fat/blitscrt-gadget.log",
			      O_WRONLY | O_CREAT | O_TRUNC, 0644);
		if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); if (fd > 2) close(fd); }
		/*
		 * busybox by path, not /bin/sh. The initramfs ships /bin/busybox
		 * with no applet symlinks -- which is why the interactive shell
		 * above is started the same way. Reaching for /bin/sh here failed
		 * silently: execl returned, the child _exit(127)'d writing
		 * nothing, and the log was created empty. An empty log next to a
		 * daemon in fabric-only mode said nothing about which of the two
		 * had gone wrong.
		 */
		execl("/bin/busybox", "sh", sh, (char *)NULL);
		execl("/bin/sh", "sh", sh, (char *)NULL);   /* if a real one exists */
		_exit(127);
	}
	if (pid < 0) return 0;
	waitpid(pid, &status, 0);

	/* The endpoint file is the honest test: configfs can be set up and still
	 * produce nothing, so the script's exit status alone is not enough. */
	if (access("/dev/ffs-blitscrt/ep0", F_OK) == 0) {
		say("blitscrt: USB gadget staged; log in /media/fat/blitscrt-gadget.log\n");
		return 1;
	}

	/* Say why on the console, not only in a log file. A staging failure used
	 * to leave an empty log and a daemon quietly in fabric-only mode, with
	 * nothing on screen or console connecting the two. */
	{
		char line[256];
		int n;
		if (WIFEXITED(status) && WEXITSTATUS(status) == 127)
			n = snprintf(line, sizeof line,
				"blitscrt: could not exec a shell for "
				"gadget-setup.sh; running without the gadget.\n");
		else if (WIFEXITED(status) && WEXITSTATUS(status) != 0)
			n = snprintf(line, sizeof line,
				"blitscrt: gadget-setup.sh failed (exit %d); "
				"running without the gadget. See "
				"/media/fat/blitscrt-gadget.log\n",
				WEXITSTATUS(status));
		else
			n = snprintf(line, sizeof line,
				"blitscrt: gadget-setup.sh ran but "
				"/dev/ffs-blitscrt/ep0 is absent; running "
				"without the gadget. Check /sys/class/udc/ "
				"names a controller.\n");
		wr(2, line, (size_t)(n > 0 ? n : 0));
	}
	return 0;
}

/*
 * Launch blitscrtd in the background to bring up the HPS<->fabric
 * register transport (M2). It reads the register block over gp and, on a match,
 * runs the heartbeat. gp writes are safe here because we own gp_out -- there is
 * no MiSTer hps_io on these wires -- so enable them. Output goes to a log on the
 * card, and the daemon is a background child so the shell still comes up. A copy
 * on the card wins over the one baked into the initramfs, so the daemon can be
 * swapped without rebuilding the kernel.
 */
static void launch_daemon(int with_gadget)
{
	static const char *paths[] = {
		"/media/fat/blitscrt/blitscrtd",   /* card copy, swappable */
		"/bin/blitscrtd",                  /* embedded fallback */
		NULL
	};
	const char *bin = NULL;
	for (int i = 0; paths[i]; i++)
		if (access(paths[i], X_OK) == 0) {
			bin = paths[i];
			break;
		}
	if (!bin) {
		say("blitscrt: no blitscrtd found; skipping the transport daemon.\n");
		return;
	}

	pid_t pid = fork();
	if (pid == 0) {
		int fd = open("/media/fat/blitscrtd.log",
			      O_WRONLY | O_CREAT | O_TRUNC, 0644);
		if (fd >= 0) {
			dup2(fd, 1);
			dup2(fd, 2);
			if (fd > 2)
				close(fd);
		}
		setenv("BLITSCRT_GP_UNSAFE", "1", 1);   /* our fabric owns gp_out */

		/*
		 * LZ4 is not set here. It is the daemon's own default, so it
		 * applies however the daemon is started -- including by hand,
		 * which is when getting something different would be most
		 * confusing. BLITSCRT_LZ4=0 turns it off.
		 */

		/*
		 * BLITSCRT_TRACE deliberately not set.
		 *
		 * It was invaluable while the bulk path was being brought up,
		 * when every failure looked like nothing happening. Now that
		 * frames flow it prints two lines per frame at 60 Hz, which is
		 * far more than a 115200 console can carry -- the writes back up,
		 * the daemon waits on them, and it costs the frame rate it is
		 * meant to be measuring. See the README for how to turn it on by
		 * hand when something needs looking at.
		 */
		if (with_gadget)
			execl(bin, "blitscrtd", (char *)NULL);
		else
			execl(bin, "blitscrtd", "--no-gadget", (char *)NULL);
		_exit(127);
	}
	if (pid > 0) {
		char line[192];
		int n = snprintf(line, sizeof line,
			"blitscrt: launched %s%s (pid %d);"
			" output in /media/fat/blitscrtd.log\n",
			bin, with_gadget ? "" : " --no-gadget", (int)pid);
		wr(2, line, (size_t)(n > 0 ? n : 0));
	}
}

int main(void)
{
	char kver[512], up[128], line[1024];

	/* PID 1: the filesystems init itself needs. */
	mkdir("/proc", 0555);
	mount("proc", "/proc", "proc", 0, NULL);
	mkdir("/sys", 0555);
	mount("sysfs", "/sys", "sysfs", 0, NULL);
	mkdir("/dev", 0755);
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);

	say("\n=== " BLITSCRT_NAME " " BLITSCRT_VERSION "-" BLITSCRT_KREV
	    " initramfs: our kernel is alive ===\n");

	if (slurp("/proc/version", kver, sizeof kver) < 0)
		strcpy(kver, "(unknown)\n");
	if (slurp("/proc/uptime", up, sizeof up) < 0)
		strcpy(up, "(unknown)\n");

	/* Wall clock. With no battery-backed RTC this reads from the epoch until
	 * something sets it, so the kernel/init build stamps below are the real
	 * proof of which image booted. */
	time_t now = time(NULL);
	struct tm tmv;
	char ts[64];
	gmtime_r(&now, &tmv);
	strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S UTC", &tmv);

	int mounted = (mount_fat() == 0);
	if (mounted) {
		int fd = open(LOGPATH, O_WRONLY | O_CREAT | O_APPEND, 0644);
		if (fd >= 0) {
			int n = snprintf(line, sizeof line,
				"---- boot ----\n"
				"name:       %s\n"
				"version:    %s\n"
				"time:       %s\n"
				"uptime:     %s"        /* /proc/uptime carries its own \n */
				"kernel:     %s"        /* /proc/version carries its own \n */
				"init-built: %s %s\n\n",
				BLITSCRT_NAME, BLITSCRT_VERSION, ts, up, kver,
				__DATE__, __TIME__);
			wr(fd, line, (size_t)(n > 0 ? n : 0));
			fsync(fd);
			close(fd);
			say("blitscrt: wrote " LOGPATH "\n");
		} else {
			say("blitscrt: could not open " LOGPATH " for writing\n");
		}
		sync();          /* flush the record; leave it mounted for the shell */
		launch_daemon(stage_gadget()); /* M2: bring up the HPS<->fabric transport */
	}

	if (mounted)
		say("\nblitscrt: " FATDIR " mounted, log written, transport daemon"
		    " started. Dropping to a shell.\n");
	else
		say("\nblitscrt: mount failed (see the dump above)."
		    " Dropping to a shell to debug.\n");

	debug_shell();                      /* interactive; never returns */
	return 0;                           /* not reached */
}
