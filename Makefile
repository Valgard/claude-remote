.PHONY: test lint fmt fmt-check sign-tmux
test:
	bats tests/

lint:
	shellcheck bin/claude-remote bin/claude-remote-pick bin/cr-sign-tmux lib/claude-remote-lib.sh install.sh

# Rebuild + ad-hoc sign tmux with an embedded Info.plist so macOS Local Network
# privacy lets picker sessions reach LAN hosts. Re-run after `brew upgrade tmux`.
sign-tmux:
	./bin/cr-sign-tmux

fmt:
	shfmt -w -i 2 -ci bin/ lib/ install.sh

fmt-check:
	shfmt -d -i 2 -ci bin/ lib/ install.sh
