/// What this app can answer without a person.
///
/// **Written down rather than generated.** A model asked "how do I get a
/// refund" will produce a confident, plausible, wrong answer — and this app
/// has nothing to refund, which is exactly the kind of fact no general
/// system knows. Every answer here is checked against what the app actually
/// does today; when the app changes, these change with it or they become
/// worse than having nothing.
///
/// The match is deliberately shallow: shared words, weighted towards the
/// unusual ones. It is not trying to understand the question. It is trying to
/// find the one card that mentions the same things, and to say honestly when
/// nothing does — because the failure that matters is answering the wrong
/// question confidently, not failing to answer.
class HelpAnswer {
  const HelpAnswer({
    required this.id,
    required this.question,
    required this.answer,
    required this.keywords,
  });

  final String id;

  /// How the question is put back to somebody, so they can tell at a glance
  /// whether it is the one they asked.
  final String question;

  final String answer;

  /// The words worth matching on. Not the whole question: "how do i" is in
  /// every question anybody types and matching it matches everything.
  final List<String> keywords;
}

/// Everything the app is asked, in the order somebody meets it.
const List<HelpAnswer> helpAnswers = <HelpAnswer>[
  HelpAnswer(
    id: 'record',
    question: 'How do I record something?',
    answer: 'The gold microphone button, from anywhere in the app. It starts '
        'a new song and goes straight into recording — no naming, no '
        'choosing where it lives. You can do both afterwards, once there is '
        'something worth filing.\n\n'
        'To add a recording to a song you already have, open it and press '
        'Record on the toolbar.',
    keywords: <String>[
      'record', 'recording', 'microphone', 'mic', 'capture', 'sing', 'play',
      'new', 'start', 'idea',
    ],
  ),
  HelpAnswer(
    id: 'take',
    question: 'How do I add a take to a song?',
    answer: 'Open the song and press Record on the toolbar. That adds a new '
        'take alongside the ones already there.\n\n'
        'A take stays private to you until you share it. Press Takes to see '
        'all of them and share the one you want the room to hear — nothing '
        'you have not shared is ever audible to anybody, including on the '
        'Open Mic.',
    keywords: <String>[
      'take', 'takes', 'another', 'add', 'overdub', 'layer', 'part', 'second',
      'share', 'shared',
    ],
  ),
  HelpAnswer(
    id: 'sheet',
    question: 'How do I get the chords and words for my song?',
    answer: 'Record something first, then open the song and press Song '
        'Sheet.\n\n'
        'CoLabRoom listens to the recording, works out every chord, finds the '
        'key and the tempo, and writes down the words you sang — then puts '
        'the chords over the words. It takes a few minutes and it keeps going '
        'if you leave the screen.',
    keywords: <String>[
      'chord', 'chords', 'sheet', 'lyrics', 'words', 'key', 'tempo', 'bpm',
      'transcribe', 'transcription', 'tab', 'analyse', 'analyze',
      'notation',
    ],
  ),
  HelpAnswer(
    id: 'audience',
    question: 'Who can hear my song?',
    answer: 'Look at the bar under the toolbar when a song is open. It always '
        'says who can hear it, and tapping it shows the whole picture:\n\n'
        '• Only you — nobody else is in the room it lives in\n'
        '• Your room — everybody in that room\n'
        '• People you asked — somebody invited to this one song\n'
        '• Anyone — it is on the Open Mic\n\n'
        'You can move it back down at any time, and a take you have not '
        'shared stays private no matter where the song sits.',
    keywords: <String>[
      'who', 'hear', 'private', 'privacy', 'public', 'see', 'visible',
      'audience', 'secret', 'safe', 'sharing', 'permission',
    ],
  ),
  HelpAnswer(
    id: 'openmic',
    question: 'How do I put a song on the Open Mic?',
    answer: 'Open the song, tap the bar that says who can hear it, then '
        '"Put it on the Open Mic".\n\n'
        'Anybody signed in can then find it, listen, and offer to play on it. '
        'Only the takes your room has already heard become audible — never '
        'one you are still working on privately. The same bar takes it back '
        'down whenever you like.',
    keywords: <String>[
      'open', 'mic', 'publish', 'post', 'share', 'public', 'everybody',
      'stage', 'upload', 'showcase',
    ],
  ),
  HelpAnswer(
    id: 'takedown',
    question: 'How do I take a song off the Open Mic?',
    answer: 'Open the song, tap the bar that says who can hear it, then '
        '"Take it off the Open Mic". It stops being findable immediately.\n\n'
        'Nothing you did while it was up is lost — the song, the takes and '
        'the song sheet all stay exactly as they were.',
    keywords: <String>[
      'take', 'off', 'remove', 'delete', 'down', 'unpublish', 'private',
      'hide', 'undo', 'mic',
    ],
  ),
  HelpAnswer(
    id: 'ask',
    question: 'How do I ask somebody for help on a song?',
    answer: 'Two ways, depending on whether you have somebody in mind.\n\n'
        'If you do: find them in the Open Mic, open their profile, and ask '
        'them. They see the one song you named and nothing else of yours '
        'until they say yes.\n\n'
        'If you do not: put the song on the Open Mic and say what it needs. '
        'It then shows up for people who play that part, and they can offer.',
    keywords: <String>[
      'ask', 'help', 'request', 'collaborate', 'collaborator', 'someone',
      'somebody', 'musician', 'find', 'need', 'bass', 'drummer', 'singer',
    ],
  ),
  HelpAnswer(
    id: 'answer-ask',
    question: 'Somebody asked me to play on their song. Where is it?',
    answer: 'In your notifications — the bell in the top corner. Open it and '
        'you can say yes or no.\n\n'
        'Saying yes gives you that one song, not the rest of their work. '
        'Saying no tells them and nothing else happens.',
    keywords: <String>[
      'asked', 'invite', 'invited', 'invitation', 'notification', 'bell',
      'accept', 'decline', 'yes', 'request', 'join',
    ],
  ),
  HelpAnswer(
    id: 'rooms',
    question: 'What is a room, and how do I make one?',
    answer: 'A room is who can see a set of songs — your band, a side '
        'project, or just the songs you write on your own. Every song lives '
        'in one, and the room decides who hears it.\n\n'
        'Make one from Your music: press New song and create a room without '
        'leaving the flow, or open the rooms list and press New room.',
    keywords: <String>[
      'room', 'rooms', 'band', 'group', 'folder', 'catalog', 'organise',
      'organize', 'make', 'create', 'new',
    ],
  ),
  HelpAnswer(
    id: 'invite-room',
    question: 'How do I invite somebody to my room?',
    answer: 'Open the room and press the person icon in the top corner.\n\n'
        'A room invitation is everything in it, now and later — so if you '
        'only want somebody on one song, ask them to play on that song '
        'instead. You can also invite somebody you met on the Open Mic '
        'straight from their profile.',
    keywords: <String>[
      'invite', 'add', 'member', 'bandmate', 'friend', 'room', 'join',
      'collaborator', 'people',
    ],
  ),
  HelpAnswer(
    id: 'remove-member',
    question: 'How do I remove somebody from a room?',
    answer: 'Open the room, then the members list, and remove them there. '
        'They lose the room and every song in it.\n\n'
        'What they already recorded stays — a take keeps its author, and '
        'removing somebody does not erase the work they did with you.',
    keywords: <String>[
      // No prepositions. "out" was here and it is the only card carrying it,
      // so "why is my guitar out of tune" was answered with how to remove
      // somebody from a room — a distinctive word that means nothing.
      'remove', 'kick', 'member', 'leave', 'left', 'quit', 'band',
      'delete', 'someone',
    ],
  ),
  HelpAnswer(
    id: 'sounds-like',
    question: 'What does "sounds like" do on my profile?',
    answer: 'It is how the app finds people making the kind of music you '
        'make. "Guitarist" does not say whether you play metal or jazz; this '
        'does.\n\n'
        'Nobody is ranked by it. It moves you sideways towards people in the '
        'same corner, never up or down past anybody. Set it from your '
        'profile, under the tuning icon. Five words at most — fewer and '
        'sharper works better than listing everything.',
    keywords: <String>[
      'sounds', 'like', 'genre', 'style', 'taste', 'tags', 'profile',
      'describe', 'match', 'matching',
    ],
  ),
  HelpAnswer(
    id: 'discoverable',
    question: 'How do I show up in the Open Mic, or stop showing up?',
    answer: 'Your profile, under the tuning icon in the corner. It is off '
        'until you turn it on — nobody appears in the Open Mic without '
        'choosing to.\n\n'
        'The same place decides who can see your city: nobody, only people '
        'you have made something with, or anybody browsing.',
    keywords: <String>[
      'discoverable', 'found', 'find', 'visible', 'hidden', 'profile',
      'appear', 'listed', 'city', 'location', 'search',
    ],
  ),
  HelpAnswer(
    id: 'sets',
    question: 'How do I make a set list?',
    answer: 'In Your music, switch from Songs to Sets and press New set.\n\n'
        'A set is a running order for one occasion — Friday practice, '
        "Saturday's show — built from songs you already have, in whatever "
        'order you will play them.',
    keywords: <String>[
      'set', 'sets', 'setlist', 'list', 'gig', 'order', 'practice',
      'performance', 'live',
    ],
  ),
  HelpAnswer(
    id: 'missing-song',
    question: 'I cannot find a song I made.',
    answer: 'Everything you have is in Your music, grouped by the room it '
        'lives in. If you cannot see it, use the search box — it matches '
        'titles, room names, and a lyric you remember.\n\n'
        'If it was somebody else\'s song you were invited to, it is under '
        'their room rather than yours.',
    keywords: <String>[
      'find', 'lost', 'missing', 'gone', 'where', 'cannot', 'disappeared',
      'search', 'song', 'deleted',
    ],
  ),
  HelpAnswer(
    id: 'report',
    question: 'Somebody posted something they should not have.',
    answer: 'Report it. There is a flag on a song\'s public page, on a '
        'person\'s profile under the More menu, and on a room under the same '
        'menu.\n\n'
        'You can also block somebody from their profile — you stop seeing '
        'each other completely, in both directions, and they are not told.\n\n'
        'Somebody reads every report.',
    keywords: <String>[
      'report', 'block', 'abuse', 'harassment', 'inappropriate', 'offensive',
      'spam', 'copyright', 'stolen', 'complaint', 'flag',
    ],
  ),
  HelpAnswer(
    id: 'refund',
    question: 'How do I get a refund? What does this cost?',
    answer: 'Nothing. There is no paid tier and no way to pay for anything in '
        'CoLabRoom right now, so there is nothing to refund.\n\n'
        'If you were charged by something calling itself CoLabRoom, it was '
        'not us — tell us at support@colabroom.com and do not pay it.',
    keywords: <String>[
      'refund', 'money', 'pay', 'paid', 'payment', 'charge', 'charged',
      'cost', 'price', 'subscription', 'billing', 'cancel', 'free',
      'premium', 'upgrade',
    ],
  ),
  HelpAnswer(
    id: 'delete-account',
    question: 'How do I delete my account?',
    answer: 'Your account screen, at the bottom. It removes your profile, '
        'your rooms and everything in them.\n\n'
        'It cannot be undone, and takes with it songs other people may be '
        'working on with you — so if you share a room, hand it over first.',
    keywords: <String>[
      'delete', 'account', 'remove', 'close', 'quit', 'leave', 'erase',
      'data', 'gdpr', 'deactivate',
    ],
  ),
  HelpAnswer(
    id: 'demo',
    question: 'What is a DEMO account?',
    answer: 'A seeded account, not a person. They exist so the app can be '
        'tested with a crowd in it before there is a real one.\n\n'
        'They are always labelled, they will never answer you, and asking one '
        'to play on your song will not go anywhere. They are removed in '
        'batches as real people arrive.',
    keywords: <String>[
      'demo', 'fake', 'bot', 'test', 'real', 'account', 'label', 'chip',
      'seeded', 'nobody',
    ],
  ),
];

