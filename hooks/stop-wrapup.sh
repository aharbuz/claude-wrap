#!/bin/bash
# Stop hook - RETIRED
#
# Previously: automated wrap-up when Claude finished meaningful work.
# Replaced by the /wrap-up skill (user-triggered) because the Stop hook
# architecture is inherently binary (block or allow) and fired too often
# on sub-task completions when the user intended to continue.
#
# Context guard (60%+) handles urgent end-of-session wrap-up automatically.
# For normal sessions, the user runs /wrap-up when ready.

exit 0
