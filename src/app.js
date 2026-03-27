'use strict';
const http = require('http');
const os   = require('os');
const fs   = require('fs');
const path = require('path');

const PORT      = process.env.PORT      || 3000;
const DATA_FILE = process.env.DATA_FILE || path.join(__dirname, 'records.json');

// ---------------------------------------------------------------------------
// EC2 instance metadata (IMDSv2)
// ---------------------------------------------------------------------------
async function imds(token, p) {
  try {
    const res = await fetch(`http://169.254.169.254/latest/meta-data/${p}`, {
      headers: { 'X-aws-ec2-metadata-token': token },
      signal: AbortSignal.timeout(2000),
    });
    return await res.text();
  } catch {
    return 'unknown';
  }
}

async function getInfo() {
  try {
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
    return { instanceId, localIp, az, amiId, containerId: require('os').hostname() };
  } catch {
    return { instanceId: 'unknown', localIp: 'unknown', az: 'unknown', amiId: 'unknown', containerId: require('os').hostname() };
  }
}

// ---------------------------------------------------------------------------
// Flat-file record store
// ---------------------------------------------------------------------------
function readRecords() {
  try {
    return JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'));
  } catch {
    return [];
  }
}

function appendRecord(record) {
  const records = readRecords();
  const entry = { name: record.name, city: record.city, company: record.company, savedAt: new Date().toISOString() };
  records.push(entry);
  fs.writeFileSync(DATA_FILE, JSON.stringify(records, null, 2));
  return entry;
}

// ---------------------------------------------------------------------------
// Request body helper
// ---------------------------------------------------------------------------
function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      try { resolve(JSON.parse(body)); }
      catch { reject(new Error('Invalid JSON')); }
    });
    req.on('error', reject);
  });
}

// ---------------------------------------------------------------------------
// HTTP server
// ---------------------------------------------------------------------------
const server = http.createServer(async (req, res) => {
  res.setHeader('Connection', 'close');
  const url = req.url.split('?')[0];

  // GET / — serve frontend
  if (req.method === 'GET' && url === '/') {
    try {
      const html = fs.readFileSync(path.join(__dirname, 'public', 'index.html'), 'utf8');
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end(html);
    } catch {
      res.writeHead(500);
      res.end('Could not load index.html');
    }
    return;
  }

  // GET /api/info — node metadata
  if (req.method === 'GET' && url === '/api/info') {
    const info = await getInfo();
    res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    res.end(JSON.stringify(info));
    return;
  }

  // GET /api/records — all records
  if (req.method === 'GET' && url === '/api/records') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(readRecords()));
    return;
  }

  // POST /api/records — add a record
  if (req.method === 'POST' && url === '/api/records') {
    try {
      const body = await readBody(req);
      const { name, city, company } = body;
      if (!name || !city || !company) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'name, city and company are required' }));
        return;
      }
      const entry = appendRecord({ name, city, company });
      res.writeHead(201, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(entry));
    } catch {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Invalid request body' }));
    }
    return;
  }

  res.writeHead(404);
  res.end('Not found');
});

server.listen(PORT, () => {
  console.log(`Listening on port ${PORT}`);
  console.log(`Data file: ${DATA_FILE}`);
});
