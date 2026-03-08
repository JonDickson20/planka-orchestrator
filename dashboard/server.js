const express = require("express");
const fs = require("fs");
const path = require("path");
const https = require("https");

const app = express();
const PORT = process.env.DASHBOARD_PORT || 3333;

const ROOT_DIR = path.resolve(__dirname, "..");
const PROJECTS_DIR = path.join(ROOT_DIR, "projects");
const LOGS_DIR = path.join(ROOT_DIR, "logs");
const STATUS_FILE = path.join(ROOT_DIR, "status.json");

const PLANKA_URL = "https://planka.jondxn.com/api";
const PLANKA_EMAIL = "jondickson20@gmail.com";
const PLANKA_PASSWORD = "YL*ZKs9PvMR5PfQrWpiBHQLy";

let cachedToken = null;

function plankaRequest(method, apiPath, body) {
  return new Promise((resolve, reject) => {
    const url = new URL(PLANKA_URL + apiPath);
    const options = {
      hostname: url.hostname,
      port: 443,
      path: url.pathname,
      method,
      headers: { "Content-Type": "application/json" },
    };
    if (cachedToken) {
      options.headers["Authorization"] = `Bearer ${cachedToken}`;
    }
    const req = https.request(options, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => {
        try {
          resolve({ status: res.statusCode, data: JSON.parse(data) });
        } catch {
          resolve({ status: res.statusCode, data });
        }
      });
    });
    req.on("error", reject);
    req.setTimeout(15000, () => {
      req.destroy();
      reject(new Error("Request timed out"));
    });
    if (body) req.write(JSON.stringify(body));
    req.end();
  });
}

async function ensureToken() {
  if (cachedToken) return;
  const res = await plankaRequest("POST", "/access-tokens", {
    emailOrUsername: PLANKA_EMAIL,
    password: PLANKA_PASSWORD,
  });
  cachedToken = res.data.item;
}

async function plankaGet(apiPath) {
  await ensureToken();
  let res = await plankaRequest("GET", apiPath);
  if (res.status === 401) {
    cachedToken = null;
    await ensureToken();
    res = await plankaRequest("GET", apiPath);
  }
  return res.data;
}

function loadProjects() {
  const projects = [];
  try {
    const files = fs.readdirSync(PROJECTS_DIR).filter((f) => f.endsWith(".json"));
    for (const file of files) {
      const cfg = JSON.parse(fs.readFileSync(path.join(PROJECTS_DIR, file), "utf8"));
      projects.push(cfg);
    }
  } catch {}
  return projects;
}

function readStatusFile() {
  try {
    if (fs.existsSync(STATUS_FILE)) {
      return JSON.parse(fs.readFileSync(STATUS_FILE, "utf8"));
    }
  } catch {}
  return null;
}

function parseLogFiles() {
  const logs = [];
  try {
    const files = fs.readdirSync(LOGS_DIR).filter((f) => f.endsWith(".log"));
    for (const file of files) {
      const match = file.match(/^agent_(\d+)_(\d{8}-\d{6})\.log$/);
      if (!match) continue;
      const stat = fs.statSync(path.join(LOGS_DIR, file));
      const cardId = match[1];
      const timestamp = match[2];
      const year = timestamp.slice(0, 4);
      const month = timestamp.slice(4, 6);
      const day = timestamp.slice(6, 8);
      const hour = timestamp.slice(9, 11);
      const min = timestamp.slice(11, 13);
      const sec = timestamp.slice(13, 15);
      const startDate = new Date(`${year}-${month}-${day}T${hour}:${min}:${sec}`);
      logs.push({
        filename: file,
        cardId,
        startTime: startDate.toISOString(),
        size: stat.size,
        lastModified: stat.mtime.toISOString(),
      });
    }
    logs.sort((a, b) => new Date(b.startTime) - new Date(a.startTime));
  } catch {}
  return logs;
}

// Serve static files
app.use(express.static(path.join(__dirname, "public")));

// API: Overall status — uses status.json for active agents, log files for history
app.get("/api/status", (req, res) => {
  const status = readStatusFile();
  const logs = parseLogFiles();

  // Active agents from status.json (written by the orchestrator in real time)
  let active = [];
  if (status && status.activeJobs) {
    active = status.activeJobs.map((job) => ({
      projectName: job.projectName,
      cardId: job.cardId,
      startTime: job.startTime,
      elapsedMinutes: job.elapsedMinutes,
      logFile: job.logFile,
    }));
  }

  // Build set of active log files to exclude from recent
  const activeLogFiles = new Set(active.map((a) => a.logFile));

  // Recent = all logs not currently active, most recent first
  const recent = logs
    .filter((l) => !activeLogFiles.has(l.filename))
    .slice(0, 30);

  // Orchestrator metadata
  const orchestrator = status
    ? {
        startedAt: status.startedAt,
        lastUpdate: status.timestamp,
        pollInterval: status.pollInterval,
        agentTimeout: status.agentTimeout,
        maxWorkers: status.maxWorkers,
      }
    : null;

  res.json({ active, recent, orchestrator });
});

// API: Queue depth per project
app.get("/api/queue", async (req, res) => {
  const projects = loadProjects();
  const results = [];
  for (const project of projects) {
    try {
      const board = await plankaGet(`/boards/${project.boardId}`);
      const cards = board.included?.cards || [];
      const listNames = {
        [project.lists.fix]: "Fix",
        [project.lists.feature]: "Feature",
        [project.lists.working]: "Working",
        [project.lists.readyToReview]: "Ready to Review",
        [project.lists.complete]: "Complete",
        [project.lists.stuck]: "Stuck",
      };
      const counts = {};
      for (const [listId, name] of Object.entries(listNames)) {
        counts[name] = cards.filter((c) => c.listId === listId).length;
      }
      results.push({ name: project.name, counts });
    } catch (err) {
      results.push({ name: project.name, error: err.message });
    }
  }
  res.json(results);
});

// API: List log files
app.get("/api/logs", (req, res) => {
  const logs = parseLogFiles();
  res.json(logs);
});

// API: Read a specific log file (supports tail parameter)
app.get("/api/logs/:filename", (req, res) => {
  const filename = path.basename(req.params.filename);
  if (!/^agent_\d+_\d{8}-\d{6}\.log$/.test(filename)) {
    return res.status(400).json({ error: "Invalid log filename" });
  }
  const filepath = path.join(LOGS_DIR, filename);
  if (!fs.existsSync(filepath)) {
    return res.status(404).json({ error: "Log file not found" });
  }
  const content = fs.readFileSync(filepath, "utf8");
  // Optional: return only the last N lines
  const tail = parseInt(req.query.tail, 10);
  if (tail > 0) {
    const lines = content.split("\n");
    return res.type("text/plain").send(lines.slice(-tail).join("\n"));
  }
  res.type("text/plain").send(content);
});

app.listen(PORT, () => {
  console.log(`Dashboard running at http://localhost:${PORT}`);
});
