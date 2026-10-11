# minilang-compiler
#
# Self-hosted minilang toolchain. The handwritten C bootstrap compiler lives in
# the sibling repository `minilang-boot`; this repo only contains the minilang
# sources (compiler.mil / vm.mil / llvm_gen.mil / milc_io.mil / main.mil) that
# the boot binary compiles and runs.
#
# Point MINILANG at a boot `minilang` binary (built from minilang-boot), or let
# the Makefile fall back to ../minilang-boot/minilang then ./minilang.

MINILANG ?= $(or $(MINILANG_BOOT),$(wildcard ../minilang-boot/minilang),./minilang)

.PHONY: all test bootstrap clean check-boot

all: check-boot
	@echo "Using boot binary: $(MINILANG)"
	$(MINILANG) build -b main.mil
	@echo "Self-hosted CLI: run with '$(MINILANG) run main.mil <command> ...'"

check-boot:
	@if [ -z "$(MINILANG)" ] || [ ! -x "$(MINILANG)" ]; then \
	  echo "Boot compiler not found. Build it first:"; \
	  echo "  git clone https://github.com/HFunction2013/minilang-boot"; \
	  echo "  $(MAKE) -C minilang-boot"; \
	  echo "then: make MINILANG_BOOT=\$$PWD/minilang-boot/minilang"; \
	  exit 1; \
	fi

test: check-boot
	@for f in tests/*.mil; do \
	  echo "--- $$f"; \
	  $(MINILANG) run "$$f" || echo "FAILED: $$f"; \
	done

bootstrap: check-boot
	./bootstrap_test.sh

clean:
	rm -f *.milc *.ll *.o
