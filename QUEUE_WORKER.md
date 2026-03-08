# Queue Worker Protocol

This document defines the operating procedure for AI agents working as queue workers on a Planka board. It is **project-agnostic** — all project-specific settings are loaded from a config file at runtime.

## Planka Credentials

**Bot accounts** (each agent type has its own identity -- password for all bots: `Planka4Bots2026`):

| Bot | Username | Used By |
|-----|----------|---------|
| Worker Bot | `worker_bot` | Fix/Feature work agents |
| Deploy Bot | `deploy_bot` | Deploy agents |
| Idea Bot | `idea_bot` | Feature idea generation |
| SEO Bot | `seo_bot` | SEO-perspective ideas |
| Marketing Bot | `marketing_bot` | Marketing-perspective ideas |
| Security Bot | `security_bot` | Security-perspective ideas |
| Accessibility Bot | `a11y_bot` | Accessibility-perspective ideas |
| Performance Bot | `perf_bot` | Performance-perspective ideas |
| Visual QA Bot | `visualqa_bot` | Visual QA-perspective ideas |

Agents receive their credentials in the prompt from the orchestrator. Use whatever credentials are specified in YOUR prompt -- do not default to the admin account.

### Authentication

Planka uses JWT tokens. Obtain one via:

```
POST /api/access-tokens
Body: {"emailOrUsername":"<username>","password":"<password>"}
Response: {"item":"<jwt_token>"}
```

All subsequent requests require: `Authorization: Bearer <jwt_token>`

## Planka API Reference

Base URL: `https://planka.jondxn.com/api`

| Action | Method | Endpoint |
|--------|--------|----------|
| Get board (with lists & cards) | GET | `/boards/{boardId}` |
| Get card (with comments) | GET | `/cards/{cardId}` |
| Create a list | POST | `/boards/{boardId}/lists` (body: `{name, position, type:"active"}`) |
| Create a card | POST | `/lists/{listId}/cards` (body: `{name, description, position, type:"project"}`) |
| Update a card (move to list) | PATCH | `/cards/{cardId}` (body: `{listId, position}`) |
| Add comment to card | POST | `/cards/{cardId}/comments` (body: `{text}`) |
| Delete a card | DELETE | `/cards/{cardId}` |

> **Note:** When using PowerShell, use `Invoke-WebRequest` with `-UseBasicParsing` and `-ContentType "application/json"` for POST/PATCH requests. `Invoke-RestMethod` may hang on this host.

## Board Structure

Every project board **must** have the following lists. The list IDs are defined in the project's config file (`projects/<project>.json`).

| List | Purpose |
|------|---------|
| **Trash** | Rejected ideas — moved here instead of deleted, freeing space in Ideas |
| **Ideas** | Brainstorming / wish list — NOT picked up automatically |
| **Fix** | Bug fix queue — work these FIRST |
| **Feature** | Feature request queue — work these AFTER all Fix cards are done |
| **Working** | Card is actively being worked on by an agent |
| **Ready to Review** | Work is complete on a branch, awaiting human review |
| **Complete** | Human has approved the work — triggers merge and deploy |
| **Stuck** | Card is blocked, agent failed, or agent timed out |
| **Deployed** | Card has been merged and deployed — final resting state |

> **Priority Rule:** Always drain ALL cards from "Fix" before touching any "Feature" cards.
> **Ideas list:** Cards in "Ideas" are never auto-claimed. They are manually promoted to Fix or Feature by a human when ready to be worked.

## Project Config Files

Each project has a JSON config file at `projects/<project-name>.json` with this structure:

```json
{
  "name": "My Project",
  "boardId": "123456789",
  "workspace": "C:\\path\\to\\project\\repo",
  "localDevUrl": "http://127.0.0.1:8000",
  "subdomain": "my-app",
  "deployMethod": "git-push-main",
  "deployNotes": "Pushing to main triggers auto-deploy.",
  "lists": {
    "trash": "<list-id>",
    "ideas": "<list-id>",
    "fix": "<list-id>",
    "feature": "<list-id>",
    "working": "<list-id>",
    "readyToReview": "<list-id>",
    "complete": "<list-id>",
    "stuck": "<list-id>",
    "deployed": "<list-id>"
  }
}
```

### Config Fields

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Human-readable project name (shown in logs) |
| `boardId` | Yes | Planka board ID |
| `workspace` | Yes | Absolute path to the git repo root on disk |
| `localDevUrl` | No | URL of the local dev server for testing (if applicable) |
| `subdomain` | No | Docker Compose service name / subdomain (e.g., `vero`). When set, deploy agents will rebuild the Docker container after merging to update the live site at `<subdomain>.jondxn.com`. |
| `deployMethod` | Yes | One of: `git-push-main` (push to main triggers deploy), `manual` (human deploys), `script` (run a deploy script) |
| `deployNotes` | No | Freeform notes about how deployment works for this project |
| `lists` | Yes | Map of list names to Planka list IDs |

