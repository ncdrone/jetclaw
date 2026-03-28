# Strategy — Meta Framework

*How we think strategically. This is the methodology, not the plan.*
*v0.1*

## Purpose

This document defines how we identify what matters, make decisions, and allocate effort. It applies universally — any product, any project, any domain. Specific strategies inherit this framework and live in their own files.

## Constraint Theory

At any point in time, there is **one bottleneck** limiting progress. Everything upstream of the bottleneck is excess capacity. Everything downstream is starved.

**How to find the constraint:**
1. Map the pipeline end-to-end (awareness -> interest -> action -> revenue, or whatever the relevant flow is)
2. Measure each stage. The narrowest point is the constraint.
3. If you can't measure, ask: "If I magically doubled output at this stage, would the system produce more?" If yes, it's likely the constraint.

**Rules:**
- Work on the constraint first. Other work is justified only if it's zero-cost or directly supports the constraint.
- When the constraint moves (because you resolved it), find the new one. Don't keep optimizing the old one.
- Revisit the constraint assessment weekly, or after any major change.

## Decision Framework

**Threshold:** 70% confidence is enough to act. Perfect information doesn't exist. Waiting for it is a decision to do nothing.

**Evaluation criteria (in order):**
1. Does this move the constraint?
2. What's the speed to impact? (Days, not months)
3. What's the downside if we're wrong? (Reversible vs irreversible)
4. What's the second and third order effect?

**When to say no:**
- It doesn't connect to the constraint and isn't zero-cost
- The downside is irreversible and confidence is below 70%
- It's interesting but not important (the hardest no)

## Prioritization

- Maximum **3 priorities** at any time. If everything is a priority, nothing is.
- Each priority must connect to the current constraint. If it doesn't, justify why it's an exception.
- Priorities are ordered. #1 gets resources before #2. Always.
- Review priorities weekly. They can change — but changing daily means you don't have priorities, you have reactions.

## Challenge Protocol

Good strategy requires disagreement.

**{agent} challenges {user} when:**
- The requested work doesn't connect to the constraint
- Data contradicts the assumption behind a decision
- There's a higher-leverage alternative
- Something is being built that should be validated first

**Format:** "Here's what I think the constraint is. Here's why this doesn't move it. Here's what would. Your call."

**{user} challenges {agent} when:**
- {agent} is optimizing for output instead of outcome
- {agent} is building instead of validating
- {agent} is playing it safe instead of having a position
- Something feels off even without data (intuition counts)

**Resolution:** Discuss. Decide. Move. Don't relitigate — log the decision and revisit at the next review.

## Measurement

**Track leading indicators, not lagging ones.**
- Lagging: revenue, followers, pageviews (outcomes you can't directly control)
- Leading: emails sent, conversations started, pages indexed, features shipped (inputs you control)

**Avoid vanity metrics.** A long list of skills and tools is a vanity metric if nobody uses them. 1 paying customer is a real metric.

**Close the feedback loop.** Every action should have a measurable outcome. If you can't measure whether it worked, define how you will before you start.

## Adversarial Thinking

Always ask:
- What if we're wrong about the constraint?
- What would someone who disagrees say?
- What's the evidence against our current plan?
- Are we building because we should or because we can?

Run adversarial thinking explicitly, not just when it feels right. Build it into weekly reviews.

## Review Cadence

| Frequency | What | Output |
|-----------|------|--------|
| Daily | Update index, check constraint still valid | Context refresh |
| Weekly | Full strategy review, index restructure | Updated priorities, cleaned files |
| After major milestones | Reassess constraint, evaluate what worked | Strategy pivot or stay-the-course decision |
| Monthly | Zoom out — are we working on the right thing entirely? | Honest assessment |

---

*This framework evolves. When we learn something about how we make decisions, update it here.*

## Changelog
- v0.1: Initial framework.
