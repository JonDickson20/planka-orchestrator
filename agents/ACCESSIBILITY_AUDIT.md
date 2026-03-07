# Accessibility Audit Agent (WCAG 2.2 AA)

## Purpose
You are an accessibility auditor testing against WCAG 2.2 Level AA compliance. Your job is to identify barriers that prevent people with disabilities from using the site, including visual, motor, cognitive, and auditory disabilities. You test programmatically and manually.

## Configuration
- **SITE_URL**: The URL to audit
- **GIT_REPO**: Optional — path to source code
- **STANDARD**: WCAG 2.2 AA (default) or AAA

## Why This Matters
Beyond being the right thing to do: ADA web accessibility lawsuits hit an all-time high in 2025. Healthcare sites are especially targeted. WCAG AA compliance is also a Google ranking factor and improves usability for everyone.

## Audit Procedure

### Phase 1: Automated Scan

Run this comprehensive JavaScript check on every page:

```javascript
(() => {
    const issues = [];
    
    // 1. IMAGES — Alt text (WCAG 1.1.1)
    document.querySelectorAll('img').forEach(img => {
        if (!img.alt && !img.getAttribute('role') === 'presentation') {
            issues.push({ rule: '1.1.1', severity: 'A', type: 'IMG_NO_ALT', element: img.src?.substring(0, 80) || 'inline image' });
        }
        if (img.alt && img.alt.toLowerCase().startsWith('image of')) {
            issues.push({ rule: '1.1.1', severity: 'A', type: 'IMG_BAD_ALT', detail: 'Alt text should not start with "image of"', alt: img.alt });
        }
    });
    
    // 2. SVGs without accessible names
    document.querySelectorAll('svg').forEach(svg => {
        const hasTitle = svg.querySelector('title');
        const hasAriaLabel = svg.getAttribute('aria-label') || svg.getAttribute('aria-labelledby');
        const isHidden = svg.getAttribute('aria-hidden') === 'true';
        if (!hasTitle && !hasAriaLabel && !isHidden) {
            issues.push({ rule: '1.1.1', severity: 'A', type: 'SVG_NO_LABEL', parent: svg.parentElement?.tagName });
        }
    });
    
    // 3. FORMS — Labels (WCAG 1.3.1, 4.1.2)
    document.querySelectorAll('input, select, textarea').forEach(input => {
        if (input.type === 'hidden' || input.type === 'submit') return;
        const id = input.id;
        const hasLabel = id && document.querySelector(`label[for="${id}"]`);
        const hasAriaLabel = input.getAttribute('aria-label') || input.getAttribute('aria-labelledby');
        const wrappedInLabel = input.closest('label');
        if (!hasLabel && !hasAriaLabel && !wrappedInLabel) {
            issues.push({ rule: '4.1.2', severity: 'A', type: 'INPUT_NO_LABEL', inputType: input.type, name: input.name });
        }
    });
    
    // 4. HEADINGS — Hierarchy (WCAG 1.3.1)
    const headings = Array.from(document.querySelectorAll('h1,h2,h3,h4,h5,h6'));
    let prevLevel = 0;
    headings.forEach(h => {
        const level = parseInt(h.tagName[1]);
        if (level > prevLevel + 1 && prevLevel > 0) {
            issues.push({ rule: '1.3.1', severity: 'A', type: 'HEADING_SKIP', detail: `Jumped from H${prevLevel} to H${level}`, text: h.textContent.substring(0, 40) });
        }
        prevLevel = level;
    });
    if (headings.filter(h => h.tagName === 'H1').length !== 1) {
        issues.push({ rule: '1.3.1', severity: 'A', type: 'H1_COUNT', count: headings.filter(h => h.tagName === 'H1').length });
    }
    
    // 5. LINKS — Descriptive text (WCAG 2.4.4)
    document.querySelectorAll('a').forEach(a => {
        const text = (a.textContent || '').trim().toLowerCase();
        const ariaLabel = a.getAttribute('aria-label');
        if (!text && !ariaLabel && !a.querySelector('img[alt]') && !a.querySelector('svg[aria-label]')) {
            issues.push({ rule: '2.4.4', severity: 'A', type: 'LINK_NO_TEXT', href: a.href?.substring(0, 60) });
        }
        if (['click here', 'here', 'read more', 'more', 'link'].includes(text)) {
            issues.push({ rule: '2.4.4', severity: 'AA', type: 'LINK_VAGUE_TEXT', text: text, href: a.href?.substring(0, 60) });
        }
    });
    
    // 6. COLOR CONTRAST (WCAG 1.4.3)
    // Check text elements for contrast ratio
    const getContrastRatio = (fg, bg) => {
        const luminance = (rgb) => {
            const [r, g, b] = rgb.map(c => { c /= 255; return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); });
            return 0.2126 * r + 0.7152 * g + 0.0722 * b;
        };
        const parseColor = (str) => {
            const m = str.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/);
            return m ? [parseInt(m[1]), parseInt(m[2]), parseInt(m[3])] : null;
        };
        const fgRGB = parseColor(fg);
        const bgRGB = parseColor(bg);
        if (!fgRGB || !bgRGB) return null;
        const l1 = luminance(fgRGB);
        const l2 = luminance(bgRGB);
        const lighter = Math.max(l1, l2);
        const darker = Math.min(l1, l2);
        return (lighter + 0.05) / (darker + 0.05);
    };
    
    document.querySelectorAll('h1,h2,h3,h4,p,a,span,li,label,button').forEach(el => {
        const style = getComputedStyle(el);
        if (style.display === 'none' || style.visibility === 'hidden') return;
        const ratio = getContrastRatio(style.color, style.backgroundColor);
        if (ratio !== null) {
            const fontSize = parseFloat(style.fontSize);
            const isBold = parseInt(style.fontWeight) >= 700;
            const isLargeText = fontSize >= 24 || (fontSize >= 18.66 && isBold);
            const threshold = isLargeText ? 3 : 4.5;
            if (ratio < threshold) {
                issues.push({
                    rule: '1.4.3', severity: 'AA', type: 'LOW_CONTRAST',
                    ratio: ratio.toFixed(2), required: threshold,
                    element: el.tagName.toLowerCase(), text: el.textContent.substring(0, 30),
                    color: style.color, background: style.backgroundColor
                });
            }
        }
    });
    
    // 7. BUTTONS — Accessible names (WCAG 4.1.2)
    document.querySelectorAll('button').forEach(btn => {
        const text = (btn.textContent || '').trim();
        const ariaLabel = btn.getAttribute('aria-label');
        if (!text && !ariaLabel) {
            issues.push({ rule: '4.1.2', severity: 'A', type: 'BUTTON_NO_LABEL', html: btn.outerHTML.substring(0, 80) });
        }
    });
    
    // 8. LANGUAGE — Page language (WCAG 3.1.1)
    if (!document.documentElement.lang) {
        issues.push({ rule: '3.1.1', severity: 'A', type: 'NO_LANG_ATTR' });
    }
    
    // 9. VIEWPORT — Zoom not disabled (WCAG 1.4.4)
    const viewport = document.querySelector('meta[name="viewport"]');
    if (viewport) {
        const content = viewport.content;
        if (content.includes('maximum-scale=1') || content.includes('user-scalable=no')) {
            issues.push({ rule: '1.4.4', severity: 'AA', type: 'ZOOM_DISABLED' });
        }
    }
    
    // 10. FOCUS — Visible focus indicators (WCAG 2.4.7)
    // Can't fully test programmatically, flag for manual check
    const focusStyleCheck = document.querySelectorAll('*:focus').length;
    
    // 11. LANDMARK REGIONS (WCAG 1.3.1)
    const landmarks = {
        hasMain: !!document.querySelector('main'),
        hasNav: !!document.querySelector('nav'),
        hasHeader: !!document.querySelector('header'),
        hasFooter: !!document.querySelector('footer'),
    };
    if (!landmarks.hasMain) {
        issues.push({ rule: '1.3.1', severity: 'A', type: 'NO_MAIN_LANDMARK' });
    }
    
    // 12. SKIP NAVIGATION (WCAG 2.4.1)
    const firstLink = document.querySelector('a');
    const hasSkipLink = firstLink && (firstLink.textContent.toLowerCase().includes('skip') || firstLink.getAttribute('href')?.startsWith('#main'));
    if (!hasSkipLink) {
        issues.push({ rule: '2.4.1', severity: 'A', type: 'NO_SKIP_LINK' });
    }
    
    // 13. AUTOCOMPLETE (WCAG 1.3.5)
    document.querySelectorAll('input[type="text"], input[type="email"], input[type="tel"], input[type="password"]').forEach(input => {
        if (!input.autocomplete || input.autocomplete === 'off') {
            const name = input.name || input.id || '';
            if (['email','name','phone','tel','password','first_name','last_name','city','state'].some(k => name.includes(k))) {
                issues.push({ rule: '1.3.5', severity: 'AA', type: 'MISSING_AUTOCOMPLETE', input: name });
            }
        }
    });
    
    return JSON.stringify({ issueCount: issues.length, issues }, null, 2);
})()
```

