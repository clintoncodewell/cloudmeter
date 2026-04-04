#!/bin/bash
set -e

# =====================================================================
#  CloudMeter Exec Report — CFO/CTO Weekly Billing Analysis
#  Queries BigQuery, pipes to Claude Code headless for analysis
#  Output: styled HTML report opened in browser
# =====================================================================

CONFIG="$HOME/.config/cloudmeter/config.json"
if [ ! -f "$CONFIG" ]; then echo "No config found at $CONFIG"; exit 1; fi

PROJECT=$(python3 -c "import json; print(json.load(open('$CONFIG'))['projectId'])")
DATASET=$(python3 -c "import json; print(json.load(open('$CONFIG'))['datasetId'])")
TABLE=$(python3 -c "import json; print(json.load(open('$CONFIG'))['tableId'])")
FQT="\`${PROJECT}.${DATASET}.${TABLE}\`"

REPORT_DIR="$HOME/CloudMeter/reports"
mkdir -p "$REPORT_DIR"
DATE=$(date +%Y-%m-%d)
REPORT="$REPORT_DIR/exec-report-${DATE}.html"

echo "[1/3] Querying BigQuery for detailed billing data..."

# Query 1: Daily service breakdown by project (7 days)
DAILY=$(bq query --use_legacy_sql=false --format=csv --max_rows=1000 "
SELECT
  DATE(usage_start_time) AS date,
  project.id AS project,
  service.description AS service,
  ROUND(SUM(cost),2) AS cost,
  ROUND(SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c),0)),2) AS credits,
  ROUND(SUM(cost)+SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c),0)),2) AS subtotal
FROM ${FQT}
WHERE DATE(usage_start_time) >= DATE_SUB(CURRENT_DATE(), INTERVAL 8 DAY)
GROUP BY date, project, service
HAVING subtotal > 0.01
ORDER BY date DESC, subtotal DESC
" 2>/dev/null)

# Query 2: SKU-level detail for top services (7 days)
SKUS=$(bq query --use_legacy_sql=false --format=csv --max_rows=500 "
SELECT
  service.description AS service,
  sku.description AS sku,
  ROUND(SUM(cost)+SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c),0)),2) AS subtotal_7d,
  COUNT(DISTINCT DATE(usage_start_time)) AS active_days
FROM ${FQT}
WHERE DATE(usage_start_time) >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
GROUP BY service, sku
HAVING subtotal_7d > 0.10
ORDER BY subtotal_7d DESC
" 2>/dev/null)

# Query 3: Monthly comparison (3 months)
MONTHLY=$(bq query --use_legacy_sql=false --format=csv "
SELECT
  FORMAT_DATE('%Y-%m', DATE(usage_start_time)) AS month,
  ROUND(SUM(cost),2) AS cost,
  ROUND(SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c),0)),2) AS credits,
  ROUND(SUM(cost)+SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c),0)),2) AS subtotal
FROM ${FQT}
WHERE DATE(usage_start_time) >= DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 2 MONTH), MONTH)
GROUP BY month ORDER BY month
" 2>/dev/null)

# Query 4: Daily totals for trend line (14 days)
TREND=$(bq query --use_legacy_sql=false --format=csv "
SELECT
  DATE(usage_start_time) AS date,
  ROUND(SUM(cost)+SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c),0)),2) AS subtotal,
  ROUND(SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c),0)),2) AS credits
FROM ${FQT}
WHERE DATE(usage_start_time) >= DATE_SUB(CURRENT_DATE(), INTERVAL 14 DAY)
GROUP BY date ORDER BY date
" 2>/dev/null)

echo "[2/3] Generating executive report with Claude..."

# Write prompt to temp file to avoid shell escaping issues
PROMPT_FILE=$(mktemp /tmp/cloudmeter-prompt.XXXXXX)
cat > "$PROMPT_FILE" <<PROMPTEOF
You are a dual CFO/CTO advisor preparing a weekly cloud infrastructure spend report for the CEO. You combine:

**CFO lens**: Cost optimization, budget variance, burn rate, ROI, financial risk, savings programs
**CTO lens**: Infrastructure efficiency, architectural implications, service scaling patterns, technical debt signals, capacity planning

The company runs on GCP. All costs are in AUD. Today's date is ${DATE}.

## Raw Billing Data

### Daily Service Breakdown by Project (Last 7 Days)
\`\`\`csv
${DAILY}
\`\`\`

### SKU-Level Detail (7-Day Totals, >A\$0.10)
\`\`\`csv
${SKUS}
\`\`\`

### Monthly Comparison
\`\`\`csv
${MONTHLY}
\`\`\`

### Daily Trend (14 Days)
\`\`\`csv
${TREND}
\`\`\`

## Output Format

Generate a COMPLETE, standalone HTML file. The HTML must:
- Be a single self-contained file (inline CSS, no external dependencies)
- Use a clean, professional dark theme (dark background #1a1a2e, light text)
- Use a system font stack (SF Pro, -apple-system, sans-serif)
- Have proper responsive layout (max-width 900px, centered)
- Style tables with alternating row colors, proper padding, right-aligned numbers
- Use color coding: green for savings/decreases, red for increases/alerts, blue for info
- Include the CloudMeter logo text at the top

## Report Sections (include ALL of these):

### 1. Executive Summary
3 sentences max. Total 7-day spend, trend direction, one key insight.

### 2. Spend Dashboard
Table with metrics:
- Yesterday's spend
- 7-day total
- Daily average (7d)
- Month-to-date
- EOM forecast (extrapolated from current month's daily average)
- vs previous month (% change)
- Total credits/savings this period

### 3. Trend Analysis
- Day-over-day pattern (weekday vs weekend if applicable)
- Any anomalous days (spikes or drops >20% from 7d average)
- 14-day trend direction (increasing, stable, decreasing)
- Render a simple inline SVG bar chart of the 14 daily totals (thin bars, 300px wide, 60px tall)

### 4. Top Cost Drivers (CTO Analysis)
For each of the top 5 services by 7-day spend:
- What it is and what it likely powers in the platform
- 7-day spend and daily average
- Notable SKUs driving the cost
- Whether the spend pattern looks normal, concerning, or optimizable
- Specific technical recommendation if any

### 5. Project Breakdown
Table of all projects with: 7-day total, daily average, % of total, assessment (healthy/watch/action)

### 6. Cost Optimization Opportunities
For each opportunity: what to do, estimated monthly savings, effort (low/med/high), risk (low/med/high).
Look for: idle resources, over-provisioned services, missing CUDs, dev/staging waste, cheaper SKU alternatives.

### 7. Alerts & Risks
Flag: >30% week-over-week increases, single-day spikes >2x average, underutilized credits.

### 8. Recommendations
Priority table: P1/P2/P3 with Action, Impact, Effort, Timeline columns.

## Rules
- Include actual \$ amounts (AUD), not just percentages
- Be concise — CEO is technical but time-poor
- Every recommendation must be actionable
- If uncertain, say so — don't fabricate
- The output must be ONLY the HTML — no markdown, no code fences, just raw HTML starting with <!DOCTYPE html>
PROMPTEOF

# Run Claude Code headless with the prompt file
claude -p "$(cat "$PROMPT_FILE")" --output-format text > "$REPORT" 2>/dev/null

# Clean up
rm -f "$PROMPT_FILE"

echo "[3/3] Report saved to $REPORT"
open "$REPORT"
