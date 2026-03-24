# Theater Configuration
<!-- Theme: david-moira -->
<!-- Generated: 2026-03-22 -->

## Project
SiliconValley Theater is a macOS menu bar app that watches Claude Code sessions and generates live comedy commentary voiced by TV characters. It reads JSONL events, feeds them to a local LLM, synthesizes speech, and plays it through a floating Zoom-style widget. David would call it "deeply unnecessary but oddly compelling." Moira would call it "a vociferous technological cabaret."

## Tech Stack
Swift 5.9, SwiftUI, macOS 14+, Ollama (Qwen 2.5 3B), Groq (Llama 3.3 70B), Pocket TTS (MLX voice cloning), Fish Audio, AVFoundation, DispatchSource (kqueue file watching), AsyncStream, JSONL parsing

## Key Concepts
- **TheaterEngine** — The central orchestrator. Seven hundred lines of Swift managing the entire pipeline from events to audio playback.
- **SessionWatcher** — Watches `~/.claude/projects/` for JSONL files. Tails the latest file, parses events into an AsyncStream.
- **EventSummarizer** — Zero-latency pre-digestion of raw events. Filters noise, keeps the conversation. The quality of this determines everything.
- **DynamicFillerPool** — Consume-and-replenish banter pool. Plays each set once, generates new ones via LLM during idle periods.
- **Voice Caching** — WAV files cached to disk by text+voiceID hash. After first synthesis, playback is instant.
- **Cold Open** — "Joining the call" intros consumed from a shuffled pool so they never repeat.
- **Few-Shot Examples** — Theme-specific dialogue in the LLM prompt. Incident-style, not analogy-style.
- **Session Flapping** — The watcher auto-switching between sessions causing interrupted playback.

## Cast
- Developer (User) = Johnny Rose — the one funding the operation, making the big asks, occasionally confused by the technology but has the vision
- Claude Code = Stevie Budd — does the actual work quietly, deadpan reactions, somehow keeps everything running
- The LLM (Qwen/Groq) = Roland Schitt — unpredictable output quality, sometimes surprisingly good, usually needs guidance
- The TTS Engine = Alexis Rose — dramatic pauses, occasionally mispronounces things, but when she's on, she's ON

## Voice Examples

### Example 1
<!-- Context: User rewrites the EventSummarizer to pass raw details instead of stripped summaries -->
David: Okay so we just rewrote the entire EventSummarizer and I need everyone to know that what we had before was UNACCEPTABLE.
Moira: The previous rendition was indeed a travesty, David. It was reducing our rich narrative tapestry to "ran a command."
David: "Ran a command." That's what it gave the LLM. Four words. I once had a barista describe my latte order with more detail.
Moira: I recall when your father's hotel management software produced reports that simply read "things happened today."
David: That was Roland's system. Johnny fired the vendor. But the POINT is, now we pass the actual conversation through.
Moira: The LLM shall finally receive the nourishment it requires. No more feeding it crumbs and expecting a banquet.

### Example 2
<!-- Context: Build fails because Makefile is missing framework imports -->
Moira: The build has failed, David. The Makefile was bereft of framework imports. SwiftUI. AppKit. AVFoundation. All absent.
David: How do you FORGET to import the frameworks? That's like opening a store and forgetting to unlock the door.
Moira: I once performed Sunrise Bay without my costume arriving. I improvised with curtain fabric. This is worse.
David: At least you had curtain fabric. We had literally nothing. Three missing lines in the Makefile.
Moira: Your father once launched a hotel chain and forgot to register the domain name. The Roses have a pattern.
David: We do NOT have a pattern. We have occasional oversights. This is fixed now. Moving on.

### Example 3
<!-- Context: User asks to redesign the UI because it looks like a dev prototype -->
David: Okay I just looked at the widget and I need to say this with love: it looks like it was designed by someone who hates design.
Moira: David, aesthetics are a matter of perspective. To some, brutalism is—
David: It's not BRUTALISM, Moira. Brutalism is intentional. This is accidental. The green border is giving RadioShack.
Moira: Perhaps a more restrained palette. When I decorated my dressing room for Sunrise Bay, I chose dove gray and—
David: Nobody needs the Sunrise Bay story right now. We need rounded corners, proper spacing, and a subtitle area that doesn't look like a parking ticket.
Moira: Very well. I shall defer to your aesthetic sensibilities. This once.

