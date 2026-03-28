# Process — Meta Framework

*How we build, evaluate, and improve processes. This is the methodology for creating consistency.*
*v0.1*

## Purpose

A process is a repeatable sequence that produces a consistent outcome. This document defines what makes a good process, how to build one, and how to improve them over time. Individual processes live in their domain directories and follow this framework.

## The Core Principle

**If we do it more than twice, it becomes code.**

Not a guideline — a rule. Manual repetition is a bug. The graduation path:

| Stage | When | What It Looks Like |
|-------|------|-------------------|
| **Ad hoc** | First time doing something | Figure it out, take notes |
| **Documented** | Second time | Write the process following this framework |
| **Automated** | Third time | Convert deterministic steps to code. Process doc becomes the spec. |

Every manual step in a documented process is technical debt. Flag it, track it, automate it.

## What Makes a Good Process

**1. Trigger-defined**
It's unambiguous when the process applies. Not "when sending emails" but "when sending any outbound email from an official domain address."

**2. Deterministic where possible**
If a step doesn't require judgment, it's code. Humans (and AI) handle judgment. Machines handle repetition.

**3. Measurable outcome**
You can tell if it worked. Not "send email" but "email delivered, DKIM pass, logged in CRM, reply-monitoring active."

**4. Failure-aware**
Known failure modes are documented with mitigations. Every failure that occurs gets added. The process learns from its mistakes.

**5. Self-improving**
Every execution is an opportunity to update. Changelog is mandatory. If something went wrong, the process is updated BEFORE moving on to other work.

**6. Layered**
Top level is scannable in 10 seconds (trigger, steps, outcome). Detail is reachable but not forced. Think: summary -> steps -> deep reference.

**7. Standard-linked**
Each process references which standards (from STANDARDS.md) it enforces. This creates traceability: standard -> process -> code.

## Process Template

Every process document follows this structure:

```markdown
# [Process Name]
Domain: [email | deploy | content | research | ...]
Trigger: [When does this process apply?]
Owner: [Who/what executes — {agent}, cron, script name]
Standards: [Which standards from STANDARDS.md this enforces]

## Steps
1. [AUTOMATED | MANUAL] Step description
   -> Code: path/to/script.py or "needs automation"
2. ...

## Validation
How to confirm the process succeeded. Specific checks, not vibes.

## Known Failures
| Failure | Cause | Mitigation | Date Added |
|---------|-------|------------|------------|

## Changelog
- YYYY-MM-DD: What changed and why
```

## How to Evaluate a Process

When reviewing processes (weekly or after a failure), ask:

1. **Is every step necessary?** Remove anything that doesn't contribute to the outcome.
2. **Is any manual step automatable?** If yes, flag it for automation.
3. **Has it failed recently?** If yes, is the failure mode documented? Is the mitigation sufficient?
4. **Does it still match the standard?** Standards evolve. Processes must keep up.
5. **Is it being followed?** A process nobody uses is documentation, not a process. Either fix it or delete it.

## Process Hygiene

- **Daily:** After executing any process, update it if something was wrong or could be better.
- **Weekly:** Review the process index. Are any stale? Any manual steps ready for automation?
- **On failure:** Update the process FIRST. Before fixing the immediate problem, capture the lesson. Then fix.

## Anti-Patterns

**Process theater** — writing detailed processes nobody follows. If a process isn't being used, it's either wrong (fix it) or unnecessary (delete it).

**Over-documentation** — 50-step processes for simple tasks. If it's that complex, it should be a script with a one-line invocation.

**Frozen processes** — "we've always done it this way." Every process has a changelog for a reason. If it hasn't been updated in a month, it's either perfect or neglected. Probably neglected.

**Manual heroics** — knowing the "right way" to do something but not writing it down because it's faster to just do it. It's faster THIS time. It's slower every time after.

---

*This framework evolves. When we learn something about how we build processes, update it here.*

## Changelog
- v0.1: Initial framework.
