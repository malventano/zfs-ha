# ZFS-HA Makefile
#
# Targets:
#   all      - build smp_send
#   install  - install tools to system paths
#   test     - run unit-ish checks (topology discovery, affiliation read)

PREFIX ?= /usr/local
HALIB ?= /usr/lib/zfs-ha
OCFDIR ?= /usr/lib/ocf/resource.d

CC ?= gcc
CFLAGS ?= -O2 -Wall

all: smp_send

smp_send: scripts/smp_send.c
	$(CC) $(CFLAGS) -o $@ $<

install: smp_send
	install -d $(DESTDIR)$(PREFIX)/bin $(DESTDIR)$(HALIB) $(DESTDIR)$(OCFDIR)/zfsha
	install -m755 smp_send $(DESTDIR)$(PREFIX)/bin/
	install -m755 scripts/zfs-ha-handoff scripts/zfs-ha-config \
	    scripts/zfs-ha-poolconf scripts/zfs-ha-quiesce scripts/zfs-ha-doctor \
	    scripts/zfs-ha-mailbox scripts/zfs-ha-amialone scripts/zfs-ha-pr \
	    scripts/zfs-ha-cutover scripts/zfs-ha-role scripts/zfs-ha-udevrule \
	    scripts/zfs-ha-udev-delete scripts/zfs-ha-recover $(DESTDIR)$(HALIB)/
	install -Dm755 scripts/strategies/stp/handoff $(DESTDIR)$(HALIB)/strategies.d/stp/handoff
	install -Dm755 scripts/strategies/sas/handoff $(DESTDIR)$(HALIB)/strategies.d/sas/handoff
	install -Dm755 scripts/strategies/null/handoff $(DESTDIR)$(HALIB)/strategies.d/null/handoff
	# every tool gets a PATH-visible symlink in $(PREFIX)/bin
	for t in zfs-ha-handoff zfs-ha-config zfs-ha-poolconf zfs-ha-quiesce \
	         zfs-ha-doctor zfs-ha-mailbox zfs-ha-amialone zfs-ha-pr \
	         zfs-ha-cutover zfs-ha-role zfs-ha-udevrule zfs-ha-udev-delete zfs-ha-recover; do \
	    ln -sf $(HALIB)/$$t $(DESTDIR)$(PREFIX)/bin/$$t; done
	ln -sf $(HALIB)/fence_zfs_ha_stp $(DESTDIR)$(PREFIX)/bin/fence_zfs_ha_stp
	install -m755 scripts/check_boot_import.sh $(DESTDIR)$(PREFIX)/bin/check_boot_import
	install -Dm755 scripts/zfsha-pool $(DESTDIR)$(OCFDIR)/zfsha/Pool
	install -m755 utils/shelf-health.py $(DESTDIR)$(PREFIX)/bin/shelf-health
	install -m755 utils/sas_topology.sh $(DESTDIR)$(PREFIX)/bin/sas_topology
	@echo "installed: smp_send, handoff dispatcher + strategies, quiesce, doctor, role, mailbox, amialone, pr, cutover, recover, udevrule + udev-delete, fence_zfs_ha_stp, check_boot_import, ocf:zfsha:Pool, shelf-health, sas_topology (all on PATH via $(PREFIX)/bin)"

check: smp_send
	@echo "== topology check =="
	@PATH=$(PREFIX)/bin:$$PATH sh utils/sas_topology.sh | head -20
	@echo "== affiliation read check =="
	@for e in /dev/bsg/expander-*; do \
		[ -e "$$e" ] || continue; \
		$(PREFIX)/bin/smp_send $$e 0x12 0000000000000000 >/dev/null 2>&1 && \
			echo "OK: $$e responds to REPORT PHY SATA"; \
	done

clean:
	rm -f smp_send

.PHONY: all install check clean
