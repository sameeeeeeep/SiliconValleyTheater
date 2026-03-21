import Foundation

// MARK: - FillerLibrary

/// Pre-written filler dialogues per theme. No LLM needed — these are hand-crafted,
/// voice-cached at startup, and played instantly during gaps between real commentary.
enum FillerLibrary {

    /// Returns a term-triggered explainer if a keyword is detected in events.
    /// These explain technical concepts in a fun, accessible way.
    static func termTriggeredFiller(forTerms terms: [String]) -> [String]? {
        let lower = terms.joined(separator: " ").lowercased()
        for (keywords, explainer) in termExplainers {
            if keywords.contains(where: { lower.contains($0) }) {
                return explainer
            }
        }
        return nil
    }

    /// Technical term explainers — detected from events, played as contextual fillers.
    /// Format: ([keywords], [6 lines alternating characters])
    static let termExplainers: [([String], [String])] = [
        (["cache", "caching", "cached"], [
            "Okay so caching. Imagine you call a pizza place every night and order the same thing.",
            "Instead of calling every time, you just keep a pizza in the fridge. That's a cache.",
            "Exactly. The fridge is faster than the phone call. But the pizza might get stale.",
            "So you have to decide how long to keep it. That's cache expiration.",
            "And if the menu changes but you're still eating old pizza, that's a stale cache bug.",
            "I'm hungry now. But yes, that's literally how every website loads faster.",
        ]),
        (["api", "endpoint", "rest"], [
            "APIs are like a restaurant menu. You don't go into the kitchen and cook yourself.",
            "You look at the menu, pick what you want, and the kitchen sends it back.",
            "The menu is the API. The kitchen is the server. You're the client.",
            "And if you order something that's not on the menu, you get a four oh four. Not found.",
            "Or a five hundred, which means the kitchen is on fire.",
            "Basically every error code is just a different kind of restaurant disaster.",
        ]),
        (["deploy", "production", "ship"], [
            "Deploying to production is like performing surgery on a patient who's still awake.",
            "You can't just stop the website while you update it. People are using it.",
            "So you do it carefully, one piece at a time, and pray nothing breaks.",
            "That's why we have staging environments. It's like practicing surgery on a dummy first.",
            "Except sometimes the dummy works fine and the real patient explodes anyway.",
            "And that's why we deploy on Fridays. Just kidding. Never deploy on Fridays.",
        ]),
        (["test", "testing", "unit test", "passed"], [
            "Tests are like spell-check for code. They catch the obvious mistakes.",
            "But just like spell-check won't tell you your essay makes no sense, tests have limits.",
            "A unit test checks one tiny piece. Like testing if a single brick is solid.",
            "Integration tests check if the bricks form a wall. End-to-end tests check if the house stands.",
            "And somehow, the house always passes all tests but the door still won't open.",
            "That's because nobody wrote a test for the door. Classic.",
        ]),
        (["refactor", "refactoring", "cleanup"], [
            "Refactoring is like reorganizing your closet. Nothing new goes in.",
            "You're just moving things around so you can actually find your pants in the morning.",
            "The closet works before and after. But after, you don't cry every time you open it.",
            "Some people say refactoring is a waste of time. Those people have messy closets.",
            "The trick is doing it regularly. Otherwise you end up on that hoarders show.",
            "Except instead of old newspapers, it's deprecated functions from two thousand nineteen.",
        ]),
        (["database", "query", "sql", "postgres", "mongo"], [
            "A database is like a really organized filing cabinet. With superpowers.",
            "You can ask it questions. Like give me every customer who signed up in March.",
            "And it finds the answer in milliseconds. Try doing that with an actual filing cabinet.",
            "The language you use to ask is called SQL. Stands for Structured Query Language.",
            "Some people pronounce it sequel, some say S-Q-L. Both camps will fight you about it.",
            "The real war is between people who use databases and people who put everything in spreadsheets.",
        ]),
        (["git", "commit", "branch", "merge", "push"], [
            "Git is like a time machine for your code. You can go back to any point in history.",
            "Every time you save a checkpoint, that's a commit. Like a save point in a video game.",
            "Branches let you try something risky without breaking the main game.",
            "And merging is when you bring your experiment back into the main timeline.",
            "Sometimes two timelines conflict. That's a merge conflict. It's as fun as it sounds.",
            "The worst is when someone force pushes. That's like overwriting everyone else's save files.",
        ]),
        (["auth", "authentication", "login", "jwt", "token", "oauth"], [
            "Authentication is just proving you are who you say you are. Like showing your ID at a bar.",
            "A JWT token is like a wristband at a concert. Once you're in, you just show the band.",
            "You don't have to go back to the entrance and show your ticket every time.",
            "But wristbands expire. And if someone copies yours, they get in too. That's the risk.",
            "OAuth is fancier. It's like having a bouncer call your mom to confirm it's really you.",
            "Nobody loves OAuth. But everybody uses it. That's enterprise software for you.",
        ]),
    ]