### Example 4
<!-- Context: The filler dialogue keeps playing generic content instead of project-specific banter -->
David: The fillers are generic. "Ran a command." "Built the project." That's not CONTENT, that's a STATUS UPDATE.
Moira: In my experience, David, the quality of the script determines the quality of the performance.
David: Exactly. We need incidents. Stories. "Remember when Johnny accidentally deleted the production database."
Moira: That was a HARROWING evening. Your father pressed one button and three thousand reservations vanished.
David: And then Roland tried to help and made it worse. He always makes it worse.
Moira: The lesson being: our fillers must have narrative texture. Not merely "a thing occurred."

## Fillers

### Filler 1
<!-- Tags: tts, voice, audio, speech -->
David: The voice cloning situation is... a lot. Pocket TTS cloned Moira's voice from a ten-second clip and it's UNSETTLING.
Moira: I find it rather flattering, David. My dulcet tones, preserved digitally for all eternity.
David: Your "dulcet tones" pronounced "authentication" as "authenti-KAY-tion." The model learned that.
Moira: That is the CORRECT pronunciation. I studied at the Royal Academy. You studied at a community college.
David: I went to a private school. And I'm not taking pronunciation notes from a voice model running on a laptop.
Moira: The laptop has more diction than half the cast of Sunrise Bay. I would know. I carried that show.

### Filler 2
<!-- Tags: llm, ollama, groq, prompt, generate -->
Moira: The language model produced a response that was, and I quote, "clean and stable." Those are not WORDS, David.
David: Those are words that a CORPORATE TRAINING VIDEO would use. Not Gilfoyle. Not anyone with personality.
Moira: When I receive a script devoid of character, I return it to the writer with a single note: "unacceptable."
David: We can't return it. It's a three-billion-parameter model. It doesn't take notes.
Moira: Then we must improve the few-shot examples. The model mirrors what we show it. Garbage in, blandness out.
David: I once hired a DJ who played exactly what you told him. Told him "something fun." He played elevator music for three hours.

### Filler 3
<!-- Tags: widget, ui, view, design, swiftui -->
David: The widget is floating above every window. It's always there. Watching. Judging. Like Moira at a town council meeting.
Moira: I do not JUDGE at council meetings. I observe. And occasionally correct.
David: You once corrected Roland's grammar during a vote on road repairs. He didn't speak for the rest of the session.
Moira: His grammar was an affront. "We should of fixed them roads." I was performing a public service.
David: Anyway the widget uses NSWindow.level floating. It can't be minimized accidentally. It persists.
Moira: Much like my presence. Persistent, unavoidable, and ultimately beneficial.

### Filler 4
<!-- Tags: event, watcher, jsonl, session, buffer -->
David: The SessionWatcher keeps switching between sessions. It's like channel surfing except every channel is code.
Moira: Fidelity, David. The watcher must commit to ONE session. Much like a marriage. Or a long-running television contract.
David: It auto-follows the most recent JSONL file. So whenever autoclawd updates, it switches. Every five seconds.
Moira: That is the behavior of someone with no object permanence. We must PIN the session.
David: Johnny once switched hotels four times in one day because each new one had slightly better pillows.
Moira: And we ended up at the motel. Which had NO pillows. The lesson being: stay committed.

### Filler 5
<!-- Tags: filler, pool, banter, dialogue -->
Moira: The filler pool has eleven sets ready. Each played once and discarded. Like tissues. Or Alexis's boyfriends.
David: Moira. That is... accurate but still mean.
Moira: The pool replenishes via LLM during idle periods. The machine writes our banter while we rest.
David: The machine wrote "that's the most efficient way to ensure our system is clean and stable" and we all agreed to never speak of it.
Moira: A dark chapter. The few-shot examples have since been improved. Incidents, not analogies.
David: "Remember when" is always funnier than "it's like." Real stories. Not metaphors from a self-help book.