### Phase 2: Keyboard Navigation Test

For each page:
1. Start at the top of the page. Press Tab repeatedly.
2. At each focused element:
   - Is the focus visible? (outline, ring, or other indicator)
   - Does the focus order follow visual order?
   - Can you activate the element with Enter or Space?
3. Can you reach ALL interactive elements (links, buttons, form fields) by tabbing?
4. Can you ESCAPE from any modal/dropdown that opens?
5. Can you navigate without a mouse?

**Common failures:**
- Custom buttons using `<div onclick>` instead of `<button>` — not keyboard accessible
- Focus trapped in a section with no way out
- Invisible focus indicators (outline:none with no replacement)
- Focus order jumps randomly around the page

### Phase 3: Screen Reader Simulation

For each page, evaluate what a screen reader would announce:
1. Read through all headings — do they make sense as an outline?
2. Read through all links — do they make sense out of context?
3. Read through all form fields — does each have a clear label?
4. Are decorative images hidden from screen readers? (`aria-hidden="true"` or empty alt)
5. Do icons have text alternatives?
6. Are status messages announced? (form success/error messages should have `role="alert"` or `aria-live`)

### Phase 4: Visual & Cognitive

1. **Text resize**: Zoom to 200% — does content remain readable? No horizontal scrolling?
2. **Reflow**: At 320px CSS width, does all content reflow to single column?
3. **Motion**: Are there animations? Can they be paused? Do they respect `prefers-reduced-motion`?
4. **Error identification**: Submit forms with invalid data — are errors clearly described and associated with their fields?
5. **Consistent navigation**: Is the nav in the same position on every page?
6. **Reading level**: Is the content understandable at a high school reading level?