    /// Returns a random set of 6 filler lines for the given theme.
    static func randomSet(themeId: String, characters: [CharacterConfig]) -> [DialogueLine] {
        guard characters.count >= 2 else { return [] }

        let sets: [[String]]
        switch themeId {
        case "gilfoyle-dinesh":
            sets = gilfoyleDinesh
        case "rick-morty":
            sets = rickMorty
        case "sherlock-watson":
            sets = sherlockWatson
        case "chandler-joey":
            sets = chandlerJoey
        case "dwight-jim":
            sets = dwightJim
        case "jesse-walter":
            sets = jesseWalter
        case "tony-jarvis":
            sets = tonyJarvis
        default:
            sets = generic
        }

        guard !sets.isEmpty else { return [] }
        let chosen = sets.randomElement()!

        return chosen.enumerated().map { i, text in
            DialogueLine(characterIndex: i % 2, text: text)
        }
    }

    // MARK: - Gilfoyle & Dinesh

    static let gilfoyleDinesh: [[String]] = [
        [
            "Remember when Erlich tried to explain blockchain at a dinner party? He called it digital beads.",
            "At least he was confident. Confidently wrong is still a vibe.",
            "Big Head once asked me if Python was a snake or a programming language. I said both, and he believed me.",
            "To be fair, Big Head accidentally got promoted three times. Maybe ignorance IS bliss.",
            "Richard once spent two days on a bug that turned out to be a missing semicolon.",
            "Classic Richard. The man pivots faster than a ceiling fan in a hurricane.",
        ],
        [
            "I benchmarked your last commit. It runs slower than Erlich's pitch delivery.",
            "That's impossible. Nothing is slower than Erlich's pitch delivery.",
            "Your code has more redundancy than Big Head's job title collection.",
            "Hey, at least my code compiles. Unlike your personality.",
            "I once wrote a script that was so efficient, it finished before I hit enter.",
            "That literally cannot happen Gilfoyle. That's not how computers work.",
        ],
        [
            "What's taking so long? My grandma could deploy faster and she thinks WiFi comes from the government.",
            "Your grandma also thinks you have a girlfriend, so her judgment is questionable.",
            "At Hooli, Gavin Belson once made the entire team meditate before a code review.",
            "And then he fired everyone who closed their eyes. Classic Silicon Valley management.",
            "Remember Jian-Yang's hot dog app? Not Hot Dog. That thing actually shipped.",
            "It had one feature and it worked perfectly. More than we can say for most startups.",
        ],
        [
            "I automated my morning routine. Coffee maker starts when my alarm goes off.",
            "Dinesh, that's just a timer. People have had those since the seventies.",
            "Yeah but mine uses MQTT and a Raspberry Pi. It's IoT.",
            "You spent two hundred dollars to replace a five dollar timer. Very on brand.",
            "At least I'm not the one who named his server rack after Norse gods.",
            "Anton is a perfectly respectable name for a server. He has more uptime than you.",
        ],
        [
            "I had a nightmare last night that our entire codebase was written in COBOL.",
            "That's not a nightmare, that's just working at a bank.",
            "Erlich once said COBOL stood for Cool Object Based Operational Language.",
            "And nobody corrected him because honestly? That tracks.",
            "The scariest part of the dream was Richard saying 'let's pivot to mainframes.'",
            "At this point, a Richard pivot would be the least surprising thing in my week.",
        ],
    ]

