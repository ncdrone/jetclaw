# Standards — Meta Framework

*What excellence looks like. The bar we hold ourselves to.*
*v0.1*

## Purpose

Standards define the minimum quality for any category of work. They're measurable, enforceable, and non-negotiable. When a standard isn't met, work isn't done — regardless of time pressure.

This document defines the universal standards framework. Domain-specific standards live in their domain directories and inherit from this framework.

## What Makes a Good Standard

1. **Measurable** — you can verify it objectively. "Good quality" is not a standard. "DKIM pass, inbox delivery" is.
2. **Binary** — met or not met. No "mostly meets the standard."
3. **Enforced** — either by code (preferred) or by process. An unenforced standard is a suggestion.
4. **Justified** — each standard exists for a reason. Document why. If you can't justify it, remove it.
5. **Evolving** — standards ratchet up. When we learn a new failure mode, the standard gets tighter. They never loosen.

## Enforcement Levels

| Level | Meaning | Example |
|-------|---------|---------|
| AUTOMATED | Code enforces this. Cannot be violated. | send_email() always includes --account flag |
| PROCESS | Documented process covers this. Requires discipline. | Check inbox delivery on first send of new campaign |
| MANUAL | No enforcement. Relies on remembering. | This is tech debt. Automate or add to process. |

**Goal: Move everything toward AUTOMATED.** Every MANUAL standard is a future mistake waiting to happen.

## Standard Template

For each domain, standards follow this structure:

```markdown
## [Domain]

| Standard | Why | Enforcement | Ref |
|----------|-----|-------------|-----|
| [What] | [Why it matters] | AUTOMATED/PROCESS/MANUAL | [Code or process path] |
```

## Universal Standards

These apply to everything, always:

### Communication
| Standard | Why | Enforcement |
|----------|-----|-------------|
| No sycophancy | Wastes time, erodes trust | PROCESS (SOUL.md) |
| State uncertainty explicitly | False confidence is worse than admitting "I don't know" | PROCESS (SOUL.md) |
| Verify before reporting | Don't report something as broken without testing it | MANUAL -> needs process |

### Code
| Standard | Why | Enforcement |
|----------|-----|-------------|
| No hardcoded values that change | Config drift, inconsistency | PROCESS |
| Commits are scoped and descriptive | Traceability, rollback clarity | MANUAL |
| Test after changing | Catch breakage before it ships | MANUAL |

### Verification
| Standard | Why | Enforcement |
|----------|-----|-------------|
| End-to-end verification before shipping | "Looks right in UI" is not verification. Actual output must match intent. | AUTOMATED (dry-run endpoint) |
| Trace full lifecycle for features | A feature touches DB -> API -> UI -> Action. ALL must be updated. | PROCESS |
| Dry-run before real actions | For any irreversible action (post, send, delete), show what will happen first | AUTOMATED (dry-run endpoints) |
| Verify assets exist before publishing | Path in DB means nothing if file doesn't exist | AUTOMATED (dry-run checks) |

### Knowledge
| Standard | Why | Enforcement |
|----------|-----|-------------|
| Read the relevant skill before acting | Skills exist to prevent known mistakes | MANUAL -> needs process |
| Update process/standard on failure | The system improves, not just the person | PROCESS |
| Don't carry stale state | Outdated info causes wrong decisions | PROCESS (index hygiene) |

### Deployment
| Standard | Why | Enforcement |
|----------|-----|-------------|
| Test app starts before switching service manager | Catch path/config errors before breaking prod | MANUAL |
| Check port availability before service restart | Stale processes cause crash loops | MANUAL |
| Map repo structure before git operations | Avoid worktree/branch confusion, wasted time | MANUAL |
| Search for existing docs before planning | Don't rediscover what's already documented | MANUAL |

**Pre-flight checklist before service switch:**
```bash
# 1. Test app can import/start
cd /new/directory && python3 -c "import api"

# 2. Check port is free
lsof -i :PORT  # should be empty or show the OLD process

# 3. Stop old service first
sudo systemctl stop old-service

# 4. Then start new
sudo systemctl start new-service
```

## The Ratchet Principle

Standards only go up. When something fails:

1. Identify what standard would have prevented it
2. If no standard exists, create one
3. If the standard exists but wasn't enforced, upgrade the enforcement level
4. Document the failure as the justification

Example: Email alignment failure
- Standard created: "All email sends use --account matching the DKIM domain"
- Enforcement: AUTOMATED (hardcoded in send_email() function)
- This standard can never be weakened. It can only be made stricter.

## Review Cadence

| Frequency | Action |
|-----------|--------|
| On failure | Add or tighten the relevant standard immediately |
| Weekly | Review MANUAL standards — any ready for automation? |
| Monthly | Are standards actually being met? Audit a random sample. |

---

*This framework evolves. When we learn something about quality, update it here.*

## Changelog
- v0.1: Initial framework.
