#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build
xcrun swiftc Sources/Events.swift Tests/EventTests.swift -o .build/EventTests
.build/EventTests