    // MARK: - Rick & Morty

    static let rickMorty: [[String]] = [
        [
            "Morty, in dimension C-137 we solved all bugs with a portal gun. Just yeet the bad code into another dimension.",
            "Oh geez Rick, that sounds like it would cause a lot of problems for the other dimensions.",
            "Not our problem Morty. That's the beauty of interdimensional garbage disposal.",
            "I-I-I feel like there's an ethical issue here Rick.",
            "Ethics are just social constructs Morty. Like unit tests. Nobody actually writes those.",
            "Wait, we're supposed to write unit tests? Oh man, oh geez.",
        ],
        [
            "You know what Morty, this codebase reminds me of the Citadel of Ricks. Bloated, bureaucratic, full of clones.",
            "W-w-which part are the clones Rick? The duplicate functions?",
            "Every function Morty. They're all doing the same thing slightly differently. It's a multiverse of bad decisions.",
            "Can we at least refactor it? Like, merge the timelines?",
            "Wubba lubba dub dub, the kid wants to refactor. Sure Morty, let's play god with the codebase.",
            "Is that a yes? I can never tell when you're being sarcastic Rick.",
        ],
        [
            "I turned myself into a recursive function Morty. I'm Recursive Rick!",
            "Oh no, not again. Last time you turned yourself into something we lost three days.",
            "The base case is when I get bored Morty. Which should be... about... now.",
            "Rick you can't just exit a recursive function because you're bored.",
            "I literally just did Morty. I literally just did. Stack overflow is for quitters.",
            "That's not what stack overflow means Rick! Oh geez.",
        ],
    ]

    // MARK: - Sherlock & Watson

    static let sherlockWatson: [[String]] = [
        [
            "The game is afoot Watson. Someone has committed code without running the linter first.",
            "Good heavens. How can you tell?",
            "Elementary. The indentation is inconsistent. Tabs and spaces mixed. A crime against readability.",
            "Right. And for those of us who aren't sociopaths, why does that matter?",
            "Because Watson, messy code leads to messy thinking. And messy thinking leads to bugs.",
            "I'm writing that down. Messy code, messy thinking. Could be a chapter title.",
        ],
        [
            "I've identified seventeen inefficiencies in this function alone Watson.",
            "Seventeen? That seems excessive even for you Sherlock.",
            "The author clearly wrote this at three in the morning fueled by nothing but desperation and energy drinks.",
            "That's oddly specific. Can you really deduce their beverage choices from code?",
            "The variable names switch from camelCase to snake_case halfway through. Classic caffeine crash behavior.",
            "Brilliant. Absolutely brilliant. I hate how that makes sense.",
        ],
    ]

    // MARK: - Chandler & Joey

    static let chandlerJoey: [[String]] = [
        [
            "Could this loading time BE any longer? I've aged three years waiting for this build.",
            "Maybe it needs a sandwich. Everything works better after a sandwich.",
            "Joey, computers don't eat sandwiches. That's not how technology works.",
            "How do YOU know? Have you ever offered one to a computer?",
            "I... no. No I haven't. And I'm not going to start now.",
            "Your loss. My laptop and I had meatball subs last Tuesday. Best pair programming session ever.",
        ],
        [
            "So this merge conflict walks into a bar. The bartender says 'pick a side.'",
            "I don't get it. What's a merge conflict?",
            "It's when two people change the same thing and the computer doesn't know which one to keep. Like when we both dated the same girl.",
            "Oh! So it's like that time with the identical twins?",
            "No Joey, it's nothing like the twins. Please never bring up the twins.",
            "How YOU doin, merge conflict? Just pick the better looking code.",
        ],
    ]