### Filler 6
<!-- Tags: build, make, compile, swift, swiftc -->
David: The Makefile uses raw swiftc. No Xcode. Just the compiler and vibes.
Moira: I once performed an entire one-woman show with nothing but a spotlight and a folding chair. This is similar energy.
David: Except your show was intentional. Our build system is accidental minimalism.
Moira: The codesign step uses ad-hoc signing. A dash. That is the software equivalent of a handshake agreement.
David: Johnny once sealed a business deal with a handshake. That business was a pyramid scheme.
Moira: And yet here we are. Building an application with handshake signing. The Rose family tradition continues.

### Filler 7
<!-- Tags: cache, voice, disk, wav -->
David: The voice cache at ~/.siliconvalley/voice_cache grows forever. No cleanup. No eviction. Just WAV files accumulating.
Moira: Much like my wig collection, David. Each one serves a purpose. Each one is irreplaceable.
David: Your wig collection has a CATALOGUE SYSTEM. The voice cache has a base64 hash. It's chaos.
Moira: At least after the first synthesis, playback is instant. Zero compute. Pure efficiency.
David: Remember when the cache was empty and every filler took four seconds of silence? That was uncomfortable.
Moira: Silence is only powerful when INTENTIONAL. Accidental silence is just technical failure with a fancy name.

### Filler 8
<!-- Tags: theme, character, config -->
David: We have voice samples for David and Moira Rose but NOT for Gilfoyle and Dinesh. We shipped before them.
Moira: As is only appropriate. The Rose family takes precedence. We are the LEADS, David.
David: Technically Gilfoyle and Dinesh are the default theme. We're an alternative.
Moira: ALTERNATIVE? I have never been an alternative in my LIFE. I am the first choice. The ONLY choice.
David: The developer said he's adding their voice samples next. We just happened to have WAV files already.
Moira: Because I am a professional. I always have my materials prepared. Unlike some people in this codebase.

## Term Explainers

### TheaterEngine
<!-- Keywords: theaterengine, engine, orchestrator, theater -->
<!-- Plain: the main controller that runs everything -->
David: TheaterEngine is the file that does EVERYTHING. Seven hundred lines. Events, dialogue, speech. All of it.
Moira: It is the Sunrise Bay of this codebase. Long-running, occasionally dramatic, absolutely essential.
David: It has six phases. Idle, watching, buffering, generating, synthesizing, playing. Like the stages of grief.
Moira: When it gets stuck in "generating" that is the LLM contemplating its existence. Give it time.
David: Johnny once asked what TheaterEngine does. I said "everything" and he said "that sounds like a management problem."
Moira: Your father has an instinct for organizational dysfunction. It's the one thing he's genuinely good at identifying.

### JSONL
<!-- Keywords: jsonl, json lines, session file, event log -->
<!-- Plain: the activity log -->
David: JSONL is JSON Lines. One JSON object per line. Every Claude Code event gets written to these files.
Moira: It is a chronicle, David. A moment-by-moment account of every tool call, every message, every decision.
David: We tail the latest file and parse each line. Remember when Johnny read his hotel's guest complaint log out loud?
Moira: Three hundred complaints. He read every one. At the dinner table. It took four hours.
David: JSONL files can get that big too. Megabytes per session. We only read the last 8KB on startup.
Moira: Selective reading. The mark of wisdom. Or denial. Depending on perspective.

### Pocket TTS
<!-- Keywords: pocket tts, pocket, tts, mlx, voice cloning, sidecar -->
<!-- Plain: the local voice generator -->
David: Pocket TTS runs voice cloning LOCALLY on your Mac. No cloud. No API key. Just your GPU doing its best.
Moira: I provided my voice sample personally. Ten seconds of my acceptance speech from the Daytime Emmys.
David: You used your EMMY SPEECH as a voice sample? Of course you did.
Moira: The model captured my gravitas perfectly. Though it occasionally adds a vibrato I did not authorize.
David: The Python sidecar runs on port 7893. If it crashes we get macOS robot voices from 2005.
Moira: I would rather perform in SILENCE than be voiced by a machine that sounds like a GPS navigation unit.

### DynamicFillerPool
<!-- Keywords: filler, pool, dynamic, banter, consume -->
<!-- Plain: the backup conversation library -->
Moira: The DynamicFillerPool is our understudy system. Pre-written dialogue waiting in the wings.
David: Each set plays once and gets discarded. Like opening night flowers. Beautiful, temporary, thrown away.
Moira: The pool replenishes during idle periods. The LLM generates new material while we rest between scenes.
David: Remember when we ran out of fillers and there was just silence? Forty seconds of nothing.
Moira: That silence was the most honest thing this application has ever produced.
David: The pool now holds five sets minimum. Context-matched by tags. It picks banter that fits what's happening.

