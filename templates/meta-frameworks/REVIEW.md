# Review — Meta Framework

*Continuously improve — measure, learn, adjust. Good today is the floor for tomorrow.*
*v0.1*

## Purpose

This document defines how we step back, evaluate, and improve the whole system. Not individual process improvements (that's PROCESS.md) — the macro view. Are we getting better? Are we working on the right things? Is the system itself working?

## Core Principle

**What you don't measure, you can't improve. What you don't review, you don't measure.** Review is not optional overhead. It's the mechanism that turns activity into progress.

## Review Cadence

### Daily — End of Day Wrap
*5 minutes. Done every session that involves meaningful work.*

1. **What happened today?** Update `memory/YYYY-MM-DD.md`
2. **Update the INDEX** — anything new? Anything moved?
3. **Update MINI INDEX** — what does tomorrow's session need to know?
4. **Any standard violated?** If yes, update the standard/process FIRST
5. **Any process used that could be improved?** Note it in the process changelog

### Weekly — Strategy Review
*30 minutes. Non-negotiable.*

1. **Constraint check** — is the constraint the same? Has it moved? Evidence?
2. **Priority review** — did we work on the right 3 things? What actually got done?
3. **Metrics update** — update the Pulse in domain strategy files with real numbers
4. **Process audit** — any MANUAL standards ready for automation?
5. **Index restructure** — clean stale entries, update locations, verify accuracy
6. **Meta framework review** — are STRATEGY/PROCESS/STANDARDS/SECURITY/LEARNING still serving us? Any updates needed?
7. **Open questions** — any resolved? Any new ones emerged?

Output: Updated strategy files, cleaned index, list of next week's priorities.

### Monthly — Honest Assessment
*1 hour. First of the month.*

1. **Zoom out** — are we working on the right thing entirely? Not just "are we executing well" but "should we be executing this at all?"
2. **Trajectory** — plot the metrics over time. Up, down, flat? Why?
3. **Knowledge gaps** — what did we hit this month that we weren't prepared for? Update LEARNING.md domains table.
4. **System health** — are the meta frameworks being used? Are they helping? What's friction?
5. **Adversarial review** — argue against our current plan. What would a smart skeptic say?
6. **{user} sync** — present findings, get pushback, realign if needed.

Output: Monthly assessment document in `memory/reviews/YYYY-MM.md`

### After Major Milestones
*Whenever something significant ships, fails, or changes.*

1. **What worked?** — specifically, not vaguely. Which processes, which decisions?
2. **What didn't?** — specifically. What would we do differently?
3. **What surprised us?** — things we didn't expect. These are the most valuable learnings.
4. **What should change?** — update frameworks, processes, standards based on learnings.

## What to Measure

### Leading Indicators (We Control)
- Emails sent / deliverability rate
- Content published / engagement rate
- Pages indexed / search impressions
- Features shipped / bugs introduced
- Processes automated / manual steps remaining

### Lagging Indicators (We Influence)
- Revenue / MRR
- Inbound inquiries
- Organic traffic
- Conversion rate (visitor -> signup -> paying)
- Customer retention

### System Health Indicators
- Standards compliance rate (how often do we violate our own standards?)
- Process coverage (what % of repeated actions have documented processes?)
- Automation rate (how many standards are automated vs. manual?)
- Stale state (how old is the oldest unreviewed item?)
- Context efficiency (are we loading what we need, not more?)

## The Retrospective Format

For any review that produces a written output:

```markdown
## [Period/Event] Review

### What Worked
- ...

### What Didn't
- ...

### What We Learned
- ...

### What Changes
- [Framework/file]: [specific change]
- ...

### Next Period Focus
- Priority 1:
- Priority 2:
- Priority 3:
```

## Anti-Patterns

**Review theater** — going through the motions without honest assessment. If every review says "things are going well," something is wrong.

**Data-free reviews** — "I feel like we're making progress" without numbers. Feelings are signals, not evidence. Pull the metrics.

**Review without action** — identifying problems but not changing anything. Every review must produce at least one concrete change, or it was a waste.

**Skipping reviews when busy** — this is exactly when reviews matter most. Being busy without reviewing is how you stay busy doing the wrong things.

**Solo reviews** — {agent} reviewing {agent} is a closed loop. The weekly review should surface findings to {user} for challenge and pushback.

---

*This framework evolves. When we learn something about how we review and improve, update it here.*

## Changelog
- v0.1: Initial framework.
