#!/bin/sh
# nginx-start.sh — runs inside the nginx container at startup.
#
# Fetches EC2 instance metadata (IMDSv2) and generates a custom index.html
# that identifies which node is serving the request.
# Useful for validating ALB round-robin: each refresh should show a different instance.
#
# This script lives on EFS (/ecs/logs/scripts/) and is volume-mounted into
# the container at /scripts. Update it directly on EFS without redeploying CF.

# curl is not in the base nginx image — install it before fetching metadata
apt-get update -qq && apt-get install -y --no-install-recommends curl -qq 2>/dev/null

# IMDSv2: get a token first (required when IMDSv1 is disabled)
TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || echo "")

INSTANCE_ID=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
  "http://169.254.169.254/latest/meta-data/instance-id" || echo "unknown")
LOCAL_IP=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
  "http://169.254.169.254/latest/meta-data/local-ipv4" || echo "unknown")
AZ=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
  "http://169.254.169.254/latest/meta-data/placement/availability-zone" || echo "unknown")
CONTAINER=$(hostname)

cat > /usr/share/nginx/html/index.html << HTMLEOF
<!DOCTYPE html>
<html>
<head>
  <title>ECS Node</title>
  <style>
    body { font-family: monospace; background: #1a1a2e; color: #e0e0e0;
           display: flex; justify-content: center; align-items: center;
           min-height: 100vh; margin: 0; }
    .box { background: #16213e; border: 2px solid #0f3460;
           padding: 2em; border-radius: 8px; min-width: 420px; }
    h1   { color: #e94560; margin-top: 0; }
    table { width: 100%; border-collapse: collapse; }
    td   { padding: 8px 4px; border-bottom: 1px solid #0f3460; }
    td:first-child { color: #888; width: 140px; }
    td:last-child  { color: #00d4ff; font-weight: bold; }
  </style>
</head>
<body>
  <div class="box">
    <h1>ECS Node Info</h1>
    <table>
      <tr><td>Instance ID</td>  <td>$INSTANCE_ID</td></tr>
      <tr><td>Private IP</td>   <td>$LOCAL_IP</td></tr>
      <tr><td>AZ</td>           <td>$AZ</td></tr>
      <tr><td>Container ID</td> <td>$CONTAINER</td></tr>
    </table>
  </div>
</body>
</html>
HTMLEOF

exec nginx -g "daemon off;"
