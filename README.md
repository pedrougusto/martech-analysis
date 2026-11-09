# 📡 Martech Analysis — Attribution & Patient Journey Measurement

> **End-to-end BigQuery SQL toolkit for patient lifecycle classification, multi-touch attribution, channel cannibalization and conversion funnels in a large healthcare diagnostics company.**

🇺🇸 English | [🇧🇷 Português](README.pt-br.md)

---

## Overview

This repository gathers the SQL layer behind the marketing measurement of a multi-brand healthcare diagnostics company (Brazil). It answers three questions that standard last-click reports cannot:

1. **Who is the patient right now?** New, recurring, inactive, churned or recovered — computed month by month.
2. **Which channel actually deserves credit for the revenue?** A data-driven multi-touch model benchmarked against last booking.
3. **Is paid media generating incremental revenue or just capturing demand that would arrive anyway?** Journey sequencing, cannibalization and LIFT.

> 🔒 All project, dataset, brand and campaign names were anonymized (`analytics-project`, `company-bi-prd`, `MARCA_01`…). No data is included — only the query logic.

---

## Business Problem

Marketing teams in multi-brand healthcare usually look at each channel in isolation and credit revenue to the last touch before booking. This creates three blind spots:

| Blind spot | Consequence | How this repo addresses it |
|---|---|---|
| Static patient label | A patient who returns after 2 years is counted as "new" and inflates acquisition KPIs | Monthly rolling-window classification (`01`) |
| Last-click attribution | CRM and upper-funnel channels look worthless | Data-driven multi-touch attribution with CRM as its own entity (`02`, `03`) |
| No incrementality view | Paid search gets credit for patients who were already coming via direct traffic | Journey sequencing with `LEAD`, cannibalization and LIFT factors (`04`–`06`) |

---

## Architecture

```
 Appointments / Bookings (DW)        GA4 export + App sessions        Patient MDM (CPF)
             │                                  │                             │
             ▼                                  ▼                             │
 ┌──────────────────────────┐        ┌───────────────────────┐                │
 │ 01 Temporal patient      │        │ Touchpoints by channel │◄──────────────┘
 │    classification (loop) │        │ / subchannel / campaign│
 └────────────┬─────────────┘        └───────────┬───────────┘
              │                                  │
              ▼                                  ▼
 ┌──────────────────────────────────────────────────────────┐
 │ 02 Unified attribution table (data-driven vs last AGD)    │
 └────────────┬──────────────────────────────────────────────┘
              ▼
 ┌──────────────────────────┐   ┌───────────────────────────────┐   ┌──────────────────────────┐
 │ 03 Dashboard view        │   │ 04–06 Journey combinations,    │   │ 07–09 Funnels: site → app │
 │    (touch order, steps)  │   │ cannibalization & LIFT         │   │ → booking → revenue       │
 └──────────────────────────┘   └───────────────────────────────┘   └──────────────────────────┘
```

The classification table produced by `01` is also the base of the companion project [**ltv-patient**](https://github.com/pedrougusto/ltv-patient) (cohorts, LTV curves, CAC × LTV).

---

## SQL Files

| # | File | What it does | Key techniques |
|---|---|---|---|
| 01 | `01_patient_temporal_classification.sql` | Monthly loop (2019 → today) classifying each patient as new / recurring / inactive / churned / recovered across 5 dimensions in a 24-month window | BigQuery scripting (`DECLARE`, `WHILE`), temp tables, conditional aggregation |
| 02 | `02_attribution_unified_table.sql` | Unifies appointments, bookings and digital touchpoints and computes **data-driven** vs **last booking** attribution, with CRM as an analytical entity | `efficiency × proximity` weight normalized per appointment (`peso_normalizado`) |
| 03 | `03_attribution_final_view_dashboard.sql` | Dashboard-ready view: touch order (top 5), step by touch position, revenue by step, days to conversion | Conditional aggregation, window function, view for BI |
| 04 | `04_journey_combinations_origin_time_lag.sql` | Multi-channel journey combinations within a 48h window and time lag between steps | `LEAD`, journey sequencing, single-journey guard |
| 05 | `05_journey_combinations_revenue_lift.sql` | Same journeys enriched with revenue, products and age group, applying LIFT factors to estimate incremental revenue | Incrementality factors, financial + clinical view |
| 06 | `06_cannibalization_campaign_mapping.sql` | Did the patient book on step 1 (e.g. direct) before clicking paid search on step 2? Maps cannibalized campaigns and hours | Intra-journey cross-check, booking timestamp vs click |
| 07 | `07_funnel_brand_site_to_app.sql` | Paid campaign → brand site → app onboarding → booking steps → revenue | Fan-out deduplication, exam → booking granularity reconciliation |
| 08 | `08_funnel_app_onboarding_to_revenue.sql` | Paid campaigns landing directly in the app: onboarding funnel to revenue | Session as base grain, booking ↔ session bridge |
| 09 | `09_paid_search_post_login_analysis.sql` | How much paid search traffic comes from patients who are already registered (logged in before or same day)? | Cross-device identity resolution (`user_pseudo_id` **or** CPF) |

---

## Key Technical Highlights

- **Procedural SQL backfill:** one script rebuilds the full monthly history, so the classification is auditable and reproducible.
- **Grain discipline:** every funnel explicitly reconciles granularity (exam → booking → session) to avoid fan-out revenue inflation.
- **Identity resolution:** patients are matched across logged-out and logged-in sessions and devices through MDM, not only cookies.
- **Incrementality over attribution:** LIFT factors separate *attributed* revenue from *incremental* revenue.

---

## Stack

| Layer | Technology |
|---|---|
| Data Warehouse | Google BigQuery |
| Transformation | BigQuery Standard SQL + Procedural SQL (scripting) |
| Web / App Analytics | GA4 → BigQuery export |
| Identity | Patient MDM (CPF-based) |
| Visualization | Looker Studio / Looker |

---

## Repository Structure

```
martech-analysis/
├── sql/
│   ├── 01_patient_temporal_classification.sql
│   ├── 02_attribution_unified_table.sql
│   ├── 03_attribution_final_view_dashboard.sql
│   ├── 04_journey_combinations_origin_time_lag.sql
│   ├── 05_journey_combinations_revenue_lift.sql
│   ├── 06_cannibalization_campaign_mapping.sql
│   ├── 07_funnel_brand_site_to_app.sql
│   ├── 08_funnel_app_onboarding_to_revenue.sql
│   └── 09_paid_search_post_login_analysis.sql
├── LICENSE
├── README.md
└── README.pt-br.md
```

---

## So What?

- **Business impact:** credit moves from "whoever was last" to the channels that actually build the journey, and paid media budget stops paying for demand that would arrive organically.
- **Recommended action:** use `01` as the single source of truth for patient status, review budget by channel using data-driven attribution, and monitor cannibalized campaigns (`06`) before scaling paid search.

---

## About

Built by **Pedro Augusto** — Analytics Engineer focused on Marketing Analytics, MarTech and Growth.
SQL comments are in Portuguese (original working language); documentation is bilingual.
