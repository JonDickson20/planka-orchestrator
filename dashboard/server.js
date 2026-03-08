const express = require('express');
const fs = require('fs');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 7700;

const PLANKA_DIR = path.resolve(__dirname, '..');
const STATUS_FILE = path.join(PLANKA_DIR, 'status.json');
const PROJECTS_DIR = path.join(PLANKA_DIR, 'projects');
const LOGS_DIR = path.join(PLANKA_DIR, 'logs');

const PLANKA_URL = 'https://planka.jondxn.com/api';
const PLANKA_EMAIL = 'jondickson20@gmail.com';
const PLANKA_PASSWORD = 'YL*ZKs9PvMR5PfQrWpiBHQLy';

let plankaToken = null;

async function getPlankaToken() {
  if (plankaToken) return plankaToken;
  const res = await fetch(`${PLANKA_URL}/access-tokens`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ emailOrUsername: PLANKA_EMAIL, password: PLANKA_PASSWORD })
  });
  const data = await res.json();
  plankaToken = data.item;
  return plankaToken;
}

async function plankaGet(path) {
  let token = await getPlankaToken();
  let res = await fetch(`${PLANKA_URL}${path}`, {
    headers: { 'Authorization': `Bearer ${token}` }
  });
  if (res.status === 401) {
    plankaToken = null;
    token = await getPlankaToken();
    res = await fetch(`${PLANKA_URL}${path}`, {
      headers: { 'Authorization': `Bearer ${token}` }
    });
  }
  return res.json();
}

// Serve static files
app.use(express.static(path.join(__dirname, 'public')));

// Orchestrator status
app.get('/api/status', (req, res) => {
  try {
    if (!fs.existsSync(STATUS_FILE)) {
      return res.json({ running: false, message: 'Orchestrator has not started yet' });
    }
    const raw = fs.readFileSync(STATUS_FILE, 'utf8');
    const status = JSON.parse(raw);
    const lastSeen = new Date(status.timestamp);
    const ageSeconds = (Date.now() - lastSeen.getTime()) / 1000;
    status.running = ageSeconds < (status.pollInterval || 30) * 3;
    status.ageSeconds = Math.round(ageSeconds);
    res.json(status);
  } catch (err) {
    res.json({ running: false, error: err.message });
  }
});

// Project configs
app.get('/api/projects', (req, res) => {
  try {
    const files = fs.readdirSync(PROJECTS_DIR).filter(f => f.endsWith('.json'));
    const projects = files.map(f => {
      const raw = fs.readFileSync(path.join(PROJECTS_DIR, f), 'utf8').replace(/^\uFEFF/, '');
      return JSON.parse(raw);
    });
    res.json(projects);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Board data from Planka (card counts per list)
app.get('/api/boards/:boardId', async (req, res) => {
  try {
    const data = await plankaGet(`/boards/${req.params.boardId}`);
    const cards = data.included?.cards || [];
    const lists = data.included?.lists || [];
    res.json({ cards, lists });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Recent logs
app.get('/api/logs', (req, res) => {
  try {
    if (!fs.existsSync(LOGS_DIR)) return res.json([]);
    const files = fs.readdirSync(LOGS_DIR)
      .filter(f => f.endsWith('.log'))
      .map(f => {
        const stat = fs.statSync(path.join(LOGS_DIR, f));
        return { name: f, size: stat.size, modified: stat.mtime };
      })
      .sort((a, b) => new Date(b.modified) - new Date(a.modified))
      .slice(0, 50);
    res.json(files);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Read a specific log
app.get('/api/logs/:filename', (req, res) => {
  try {
    const safeName = path.basename(req.params.filename);
    const filePath = path.join(LOGS_DIR, safeName);
    if (!fs.existsSync(filePath)) return res.status(404).json({ error: 'Not found' });
    const content = fs.readFileSync(filePath, 'utf8');
    res.type('text/plain').send(content);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.listen(PORT, () => {
  console.log(`Planka Dashboard running on http://localhost:${PORT}`);
});