## Git Workflow

The git repository lives at the path specified in `workspace`. Deployment behavior is defined by `deployMethod` in the config.

### Branch-Per-Card Strategy

Each card gets its own branch. This keeps changes isolated and prevents conflicts between workers.

```
Branch naming convention:
  fix/{card-short-name}      — for Fix cards
  feature/{card-short-name}  — for Feature cards

Examples:
  fix/photo-uploads
  fix/button-overflow
  feature/better-uploads
```

### Rules

1. **Never commit directly to `main`.** All work happens on a card branch.
2. **One branch = one card = one unit of work.** Do not combine multiple cards into one branch.
3. **Always `git pull origin main` before creating a new branch** to ensure you start from the latest code.
4. **Keep commits clean.** Use a single descriptive commit message per card (squash if needed). Format: `[fix] Short description` or `[feature] Short description`.
5. **Push the branch** to `origin` when moving the card to "Ready to Review" so the reviewer can inspect it on GitHub.

## Worker Lifecycle

### Step 1 — Claim a Card

The orchestrator (`planka_poll.ps1`) handles claiming:
1. It polls each project board every 30 seconds.
2. It selects cards from Fix (priority) then Feature.
3. It moves the card to "Working" before spawning the agent.
4. **Worktree isolation** — each work agent gets an isolated git worktree, allowing multiple agents per project simultaneously. Deploy agents still use the main workspace with per-project locking.
5. The card is already in "Working" when your agent starts.

### Step 2 — Plan

1. Read the card's **name**, **description**, and **comments** thoroughly. Context may be split across all three — the description might be empty with all details in the comments, or vice versa. If only a title is provided, work from that.
2. Read the project's **CLAUDE.md** (included in your prompt if it exists) for coding conventions and architecture.
3. Research the relevant files in the codebase at the project's `workspace` path.
4. Write an implementation plan.
5. **Post the plan as a comment** on the card via `POST /api/cards/{cardId}/comments` with body `{"text":"..."}`.

### Step 3 — Execute

1. **Pull latest main:** `git pull origin main`
2. **Create a card branch:** `git checkout -b fix/{card-name}` or `git checkout -b feature/{card-name}`
3. Implement the changes described in your plan.
4. Follow existing code patterns and conventions in the project (see CLAUDE.md if provided).
5. Do not introduce unnecessary dependencies.
6. **Commit your work:** `git add -A && git commit -m "[fix] Description"` (or `[feature]`).

### Step 4 — QA / Verify

1. **Test your changes** as a QA tester would.
2. If the project config has a `localDevUrl`, browse to the affected pages/features in the browser.
3. Check for visual correctness, functionality, and edge cases.
4. If you find issues, fix them, amend your commit, and re-verify.
5. Ensure no errors in the console or server logs.

### Step 5 — Ship to Review

1. **Push the branch:** `git push origin fix/{card-name}` (or `feature/...`).
2. **Move the card** to **"Ready to Review"**: `PATCH /api/cards/{cardId}` with body `{"listId":"<readyToReview-list-id>","position":1}`.
3. **Add a final comment** to the card summarizing what was done, the branch name, and any notes for the reviewer. **Always include a GitHub review link** if the project has a GitHub remote. The link format is: `https://github.com/{owner}/{repo}/compare/main...{branch-name}`. Get the remote URL via `git remote get-url origin` and construct the compare URL from it. This lets the reviewer jump straight to the diff.
4. **Switch back to main:** `git checkout main`

### Step 6 — Exit

After completing a card, exit cleanly (exit code 0). The orchestrator will detect the successful exit and spawn a new agent for the next available card.

If you encounter an unrecoverable error, exit with a non-zero exit code. The orchestrator will move the card to "Stuck" and attach your log output as a comment.

## Deployment

When a human reviewer moves a card from "Ready to Review" to **"Complete"**, the orchestrator picks it up and spawns a deploy agent.

