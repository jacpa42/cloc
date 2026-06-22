COMPILE := odin build cloc.odin -file -out:cloc

COMMON_FLAGS := -strict-style -vet-cast -vet-semicolon -vet-shadowing -vet-style -vet-unused-variables -vet-using-param -vet-using-stmt -thread-count:12 -warnings-as-errors -linker:lld
DEBUG_FLAGS := $(COMMON_FLAGS) -debug
RELEASE_FLAGS := $(COMMON_FLAGS) -o:speed -lto:thin -no-bounds-check
# RELEASE_FLAGS := $(COMMON_FLAGS) -o:speed -disable-assert -lto:thin -no-bounds-check -source-code-locations:none

.PHONY: bd br rd rr

bd:
	$(COMPILE) $(DEBUG_FLAGS)
br:
	$(COMPILE) $(RELEASE_FLAGS)
rd: bd
	./cloc
rr: br
	./cloc
