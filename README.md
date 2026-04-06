# CloudMeter

macOS menu bar app for tracking GCP billing spend at a glance. Pure AppKit, zero dependencies, single-file Swift.

## Features

- **Menu bar** — Cloud icon + yesterday's spend (AUD), always visible
- **7-day stacked bar chart** — Per-service cost breakdown with click-to-drill into any day
- **Service breakdown** — Colored dots, inline cost bars, % change vs prior period
- **SKU drill-down** — Click any service to see SKU-level detail (lazy-loaded from BigQuery)
- **Project filter** — Dropdown with per-project yesterday + 7-day costs, filter all views
- **Header metrics** — Month-to-date, rolling 7-day total, EOM forecast, burn rate, credits/discounts
- **Budget tracking** — Progress bar with green/amber/red thresholds, configurable monthly budget
- **Exec Report** — One-click CFO/CTO analysis via Claude Code headless (styled HTML output)
- **Smart refresh** — 2x daily (7am + 1pm) by default, manual refresh button, configurable
- **Notifications** — Budget threshold alerts via macOS native notifications

## Requirements

- macOS 14+
- `gcloud` CLI authenticated (`gcloud auth login`)
- BigQuery billing export enabled in your GCP project

## Setup

```bash
# Authenticate with GCP
gcloud auth login

# Clone and build
git clone https://github.com/clintoncodewell/cloudmeter.git
cd cloudmeter
bash build.sh

# Edit config with your GCP details
open ~/.config/cloudmeter/config.json
```

Update `config.json` with your project ID and billing export table:

```json
{
  "projectId": "your-gcp-project-id",
  "datasetId": "gcp_billing_export",
  "tableId": "gcp_billing_export_v1_XXXXXX_XXXXXX_XXXXXX"
}
```

Find your table name:
```bash
bq ls your-project-id:gcp_billing_export
```

## Run

```bash
open CloudMeter.app
```

## Architecture

- **Single file** — `main.swift` (~1900 lines), compiled with `swiftc`
- **Pure AppKit** — No SwiftUI, no Xcode, no storyboards
- **Zero dependencies** — All native macOS APIs (NSStatusItem, NSPopover, URLSession, Core Graphics)
- **Frame-based layout** — Manual coordinate positioning, no AutoLayout
- **System colors** — Automatic light/dark mode support
- **Auth** — Three-tier: ADC refresh token -> gcloud credentials DB -> gcloud CLI fallback

## Exec Report

Click "Exec Report" in the footer to generate a CFO/CTO weekly billing analysis:

1. Queries BigQuery for 4 comprehensive datasets (daily/project/service, SKU detail, monthly comparison, 14-day trend)
2. Pipes data to Claude Code headless (`claude -p`) with a dual CFO/CTO advisor prompt
3. Generates styled dark-theme HTML report with 9 sections
4. Auto-opens in browser, saved to `~/CloudMeter/reports/`

Requires `claude` CLI installed and authenticated via OAuth.

## Config

Stored at `~/.config/cloudmeter/config.json`:

| Key | Default | Description |
|-----|---------|-------------|
| `projectId` | — | GCP project containing the billing export |
| `datasetId` | `gcp_billing_export` | BigQuery dataset name |
| `tableId` | — | Billing export table name |
| `refreshMin` | `0` | Refresh mode: `0` = 2x daily, `60` = hourly, `-1` = manual |
| `displayMode` | `yesterday` | Menu bar shows: `yesterday`, `mtd`, or `burn` |
| `monthlyBudget` | `0` | Monthly budget in AUD (0 = disabled) |
| `alertPct` | `80` | Alert at this % of budget |
| `enableAlerts` | `false` | Enable budget notifications |

## Files

```
cloudmeter/
  main.swift          — Complete app source
  build.sh            — Build script (swiftc -> .app bundle)
  exec-report.sh      — Exec report generator (BQ queries + Claude)
  .gitignore
  README.md
```

## Cost

BigQuery queries cost ~$0.006 per refresh (well within the free 1TB/month tier). At 2x daily refresh, expect ~$0.00/month in BQ costs.
