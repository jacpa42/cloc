OUT := cloc
EXE := cloc.odin
COMPILE := odin build $(EXE) -file -out:$(OUT)

COMMON_FLAGS := -strict-style -vet-cast -vet-semicolon -vet-shadowing -vet-style -vet-unused-variables -vet-using-param -vet-using-stmt -warnings-as-errors -linker:lld
DEBUG_FLAGS := $(COMMON_FLAGS) -debug
RELEASE_FLAGS := $(COMMON_FLAGS) -o:speed -lto:thin -no-bounds-check -source-code-locations:none

.PHONY: bd br rd rr

bd:
	$(COMPILE) $(DEBUG_FLAGS)
br:
	$(COMPILE) $(RELEASE_FLAGS)
	strip $(OUT)
rd: bd
	./$(OUT)
rr: br
	./$(OUT)