/// The best answer for what somebody typed, or null when nothing is close.
///
/// Scored on the unusual words rather than all of them. "How do I share a
/// song" and "how do I record a song" have three words in common and nothing
/// useful between them; the whole signal is in "share" and "record".
///
/// Returning null is a real answer and the important one. A help system that
/// always produces something produces a wrong thing most of the time, and a
/// confidently wrong answer costs more than a shrug and a route to a person.
HelpAnswer? bestHelpAnswer(String typed) {
  final words = _words(typed);
  if (words.isEmpty) return null;

  HelpAnswer? best;
  var bestScore = 0.0;
  for (final answer in helpAnswers) {
    final score = _score(words, answer);
    if (score > bestScore) {
      bestScore = score;
      best = answer;
    }
  }

  // Half of one distinctive word. A word appearing on a single card is worth
  // 1.0, so any one of those clears it; a word shared by two cards is worth
  // 0.5 and clears it alone only just.
  return bestScore >= 0.5 ? best : null;
}

/// How well [words] fit [answer], weighted by how distinctive each hit is.
///
/// Counting hits and dividing by the length of the question was the first
/// attempt and it failed in both directions at once. "Is my music private"
/// went to the song sheet because "music" was on that card and matched as
/// strongly as "private" did; "someone posted something offensive" matched
/// nothing, because one hit in four words fell under the threshold.
///
/// Rarity fixes both. A word that appears on exactly one card is the whole
/// answer — "offensive" can only mean one thing here — and a word on six
/// cards settles almost nothing. Dividing by how many cards carry the word
/// says that directly, and stops a question being scored on its own length.
double _score(Set<String> words, HelpAnswer answer) {
  var total = 0.0;
  for (final word in words) {
    if (!answer.keywords.contains(word)) continue;
    final carriers = helpAnswers.where((a) => a.keywords.contains(word)).length;
    total += 1.0 / carriers;
  }
  return total;
}

