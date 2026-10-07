#!/bin/zsh
# The scheduled briefs' steps, as a few fixed commands. A scheduled run has no one
# there to approve each action, so it runs only these, and each is approved once
# ("Always allow") the first time.
#
#   brief.sh morning   refresh Mail and Daybook, then print today.md, mail.md, followups.md and work.md
#   brief.sh week      refresh Daybook, then print week.md and time.md
#   brief.sh check     embed the headline font, then render brief.html to brief-check.png
#   brief.sh post      send brief.md to the iPhone, and leave Daybook open on the Mac
set -u
DIR="$HOME/Library/Application Support/Daybook"

show() {
  for f in "$@"; do
    echo "===== $f ====="
    if [[ -f "$DIR/$f" ]]; then cat "$DIR/$f"; else echo "(missing)"; fi
    echo
  done
}

case "${1:-}" in
  morning)
    # Open Mail in the background and give every account a minute to check in.
    open -g -a Mail
    sleep 60
    # -n starts a separate copy that exports and quits, even if Daybook is open.
    # -W waits for the export to finish (it checks Mail, your repos and GitHub).
    open -n -W -g -a Daybook --args --export --mail
    show today.md mail.md followups.md work.md bills.md
    ;;
  week)
    open -n -W -g -a Daybook --args --export
    show week.md time.md
    ;;
  check)
    # The page names its headline font as url(__FRAUNCES__); put the real file in,
    # as base64, so the page opens with no network. (Cheaper than the agent
    # writing 80 KB of base64 itself.)
    FONT=$(find "$HOME/Library/Application Support/Claude/local-agent-mode-sessions/skills-plugin" \
      -path "*morning/assets/fonts/fraunces-latin-600-normal.woff2" 2>/dev/null | head -1)
    if [[ -n "$FONT" ]]; then
      DATA="data:font/woff2;base64,$(base64 -i "$FONT" | tr -d '\n')"
      for page in "$DIR"/brief.html "$DIR"/briefs/*.html(N); do
        grep -q "__FRAUNCES__" "$page" && DATA="$DATA" perl -0pi -e 's/__FRAUNCES__/$ENV{DATA}/g' "$page"
      done
    fi
    rm -f "$DIR/brief-check.png"
    qlmanage -t -s 1400 -o "$DIR" "$DIR/brief.html" >/dev/null 2>&1
    if [[ -f "$DIR/brief.html.png" ]]; then
      mv "$DIR/brief.html.png" "$DIR/brief-check.png"
      echo "$DIR/brief-check.png"
    else
      echo "Quick Look couldn't render brief.html" >&2
      exit 1
    fi
    ;;
  post)
    open -n -g -a Daybook --args --post-brief
    sleep 5
    open -g -a Daybook
    echo "Posted."
    ;;
  *)
    echo "usage: brief.sh morning|week|check|post" >&2
    exit 2
    ;;
esac