The deploy agent receives the **branch name** directly in its prompt (extracted from the card's comments by the orchestrator).

### Core Steps (all deploy methods)

1. `git checkout main`
2. `git pull origin main`
3. `git merge {branch-name} --no-ff -m "Merge {branch-name}: {card title}"`
4. `git push origin main`
5. `git branch -d {branch-name}` -- clean up local branch.
6. `git push origin --delete {branch-name}` -- clean up remote branch.

### Docker Rebuild (if `subdomain` is set)

If the project config has a `subdomain` field, the deploy agent also rebuilds the Docker container so the live site updates:

```
cd C:\Users\JonDi\Desktop\Hosting
docker compose up -d --build {subdomain}
docker compose ps {subdomain}   # verify container is running
```

This updates the app at `{subdomain}.jondxn.com` with the latest code from main.

### Cloudflare Cache Purge

After a Docker rebuild, Cloudflare's edge cache may still serve stale static assets (JS, CSS, etc.). The deploy prompt includes a cache purge step that runs `Hosting/purge-cache.ps1`. **Always run it.**

Two layers of protection ensure deploys are reflected on the live site:

1. **Cache purge script** — If `Hosting/cloudflare.json` has a valid API token, it purges the Cloudflare edge cache immediately. Takes effect in seconds.
2. **`s-maxage=60` header** — Caddy sets this on all responses (unless the app sets its own `Cache-Control`). This tells Cloudflare's edge to expire cached content after 60 seconds, regardless of dashboard settings. Even if the purge script fails or has no token, the site updates within 1 minute.

The orchestrator also runs a backup purge when the deploy agent finishes successfully.

### Final Steps

7. **Add a comment** to the card summarizing what was merged and deployed.
8. **Move the card** to **"Deployed"**.

## Orchestrator Features

The polling script (`planka_poll.ps1`) is a **persistent orchestrator** that runs continuously:

1. **Never exits** — it runs in an infinite loop with a configurable poll interval.
2. **Multi-project** — scans all config files in `projects/` and polls each board.
3. **Worktree isolation** — each work agent (fix/feature) gets an isolated git worktree, enabling multiple agents per project. Deploy agents still use the main workspace with per-project locking.
4. **Spawns Claude Code agents** — when a card is found, it spawns `claude -p "..."` as a background process.
5. **Tracks active workers** — maintains a map of card IDs to running processes, cleans up finished ones.
6. **Enforces concurrency** — max workers configurable (default 2).
7. **Agent timeout** — kills agents that exceed the configured time limit (default 30 min), moves their card to Stuck.
8. **Failure recovery** — agents that exit with non-zero codes have their cards moved to Stuck with log output attached.
9. **Output logging** — all agent stdout/stderr is captured to `logs/agent_{cardId}_{timestamp}.log`.
10. **CLAUDE.md injection** — includes the project's CLAUDE.md in the agent prompt for coding conventions.
11. **Branch name injection** — for deploy actions, extracts the branch name from card comments and passes it directly.
12. **Token caching** — authenticates once and re-auths only on 401 errors, not every poll cycle.
13. **Temp file cleanup** — removes prompt files after agents finish.
14. **Priority order** — Complete (deploy) → Fix (work) → Feature (work, only if no Fix cards exist) → Ideas replenishment (lowest).
15. **Hot-reload** — project configs are re-read each poll cycle, so you can add new projects without restarting.
16. **Idea generation** — when a project's Ideas list drops below 10 cards, spawns an idea generation agent that explores the codebase and creates new idea cards. Generates feature ideas to reach the minimum, plus 1 additional idea from each specialist agent perspective (SEO, Marketing, Performance, Security, Accessibility, Visual QA).
17. **Auto-deploy** — when a project has a `subdomain` configured, deploy agents rebuild the Docker container after merging to update the live site.

### Running It

```powershell
powershell -ExecutionPolicy Bypass -File planka_poll.ps1
```

### Adding a New Project

1. Create a new board on Planka with the required lists (Trash, Ideas, Fix, Feature, Working, Ready to Review, Complete, Stuck, Deployed).
2. Copy the list IDs from the Planka UI or API.
3. Create a JSON config file in `projects/<project-name>.json` following the schema above.
4. The orchestrator will pick it up on the next poll cycle — no restart needed.

## Important Notes

- When using PowerShell to call the Planka API, `Invoke-WebRequest -UseBasicParsing` is more reliable than `Invoke-RestMethod` for this host (Cloudflare). Always include `-TimeoutSec 30`.
- Card descriptions often contain URLs — these reference the production deployment. Replicate the issue locally using the project's `localDevUrl` if available.
- Always test changes against the local dev server before marking a card as done.
- Follow existing code patterns and conventions found in each project's codebase and CLAUDE.md.
- Cards in the "Ideas" list are never auto-picked. A human must promote them to Fix or Feature.
- Agent logs are stored in `logs/` and include timestamps for debugging failed or timed-out runs.
- **Cloudflare caching:** Caddy sets `Cache-Control: max-age=60` on responses so Cloudflare's edge cache expires quickly after deploys. If `cloudflare.json` in the Hosting directory has a valid API token, deploy agents will also purge the Cloudflare cache programmatically after Docker rebuilds.
