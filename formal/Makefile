# formal — SymbiYosys proofs (docs/PLAN.md T5.2, ASSERTIONS.md "F-*" rows).
# Every .sby has a `prove` task (abc pdr: unbounded) and a `cover` task (smtbmc).
# Needs sby + a slang-capable yosys + abc + an SMT solver. ctrl/fc read the RTL
# through slang because the native Yosys parser rejects package imports in module
# headers.
#
# Toolchain portability: the committed .sby are written for the OSS CAD Suite,
# where slang is a loadable plugin (`plugin -i slang`) and yices is present. An
# upstream-built Yosys instead has slang BUILT IN (read_slang, no plugin) and may
# only have z3. To run in both without forking the .sby, this Makefile detects the
# local tools and, only when they differ from the OSS CAD Suite baseline, runs a
# generated copy (`_<proof>.sby`) with `plugin -i slang` stripped and the cover
# solver swapped. With the OSS CAD Suite the pristine .sby run unchanged (CI path).
SBY    ?= sby
YOSYS  ?= yosys
PROOFS := async_fifo ingress_gate ctrl fc

# 1 when read_slang is a built-in command (upstream Yosys); empty with the plugin.
SLANG_BUILTIN := $(shell $(YOSYS) -qp 'read_slang' 2>&1 | grep -qi 'no such command' && echo || echo 1)
# Prefer yices (OSS CAD Suite / CI); fall back to z3 (e.g. pip-installed) otherwise.
COVER_SOLVER  := $(shell command -v yices-smt2 >/dev/null 2>&1 && echo yices || echo z3)

.PHONY: all $(PROOFS) clean
all: $(PROOFS)
	@echo "formal: OK ($(PROOFS): prove + cover)"

# If the local tools match the OSS CAD Suite baseline (slang plugin + yices), run
# the committed .sby verbatim; otherwise run an adapted _<proof>.sby.
$(PROOFS):
	@if [ -z "$(SLANG_BUILTIN)" ] && [ "$(COVER_SOLVER)" = "yices" ]; then \
	  echo "+ $(SBY) -f $@.sby"; $(SBY) -f $@.sby; \
	else \
	  sed $(if $(SLANG_BUILTIN),-e '/^[[:space:]]*plugin -i slang/d') \
	      -e 's/smtbmc yices/smtbmc $(COVER_SOLVER)/' $@.sby > _$@.sby; \
	  echo "[formal] adapted $@ (slang_builtin=$(if $(SLANG_BUILTIN),1,0), solver=$(COVER_SOLVER)) -> _$@.sby"; \
	  echo "+ $(SBY) -f _$@.sby"; $(SBY) -f _$@.sby; \
	fi

clean:
	rm -rf $(addsuffix _prove,$(PROOFS)) $(addsuffix _cover,$(PROOFS)) ctrl_prove_fc ctrl_cover_fc
	rm -rf _*.sby _async_fifo* _ingress_gate* _ctrl* _fc*
