#!/usr/bin/env bash
# scripts/test-tier-routing.sh
#
# ITER-041 end-to-end verification:
# Sends StructuredGenerator-style requests through each tier and
# verifies the worker:
#   1. routes to the correct model per tier,
#   2. returns valid JSON (not empty content),
#   3. returns tier_used + model_used in the envelope.
#
# Usage:
#   MW_LICENSE_KEY=<key> ./scripts/test-tier-routing.sh
#
# Get the license from app Settings → Pro → copy "License key".

set -eu

LICENSE="${MW_LICENSE_KEY:-}"
if [ -z "$LICENSE" ]; then
  echo "FAIL: set MW_LICENSE_KEY env var (Pro license token from app Settings → Pro)"
  exit 1
fi

URL="https://api.metawhisp.com/api/pro/advice"

# Realistic StructuredGenerator-style prompts. The system prompt is a
# trimmed version of what Services/Intelligence/StructuredGenerator.swift
# actually sends, demanding the same 7-field JSON shape.
SYSTEM='You analyse a short meeting transcript and emit STRICT JSON with this exact shape:
{"title":"...","project":"...","category":"...","emoji":"...","topics":["..."],"decisions":["..."],"nextSteps":["..."]}
Rules:
- Title: 3-7 words, specific to the meeting content
- Project: name of project mentioned, or null
- Category: work | personal | health | finance | technology | other
- Emoji: one emoji that matches category
- Topics: 1-3 topics covered
- Decisions: list of concrete decisions made
- NextSteps: list of action items
Return ONLY the JSON object, no markdown, no commentary.'

USER='Transcript: "Today we discussed the new pricing tier for Project Aurora. We decided to ship it next Friday after the security review. Alice will handle the marketing copy by Wednesday. Bob will deploy the database migration by Thursday. We agreed not to bundle this with the legacy plan."'

run_tier() {
  local tier="$1"
  local label="$2"
  printf '\n=== Tier: %s — expecting %s ===\n' "$tier" "$label"

  local body
  body=$(python3 -c "
import json
print(json.dumps({
  'system': '''$SYSTEM''',
  'user': '''$USER''',
  'tier': '$tier',
  'service_id': 'test-tier-routing'
}))
")
  local response
  response=$(curl -s -w '\n%{http_code}' -X POST "$URL" \
    -H "Authorization: Bearer $LICENSE" \
    -H "Content-Type: application/json" \
    --data-raw "$body")

  local http_status
  http_status=$(echo "$response" | tail -n1)
  local body_resp
  body_resp=$(echo "$response" | sed '$d')

  printf 'HTTP: %s\n' "$http_status"

  if [ "$http_status" = "401" ]; then
    echo "FAIL: license invalid"
    exit 2
  fi

  # Extract envelope fields
  local tier_used model_used provider text_len text_head
  tier_used=$(echo "$body_resp"     | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tier_used','?'))" 2>/dev/null || echo "?")
  model_used=$(echo "$body_resp"    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('model_used','?'))" 2>/dev/null || echo "?")
  provider=$(echo "$body_resp"      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('provider','?'))" 2>/dev/null || echo "?")
  text_len=$(echo "$body_resp"      | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('text','')))" 2>/dev/null || echo "0")
  text_head=$(echo "$body_resp"     | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('text','')[:200])" 2>/dev/null || echo "")

  printf 'tier_used = %s\n' "$tier_used"
  printf 'model_used = %s\n' "$model_used"
  printf 'provider = %s\n' "$provider"
  printf 'text length = %s chars\n' "$text_len"
  printf 'text head: %s\n' "$text_head"

  if [ "$http_status" = "200" ] && [ "$text_len" -gt 20 ]; then
    # Try to parse the text as JSON to check StructuredGenerator-style validity
    echo "$body_resp" | python3 -c "
import sys, json
data = json.load(sys.stdin)
text = data.get('text','')
# Strip code fences if present
text = text.strip()
if text.startswith('\`\`\`'):
    text = text.split('\`\`\`')[1] if '\`\`\`' in text else text
    if text.startswith('json'): text = text[4:].strip()
# Find first { and last }
s = text.find('{')
e = text.rfind('}')
if s < 0 or e <= s:
    print('❌ no JSON object found in text')
    sys.exit(1)
inner = text[s:e+1]
try:
    parsed = json.loads(inner)
    expected = ['title','project','category','emoji','topics','decisions','nextSteps']
    have = list(parsed.keys())
    missing = [k for k in expected if k not in have]
    if missing:
        print(f'⚠️  partial JSON — missing fields: {missing}')
        print(f'   present: {have}')
    else:
        print(f'✅ valid StructuredGenerator JSON — all 7 fields present')
        print(f'   title = {parsed[\"title\"]}')
        print(f'   project = {parsed[\"project\"]}')
        print(f'   decisions = {parsed[\"decisions\"]}')
except json.JSONDecodeError as e:
    print(f'❌ JSON parse error: {e}')
    print(f'   inner snippet: {inner[:200]}')
    sys.exit(1)
"
  else
    echo "❌ FAIL — http=$http_status text_len=$text_len"
    echo "Full response head:"
    echo "$body_resp" | head -c 500
    echo
  fi
}

echo "=== ITER-041 tier-routing live verification ==="
echo "License: ${LICENSE:0:8}..."
echo

run_tier "mini"   "llama-3.1-8b-instant   (\$0.05/\$0.08, expected: maybe truncated on this complex schema)"
run_tier "medium" "openai/gpt-oss-120b    (\$0.15/\$0.60, expected: full JSON after fix)"
run_tier "heavy"  "llama-3.3-70b-versatile (\$0.59/\$0.79, baseline — should always work)"

echo
echo "=== Test back-compat: missing tier → defaults to heavy ==="
body=$(python3 -c "import json; print(json.dumps({'system': '''$SYSTEM''', 'user': '''$USER''', 'service_id': 'test-no-tier'}))")
curl -s -X POST "$URL" \
  -H "Authorization: Bearer $LICENSE" \
  -H "Content-Type: application/json" \
  --data-raw "$body" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'tier_used = {d.get(\"tier_used\")} (should be \"default\")')
print(f'model_used = {d.get(\"model_used\")} (should be llama-3.3-70b-versatile)')
print(f'text length = {len(d.get(\"text\",\"\"))} chars')
"

echo
echo "=== DONE — interpret: all 3 tiers should produce parseable 7-field JSON ==="