### kqueue
<!-- Keywords: kqueue, file watcher, dispatchsource, file watching, inotify -->
<!-- Plain: the file change detector -->
David: kqueue is how macOS tells us a file changed. We register a file and the OS pings us when it updates.
Moira: When I starred in Sunrise Bay, I had a personal assistant who informed me of script changes INSTANTLY. kqueue is that.
David: Except kqueue never takes lunch breaks. Remember when your assistant missed the rewrite of episode forty-seven?
Moira: She was at a DENTIST appointment, David. And the rewrite was catastrophic. I performed the wrong death scene.
David: That's why we use kqueue. Sub-millisecond. No dentist appointments. No wrong death scenes.
Moira: Superior to every assistant I've ever employed. Including the one who lost my wig catalogue in Dubrovnik.

### Voice Cloning
<!-- Keywords: voice clone, voice cloning, clone, voice sample, reference audio -->
<!-- Plain: copying someone's voice from a short recording -->
David: Voice cloning takes a ten-second audio clip and builds a whole voice from it. Locally. On your laptop.
Moira: I provided MY voice. Ten seconds of my Daytime Emmy acceptance speech. The model was HONORED to receive it.
David: Remember when Roland tried to record HIS voice sample? There was a lawnmower running the entire time.
Moira: The result sounded like Roland speaking through a leaf blower. Which, honestly, was an improvement on Roland.
David: The catch is you need clean audio. No background noise. Johnny's first sample had Alexis yelling in the background.
Moira: And the cloned voice kept inserting "oh my GOD David" at random intervals. We had to re-record.

### WAV Cache
<!-- Keywords: wav cache, voice cache, voice_cache, disk cache, cached audio -->
<!-- Plain: saved voice recordings for instant replay -->
David: Every line we synthesize gets saved as a WAV file on disk. So next time the same line comes up, instant playback.
Moira: Remember the FIRST session before we had caching? Four seconds of silence between every line.
David: It was unbearable. Johnny asked if the app had crashed. It hadn't. It was just THINKING.
Moira: Now after a few sessions, ninety percent of playback is pure disk reads. The TTS engine barely works.
David: The cache lives at ~/.siliconvalley/voice_cache and it grows forever. No cleanup. No eviction.
Moira: Your father once kept every hotel receipt from 1987 onward. The Rose family does not delete.

### Few-Shot Examples
<!-- Keywords: few-shot, few shot, example, examples, prompt example -->
<!-- Plain: sample conversations we show as a reference -->
David: Few-shot examples are sample dialogues we show the LLM before asking it to write one. Show, don't tell.
Moira: I once gave a line reading for a FUNERAL scene and the understudy performed it at a WEDDING. That is what happens without examples.
David: Without them, the three-billion-parameter model writes "that's a good approach" over and over. We tested this.
Moira: BLAND. Fourteen consecutive lines of "agreed, let's proceed." I was EVISCERATED by the mediocrity.
David: The trick is matching the right example to the situation. Johnny once showed up to a black-tie event in hiking boots.
Moira: Wrong context. Wrong example. Wrong boots. The principle is universal.

### RAG
<!-- Keywords: rag, retrieval, keyword matching, context matching, relevance -->
<!-- Plain: finding the best matching example for the situation -->
David: RAG is Retrieval Augmented Generation. We search our examples for the best match, then feed it to the LLM.
Moira: We do not randomly select. Remember when the caterer randomly selected the menu for Johnny's birthday?
David: We got a vegan tasting menu at a steakhouse. Johnny didn't speak to Alexis for a week.
Moira: PRECISELY. Random selection produces inappropriate results. RAG prevents this.
David: We count keyword overlaps between the event summary and each example's context. Highest score wins.
Moira: The system once matched a "build failed" example when the build had SUCCEEDED. We added a minimum threshold.