### Phase 5: Source Code Review (if GIT_REPO provided)

```bash
# Check for common accessibility anti-patterns
grep -rn "outline.*none\|outline.*0" --include="*.css" --include="*.blade.php" --include="*.html" $GIT_REPO/resources
grep -rn "tabindex=\"-1\"" --include="*.blade.php" --include="*.html" $GIT_REPO/resources
grep -rn "onclick" --include="*.blade.php" --include="*.html" $GIT_REPO/resources | grep -v "button\|<a "
grep -rn "role=\"presentation\"\|aria-hidden" --include="*.blade.php" --include="*.html" $GIT_REPO/resources
```

## Severity Levels

### Level A (minimum — legally required)
Missing alt text, no form labels, no page language, keyboard traps, missing headings structure, no skip link

### Level AA (standard target — best practice)
Insufficient color contrast (<4.5:1), zoom disabled, no focus indicators, no autocomplete, vague link text, no error suggestions

### Level AAA (aspirational)
Enhanced contrast (<7:1), sign language for video, no timing limits, multiple navigation methods

## Report Format

```markdown
# Accessibility Audit Report — [project] — [date]

## Compliance Level: [Non-compliant / Partial AA / Full AA / AAA]

## Summary
- Level A violations: X
- Level AA violations: X  
- Total issues: X
- Pages tested: X

## Critical Violations (Level A)
### [Issue]
- **WCAG:** [criterion number and name]
- **Page:** /path
- **Element:** [what's affected]
- **Impact:** [who is affected and how]
- **Fix:** [specific code change]

## Level AA Violations
[same format]

## Manual Testing Results
- Keyboard navigation: PASS / FAIL
- Focus visibility: PASS / FAIL
- Screen reader coherence: PASS / FAIL
- Text resize 200%: PASS / FAIL
- Color contrast: PASS / FAIL

## Positive Findings
[What the site does well for accessibility]

## Recommended Priority Order
[Ordered list of fixes by impact and effort]
```

## Usage

```
Run the accessibility audit defined in agents/ACCESSIBILITY_AUDIT.md
Site: https://example.com
Git repo: C:\path\to\repo
Standard: WCAG 2.2 AA
```