/// Every answer, ranked, for the list somebody browses when they have not
/// typed anything.
List<HelpAnswer> helpAnswersFor(String typed) {
  final words = _words(typed);
  if (words.isEmpty) return helpAnswers;
  final scored = <(HelpAnswer, int)>[];
  for (final answer in helpAnswers) {
    final hits = words.where(answer.keywords.contains).length;
    if (hits > 0) scored.add((answer, hits));
  }
  scored.sort((a, b) => b.$2.compareTo(a.$2));
  return <HelpAnswer>[for (final entry in scored) entry.$1];
}

/// Words worth matching on: lowercased, stripped of punctuation, and without
/// the ones every question contains.
Set<String> _words(String text) {
  const ignore = <String>{
    'how', 'do', 'i', 'a', 'an', 'the', 'to', 'my', 'me', 'is', 'it', 'in',
    'on', 'of', 'and', 'or', 'can', 'you', 'get', 'what', 'where', 'why',
    'this', 'that', 'for', 'with', 'if', 'be', 'am', 'are', 'was', 'does',
    'there', 'here', 'have', 'has', 'not', 'no', 'want', 'need', 'please',
  };
  return text
      .toLowerCase()
      .replaceAll(RegExp(r"[^a-z0-9\s']"), ' ')
      .split(RegExp(r'\s+'))
      .where((word) => word.length > 1 && !ignore.contains(word))
      .toSet();
}
