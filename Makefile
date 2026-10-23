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
	install -m755 smp_send $(PREFIX)/bin/
	install -m755 scripts/zfs-ha-handoff scripts/zfs-ha-config \
	    scripts/zfs-ha-poolconf scripts/zfs-ha-quiesce scripts/zfs-ha-doctor \
	    scripts/zfs-ha-mailbox scripts/zfs-ha-amialone scripts/zfs-ha-pr \
	    scripts/zfs-ha-cutover $(HALIB)/
	install -Dm755 scripts/strategies/stp/handoff $(HALIB)/strategies.d/stp/handoff
	install -Dm755 scripts/strategies/sas/handoff $(HALIB)/strategies.d/sas/handoff
	install -Dm755 scripts/strategies/null/handoff $(HALIB)/strategies.d/null/handoff
	ln -sf $(HALIB)/zfs-ha-pr $(PREFIX)/bin/zfs-ha-pr
	ln -sf $(HALIB)/zfs-ha-cutover $(PREFIX)/bin/zfs-ha-cutover
	install -Dm755 scripts/zfsha-pool $(OCFDIR)/zfsha/Pool
	install -m755 scripts/shelf-health.py $(PREFIX)/bin/shelf-health
	@echo "installed: smp_send, handoff dispatcher + strategies, quiesce, doctor, mailbox, amialone, ocf:zfsha:Pool"

check: smp_send
	@echo "== topology check =="
	@PATH=$(PREFIX)/bin:$$PATH sh scripts/sas_topology.sh | head -20
	@echo "== affiliation read check =="
	@for e in /dev/bsg/expander-*; do \
		[ -e "$$e" ] || continue; \
		$(PREFIX)/bin/smp_send $$e 0x12 0000000000000000 >/dev/null 2>&1 && \
			echo "OK: $$e responds to REPORT PHY SATA"; \
	done

clean:
	rm -f smp_send

.PHONY: all install check clean