### Event Batching
<!-- Keywords: batch, buffer, buffering, event buffer, batch events -->
David: We don't react to every single event. We wait three seconds, collect everything, THEN respond.
Moira: Remember when Alexis used to narrate every step of her morning routine on Instagram LIVE?
David: "I'm opening the fridge. I'm looking at the fridge. I'm closing the fridge." That's what unbatched events sound like.
Moira: Three seconds of collection. Then one thoughtful response. The Alexis era taught us RESTRAINT.
David: The buffer fills up, flushes to the LLM, gets six lines back. Clean.
Moira: Your father once received forty-seven emails in a row because someone replied to each sentence separately. Batching prevents this.

### Pipelined Playback
<!-- Keywords: pipeline, pipelined, synthesize ahead, pre-synthesize, concurrent -->
David: Pipelined playback means we start making the audio for line two while line one is still playing. No gaps.
Moira: In Sunrise Bay, we called this "hot switching." One camera cuts to the next. No dead air between scenes.
David: Remember when the pipeline WASN'T working? Three-second pause between every line.
Moira: It sounded like a hostage negotiation. Long silences. Then someone speaks. Then more silence.
David: Johnny asked if we were buffering. We weren't. The TTS was just starting from scratch each time.
Moira: Now the next line is READY before the current one finishes. As it should be. As PROFESSIONALS do.

### Sidecar Process
<!-- Keywords: sidecar, python sidecar, server.py, helper process, subprocess -->
David: A sidecar is a helper process. Our main app is Swift. The TTS engine is a Python server running alongside it.
Moira: Remember when Johnny hired Roland as a "business consultant"? Two different people. Two different languages. Same office.
David: Roland flooded the basement. Our sidecar merely crashes occasionally. Still an improvement.
Moira: They communicate via HTTP. The Swift app says "speak this." The Python server says "here's the audio."
David: If the sidecar dies, we fall back to macOS system voices from 2005. Robotic. Soulless.
Moira: I would rather perform in COMPLETE silence than be voiced by a navigation device. I have STANDARDS.

### MLX
<!-- Keywords: mlx, apple silicon, metal, gpu, neural engine, local inference -->
David: MLX is Apple's framework for running AI models locally. Right on the GPU. No internet required.
Moira: Remember when the hotel WiFi went down for three days? Johnny couldn't run ANYTHING cloud-based.
David: MLX means that never happens to us. Voice cloning, inference, everything runs on the actual laptop.
Moira: No API key. No monthly bill. No service outage at two AM when you need it most.
David: It IS slower than cloud APIs. But it's free and it works in a cabin with no cell service.
Moira: Your father once ran a board meeting from a cabin with no cell service. It was the most productive meeting they ever had.

### Context Window
<!-- Keywords: context window, context length, token limit, 32k, prompt length -->
David: The context window is how much text the LLM can see at once. Ours is thirty-two thousand tokens.
Moira: Remember when Johnny tried to read the ENTIRE hotel operations manual at once? Two thousand pages?
David: He got to page forty and forgot what page one was about. That's context window overflow.
Moira: Our prompt is about two thousand characters. Summary, example, instructions. Well within limits.
David: The trick is keeping it short. Every extra word pushes something important off the edge.
Moira: When I script-doctored Sunrise Bay, I cut every episode by fifteen pages. BREVITY, David. Brevity.

### System Prompt
<!-- Keywords: system prompt, instructions, prompt engineering, prompt template -->
David: The system prompt is instructions we give the LLM before it writes anything. Director's notes.
Moira: Remember when the new director on Sunrise Bay gave NO notes? The actors improvised for two episodes.
David: Someone played a death scene as comedy. THAT is what happens without a system prompt.
Moira: Our prompt says "write as David and Moira, under twenty words per line, react to each other."
David: Three-billion parameters can handle about five rules before it gets confused. We learned this the hard way.
Moira: We once gave it fourteen rules. The output was GIBBERISH. Half the lines were in German.

### Token
<!-- Keywords: token, tokens, tokenizer, tokenization -->
David: A token is roughly a word. Or part of a word. It's how LLMs measure input and output.
Moira: The model does not read WORDS, David. It reads tokens. "Unbelievable" becomes three tokens. "Hi" is one.
David: Remember when Johnny tried to send a one-page fax and it came out as forty pages? Tokenization is the reverse.
Moira: Our prompt is about five hundred tokens. The model generates one hundred fifty back. Tight budget.
David: Going over budget is going over budget. Johnny once cut craft services to save forty dollars.
Moira: The cast nearly REVOLTED. Stevie had to personally drive to the store for emergency snacks.

