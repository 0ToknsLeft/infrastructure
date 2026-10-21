DB_PASS=$(file < .db-pass)

.PHONY: print-pass
print-pass:
	@echo "pass: $(DB_PASS)"

.PHONY: setup
setup:
	git-crypt unlock
