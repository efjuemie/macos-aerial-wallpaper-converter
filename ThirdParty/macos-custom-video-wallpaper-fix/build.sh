#!/bin/bash
# Build the temporal-scalability HEVC encoder.
set -e
cd "$(dirname "$0")"
swiftc -O encode_temporal.swift -o encode_temporal
echo "Built ./encode_temporal"
echo "Usage: ./encode_temporal <input.mov> <output.mov> [loopCount] [bitrateMbps]"
echo "Example (18s clip -> ~5 min, matches Apple aerials): ./encode_temporal in.mov out.mov 17 12"
