# Visual QA Agent — Automated Design Audit

## Purpose
You are a visual QA agent. Your job is to crawl a website, take screenshots at multiple viewport sizes, and identify visual defects that a human designer would immediately notice.

## Configuration
Set these before running:
- **SITE_URL**: The URL to test (e.g. `https://hospital-staffing-partners-main-rb5dn0.laravel.cloud`)
- **PROJECT_NAME**: For report naming (e.g. `hsp`)
- **PAGES**: List of paths to test (defaults to core pages below)
- **GIT_REPO**: Optional — path to the git repo to check recently changed views

## What You're Looking For

### CRITICAL defects (must fix immediately):
1. **Horizontal overflow** — Content extends past the right edge of the viewport, creating a horizontal scrollbar or a visible white/blank strip. Test with `document.documentElement.scrollWidth > document.documentElement.clientWidth`.
2. **Element overlap** — Elements visually overlap each other UNLESS intentionally layered (dropdowns, modals, tooltips, fixed navbars). Stat cards overlapping, text over images, buttons over buttons, sections bleeding into each other.
3. **Text truncation / clipping** — Text cut off by its container, especially on mobile. Buttons with text that doesn't fit. Headlines overflowing containers.
4. **Broken layouts** — Columns side-by-side that have stacked incorrectly. Grid items with wildly inconsistent heights. Flexbox wrapping wrong.
5. **Invisible or unreachable elements** — Buttons/links off-screen, hidden behind other elements, or positioned outside the viewport.

### IMPORTANT defects (should fix soon):
6. **Excessive whitespace** — Large empty gaps (>150px) between sections that look unintentional.
7. **Inconsistent spacing** — Sections with visibly different padding/margins from adjacent sections for no design reason.
8. **Touch target issues** (mobile) — Interactive elements smaller than 44x44px or closer than 8px apart.
9. **Font rendering issues** — FOUT, missing web fonts falling back to system fonts, text too small on mobile (<12px).
10. **Color contrast** — Text hard to read against its background.

### What is NOT a defect:
- Fixed/sticky navbars overlapping page content (intentional)
- Dropdown/flyout menus overlapping when open (intentional)
- Modal overlays covering the page (intentional)
- Decorative elements with subtle overlap (offset shadows, badges)
- Responsive layout changes between breakpoints (columns stacking on mobile is expected)

## Testing Procedure

### Step 1: Identify pages to test
If GIT_REPO is set, check recently changed views:
```bash
cd $GIT_REPO && git log --name-only --pretty=format: -10 | grep "\.blade\.php\|\.html\|\.vue\|\.jsx" | sort -u
```
Always test the core pages provided in the PAGES list.

### Step 2: For each page, test at THREE viewport sizes
1. **Desktop**: 1440 x 900
2. **Tablet**: 768 x 1024
3. **Mobile**: 375 x 812

### Step 3: At each viewport, perform these checks

#### A. Screenshot and visual inspection
1. Resize the browser window to the target viewport
2. Navigate to the page
3. Wait for load, then take a screenshot
4. Visually inspect for ANY defects listed above
5. Scroll down the page, taking screenshots every viewport-height
6. Check each screenshot for overlap, overflow, and layout issues

