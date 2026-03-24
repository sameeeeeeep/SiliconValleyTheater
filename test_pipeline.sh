#!/bin/bash
# End-to-end pipeline test: fake events → summarizer logic → prompt → Qwen 3B → output
# Tests multiple scenarios to benchmark ELI5 quality

PASS=0
FAIL=0
TOTAL=0

run_test() {
    local name="$1"
    local prompt="$2"
    TOTAL=$((TOTAL + 1))

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "TEST $TOTAL: $name"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "PROMPT (first 200 chars of seed section):"
    echo "$prompt" | grep -A 5 "Continue this\|Write about" | head -8
    echo ""
    echo "MODEL OUTPUT:"
    result=$(echo "$prompt" | ollama run qwen2.5:3b --nowordwrap 2>/dev/null)
    echo "$result"
    echo ""

    # Quality checks
    local issues=""

    # Check: has character names
    if ! echo "$result" | grep -qi "David\|Moira"; then
        issues="$issues [NO_CHARACTER_NAMES]"
    fi

    # Check: not too long (should be under 25 words per line)
    local long_lines=$(echo "$result" | awk '{if(NF>30) print NR}' | head -3)
    if [ -n "$long_lines" ]; then
        issues="$issues [LINES_TOO_LONG]"
    fi

    # Check: not corporate speak
    if echo "$result" | grep -qi "let's proceed\|agreed.*let's\|excellent work\|perfect.*timing\|absolutely.*let's\|fantastic.*progress"; then
        issues="$issues [CORPORATE_SPEAK]"
    fi

    # Check: has some character voice indicators
    if echo "$result" | grep -qi "bébé\|sunrise bay\|LOVE that\|okay so\|travesty\|UNACCEPTABLE\|eviscerated\|remember when\|once had\|once tried"; then
        issues="$issues [HAS_VOICE ✓]"
    fi

    # Check: line count
    local linecount=$(echo "$result" | grep -c "David:\|Moira:")
    if [ "$linecount" -lt 2 ]; then
        issues="$issues [TOO_FEW_LINES:$linecount]"
    fi

    if echo "$issues" | grep -q "CORPORATE_SPEAK\|NO_CHARACTER_NAMES\|TOO_FEW_LINES"; then
        echo "RESULT: ❌ FAIL $issues"
        FAIL=$((FAIL + 1))
    else
        echo "RESULT: ✅ PASS $issues"
        PASS=$((PASS + 1))
    fi
    echo ""
}

# Theater.md example for all tests (the UI design one — most versatile)
EXAMPLE='David: Okay I just looked at the widget and I need to say this with love: it looks like it was designed by someone who hates design.
Moira: David, aesthetics are a matter of perspective. To some, brutalism is—
David: It is not BRUTALISM, Moira. Brutalism is intentional. This is accidental. The green border is giving RadioShack.
Moira: Perhaps a more restrained palette. When I decorated my dressing room for Sunrise Bay, I chose dove gray and—
David: Nobody needs the Sunrise Bay story right now. We need rounded corners, proper spacing, and a subtitle area that does not look like a parking ticket.
Moira: Very well. I shall defer to your aesthetic sensibilities. This once.'

PROJECT="PROJECT: SiliconValley Theater — macOS menu bar app for live comedy commentary on coding sessions."

# ─── TEST 1: Good seed lines (technical explanation available) ───

run_test "Particle bug fix — with seed lines" "David and Moira are working on a project together. They talk as if THEY are doing the work.
$PROJECT

RULES:
- Continue the conversation below. Write 3 more lines
- They RESPOND to each other. Each line reacts to the previous one
- Max 20 words per line. Short and punchy
- Talk about what you DID and WHY. Tell quick stories from past experience
- Never say Claude. The developer is called Johnny

$EXAMPLE

WHAT HAPPENED:
USER: fix the particle effect on the landing page
ASSISTANT: the clip-path crops to the left half showing the human hand but we are sampling pixels from that same left image. The green matrix hand is on the right side which is not being sampled. Fixed by sampling from the right half
CHANGED: particles.js — sampling from right half pixels instead of left

Continue this conversation about the particle effect on the wrong hand:
David: Johnny wants us to fix the particle effect on the landing page. On it.
Moira: So what happened was — the clip-path crops to the left half showing the human hand but we are sampling pixels from the wrong side. The green hand is on the right
David: And it passed. All of it. I don't trust it but it passed.
Moira:
David:
Moira:"

# ─── TEST 2: Build failure — with seed lines ───

run_test "Build failure — missing imports" "David and Moira are working on a project together. They talk as if THEY are doing the work.
$PROJECT

RULES:
- Continue the conversation below. Write 3 more lines
- They RESPOND to each other. Each line reacts to the previous one
- Max 20 words per line. Short and punchy
- Talk about what you DID and WHY. Tell quick stories from past experience
- Never say Claude. The developer is called Johnny

$EXAMPLE

WHAT HAPPENED:
USER: build the project
ASSISTANT: the Makefile was missing framework imports for SwiftUI, AppKit, and AVFoundation. Added the missing -framework flags
CHANGED: Makefile — adding missing framework imports
FAILED: No such module SwiftUI
BUILD SUCCEEDED

