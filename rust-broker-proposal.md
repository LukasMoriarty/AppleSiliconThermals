# Proposal: Rust-based Fan Broker

## Overview
This branch explores rewriting the bash-based fan control broker (`system/apple-silicon-fan-control`) in **Rust**, based on the concepts proposed in PR #1.

## The "Why"
The Rust implementation aims to solve two main limitations of our current setup:
1. **Dynamic Fan Curves:** A lightweight compiled daemon could monitor sensors in real-time and smoothly adjust fan speeds based on temperature curves, completely independent of the Omarchy UI.
2. **Suspend/Resume Reliability:** A binary can easily hook into systemd/DBus to detect system sleep/wake events and automatically restore fan speeds, fixing the current resume bugs.

## The Conflict: "Zero Dependencies"
The main drawback is breaking the plugin's core "zero dependency" philosophy.
- **Distribution:** Users would need to install the Rust toolchain to compile it, or we would need to distribute pre-compiled binaries.
- **Auditability:** Bash scripts are transparent; any Linux user can audit what the script does as `root`. A compiled binary is opaque and requires more trust.

## Goal of this Branch
This is a sandbox to safely experiment with the Rust codebase. We will evaluate if the thermal efficiency and system-state reliability justify sacrificing the pure-bash ideology, or if we can extract just the suspend/resume fixes to apply back to our bash scripts.
