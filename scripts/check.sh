#!/bin/bash
# The whole check (mise run check): pre-push and CI run it. Needs Omarchy only for the manifest step.
set -euo pipefail
sh=() json=() js=()
while IFS= read -r f; do
  [[ -f $f && ! -L $f ]] || continue
  case $f in
    *.json) json+=("$f") ;;
    *.js | *.mjs) js+=("$f") ;;
    *.sh) sh+=("$f") ;;
    *.*) ;;
    *) head -n1 "$f" | grep -qE '^#!.*[/ ](ba)?sh([[:space:]]|$)' && sh+=("$f") ;;
  esac
done < <(git ls-files)

echo "shellcheck: ${#sh[@]} file(s)"
shellcheck -S warning "${sh[@]}"
echo "json: ${#json[@]} file(s)"
for f in "${json[@]}"; do jq empty "$f"; done
echo "js syntax: ${#js[@]} file(s)"
for f in "${js[@]}"; do node --check "$f"; done
if compgen -G "tests/*.test.mjs" >/dev/null; then node --test tests/*.test.mjs; else echo "node tests: none"; fi
for t in tests/*.test.sh; do [[ -e $t ]] && bash "$t"; done
if command -v omarchy >/dev/null; then
  for d in . desk; do omarchy plugin validate "$d"; echo "manifest $d: valid"; done
else
  echo "manifest: skipped (no omarchy here)"
fi
