import 'dart:typed_data';

import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/openmic/musician_profile_screen.dart';
import 'package:colabroom/services/picture_for_upload.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

/// Pictures on a profile, and the four rules that keep them from becoming a
/// feed.
///
/// Eight is the shelf. Nobody else sees one until it has been looked at. A
/// picture can only play a song its owner owns and has already put out in the
/// open. And anybody who is shown one can say it should not be there.
///
/// Each of those is easy to lose in a later tidy-up: a cap raised "because
/// eight is arbitrary", a read that stops filtering because the function
/// already did, a tie that accepts any song id because the trigger checks it
/// anyway. These are what makes that a failure rather than a refactor.
Future<void> _boot(
  WidgetTester tester,
  Widget screen, {
  Size size = const Size(390, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    theme: CoLabRoomTheme.dark(),
    home: screen,
  ));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

/// The profile is a lazy ListView, so a section below the fold has not been
/// built and is invisible to `find` — and to a screen reader too.
Future<Finder> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isNotEmpty) return finder;
  await tester.scrollUntilVisible(finder, 220, maxScrolls: 14);
  await tester.pump(const Duration(milliseconds: 60));
  return finder;
}

/// A repository that remembers what was reported about what.
class _Reported extends InMemoryMusicRepository {
  _Reported() : super.from(InMemoryMusicRepository.seeded());

  String? kind;
  String? pictureId;

  @override
  Future<void> reportContent({
    required String kind,
    required String reason,
    String detail = '',
    String? profileId,
    String? projectId,
    String? layerId,
    String? linkId,
    String? roomId,
    String? pictureId,
  }) async {
    this.kind = kind;
    this.pictureId = pictureId;
  }
}

Uint8List _somePicture() => Uint8List.fromList(<int>[1, 2, 3, 4]);

