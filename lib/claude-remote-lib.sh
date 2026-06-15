#!/usr/bin/env bash
# claude-remote shared helpers. Sourced by bin/claude-remote, bin/claude-remote-pick, and tests.
# All tmux/abtop access goes through the CR_TMUX / CR_ABTOP env seams.

: "${CR_TMUX:=tmux}"
: "${CR_ABTOP:=abtop}"

# (functions added by later tasks)