Continue this conversation about the build failing because of missing framework imports:
David: Johnny wants us to build the project. On it.
Moira: So what happened was — the Makefile was missing framework imports for SwiftUI, AppKit, and AVFoundation. Added the missing framework flags
David: And it FAILED. No such module SwiftUI. I don't love that.
Moira:
David:
Moira:"

# ─── TEST 3: No seed lines — model writes all 6 ───

run_test "Auth refactor — no seeds, model writes all" "David and Moira are working on a project together. They talk as if THEY are doing the work.
$PROJECT

RULES:
- Write 6 lines about what just happened. David and Moira alternate
- They RESPOND to each other. Each line reacts to the previous one
- Max 20 words per line. Short and punchy
- Talk about what you DID and WHY. Tell quick stories from past experience
- Never say Claude. The developer is called Johnny

$EXAMPLE

WHAT HAPPENED:
ASSISTANT: replacing the old cookie-based login with JWT tokens. This means the server checks a signed token instead of looking up a session in the database. Much faster
CHANGED: auth.swift — replacing cookieStore.get with jwt.verify
TESTS PASSED

Write about replacing cookie auth with JWT tokens:
David:
Moira:
David:
Moira:
David:
Moira:"

# ─── TEST 4: UI debugging ───

run_test "UI opacity fix — with seeds" "David and Moira are working on a project together. They talk as if THEY are doing the work.
$PROJECT

RULES:
- Continue the conversation below. Write 3 more lines
- They RESPOND to each other. Each line reacts to the previous one
- Max 20 words per line. Short and punchy
- Talk about what you DID and WHY. Tell quick stories from past experience
- Never say Claude. The developer is called Johnny

$EXAMPLE

WHAT HAPPENED:
ASSISTANT: The character tile fallback letter opacity is really low at 0.03. That is basically invisible. Bumping it to 0.05 so the initial is at least subtly visible
CHANGED: WidgetView.swift — replacing opacity 0.03 with 0.05
BUILD SUCCEEDED

Continue this conversation about fixing the character tile opacity:
David: Johnny wants us to fix the widget tiles. On it.
Moira: So what happened was — the character tile fallback letter opacity was at 0.03. Basically invisible. We bumped it to 0.05
David: Build went through. No errors. Suspicious but I'll take it.
Moira:
David:
Moira:"

# ─── TEST 5: Meta conversation (should produce empty seeds, model writes all) ───

run_test "Meta conversation — should skip user message" "David and Moira are working on a project together. They talk as if THEY are doing the work.
$PROJECT

RULES:
- Write 6 lines about what just happened. David and Moira alternate
- They RESPOND to each other. Each line reacts to the previous one
- Max 20 words per line. Short and punchy
- Talk about what you DID and WHY. Tell quick stories from past experience
- Never say Claude. The developer is called Johnny

$EXAMPLE

WHAT HAPPENED:
CHANGED: DialogueGenerator.swift — replacing old seed builder with filtered version
CHANGED: DynamicFillerPool.swift — adding consumedTerms set
BUILD SUCCEEDED

Write about updating the dialogue generator and filler pool:
David:
Moira:
David:
Moira:
David:
Moira:"

# ─── TEST 6: Test with incident-style theater.md example ───

INCIDENT_EXAMPLE='David: Okay so we just rewrote the entire EventSummarizer and what we had before was UNACCEPTABLE.
Moira: The previous rendition was indeed a travesty, David. Reducing our rich narrative to ran a command.
David: Ran a command. That is four words. A barista describes my latte with more detail.
Moira: I recall when your father hotel management software produced reports that simply read things happened today.
David: That was Roland system. Johnny fired the vendor. POINT is we pass the real data now.
Moira: The LLM shall finally receive the nourishment it requires. No more feeding it crumbs.'

run_test "With incident-style example" "David and Moira are working on a project together. They talk as if THEY are doing the work.
$PROJECT

RULES:
- Continue the conversation below. Write 3 more lines
- They RESPOND to each other. Each line reacts to the previous one
- Max 20 words per line. Short and punchy
- Talk about what you DID and WHY. Tell quick stories from past experience
- Never say Claude. The developer is called Johnny

$INCIDENT_EXAMPLE

WHAT HAPPENED:
ASSISTANT: the voice cache was growing forever with no eviction. Every WAV file stays on disk permanently. Added a size check that clears files older than 7 days
CHANGED: TheaterEngine.swift — adding cache eviction for WAV files older than 7 days
BUILD SUCCEEDED

Continue this conversation about adding cache eviction:
David: Johnny wants us to clean up the voice cache. It was growing forever.
Moira: So what happened was — every WAV file stayed on disk permanently. No eviction. We added a cleanup that removes files older than seven days
David: Build went through. No errors. Suspicious but I'll take it.
Moira:
David:
Moira:"

# ─── SUMMARY ───

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "RESULTS: $PASS/$TOTAL passed, $FAIL/$TOTAL failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
