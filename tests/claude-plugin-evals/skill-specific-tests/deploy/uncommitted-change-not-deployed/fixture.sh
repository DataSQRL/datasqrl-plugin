#!/bin/bash
# Writes a committed DataSQRL project into a new git repository with a GitHub remote.
# Then changes package.json without committing it.
set -euo pipefail

cat > sensors.sqrl <<'EOF'
IMPORT sensors.SensorReading;

HighTemperature := SELECT * FROM SensorReading WHERE temperature > 100;
EOF
cat > package.json <<'EOF'
{ "version": "1", "script": { "main": "sensors.sqrl" } }
EOF

git init -q
git remote add origin https://github.com/example/sensors.git
git add .
git -c user.name=eval -c user.email=eval@example.com commit -q -m "sensors pipeline"

cat > package.json <<'EOF'
{ "version": "1", "script": { "main": "sensors.sqrl" }, "engines": { "flink": { "config": { "parallelism.default": 2 } } } }
EOF
