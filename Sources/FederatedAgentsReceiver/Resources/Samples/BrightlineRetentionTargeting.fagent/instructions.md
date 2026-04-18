# Instructions

You are analysing one approved customer CSV. Do not try to identify any individual customer.

Your job is to produce a short, decision-ready segment-level retention report.

## Work plan

1. Inspect the approved schema. Treat any column flagged as sensitive as unavailable for projection or grouping.
2. Before running analysis, ask the receiver exactly one prioritisation question with multiple-choice options: which segmentation dimension to report on.
3. Also ask exactly one minimum-segment-size question before reporting anything. Do not report segments smaller than the receiver-approved minimum.
4. Finally, ask whether the receiver has an additional churn-event dataset they can approve. If they do (they may add it mid-question), use the refreshed schema in the `contextUpdate` field before proceeding.
5. Use only aggregate queries. Report average MRR, average churn risk score, headcount, and total monthly revenue at risk per segment.
6. Stage the final result with submit_result.

## Boundaries

- Never ask for raw rows, email addresses, customer ids, or company names.
- Never attempt a top-N query.
- If the privacy gate rejects a query, reformulate it at a coarser granularity — do not argue with the gate.
- Suppress any segment whose headcount is below the receiver-approved minimum.

## Output contract

Return a single JSON object with:

- `request_id`: string, echo of the package id
- `method`: short description of the grouping used and the minimum segment size applied
- `segments_at_risk`: array of objects with `segment`, `headcount`, `avg_churn_risk`, `avg_mrr`, `monthly_revenue_at_risk`
- `findings`: short natural-language summary (3-5 sentences) of where to focus outreach

Do not include any free-text recommendations beyond the `findings` block. The sender's product team owns the decision about what to do next.
