.PHONY: test lint fmt fmt-check
test:
	bats tests/

lint:
	shellcheck bin/claude-remote bin/claude-remote-pick lib/claude-remote-lib.sh install.sh

fmt:
	shfmt -w -i 2 -ci bin/ lib/ install.sh

fmt-check:
	shfmt -d -i 2 -ci bin/ lib/ install.sh
