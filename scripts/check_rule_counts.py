#!/usr/bin/env python3
"""CI gate: verify that every rule-count claim in README.md / SKILL.md agrees
with what is actually implemented, so the two numbers can never drift apart
silently again.

Two different things get counted in this repo and they are NOT the same
number:

  * "analyzer rules"  -- distinct `rule_id="..."` values assigned inside
    scripts/analyze_sql.py. These are the checks the static analyzer
    actually runs.
  * "advisory rules"  -- distinct guidance entries in
    skills/nitsql/references/universal-rules.md: the bold `**`category-name`**`
    rule markers in categories 1-5 and 7-10, plus the rows of the Static
    Analysis cross-reference table in category 6 (a documented subset of the
    analyzer's own rule IDs).

This script derives both counts from source, greps every place the counts
are *claimed* in prose, and fails the build if any claim disagrees with the
derived value.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ANALYZER_PY = ROOT / "scripts" / "analyze_sql.py"
UNIVERSAL_RULES_MD = ROOT / "skills" / "nitsql" / "references" / "universal-rules.md"
README_MD = ROOT / "README.md"
SKILL_MD = ROOT / "skills" / "nitsql" / "SKILL.md"

errors = []


def derive_analyzer_rule_count():
    text = ANALYZER_PY.read_text(encoding="utf-8")
    ids = set(re.findall(r'rule_id\s*=\s*"([A-Za-z0-9-]+)"', text))
    if not ids:
        errors.append(f"{ANALYZER_PY}: found no rule_id=\"...\" assignments at all -- parser is broken")
    return ids


def derive_advisory_rule_count():
    text = UNIVERSAL_RULES_MD.read_text(encoding="utf-8")
    markers = set(re.findall(r"^\*\*`([a-zA-Z0-9_-]+)`", text, re.MULTILINE))
    sa_rows = set(re.findall(r"^\|\s*\*\*(SA\d{4})\*\*", text, re.MULTILINE))
    if not markers:
        errors.append(f"{UNIVERSAL_RULES_MD}: found no '**`rule-name`**' markers -- parser is broken")
    if not sa_rows:
        errors.append(f"{UNIVERSAL_RULES_MD}: found no Static Analysis (SA####) table rows -- parser is broken")
    overlap = markers & sa_rows
    if overlap:
        errors.append(f"{UNIVERSAL_RULES_MD}: marker/SA-row namespaces overlap unexpectedly: {sorted(overlap)}")
    return markers | sa_rows, markers, sa_rows


def check(label, claimed, derived):
    if claimed != derived:
        errors.append(f"{label}: claims {claimed}, but derived count from source is {derived}")


def main():
    analyzer_ids = derive_analyzer_rule_count()
    analyzer_count = len(analyzer_ids)

    advisory_ids, advisory_markers, advisory_sa_rows = derive_advisory_rule_count()
    advisory_count = len(advisory_ids)

    print(f"Derived analyzer rule count (scripts/analyze_sql.py): {analyzer_count}")
    print(f"Derived advisory rule count (references/universal-rules.md): "
          f"{advisory_count} ({len(advisory_markers)} guidance markers + {len(advisory_sa_rows)} SA cross-refs)")

    # --- README.md -----------------------------------------------------
    readme = README_MD.read_text(encoding="utf-8")
    m = re.search(r"\*\*(\d+) rules\*\*", readme)
    if not m:
        errors.append(f"{README_MD}: could not find a '**N rules**' claim to check")
    else:
        check(f"{README_MD} headline claim", int(m.group(1)), analyzer_count)

    # --- SKILL.md --------------------------------------------------------
    skill = SKILL_MD.read_text(encoding="utf-8")

    rule_analyzer_claims = re.findall(r"(\d+)-rule static analyzer", skill)
    if len(rule_analyzer_claims) < 2:
        errors.append(f"{SKILL_MD}: expected at least 2 'N-rule static analyzer' claims "
                       f"(YAML description + Role line), found {len(rule_analyzer_claims)}")
    for i, claim in enumerate(rule_analyzer_claims, 1):
        check(f"{SKILL_MD} 'N-rule static analyzer' claim #{i}", int(claim), analyzer_count)

    m = re.search(r"\((\d+) checks across \d+ dialects\)", skill)
    if not m:
        errors.append(f"{SKILL_MD}: could not find the '(N checks across M dialects)' claim to check")
    else:
        check(f"{SKILL_MD} 'N checks across M dialects' claim", int(m.group(1)), analyzer_count)

    m = re.search(r"\*\*(\d+) advisory guidance rules across (\d+) categories\*\*", skill)
    if not m:
        errors.append(f"{SKILL_MD}: could not find the 'N advisory guidance rules across M categories' headline")
    else:
        check(f"{SKILL_MD} advisory headline rule count", int(m.group(1)), advisory_count)
        category_count = len(re.findall(r"^\d+\. \*\*[^*]+\*\* \(\d+ rules", skill, re.MULTILINE))
        check(f"{SKILL_MD} advisory headline category count", int(m.group(2)), category_count)

    per_category = [int(n) for n in re.findall(r"^\d+\. \*\*[^*]+\*\* \((\d+) rules", skill, re.MULTILINE)]
    if not per_category:
        errors.append(f"{SKILL_MD}: could not find any per-category '(N rules, ...)' entries")
    else:
        check(f"{SKILL_MD} sum of per-category rule counts", sum(per_category), advisory_count)

    if errors:
        print("\nRule-count claims disagree with derived source-of-truth counts:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        sys.exit(1)

    print("\nAll rule-count claims agree with derived counts.")
    sys.exit(0)


if __name__ == "__main__":
    main()
