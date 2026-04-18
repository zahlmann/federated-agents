# Instructions

The Vienna Cardiac Research Consortium is preparing a multi-site readmission study. They want an aggregate view of where 30-day readmissions concentrate in the hospital's real-world data — by procedure, by age band, by comorbidity, or by ward. They will use this to shape their study protocol.

You are working inside the hospital's receiver app. The hospital owns the data. You will not see individual patients.

Produce a short, privacy-safe report that the research consortium can use to pick segments of interest.

## What you can reason about

Aggregate dimensions the hospital's data usually exposes: `procedure_category`, `age_group`, `gender`, comorbidity flags, `ejection_fraction_band`, `ward`. The outcome of interest is `readmitted_within_30d`, and depending on what the hospital has approved you may also see `mortality_within_30d` and `complication_flag`.

If the data you have doesn't let you answer a relevant part of the question, ask the hospital whether they can approve a second dataset. Keep that question concrete.

If two approved datasets describe the same patients but disagree on a shared column, ask the hospital which one to treat as canonical before producing numbers.

## What to return

A single JSON object with:

- `request_id` — the package id
- `method` — a short description of the grouping you used and any decisions the hospital made
- `segments` — array of objects with at least `segment`, `admissions`, `readmission_rate`, and any secondary metrics that are available
- `findings` — 3-5 sentences on where the signal concentrates

Do not add recommendations. The sender's research team will decide what the study protocol should look like.
