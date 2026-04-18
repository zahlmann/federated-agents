# Purpose

The Vienna Cardiac Research Consortium is planning a multi-site study on 30-day readmission after cardiac interventions. Before writing the protocol, the consortium needs a privacy-safe view of where readmissions cluster in real-world hospital data: which procedure categories, which comorbidity profiles, which age bands.

The receiver is a hospital that holds the patient-level records for the last 18 months of cardiac admissions. The hospital's data governance forbids sharing any row-level, identifying, or near-identifying information with the research group.

What the sender wants is the **shape** of the problem, not the **who**: aggregated readmission rates per segment, with a minimum segment size decided by the hospital.

This decision matters because an under-powered study is a wasted year of staff time, and an over-specified study can re-identify people. The hospital's choices about granularity are therefore part of the research design, not a roadblock.
