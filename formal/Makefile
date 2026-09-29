# formal — SymbiYosys proofs (docs/PLAN.md T5.2, ASSERTIONS.md "F-*" rows).
# Every .sby has a `prove` task (abc pdr: unbounded) and a `cover` task (smtbmc).
# Needs the pinned OSS CAD Suite (sby, yosys with the slang plugin, abc, yices):
# ctrl.sby reads the RTL through yosys-slang because the native Yosys parser
# rejects package imports in module headers.
SBY    ?= sby
PROOFS := async_fifo ingress_gate ctrl

.PHONY: all $(PROOFS) clean
all: $(PROOFS)
	@echo "formal: OK ($(PROOFS): prove + cover)"

$(PROOFS):
	$(SBY) -f $@.sby

clean:
	rm -rf $(addsuffix _prove,$(PROOFS)) $(addsuffix _cover,$(PROOFS))