void main() {
  test('eight is the shelf, and the ninth is refused in the server’s words',
      () async {
    final repository = InMemoryMusicRepository.seeded();
    for (var i = 0; i < 8; i += 1) {
      await repository.addGalleryPicture(bytes: _somePicture());
    }
    expect((await repository.loadGallery(repository.currentUserId)),
        hasLength(8));

    await expectLater(
      repository.addGalleryPicture(bytes: _somePicture()),
      throwsA(isA<PostgrestException>()
          .having((error) => error.code, 'code', '54000')
          .having((error) => error.message, 'message',
              'A profile can show up to eight pictures.')),
      reason: 'the cap is the database\'s, and the preview has to refuse the '
          'same thing with the same sentence',
    );
  });

  test('nobody else sees a picture until it has been looked at', () async {
    final repository = InMemoryMusicRepository.seeded();

    final asAStranger = await repository.loadGallery('preview-mara');
    expect(asAStranger.map((picture) => picture.id),
        isNot(contains('preview-picture-3')),
        reason: 'a picture nobody has looked at is nobody else\'s to see');
    expect(asAStranger.every((picture) => !picture.waiting), isTrue);

    repository.currentUserId = 'preview-mara';
    final asHerself = await repository.loadGallery('preview-mara');
    expect(asHerself.map((picture) => picture.id),
        contains('preview-picture-3'),
        reason: 'your own page shows it, so adding a picture does not look '
            'like nothing happening');
    expect(asHerself.firstWhere((each) => each.id == 'preview-picture-3').waiting,
        isTrue);
  });

  test('a picture keeps the words its owner wrote, trimmed', () async {
    final repository = InMemoryMusicRepository.seeded();
    await repository.addGalleryPicture(
      bytes: _somePicture(),
      caption: '  The Bird, October  ',
    );
    final mine = await repository.loadGallery(repository.currentUserId);
    expect(mine.single.caption, 'The Bird, October');
  });

  test('a picture plays one of your own songs, and only out in the open',
      () async {
    final repository = InMemoryMusicRepository.seeded();

    await expectLater(
      repository.addGalleryPicture(
        bytes: _somePicture(),
        // Mara's song. A picture that plays somebody else's song is a
        // picture claiming it.
        songId: 'preview-open-1',
      ),
      throwsA(isA<StateError>()),
    );
    expect(await repository.loadGallery(repository.currentUserId), isEmpty,
        reason: 'a refused tie must not leave a picture behind anyway');

    await repository.addGalleryPicture(
      bytes: _somePicture(),
      caption: 'The Bird, October',
      songId: 'preview-open-mine',
    );
    final mine = await repository.loadGallery(repository.currentUserId);
    expect(mine.single.songId, 'preview-open-mine');
    expect(mine.single.playsASong, isTrue,
        reason: 'the audio comes back with the picture, so tapping it plays '
            'without a second round trip that could answer differently');
  });

  test('taking one off takes that one off', () async {
    final repository = InMemoryMusicRepository.seeded();
    await repository.addGalleryPicture(bytes: _somePicture(), caption: 'One');
    await repository.addGalleryPicture(bytes: _somePicture(), caption: 'Two');
    final mine = await repository.loadGallery(repository.currentUserId);

    await repository.removeGalleryPicture(mine.first.id);
    final left = await repository.loadGallery(repository.currentUserId);
    expect(left.map((picture) => picture.caption), <String>['Two']);
  });

  testWidgets('an empty account still has the way in', (tester) async {
    final repository = InMemoryMusicRepository.seeded();
    await _boot(
      tester,
      MusicianProfileScreen(
        profileId: repository.currentUserId,
        repository: repository,
      ),
    );

    final door = await _reveal(
        tester, find.byKey(const Key('add_gallery_pictures')));
    expect(door, findsOneWidget,
        reason: 'a door that only exists once there is something behind it '
            'is one nobody finds the first time');
    expect(find.text('Add pictures'), findsOneWidget);
    expect(find.text('PICTURES'), findsOneWidget);
  });

  testWidgets('and nobody else is told what their page is missing',
      (tester) async {
    final repository = InMemoryMusicRepository.seeded();
    await _boot(
      tester,
      // Dev has no pictures.
      MusicianProfileScreen(profileId: 'preview-dev', repository: repository),
    );
    await tester.scrollUntilVisible(find.text('ELSEWHERE'), 220, maxScrolls: 14);
    await tester.pump(const Duration(milliseconds: 60));

    expect(find.text('PICTURES'), findsNothing,
        reason: 'an empty section on somebody else\'s page says nothing '
            'except that the app expected more of them');
  });

  testWidgets('somebody else’s pictures are there, and one of them plays',
      (tester) async {
    final repository = InMemoryMusicRepository.seeded();
    await _boot(
      tester,
      MusicianProfileScreen(profileId: 'preview-mara', repository: repository),
    );

    final strip = await _reveal(
        tester, find.byKey(const Key('gallery_picture_preview-picture-1')));
    expect(strip, findsOneWidget);
    expect(find.byKey(const Key('gallery_picture_preview-picture-3')),
        findsNothing,
        reason: 'the one nobody has looked at never reaches a stranger');

    await tester.tap(strip);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('gallery_caption')), findsOneWidget);
    expect(find.text('The Bird, October'), findsOneWidget);
    expect(find.byKey(const Key('gallery_play_preview-picture-1')),
        findsOneWidget,
        reason: 'a photograph of a gig plays the song from that night');
    expect(find.byKey(const Key('remove_gallery_picture')), findsNothing,
        reason: 'somebody else\'s picture is not yours to take off');
  });

  testWidgets('and saying a picture should not be there reaches it',
      (tester) async {
    final repository = _Reported();
    await _boot(
      tester,
      MusicianProfileScreen(profileId: 'preview-mara', repository: repository),
    );

    await tester.tap(await _reveal(
        tester, find.byKey(const Key('gallery_picture_preview-picture-2'))));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('report_gallery_picture')));
    await tester.pumpAndSettle();

    await tester.tap(find.text(ReportReason.values.first.label));
    await tester.pump();
    await tester.tap(find.text('Send the report'));
    await tester.pumpAndSettle();

    expect(repository.kind, 'gallery_picture');
    expect(repository.pictureId, 'preview-picture-2',
        reason: 'a report has to name the picture, not the person: a takedown '
            'that removed the whole profile would be the wrong answer');
  });

  testWidgets('your own picture can be taken off from the picture itself',
      (tester) async {
    final repository = InMemoryMusicRepository.seeded();
    await repository.addGalleryPicture(
      bytes: _somePicture(),
      caption: 'The pedalboard',
    );
    final mine = await repository.loadGallery(repository.currentUserId);

    await _boot(
      tester,
      MusicianProfileScreen(
        profileId: repository.currentUserId,
        repository: repository,
      ),
    );

    await tester.tap(await _reveal(
        tester, find.byKey(Key('gallery_picture_${mine.single.id}'))));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('remove_gallery_picture')));
    await tester.pumpAndSettle();

    expect(await repository.loadGallery(repository.currentUserId), isEmpty);
    expect(find.byKey(Key('gallery_picture_${mine.single.id}')), findsNothing);
  });

  testWidgets('a picture this phone cannot read is refused rather than sent',
      (tester) async {
    // The other half of this — that a readable picture comes back as a fresh
    // PNG, which is what leaves the EXIF behind — cannot be asserted here:
    // `Image.toByteData` never completes under flutter_test, so a test of the
    // encode hangs for ten minutes rather than failing. It is the same call
    // `shrink` has made for every avatar since 0077, so it is exercised on
    // every device instead. This half needs no encoder and is the half with
    // a rule in it.
    await expectLater(
      PictureForUpload.forGallery(Uint8List.fromList(<int>[1, 2, 3, 4])),
      throwsA(isA<PictureThisPhoneCannotRead>()),
      reason: 'a picture this phone cannot decode is one it cannot strip, and '
          'a gallery can do without a picture nobody here can read',
    );
  });
}