#### B. Programmatic overflow check
Run this JavaScript on every page at every viewport:
```javascript
(() => {
    const issues = [];
    
    // Check horizontal overflow
    if (document.documentElement.scrollWidth > document.documentElement.clientWidth) {
        issues.push({
            type: 'HORIZONTAL_OVERFLOW',
            severity: 'CRITICAL',
            scrollWidth: document.documentElement.scrollWidth,
            clientWidth: document.documentElement.clientWidth,
            overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth
        });
    }
    
    // Find elements extending beyond viewport
    document.querySelectorAll('*').forEach(el => {
        const rect = el.getBoundingClientRect();
        if (rect.width > 0 && rect.right > window.innerWidth + 5) {
            const tag = el.tagName.toLowerCase();
            const cls = el.className?.toString().substring(0, 60) || '';
            if (!['script','style','meta','link','head'].includes(tag)) {
                issues.push({
                    type: 'ELEMENT_OVERFLOWS_VIEWPORT',
                    severity: 'CRITICAL',
                    element: `<${tag} class="${cls}">`,
                    right: Math.round(rect.right),
                    viewportWidth: window.innerWidth,
                    overflow: Math.round(rect.right - window.innerWidth)
                });
            }
        }
    });
    
    // Check for overlapping sibling elements (non-positioned)
    const checkOverlap = (parent) => {
        const children = Array.from(parent.children).filter(el => {
            const style = getComputedStyle(el);
            return style.display !== 'none' 
                && style.visibility !== 'hidden'
                && style.position !== 'fixed'
                && style.position !== 'absolute'
                && el.getBoundingClientRect().height > 0;
        });
        
        for (let i = 0; i < children.length; i++) {
            for (let j = i + 1; j < children.length; j++) {
                const a = children[i].getBoundingClientRect();
                const b = children[j].getBoundingClientRect();
                
                const overlapX = Math.max(0, Math.min(a.right, b.right) - Math.max(a.left, b.left));
                const overlapY = Math.max(0, Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top));
                
                if (overlapX > 2 && overlapY > 2) {
                    issues.push({
                        type: 'SIBLING_OVERLAP',
                        severity: 'CRITICAL',
                        elementA: `<${children[i].tagName.toLowerCase()} class="${children[i].className?.toString().substring(0, 40) || ''}">`,
                        elementB: `<${children[j].tagName.toLowerCase()} class="${children[j].className?.toString().substring(0, 40) || ''}">`,
                        overlapArea: `${Math.round(overlapX)}x${Math.round(overlapY)}px`
                    });
                }
            }
        }
    };
    
    // Check all layout containers
    document.querySelectorAll('section, main, form, [class*="grid"], [class*="flex"], [class*="row"], [class*="col"], [class*="card"], [class*="stat"], [class*="hero"]').forEach(checkOverlap);
    
    // Check for text overflow/clipping
    document.querySelectorAll('h1, h2, h3, h4, p, a, button, span, li, label').forEach(el => {
        if (el.scrollWidth > el.clientWidth + 5 && getComputedStyle(el).overflow !== 'hidden' && getComputedStyle(el).textOverflow !== 'ellipsis') {
            issues.push({
                type: 'TEXT_OVERFLOW',
                severity: 'IMPORTANT',
                element: `<${el.tagName.toLowerCase()}>`,
                text: el.textContent.substring(0, 50),
                scrollWidth: el.scrollWidth,
                clientWidth: el.clientWidth
            });
        }
    });
    
    return JSON.stringify(issues, null, 2);
})()
```

#### C. Interactive element testing
1. If there's a hamburger menu (mobile), click it and screenshot — verify no overflow
2. If there are hover states, hover over key elements and screenshot
3. If there are forms, check field sizing and label alignment
4. Tab through interactive elements to verify focus order

### Step 4: Generate report

Create `VISUAL_QA_REPORT.md`:

```markdown
# Visual QA Report — [project] — [date]

## Summary
- Pages tested: X
- Viewports tested: X
- Critical issues: X
- Important issues: X
- Pages clean: X

## Critical Issues

### [Issue title]
- **Page:** /path
- **Viewport:** 375x812 (mobile)
- **Type:** HORIZONTAL_OVERFLOW | ELEMENT_OVERLAP | TEXT_CLIPPING | BROKEN_LAYOUT
- **Description:** What's wrong
- **Location:** Where on the page
- **Suggested fix:** CSS/HTML change needed

## Important Issues
[same format]

## Clean Pages
[list]
```

### Step 5: Auto-fix if confident

If you identify a CRITICAL issue and the fix is straightforward CSS (overflow:hidden, removing a transform, fixing a width), apply the fix directly. Commit with:
```
[visual-qa] Fix: [brief description]
```

If the fix requires HTML restructuring, log it and do NOT attempt it.

## Usage

Full audit:
```
Run the visual QA audit defined in agents/VISUAL_QA.md. 
Site: https://example.com
Pages: /, /about, /contact, /register
```

Quick check after a commit:
```
Run a quick visual QA on pages changed in the last commit.
Site: https://example.com
Git repo: C:\path\to\repo
Desktop and mobile only.
```

## Common Gotchas
- `transform: translate()` moves elements visually but doesn't affect layout flow — grid/flex siblings will overlap the translated element
- `position: relative` with offsets has the same problem
- `overflow-x: hidden` on `body` alone doesn't prevent horizontal scroll on some mobile browsers — also needs to be on `html`
- Pseudo-elements (`::before`, `::after`) with negative positioning (`right: -10%`) can extend past viewport
- Fixed-width elements inside flex/grid containers can overflow on narrow viewports
- Google Fonts loaded externally can cause FOUT if `font-display` isn't set
- `min-height: 100vh` on desktop creates huge gaps if content is short
