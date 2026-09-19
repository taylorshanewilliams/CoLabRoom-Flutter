import 'package:colabroom/services/brought_chart.dart';
import 'package:colabroom/services/music_reference.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reading a chart somebody already has.
///
/// Every fixture here is either written for this test or taken from a song
/// old enough to be anyone's — Amazing Grace, and the traditional words of
/// House of the Rising Sun. Nothing under copyright goes in this repository,
/// which is the same rule the feature itself is built on: this app never
/// fetches a chart from anywhere, it only reads one a person brought.

/// Every line of the chart, as `readChart` understood it.
List<String> _shape(BroughtChart chart) => <String>[
      for (final line in chart.lines)
        '${line.kind.name}|${line.text}|'
            '${line.chords.map((c) => '${c.chord}@${c.at}').join(',')}',
    ];

void main() {
  group('a chord line is chords and a lyric line is words', () {
    test('"A" is a chord and "A man walks in" is not', () {
      expect(isChordName('A'), isTrue);
      expect(isChordName('Am'), isTrue);
      expect(isChordName('G/B'), isTrue);
      expect(isChordName('Am7'), isTrue);
      expect(isChordName('F#m7b5'), isTrue);
      expect(isChordName('I'), isFalse);
      expect(isChordName('the'), isFalse);
      expect(isChordName('Oh'), isFalse);
      expect(isChordName('A:min'), isFalse,
          reason: 'Harte is the analysis speaking, never a person');
    });

    test('"Am I the only one" stays a lyric', () {
      final chart = readChart(
        'Am I the only one\n'
        'Am      C\n'
        'Still awake\n',
      );
      expect(_shape(chart), <String>[
        'words|Am I the only one|',
        'words|Still awake|Am@0,C@8',
      ]);
    });

    test('a single word that happens to be a chord is still a lyric line', () {
      // "Do" would be a D diminished under a looser grammar, and a line of
      // words would be drawn as music.
      final chart = readChart('Do\nyou hear me\n');
      expect(_shape(chart), <String>[
        'words|Do|',
        'words|you hear me|',
      ]);
    });
  });

  group('chords over words, the way a tab site prints them', () {
    test('the chords land on the words they were written above', () {
      const source = '[Verse 1]\n'
          'G             G7          C          G\n'
          'Amazing grace how sweet the sound\n';
      final chart = readChart(source);
      expect(_shape(chart), <String>[
        'heading|Verse 1|',
        'words|Amazing grace how sweet the sound|G@0,G7@14,C@26,G@33',
      ]);
      expect(chart.chordsUsed, <String>['G', 'G7', 'C']);
    });

    test('a chord past the end of the line stays on the line', () {
      const source = 'C                         G\n'
          'That saved a wretch\n';
      final chart = readChart(source);
      expect(chart.lines.single.chords.last.at, 19,
          reason: 'the words are 19 characters long and a chord cannot sit '
              'in the margin');
    });

    test('tabs used for alignment count as columns, not as one character', () {
      // Eight-column stops, which is what every text editor a chart is typed
      // in does. Counted as one character each, every chord in the line lands
      // over the wrong word.
      const source = 'C\tG\tAm\n'
          'Amazing grace how sweet\n';
      final chart = readChart(source);
      expect(_shape(chart), <String>[
        'words|Amazing grace how sweet|C@0,G@8,Am@16',
      ]);
    });

    test('a row of chords with nothing under it is kept as a row', () {
      const source = '[Intro]\n'
          'Am  C  D  F\n'
          '\n'
          'Am              C\n'
          'There is a house in New Orleans\n';
      final chart = readChart(source);
      expect(_shape(chart), <String>[
        'heading|Intro|',
        'chords||Am@0,C@0,D@0,F@0',
        'blank||',
        'words|There is a house in New Orleans|Am@0,C@16',
      ]);
    });

    test('bar lines and repeat marks pass through a chord row', () {
      final chart = readChart('| Am | C | D | F | x4\n');
      expect(chart.lines.single.chords.map((c) => c.chord).toList(),
          <String>['Am', 'C', 'D', 'F']);
    });

    test('windows line endings read as the same chart', () {
      const source = 'C      G\r\n'
          'Amazing grace\r\n';
      expect(_shape(readChart(source)), <String>[
        'words|Amazing grace|C@0,G@7',
      ]);
    });
  });

  group('words with the chords already in brackets', () {
    test('an inline chord names the letter it is written in front of', () {
      final chart = readChart('[G]Amazing [C]grace how [G]sweet the sound\n');
      expect(_shape(chart), <String>[
        'words|Amazing grace how sweet the sound|G@0,C@8,G@18',
      ]);
    });

    test('a bracket that is not a chord is left in the words', () {
      final chart = readChart('[x4] [Am]Play it again\n');
      expect(_shape(chart), <String>[
        'words|[x4] Play it again|Am@5',
      ]);
    });

    test('a bracketed part name is a heading and a bracketed chord is not',
        () {
      final chart = readChart('[Chorus]\n[C]\n');
      expect(_shape(chart), <String>[
        'heading|Chorus|',
        'chords||C@0',
      ]);
    });
  });

  group('ChordPro', () {
    test('the header is kept as facts and the body as lines', () {
      const source = '{title: Amazing Grace}\n'
          '{artist: Traditional}\n'
          '{key: G}\n'
          '{capo: 2}\n'
          '{tuning: DADGAD}\n'
          '\n'
          '{start_of_chorus: Chorus}\n'
          '[G]Amazing [C]grace\n'
          '{end_of_chorus}\n';
      final chart = readChart(source);
      expect(chart.title, 'Amazing Grace');
      expect(chart.artist, 'Traditional');
      expect(chart.key, 'G');
      expect(chart.capo, '2');
      expect(chart.tuning, 'DADGAD');
      expect(_shape(chart), <String>[
        'heading|Chorus|',
        'words|Amazing grace|G@0,C@8',
      ]);
    });

    test('the short forms read the same as the long ones', () {
      final chart = readChart('{t: Amazing Grace}\n{a: Traditional}\n{k: G}\n'
          '{c: Verse 1}\n[G]Amazing\n');
      expect(chart.title, 'Amazing Grace');
      expect(chart.artist, 'Traditional');
      expect(chart.key, 'G');
      expect(_shape(chart), <String>[
        'heading|Verse 1|',
        'words|Amazing|G@0',
      ]);
    });

    test('a directive this reader does not know is kept exactly as it was',
        () {
      final chart = readChart('{tempo: 96}\n{G}rand\n');
      expect(_shape(chart), <String>[
        'text|{tempo: 96}|',
        'words|{G}rand|',
      ]);
    });
  });

  group('tablature', () {
    test('a tab block is kept character for character', () {
      const source = '[Intro]\n'
          '{start_of_tab}\n'
          'e|-----0-----|\n'
          'B|---1---1---|\n'
          'G|-0-------0-|\n'
          '{end_of_tab}\n';
      final chart = readChart(source);
      expect(_shape(chart), <String>[
        'heading|Intro|',
        'tab|e|-----0-----||',
        'tab|B|---1---1---||',
        'tab|G|-0-------0-||',
      ]);
    });

    test('a tab block with no directives around it is still a tab block', () {
      const source = 'e|-----0-----|\n'
          'B|---1---1---|\n'
          '\n'
          'Amazing grace\n';
      final chart = readChart(source);
      expect(chart.lines.first.kind, ChartLineKind.tab);
      expect(chart.lines[1].kind, ChartLineKind.tab);
      expect(chart.lines.last.kind, ChartLineKind.words);
    });

    test('tablature comes back out inside a tab block', () {
      final chart = readChart('e|--0--|\nB|--1--|\n');
      expect(chart.chordPro,
          '{start_of_tab}\ne|--0--|\nB|--1--|\n{end_of_tab}\n');
    });
  });

  group('what a chart says about itself', () {
    test('a Capo line is a fact and not a lyric', () {
      final chart = readChart('Capo 2\n\n[G]Amazing\n');
      expect(chart.capo, '2');
      expect(_shape(chart), <String>['words|Amazing|G@0']);
    });

    test('Key and Tuning need their colon, so a lyric keeps its words', () {
      final stated = readChart('Key: Am\nTuning: Drop D\n');
      expect(stated.key, 'Am');
      expect(stated.tuning, 'Drop D');

      final sung = readChart('Key to my heart\nTuning out the world\n');
      expect(sung.key, isNull);
      expect(sung.tuning, isNull);
      expect(_shape(sung), <String>[
        'words|Key to my heart|',
        'words|Tuning out the world|',
      ]);
    });
  });

  group('nothing is lost and nothing is added', () {
    test('a chart read and written out twice is the same chart', () {
      const source = 'Amazing Grace\n'
          'Capo 2\n'
          'Key: G\n'
          '\n'
          '[Verse 1]\n'
          'G             G7          C          G\n'
          'Amazing grace how sweet the sound\n'
          '\n'
          '[Intro]\n'
          'Am  C  D  F\n'
          'e|-----0-----|\n'
          'B|---1---1---|\n'
          '\n'
          '{tempo: 96}\n'
          'Repeat to fade\n';
      final once = readChart(source).chordPro;
      final twice = readChart(once).chordPro;
      expect(twice, once);
    });

    test('a line this reader cannot place still comes out the other side',
        () {
      final chart = readChart('Whistle the melody here\n');
      expect(_shape(chart), <String>['words|Whistle the melody here|']);
      expect(chart.chordPro, 'Whistle the melody here\n');
    });

    test('the traditional words come through with their chords', () {
      const source = '{title: House Of The Rising Sun}\n'
          '{artist: Traditional}\n'
          '\n'
          '[Verse 1]\n'
          'Am        C        D            F\n'
          'There is a house in New Orleans\n'
          'Am          C       E7      E7\n'
          'They call the Rising Sun\n';
      final chart = readChart(source);
      expect(chart.title, 'House Of The Rising Sun');
      expect(chart.chordCount, 8);
      expect(_shape(chart), <String>[
        'heading|Verse 1|',
        'words|There is a house in New Orleans|Am@0,C@10,D@19,F@31',
        'words|They call the Rising Sun|Am@0,C@12,E7@20,E7@24',
      ]);
      expect(
        chart.chordPro,
        '{title: House Of The Rising Sun}\n'
        '{artist: Traditional}\n'
        '\n'
        '{comment: Verse 1}\n'
        '[Am]There is a[C] house in[D] New Orleans[F]\n'
        '[Am]They call th[C]e Rising[E7] Sun[E7]\n',
      );
    });

    test('an empty paste has nothing in it', () {
      expect(readChart('   \n\n').isEmpty, isTrue);
      expect(readChart('[G]Amazing\n').isEmpty, isFalse);
    });
  });
}
