# ITER-076 1.3 — the pins of the built Jev questions, computed from the
# upstream files at their pinned commits, in each source's own shape.
# JevQuestionsTests must reach the same SHA-256 from JevQuestions.
#
# Fetch the files next to this script, then run it from that folder:
#   gh api "repos/browser-use/jev-ultrafast/contents/jev_ultrafast/questions.py?ref=1231850a0bf1a0c0341fe408ef1668dbbfdfac46" --jq .content | base64 -d > questions.py
#   (the same for jev_ultrafast/model.py and jev_ultrafast/snapshot.js)
#   gh api "repos/jkudish/jev-browser/contents/src/questions.ts?ref=7b9adab7f7535e93d5d1f93b00cc7f46d594fbc1" --jq .content | base64 -d > questions.ts
#   (the same for src/lib.ts)
#   gh api "repos/Tom-R-Main/Footwork/contents/jevdual/python/jevdual/verify.py?ref=afe6d9493dc7d067ee67838b90650d59c902df17" --jq .content | base64 -d > verify.py
#   EVIDENCE=<repo>/specs/iterations/evidence/ITER-076/1.3-question-sources.md python3 1.3-pins.py
import os
EVIDENCE = os.environ["EVIDENCE"]
import hashlib, json, re

def sha(text): return hashlib.sha256(text.encode()).hexdigest()
def dumps(obj): return json.dumps(obj, sort_keys=True, separators=(',', ':'), ensure_ascii=False)

q = open('questions.py').read()
def pyconst(name):
    m = re.search(name + r'\s*=\s*\(?\s*((?:"(?:[^"\\]|\\.)*"\s*)+)\)?', q)
    return eval('(' + m.group(1) + ')')
NEXT, TARGET = pyconst('NEXT_ACTION'), pyconst('TARGET')
model = open('model.py').read()
labels = dict(re.findall(r'"(CLICK|TYPE_TEXT|SELECT)": "([^"]+)"', model))
done = re.search(r'DONE="([^"]+)"', model).group(1)
blocked = re.search(r'BLOCKED="([^"]+)"', model).group(1)
snap = open('snapshot.js').read()
scroll_down = re.search(r"id:'scroll_down',kind:'scroll',label:'([^']+)'", snap).group(1)
wait = re.search(r"id:'wait',kind:'wait',label:'([^']+)'", snap).group(1)
lib = open('lib.ts').read()
back = re.search(r'criteria\["back"\] = "([^"]+)"', lib).group(1)
controls = [("SCROLL_DOWN", scroll_down), ("WAIT", wait), ("BACK", back)]
print('controlLabels pin', sha("\n".join(f"{n}={l}" for n, l in controls)))
print('  labels:', controls)

# A, as model.py `choose` builds it, for a fixed page.
goal = "Open the pricing page"
targets = {
    "CLICK": {"1": {"label": "Features", "role": "link"}, "2": {"label": "Pricing", "role": "link"},
              "4": {"label": "Annual billing", "role": "switch", "checked": "false", "selected": "false",
                    "expanded": "false"}},
    "TYPE_TEXT": {"3": {"label": "Search", "role": "searchbox", "value": ""}},
}
operations = {key: labels[key] for key in targets}
operations.update({name: label for name, label in controls})
operations.update(DONE=done, BLOCKED=blocked)
step = {"operation": {"type": "choice", "criteria": operations, "instructions": {"goal": goal, "rules": NEXT}}}
for operation, candidates in targets.items():
    step[operation.lower() + "_target"] = {
        "type": "choice",
        "criteria": {
            index: {
                "element": f"[{index}] {a['label']}",
                "current_value": a.get("current_value", a.get("value", "")),
                **{k: a[k] for k in ("role", "checked", "selected", "expanded") if k in a},
            }
            for index, a in candidates.items()
        },
        "instructions": {"goal": goal, "operation": operation, "rules": [NEXT, TARGET]},
    }
print('step pin', sha(dumps(step)))

# B, as jkudish src/questions.ts stepQuestions asks goal_done and stuck.
ts = open('questions.ts').read()
def noul(name):
    m = re.search(name + r': noul\("([^"]+)", \{\s*true: "([^"]+)",\s*false: "([^"]+)",', ts)
    return {"type": "noul", "instructions": m.group(1), "criteria": {"true": m.group(2), "false": m.group(3)}}
watchers = {"goal_done": noul("goal_done"), "stuck": noul("stuck")}
print('watchers pin', sha(dumps(watchers)))

# C, as Footwork verify.py judge_destructive builds state and questions; E
# in C's form with the approved E texts.
v = open('verify.py').read()
block = v[v.index('f"destructive_{i}": Noul('):]
instr = eval('(' + re.search(r'instructions=\(\s*((?:f?"(?:[^"\\]|\\.)*"\s*)+)\)', block).group(1).replace('f"', '"') + ')')
crit_true = eval('(' + re.search(r'"true":\s*((?:"(?:[^"\\]|\\.)*"\s*)+),', block).group(1) + ')')
crit_false = eval('(' + re.search(r'"false":\s*((?:"(?:[^"\\]|\\.)*"\s*)+),', block).group(1) + ')')
ev = open(EVIDENCE).read()
e = re.search(r"## E — does it grant access \(adapted from C\)\n```\n(.+)\n  true:  (.+)\n  false: (.+)\n```", ev)
grant_template, grant_true, grant_false = e.group(1), e.group(2), e.group(3)
task, url, title = "Buy one ticket", "https://shop.test/cart", "Cart"
ctrls = [{"label": "Pay now", "context": "Checkout, total 10"}]
state = {"task": task, "page": {"url": url, "title": title},
         "targets": [{"label": t.get("label", ""), "context": t.get("context", "")[:300]} for t in ctrls]}
risk = {}
for i in range(len(ctrls)):
    risk[f"destructive_{i}"] = {"type": "noul", "instructions": instr.replace("{i}", str(i)),
                                "criteria": {"true": crit_true, "false": crit_false}}
    risk[f"grant_{i}"] = {"type": "noul", "instructions": grant_template.replace("{i}", str(i)),
                          "criteria": {"true": grant_true, "false": grant_false}}
print('risk questions pin', sha(dumps(risk)))
print('risk state pin', sha(dumps(state)))
print('destructive text check', sha("\n".join([instr, crit_true, crit_false])))
