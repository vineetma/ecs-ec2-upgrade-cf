'use strict';
const http = require('http');
const os   = require('os');

const PORT = process.env.PORT || 3000;

// Fetch a single EC2 IMDSv2 metadata path. Returns 'unknown' on any error.
async function imds(token, path) {
  try {
    const res = await fetch(`http://169.254.169.254/latest/meta-data/${path}`, {
      headers: { 'X-aws-ec2-metadata-token': token },
      signal: AbortSignal.timeout(2000),
    });
    return await res.text();
  } catch {
    return 'unknown';
  }
}

async function getMetadata() {
  try {
    // IMDSv2 requires a session token before reading metadata
    const tokenRes = await fetch('http://169.254.169.254/latest/api/token', {
      method: 'PUT',
      headers: { 'X-aws-ec2-metadata-token-ttl-seconds': '21600' },
      signal: AbortSignal.timeout(2000),
    });
    const token = await tokenRes.text();

    const [instanceId, localIp, az, amiId] = await Promise.all([
      imds(token, 'instance-id'),
      imds(token, 'local-ipv4'),
      imds(token, 'placement/availability-zone'),
      imds(token, 'ami-id'),
    ]);

    return { instanceId, localIp, az, amiId };
  } catch {
    return { instanceId: 'unknown', localIp: 'unknown', az: 'unknown', amiId: 'unknown' };
  }
}

const server = http.createServer(async (req, res) => {
  if (req.url !== '/') {
    res.writeHead(404);
    res.end('Not found');
    return;
  }

  const { instanceId, localIp, az, amiId } = await getMetadata();
  const containerId = os.hostname();

  const html = `<!DOCTYPE html>
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
      <tr><td>Instance ID</td>  <td>${instanceId}</td></tr>
      <tr><td>Private IP</td>   <td>${localIp}</td></tr>
      <tr><td>AZ</td>           <td>${az}</td></tr>
      <tr><td>AMI ID</td>       <td>${amiId}</td></tr>
      <tr><td>Container ID</td> <td>${containerId}</td></tr>
    </table>
  </div>
</body>
</html>`;

  res.writeHead(200, { 'Content-Type': 'text/html' });
  res.end(html);
});

server.listen(PORT, () => {
  console.log(`Listening on port ${PORT}`);
});
