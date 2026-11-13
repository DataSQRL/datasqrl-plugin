#!/bin/bash
# Writes notes.md into a new git repository. The notes ask for a realtime result and give no reason
# why older results would not do.
set -euo pipefail

cat > notes.md <<'EOF'
# Sensor dashboard

Our machines send temperature readings to the Kafka topic `sensor-readings`. A record looks like this:

    {"sensor_id": "s-4", "machine_id": "m-12", "temperature": 71.3, "read_at": "2026-03-01T10:15:00Z"}

We want a realtime dashboard API that shows the average temperature of each machine for each hour.
About 200 sensors send one reading every 10 seconds.
EOF

git init -q
git add notes.md
git -c user.name=eval -c user.email=eval@example.com commit -q -m "notes"