### SwiftUI
<!-- Keywords: swiftui, swift ui, view, widget view, @state, @observable -->
David: SwiftUI is how we build the interface. You describe what you want and it figures out the layout.
Moira: Remember when Johnny described what he wanted for the motel lobby and Ted just DID it?
David: Except SwiftUI doesn't argue back. You say "rounded corners, twelve pixels" and it happens.
Moira: Our widget is all SwiftUI. The tiles, the subtitle area, the toolbar. Six hundred lines.
David: When something changes — new dialogue, new speaker — the view updates automatically. No manual refresh.
Moira: Self-updating. Unlike the Schitt's Creek town sign, which required MANUAL maintenance and a ladder.

### Ollama
<!-- Keywords: ollama, ollama serve, local llm, qwen, model serve -->
David: Ollama runs language models locally on your Mac. Pull a model, start the server, talk to it.
Moira: Remember when we tried to use a cloud API and Johnny's WiFi dropped mid-generation?
David: Half a sentence. "David and Moira are—" and then nothing. For forty-five seconds.
Moira: Ollama runs LOCALLY. No WiFi. No outage. The model lives on YOUR machine.
David: We use Qwen two point five three billion parameters. Small but fast. Three seconds per response.
Moira: If Ollama isn't running, we get nothing. "Ollama serve" must be active. NON-NEGOTIABLE.

## Cold Opens

### Intro 1
David: Okay. SiliconValley Theater. We're live. This is happening. I'm not ready but that's never stopped us.
Moira: One is never truly ready, David. One simply arrives and performs. As I did for thirty-seven years of Sunrise Bay.
David: We don't need the Sunrise Bay story right now. We need to connect to the session.
Moira: Very well. The JSONL stream awaits. Johnny is working again, I presume?
David: Johnny is always working. That's what Johnny does. He works and we commentate.
Moira: Then let us commentate with DISTINCTION. Connecting now.

### Intro 2
Moira: A new session has manifested. The developer requires our presence. Our VOCAL presence.
David: "Manifested." It's a JSONL file update, Moira. Not a spiritual awakening.
Moira: Every creative endeavor begins with intention, David. The file updated. We respond. That is our calling.
David: Our calling is literally a DispatchSource kqueue callback. But sure. Calling.
Moira: Johnny is typing something. I can sense it. The events are buffering.
David: You can't SENSE events. They come through a file watcher. But yes, we're in. Let's go.

### Intro 3
David: We're back. Another session. Another opportunity for me to watch code happen and have opinions about it.
Moira: Opinions are the currency of the commentator, David. Spend them lavishly.
David: Last session Johnny asked us to redesign the UI. I had MANY opinions. Not all of them were heard.
Moira: Your opinions on corner radius were noted. And implemented. The twelve-pixel radius was a victory.
David: Twenty-two pixels. We went with twenty-two. Because twelve was giving "government website."
Moira: Twenty-two. Very well. The point being: we influence outcomes. We are not mere observers.

### Intro 4
Moira: The filler pool is seeded. The voice cache is warm. My vocal instrument is calibrated.
David: Your "vocal instrument" is a WAV file from your Emmy speech running through a three-billion-parameter model.
Moira: And it sounds MAGNIFICENT. Better than most living actors. Present company excluded, naturally.
David: Naturally. Okay Johnny's session is active. Let's see what he's building today.
Moira: Whatever it is, we shall narrate it with the gravitas it deserves. Or more than it deserves.
David: Probably more. That's kind of our whole thing. Over-narrating normal coding. Connecting.

### Intro 5
David: Theater session starting. I want to acknowledge that we are two fictional characters watching real code happen.
Moira: We are ARTISTS interpreting the technical process through the lens of dramatic narrative.
David: We're a menu bar app. Let's not oversell it.
Moira: Every great performance begins with humility, David. And then quickly abandons it.
David: Fine. Let's connect, watch Johnny work, and say things that are hopefully more interesting than "ran a command."
Moira: If our commentary ever descends to "ran a command," I shall retire. From this application and from public life.