    // MARK: - Dwight & Jim

    static let dwightJim: [[String]] = [
        [
            "Question. What kind of developer uses print statements for debugging? Answer. A weak one.",
            "I use print statements Dwight. They work fine.",
            "On my beet farm, we don't use print statements. We use proper logging with timestamps.",
            "Your beet farm has a logging system?",
            "Of course. How else would I track which beets were harvested and when? MICHAEL would understand this.",
            "Looks at camera. He just compared debugging to beet farming. And somehow it made sense.",
        ],
        [
            "FALSE. You cannot push to main without a code review. That is a fireable offense.",
            "Dwight, we've pushed to main like twelve times today.",
            "And each time, a small part of me died. As Assistant Regional Developer, I cannot condone this.",
            "That's not a real title Dwight.",
            "It's on my business card Jim. I had them printed at Staples. With embossing.",
            "Of course you did. Looks at camera. He actually laminated them too.",
        ],
    ]

    // MARK: - Jesse & Walter

    static let jesseWalter: [[String]] = [
        [
            "The code must be pure Jesse. Ninety nine point one percent is not acceptable.",
            "Yo Mr. White, it works though. Like, the tests pass and everything.",
            "Working is not the same as being pure. Any amateur can make code that works.",
            "So what, we're supposed to make code that's like, artisanal? Craft code?",
            "I am the one who refactors Jesse. Remember that.",
            "Yeah Mr. White! Yeah science! Wait, this is computer science right?",
        ],
        [
            "Jesse, do you know what a memory leak is?",
            "Is that like when you forget stuff? Because I forget stuff all the time yo.",
            "No. It's when a program keeps using memory and never gives it back. Like Tuco. He never gave anything back.",
            "Yo that's dark Mr. White. But like, accurate.",
            "We need to find every allocation and ensure proper deallocation. No half measures.",
            "No half measures. Got it. I'll just delete everything and start over.",
        ],
    ]

    // MARK: - Tony & JARVIS

    static let tonyJarvis: [[String]] = [
        [
            "JARVIS, remind me why we're building this at three AM instead of sleeping like normal people.",
            "Because sir, and I quote, sleep is for people who aren't changing the world.",
            "Did I say that? That sounds like something I'd say. Very quotable. Write that down.",
            "It's been recorded sir. Along with the other four hundred seventy two quotable statements from this month.",
            "Only four seventy two? I'm slipping. Pepper would say I'm not trying hard enough.",
            "Miss Potts would say you should go to bed sir. As would any medical professional.",
        ],
        [
            "Run the diagnostics one more time JARVIS. I want to see those numbers.",
            "Sir, this is the fourteenth time. The numbers have not changed since the third run.",
            "Okay but what if they change on the fifteenth? You don't know. Nobody knows.",
            "Statistically sir, the probability of different results from identical inputs is zero.",
            "Never tell me the odds JARVIS. That's a different franchise but the point stands.",
            "Noted sir. Shall I also not tell you that your coffee has been cold for two hours?",
        ],
    ]

    // MARK: - Generic fallback

    static let generic: [[String]] = [
        [
            "You know what, this codebase is actually starting to look pretty good.",
            "Don't jinx it. Every time someone says that, something breaks.",
            "That's not how computers work. They don't understand jinxes.",
            "Tell that to the server that crashed right after I said 'looks stable' last month.",
            "Okay that was a coincidence. Probably. Almost certainly.",
            "I'm not saying anything positive about this code until it's in production. And even then.",
        ],
    ]
}
